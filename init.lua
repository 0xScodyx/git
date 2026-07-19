-- mod-version:3
--[[
  git.lua
  A lightweight git client for Lite XL.

  Features:
    * A toggleable git panel (right-hand sidebar) listing changed / untracked /
      staged files, grouped under collapsible directories (click a directory or
      press space to expand/collapse). Modified = orange, untracked = "?"
      (yellow), staged = green. After a commit the colors disappear.
    * Per-line gutter markers in the editor: green for added lines,
      yellow for modified lines (via git diff, persistent until commit).
    * GUI actions: stage / unstage, commit a single file or a whole directory,
      push, switch branch, create branch, add / rename / remove remote.
    * Right-click any file or directory in the panel for a context menu
      (commit / stage / open).
    * The built-in file tree (TreeView) is also colored by git status, and
      right-clicking an item there opens the same commit / stage menu.
    * A status-bar item showing the current branch and ahead/behind counts.

  Usage:
    * Press the toggle key (default ctrl+alt+shift+g) to open/close the panel.
    * In the panel: enter / click = open file, space = toggle directory,
      s = stage/unstage, right-click = context menu.
    * Commit / push / branch / remote are bound to ctrl+alt+shift+c/p/b/r.

  Configurable through config.plugins.git.
--]]

local core = require("core")
local common = require("core.common")
local command = require("core.command")
local config = require("core.config")
local style = require("core.style")

-- Resolve configured colors lazily into a cache so a color is always a table
-- even if the user overrode it with something odd. The cache is reset from a
-- config_spec `on_apply` hook whenever a color is changed in the Settings GUI,
-- so the new value takes effect immediately.
local color_cache = {}
local function git_color(name, color, fallback)
	if color_cache[name] then
		return color_cache[name]
	end
	local c
	-- The Settings GUI "color" widget stores values as {r,g,b,a} tables, but a
	-- user may still override the value in user/init.lua as a hex string, so we
	-- accept both shapes. Fall back to a safe color if neither parses.
	if type(color) == "table" then
		c = color
	else
		local ok, v = pcall(common.color, color)
		c = (ok and type(v) == "table") and v or fallback
	end
	color_cache[name] = c
	return c
end

local keymap = require("core.keymap")
local View = require("core.view")
local DocView = require("core.docview")
local StatusView = require("core.statusview")

--------------------------------------------------------------------------------
-- Conflict guard
--
-- The standalone "gitstatus" plugin registers a status-bar item named
-- "status:git", which this plugin also owns. Loading both makes Lite XL
-- assert + crash on startup ("status item already exists: status:git"),
-- which in turn breaks the whole session (e.g. Enter stops working).
--
-- We cannot reliably out-load gitstatus (plugin load order is by name /
-- priority and is outside our control), so instead we detect the conflict
-- up front and refuse to activate. The user must remove gitstatus.lua.
--
-- This plugin is NOT activated when a conflict is detected: we abort before
-- registering any commands, views, keymaps or the status item.
--------------------------------------------------------------------------------

local function plugin_dir()
	-- Plugins live next to this file. Works on Linux, macOS and Windows.
	local this = debug.getinfo(1, "S").source:match("@(.+)$")
	local dir = common.dirname(this)
	-- On Windows debug source may carry a volume prefix; normalize slashes.
	dir = dir:gsub("\\", PATHSEP)
	return dir
end

local function conflict_path()
	-- Check the same plugins folder this plugin lives in (covers userdir),
	-- plus the common system/user locations for both platforms.
	local candidates = {
		plugin_dir() .. PATHSEP .. "gitstatus.lua",
		USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "gitstatus.lua",
	}
	if PATHSEP == "\\" then
		-- Windows: also check the legacy AppData location.
		local appdata = os.getenv("APPDATA") or (os.getenv("USERPROFILE") and os.getenv("USERPROFILE") .. PATHSEP .. "AppData" .. PATHSEP .. "Roaming")
		if appdata then
			candidates[#candidates + 1] = appdata .. PATHSEP .. "lite-xl" .. PATHSEP .. "plugins" .. PATHSEP .. "gitstatus.lua"
		end
	else
		-- Linux/macOS: also check XDG and HOME fallbacks.
		local home = os.getenv("HOME")
		if home then
			candidates[#candidates + 1] = home .. PATHSEP .. ".config" .. PATHSEP .. "lite-xl" .. PATHSEP .. "plugins" .. PATHSEP .. "gitstatus.lua"
			candidates[#candidates + 1] = home .. PATHSEP .. ".lite-xl" .. PATHSEP .. "plugins" .. PATHSEP .. "gitstatus.lua"
		end
	end
	for _, p in ipairs(candidates) do
		if system.get_file_info(p) then return p end
	end
	return nil
end

local conflicting = conflict_path()
if conflicting then
	core.error(
		"[git] Plugin conflict: '" .. conflicting .. "' registers a status-bar " ..
		"item named 'status:git', which this plugin also owns. Lite XL would " ..
		"crash on startup with 'status item already exists: status:git' (and the " ..
		"whole session breaks, e.g. Enter stops working). This git plugin is " ..
		"NOT activated. Remove the conflicting plugin, then restart Lite XL:\n" ..
		"    rm " .. conflicting .. "\n" ..
		"(This plugin already provides the same TreeView coloring + branch/+/- " ..
		"status item, and much more.)"
	)
	return -- abort activation entirely; do not register anything
end


--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

config.plugins.git = common.merge({
	-- Key used to toggle the git panel.
	activate = "ctrl+alt+shift+g",

	-- How often (seconds) to refresh git state in the background.
	scan_rate = 2,

	-- Colors for status markers (stored as {r,g,b,a} tables, as the Settings
	-- GUI color widget provides). common.color parses the hex defaults.
	color_modified = common.color("#e6a800"), -- orange  (modified)
	color_untracked = common.color("#c9b400"), -- yellow  (untracked / ?)
	color_staged = common.color("#4ec94e"), -- green   (staged)
	color_gutter_added = common.color("#4ec94e"),
	color_gutter_modified = common.color("#e6a800"),

	-- Draw the per-line gutter diff markers in the editor.
	gutter_diff = true,

	config_spec = {
		name = "Git",
		{
			label = "Scan Rate",
			description = "How often (in seconds) to refresh git state in the background.",
			path = "scan_rate",
			type = "number",
			min = 1,
			default = 2,
		},
		{
			label = "Gutter Diff",
			description = "Show added/modified line markers on the left of the editor.",
			path = "gutter_diff",
			type = "toggle",
			default = true,
		},
		{
			label = "Color: Modified",
			description = "Color used for modified files and the per-line gutter marker.",
			path = "color_modified",
			type = "color",
			default = common.color("#e6a800"),
			on_apply = function() color_cache = {} end,
		},
		{
			label = "Color: Untracked",
			description = "Color used for untracked files (the '?' marker).",
			path = "color_untracked",
			type = "color",
			default = common.color("#c9b400"),
			on_apply = function() color_cache = {} end,
		},
		{
			label = "Color: Staged",
			description = "Color used for staged files and ahead/behind counts.",
			path = "color_staged",
			type = "color",
			default = common.color("#4ec94e"),
			on_apply = function() color_cache = {} end,
		},
		{
			label = "Color: Gutter Added",
			description = "Color of the gutter marker on added lines.",
			path = "color_gutter_added",
			type = "color",
			default = common.color("#4ec94e"),
			on_apply = function() color_cache = {} end,
		},
		{
			label = "Color: Gutter Modified",
			description = "Color of the gutter marker on modified lines.",
			path = "color_gutter_modified",
			type = "color",
			default = common.color("#e6a800"),
			on_apply = function() color_cache = {} end,
		},
	},
}, config.plugins.git)

-- exposed on style for convenience / external use
style.git_modified = git_color("modified", config.plugins.git.color_modified, style.accent)
style.git_untracked = git_color("untracked", config.plugins.git.color_untracked, style.dim)
style.git_staged = git_color("staged", config.plugins.git.color_staged, style.text)
style.git_gutter_added = git_color("g_added", config.plugins.git.color_gutter_added, style.accent)
style.git_gutter_modified = git_color("g_modified", config.plugins.git.color_gutter_modified, style.accent)

--------------------------------------------------------------------------------
-- Git state
--------------------------------------------------------------------------------

local git = {
	available = false,
	branch = nil,
	ahead = 0,
	behind = 0,
	files = {}, -- array of { path, abs_path, status } status in {M,A,??,D,...}
	-- panel tree: list of rows to draw. Each row is either
	--   { kind = "dir", name, path, open, child_count, status }
	--   { kind = "file", name, path, abs_path, x, y }
	tree = {},
}

-- Build the panel tree from git.files: group files under their directories,
-- keep directories collapsed (short), mark each dir with its "worst" status.
local function build_tree()
	if #git.files == 0 then
		git.tree = {}
		return
	end

	-- Build a nested dir tree: map dir path -> { name, path, open, children }
	git.dir_open = git.dir_open or {}
	local dirs = { [""] = { name = "", path = "", open = true, children = {} } }
	local function get_dir(dirpath)
		if not dirs[dirpath] then
			dirs[dirpath] = {
				name = dirpath:match("([^/]+)$") or dirpath,
				path = dirpath,
				open = git.dir_open[dirpath] or false,
				children = {},
			}
		end
		return dirs[dirpath]
	end

	local rank = { A = 3, M = 3, D = 3, R = 3, C = 3, ["?"] = 1, [" "] = 0, [""] = 0 }
	local function worse(a, b)
		return (rank[a] or 0) > (rank[b] or 0) and a or b
	end

	for _, f in ipairs(git.files) do
		local dir = f.path:match("^(.*)/") or ""
		local name = f.path:match("([^/]+)$") or f.path
		-- Walk the full directory chain so nested paths like "src/foo/bar.lua"
		-- build the hierarchy src -> foo, linking each level into its parent.
		-- Without this, only top-level dirs (and root files) ever appear, and
		-- anything deeper is silently dropped from the panel.
		local parent = ""
		local accum = ""
		for seg in dir:gmatch("[^/]+") do
			accum = accum == "" and seg or accum .. "/" .. seg
			local d = get_dir(accum)
			local pn = get_dir(parent)
			local linked = false
			for _, ch in ipairs(pn.children) do
				if ch.kind == "dir" and ch.path == accum then
					linked = true
					break
				end
			end
			if not linked then
				pn.children[#pn.children + 1] = { kind = "dir", name = seg, path = accum }
			end
			parent = accum
		end
		local node = get_dir(dir)
		node.children[#node.children + 1] = {
			kind = "file",
			name = name,
			path = f.path,
			abs_path = f.abs_path,
			x = f.x,
			y = f.y,
			status = f.x,
		}
	end

	-- flatten to a draw list, recursing into open dirs
	git.tree = {}
	local function add_level(dirpath, depth)
		local node = dirs[dirpath]
		table.sort(node.children, function(a, b)
			if a.kind ~= b.kind then
				return a.kind == "dir"
			end
			return a.name < b.name
		end)
		for _, c in ipairs(node.children) do
			if c.kind == "file" then
				c.depth = depth
				git.tree[#git.tree + 1] = c
			else
				-- compute this dir's worst status from descendants
				local status = " "
				local function scan(d)
					for _, ch in ipairs(dirs[d].children) do
						if ch.kind == "file" then
							status = worse(status, ch.x)
						else
							scan(ch.path)
						end
					end
				end
				scan(c.path)
				git.tree[#git.tree + 1] = {
					kind = "dir",
					name = c.name,
					path = c.path,
					open = dirs[c.path].open,
					status = status,
					depth = depth,
				}
				if dirs[c.path].open then
					add_level(c.path, depth + 1)
				end
			end
		end
	end
	add_level("", 0)
end

local function git_exec(args)
	-- Always run with cwd = project dir and discard stdin so git never
	-- blocks waiting for credentials on a tty.
	local proc = process.start(args, {
		cwd = core.project_dir or ".",
		stdin = process.REDIRECT_DISCARD,
	})
	while proc:running() do
		coroutine.yield(0.05)
	end
	local out = proc:read_stdout() or ""
	local code = proc:returncode()
	return out, code
end

local function refresh_state()
	if not system.get_file_info(".git") then
		git.available = false
		git.branch = nil
		git.files = {}
		git.ahead = 0
		git.behind = 0
		return
	end
	git.available = true

	git.branch = git_exec({ "git", "rev-parse", "--abbrev-ref", "HEAD" }):match("[^\n]*")

	-- ahead / behind relative to upstream
	local ab = git_exec({ "git", "rev-list", "--left-right", "--count", "@{upstream}...HEAD" }):match("(%d+)%s+(%d+)")
	if ab then
		local behind, ahead = ab:match("(%d+)%s+(%d+)")
		git.behind = tonumber(behind) or 0
		git.ahead = tonumber(ahead) or 0
	else
		git.ahead = 0
		git.behind = 0
	end

	-- file statuses
	local out = git_exec({ "git", "status", "--porcelain=v1", "-uall" })
	git.files = {}
	for line in out:gmatch("[^\n]+") do
		local x, y, path = line:match("^(.)(.)%s+(.+)$")
		if path then
			-- normalize renamed "a -> b"
			path = path:match("^(.+)%s+->%s+(.+)$") or path
			git.files[#git.files + 1] = {
				path = path,
				abs_path = core.project_dir .. PATHSEP .. path,
				x = x, -- index status
				y = y, -- worktree status
			}
		end
	end
	build_tree()
end

--------------------------------------------------------------------------------
-- Background scanner
--------------------------------------------------------------------------------

core.add_thread(function()
	while true do
		local ok, err = pcall(refresh_state)
		if not ok then
			git.available = false
		end
		core.redraw = true
		coroutine.yield(config.plugins.git.scan_rate)
	end
end)

--------------------------------------------------------------------------------
-- Git panel (View)
--------------------------------------------------------------------------------

local GitView = View:extend()

function GitView:new()
	GitView.super.new(self)
	self.scrollable = true
	self.selected = 1
	self.target_size = 300 * SCALE
	self.cursor = "arrow" -- mouse cursor (do NOT reuse for index!)
end

function GitView:set_target_size(axis, value)
	if axis == "y" or axis == "x" then
		self.target_size = value
		return true
	end
end

function GitView:get_name()
	return "Git"
end

function GitView:get_line_height()
	return style.font:get_height() + style.padding.y
end

function GitView:get_line_count()
	return math.max(1, #git.tree)
end

function GitView:get_scrollable_size()
	return self:get_line_count() * self:get_line_height() + style.padding.y * 2
end

-- Keep the currently selected row visible while navigating with arrows.
function GitView:scroll_to_selected()
	local lh = self:get_line_height()
	local y = (self.selected - 1) * lh
	if y < self.scroll.y then
		self.scroll.to.y = y
	elseif y + lh > self.scroll.y + self.size.y then
		self.scroll.to.y = y + lh - self.size.y
	end
	self.scroll.to.y = common.clamp(self.scroll.to.y, 0, math.max(0, self:get_scrollable_size() - self.size.y))
end

function GitView:status_color(x)
	if x == "A" or x == "M" or x == "D" or x == "R" or x == "C" then
		return git_color("staged", config.plugins.git.color_staged, style.text)
	elseif x == "?" then
		return git_color("untracked", config.plugins.git.color_untracked, style.dim)
	end
	return git_color("modified", config.plugins.git.color_modified, style.accent)
end

function GitView:status_label(x)
	if x == "?" then
		return "?"
	end
	if x == "A" then
		return "A"
	end
	if x == "M" then
		return "M"
	end
	if x == "D" then
		return "D"
	end
	if x == "R" then
		return "R"
	end
	return x
end

-- Toggle dir open/closed by path. State is kept in git.dir_open so it
-- survives rebuilds of the tree.
local function toggle_dir(path)
	git.dir_open = git.dir_open or {}
	git.dir_open[path] = not (git.dir_open[path] or false)
	build_tree()
end

-- Right-click context menu: commit / stage a file or a whole directory.
local function git_context_menu(row)
	local file_paths = {}
	local label
	if row.kind == "dir" then
		-- collect every tracked path under this directory
		for _, f in ipairs(git.files) do
			if f.path:match("^" .. row.path:gsub("[%.%/]", "%%%0") .. "/") then
				file_paths[#file_paths + 1] = f.path
			end
		end
		label = "Directory " .. row.name
	else
		file_paths[#file_paths + 1] = row.path
		label = row.name
	end

	local function commit_files(paths)
		stage_and_commit(paths, default_msg_for(paths[1]), true)
	end

	local function stage_files(paths, unstage)
		for _, p in ipairs(paths) do
			if unstage then
				git_exec({ "git", "restore", "--staged", "--", p })
			else
				git_exec({ "git", "add", "--", p })
			end
		end
		refresh_state()
	end

	local items = {}
	items[#items + 1] = {
		text = "Commit " .. label,
		command = function()
			commit_files(file_paths)
		end,
	}
	items[#items + 1] = {
		text = "Commit & Push " .. label,
		command = function()
			core.command_view:enter("Commit + push message", {
				submit = function(msg)
					if not msg or msg == "" then
						return
					end
					core.add_thread(function()
						for _, p in ipairs(file_paths) do
							git_exec({ "git", "add", "--", p })
						end
						local args = { "git", "commit", "-m", msg, "--" }
						for _, p in ipairs(file_paths) do
							args[#args + 1] = p
						end
						local _, code = git_exec(args)
						if code == 0 then
							git_exec({ "git", "push" })
							core.log("git: committed + pushed")
						else
							core.error("git: commit failed, not pushing")
						end
						refresh_state()
						if git.clear_diff_cache then
							git.clear_diff_cache()
						end
						core.redraw = true
					end)
				end,
				text = default_msg_for(file_paths[1]),
				select_text = true,
			})
		end,
	}
	if row.kind == "dir" then
		items[#items + 1] = {
			text = "Stage directory",
			command = function()
				stage_files(file_paths, false)
			end,
		}
	else
		local staged = row.x ~= "?"
		items[#items + 1] = {
			text = staged and "Unstage file" or "Stage file",
			command = function()
				stage_files(file_paths, staged)
			end,
		}
		items[#items + 1] = {
			text = "Open file",
			command = function()
				core.try(function()
					core.root_view:open_doc(core.open_doc(row.abs_path))
				end)
			end,
		}
		items[#items + 1] = {
			text = "Discard changes",
			command = function()
				core.command_view:enter("Discard " .. row.name .. "? type 'yes'", {
					submit = function(ans)
						if ans ~= "yes" then
							return
						end
						core.add_thread(function()
							git_exec({ "git", "checkout", "--", row.path })
							refresh_state()
							if git.clear_diff_cache then
								git.clear_diff_cache()
							end
							core.redraw = true
						end)
					end,
				})
			end,
		}
	end

	-- Use the command view's suggestion list as a quick menu.
	core.command_view:enter("Git: " .. label, {
		submit = function(text)
			for _, it in ipairs(items) do
				if it.text == text then
					it.command()
					return
				end
			end
		end,
		suggest = function()
			return items
		end,
	})
end

-- Find the row currently under the cursor y position.
function GitView:row_at(y)
	local lh = self:get_line_height()
	local _, cy = self:get_content_offset()
	local idx = math.floor((y - cy) / lh) + 1
	return git.tree[idx]
end

function GitView:on_mouse_pressed(button, x, y, clicks, ...)
	if GitView.super.on_mouse_pressed(self, button, x, y, clicks, ...) then
		return true
	end
	if #git.tree == 0 then
		return true
	end
	local row = self:row_at(y)
	if not row then
		return true
	end
	self.selected = row.idx or self.selected

	if button == "right" then
		git_context_menu(row)
		return true
	end

	if row.kind == "dir" then
		toggle_dir(row.path)
	else
		core.try(function()
			core.root_view:open_doc(core.open_doc(row.abs_path))
		end)
	end
	return true
end

function GitView:on_key_pressed(key, ...)
	if key == "tab" then
		-- move focus back to the editor without closing the panel
		for _, doc in ipairs(core.docs) do
			if doc:is(core.doc) then
				local views = core.get_views_referencing_doc(doc)
				if #views > 0 then
					core.set_active_view(views[1])
				end
				break
			end
		end
		return true
	end
	if #git.tree > 0 then
		if key == "down" then
			self.selected = math.min(#git.tree, self.selected + 1)
			self:scroll_to_selected()
			return true
		elseif key == "up" then
			self.selected = math.max(1, self.selected - 1)
			self:scroll_to_selected()
			return true
		elseif key == "return" then
			local row = git.tree[self.selected]
			if row and row.kind == "file" then
				core.try(function()
					core.root_view:open_doc(core.open_doc(row.abs_path))
				end)
			elseif row and row.kind == "dir" then
				toggle_dir(row.path)
			end
			return true
		elseif key == "space" then
			local row = git.tree[self.selected]
			if row and row.kind == "dir" then
				toggle_dir(row.path)
			end
			return true
		elseif key == "s" then
			local row = git.tree[self.selected]
			if row and row.kind == "file" then
				if row.x == "?" then
					git_exec({ "git", "add", "--", row.path })
				else
					git_exec({ "git", "restore", "--staged", "--", row.path })
				end
				refresh_state()
			end
			return true
		elseif key == "c" then
			local row = git.tree[self.selected]
			if row and row.kind == "file" then
				stage_and_commit({ row.path }, default_msg_for(row.path), true)
			elseif row and row.kind == "dir" then
				local paths = {}
				for _, f in ipairs(git.files) do
					if f.path:match("^" .. row.path:gsub("[%.%/]", "%%%0") .. "/") then
						paths[#paths + 1] = f.path
					end
				end
				if #paths > 0 then
					stage_and_commit(paths, default_msg_for(row.name), true)
				end
			end
			return true
		elseif key == "a" then
			core.add_thread(function()
				git_exec({ "git", "add", "-A" })
				refresh_state()
				core.redraw = true
			end)
			return true
		end
	end
	if key == "escape" then
		close_panel()
		return true
	end
	return GitView.super.on_key_pressed(self, key, ...)
end

function GitView:update(...)
	-- animate the panel size toward its target (width for right split)
	self:move_towards(self.size, "x", self.target_size)
	GitView.super.update(self, ...)
end

function GitView:draw()
	self:draw_background(style.background)
	if not git.available then
		local cx, cy = self:get_content_offset()
		common.draw_text(
			style.font,
			style.dim,
			"not a git repository",
			"left",
			cx,
			cy,
			self.size.x,
			self:get_line_height()
		)
		self:draw_scrollbar(self)
		return
	end

	local x, y = self:get_content_offset()
	local lh = self:get_line_height()
	for i, row in ipairs(git.tree) do
		row.idx = i
		-- defensive: color must be a table, else fall back
		local ok, color = pcall(self.status_color, self, row.status or row.x)
		if not ok or type(color) ~= "table" then
			color = style.text
		end
		if i == self.selected then
			renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight or style.line)
		end
		local marker = (row.kind == "dir") and (row.open and "▾ " or "▸ ")
			or ((self.status_label(self, row.status or row.x)) .. " ")
		local indent = (row.depth or 0) * (style.padding.x * 2)
		common.draw_text(style.font, color, marker, "left", x + style.padding.x + indent, y, self.size.x, lh)
		common.draw_text(style.font, style.text, row.name, "left", x + style.padding.x * 3 + indent, y, self.size.x, lh)
		y = y + lh
	end

	if #git.tree == 0 then
		common.draw_text(style.font, style.dim, "working tree clean", "left", x + style.padding.x, y, self.size.x, lh)
	end
	self:draw_scrollbar(self)
end

--------------------------------------------------------------------------------
-- Panel toggle
--------------------------------------------------------------------------------

local panel_view = nil

-- Safely close the git panel without touching the command view context.
local function close_panel()
	if not panel_view then
		return
	end
	-- Make sure a real document view is active before removing the panel,
	-- otherwise command_view may try to restore a nil active view and crash.
	if core.active_view == panel_view or core.active_view == core.command_view then
		for _, doc in ipairs(core.docs) do
			if doc:is(core.doc) then
				local views = core.get_views_referencing_doc(doc)
				if #views > 0 then
					core.set_active_view(views[1])
				end
				break
			end
		end
	end
	local node = core.root_view.root_node:get_node_for_view(panel_view)
	if node then
		node:remove_view(core.root_view.root_node, panel_view)
	end
	panel_view = nil
end

--------------------------------------------------------------------------------
-- Commit helpers (shared)
--------------------------------------------------------------------------------

-- Run `git commit` in the background and refresh everything.
local function run_commit(msg, extra_args)
	core.add_thread(function()
		local args = { "git", "commit", "-m", msg }
		if extra_args then
			for _, a in ipairs(extra_args) do
				args[#args + 1] = a
			end
		end
		local out, code = git_exec(args)
		refresh_state()
		if git.clear_diff_cache then
			git.clear_diff_cache()
		end
		core.redraw = true
		if code == 0 then
			core.log('git: committed "' .. msg .. '"')
		else
			core.error("git: commit failed:\n" .. (out or ""))
		end
	end)
end

-- Stage the given paths, then commit them. If prompt is true, ask for the
-- message (prefilled with default_msg); otherwise commit instantly.
local function stage_and_commit(paths, default_msg, prompt)
	local function go(msg)
		if not msg or msg == "" then
			return
		end
		core.add_thread(function()
			for _, p in ipairs(paths) do
				git_exec({ "git", "add", "--", p })
			end
			-- commit only the given pathspecs so unrelated staged files stay staged
			local args = { "git", "commit", "-m", msg, "--" }
			for _, p in ipairs(paths) do
				args[#args + 1] = p
			end
			local out, code = git_exec(args)
			refresh_state()
			if git.clear_diff_cache then
				git.clear_diff_cache()
			end
			core.redraw = true
			if code == 0 then
				core.log("git: committed " .. #paths .. " file(s)")
			else
				core.error("git: commit failed:\n" .. (out or ""))
			end
		end)
	end
	if prompt then
		core.command_view:enter("Commit message", {
			submit = go,
			text = default_msg or "",
			select_text = true,
		})
	else
		go(default_msg)
	end
end

-- The file path of the currently active document, relative to project dir.
local function current_file()
	local dv = core.active_view
	if dv and dv:is(DocView) and dv.doc and dv.doc.filename then
		local abs = dv.doc.abs_filename or dv.doc.filename
		local rel = abs
		if core.project_dir and abs:sub(1, #core.project_dir) == core.project_dir then
			rel = abs:sub(#core.project_dir + 2)
		end
		return rel, abs
	end
	-- fall back to the selected row in the panel
	if panel_view and git.tree[panel_view.selected] and git.tree[panel_view.selected].kind == "file" then
		return git.tree[panel_view.selected].path
	end
end

-- A sensible default commit message for a file.
local function default_msg_for(rel)
	local base = rel and rel:match("([^/]+)$") or "changes"
	return "Update " .. base
end

command.add(nil, {
	["git:toggle"] = function()
		if panel_view then
			close_panel()
		else
			-- open as a right-hand split (full height), like a sidebar
			panel_view = GitView()
			local node = core.root_view:get_primary_node()
			node:split("right", panel_view, { x = true }, true)
			core.set_active_view(panel_view)
		end
	end,

	-- Open the panel (if needed) and move keyboard focus to it so the arrow
	-- keys navigate the file list without touching the mouse.
	["git:focus-panel"] = function()
		if not panel_view then
			panel_view = GitView()
			local node = core.root_view:get_primary_node()
			node:split("right", panel_view, { x = true }, true)
		end
		-- Toggle focus: pressing again returns you to the editor.
		if core.active_view == panel_view then
			local views = core.get_views_referencing_doc(core.active_doc)
			if #views > 0 then core.set_active_view(views[1]) end
			return
		end
		core.set_active_view(panel_view)
	end,
})

-- Panel navigation. Registered with a predicate that is true ONLY when the git
-- panel currently has keyboard focus. command.perform checks this predicate
-- BEFORE running the function, so when the panel is not focused these commands
-- are skipped entirely and the keystroke falls through to the editor untouched:
-- Enter still inserts a newline, space still types a space, tab still indents,
-- escape still works normally. This is the proper way to scope keys to a view,
-- instead of binding globally and relying on a guard returning false.
command.add(function() return core.active_view ~= nil and core.active_view == panel_view end, {
	["git:panel-up"] = function()
		if #git.tree == 0 then return end
		panel_view.selected = math.max(1, panel_view.selected - 1)
		panel_view:scroll_to_selected()
	end,
	["git:panel-down"] = function()
		if #git.tree == 0 then return end
		panel_view.selected = math.min(#git.tree, panel_view.selected + 1)
		panel_view:scroll_to_selected()
	end,
	["git:panel-enter"] = function()
		local row = git.tree[panel_view.selected]
		if row and row.kind == "file" then
			core.try(function()
				core.root_view:open_doc(core.open_doc(row.abs_path))
			end)
		elseif row and row.kind == "dir" then
			toggle_dir(row.path)
		end
	end,
	["git:panel-space"] = function()
		local row = git.tree[panel_view.selected]
		if row and row.kind == "dir" then
			toggle_dir(row.path)
		end
	end,
	["git:panel-tab"] = function()
		for _, doc in ipairs(core.docs) do
			if doc:is(core.doc) then
				local views = core.get_views_referencing_doc(doc)
				if #views > 0 then
					core.set_active_view(views[1])
				end
				break
			end
		end
	end,
	["git:panel-escape"] = function()
		close_panel()
	end,
})

command.add(nil, {
	-- Commit whatever is already staged (asks for a message).
	["git:commit"] = function()
		core.command_view:enter("Commit message", {
			submit = function(msg)
				if msg and msg ~= "" then
					run_commit(msg)
				end
			end,
			text = "",
		})
	end,

	-- Commit the current file: stage it + ask for a message (prefilled).
	["git:commit-current"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file to commit")
			return
		end
		stage_and_commit({ rel }, default_msg_for(rel), true)
	end,

	-- Commit the current file instantly with an auto message (no typing).
	["git:commit-current-quick"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file to commit")
			return
		end
		stage_and_commit({ rel }, default_msg_for(rel), false)
	end,

	-- Stage everything and commit (asks for a message).
	["git:commit-all"] = function()
		core.add_thread(function()
			git_exec({ "git", "add", "-A" })
			refresh_state()
			core.redraw = true
			core.command_view:enter("Commit ALL changes", {
				submit = function(msg)
					if msg and msg ~= "" then
						run_commit(msg)
					end
				end,
				text = "",
			})
		end)
	end,

	-- Amend the last commit (keep its message) with current staged changes.
	["git:commit-amend"] = function()
		core.add_thread(function()
			git_exec({ "git", "add", "-A" })
			local out, code = git_exec({ "git", "commit", "--amend", "--no-edit" })
			refresh_state()
			if git.clear_diff_cache then
				git.clear_diff_cache()
			end
			core.redraw = true
			if code == 0 then
				core.log("git: amended last commit")
			else
				core.error("git: amend failed:\n" .. (out or ""))
			end
		end)
	end,

	-- Stage / unstage the current file.
	["git:stage-current"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file")
			return
		end
		core.add_thread(function()
			git_exec({ "git", "add", "--", rel })
			refresh_state()
			core.redraw = true
			core.log("git: staged " .. rel)
		end)
	end,

	["git:unstage-current"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file")
			return
		end
		core.add_thread(function()
			git_exec({ "git", "restore", "--staged", "--", rel })
			refresh_state()
			core.redraw = true
			core.log("git: unstaged " .. rel)
		end)
	end,

	-- Stage everything (no commit).
	["git:stage-all"] = function()
		core.add_thread(function()
			git_exec({ "git", "add", "-A" })
			refresh_state()
			core.redraw = true
			core.log("git: staged all changes")
		end)
	end,

	-- Discard uncommitted changes in the current file (with confirmation).
	["git:discard-current"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file")
			return
		end
		core.command_view:enter("Discard changes in " .. rel .. "? type 'yes'", {
			submit = function(ans)
				if ans ~= "yes" then
					core.log("git: discard cancelled")
					return
				end
				core.add_thread(function()
					git_exec({ "git", "checkout", "--", rel })
					refresh_state()
					if git.clear_diff_cache then
						git.clear_diff_cache()
					end
					core.redraw = true
					core.log("git: discarded changes in " .. rel)
				end)
			end,
		})
	end,

	-- Commit the current file, then push, in one action.
	["git:commit-current-and-push"] = function()
		local rel = current_file()
		if not rel then
			core.error("git: no file to commit")
			return
		end
		core.command_view:enter("Commit + push message", {
			submit = function(msg)
				if not msg or msg == "" then
					return
				end
				core.add_thread(function()
					git_exec({ "git", "add", "--", rel })
					local args = { "git", "commit", "-m", msg, "--", rel }
					local _, code = git_exec(args)
					if code == 0 then
						git_exec({ "git", "push" })
						core.log("git: committed + pushed")
					else
						core.error("git: commit failed, not pushing")
					end
					refresh_state()
					if git.clear_diff_cache then
						git.clear_diff_cache()
					end
					core.redraw = true
				end)
			end,
			text = default_msg_for(rel),
			select_text = true,
		})
	end,

	["git:push"] = function()
		core.add_thread(function()
			git_exec({ "git", "push" })
			refresh_state()
			core.log("git: push done")
		end)
	end,

	["git:pull"] = function()
		core.add_thread(function()
			local out = git_exec({ "git", "pull" })
			refresh_state()
			core.log("git: pull done" .. (out and out ~= "" and ("\n" .. out) or ""))
		end)
	end,

	["git:branch"] = function()
		core.command_view:enter("Switch/create branch", {
			submit = function(name)
				if not name or name == "" then
					return
				end
				-- if exists -> switch, else create+switch
				core.add_thread(function()
					local _, code = git_exec({ "git", "rev-parse", "--verify", "refs/heads/" .. name })
					if code == 0 then
						git_exec({ "git", "checkout", name })
					else
						git_exec({ "git", "checkout", "-b", name })
					end
					refresh_state()
				end)
			end,
			text = git.branch or "",
		})
	end,

	["git:remote"] = function()
		core.add_thread(function()
			local items = {}
			local out = (git_exec({ "git", "remote" })):gmatch("[^\n]+")
			for r in out do
				items[#items + 1] = r
			end
			core.command_view:enter("Remote (add <name> <url> | rename <old> <new> | remove <name>)", {
				submit = function(arg)
					core.add_thread(function()
						local cmd, a, b = arg:match("^(%S+)%s+(%S+)%s*(%S*)")
						if cmd == "add" and a and b then
							git_exec({ "git", "remote", "add", a, b })
						elseif cmd == "rename" and a and b then
							git_exec({ "git", "remote", "rename", a, b })
						elseif cmd == "remove" and a then
							git_exec({ "git", "remote", "remove", a })
						else
							core.error("git: remote usage: add <name> <url> | rename <old> <new> | remove <name>")
						end
						refresh_state()
					end)
				end,
				text = table.concat(items, " "),
			})
		end)
	end,
})

--------------------------------------------------------------------------------
-- Status bar item
--------------------------------------------------------------------------------

-- Conflict guard: another plugin (e.g. the standalone "gitstatus" plugin)
-- registers a status item named "status:git", which collides with ours and
-- makes Lite XL assert + crash on startup. Detect it early and fail loudly
-- with actionable instructions instead of a cryptic stack trace.
do
	local conflicts = {}
	-- gitstatus registers its status item under this exact name.
	if package.loaded["plugins.gitstatus"] then
		conflicts[#conflicts + 1] = "gitstatus"
	end
	-- Also catch it by inspecting already-registered status items (name-based),
	-- in case it was required under a different module path.
	for _, item in ipairs(core.status_view.items or {}) do
		if item.name == "status:git" then
			conflicts[#conflicts + 1] = "status:git (already registered)"
			break
		end
	end
	if #conflicts > 0 then
		-- Best-effort: prevent the conflicting plugin from loading at all by
		-- marking it disabled in the config. load_plugins() skips plugins whose
		-- config.plugins[name] == false, so this stops gitstatus.lua before it
		-- can re-register the colliding "status:git" item and crash startup.
		config.plugins.gitstatus = false
		core.log(
			"[git] Conflicting plugin detected (" .. table.concat(conflicts, ", ") ..
			"). The standalone 'gitstatus' plugin registers a status-bar item " ..
			"named 'status:git', which this plugin also owns, and makes Lite XL " ..
			"crash on startup. It has been auto-disabled. Remove it to silence " ..
			"this notice: rm ~/.config/lite-xl/plugins/gitstatus.lua"
		)
	end
end

core.status_view:add_item({
	name = "status:git",
	alignment = StatusView.Item.RIGHT,
	get_item = function()
		if not git.available or not git.branch then
			return {}
		end
		return {
			style.accent,
			git.branch,
			style.dim,
			"  ",
			git.ahead > 0 and git_color("staged", config.plugins.git.color_staged, style.accent) or style.dim,
			"↑" .. git.ahead,
			style.dim,
			" ",
			git.behind > 0 and git_color("modified", config.plugins.git.color_modified, style.accent) or style.dim,
			"↓" .. git.behind,
		}
	end,
	position = -1,
	tooltip = "git branch / ahead-behind",
	separator = core.status_view.separator2,
})

--------------------------------------------------------------------------------
-- Gutter diff markers (per-line)
--------------------------------------------------------------------------------

if config.plugins.git.gutter_diff then
	local cache = {} -- doc -> { [line] = "added"|"modified" }

	-- Parse a `git diff -U0 HEAD` output into per-line markers. Compared
	-- against the last commit (HEAD), NOT the working tree, so markers stay
	-- visible after a save and only disappear once the file is committed.
	-- Runs only inside a coroutine (background thread).
	local function compute_diff(doc)
		local file = doc.filename
		if not file or not system.get_file_info(file) then
			return {}
		end
		local out = git_exec({ "git", "diff", "--no-color", "-U0", "HEAD", "--", file })
		local marks = {}
		for hunk in out:gmatch("@@[^\n]*\n[^\n]*") do
			-- header: "@@ -a,b +c,d @@"  (c = first new-file line number)
			local start = hunk:match("@@ %-%d+,?%d* %+(%d+)")
			start = tonumber(start)
			if start then
				local body = hunk:match("\n(.+)$")
				if body then
					if body:sub(1, 1) == "+" then
						-- pure addition (no '-' line in the hunk)
						marks[start] = "added"
					else
						-- line was removed on the left -> it is a modification
						marks[start] = "modified"
					end
				end
			end
		end
		-- Untracked files: git diff HEAD shows nothing, so diff them against
		-- /dev/null via intent-to-add so new files also get a green marker.
		if not next(marks) then
			local untracked = git_exec({ "git", "diff", "--no-color", "-U0", "--no-index", "/dev/null", file })
			for hunk in untracked:gmatch("@@[^\n]*\n[^\n]*") do
				local start = hunk:match("@@ %-%d+,?%d* %+(%d+)")
				start = tonumber(start)
				if start and hunk:match("\n%+(.+)") then
					marks[start] = "added"
				end
			end
		end
		return marks
	end

	-- Clear the diff cache (e.g. after a commit) so markers disappear.
	function git.clear_diff_cache()
		cache = {}
	end

	-- Compute (lazily, once) the diff for a doc and store it. Never runs on
	-- save, so markers persist across edits until the file is committed.
	local pending = {}
	local function ensure_diff(doc)
		if cache[doc] ~= nil then
			return
		end -- already computed (or empty)
		if pending[doc] then
			return
		end -- already scheduled
		pending[doc] = true
		core.add_thread(function()
			local ok, marks = pcall(compute_diff, doc)
			pending[doc] = nil
			if ok then
				cache[doc] = marks
			end
			core.redraw = true
		end)
	end

	local draw_overlay = DocView.draw_overlay
	function DocView:draw_overlay(...)
		local res = draw_overlay(self, ...)
		if not config.plugins.git.gutter_diff then
			return res
		end
		local doc = self.doc
		if not doc or not doc.filename then
			return res
		end
		if not git.available then
			return res
		end

		if cache[doc] == nil then
			ensure_diff(doc) -- schedule compute; markers show up next frames
			return res
		end
		local marks = cache[doc]

		local lh = self:get_line_height()
		local gw = self:get_gutter_width()
		for line = 1, #doc.lines do
			if marks[line] then
				local _, oy = self:get_line_screen_position(line)
				local color = marks[line] == "added"
						and git_color("g_added", config.plugins.git.color_gutter_added, style.accent)
					or git_color("g_modified", config.plugins.git.color_gutter_modified, style.accent)
				if type(color) == "table" then
					renderer.draw_rect(self.position.x, oy, math.max(2, gw * 0.15), lh, color)
				end
			end
		end
		return res
	end

	-- NOTE: we do NOT reset the cache on save/text change. A file differs from
	-- HEAD until it is committed, so markers must remain until then.
end

--------------------------------------------------------------------------------
-- Keybindings
--------------------------------------------------------------------------------

keymap.add({
	[config.plugins.git.activate] = "git:toggle",
	["ctrl+alt+shift+j"] = "git:focus-panel",

	-- Fast commit bindings (minimal movement — no touchpad needed):
	--   ctrl+enter        -> commit current file, message prefilled, just Enter
	--   ctrl+shift+enter  -> instant commit current file (auto message, no typing)
	--   ctrl+alt+enter    -> commit current file + push
	["ctrl+return"] = "git:commit-current",
	["ctrl+shift+return"] = "git:commit-current-quick",
	["ctrl+alt+return"] = "git:commit-current-and-push",

	-- Staging shortcuts
	["ctrl+altgr+shift+s"] = "git:stage-current",
	["ctrl+alt+shift+u"] = "git:unstage-current",
	["ctrl+alt+shift+a"] = "git:stage-all",

	-- Bigger commits / history
	["ctrl+alt+shift+c"] = "git:commit-all",
	["ctrl+alt+shift+m"] = "git:commit-amend",
	["ctrl+alt+shift+d"] = "git:discard-current",

	-- Repo actions
	["ctrl+alt+shift+p"] = "git:push",
	["ctrl+alt+shift+l"] = "git:pull",
	["ctrl+alt+shift+b"] = "git:branch",
	["ctrl+alt+shift+r"] = "git:remote",

	-- Panel navigation (only act when the git panel has focus; otherwise the
	-- keystroke falls through to the editor / command view).
	["up"] = "git:panel-up",
	["down"] = "git:panel-down",
	["return"] = "git:panel-enter",
	["space"] = "git:panel-space",
	["tab"] = "git:panel-tab",
	["escape"] = "git:panel-escape",
})

--------------------------------------------------------------------------------
-- TreeView integration: color files by git status + right-click menu
--------------------------------------------------------------------------------

do
	local ok, TreeView = pcall(require, "plugins.treeview")
	if not ok or not TreeView then
		goto skip_treeview
	end

	-- Fallback colors in case style.git_* failed to resolve to a table.
	local C_MODIFIED = type(style.git_modified) == "table" and style.git_modified or style.accent
	local C_UNTRACKED = type(style.git_untracked) == "table" and style.git_untracked or style.dim
	local C_STAGED = type(style.git_staged) == "table" and style.git_staged or style.text

	-- Look up the git status record for an absolute path.
	local function status_for_abs(abs)
		for _, f in ipairs(git.files) do
			if f.abs_path == abs then
				return f
			end
		end
	end

	-- "Worst" status among all tracked files under an absolute directory.
	local function status_for_dir(abs_dir)
		local worst, rank = " ", { A = 3, M = 3, D = 3, R = 3, C = 3, ["?"] = 1, [" "] = 0 }
		local prefix = abs_dir .. PATHSEP
		for _, f in ipairs(git.files) do
			if f.abs_path == prefix or f.abs_path:sub(1, #prefix) == prefix then
				if (rank[f.x] or 0) > (rank[worst] or 0) then
					worst = f.x
				end
			end
		end
		return worst
	end

	-- Color a treeview item according to its git status.
	local get_item_text = TreeView.get_item_text
	function TreeView:get_item_text(item, active, hovered)
		local text, font, color = get_item_text(self, item, active, hovered)
		-- Always return a valid (table) color; anything else crashes draw_text.
		if type(color) ~= "table" then
			color = style.text
		end
		local ok, st = pcall(function()
			if not git.available or not item or not item.abs_filename then
				return nil
			end
			if active or hovered then
				return nil
			end
			return item.type == "dir" and status_for_dir(item.abs_filename)
				or (status_for_abs(item.abs_filename) or {}).x
		end)
		if ok and st and st ~= " " and st ~= "" then
			local c = st == "?" and git_color("untracked", config.plugins.git.color_untracked, style.dim)
				or (st == "A" or st == "M" or st == "D" or st == "R" or st == "C") and git_color(
					"staged",
					config.plugins.git.color_staged,
					style.text
				)
				or git_color("modified", config.plugins.git.color_modified, style.accent)
			if type(c) == "table" then
				color = c
			end
		end
		return text, font, color
	end

	-- Right-click menu on a treeview item: commit / stage file or directory.
	local on_mouse_pressed = TreeView.on_mouse_pressed
	function TreeView:on_mouse_pressed(button, x, y, clicks, ...)
		if button == "right" then
			local hit
			for item, ix, iy, iw, ih in self:each_item() do
				if x > ix and y > iy and x <= ix + iw and y <= iy + ih then
					hit = item
					break
				end
			end
			if hit and hit.abs_filename then
				if hit.type == "dir" then
					local rel = hit.abs_filename:sub(#core.project_dir + 2)
					git_context_menu({
						kind = "dir",
						name = common.basename(hit.abs_filename),
						path = rel,
						status = status_for_dir(hit.abs_filename),
					})
				else
					local f = status_for_abs(hit.abs_filename)
					if f then
						git_context_menu({
							kind = "file",
							name = f.path:match("([^/]+)$"),
							path = f.path,
							abs_path = f.abs_path,
							x = f.x,
							y = f.y,
						})
					end
				end
				return true
			end
		end
		if on_mouse_pressed then
			return on_mouse_pressed(self, button, x, y, clicks, ...)
		end
		return TreeView.super.on_mouse_pressed(self, button, x, y, clicks, ...)
	end
end

::skip_treeview::

return git

# git

A lightweight git client for Lite XL. Track changes, stage/unstage, commit,
pull, push, and manage branches and remotes — all from inside the editor.
Built for minimum mouse/touchpad movement: most actions are one keystroke.

## Features

- **Git panel** (toggle with `ctrl+alt+shift+g`) opening as a right-hand
  sidebar listing every changed, untracked and staged file, grouped under
  collapsible directories:
  - **Modified** files are shown in **orange**.
  - **Untracked** files (not yet `git add`-ed) are marked with **`?`** in
    **yellow**.
  - **Staged** files turn **green**. After a commit the colors disappear.
  - Click or press `return` to open a file; press `space` (or click) on a
    directory to expand/collapse it; `s` to stage/unstage; `c` to commit the
    selected file/directory; `a` to stage everything.
  - Press `ctrl+alt+shift+j` to send keyboard focus to the panel; press it
    **again** to send focus back to the editor. While the panel is focused,
    use `up`/`down` to move the selection (the view auto-scrolls), `tab` to
    return focus to the editor, and `escape` to close the panel.
  - **Right-click** any file or directory for a context menu:
    - Commit a single file / whole directory
    - Commit & Push
    - Stage / Unstage
    - Discard changes
    - Open file
- **Gutter diff markers**: added lines get a **green** marker on the left,
  modified lines a **yellow** one. The markers are computed from `git diff HEAD`
  and **stay visible after saving** — they only disappear once the file is
  committed.
- **File tree integration**: the built-in file tree (TreeView) on the left is
  colored by git status too, and right-clicking an item there opens the same
  commit / stage / discard context menu.
- **One-keystroke commits** (see Keybindings below):
  - `ctrl+return` — commit the **current file**, message prefilled (just press
    Enter to confirm).
  - `ctrl+shift+return` — **instant** commit of the current file with an auto
    message, no typing at all.
  - `ctrl+alt+return` — commit the current file **and push**.
  - `ctrl+alt+shift+c` — stage everything and commit.
  - `ctrl+alt+shift+m` — amend the last commit (keeps its message).
  - `ctrl+alt+shift+d` — discard uncommitted changes in the current file.
- **GUI actions** (also bound to keys):
  - `git:pull` (`ctrl+alt+shift+l`) — pull the current branch.
  - `git:push` (`ctrl+alt+shift+p`) — push the current branch.
  - `git:branch` (`ctrl+alt+shift+b`) — switch to an existing branch or create
    a new one.
  - `git:remote` (`ctrl+alt+shift+r`) — `add <name> <url>`,
    `rename <old> <new>`, `remove <name>`.
- **Status bar** item showing the current branch and ahead/behind (`↑`/`↓`)
  counts.

## Keyboard focus & isolation

The panel-navigation keys (`up`, `down`, `return`, `space`, `tab`, `escape`)
are registered with a **command predicate** that is only true when the git
panel has keyboard focus. Lite XL checks this predicate *before* running the
command, so when the panel is **not** focused these keys fall through to the
editor untouched — `return` still inserts a newline, `space` still types a
space, `tab` still indents, etc. This is the correct, view-scoped way to bind
keys rather than binding them globally and hoping a guard returns early.

## Keybindings

| Key                   | Action                                    |
|-----------------------|-------------------------------------------|
| `ctrl+alt+shift+g`    | Toggle git panel                          |
| `ctrl+alt+shift+j`    | Focus git panel (press again to unfocus)  |
| `ctrl+return`         | Commit current file (message prefilled)   |
| `ctrl+shift+return`   | Instant commit current file (auto msg)    |
| `ctrl+alt+return`     | Commit current file + push                |
| `ctrl+altgr+shift+s`  | Stage current file                        |
| `ctrl+alt+shift+u`    | Unstage current file                      |
| `ctrl+alt+shift+a`    | Stage all changes                         |
| `ctrl+alt+shift+c`    | Stage all + commit                        |
| `ctrl+alt+shift+m`    | Amend last commit                         |
| `ctrl+alt+shift+d`    | Discard changes in current file           |
| `ctrl+alt+shift+l`    | Pull                                      |
| `ctrl+alt+shift+p`    | Push                                      |
| `ctrl+alt+shift+b`    | Switch / create branch                    |
| `ctrl+alt+shift+r`    | Remote actions                            |

In the panel (when focused): `up`/`down` move, `return` opens a file / toggles
a directory, `space` toggles a directory, `s` stages/unstages, `c` commits,
`a` stages all, `tab` returns focus to the editor, `escape` closes the panel.

## Install

Drop the `git` folder into `~/.config/lite-xl/plugins/`, or install via
[lpm](https://github.com/adamharrison/lite-xl-plugin-manager):

```
lpm install git
```

## Conflicts

This plugin registers a status-bar item named `status:git`. The standalone
**`gitstatus`** plugin registers an item under the same name, and loading both
makes Lite XL crash on startup (`status item already exists: status:git`),
which also breaks the current session (e.g. `Enter` stops working).

This plugin already provides everything `gitstatus` does (TreeView coloring +
a branch / `+`/`-` status item) and much more, so you should remove the
standalone plugin:

```
rm ~/.config/lite-xl/plugins/gitstatus.lua
```

On Windows the file usually lives at
`%APPDATA%\lite-xl\plugins\gitstatus.lua`.

If `gitstatus` is still present, this plugin detects the conflict on startup
and **refuses to activate** (logging an actionable message) instead of letting
the editor crash. You can also disable `gitstatus` without deleting it by
adding this to your `user/init.lua`:

```lua
config.plugins.gitstatus = false
```

## Configuration

All behavior is configurable through `config.plugins.git` in your
`user/init.lua`:

```lua
config.plugins.git.activate   = "ctrl+alt+shift+g"  -- toggle panel
config.plugins.git.scan_rate = 2                    -- refresh interval (s)
config.plugins.git.gutter_diff = true               -- gutter markers
-- colors are {r, g, b, a} tables; common.color() parses a hex string
config.plugins.git.color_modified  = common.color("#e6a800")  -- orange
config.plugins.git.color_untracked = common.color("#c9b400")  -- yellow
config.plugins.git.color_staged    = common.color("#4ec94e")  -- green
```

Colors (modified / untracked / staged / gutter added / gutter modified) are
also editable live from the **Settings → Git** GUI using the built-in color
picker — changes apply immediately without restarting.

## License

MIT

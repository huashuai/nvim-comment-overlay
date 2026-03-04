# nvim-comment-overlay

Google Docs-style inline comments for Neovim. Add comments to any line or selection, see them highlighted with visual cues, and browse them in a side panel.

Pure Lua. No dependencies. Requires Neovim 0.7+.

## Features

- **Line highlights** with warm amber background tint on commented lines
- **Sign column icons** (`󰆉`) on the gutter for quick scanning
- **Virtual text** previews at end-of-line showing truncated comment body
- **Reply-aware line previews** showing thread activity like `(2 replies)`
- **Floating windows** for adding, editing, and previewing comments
- **Side panel** listing all comments with status, navigation, and inline actions
- **Threaded discussions** with one-level replies in the side panel
- **Resolved/active** status tracking per comment
- **Dark and light** theme support (auto-detected)
- **Per-project storage** in `.nvim-comments.json` at project root

## Installation

```lua
{
  "hqu/nvim-comment-overlay",
  event = "BufReadPost",
  config = function()
    require("comment-overlay").setup()
  end,
}
```

## Workflow

This plugin pairs well with a Claude Code skill or custom command that reads `.nvim-comments.json`, incorporates the comments as context, and suggests improvements directly in your codebase. Add comments as you review, then let your AI assistant process them in bulk.

## Keymaps

### Global

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ca` | normal | Add comment on current line |
| `<leader>ca` | visual | Add comment on selected lines |
| `<leader>ce` | normal | Edit comment under cursor |
| `<leader>cd` | normal | Delete comment under cursor |
| `<leader>cl` | normal | Toggle comment list panel |
| `cL` | normal | Toggle global comment list panel |
| `<leader>cs` | normal | Toggle sign/highlight visibility |
| `<leader>cy` | normal | Copy resolved comment JSON filepath |
| `<leader>co` | normal | Open comment JSON file |
| `]c` | normal | Jump to next comment |
| `[c` | normal | Jump to previous comment |

### Floating windows (add/edit)

| Key | Action |
|-----|--------|
| `<C-s>` | Save and close |
| `<CR>` | Save and close (normal mode) |
| `q` | Close without saving |
| `<Esc>` | Close without saving |

### List panel

| Key | Action |
|-----|--------|
| `<CR>` / `o` | Jump to comment location |
| `e` | Edit comment |
| `t` | Reply to selected comment |
| `d` | Delete comment (with confirmation) |
| `r` | Toggle resolved/active on parent thread |
| `f` | Toggle focused thread view |
| `z` | Toggle collapse for selected thread |
| `+` / `-` | Grow/shrink list panel size |
| `R` | Reload comments from disk |
| `y` | Copy resolved storage JSON filepath |
| `j` / `k` | Jump to next/previous comment |
| `a` | Add new comment (switches to source) |
| `q` | Close panel |

## Commands

All actions are also available as commands:

```
:CommentAdd          Add comment (supports range in visual mode)
:CommentEdit         Edit comment under cursor
:CommentDelete       Delete comment under cursor
:CommentPreview      Preview comment in floating window
:CommentResolve      Toggle resolved status
:CommentReply        Reply to comment under cursor
:CommentList         Toggle comment list panel
:CommentGlobalList   Toggle global comment list panel (all files)
:CommentNext         Jump to next comment
:CommentPrev         Jump to previous comment
:CommentRefresh      Reload comments from disk and repaint overlays
:CommentCopyStoragePath Copy resolved storage JSON filepath to clipboard/register
:CommentOpenStorage  Open storage JSON file in current window
:CommentMigrateV1ToV2 Convert legacy `comments` array storage to v2 format
:CommentListWidth    Set list panel size (`:CommentListWidth 60`)
:CommentToggleSigns  Toggle highlight/sign visibility
```

## Configuration

All options are optional. These are the defaults:

```lua
require("comment-overlay").setup({
  signs = {
    enabled = true,
    icon = "󰆉",           -- nerd font comment icon
    hl = "CommentOverlaySign",
  },
  highlights = {
    comment_bg = "CommentOverlayBg",
    comment_icon = "CommentOverlaySign",
    comment_virt = "CommentOverlayVirt",
    comment_border = "CommentOverlayBorder",
    comment_title = "CommentOverlayTitle",
    comment_count = "CommentOverlayCount",
  },
  float = {
    width = 60,
    height = 10,
    border = "rounded",
    title_pos = "center",
  },
  list = {
    position = "right",   -- "right", "left", or "bottom"
    width = 40,            -- default width for left/right list panel
    height = 15,           -- for bottom position
    auto_preview = true,
  },
  storage = {
    path = nil,            -- auto-detect project root via .git
    filename = ".nvim-comments.json",
  },
  keymaps = {
    add = "<leader>ca",
    delete = "<leader>cd",
    edit = "<leader>ce",
    next = "]c",
    prev = "[c",
    toggle_list = "<leader>cl",
    toggle_global_list = "cL",
    toggle_signs = "<leader>cs",
    copy_storage_path = "<leader>cy",
    open_storage = "<leader>co",
  },
})
```

## Storage

Comments are stored in `.nvim-comments.json` at the project root (auto-detected via `.git` directory). The file is human-readable JSON — you can commit it to share comments with your team or add it to `.gitignore`.

Threaded comments use:
- `kind`: `"comment"` or `"reply"`
- `root_id`: root comment id for replies
- `reply_ids`: list of reply ids on root comments

By default, new comments are attributed to your `$USER`/`$LOGNAME`, and resolving a comment records `resolved_by` with the same actor. To override this (for agents), set either:

```lua
vim.g.comment_overlay_actor = "Codex" -- or "Claude", etc.
```

or plugin config:

```lua
require("comment-overlay").setup({
  actor = "Codex",
})
```

Set `vim.g.comment_overlay_actor = false` to disable automatic attribution.

When the storage file changes externally, the plugin now auto-reloads on `FocusGained`/buffer enter. You can also force reload with `:CommentRefresh`.

When a thread is resolved, replies in that thread are rendered in resolved style in the list panel as well, and resolved threads start collapsed by default (toggle with `z`).

Storage format:
- New format (v2) stores `comments` as a map keyed by id and `files` as `file -> [root_comment_ids]`.
- Legacy format (v1) with `comments` as an array is still readable.
- Run `:CommentMigrateV1ToV2` to persist a loaded legacy file in v2 shape.

## License

MIT

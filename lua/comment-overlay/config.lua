--- comment-overlay configuration
--- All modules import defaults and user overrides from here.

local M = {}

---@class CommentOverlayConfig
---@field actor string|false|nil
---@field signs CommentOverlaySigns
---@field highlights CommentOverlayHighlights
---@field float CommentOverlayFloat
---@field list CommentOverlayList
---@field storage CommentOverlayStorage
---@field keymaps CommentOverlayKeymaps

---@class CommentOverlaySigns
---@field enabled boolean
---@field icon string
---@field hl string

---@class CommentOverlayHighlights
---@field comment_bg string  -- highlight group for commented line background
---@field comment_icon string  -- highlight group for sign column icon
---@field comment_virt string  -- highlight group for virtual text preview
---@field comment_border string  -- highlight group for floating window border
---@field comment_title string  -- highlight group for floating window title
---@field comment_count string  -- highlight group for comment count badge

---@class CommentOverlayFloat
---@field width number  -- percentage of editor width (0-1) or absolute columns
---@field height number
---@field border string|string[]  -- border style
---@field title_pos string

---@class CommentOverlayList
---@field position string  -- "right" | "left" | "bottom" | "float"
---@field width number  -- for left/right position
---@field height number  -- for bottom position
---@field auto_preview boolean

---@class CommentOverlayStorage
---@field path string|nil  -- nil = auto-detect project root
---@field filename string  -- default ".nvim-comments.json"

---@class CommentOverlayKeymaps
---@field add string
---@field delete string
---@field edit string
---@field next string
---@field prev string
---@field toggle_list string
---@field toggle_global_list string
---@field toggle_signs string
---@field copy_storage_path string
---@field open_storage string

---@class Comment
---@field id string
---@field file string  -- relative path from project root
---@field line_start number  -- 1-indexed
---@field line_end number  -- 1-indexed, inclusive
---@field body string
---@field author string|nil
---@field kind string|nil  -- "comment" | "reply" (nil treated as "comment")
---@field root_id string|nil  -- root comment id for replies
---@field thread_id string|nil  -- root comment id
---@field parent_id string|nil  -- root comment id for one-level replies
---@field reply_ids string[]|nil  -- reply ids for top-level comments
---@field resolved_by string|nil
---@field resolved_at string|nil  -- ISO 8601
---@field created_at string  -- ISO 8601
---@field updated_at string  -- ISO 8601
---@field resolved boolean

M.namespace = "comment_overlay"

M.defaults = {
  actor = nil,
  signs = {
    enabled = true,
    icon = "󰆉",  -- nerd font comment icon
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
    position = "right",
    width = 40,
    height = 15,
    auto_preview = true,
  },
  storage = {
    path = nil,  -- auto-detect
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
}

---@type CommentOverlayConfig
M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

--- Resolve actor identity used for author/resolved_by fields.
--- Priority: opts.actor -> g:comment_overlay_actor -> env -> nil.
---@return string|nil
function M.get_actor()
  local actor_opt = M.options.actor
  if actor_opt == false then
    return nil
  end
  if type(actor_opt) == "string" and actor_opt ~= "" then
    return actor_opt
  end

  local from_global = vim.g.comment_overlay_actor
  if from_global == false then
    return nil
  end
  if type(from_global) == "string" and from_global ~= "" then
    return from_global
  end

  local from_env = vim.env.USER or vim.env.LOGNAME
  if from_env and from_env ~= "" then
    return from_env
  end
  return nil
end

return M

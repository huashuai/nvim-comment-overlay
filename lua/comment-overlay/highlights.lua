--- comment-overlay highlight groups, extmarks, signs, and virtual text
--- Handles all visual rendering for the plugin.

local config = require("comment-overlay.config")

local M = {}

local ns = vim.api.nvim_create_namespace(config.namespace)

--------------------------------------------------------------------------------
-- Color math helpers
--------------------------------------------------------------------------------

--- Parse a "#RRGGBB" hex string into r, g, b (0-255).
---@param hex string
---@return number, number, number
local function hex_to_rgb(hex)
  hex = hex:gsub("^#", "")
  return tonumber(hex:sub(1, 2), 16),
         tonumber(hex:sub(3, 4), 16),
         tonumber(hex:sub(5, 6), 16)
end

--- Format r, g, b (0-255) into "#RRGGBB".
---@return string
local function rgb_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", math.floor(r), math.floor(g), math.floor(b))
end

--- Blend two colors. ratio=0 gives base, ratio=1 gives tint.
---@param base string "#RRGGBB"
---@param tint string "#RRGGBB"
---@param ratio number 0.0-1.0
---@return string "#RRGGBB"
local function blend(base, tint, ratio)
  local br, bg, bb = hex_to_rgb(base)
  local tr, tg, tb = hex_to_rgb(tint)
  return rgb_to_hex(
    br + (tr - br) * ratio,
    bg + (tg - bg) * ratio,
    bb + (tb - bb) * ratio
  )
end

--- Lighten a color by mixing with white.
---@param hex string
---@param amount number 0.0-1.0
---@return string
local function lighten(hex, amount)
  return blend(hex, "#ffffff", amount)
end

--- Darken a color by mixing with black.
---@param hex string
---@param amount number 0.0-1.0
---@return string
local function darken(hex, amount)
  return blend(hex, "#000000", amount)
end

--- Extract the bg color from a highlight group as "#RRGGBB", or nil.
---@param group string
---@return string|nil
local function get_hl_bg(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and hl and hl.bg then
    return string.format("#%06x", hl.bg)
  end
  return nil
end

--- Extract the fg color from a highlight group as "#RRGGBB", or nil.
---@param group string
---@return string|nil
local function get_hl_fg(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and hl and hl.fg then
    return string.format("#%06x", hl.fg)
  end
  return nil
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

-- The tint color blended into the Normal bg for commented lines.
-- Purple-blue hue so it's distinguishable from selection/search highlights.
local TINT = "#8878c8"

---@param comment Comment
---@return boolean
local function is_reply(comment)
  return comment.kind == "reply"
end

---@param comment Comment
---@return string
local function thread_id(comment)
  return comment.thread_id or comment.id
end

--- Define highlight groups derived from the active colorscheme.
--- Safe to call multiple times (e.g. on colorscheme change).
function M.setup()
  local dark = vim.o.background ~= "light"
  local set = vim.api.nvim_set_hl

  -- Get the editor's actual background color.
  local normal_bg = get_hl_bg("Normal") or (dark and "#1e1e2e" or "#ffffff")
  local comment_fg = get_hl_fg("Comment") or (dark and "#6c7086" or "#9ca0b0")

  -- Comment line background: blend normal bg with tint (stronger for visibility).
  local comment_bg = blend(normal_bg, TINT, dark and 0.28 or 0.18)

  -- Resolved background: blend with green instead, dimmer.
  local resolved_bg = blend(normal_bg, "#68a87a", dark and 0.10 or 0.08)

  -- Sign icon: the tint color, brightened to stand out in the gutter.
  local sign_fg = dark and lighten(TINT, 0.3) or darken(TINT, 0.2)

  -- Virtual text: distinct from code, warm tint.
  local virt_fg = dark and lighten(TINT, 0.4) or darken(TINT, 0.3)

  -- Border: muted version of sign color.
  local border_fg = blend(comment_fg, TINT, 0.3)

  -- Title: bright tint.
  local title_fg = dark and lighten(TINT, 0.4) or darken(TINT, 0.15)

  -- Count badge: inverted.
  local count_bg = sign_fg
  local count_fg = normal_bg

  -- Resolved text: green-tinted comment color.
  local resolved_fg = blend(comment_fg, "#68a87a", 0.5)

  set(0, "CommentOverlayBg", { bg = comment_bg })
  set(0, "CommentOverlaySign", { fg = sign_fg })
  set(0, "CommentOverlayVirt", { fg = virt_fg, italic = true, bold = true })

  -- Badge style: distinct bg pill for right-aligned comment previews
  local badge_bg = blend(normal_bg, TINT, dark and 0.25 or 0.15)
  local badge_fg = dark and lighten(TINT, 0.5) or darken(TINT, 0.3)
  set(0, "CommentOverlayBadge", { fg = badge_fg, bg = badge_bg, bold = true })
  set(0, "CommentOverlayBorder", { fg = border_fg })
  set(0, "CommentOverlayTitle", { fg = title_fg, bold = true })
  set(0, "CommentOverlayCount", { fg = count_fg, bg = count_bg, bold = true })
  set(0, "CommentOverlayResolved", { bg = resolved_bg, fg = resolved_fg, italic = true })
end

--- Build a truncated preview string from comment body.
---@param body string
---@param resolved boolean
---@param reply_count number
---@return string
local function preview_text(body, resolved, reply_count)
  -- Collapse to single line, trim whitespace
  local text = body:gsub("\n", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 40 then
    text = text:sub(1, 40) .. "..."
  end
  if reply_count > 0 then
    text = text .. string.format(" (%d replies)", reply_count)
  end
  if resolved then
    text = "✓ " .. text
  end
  return text
end

--- Sort comments by line_start ascending, then by line_end descending
--- so wider ranges come first for the same start line.
---@param comments Comment[]
---@return Comment[]
local function sort_comments(comments)
  local sorted = vim.list_extend({}, comments)
  table.sort(sorted, function(a, b)
    if a.line_start ~= b.line_start then
      return a.line_start < b.line_start
    end
    return a.line_end > b.line_end
  end)
  return sorted
end

--- Render all comment decorations for a buffer.
---@param bufnr number
---@param comments Comment[]
function M.render_buffer(bufnr, comments)
  if not comments or #comments == 0 then
    return
  end

  local opts = config.options
  local hl = opts.highlights
  local signs = opts.signs
  local sorted = sort_comments(comments)

  -- Count replies for each thread so root line previews can show thread activity.
  local reply_count_by_thread = {} ---@type table<string, number>
  for _, comment in ipairs(sorted) do
    if is_reply(comment) then
      local tid = thread_id(comment)
      reply_count_by_thread[tid] = (reply_count_by_thread[tid] or 0) + 1
    end
  end

  -- First pass: collect all virtual text segments and sign info per line.
  -- This lets us show ALL comments that start on a given line.
  local line_has_sign = {} ---@type table<number, boolean>
  local line_has_bg = {} ---@type table<number, boolean>
  local line_virt_texts = {} ---@type table<number, {string,string}[]>

  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, comment in ipairs(sorted) do
    if is_reply(comment) then
      goto continue
    end

    local first_line = comment.line_start - 1 -- 0-indexed
    local last_line = math.min(comment.line_end - 1, buf_line_count - 1)

    -- Clamp comments beyond buffer to the last line
    if first_line >= buf_line_count then
      first_line = buf_line_count - 1
      last_line = buf_line_count - 1
    end

    -- No full-range background — keeps the doc readable when many comments exist

    -- Place sign on the first line of each comment (only one sign per line)
    if signs.enabled and not line_has_sign[first_line] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, first_line, 0, {
        sign_text = signs.icon,
        sign_hl_group = signs.hl,
        priority = 10,
      })
      line_has_sign[first_line] = true
    end

    -- Collect virtual text for the first line of this comment
    local virt_hl = comment.resolved and "CommentOverlayResolved" or hl.comment_virt
    local text = " " .. preview_text(comment.body, comment.resolved, reply_count_by_thread[thread_id(comment)] or 0)
    if not line_virt_texts[first_line] then
      line_virt_texts[first_line] = {}
    end
    table.insert(line_virt_texts[first_line], { text, virt_hl })
    ::continue::
  end

  -- Second pass: place right-aligned badge virtual text.
  for lnum, segments in pairs(line_virt_texts) do
    local virt_text = {}
    for i, seg in ipairs(segments) do
      if i > 1 then
        table.insert(virt_text, { " │ ", "CommentOverlayBadge" })
      end
      -- Wrap in badge highlight (bg pill)
      table.insert(virt_text, { " " .. seg[1] .. " ", "CommentOverlayBadge" })
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
      virt_text = virt_text,
      virt_text_pos = "right_align",
      priority = 10,
    })
  end
end

--- Remove all comment-overlay decorations from a buffer.
---@param bufnr number
function M.clear_buffer(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Clear then re-render decorations for a buffer.
---@param bufnr number
---@param comments Comment[]
function M.refresh(bufnr, comments)
  M.clear_buffer(bufnr)
  M.render_buffer(bufnr, comments)
end

return M

--- comment-overlay floating window UI
--- Handles add, edit, and preview floats for comments.

local config = require("comment-overlay.config")

local M = {}

--- Tracks the currently open float so we can clean up.
---@type { win: number|nil, buf: number|nil }
local current_float = { win = nil, buf = nil }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Compute centered float dimensions, capping at 80% of editor size.
---@param width number requested width
---@param height number requested height
---@return number col, number row, number w, number h
local function centered_geometry(width, height)
  local editor_w = vim.o.columns
  local editor_h = vim.o.lines - vim.o.cmdheight - 1 -- account for statusline
  local w = math.min(width, math.floor(editor_w * 0.8))
  local h = math.min(height, math.floor(editor_h * 0.8))
  local col = math.floor((editor_w - w) / 2)
  local row = math.floor((editor_h - h) / 2)
  return col, row, w, h
end

--- Create a scratch buffer with common settings.
---@param lines string[]|nil initial lines
---@param modifiable boolean
---@return number buf
local function make_scratch_buf(lines, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  if lines and #lines > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  if not modifiable then
    vim.bo[buf].modifiable = false
  end
  return buf
end

--- Shared float-creation logic.
---@param opts { title: string, title_hl: string|nil, lines: string[]|nil, modifiable: boolean, width: number|nil, height: number|nil }
---@return { win: number, buf: number }
local function create_float(opts)
  -- Close any existing float first.
  M.close()

  local cfg = config.options.float
  local width = opts.width or cfg.width
  local height = opts.height or cfg.height
  local col, row, w, h = centered_geometry(width, height)

  local buf = make_scratch_buf(opts.lines, opts.modifiable)

  local title_hl = opts.title_hl or config.options.highlights.comment_title
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    col = col,
    row = row,
    style = "minimal",
    border = cfg.border,
    title = { { opts.title, title_hl } },
    title_pos = cfg.title_pos,
  })

  -- Padding: shift text 1 space right for readability.
  vim.wo[win].winhl = "Normal:Normal,FloatBorder:" .. config.options.highlights.comment_border
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  -- Auto-close when focus leaves.
  local augroup = vim.api.nvim_create_augroup("CommentOverlayFloat", { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function()
      M.close()
    end,
  })

  current_float = { win = win, buf = buf }
  return current_float
end

--- Set keymaps to close a float without saving.
---@param buf number
local function set_close_keymaps(buf)
  local close = function()
    M.close()
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
end

--- Set keymaps for save + close inside an editable float.
---@param buf number
---@param on_save fun(body: string)
local function set_save_keymaps(buf, on_save)
  local save_and_close = function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    M.close()
    on_save(body)
  end
  vim.keymap.set("n", "<C-s>", save_and_close, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<CR>", save_and_close, { buffer = buf, silent = true, nowait = true })
end

--- Build a separator line that fills the float width.
---@param width number|nil
---@return string
local function separator(width)
  local w = width or config.options.float.width
  return string.rep("\u{2500}", w - 2) -- U+2500 BOX DRAWINGS LIGHT HORIZONTAL
end

--- Format a line range label.
---@param line_start number
---@param line_end number
---@return string
local function line_range_label(line_start, line_end)
  if line_start == line_end then
    return "Line " .. line_start
  end
  return "Lines " .. line_start .. "-" .. line_end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Open a floating window to add a new comment.
---@param line_start number 1-indexed
---@param line_end number 1-indexed, inclusive
---@param on_save fun(body: string) called with the comment body text
function M.open_add(line_start, line_end, on_save)
  local title = "  Add Comment  " .. line_range_label(line_start, line_end)
  local handle = create_float({
    title = title,
    modifiable = true,
  })

  set_close_keymaps(handle.buf)
  set_save_keymaps(handle.buf, on_save)

  -- Start in insert mode for immediate typing.
  vim.cmd("startinsert")
end

--- Open a floating window to edit an existing comment.
---@param comment Comment
---@param on_save fun(body: string) called with updated body text
function M.open_edit(comment, on_save)
  local title = "  Edit Comment  " .. line_range_label(comment.line_start, comment.line_end)
  local lines = vim.split(comment.body, "\n", { plain = true })

  local handle = create_float({
    title = title,
    lines = lines,
    modifiable = true,
  })

  set_close_keymaps(handle.buf)
  set_save_keymaps(handle.buf, on_save)

  -- Start in insert mode at end of existing text.
  vim.cmd("normal! G$")
  vim.cmd("startinsert!")
end

--- Open a reply float with thread context visible above the input area.
---@param thread Comment[] the thread (root + replies)
---@param on_save fun(body: string) called with the reply body text
function M.open_reply(thread, on_save)
  local root = thread[1]
  local title = "  Reply  " .. line_range_label(root.line_start, root.line_end)

  -- Build thread context (read-only portion)
  local content = {}
  for i, comment in ipairs(thread) do
    local author = comment.author or "unknown"
    local date = ""
    if comment.created_at then
      date = " " .. string.sub(comment.created_at, 1, 10)
    end
    local prefix = i == 1 and " " or "   "
    table.insert(content, prefix .. author .. date)
    local body_lines = vim.split(comment.body, "\n", { plain = true })
    for _, line in ipairs(body_lines) do
      table.insert(content, prefix .. "  " .. line)
    end
    if i < #thread then
      table.insert(content, "")
    end
  end

  -- Separator between context and reply input
  table.insert(content, "")
  local sep_line = " " .. string.rep("\u{2500}", 60)
  table.insert(content, sep_line)
  table.insert(content, "")
  table.insert(content, "")

  local reply_start_line = #content -- 1-indexed line count; cursor goes here

  local h = math.max(#content + 5, 12)
  local max_h = math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.8)
  h = math.min(h, max_h)

  local float_cfg = config.options.float
  local handle = create_float({
    title = title,
    lines = content,
    modifiable = true,
    height = h,
    width = math.max(float_cfg.width, 80),
  })

  -- Make the context area read-only by locking lines above separator
  -- We use an extmark highlight to visually distinguish context
  local ns = vim.api.nvim_create_namespace("comment_overlay_reply")
  for i = 0, reply_start_line - 2 do
    pcall(vim.api.nvim_buf_set_extmark, handle.buf, ns, i, 0, {
      line_hl_group = "Comment",
    })
  end

  -- Position cursor at the reply area
  local buf_line_count = vim.api.nvim_buf_line_count(handle.buf)
  local cursor_line = math.min(reply_start_line, buf_line_count)
  vim.api.nvim_win_set_cursor(handle.win, { cursor_line, 0 })

  set_close_keymaps(handle.buf)

  -- Save: only capture text below the separator
  local save_and_close = function()
    local all_lines = vim.api.nvim_buf_get_lines(handle.buf, reply_start_line - 1, -1, false)
    -- Trim empty lines from start/end
    while #all_lines > 0 and all_lines[1]:match("^%s*$") do
      table.remove(all_lines, 1)
    end
    while #all_lines > 0 and all_lines[#all_lines]:match("^%s*$") do
      table.remove(all_lines)
    end
    local body = table.concat(all_lines, "\n")
    M.close()
    if body ~= "" then
      on_save(body)
    end
  end

  vim.keymap.set("n", "<C-s>", save_and_close, { buffer = handle.buf, silent = true, nowait = true })
  vim.keymap.set("n", "<CR>", save_and_close, { buffer = handle.buf, silent = true, nowait = true })
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd("stopinsert")
    save_and_close()
  end, { buffer = handle.buf, silent = true, nowait = true })

  vim.cmd("startinsert")
end

--- Open a read-only preview of an existing comment.
---@param comment Comment
function M.open_preview(comment)
  local resolved_tag = comment.resolved and " \u{2713} Resolved" or ""
  local title = "  Comment  " .. line_range_label(comment.line_start, comment.line_end) .. resolved_tag
  local title_hl = comment.resolved and "DiagnosticOk" or nil

  -- Build content lines: body + separator + metadata.
  local body_lines = vim.split(comment.body, "\n", { plain = true })
  local content = {}
  for _, line in ipairs(body_lines) do
    table.insert(content, " " .. line) -- 1-space left padding
  end
  table.insert(content, "")
  table.insert(content, " " .. separator())

  -- Metadata footer.
  local date = ""
  if comment.created_at then
    date = string.sub(comment.created_at, 1, 10) -- YYYY-MM-DD portion
  end
  local author = comment.author or ""
  local meta_parts = {}
  if date ~= "" then
    table.insert(meta_parts, "Created: " .. date)
  end
  if author ~= "" then
    table.insert(meta_parts, "Author: " .. author)
  end
  if comment.kind == "reply" then
    table.insert(meta_parts, "Type: Reply")
  end
  if comment.resolved and comment.resolved_by and comment.resolved_by ~= "" then
    table.insert(meta_parts, "Resolved by: " .. comment.resolved_by)
  end
  if comment.resolved and comment.resolved_at and comment.resolved_at ~= "" then
    table.insert(meta_parts, "Resolved at: " .. comment.resolved_at)
  end
  if #meta_parts > 0 then
    table.insert(content, " " .. table.concat(meta_parts, "  "))
  end

  -- Size the preview to fit content, with a minimum.
  local h = math.max(#content + 1, 5)
  local cfg = config.options.float
  h = math.min(h, cfg.height + 4) -- don't grow unbounded

  local handle = create_float({
    title = title,
    title_hl = title_hl,
    lines = content,
    modifiable = false,
    height = h,
  })

  set_close_keymaps(handle.buf)
end

--- Open an interactive thread popup showing all comments/replies on a line.
--- Supports inline reply and resolve without leaving the popup.
---@param thread Comment[] ordered list: root comment followed by replies
---@param opts { on_reply: fun(root_id: string, body: string), on_resolve: fun(id: string) }
function M.open_thread(thread, opts)
  if not thread or #thread == 0 then
    return
  end

  local root = thread[1]
  local resolved_tag = root.resolved and " \u{2713} Resolved" or ""
  local title = "  Thread  " .. line_range_label(root.line_start, root.line_end) .. resolved_tag
  local title_hl = root.resolved and "DiagnosticOk" or nil

  -- Build thread content like a chat view
  local content = {}
  for i, comment in ipairs(thread) do
    local author = comment.author or "unknown"
    local date = ""
    if comment.created_at then
      date = " " .. string.sub(comment.created_at, 1, 10)
    end
    local prefix = i == 1 and " " or "   "
    local header = prefix .. author .. date
    if comment.resolved then
      header = header .. " [resolved]"
    end
    table.insert(content, header)

    local body_lines = vim.split(comment.body, "\n", { plain = true })
    for _, line in ipairs(body_lines) do
      table.insert(content, prefix .. "  " .. line)
    end
    if i < #thread then
      table.insert(content, "")
    end
  end

  table.insert(content, "")
  table.insert(content, " " .. separator())
  table.insert(content, " r = reply  x = resolve  ]c = next  [c = prev  q = close")

  local h = math.max(#content + 2, 8)
  local max_h = math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.8)
  h = math.min(h, max_h)

  local float_cfg = config.options.float
  local handle = create_float({
    title = title,
    title_hl = title_hl,
    lines = content,
    modifiable = false,
    height = h,
    width = math.max(float_cfg.width, 80),
  })

  -- Close keymaps
  set_close_keymaps(handle.buf)

  -- Reply: close popup, open reply-with-context, then auto-advance
  vim.keymap.set("n", "r", function()
    M.close()
    M.open_reply(thread, function(body)
      if opts.on_reply then
        opts.on_reply(root.id, body)
      end
      vim.schedule(function()
        if opts.on_next then
          opts.on_next()
        end
      end)
    end)
  end, { buffer = handle.buf, silent = true, nowait = true })

  -- Resolve: approve and auto-advance to next comment
  vim.keymap.set("n", "x", function()
    M.close()
    if opts.on_resolve then
      opts.on_resolve(root.id)
    end
    vim.schedule(function()
      if opts.on_next then
        opts.on_next()
      end
    end)
  end, { buffer = handle.buf, silent = true, nowait = true })

  -- Navigate to next comment
  vim.keymap.set("n", "]c", function()
    M.close()
    if opts.on_next then
      opts.on_next()
    end
  end, { buffer = handle.buf, silent = true, nowait = true })

  -- Navigate to prev comment
  vim.keymap.set("n", "[c", function()
    M.close()
    if opts.on_prev then
      opts.on_prev()
    end
  end, { buffer = handle.buf, silent = true, nowait = true })
end

--- Close the currently open comment float, if any.
function M.close()
  local win = current_float.win
  local buf = current_float.buf
  current_float = { win = nil, buf = nil }

  -- Clear the autocommand group to prevent stale callbacks.
  pcall(vim.api.nvim_create_augroup, "CommentOverlayFloat", { clear = true })

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Check if a float is currently open.
---@return boolean
function M.is_open()
  return current_float.win ~= nil and vim.api.nvim_win_is_valid(current_float.win)
end

return M

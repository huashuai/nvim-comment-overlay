--- comment-overlay global list panel
--- Side panel showing all commented files and root threads.

local config = require("comment-overlay.config")

local M = {}

local state = {
  buf = nil, ---@type number|nil
  win = nil, ---@type number|nil
  source_win = nil, ---@type number|nil
  line_to_comment = {}, ---@type table<number, string>
  line_to_file = {}, ---@type table<number, string>
  collapsed_files = {}, ---@type table<string, boolean>
}

local function storage()
  return require("comment-overlay.store")
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

local ns = vim.api.nvim_create_namespace("comment_overlay_global_list")

local HL = {
  title = "CommentOverlayGlobalTitle",
  separator = "CommentOverlayGlobalSeparator",
  file = "CommentOverlayGlobalFile",
  range = "CommentOverlayGlobalRange",
  row_active = "CommentOverlayGlobalRowActive",
  row_resolved = "CommentOverlayGlobalRowResolved",
  meta = "CommentOverlayGlobalMeta",
}

local function ensure_highlights()
  local function def(name, opts)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  def(HL.title, { bold = true, link = "Title" })
  def(HL.separator, { link = "Comment" })
  def(HL.file, { bold = true, link = "Identifier" })
  def(HL.range, { bold = true, link = "Number" })
  def(HL.row_active, { link = "Normal" })
  def(HL.row_resolved, { bold = true, link = "DiagnosticOk" })
  def(HL.meta, { link = "Comment" })
end

local function comment_count_for_file(file)
  local items = storage().get_for_file(file)
  return #items
end

local function line_range_label(comment)
  if comment.line_end and comment.line_end > comment.line_start then
    return string.format("L:%d-%d", comment.line_start, comment.line_end)
  end
  return string.format("L:%d", comment.line_start)
end

local function build_content(width)
  local lines = {}
  local hls = {}
  local line_to_comment = {}
  local line_to_file = {}

  local files = storage().get_files_with_comments()

  local title = string.format(" 󰍉 All Comments  files:%d", #files)
  lines[#lines + 1] = title
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #title, hl = HL.title }

  local sep = string.rep("─", math.max(width, 20))
  lines[#lines + 1] = sep
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #sep, hl = HL.separator }

  if #files == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  No comments in this project."
  else
    for _, file in ipairs(files) do
      lines[#lines + 1] = ""

      local collapsed = state.collapsed_files[file] == true
      local icon = collapsed and "▸" or "▾"
      local count = comment_count_for_file(file)
      local header = string.format(" %s %s (%d comments)", icon, file, count)
      lines[#lines + 1] = header
      hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #header, hl = HL.file }
      line_to_file[#lines] = file

      if not collapsed then
        local roots = storage().get_for_file(file, { roots_only = true })
        for _, root in ipairs(roots) do
          local preview = (root.body or ""):gsub("\n", " ")
          if #preview > 56 then
            preview = preview:sub(1, 56) .. "..."
          end
          local author = root.author or "unknown"
          local replies = #(root.reply_ids or {})
          local icon = root.resolved and "✓" or "●"
          local row = string.format("   %s  %s %s", line_range_label(root), icon, preview)
          local metadata = author
          if replies > 0 then
            local word = replies == 1 and "reply" or "replies"
            metadata = string.format("%s · %d %s", metadata, replies, word)
          end

          lines[#lines + 1] = row
          local row_line = #lines
          local range = line_range_label(root)
          local range_start = 3
          local range_end = range_start + #range
          hls[#hls + 1] = {
            line = row_line - 1,
            col_start = 0,
            col_end = #row,
            hl = root.resolved and HL.row_resolved or HL.row_active,
          }
          hls[#hls + 1] = {
            line = row_line - 1,
            col_start = range_start,
            col_end = range_end,
            hl = HL.range,
          }
          line_to_comment[row_line] = root.id

          lines[#lines + 1] = "      " .. metadata
          hls[#hls + 1] = {
            line = #lines - 1,
            col_start = 0,
            col_end = -1,
            hl = HL.meta,
          }
          line_to_comment[#lines] = root.id
        end
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = sep
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #sep, hl = HL.separator }
  lines[#lines + 1] = " q close  <CR>/o open/toggle  z toggle-file  y copy-storage-path  R refresh"
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = HL.meta }

  return lines, hls, line_to_comment, line_to_file
end

local function render()
  if not buf_valid() then
    return
  end

  local width = 50
  if win_valid(state.win) then
    width = vim.api.nvim_win_get_width(state.win)
  end

  local lines, hls, line_to_comment, line_to_file = build_content(width)
  state.line_to_comment = line_to_comment
  state.line_to_file = line_to_file

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local col_end = h.col_end
    if col_end == -1 then
      col_end = #lines[h.line + 1] or 0
    end
    vim.api.nvim_buf_add_highlight(state.buf, ns, h.hl, h.line, h.col_start or 0, col_end)
  end
end

local function cursor_line()
  if not win_valid(state.win) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(state.win)[1]
end

local function toggle_current_file()
  local line = cursor_line()
  if not line then
    return
  end
  local file = state.line_to_file[line]
  if not file then
    return
  end
  state.collapsed_files[file] = not state.collapsed_files[file]
  render()
end

local function jump_to_comment()
  local line = cursor_line()
  if not line then
    return
  end

  local file = state.line_to_file[line]
  if file then
    toggle_current_file()
    return
  end

  local id = state.line_to_comment[line]
  if not id then
    return
  end

  local comment = storage().get(id)
  if not comment then
    return
  end

  local root = storage().get_project_root()
  local abs = root .. "/" .. comment.file

  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end

  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  vim.api.nvim_win_set_cursor(0, { comment.line_start, 0 })
  vim.cmd("normal! zz")
end

local function refresh()
  render()
end

local function copy_storage_path()
  local path = storage().get_storage_path({ resolve = true })
  local reg = vim.fn.has("clipboard") == 1 and "+" or '"'
  vim.fn.setreg(reg, path)
  vim.notify("Comment storage path copied: " .. path, vim.log.levels.INFO)
end

local function setup_keymaps()
  if not buf_valid() then
    return
  end
  local opts = { buffer = state.buf, nowait = true, silent = true }

  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<CR>", jump_to_comment, opts)
  vim.keymap.set("n", "o", jump_to_comment, opts)
  vim.keymap.set("n", "z", toggle_current_file, opts)
  vim.keymap.set("n", "y", copy_storage_path, opts)
  vim.keymap.set("n", "R", refresh, opts)
end

function M.open()
  if win_valid(state.win) and buf_valid() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.source_win = vim.api.nvim_get_current_win()

  local opts = config.options.list or config.defaults.list
  local width = math.max((opts.width or 40) + 10, 50)
  vim.cmd("botright vertical " .. width .. "split")
  state.win = vim.api.nvim_get_current_win()

  if not buf_valid() then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "wipe"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].filetype = "comment-overlay-global-list"
    vim.api.nvim_buf_set_name(state.buf, "comment-overlay://global-list")
  end

  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].wrap = true
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].winfixwidth = true

  ensure_highlights()
  setup_keymaps()
  render()

  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
end

function M.close()
  if win_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if buf_valid() then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.buf = nil
  state.win = nil
  state.line_to_comment = {}
  state.line_to_file = {}
  state.collapsed_files = {}
end

function M.toggle()
  if win_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.refresh()
  if win_valid(state.win) and buf_valid() then
    render()
  end
end

function M.is_open()
  return win_valid(state.win)
end

return M

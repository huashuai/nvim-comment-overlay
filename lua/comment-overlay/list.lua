--- comment-overlay list panel
--- Side panel showing all comments for the current file with navigation.

local config = require("comment-overlay.config")

local M = {}

-- Panel state ---------------------------------------------------------------

local state = {
  buf = nil, ---@type number|nil
  win = nil, ---@type number|nil
  source_buf = nil, ---@type number|nil  buffer that was active when panel opened
  source_win = nil, ---@type number|nil  window that was active when panel opened
  line_to_comment = {}, ---@type table<number, string>  list-buf line -> comment id
  comment_header_lines = {}, ---@type number[]  list-buf lines that are comment headers
  focus_thread_id = nil, ---@type string|nil
  collapsed_threads = {}, ---@type table<string, boolean>
  autocmd_group = nil, ---@type number|nil
}

-- Helpers -------------------------------------------------------------------

---Lazy-load the store module so list.lua has no hard init-time dep.
---@return table
local function storage()
  return require("comment-overlay.store")
end

---Return the relative filepath for a buffer (matches Comment.file).
---Uses store.get_relative_path so paths match what's persisted.
---@param bufnr number
---@return string
local function buf_relpath(bufnr)
  local abs = vim.api.nvim_buf_get_name(bufnr)
  if abs == "" then
    return ""
  end
  return storage().get_relative_path(abs)
end

---Check whether a window handle is still valid and visible.
---@param win number|nil
---@return boolean
local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---Check whether the panel buffer is still alive.
---@return boolean
local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

---Get comments for the source buffer.
---@return Comment[]
local function get_comments()
  if not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return {}
  end
  local relpath = buf_relpath(state.source_buf)
  if relpath == "" then
    return {}
  end
  local opts = {}
  if state.focus_thread_id then
    opts.thread_id = state.focus_thread_id
  end
  return storage().get_for_file(relpath, opts) or {}
end

---Group comments by thread id and return sorted thread structures.
---@param comments Comment[]
---@return table[]
local function build_threads(comments)
  local threads_by_id = {} ---@type table<string, { id:string, root:Comment|nil, comments:Comment[], replies:Comment[] }>

  for _, comment in ipairs(comments) do
    local tid = comment.thread_id or comment.id
    if not threads_by_id[tid] then
      threads_by_id[tid] = { id = tid, root = nil, comments = {}, replies = {} }
    end
    local thread = threads_by_id[tid]
    table.insert(thread.comments, comment)

    if comment.kind == "reply" then
      table.insert(thread.replies, comment)
    elseif comment.id == tid or not thread.root then
      thread.root = comment
    end
  end

  local threads = {}
  for _, thread in pairs(threads_by_id) do
    if not thread.root and #thread.comments > 0 then
      table.sort(thread.comments, function(a, b)
        if (a.created_at or "") ~= (b.created_at or "") then
          return (a.created_at or "") < (b.created_at or "")
        end
        return a.id < b.id
      end)
      thread.root = thread.comments[1]
      thread.replies = {}
      for _, c in ipairs(thread.comments) do
        if c.id ~= thread.root.id then
          table.insert(thread.replies, c)
        end
      end
    end

    table.sort(thread.replies, function(a, b)
      if (a.created_at or "") ~= (b.created_at or "") then
        return (a.created_at or "") < (b.created_at or "")
      end
      return a.id < b.id
    end)

    table.insert(threads, thread)
  end

  table.sort(threads, function(a, b)
    local ar = a.root
    local br = b.root
    if not ar then
      return false
    end
    if not br then
      return true
    end
    if ar.line_start ~= br.line_start then
      return ar.line_start < br.line_start
    end
    if (ar.created_at or "") ~= (br.created_at or "") then
      return (ar.created_at or "") < (br.created_at or "")
    end
    return ar.id < br.id
  end)

  return threads
end

---@param comment Comment
---@return string
local function comment_thread_id(comment)
  return comment.thread_id or comment.id
end

---@param thread table
---@return boolean
local function is_thread_collapsed(thread)
  local explicit = state.collapsed_threads[thread.id]
  if explicit ~= nil then
    return explicit
  end
  local root = thread.root
  return root and root.resolved or false
end

-- Highlight groups ----------------------------------------------------------

local ns = vim.api.nvim_create_namespace("comment_overlay_list")

local HL = {
  title = "CommentOverlayListTitle",
  separator = "CommentOverlayListSeparator",
  header_active = "CommentOverlayListHeaderActive",
  header_resolved = "CommentOverlayListHeaderResolved",
  body = "CommentOverlayListBody",
  body_resolved = "CommentOverlayListBodyResolved",
  reply_header = "CommentOverlayListReplyHeader",
  footer = "CommentOverlayListFooter",
  line_nr = "CommentOverlayListLineNr",
}

local function ensure_highlights()
  local function def(name, opts)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
  def(HL.title, { bold = true, link = "Title" })
  def(HL.separator, { link = "Comment" })
  def(HL.header_active, { bold = true, link = "Keyword" })
  def(HL.header_resolved, { bold = true, link = "DiagnosticOk" })
  def(HL.body, { link = "Normal" })
  def(HL.body_resolved, { link = "Comment" })
  def(HL.reply_header, { link = "Identifier" })
  def(HL.footer, { link = "Comment" })
  def(HL.line_nr, { bold = true, link = "Number" })
end

-- Rendering -----------------------------------------------------------------

local SEPARATOR_CHAR = "─"
local MAX_BODY_LINES = 3

---@param comment Comment
---@return string, string
local function status_parts(comment)
  if comment.resolved then
    return "✓", "Resolved"
  end
  return "●", "Active"
end

---@param iso string|nil
---@return string
local function format_timestamp(iso)
  if not iso or iso == "" then
    return ""
  end
  local y, m, d, hh, mm = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not y then
    return iso
  end
  return string.format("%s-%s-%s %s:%s UTC", y, m, d, hh, mm)
end

---@param resolved boolean
---@param comment Comment
---@param lines string[]
---@param hls table[]
---@param line_map table<number, string>
---@param indent string
local function append_comment_body(resolved, comment, lines, hls, line_map, indent)
  local body_lines = vim.split(comment.body or "", "\n", { plain = true })
  local body_hl = resolved and HL.body_resolved or HL.body
  local shown = 0
  for _, bline in ipairs(body_lines) do
    if shown >= MAX_BODY_LINES then
      lines[#lines + 1] = indent .. "..."
      hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = body_hl }
      line_map[#lines] = comment.id
      break
    end
    lines[#lines + 1] = indent .. bline
    hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = body_hl }
    line_map[#lines] = comment.id
    shown = shown + 1
  end
end

---Build the lines and highlight data for the panel buffer.
---@param comments Comment[]
---@param width number
---@return string[] lines, {line:number,col_start:number,col_end:number,hl:string}[] highlights, table<number,string> line_map, number[] header_lines
local function build_content(comments, width)
  local lines = {}
  local hls = {}
  local line_map = {}
  local header_lines = {}

  local threads = build_threads(comments)
  local sep = string.rep(SEPARATOR_CHAR, math.max(width, 20))

  local title
  if state.focus_thread_id and #threads > 0 and threads[1].root then
    local root = threads[1].root
    local range
    if root.line_end and root.line_end > root.line_start then
      range = string.format("L:%d-%d", root.line_start, root.line_end)
    else
      range = string.format("L:%d", root.line_start)
    end
    title = string.format(" 󰆉 Thread %s  comments:%d", range, #comments)
  else
    title = string.format(" 󰆉 Comments  threads:%d  comments:%d", #threads, #comments)
  end
  lines[#lines + 1] = title
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #title, hl = HL.title }

  lines[#lines + 1] = sep
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #sep, hl = HL.separator }

  if #threads == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  No comments in this file."
    hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = HL.body }
    lines[#lines + 1] = ""
  else
    for _, thread in ipairs(threads) do
      local root = thread.root
      if root then
        lines[#lines + 1] = ""

        local range
        if root.line_end and root.line_end > root.line_start then
          range = string.format("L:%d-%d", root.line_start, root.line_end)
        else
          range = string.format("L:%d", root.line_start)
        end

        local icon, status = status_parts(root)
        local thread_resolved = root.resolved
        local collapsed = is_thread_collapsed(thread)
        local collapse_icon = collapsed and "▸" or "▾"
        local reply_count = #thread.replies
        local header = string.format(" %s  %s %s %s", range, icon, status, collapse_icon)
        if reply_count > 0 then
          header = header .. string.format("  replies:%d", reply_count)
        end
        lines[#lines + 1] = header

        local hline = #lines - 1
        header_lines[#header_lines + 1] = #lines
        line_map[#lines] = root.id

        local range_end = 1 + #range
        local header_hl = root.resolved and HL.header_resolved or HL.header_active
        hls[#hls + 1] = { line = hline, col_start = 1, col_end = range_end, hl = HL.line_nr }
        hls[#hls + 1] = { line = hline, col_start = range_end, col_end = #header, hl = header_hl }

        local root_meta = {}
        if root.author and root.author ~= "" then
          table.insert(root_meta, "author: " .. root.author)
        end
        if root.resolved then
          local resolved_meta = {}
          if root.resolved_by and root.resolved_by ~= "" then
            table.insert(resolved_meta, "resolved_by: " .. root.resolved_by)
          end
          if root.resolved_at and root.resolved_at ~= "" then
            table.insert(resolved_meta, "at: " .. format_timestamp(root.resolved_at))
          end
          if #resolved_meta > 0 then
            table.insert(root_meta, table.concat(resolved_meta, "  "))
          end
        end
        if #root_meta > 0 then
          lines[#lines + 1] = "   " .. table.concat(root_meta, "  ")
          hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = HL.footer }
          line_map[#lines] = root.id
        end

        append_comment_body(thread_resolved or root.resolved, root, lines, hls, line_map, " ")

        if not collapsed then
          for _, reply in ipairs(thread.replies) do
            local reply_author = reply.author or "unknown"
            local reply_header = string.format("   ↳ %s", reply_author)
            lines[#lines + 1] = reply_header
            hls[#hls + 1] = {
              line = #lines - 1,
              col_start = 0,
              col_end = #reply_header,
              hl = (thread_resolved or reply.resolved) and HL.header_resolved or HL.reply_header,
            }
            header_lines[#header_lines + 1] = #lines
            line_map[#lines] = reply.id

            if reply.resolved and reply.resolved_by and reply.resolved_by ~= "" then
              local rb = "      resolved_by: " .. reply.resolved_by
              lines[#lines + 1] = rb
              hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, hl = HL.footer }
              line_map[#lines] = reply.id
            end

            append_comment_body(thread_resolved or reply.resolved, reply, lines, hls, line_map, "      ")
          end
        end
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = sep
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #sep, hl = HL.separator }
  local footer =
    " q close  e edit  d delete  r resolve-thread  t reply  f toggle-focus  z collapse-toggle  y copy-storage-path  +/- resize  R refresh"
  lines[#lines + 1] = footer
  hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = #footer, hl = HL.footer }

  return lines, hls, line_map, header_lines
end

---Render content into the panel buffer.
local function render()
  if not buf_valid() then
    return
  end

  local opts = config.options.list or config.defaults.list
  local width = opts.width or 40
  if win_valid(state.win) then
    width = vim.api.nvim_win_get_width(state.win)
  end

  local comments = get_comments()
  local lines, hls, line_map, header_lines = build_content(comments, width)

  state.line_to_comment = line_map
  state.comment_header_lines = header_lines

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local col_end = h.col_end
    if col_end == -1 then
      col_end = #lines[h.line + 1] or 0
    end
    vim.api.nvim_buf_add_highlight(state.buf, ns, h.hl, h.line, h.col_start, col_end)
  end
end

-- Comment-under-cursor helpers ----------------------------------------------

---Return the comment id at the current cursor line, or nil.
---@return string|nil
local function comment_at_cursor()
  if not win_valid(state.win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_to_comment[line]
end

---Return the full comment object at cursor, or nil.
---@return Comment|nil
local function comment_obj_at_cursor()
  local id = comment_at_cursor()
  if not id then
    return nil
  end
  local comments = get_comments()
  for _, c in ipairs(comments) do
    if c.id == id then
      return c
    end
  end
  return nil
end

-- Keymaps -------------------------------------------------------------------

local function jump_to_comment()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
    vim.api.nvim_win_set_cursor(state.source_win, { comment.line_start, 0 })
    vim.cmd("normal! zz")
  end
end

local function edit_comment()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  vim.schedule(function()
    local ok, overlay = pcall(require, "comment-overlay")
    if ok and overlay.edit_comment then
      overlay.edit_comment(comment.id)
    end
  end)
end

local function reply_to_comment()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  vim.schedule(function()
    local ok, overlay = pcall(require, "comment-overlay")
    if ok and overlay.reply_comment then
      overlay.reply_comment(comment.id)
    end
  end)
end

local function delete_comment()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  local choice = vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  storage().delete(comment.id)
  M.refresh()
end

local function toggle_resolved()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  local tid = comment_thread_id(comment)
  local target_id = comment.kind == "reply" and tid or comment.id
  storage().resolve(target_id, config.get_actor())
  M.refresh()
end

local function toggle_focus_thread()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  local tid = comment_thread_id(comment)
  if state.focus_thread_id == tid then
    state.focus_thread_id = nil
  else
    state.focus_thread_id = tid
  end
  M.refresh()
  if state.focus_thread_id and #state.comment_header_lines > 0 and win_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { state.comment_header_lines[1], 0 })
  end
end

local function toggle_thread_collapsed()
  local comment = comment_obj_at_cursor()
  if not comment then
    return
  end
  local tid = comment_thread_id(comment)
  local current = state.collapsed_threads[tid]
  if current == nil then
    -- First explicit toggle should invert the default behavior.
    local thread_comments = storage().get_thread(tid)
    local root_resolved = false
    for _, c in ipairs(thread_comments) do
      if c.id == tid or c.kind ~= "reply" then
        root_resolved = c.resolved and true or false
        break
      end
    end
    state.collapsed_threads[tid] = not root_resolved
  else
    state.collapsed_threads[tid] = not current
  end
  M.refresh()
end

local function refresh_comments()
  local ok, overlay = pcall(require, "comment-overlay")
  if ok and overlay.refresh then
    overlay.refresh()
  else
    M.refresh()
  end
end

--- Adjust list panel size by delta.
--- For left/right list: adjusts width. For bottom list: adjusts height.
---@param delta number
local function adjust_size(delta)
  if not win_valid(state.win) then
    return
  end
  local opts = config.options.list or config.defaults.list
  local position = opts.position or "right"
  local min_size = 20
  local max_size = 180

  if position == "bottom" then
    local current = vim.api.nvim_win_get_height(state.win)
    local target = math.max(min_size, math.min(max_size, current + delta))
    vim.api.nvim_win_set_height(state.win, target)
    opts.height = target
    return
  end

  local current = vim.api.nvim_win_get_width(state.win)
  local target = math.max(min_size, math.min(max_size, current + delta))
  vim.api.nvim_win_set_width(state.win, target)
  opts.width = target
end

local function grow_list()
  adjust_size(8)
end

local function shrink_list()
  adjust_size(-8)
end

local function next_comment()
  if not win_valid(state.win) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  for _, hline in ipairs(state.comment_header_lines) do
    if hline > cur then
      vim.api.nvim_win_set_cursor(state.win, { hline, 0 })
      return
    end
  end
  if #state.comment_header_lines > 0 then
    vim.api.nvim_win_set_cursor(state.win, { state.comment_header_lines[1], 0 })
  end
end

local function prev_comment()
  if not win_valid(state.win) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  for i = #state.comment_header_lines, 1, -1 do
    if state.comment_header_lines[i] < cur then
      vim.api.nvim_win_set_cursor(state.win, { state.comment_header_lines[i], 0 })
      return
    end
  end
  if #state.comment_header_lines > 0 then
    vim.api.nvim_win_set_cursor(state.win, { state.comment_header_lines[#state.comment_header_lines], 0 })
  end
end

local function add_comment()
  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  vim.schedule(function()
    local ok, overlay = pcall(require, "comment-overlay")
    if ok and overlay.add_comment then
      overlay.add_comment()
    end
  end)
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
  local buf = state.buf
  local map_opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<CR>", jump_to_comment, map_opts)
  vim.keymap.set("n", "o", jump_to_comment, map_opts)
  vim.keymap.set("n", "e", edit_comment, map_opts)
  vim.keymap.set("n", "t", reply_to_comment, map_opts)
  vim.keymap.set("n", "d", delete_comment, map_opts)
  vim.keymap.set("n", "r", toggle_resolved, map_opts)
  vim.keymap.set("n", "q", M.close, map_opts)
  vim.keymap.set("n", "j", next_comment, map_opts)
  vim.keymap.set("n", "k", prev_comment, map_opts)
  vim.keymap.set("n", "a", add_comment, map_opts)
  vim.keymap.set("n", "y", copy_storage_path, map_opts)
  vim.keymap.set("n", "R", refresh_comments, map_opts)
  vim.keymap.set("n", "f", toggle_focus_thread, map_opts)
  vim.keymap.set("n", "z", toggle_thread_collapsed, map_opts)
  vim.keymap.set("n", "+", grow_list, map_opts)
  vim.keymap.set("n", "-", shrink_list, map_opts)
end

-- Autocmds ------------------------------------------------------------------

local function setup_autocmds()
  if state.autocmd_group then
    vim.api.nvim_del_augroup_by_id(state.autocmd_group)
  end
  state.autocmd_group = vim.api.nvim_create_augroup("CommentOverlayList", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = state.autocmd_group,
    callback = function(args)
      if not win_valid(state.win) then
        return
      end
      if args.buf == state.buf then
        return
      end
      local ft = vim.bo[args.buf].filetype
      if ft == "comment-overlay-list" or vim.bo[args.buf].buftype ~= "" then
        return
      end
      state.source_buf = args.buf
      state.source_win = vim.api.nvim_get_current_win()
      state.focus_thread_id = nil
      state.collapsed_threads = {}
      M.refresh()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.autocmd_group,
    callback = function(args)
      if state.win and tostring(state.win) == args.match then
        M.close()
      end
    end,
  })
end

local function teardown_autocmds()
  if state.autocmd_group then
    vim.api.nvim_del_augroup_by_id(state.autocmd_group)
    state.autocmd_group = nil
  end
end

-- Public API ----------------------------------------------------------------

---Open the comment list panel.
function M.open()
  if win_valid(state.win) and buf_valid() then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  ensure_highlights()

  state.source_win = vim.api.nvim_get_current_win()
  state.source_buf = vim.api.nvim_get_current_buf()
  state.focus_thread_id = nil
  state.collapsed_threads = {}

  local opts = config.options.list or config.defaults.list
  local width = opts.width or 40
  local position = opts.position or "right"

  if position == "left" then
    vim.cmd("topleft vertical " .. width .. "split")
  elseif position == "bottom" then
    local height = opts.height or 15
    vim.cmd("botright " .. height .. "split")
  else
    vim.cmd("botright vertical " .. width .. "split")
  end

  state.win = vim.api.nvim_get_current_win()

  if not buf_valid() then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "wipe"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].filetype = "comment-overlay-list"
    vim.api.nvim_buf_set_name(state.buf, "comment-overlay://list")
  end

  vim.api.nvim_win_set_buf(state.win, state.buf)

  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].wrap = true
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].winfixwidth = true

  setup_keymaps()
  render()
  setup_autocmds()

  if #state.comment_header_lines > 0 then
    vim.api.nvim_win_set_cursor(state.win, { state.comment_header_lines[1], 0 })
  end

  if win_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
end

---Close the comment list panel.
function M.close()
  teardown_autocmds()

  if win_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end

  if buf_valid() then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  state.win = nil
  state.buf = nil
  state.line_to_comment = {}
  state.comment_header_lines = {}
  state.focus_thread_id = nil
  state.collapsed_threads = {}
end

---Toggle the comment list panel.
function M.toggle()
  if win_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

---Re-render the panel content. Call after add/edit/delete/resolve.
function M.refresh()
  if not win_valid(state.win) or not buf_valid() then
    return
  end
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)
  render()
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  local row = math.min(cursor_pos[1], line_count)
  pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
end

---Return whether the panel is currently open.
---@return boolean
function M.is_open()
  return win_valid(state.win)
end

--- Set list width (or height when bottom position) for current and future opens.
---@param size number
---@return boolean
function M.set_size(size)
  local n = tonumber(size)
  if not n or n < 20 then
    return false
  end
  local opts = config.options.list or config.defaults.list
  local position = opts.position or "right"
  if position == "bottom" then
    opts.height = math.floor(n)
    if win_valid(state.win) then
      vim.api.nvim_win_set_height(state.win, opts.height)
    end
    return true
  end
  opts.width = math.floor(n)
  if win_valid(state.win) then
    vim.api.nvim_win_set_width(state.win, opts.width)
  end
  return true
end

return M

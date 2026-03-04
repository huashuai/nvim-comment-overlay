--- comment-overlay: main entry point
--- Wires together config, store, highlights, ui, and list modules.

local M = {}

local config = require("comment-overlay.config")
local store = require("comment-overlay.store")
local highlights = require("comment-overlay.highlights")
local ui = require("comment-overlay.ui")
local list = require("comment-overlay.list")
local global_list = require("comment-overlay.global-list")

local augroup_name = "CommentOverlay"
local signs_visible = true

--- Get the relative file path for the current buffer.
---@return string
local function current_file()
  return store.get_relative_path(vim.api.nvim_buf_get_name(0))
end

--- Get comment(s) on a specific line of the current buffer.
---@param lnum? number line number (1-indexed), defaults to cursor line
---@return Comment[]
local function comments_at_line(lnum)
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  return store.get_for_line(current_file(), lnum, { roots_only = true })
end

--- Pick a single comment from a list, prompting if multiple.
---@param comments Comment[]
---@param cb fun(comment: Comment)
local function pick_comment(comments, cb)
  if #comments == 0 then
    vim.notify("No comment on this line", vim.log.levels.INFO)
    return
  end
  if #comments == 1 then
    cb(comments[1])
    return
  end
  vim.ui.select(comments, {
    prompt = "Select comment:",
    format_item = function(c)
      local preview = c.body:sub(1, 60)
      if #c.body > 60 then
        preview = preview .. "..."
      end
      return string.format("[L%d] %s", c.line_start, preview)
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

--- Refresh highlights for the current buffer.
local function refresh_buf()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local file = store.get_relative_path(name)
  local comments = store.get_for_file(file)
  highlights.refresh(bufnr, comments)
  -- Also refresh the list panel if open
  if list.is_open and list.is_open() then
    list.refresh()
  end
  if global_list.is_open and global_list.is_open() then
    global_list.refresh()
  end
end

--- Render comments for a buffer (clear + display).
---@param bufnr number
local function render_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local file = store.get_relative_path(name)
  local comments = store.get_for_file(file)
  highlights.refresh(bufnr, comments)
end

--- Refresh comment overlays (and list panel) across loaded buffers.
local function refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        if signs_visible then
          render_buf(bufnr)
        else
          highlights.clear_buffer(bufnr)
        end
      end
    end
  end
  if list.is_open and list.is_open() then
    list.refresh()
  end
  if global_list.is_open and global_list.is_open() then
    global_list.refresh()
  end
end

--- Force reload comments from disk and repaint UI.
---@param notify boolean|nil
local function refresh_from_disk(notify)
  store.reload()
  refresh_all()
  if notify ~= false then
    vim.notify("Comments refreshed", vim.log.levels.INFO)
  end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- Add a comment spanning line_start..line_end in the current buffer.
---@param line_start number
---@param line_end number
local function add_comment(line_start, line_end)
  local file = current_file()
  ui.open_add(line_start, line_end, function(body)
    store.add(file, line_start, line_end, body, config.get_actor())
    refresh_buf()
  end)
end

--- Add a reply under the cursor's thread.
local function reply_comment()
  local comments = comments_at_line()
  pick_comment(comments, function(comment)
    ui.open_add(comment.line_start, comment.line_end, function(body)
      local reply = store.add_reply(comment.id, body, config.get_actor())
      if not reply then
        vim.notify("Unable to add reply", vim.log.levels.WARN)
        return
      end
      refresh_buf()
    end)
  end)
end

--- Delete the comment under the cursor.
local function delete_comment()
  local comments = comments_at_line()
  pick_comment(comments, function(comment)
    local ok = vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2)
    if ok == 1 then
      store.delete(comment.id)
      refresh_buf()
    end
  end)
end

--- Edit the comment under the cursor.
local function edit_comment()
  local comments = comments_at_line()
  pick_comment(comments, function(comment)
    ui.open_edit(comment, function(body)
      store.update(comment.id, body)
      refresh_buf()
    end)
  end)
end

--- Preview the comment under the cursor in a floating window.
local function preview_comment()
  local comments = comments_at_line()
  pick_comment(comments, function(comment)
    ui.open_preview(comment)
  end)
end

--- Toggle the resolved status of the comment under the cursor.
local function resolve_comment()
  local comments = comments_at_line()
  pick_comment(comments, function(comment)
    store.resolve(comment.id, config.get_actor())
    refresh_buf()
  end)
end

--- Jump to the next comment in the current file.
local function next_comment()
  local file = current_file()
  local comments = store.get_for_file(file, { roots_only = true })
  if #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.INFO)
    return
  end
  table.sort(comments, function(a, b)
    return a.line_start < b.line_start
  end)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, c in ipairs(comments) do
    if c.line_start > cursor_line then
      vim.api.nvim_win_set_cursor(0, { c.line_start, 0 })
      return
    end
  end
  -- Wrap around to first comment
  vim.api.nvim_win_set_cursor(0, { comments[1].line_start, 0 })
end

--- Jump to the previous comment in the current file.
local function prev_comment()
  local file = current_file()
  local comments = store.get_for_file(file, { roots_only = true })
  if #comments == 0 then
    vim.notify("No comments in this file", vim.log.levels.INFO)
    return
  end
  table.sort(comments, function(a, b)
    return a.line_start < b.line_start
  end)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  for i = #comments, 1, -1 do
    if comments[i].line_start < cursor_line then
      vim.api.nvim_win_set_cursor(0, { comments[i].line_start, 0 })
      return
    end
  end
  -- Wrap around to last comment
  vim.api.nvim_win_set_cursor(0, { comments[#comments].line_start, 0 })
end

--- Toggle sign/highlight visibility across all buffers.
local function toggle_signs()
  signs_visible = not signs_visible
  if signs_visible then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
        render_buf(bufnr)
      end
    end
    vim.notify("Comment signs shown", vim.log.levels.INFO)
  else
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        highlights.clear_buffer(bufnr)
      end
    end
    vim.notify("Comment signs hidden", vim.log.levels.INFO)
  end
end

--- Copy the storage JSON path to clipboard/register.
local function copy_storage_path()
  local path = store.get_storage_path({ resolve = true })
  local reg = vim.fn.has("clipboard") == 1 and "+" or '"'
  vim.fn.setreg(reg, path)
  vim.notify("Comment storage path copied: " .. path, vim.log.levels.INFO)
end

--- Open the storage JSON file in the current window.
local function open_storage_file()
  local path = store.get_storage_path({ resolve = true })
  if vim.fn.filereadable(path) ~= 1 then
    store.load()
    store.save()
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

---------------------------------------------------------------------------
-- User commands
---------------------------------------------------------------------------

local function register_commands()
  vim.api.nvim_create_user_command("CommentAdd", function(cmd)
    add_comment(cmd.line1, cmd.line2)
  end, { range = true })

  vim.api.nvim_create_user_command("CommentDelete", function()
    delete_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentEdit", function()
    edit_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentPreview", function()
    preview_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentResolve", function()
    resolve_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentReply", function()
    reply_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentList", function()
    list.toggle()
  end, {})

  vim.api.nvim_create_user_command("CommentGlobalList", function()
    global_list.toggle()
  end, {})

  vim.api.nvim_create_user_command("CommentNext", function()
    next_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentPrev", function()
    prev_comment()
  end, {})

  vim.api.nvim_create_user_command("CommentToggleSigns", function()
    toggle_signs()
  end, {})

  vim.api.nvim_create_user_command("CommentRefresh", function()
    refresh_from_disk(true)
  end, {})

  vim.api.nvim_create_user_command("CommentCopyStoragePath", function()
    copy_storage_path()
  end, {})

  vim.api.nvim_create_user_command("CommentOpenStorage", function()
    open_storage_file()
  end, {})

  -- Undocumented maintenance command for migrating legacy storage to v2.
  vim.api.nvim_create_user_command("CommentMigrateV1ToV2", function()
    local updated = store.migrate_v1_to_v2()
    refresh_all()
    vim.notify(string.format("V1->V2 migration complete: %d comments converted", updated), vim.log.levels.INFO)
  end, {})

  vim.api.nvim_create_user_command("CommentListWidth", function(cmd)
    local size = tonumber(cmd.args)
    if not size then
      vim.notify("Usage: :CommentListWidth <number>", vim.log.levels.WARN)
      return
    end
    if not list.set_size or not list.set_size(size) then
      vim.notify("Invalid size; must be >= 20", vim.log.levels.WARN)
    end
  end, { nargs = 1 })
end

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

local function register_keymaps()
  local km = config.options.keymaps
  local opts = { silent = true }

  -- Normal mode mappings
  vim.keymap.set("n", km.add, function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    add_comment(lnum, lnum)
  end, vim.tbl_extend("force", opts, { desc = "Add comment" }))

  -- Visual mode add: capture selection range
  vim.keymap.set("v", km.add, function()
    local start = vim.fn.line("v")
    local end_ = vim.fn.line(".")
    if start > end_ then
      start, end_ = end_, start
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    add_comment(start, end_)
  end, vim.tbl_extend("force", opts, { desc = "Add comment on selection" }))

  vim.keymap.set("n", km.delete, function()
    delete_comment()
  end, vim.tbl_extend("force", opts, { desc = "Delete comment" }))

  vim.keymap.set("n", km.edit, function()
    edit_comment()
  end, vim.tbl_extend("force", opts, { desc = "Edit comment" }))

  vim.keymap.set("n", km.next, function()
    next_comment()
  end, vim.tbl_extend("force", opts, { desc = "Next comment" }))

  vim.keymap.set("n", km.prev, function()
    prev_comment()
  end, vim.tbl_extend("force", opts, { desc = "Previous comment" }))

  vim.keymap.set("n", km.toggle_list, function()
    list.toggle()
  end, vim.tbl_extend("force", opts, { desc = "Toggle comment list" }))

  vim.keymap.set("n", km.toggle_global_list, function()
    global_list.toggle()
  end, vim.tbl_extend("force", opts, { desc = "Toggle global comment list" }))

  vim.keymap.set("n", km.toggle_signs, function()
    toggle_signs()
  end, vim.tbl_extend("force", opts, { desc = "Toggle comment signs" }))

  vim.keymap.set("n", km.copy_storage_path, function()
    copy_storage_path()
  end, vim.tbl_extend("force", opts, { desc = "Copy comment storage path" }))

  vim.keymap.set("n", km.open_storage, function()
    open_storage_file()
  end, vim.tbl_extend("force", opts, { desc = "Open comment storage file" }))
end

---------------------------------------------------------------------------
-- Autocommands
---------------------------------------------------------------------------

local function register_autocommands()
  local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      local changed = store.reload_if_changed()
      if changed then
        refresh_all()
      end
      if signs_visible then
        render_buf(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if store.reload_if_changed() then
        refresh_all()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if signs_visible then
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name ~= "" then
          local file = store.get_relative_path(name)
          local file_comments = store.get_for_file(file)
          highlights.refresh(ev.buf, file_comments)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      highlights.setup()
    end,
  })
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(opts)
  config.setup(opts)
  highlights.setup()
  store.load()
  register_commands()
  register_keymaps()
  register_autocommands()
end

--- Public API for cross-module calls (e.g. from list panel).

--- Add a comment on the current line (used by list panel 'a' keymap).
function M.add_comment()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  add_comment(lnum, lnum)
end

--- Reply to a comment by ID (or comment under cursor when nil).
---@param comment_id? string
function M.reply_comment(comment_id)
  if comment_id then
    local comment = store.get(comment_id)
    if not comment then
      vim.notify("Comment not found", vim.log.levels.WARN)
      return
    end
    ui.open_add(comment.line_start, comment.line_end, function(body)
      local reply = store.add_reply(comment.id, body, config.get_actor())
      if not reply then
        vim.notify("Unable to add reply", vim.log.levels.WARN)
        return
      end
      refresh_buf()
    end)
    return
  end
  reply_comment()
end

--- Edit a comment by ID (used by list panel 'e' keymap).
---@param comment_id string
function M.edit_comment(comment_id)
  local comment = store.get(comment_id)
  if not comment then
    vim.notify("Comment not found", vim.log.levels.WARN)
    return
  end
  ui.open_edit(comment, function(body)
    store.update(comment.id, body)
    refresh_buf()
  end)
end

--- Force reload comments from disk and repaint all visible overlays.
function M.refresh()
  refresh_from_disk(true)
end

return M

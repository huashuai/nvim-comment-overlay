--- comment-overlay data store
--- Manages comment persistence and in-memory cache with JSON file backing.

local config = require("comment-overlay.config")

local M = {}
local uv = vim.uv or vim.loop

---@type table<string, Comment>
local comments = {}

---@type table<string, string[]>
local files = {}

---@type string|nil
local project_root_cache = nil

---@type boolean
local loaded = false

---@type number|nil
local last_loaded_mtime = nil

---@type "v1"|"v2"|nil
local loaded_format = nil

local is_list = vim.islist or vim.tbl_islist

--- Return current ISO 8601 timestamp.
---@return string
local function iso_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Generate a unique comment ID from timestamp and random hex suffix.
---@return string
local function generate_id()
  return string.format("%s_%04x", os.date("%Y%m%d%H%M%S"), math.random(0, 0xFFFF))
end

--- Return true when comment is a reply.
---@param comment Comment
---@return boolean
local function is_reply(comment)
  return comment.kind == "reply"
end

--- Return root thread id for a comment.
---@param comment Comment
---@return string
local function thread_id(comment)
  if comment.root_id and comment.root_id ~= "" then
    return comment.root_id
  end
  if comment.thread_id and comment.thread_id ~= "" then
    return comment.thread_id
  end
  return comment.id
end

--- Ensure a comment has required default fields.
---@param comment Comment
local function normalize_comment(comment)
  if not comment.kind or comment.kind == "" then
    comment.kind = "comment"
  end

  if comment.kind == "reply" then
    local rid = thread_id(comment)
    comment.root_id = rid
    comment.thread_id = rid
    comment.parent_id = rid
    comment.reply_ids = nil
  else
    comment.root_id = nil
    comment.thread_id = comment.id
    comment.parent_id = nil
    if type(comment.reply_ids) ~= "table" then
      comment.reply_ids = {}
    end
  end

  if comment.resolved == nil then
    comment.resolved = false
  end
  if not comment.created_at or comment.created_at == "" then
    comment.created_at = iso_now()
  end
  if not comment.updated_at or comment.updated_at == "" then
    comment.updated_at = comment.created_at
  end
end

--- Build per-file root index and per-root reply index from comments map.
local function rebuild_indexes()
  files = {}

  for _, c in pairs(comments) do
    normalize_comment(c)
    if c.kind == "comment" then
      local list = files[c.file]
      if not list then
        list = {}
        files[c.file] = list
      end
      list[#list + 1] = c.id
      c.reply_ids = {}
    end
  end

  for _, c in pairs(comments) do
    if c.kind == "reply" then
      local root = comments[thread_id(c)]
      if root and root.kind == "comment" then
        root.reply_ids[#root.reply_ids + 1] = c.id
      end
    end
  end

  local function comment_cmp(a, b)
    if a.line_start ~= b.line_start then
      return a.line_start < b.line_start
    end
    if (a.created_at or "") ~= (b.created_at or "") then
      return (a.created_at or "") < (b.created_at or "")
    end
    return a.id < b.id
  end

  for _, root_ids in pairs(files) do
    table.sort(root_ids, function(aid, bid)
      local a = comments[aid]
      local b = comments[bid]
      if not a then
        return false
      end
      if not b then
        return true
      end
      return comment_cmp(a, b)
    end)
  end

  for _, root in pairs(comments) do
    if root.kind == "comment" and root.reply_ids then
      table.sort(root.reply_ids, function(aid, bid)
        local a = comments[aid]
        local b = comments[bid]
        if not a then
          return false
        end
        if not b then
          return true
        end
        if (a.created_at or "") ~= (b.created_at or "") then
          return (a.created_at or "") < (b.created_at or "")
        end
        return a.id < b.id
      end)
    end
  end
end

--- Convert legacy v1 comments array into v2 in-memory shape.
---@param legacy_comments Comment[]
local function migrate_v1_in_memory(legacy_comments)
  comments = {}

  for _, c in ipairs(legacy_comments or {}) do
    normalize_comment(c)
    comments[c.id] = c
  end

  rebuild_indexes()
end

--- Find project root by walking up from CWD looking for `.git` directory,
--- then falling back to a directory containing `.nvim-comments.json`,
--- then falling back to CWD itself. Result is cached.
---@return string
function M.get_project_root()
  if project_root_cache then
    return project_root_cache
  end

  local cwd = vim.fn.getcwd()
  local storage_cfg = config.options.storage or config.defaults.storage

  -- If user explicitly configured a path, use that.
  if storage_cfg.path then
    project_root_cache = storage_cfg.path
    return project_root_cache
  end

  -- Walk up from CWD looking for .git directory.
  local dir = cwd
  while true do
    if vim.fn.isdirectory(dir .. "/.git") == 1 then
      project_root_cache = dir
      return project_root_cache
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  -- Fallback: walk up looking for existing .nvim-comments.json.
  local filename = storage_cfg.filename or ".nvim-comments.json"
  dir = cwd
  while true do
    if vim.fn.filereadable(dir .. "/" .. filename) == 1 then
      project_root_cache = dir
      return project_root_cache
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  -- Final fallback: CWD.
  project_root_cache = cwd
  return project_root_cache
end

--- Get the full path to the JSON storage file.
---@return string
local function storage_path()
  local root = M.get_project_root()
  local storage_cfg = config.options.storage or config.defaults.storage
  local filename = storage_cfg.filename or ".nvim-comments.json"
  return root .. "/" .. filename
end

--- Get the full path to the JSON storage file.
--- Optionally resolves symlinks for the path/root.
---@param opts? { resolve?: boolean }
---@return string
function M.get_storage_path(opts)
  local path = storage_path()
  opts = opts or {}
  if not opts.resolve then
    return path
  end

  local resolved_path = uv and uv.fs_realpath and uv.fs_realpath(path) or nil
  if resolved_path and resolved_path ~= "" then
    return resolved_path
  end

  local root = M.get_project_root()
  local resolved_root = uv and uv.fs_realpath and uv.fs_realpath(root) or nil
  if resolved_root and resolved_root ~= "" then
    local storage_cfg = config.options.storage or config.defaults.storage
    local filename = storage_cfg.filename or ".nvim-comments.json"
    return resolved_root:gsub("/$", "") .. "/" .. filename
  end

  return path
end

--- Get storage file mtime or nil if file doesn't exist.
---@return number|nil
local function storage_mtime()
  local mtime = vim.fn.getftime(storage_path())
  if mtime < 0 then
    return nil
  end
  return mtime
end

--- Convert an absolute path to a path relative to project root.
---@param absolute_path string
---@return string
function M.get_relative_path(absolute_path)
  local root = M.get_project_root()
  local prefix = root:gsub("/$", "") .. "/"
  if absolute_path:sub(1, #prefix) == prefix then
    return absolute_path:sub(#prefix + 1)
  end
  return absolute_path
end

--- Load comments from the JSON file on disk into memory.
--- Safe against missing or corrupt files (starts with empty set).
---@param force? boolean
---@return boolean reloaded true if in-memory cache changed from disk read
function M.load(force)
  if loaded and not force then
    return false
  end

  local path = storage_path()
  if vim.fn.filereadable(path) ~= 1 then
    comments = {}
    files = {}
    loaded = true
    loaded_format = "v2"
    last_loaded_mtime = nil
    return true
  end

  local mtime = storage_mtime()
  if loaded and mtime == last_loaded_mtime then
    return false
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    comments = {}
    files = {}
    loaded = true
    loaded_format = "v2"
    last_loaded_mtime = mtime
    return true
  end

  local raw = table.concat(lines, "\n")
  local decode_ok, data = pcall(vim.fn.json_decode, raw)
  if not decode_ok or type(data) ~= "table" then
    vim.notify("[comment-overlay] corrupt JSON file, starting fresh", vim.log.levels.WARN)
    comments = {}
    files = {}
    loaded = true
    loaded_format = "v2"
    last_loaded_mtime = mtime
    return true
  end

  local comments_field = data.comments
  local is_comments_array = type(comments_field) == "table" and is_list(comments_field)
  local is_comments_map = type(comments_field) == "table" and not is_list(comments_field)

  if data.version == 2 or (is_comments_map and type(data.files) == "table") then
    comments = is_comments_map and comments_field or {}
    files = type(data.files) == "table" and data.files or {}
    rebuild_indexes()
    loaded_format = "v2"
  elseif is_comments_array then
    migrate_v1_in_memory(comments_field)
    loaded_format = "v1"
  else
    comments = {}
    files = {}
    loaded_format = "v2"
  end

  loaded = true
  last_loaded_mtime = mtime
  return true
end

--- Simple JSON pretty-printer (2-space indent).
---@param str string compact JSON
---@return string formatted JSON
local function pretty_json(str)
  local indent = 0
  local result = {}
  local in_string = false
  local i = 1
  while i <= #str do
    local ch = str:sub(i, i)
    if ch == '"' and (i == 1 or str:sub(i - 1, i - 1) ~= "\\") then
      in_string = not in_string
      result[#result + 1] = ch
    elseif in_string then
      result[#result + 1] = ch
    elseif ch == "{" or ch == "[" then
      indent = indent + 1
      result[#result + 1] = ch .. "\n" .. string.rep("  ", indent)
    elseif ch == "}" or ch == "]" then
      indent = indent - 1
      result[#result + 1] = "\n" .. string.rep("  ", indent) .. ch
    elseif ch == "," then
      result[#result + 1] = ",\n" .. string.rep("  ", indent)
    elseif ch == ":" then
      result[#result + 1] = ": "
    elseif ch ~= " " and ch ~= "\n" and ch ~= "\r" and ch ~= "\t" then
      result[#result + 1] = ch
    end
    i = i + 1
  end
  return table.concat(result)
end

--- Persist all in-memory comments to the JSON file on disk.
--- Writes canonical v2 shape.
function M.save()
  local path = storage_path()
  local data = {
    version = 2,
    comments = comments,
    files = files,
  }
  local json = vim.fn.json_encode(data)
  local formatted = pretty_json(json)
  local lines = vim.split(formatted, "\n", { plain = true })

  local write_ok, err = pcall(vim.fn.writefile, lines, path)
  if not write_ok then
    vim.notify("[comment-overlay] failed to save: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  loaded_format = "v2"
  last_loaded_mtime = storage_mtime()
end

--- Ensure comments are loaded before any read/write operation.
local function ensure_loaded()
  if not loaded then
    M.load()
  end
end

--- Build a sorted flat list for a file from root ids and reply ids.
---@param file string
---@return Comment[]
local function flat_file_comments(file)
  local root_ids = files[file] or {}
  local out = {}
  for _, rid in ipairs(root_ids) do
    local root = comments[rid]
    if root then
      out[#out + 1] = root
      for _, reply_id in ipairs(root.reply_ids or {}) do
        local reply = comments[reply_id]
        if reply then
          out[#out + 1] = reply
        end
      end
    end
  end
  return out
end

--- Add a comment or reply.
---@param file string relative path from project root
---@param line_start number 1-indexed
---@param line_end number 1-indexed, inclusive
---@param body string
---@param author string|nil
---@param parent_id string|nil
---@return Comment
function M.add(file, line_start, line_end, body, author, parent_id)
  ensure_loaded()

  local now = iso_now()
  local kind = parent_id and "reply" or "comment"
  local parent = parent_id and M.get(parent_id) or nil
  local root = nil

  if parent then
    root = parent.kind == "reply" and comments[thread_id(parent)] or parent
    if not root then
      root = parent
    end
    file = root.file
    line_start = root.line_start
    line_end = root.line_end
  else
    parent_id = nil
    kind = "comment"
  end

  local id = generate_id()
  while comments[id] do
    id = generate_id()
  end

  local tid = root and root.id or id

  ---@type Comment
  local comment = {
    id = id,
    file = file,
    line_start = line_start,
    line_end = line_end,
    body = body,
    author = author,
    kind = kind,
    root_id = kind == "reply" and tid or nil,
    thread_id = tid,
    parent_id = kind == "reply" and tid or nil,
    reply_ids = kind == "comment" and {} or nil,
    resolved_by = nil,
    resolved_at = nil,
    created_at = now,
    updated_at = now,
    resolved = false,
  }

  comments[id] = comment

  if kind == "comment" then
    local roots = files[file]
    if not roots then
      roots = {}
      files[file] = roots
    end
    roots[#roots + 1] = id
    rebuild_indexes()
  else
    local root_comment = comments[tid]
    if root_comment then
      root_comment.reply_ids = root_comment.reply_ids or {}
      root_comment.reply_ids[#root_comment.reply_ids + 1] = id
      table.sort(root_comment.reply_ids, function(aid, bid)
        local a = comments[aid]
        local b = comments[bid]
        if not a then
          return false
        end
        if not b then
          return true
        end
        if (a.created_at or "") ~= (b.created_at or "") then
          return (a.created_at or "") < (b.created_at or "")
        end
        return a.id < b.id
      end)
    end
  end

  M.save()
  return comment
end

--- Add a reply to an existing comment/thread item.
--- Replies are always attached to the thread root (one-level thread model).
---@param parent_id string
---@param body string
---@param author string|nil
---@return Comment|nil
function M.add_reply(parent_id, body, author)
  ensure_loaded()
  local parent = M.get(parent_id)
  if not parent then
    return nil
  end
  local root_id = thread_id(parent)
  local root = M.get(root_id) or parent
  return M.add(root.file, root.line_start, root.line_end, body, author, root.id)
end

--- Get a comment by its ID.
---@param id string
---@return Comment|nil
function M.get(id)
  ensure_loaded()
  return comments[id]
end

--- Get all comments for a given file.
---@param file string relative path
---@param opts? { roots_only?: boolean, thread_id?: string }
---@return Comment[]
function M.get_for_file(file, opts)
  ensure_loaded()
  opts = opts or {}

  local result = {}
  local flat = flat_file_comments(file)
  for _, c in ipairs(flat) do
    if opts.thread_id and thread_id(c) ~= opts.thread_id then
      goto continue
    end
    if opts.roots_only and is_reply(c) then
      goto continue
    end
    result[#result + 1] = c
    ::continue::
  end

  return result
end

--- Get all comments that span a given line (line_start <= line <= line_end).
---@param file string relative path
---@param line number 1-indexed
---@param opts? { roots_only?: boolean }
---@return Comment[]
function M.get_for_line(file, line, opts)
  ensure_loaded()
  opts = opts or {}

  local result = {}
  local flat = flat_file_comments(file)
  for _, c in ipairs(flat) do
    if c.line_start <= line and line <= c.line_end then
      if opts.roots_only and is_reply(c) then
        goto continue
      end
      result[#result + 1] = c
    end
    ::continue::
  end
  return result
end

--- Get all comments in a thread by thread id.
---@param tid string
---@return Comment[]
function M.get_thread(tid)
  ensure_loaded()
  local root = comments[tid]
  if not root then
    return {}
  end

  local result = { root }
  for _, rid in ipairs(root.reply_ids or {}) do
    local reply = comments[rid]
    if reply then
      result[#result + 1] = reply
    end
  end
  return result
end

--- Update a comment's body text.
---@param id string
---@param body string
---@return Comment|nil updated comment, or nil if not found
function M.update(id, body)
  ensure_loaded()
  local c = comments[id]
  if not c then
    return nil
  end
  c.body = body
  c.updated_at = iso_now()
  M.save()
  return c
end

--- Delete a comment by ID.
--- Deleting a root comment deletes the whole thread.
---@param id string
---@return boolean true if deleted
function M.delete(id)
  ensure_loaded()
  local target = comments[id]
  if not target then
    return false
  end

  if is_reply(target) then
    local root = comments[thread_id(target)]
    if root and root.reply_ids then
      for i, rid in ipairs(root.reply_ids) do
        if rid == id then
          table.remove(root.reply_ids, i)
          break
        end
      end
    end
    comments[id] = nil
    M.save()
    return true
  end

  local file_roots = files[target.file] or {}
  for i, rid in ipairs(file_roots) do
    if rid == id then
      table.remove(file_roots, i)
      break
    end
  end
  if #file_roots == 0 then
    files[target.file] = nil
  else
    files[target.file] = file_roots
  end

  for _, rid in ipairs(target.reply_ids or {}) do
    comments[rid] = nil
  end
  comments[id] = nil

  M.save()
  return true
end

--- Toggle the resolved status of a comment.
---@param id string
---@param resolved_by string|nil
---@return Comment|nil updated comment, or nil if not found
function M.resolve(id, resolved_by)
  ensure_loaded()
  local c = comments[id]
  if not c then
    return nil
  end

  c.resolved = not c.resolved
  if c.resolved then
    c.resolved_by = resolved_by
    c.resolved_at = iso_now()
  else
    c.resolved_by = nil
    c.resolved_at = nil
  end
  c.updated_at = iso_now()
  M.save()
  return c
end

--- Return all comments.
---@return Comment[]
function M.get_all()
  ensure_loaded()
  local result = {}
  for _, c in pairs(comments) do
    result[#result + 1] = c
  end
  table.sort(result, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line_start ~= b.line_start then
      return a.line_start < b.line_start
    end
    if (a.created_at or "") ~= (b.created_at or "") then
      return (a.created_at or "") < (b.created_at or "")
    end
    return a.id < b.id
  end)
  return result
end

--- Return all files that currently have comments.
---@return string[]
function M.get_files_with_comments()
  ensure_loaded()
  local out = {}
  for file, roots in pairs(files) do
    if type(roots) == "table" and #roots > 0 then
      out[#out + 1] = file
    end
  end
  table.sort(out)
  return out
end

--- Migrate legacy v1 storage shape to v2 on disk.
---@return number updated_count number of comments persisted in v2 shape
function M.migrate_v1_to_v2()
  M.load(true)
  if loaded_format ~= "v1" then
    return 0
  end
  local count = 0
  for _ in pairs(comments) do
    count = count + 1
  end
  M.save()
  return count
end

--- Force reload comments from disk.
---@return boolean reloaded
function M.reload()
  loaded = false
  return M.load(true)
end

--- Reload comments only if the storage file changed on disk.
---@return boolean reloaded
function M.reload_if_changed()
  if not loaded then
    return M.load(true)
  end
  local mtime = storage_mtime()
  if mtime ~= last_loaded_mtime then
    return M.load(true)
  end
  return false
end

return M

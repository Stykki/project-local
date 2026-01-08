---@class project_local.util
local M = {}

local uv = vim.loop

-- Determine path separator based on OS
local IS_WINDOWS = uv.os_uname().sysname:find("Windows") ~= nil
M.PATH_SEP = IS_WINDOWS and "\\" or "/"

---Join path components with the appropriate separator
---@param ... string Path components to join
---@return string
function M.path_join(...)
  local parts = { ... }
  return table.concat(parts, M.PATH_SEP)
end

---Normalize a path to absolute form
---@param path string Path to normalize
---@return string
function M.normalize(path)
  return vim.fn.fnamemodify(path, ":p")
end

---Check if a path exists and return its type
---@param path string Path to check
---@return string|nil type Returns "file", "directory", or nil
function M.exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type or nil
end

---Calculate SHA256 hash of a file
---@param path string Path to the file
---@return string|nil hash The hex-encoded SHA256 hash, or nil on error
function M.sha256(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if not content then
    return nil
  end
  return vim.fn.sha256(content)
end

return M

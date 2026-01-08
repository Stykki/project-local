---@class project_local.trust
local Trust = {}

local uv = vim.loop
local util = require("project_local.util")

-- Internal state
local store = {
  enabled = true,
  prompt = true,
  store_dir = vim.fn.stdpath("data") .. "/project_local",
  store_file = "trusted.json",
}

local trust_cache = nil
local sha256_cache = nil -- Separate cache for sha256-based trust
local prompting_in_progress = {}

---Ensure the store directory exists
---@return string
local function ensure_store_path()
  if util.exists(store.store_dir) ~= "directory" then
    vim.fn.mkdir(store.store_dir, "p")
  end
  return store.store_dir
end

---Get the full path to the trust store file
---@return string
local function store_path()
  return util.path_join(ensure_store_path(), store.store_file)
end

---Load the trust store from disk with error handling and backup
---@return table, table trust_cache, sha256_cache
local function load_store()
  if trust_cache and sha256_cache then
    return trust_cache, sha256_cache
  end
  local fp = store_path()
  if util.exists(fp) ~= "file" then
    trust_cache = {}
    sha256_cache = {}
    return trust_cache, sha256_cache
  end
  local ok, decoded = pcall(function()
    local content = table.concat(vim.fn.readfile(fp), "\n")
    return vim.json.decode(content)
  end)
  if not ok or type(decoded) ~= "table" then
    -- Backup corrupted file before resetting
    local backup_path = fp .. ".backup." .. os.time()
    local backup_ok = pcall(function()
      vim.fn.writefile(vim.fn.readfile(fp), backup_path)
    end)
    if backup_ok then
      vim.notify(
        string.format(
          "[project-local] Corrupted trust store backed up to %s. Starting fresh.",
          backup_path
        ),
        vim.log.levels.WARN
      )
    else
      vim.notify(
        "[project-local] Corrupted trust store detected. Starting fresh.",
        vim.log.levels.WARN
      )
    end
    trust_cache = {}
    sha256_cache = {}
  else
    -- Support both old format (flat) and new format (with directories and sha256)
    if decoded.directories or decoded.sha256 then
      trust_cache = decoded.directories or {}
      sha256_cache = decoded.sha256 or {}
    else
      -- Migration from old format: treat all entries as directory trust
      trust_cache = decoded
      sha256_cache = {}
    end
  end
  return trust_cache, sha256_cache
end

---Save the trust store to disk with error handling
local function save_store()
  if not trust_cache then
    return
  end
  local data = {
    directories = trust_cache,
    sha256 = sha256_cache or {},
  }
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    vim.notify("[project-local] Failed to encode trust store", vim.log.levels.ERROR)
    return
  end
  local fp = store_path()
  local f, err = io.open(fp, "w")
  if not f then
    vim.notify(
      string.format("[project-local] Failed to save trust store: %s", err or "unknown error"),
      vim.log.levels.ERROR
    )
    return
  end
  f:write(encoded)
  f:close()
end

-- Public setup (called from core)
---@param opts table|nil Configuration options
function Trust.setup(opts)
  if opts then
    for k, v in pairs(opts) do
      store[k] = v
    end
  end
end

---Check if a directory is trusted
---@param dir string Directory path to check
---@return boolean
function Trust.is_trusted(dir)
  if not store.enabled then
    return true
  end
  dir = util.normalize(dir)
  local dirs, _ = load_store()
  return dirs[dir] == true
end

---Check if a file is trusted by its SHA256 hash
---@param file_path string Full path to the file
---@return boolean
function Trust.is_trusted_sha256(file_path)
  if not store.enabled then
    return true
  end
  file_path = util.normalize(file_path)
  local _, hashes = load_store()
  local stored_hash = hashes[file_path]
  if not stored_hash then
    return false
  end
  local current_hash = util.sha256(file_path)
  return current_hash == stored_hash
end

---Set trust status for a directory
---@param dir string Directory path
---@param val boolean|nil Trust status (nil to remove)
function Trust.set_trusted(dir, val)
  dir = util.normalize(dir)
  load_store()
  if val then
    trust_cache[dir] = true
  else
    trust_cache[dir] = nil
  end
  save_store()
end

---Remove trust for a directory
---@param dir string Directory path
function Trust.untrust(dir)
  dir = util.normalize(dir)
  load_store()
  trust_cache[dir] = nil
  save_store()
end

---Trust a file by its SHA256 hash
---@param file_path string Full path to the file
---@return boolean success Whether the trust was set successfully
function Trust.trust_sha256(file_path)
  file_path = util.normalize(file_path)
  local hash = util.sha256(file_path)
  if not hash then
    vim.notify(
      string.format("[project-local] Failed to compute SHA256 for: %s", file_path),
      vim.log.levels.ERROR
    )
    return false
  end
  load_store()
  sha256_cache[file_path] = hash
  save_store()
  return true
end

---Remove SHA256 trust for a file
---@param file_path string Full path to the file
function Trust.untrust_sha256(file_path)
  file_path = util.normalize(file_path)
  load_store()
  sha256_cache[file_path] = nil
  save_store()
end

-- Prompt user (async via vim.schedule) with race condition protection
---@param dir string Directory path
---@param cb function Callback function(allow: boolean)
---@param file_path string|nil Optional file path for sha256 trust option
function Trust.prompt(dir, cb, file_path)
  if not store.prompt then
    return cb(false)
  end
  
  -- Prevent multiple prompts for the same directory
  dir = util.normalize(dir)
  if prompting_in_progress[dir] then
    -- Queue callback to be called when current prompt resolves
    table.insert(prompting_in_progress[dir], cb)
    return
  end
  
  prompting_in_progress[dir] = { cb }
  
  local opts = {
    "Yes (trust directory)",
    "Yes (trust file SHA256)",
    "No (skip)",
    "Trust once (not persisted)",
  }
  vim.schedule(function()
    vim.ui.select(opts, { prompt = "Trust and load project-local config in: " .. dir .. " ?" }, function(choice)
      local allow = false
      if choice == opts[1] then
        Trust.set_trusted(dir, true)
        allow = true
      elseif choice == opts[2] then
        if file_path then
          Trust.trust_sha256(file_path)
          allow = true
        else
          vim.notify("[project-local] No file path available for SHA256 trust", vim.log.levels.WARN)
        end
      elseif choice == opts[4] then
        allow = true -- one-time trust
      end
      
      -- Call all queued callbacks
      local callbacks = prompting_in_progress[dir]
      prompting_in_progress[dir] = nil
      
      if callbacks then
        for _, callback in ipairs(callbacks) do
          callback(allow)
        end
      end
    end)
  end)
end

-- Convenience wrappers
---Mark a directory as trusted
---@param dir string Directory path
function Trust.trust(dir)
  Trust.set_trusted(dir, true)
end

---Get all trusted directories and files
---@return table { directories: table<string, boolean>, sha256: table<string, string> }
function Trust.list_trusted()
  local dirs, hashes = load_store()
  return {
    directories = vim.deepcopy(dirs),
    sha256 = vim.deepcopy(hashes),
  }
end

---Get the SHA256 hash for a trusted file (if any)
---@param file_path string Full path to the file
---@return string|nil hash The stored hash, or nil if not trusted by sha256
function Trust.get_trusted_sha256(file_path)
  file_path = util.normalize(file_path)
  local _, hashes = load_store()
  return hashes[file_path]
end

return Trust
---@class project_local.core
local M = {}

local uv = vim.loop
local Trust = require("project_local.trust")
local util = require("project_local.util")

-- Config defaults (excluding trust internals which are passed to Trust.setup)
local defaults = {
  candidates = {
    { type = "dir",  path = ".nvim",      entry = "init.lua" },
    { type = "file", path = ".nvim.lua" },
  },
  on_before_load = nil,
  on_after_load = nil,
  trust = {
    enabled = true,
    prompt = true,
    store_dir = (vim.fn.stdpath("data") .. "/project_local"),
    store_file = "trusted.json",
  },
  log_level = "info",
  cache_session = true,
}

local config = vim.deepcopy(defaults)

local log_levels = { error = 1, warn = 2, info = 3, debug = 4 }

---Log a message with a specific level
---@param level string Log level (error, warn, info, debug)
---@param msg string Message to log
local function log(level, msg)
  if not config.log_level then return end
  if log_levels[level] and log_levels[level] <= log_levels[config.log_level] then
    vim.notify("[project-local] " .. msg, vim.log.levels[string.upper(level)])
  end
end

---Validate a candidate entry
---@param c table Candidate configuration
---@param idx number Index in candidates array
---@return boolean, string|nil valid, error_message
local function validate_candidate(c, idx)
  if type(c) ~= "table" then
    return false, string.format("Candidate #%d must be a table, got %s", idx, type(c))
  end
  if c.type ~= "dir" and c.type ~= "file" then
    return false, string.format('Candidate #%d: type must be "dir" or "file", got %s', idx, tostring(c.type))
  end
  if type(c.path) ~= "string" or c.path == "" then
    return false, string.format("Candidate #%d: path must be a non-empty string", idx)
  end
  if c.type == "dir" and c.entry and type(c.entry) ~= "string" then
    return false, string.format("Candidate #%d: entry must be a string when provided", idx)
  end
  return true
end

-- Returns (exec_type, full_path, display_name) or nil
---@param root string Root directory to search
---@return string|nil, string|nil, string|nil exec_type, full_path, display_name
local function find_project_script(root)
  for _, c in ipairs(config.candidates) do
    if c.type == "dir" then
      local full_dir = util.path_join(root, c.path)
      if util.exists(full_dir) == "directory" then
        local entry = c.entry or "init.lua"
        local full_file = util.path_join(full_dir, entry)
        if util.exists(full_file) == "file" then
          return "file", full_file, c.path .. "/" .. entry
        end
      end
    elseif c.type == "file" then
      local full_file = util.path_join(root, c.path)
      if util.exists(full_file) == "file" then
        return "file", full_file, c.path
      end
    end
  end
  return nil
end

local session_loaded = {}
local active_root = nil

---Load and execute a project-local file
---@param full_path string Path to the file to load
---@return boolean success
local function load_file(full_path)
  local start = uv.hrtime()
  local chunk, err = loadfile(full_path)
  if not chunk then
    log("error", "Failed loading " .. full_path .. ": " .. err)
    return false
  end
  local ok, runtime_err = pcall(chunk)
  if not ok then
    log("error", "Runtime error in " .. full_path .. ": " .. runtime_err)
    return false
  end
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  if config.on_after_load then
    pcall(config.on_after_load, full_path, elapsed_ms)
  end
  log("info", ("Loaded %s (%.1f ms)"):format(full_path, elapsed_ms))
  return true
end

---Load project-local config for a specific directory
---@param dir string Directory path
function M.load_for_dir(dir)
  dir = util.normalize(dir)
  
  -- Check session cache
  if config.cache_session and session_loaded[dir] then
    -- Verify the cached file still exists
    local cached_file = session_loaded[dir]
    if util.exists(cached_file) == "file" then
      log("debug", "Already loaded for " .. dir)
      return
    else
      log("debug", "Cached file no longer exists: " .. cached_file)
      session_loaded[dir] = nil
    end
  end

  local kind, full_path = find_project_script(dir)
  if not kind then
    log("debug", "No project-local config found in " .. dir)
    return
  end

  if config.on_before_load then
    local proceed = true
    local ok, res = pcall(config.on_before_load, full_path)
    if ok then proceed = res ~= false end
    if not proceed then
      log("info", "Load aborted by on_before_load for " .. full_path)
      return
    end
  end

  if config.trust.enabled and not Trust.is_trusted(dir) and not Trust.is_trusted_sha256(full_path) then
    Trust.prompt(dir, function(allow)
      if allow then
        if load_file(full_path) and config.cache_session then
          session_loaded[dir] = full_path
        end
      else
        log("warn", "Denied loading project-local config in " .. dir)
      end
    end, full_path)
  else
    if load_file(full_path) and config.cache_session then
      session_loaded[dir] = full_path
    end
  end
end

---Setup the plugin with user configuration
---@param user_opts table|nil User configuration options
function M.setup(user_opts)
  if user_opts then
    -- Validate candidates if provided
    if user_opts.candidates then
      if type(user_opts.candidates) ~= "table" then
        error("config.candidates must be a table")
      end
      for idx, c in ipairs(user_opts.candidates) do
        local valid, err = validate_candidate(c, idx)
        if not valid then
          error("Invalid candidate configuration: " .. err)
        end
      end
    end
    
    config = vim.tbl_deep_extend("force", config, user_opts)
  end
  -- Initialize trust subsystem with trust config subsection
  Trust.setup(config.trust)

  vim.api.nvim_create_user_command("ProjectLocalReload", function()
    local cwd = uv.cwd()
    session_loaded[cwd] = nil
    M.load_for_dir(cwd)
  end, { desc = "Reload project-local configuration for current directory" })

  vim.api.nvim_create_user_command("ProjectLocalList", function()
    local trusted = Trust.list_trusted()
    local dirs = vim.tbl_keys(trusted.directories)
    local files = vim.tbl_keys(trusted.sha256)
    
    if #dirs == 0 and #files == 0 then
      vim.notify("[project-local] No trusted directories or files", vim.log.levels.INFO)
      return
    end
    
    local lines = {}
    
    if #dirs > 0 then
      table.sort(dirs)
      table.insert(lines, "Trusted directories:")
      for _, dir in ipairs(dirs) do
        table.insert(lines, "  " .. dir)
      end
    end
    
    if #files > 0 then
      table.sort(files)
      if #dirs > 0 then
        table.insert(lines, "")
      end
      table.insert(lines, "Trusted files (by SHA256):")
      for _, file in ipairs(files) do
        local hash = trusted.sha256[file]
        table.insert(lines, "  " .. file)
        table.insert(lines, "    sha256: " .. hash)
      end
    end
    
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "List all trusted project directories and files" })

  vim.api.nvim_create_user_command("ProjectLocalTrustSha256", function()
    local dir = uv.cwd()
    local _, file_path = find_project_script(dir)
    if not file_path then
      vim.notify("[project-local] No project config file found in " .. dir, vim.log.levels.WARN)
      return
    end
    if Trust.trust_sha256(file_path) then
      vim.notify("[project-local] Trusted by SHA256: " .. file_path, vim.log.levels.INFO)
      -- Reload after trusting
      session_loaded[dir] = nil
      M.load_for_dir(dir)
    end
  end, { desc = "Trust current project config file by its SHA256 hash" })

  vim.api.nvim_create_user_command("ProjectLocalUntrustSha256", function()
    local dir = uv.cwd()
    local _, file_path = find_project_script(dir)
    if not file_path then
      vim.notify("[project-local] No project config file found in " .. dir, vim.log.levels.WARN)
      return
    end
    Trust.untrust_sha256(file_path)
    vim.notify("[project-local] Removed SHA256 trust for: " .. file_path, vim.log.levels.INFO)
  end, { desc = "Remove SHA256 trust for current project config file" })

  vim.api.nvim_create_augroup("ProjectLocal", { clear = true })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = "ProjectLocal",
    callback = function(ev)
      local cwd = ev.file
      active_root = cwd
      M.load_for_dir(cwd)
    end,
    desc = "Load project-local config on directory change",
  })

  -- Initial load (scheduled to avoid interfering with startup sequence)
  vim.schedule(function()
    local cwd = uv.cwd()
    active_root = cwd
    M.load_for_dir(cwd)
  end)
end

-- Public helpers

---Get the currently active project root
---@return string|nil
function M.get_active_root()
  return active_root
end

---Check if a directory is trusted
---@param dir string|nil Directory path (defaults to active root or cwd)
---@return boolean
function M.is_trusted(dir)
  dir = dir or active_root or uv.cwd()
  return Trust.is_trusted(dir)
end

---Mark a directory as trusted
---@param dir string|nil Directory path (defaults to active root or cwd)
function M.trust(dir)
  dir = dir or active_root or uv.cwd()
  Trust.trust(dir)
end

---Remove trust for a directory
---@param dir string|nil Directory path (defaults to active root or cwd)
function M.untrust(dir)
  dir = dir or active_root or uv.cwd()
  Trust.untrust(dir)
end

---Get all trusted directories
---@return table { directories: table<string, boolean>, sha256: table<string, string> }
function M.list_trusted()
  return Trust.list_trusted()
end

---Trust a file by its SHA256 hash
---@param file_path string|nil File path (defaults to current project's config file)
---@return boolean success
function M.trust_sha256(file_path)
  if not file_path then
    local dir = active_root or uv.cwd()
    local _, found_path = find_project_script(dir)
    if not found_path then
      vim.notify("[project-local] No project config file found in " .. dir, vim.log.levels.WARN)
      return false
    end
    file_path = found_path
  end
  return Trust.trust_sha256(file_path)
end

---Remove SHA256 trust for a file
---@param file_path string|nil File path (defaults to current project's config file)
function M.untrust_sha256(file_path)
  if not file_path then
    local dir = active_root or uv.cwd()
    local _, found_path = find_project_script(dir)
    if not found_path then
      vim.notify("[project-local] No project config file found in " .. dir, vim.log.levels.WARN)
      return
    end
    file_path = found_path
  end
  Trust.untrust_sha256(file_path)
end

---Check if a file is trusted by its SHA256 hash
---@param file_path string|nil File path (defaults to current project's config file)
---@return boolean
function M.is_trusted_sha256(file_path)
  if not file_path then
    local dir = active_root or uv.cwd()
    local _, found_path = find_project_script(dir)
    if not found_path then
      return false
    end
    file_path = found_path
  end
  return Trust.is_trusted_sha256(file_path)
end

return M
-- Entry point loaded by Neovim at startup if on runtimepath.
if vim.g.loaded_project_local then
  return
end
vim.g.loaded_project_local = true

local ok, mod = pcall(require, "project_local")
if not ok then
  vim.notify("[project-local] failed to require module: " .. tostring(mod), vim.log.levels.ERROR)
  return
end

-- Auto-setup with defaults if user hasn't configured it yet
-- Users can call setup() earlier in their init.lua to customize before this runs
if not vim.g.project_local_configured then
  mod.setup()
  vim.g.project_local_configured = true
end

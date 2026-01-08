# project-local.nvim

Execute per-project Lua when you `:cd`, open a file that triggers a root change, or otherwise change Neovim’s working directory.  
It looks for a local project configuration (`.nvim/init.lua` or `.nvim.lua`) in the project root and sources it (optionally gated by a trust prompt so you don’t unknowingly execute arbitrary code from untrusted repositories).

---

## Features

- Automatic detection on:
  - Startup (initial `cwd`)
  - `DirChanged` events (e.g. `:cd`, `:tcd`, `:lcd`, plugins that alter cwd)
- Two default patterns (processed in order, first match wins):
  1. `.nvim/init.lua` (directory style)
  2. `.nvim.lua` (single-file style)
- Trust system (persisted JSON) with selectable prompt
- Session cache to avoid re-running the same project config repeatedly
- Hooks: `on_before_load`, `on_after_load`
- Commands: `:ProjectLocalReload`, `:ProjectLocalList`
- Helper API for managing trust programmatically

---

## Why?

Different projects often need slightly different editor behavior:

- Add temporary runtimepaths
- Define local build/test commands
- Set buffer or global options (indent width, diagnostics tweaks)
- Inject project-specific tooling (e.g. local linters) without polluting a global config

---

## Security Warning

Project-local code is arbitrary Lua executed in your Neovim instance.  
Enable and keep the trust prompt unless:
- You fully control / audit all repositories you open, or
- You deliberately want “just run it” behavior.

You can always revoke trust via deleting the trust store file or calling the API.

---

## Installation

### Using lazy.nvim (Recommended)

Below are several patterns you can choose from depending on how you prefer to declare plugins in [lazy.nvim](https://github.com/folke/lazy.nvim).

#### 1. Minimal (Auto-Setup With Defaults)

```lua
{
  "stykki/project-local.nvim",
  -- If you put setup inside plugin/project_local.lua you can omit config.
  config = function()
    require("project_local.core").setup()
  end,
}
```

#### 2. Using `opts` (Cleaner Pattern in Lazy)

If you change `core.lua` to export `setup` the same, you can let lazy.nvim inject `opts`:

```lua
{
  "stykki/project-local.nvim",
  opts = {
    log_level = "warn",
    trust = { enabled = true, prompt = true },
  },
  config = function(_, opts)
    require("project_local.core").setup(opts)
  end,
}
```

#### 3. Add Lazy-Loading Conditions

(Strictly speaking this plugin benefits from loading early, but you can still gate it.)

```lua
{
  "stykki/project-local.nvim",
  event = { "VimEnter" },   -- or very early: "User VeryLazy" if you prefer after core
  priority = 60,            -- lower numbers = loads earlier in lazy.nvim
  opts = {
    log_level = "info",
  },
  config = function(_, opts)
    require("project_local.core").setup(opts)
  end,
}
```

#### 4. Advanced Customization

```lua
{
  "stykki/project-local.nvim",
  priority = 100,   -- lower numbers = loads earlier in lazy.nvim
  opts = {
    candidates = {
      { type = "dir",  path = ".nvim",      entry = "init.lua" },
      { type = "file", path = ".nvim.lua" },
      -- Additional patterns:
      { type = "file", path = ".nvimrc.lua" },
    },
    trust = {
      enabled = true,
      prompt = true,
      -- Optionally override store location:
      store_dir = vim.fn.stdpath("data") .. "/project_local",
      store_file = "trusted.json",
    },
    log_level = "debug", -- debug / info / warn / error / nil
    cache_session = true,
    on_before_load = function(full_path)
      -- Return false to block execution
      vim.notify("[project-local] About to load " .. full_path)
      return true
    end,
    on_after_load = function(full_path, ms)
      vim.notify(("[project-local] Loaded %s in %.1f ms"):format(full_path, ms))
    end,
  },
  config = function(_, opts)
    require("project_local.core").setup(opts)
  end,
}
```

#### 5. Local Development (Using `dev` / local path)

If you are hacking on the plugin itself inside (for example) `~/code/project-local.nvim`:

```lua
{
  dir = "~/code/project-local.nvim",
  name = "project-local.nvim",
  dev = true, -- optional if you configured lazy’s dev path
  config = function()
    require("project_local.core").setup({
      log_level = "debug",
    })
  end,
}
```

#### 6. Conditional Enabling (e.g., disable in remote environments)

```lua
{
  "stykki/project-local.nvim",
  enabled = function()
    return not vim.env.SSH_CONNECTION  -- skip when over SSH
  end,
  opts = {
    trust = { enabled = true, prompt = true },
  },
  config = function(_, opts)
    require("project_local.core").setup(opts)
  end,
}
```

#### 7. Interacting With Other Plugins After Load

If you want project-local config to possibly adjust LSP settings before servers attach, load it early with a lower priority number in lazy.nvim (lower = earlier):

Example:

```lua
{
  "stykki/project-local.nvim",
  priority = 120,  -- lower number = loads earlier
  config = function()
    require("project_local.core").setup({
      on_after_load = function()
        -- Example: maybe re-run something that depends on a variable set by project config
        -- require("my-lsp-wrapper").refresh()
      end,
    })
  end,
}
```

---

### Using packer.nvim

```lua
use {
  "stykki/project-local.nvim",
  config = function()
    require("project_local.core").setup()
  end,
}
```

### Manual / Runtimepath Drop-In

Copy the `lua/project_local/` directory and the `plugin/project_local.lua` file into a directory already on `runtimepath`.  
(Example: your `~/.config/nvim/` if you vendor it within your dotfiles.)

---

## Basic Usage

Create a project-level config:

```
my-project/
  .nvim/
    init.lua
```

`init.lua` example:

```lua
-- Project-specific Neovim tweaks
vim.bo.shiftwidth = 2
vim.g.my_project_root = vim.loop.cwd()

-- Extend runtimepath (e.g. so you can require modules under .nvim/lua)
vim.opt.runtimepath:append(vim.loop.cwd() .. "/.nvim")

-- Define a custom project command
vim.api.nvim_create_user_command("BuildProject", function()
  vim.cmd("!make -j8")
end, {})
```

Or single-file style:

```
my-project/
  .nvim.lua
```

---

## Trust Model

The plugin supports two trust modes:

1. **Directory trust** - Trusts all config files in a directory (traditional approach)
2. **SHA256 trust** - Trusts a specific file by its content hash (more secure)

### Trust Prompt

First time in a directory with project-local config:
- A `vim.ui.select` prompt offers:
  - Yes (trust directory) — permanently trust all configs in this directory
  - Yes (trust file SHA256) — trust only this specific file content
  - No (skip)
  - Trust once (run this session only)

### Directory Trust

Trusts the directory path. Any config file in that directory will be executed. Simple but less secure if the file content changes.

### SHA256 Trust

Trusts the specific file content by storing its SHA256 hash. If the file is modified, trust is invalidated and you'll be prompted again. This is more secure as it ensures only the exact code you reviewed will run.

Store location (default):
```
:echo stdpath('data') .. '/project_local/trusted.json'
```

Disable prompting but keep trust (auto-run only trusted directories — untrusted are silently skipped):
```lua
trust = { enabled = true, prompt = false }
```

Disable trust entire system (always run):
```lua
trust = { enabled = false }
```

Revoke trust:
```lua
-- Remove directory trust
require("project_local").untrust("/absolute/path/to/project")

-- Remove SHA256 trust
require("project_local").untrust_sha256("/absolute/path/to/project/.nvim.lua")

-- or delete the JSON file
```

---

## API

```lua
local project_local = require("project_local.core")

project_local.setup({
  candidates = {
    { type = "dir",  path = ".nvim", entry = "init.lua" },
    { type = "file", path = ".nvim.lua" },
  },
  on_before_load = function(full_path)
    return true -- false to abort
  end,
  on_after_load = function(full_path, elapsed_ms)
    vim.notify(("Loaded %s in %.2f ms"):format(full_path, elapsed_ms))
  end,
  trust = {
    enabled = true,
    prompt = true,
  },
  log_level = "info",
  cache_session = true,
})
```

Helpers:

| Function | Description |
|----------|-------------|
| `get_active_root()` | Returns the last directory that was processed. |
| `is_trusted(dir?)` | Whether a directory is trusted. Defaults to active root. |
| `trust(dir?)` | Mark directory trusted. |
| `untrust(dir?)` | Remove trust entry. |
| `is_trusted_sha256(file?)` | Whether a file is trusted by SHA256. Defaults to current project config. |
| `trust_sha256(file?)` | Trust a file by its SHA256 hash. |
| `untrust_sha256(file?)` | Remove SHA256 trust for a file. |
| `load_for_dir(dir)` | Manually trigger load logic for any path. |
| `list_trusted()` | Get all trusted directories and SHA256-trusted files. |

---

## Commands

| Command | Description |
|---------|-------------|
| `:ProjectLocalReload` | Clears session cache for current `cwd` and re-runs detection (will re-prompt if not trusted). |
| `:ProjectLocalList` | List all trusted project directories and SHA256-trusted files. |
| `:ProjectLocalTrustSha256` | Trust the current project config file by its SHA256 hash. |
| `:ProjectLocalUntrustSha256` | Remove SHA256 trust for the current project config file. |

---

## Extending

Add extra patterns (patterns are checked in order; first match wins):

```lua
candidates = {
  { type = "dir",  path = ".nvim", entry = "init.lua" },
  { type = "file", path = ".nvim.lua" },
  { type = "file", path = ".nvimrc.lua" },
}
```

Load supplemental plugin definitions after the main file:

**⚠️ Security Warning**: Using `dofile()` or `loadfile()` in hooks bypasses the trust system. Ensure you trust the source of any additional files you load, or implement your own trust checks.

```lua
on_after_load = function(root_file)
  local root_dir = vim.fn.fnamemodify(root_file, ":h")
  local extra = root_dir .. "/plugins.lua"
  if vim.loop.fs_stat(extra) then
    -- Warning: This bypasses trust checks! Only do this if you trust the project.
    dofile(extra)
  end
end
```

---

## Troubleshooting

| Symptom | Possible Cause | Fix |
|---------|----------------|-----|
| “Nothing loads” | Wrong file path or pattern order | Enable `log_level = "debug"` and check messages |
| Repeated prompts | Trust store not writable | Check `:echo stdpath('data')` permissions |
| Need to re-run after editing `.nvim/init.lua` | Session cache holds old version | `:ProjectLocalReload` or set `cache_session = false` |
| Unexpected settings linger after leaving project | Those settings are global | Use buffer-local options or write a teardown in another hook |

Enable verbose logging:

```lua
require("project_local.core").setup({ log_level = "debug" })
```

---

## Security Considerations

- Always inspect `.nvim` (or `.nvim.lua`) in new repositories before trusting.
- Avoid cloning random code and opening it with trust prompts disabled.
- Consider version controlling `.nvim/` to audit changes in PRs.
- **Prefer SHA256 trust** when working with repositories where the config file may change unexpectedly (e.g., shared repos, open source projects). This ensures you only run code you've explicitly reviewed.

---

## Roadmap Ideas (Feel Free to PR)

- Optional root detection via git/mercurial markers above `cwd`
- Integration with a notification history window
- Plenary tests & CI example

---

## License

MIT (see LICENSE)

---

## Quick Start (Inline)

```lua
-- Early in your main init
require("project_local.core").setup({
  log_level = "warn",
})
```

Open a project with a `.nvim/init.lua` and confirm the trust prompt.

Happy hacking!

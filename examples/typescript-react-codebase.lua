-------------------------------------------------------------------------------
-- Example: TypeScript React Project Configuration
-------------------------------------------------------------------------------
--
-- This is an example project-local configuration for a TypeScript React
-- codebase. It provides commands for type checking and linting that integrate
-- with Neovim's quickfix list.
--
-------------------------------------------------------------------------------
-- INSTALLATION
-------------------------------------------------------------------------------
--
-- To use this configuration in your TypeScript React project:
--
-- Option 1: Single file style
--   Copy this file to your project root as `.nvim.lua`:
--     cp examples/typescript-react-codebase.lua /path/to/your/project/.nvim.lua
--
-- Option 2: Directory style
--   Create a `.nvim` directory and copy as `init.lua`:
--     mkdir /path/to/your/project/.nvim
--     cp examples/typescript-react-codebase.lua /path/to/your/project/.nvim/init.lua
--
-- Then open your project in Neovim:
--   cd /path/to/your/project
--   nvim .
--
-- You will be prompted to trust the project configuration.
-- Select "Yes (trust directory)" or "Yes (trust file SHA256)" to enable.
--
-------------------------------------------------------------------------------
-- REQUIREMENTS
-------------------------------------------------------------------------------
--
-- - Node.js and yarn installed
-- - TypeScript installed in your project (yarn add -D typescript)
-- - ESLint installed in your project (yarn add -D eslint)
-- - A tsconfig.json file in your project root
--
-------------------------------------------------------------------------------
-- COMMANDS
-------------------------------------------------------------------------------
--
-- :CheckTypes
--     Run TypeScript type checking on the entire project.
--     Executes: yarn tsc --noEmit
--     Results are populated in the quickfix list.
--     Opens quickfix automatically if errors are found.
--
--     Usage:
--       :CheckTypes
--       :copen          " Open quickfix if not auto-opened
--       :cnext          " Jump to next error
--       :cprev          " Jump to previous error
--
-- :Eslint
--     Run ESLint on all TypeScript/TSX files in src/ and targets/ directories.
--     Executes: yarn eslint --cache --quiet --format unix 'src/**/*.ts' ...
--     Results are populated in the quickfix list.
--     Opens quickfix automatically if errors are found.
--
--     Usage:
--       :Eslint
--       :copen          " Open quickfix if not auto-opened
--       :cnext          " Jump to next error
--
-- :EslintFile
--     Run ESLint on the current file only.
--     Useful for quick checks without linting the entire project.
--
--     Usage:
--       :EslintFile     " Lint current buffer
--
-------------------------------------------------------------------------------
-- CUSTOMIZATION
-------------------------------------------------------------------------------
--
-- You may want to adjust the following for your project:
--
-- 1. ESLint file patterns in :Eslint command (line ~68):
--    Change 'src/**/*.ts' etc. to match your project structure
--
-- 2. Add keymaps for quick access:
--    vim.keymap.set("n", "<leader>tc", "<cmd>CheckTypes<cr>", { desc = "Type check" })
--    vim.keymap.set("n", "<leader>el", "<cmd>Eslint<cr>", { desc = "ESLint project" })
--    vim.keymap.set("n", "<leader>ef", "<cmd>EslintFile<cr>", { desc = "ESLint file" })
--
-------------------------------------------------------------------------------

-- Project-local Neovim configuration for a Typescript React codebase

-- Convert TypeScript error format to quickfix format
-- From: file(line,col): error TS1234: message
-- To:   file:line:col: error TS1234: message
local function convert_tsc_to_quickfix(line)
	-- Match: path(line,col): error/warning message
	local file, lnum, col, rest = line:match("^(.-)%((%d+),(%d+)%):%s*(.*)$")
	if file and lnum and col then
		return string.format("%s:%s:%s: %s", file, lnum, col, rest)
	end
	return line
end

-- Check TypeScript types and add results to quickfix
vim.api.nvim_create_user_command("CheckTypes", function()
	vim.fn.setqflist({}, "r", { title = "TypeScript Type Check" })

	local cmd = "yarn tsc --noEmit --forceConsistentCasingInFileNames 2>&1"
	local collected_lines = {}

	vim.notify("Running type check...", vim.log.levels.INFO)

	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(collected_lines, convert_tsc_to_quickfix(line))
					end
				end
			end
		end,
		on_stderr = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(collected_lines, convert_tsc_to_quickfix(line))
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			vim.schedule(function()
				if #collected_lines > 0 then
					vim.fn.setqflist({}, "a", { lines = collected_lines })
				end
				if exit_code == 0 then
					vim.notify("Type check passed!", vim.log.levels.INFO)
				else
					vim.notify("Type check failed. See quickfix for errors.", vim.log.levels.WARN)
					vim.cmd("copen")
				end
			end)
		end,
	})
end, { desc = "Run TypeScript type check and populate quickfix" })

-- Run ESLint and add errors to quickfix
vim.api.nvim_create_user_command("Eslint", function()
	vim.cmd("cexpr []") -- Clear quickfix
	vim.fn.setqflist({}, "r", { title = "ESLint" })

	-- Use eslint with unix formatter for easy quickfix parsing
	local cmd =
		"yarn eslint --cache --quiet --format unix 'src/**/*.ts' 'src/**/*.tsx' 'targets/**/*.ts' 'targets/**/*.tsx' 2>&1"

	vim.notify("Running ESLint...", vim.log.levels.INFO)

	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				local lines = vim.tbl_filter(function(line)
					return line ~= ""
				end, data)
				if #lines > 0 then
					vim.fn.setqflist({}, "a", { lines = lines })
				end
			end
		end,
		on_stderr = function(_, data)
			if data then
				local lines = vim.tbl_filter(function(line)
					return line ~= ""
				end, data)
				if #lines > 0 then
					vim.fn.setqflist({}, "a", { lines = lines })
				end
			end
		end,
		on_exit = function(_, exit_code)
			vim.schedule(function()
				if exit_code == 0 then
					vim.notify("ESLint passed!", vim.log.levels.INFO)
				else
					vim.notify("ESLint found errors. See quickfix.", vim.log.levels.WARN)
					vim.cmd("copen")
				end
			end)
		end,
	})
end, { desc = "Run ESLint and populate quickfix with errors" })

-- Run ESLint on current file only
vim.api.nvim_create_user_command("EslintFile", function()
	vim.cmd("cexpr []") -- Clear quickfix
	vim.fn.setqflist({}, "r", { title = "ESLint (current file)" })

	local file = vim.fn.expand("%:p")
	local cmd = string.format("yarn eslint --format unix '%s' 2>&1", file)

	vim.notify("Running ESLint on current file...", vim.log.levels.INFO)

	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				local lines = vim.tbl_filter(function(line)
					return line ~= ""
				end, data)
				if #lines > 0 then
					vim.fn.setqflist({}, "a", { lines = lines })
				end
			end
		end,
		on_stderr = function(_, data)
			if data then
				local lines = vim.tbl_filter(function(line)
					return line ~= ""
				end, data)
				if #lines > 0 then
					vim.fn.setqflist({}, "a", { lines = lines })
				end
			end
		end,
		on_exit = function(_, exit_code)
			vim.schedule(function()
				if exit_code == 0 then
					vim.notify("ESLint passed!", vim.log.levels.INFO)
				else
					vim.notify("ESLint found errors. See quickfix.", vim.log.levels.WARN)
					vim.cmd("copen")
				end
			end)
		end,
	})
end, { desc = "Run ESLint on current file and populate quickfix" })

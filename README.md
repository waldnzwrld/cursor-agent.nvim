## Cursor Agent Neovim Plugin 

A minimal Neovim plugin to run the Cursor Agent CLI inside a terminal window. Toggle an interactive terminal at your project root, or send the current buffer or a visual selection to Cursor Agent. Supports both floating window and sidebar modes.

### Requirements
- **Cursor Agent CLI**: `cursor-agent` available on your `$PATH`

## Installation

### lazy.nvim
```lua
{
  "testing/cursor-agent.nvim",
  config = function()
    vim.keymap.set("n", "<leader>ca", ":CursorAgent<CR>", { desc = "Cursor Agent: Toggle terminal" })
    vim.keymap.set("v", "<leader>ca", ":CursorAgentSelection<CR>", { desc = "Cursor Agent: Send selection" })
    vim.keymap.set("n", "<leader>cA", ":CursorAgentBuffer<CR>", { desc = "Cursor Agent: Send buffer" })
  end,
}
```

### packer.nvim
```lua
use({
  "testing/cursor-agent.nvim",
  config = function()
    require("cursor-agent").setup({})
  end,
})
```

### vim-plug
```vim
Plug 'testing/cursor-agent.nvim'
```
Then in your `init.lua`:
```lua
require("cursor-agent").setup({})
```

Note: The plugin auto-initializes with defaults on load (via `after/plugin/cursor-agent.lua`). Calling `setup()` yourself lets you override defaults.

## Quickstart

- Run `:CursorAgent` to toggle an interactive terminal in your project root. Type directly into the `cursor-agent` program.
- Visually select code, then use `:CursorAgentSelection` to ask about just that selection.
- Run `:CursorAgentBuffer` to send the entire current buffer (handy for files like `cursor.md`).
- Press `q` in normal mode to close the terminal or run `:CursorAgent` / `<leader>ca` to toggle it away.

By default, interactions happen in a centered floating window. You can configure the plugin to use an attached sidebar instead (see Configuration section).

## Commands

- **:CursorAgent**: Toggle the interactive Cursor Agent terminal (project root). Uses your configured window mode.
- **:CursorAgentSelection**: Send the current visual selection (writes to a temp file and opens terminal rendering).
- **:CursorAgentBuffer**: Send the full current buffer (writes to a temp file and opens terminal rendering).
- **:CursorAgentReload**: Manually check all buffers for external changes and reload them.
- **:CursorAgentAutoReload [on|off]**: Enable, disable, or toggle automatic buffer reloading.

### Window Mode Behavior

#### Floating Mode (default)
- Opens a centered floating window
- Title bar shows "Cursor Agent"  
- Rounded borders
- Press `q` in normal mode to close

#### Attached Mode (Sidebar)
- Opens as a vertical split
- Can be positioned on left or right side
- Configurable width as fraction of screen (e.g., 0.2 = 20%)
- Press `q` in normal mode to close
- Window integrates with your existing split layout

## Configuration

Only set what you need. For typical usage, `cmd` and `args` are enough.

### Basic Configuration
```lua
require("cursor-agent").setup({
  -- Executable or argv table. Example: "cursor-agent" or {"/usr/local/bin/cursor-agent"}
  cmd = "cursor-agent",
  -- Additional arguments always passed to the CLI
  args = {},
})
```

### Window Mode Configuration

The plugin supports two window modes: floating (default) and attached (sidebar).

#### Default Configuration (Floating Window)
```lua
require("cursor-agent").setup({
  -- Default behavior - opens in floating window
  window_mode = "floating",  -- or omit this line for default
})
```

#### Attached Mode (Sidebar) - Right Side
```lua
require("cursor-agent").setup({
  window_mode = "attached",
  position = "right",        -- Opens on right side
  width = 0.2,              -- 1/5 of screen width
})
```

#### Attached Mode (Sidebar) - Left Side  
```lua
require("cursor-agent").setup({
  window_mode = "attached",
  position = "left",         -- Opens on left side
  width = 0.25,             -- 1/4 of screen width
})
```

### Complete Configuration Example
```lua
require("cursor-agent").setup({
  -- Standard options
  cmd = "cursor-agent",
  args = {},
  use_stdin = true,
  multi_instance = false,
  timeout_ms = 60000,
  auto_scroll = true,
  
  -- Window mode options
  window_mode = "attached",   -- Use split window instead of floating
  position = "right",         -- Position on right side
  width = 0.2,               -- Use 1/5 of screen width (20%)
  
  -- Auto-reload buffers when Cursor modifies files
  auto_reload = true,         -- Enabled by default
})
```

### Auto-Reload Feature

When `auto_reload = true` (the default), buffers are automatically reloaded when Cursor CLI modifies files on disk. This ensures your editor always shows the latest content without manual intervention.

How it works:
- **File watchers**: Uses libuv file system events to detect changes in real-time
- **Focus-based checks**: Runs `:checktime` when leaving the terminal window or when Neovim gains focus  
- **Safe reloading**: Buffers with unsaved changes are never automatically reloaded

You can control this feature with:
```vim
:CursorAgentAutoReload on    " Enable auto-reload
:CursorAgentAutoReload off   " Disable auto-reload
:CursorAgentAutoReload       " Toggle auto-reload
:CursorAgentReload           " Manually check all buffers for changes
```

### Advanced Options
For lower-level CLI helpers present in the codebase but not required for terminal mode:
```lua
require("cursor-agent").setup({
  -- Whether to send content via stdin when using non-terminal helpers
  use_stdin = true,
  -- Reserved for future concurrency control
  multi_instance = false,
  -- Timeout for non-streaming helpers (ms)
  timeout_ms = 60000,
  -- Auto-scroll behavior for certain UI helpers
  auto_scroll = true,
})
```

### Examples

- Use an absolute path for the CLI:
```lua
require("cursor-agent").setup({ cmd = "/usr/local/bin/cursor-agent" })
```

## Suggested keymaps

```lua
-- Toggle the interactive terminal
vim.keymap.set("n", "<leader>ca", ":CursorAgent<CR>", { desc = "Cursor Agent: Toggle terminal" })

-- Ask about the visual selection
vim.keymap.set("v", "<leader>ca", ":CursorAgentSelection<CR>", { desc = "Cursor Agent: Send selection" })

-- Ask about the current buffer
vim.keymap.set("n", "<leader>cA", ":CursorAgentBuffer<CR>", { desc = "Cursor Agent: Send buffer" })
```

## Programmatic usage

You can call the API directly if you prefer:
```lua
-- Launch a one-off run passing a prompt as argv (opens a floating terminal)
require("cursor-agent").ask({ prompt = "How can I refactor this function?" })
```
This opens a floating terminal using `termopen`, with the working directory set to the detected project root.

## Troubleshooting

- **CLI not found**: Ensure `cursor-agent` is on your `$PATH`.
- **No output appears**: Verify your CLI installation by running it in a normal terminal.
- **Wrong directory**: The terminal starts in your project root (LSP root if available, otherwise common markers like `.git`).

## How it works

- A terminal window is created with `termopen`, ready for immediate input. Window mode depends on your configuration:
  - **Floating mode**: Creates a centered floating window with rounded borders
  - **Attached mode**: Creates a vertical split positioned on the left or right side
- The terminal starts in the detected project root so Cursor Agent has the right context.
- For selection/buffer commands, the text is written to a temporary file and its path is passed to the CLI as a positional argument.

## Contributing

Contributions are welcome! If you have ideas or improvements, please open an issue or submit a PR.

## Acknowledgements

- Cursor Agent CLI by Cursor - This plugin was build entirely using GPT-5 in Cursor Agent CLI. Development cost: $0.45 with 10m 34s of API time.

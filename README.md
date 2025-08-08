## Cursor Agent Neovim Plugin 

A minimal Neovim plugin to run the Cursor Agent CLI inside a centered floating terminal. Toggle an interactive terminal at your project root, or send the current buffer or a visual selection to Cursor Agent.

### Requirements
- **Cursor Agent CLI**: `cursor-agent` available on your `$PATH`

## Installation

### lazy.nvim
```lua
{
  "xTacobaco/cursor-agent.nvim",
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
  "xTacobaco/cursor-agent.nvim",
  config = function()
    require("cursor-agent").setup({})
  end,
})
```

### vim-plug
```vim
Plug 'xTacobaco/cursor-agent.nvim'
```
Then in your `init.lua`:
```lua
require("cursor-agent").setup({})
```

Note: The plugin auto-initializes with defaults on load (via `after/plugin/cursor-agent.lua`). Calling `setup()` yourself lets you override defaults.

## Quickstart

- Run `:CursorAgent` to toggle an interactive floating terminal in your project root. Type directly into the `cursor-agent` program.
- Visually select code, then use `:CursorAgentSelection` to ask about just that selection.
- Run `:CursorAgentBuffer` to send the entire current buffer (handy for files like `cursor.md`).
- Press `q` in normal mode in the floating terminal to close it or run :CursorAgent `<leader>ca` to toggle it away.

All interactions happen in a centered floating terminal.

## Commands

- **:CursorAgent**: Toggle the interactive Cursor Agent terminal (project root).
- **:CursorAgentSelection**: Send the current visual selection (writes to a temp file and opens terminal rendering).
- **:CursorAgentBuffer**: Send the full current buffer (writes to a temp file and opens terminal rendering).

## Configuration

Only set what you need. For typical usage, `cmd` and `args` are enough.
```lua
require("cursor-agent").setup({
  -- Executable or argv table. Example: "cursor-agent" or {"/usr/local/bin/cursor-agent"}
  cmd = "cursor-agent",
  -- Additional arguments always passed to the CLI
  args = {},
})
```

Advanced (for lower-level CLI helpers present in the codebase but not required for terminal mode):
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

- A floating terminal is created with `termopen`, centered, wrapped, and ready for immediate input.
- The terminal starts in the detected project root so Cursor Agent has the right context.
- For selection/buffer commands, the text is written to a temporary file and its path is passed to the CLI as a positional argument.

## Contributing

Contributions are welcome! If you have ideas or improvements, please open an issue or submit a PR.

## Acknowledgements

- Cursor Agent CLI by Cursor - This plugin was build entirely using GPT-5 in Cursor Agent CLI. Development cost: $0.45 with 10m 34s of API time.

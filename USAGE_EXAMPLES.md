# Cursor Agent Window Mode Configuration Examples

This document provides examples of how to configure the cursor-agent.nvim plugin with the new window mode options.

## Default Configuration (Floating Window)

```lua
require('cursor-agent').setup({
  -- Default behavior - opens in floating window
  window_mode = "floating",  -- or omit this line for default
})
```

## Attached Mode (Split Window) - Right Side

```lua
require('cursor-agent').setup({
  window_mode = "attached",
  position = "right",        -- Opens on right side
  width = 0.2,              -- 1/5 of screen width
})
```

## Attached Mode (Split Window) - Left Side  

```lua
require('cursor-agent').setup({
  window_mode = "attached",
  position = "left",         -- Opens on left side
  width = 0.25,             -- 1/4 of screen width
})
```

## Mixed Configuration with Other Options

```lua
require('cursor-agent').setup({
  -- Standard options
  cmd = "cursor-agent",
  args = {},
  use_stdin = true,
  multi_instance = false,
  timeout_ms = 60000,
  auto_scroll = true,
  
  -- New window mode options
  window_mode = "attached",   -- Use split window instead of floating
  position = "right",         -- Position on right side
  width = 0.2,               -- Use 1/5 of screen width (20%)
})
```

## Usage

Once configured, use the commands as normal:

- `:CursorAgent` - Toggle the interactive terminal (will use your configured window mode)
- `:CursorAgentSelection` - Send visual selection to Cursor Agent
- `:CursorAgentBuffer` - Send entire buffer to Cursor Agent

Or use the default keymap:
- `<leader>ca` - Toggle Cursor Agent terminal

## Window Mode Behavior

### Floating Mode (default)
- Opens a centered floating window
- Title bar shows "Cursor Agent"
- Rounded borders
- Press `q` to close

### Attached Mode  
- Opens as a vertical split
- Can be positioned on left or right side
- Configurable width as fraction of screen (e.g., 0.2 = 20%)
- Press `q` to close
- Window integrates with your existing split layout
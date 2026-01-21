# Cursor Agent MCP Server

Pure Lua MCP server for deeper Neovim/Cursor integration. **Zero manual configuration required.**

## How it works

When you call `require('cursor-agent').setup()`, the plugin automatically:
1. Locates the MCP server (`mcp/server.lua`)
2. Adds it to `~/.cursor/mcp.json`
3. Future cursor-cli sessions can use the MCP tools

```
Plugin setup → auto-configures ~/.cursor/mcp.json
                        ↓
cursor-cli starts → loads MCP server → connects back to Neovim via $NVIM
                        ↓
AI can call nvim_save_baseline, nvim_notify_change, etc.
```

## Requirements

- Run cursor-cli from Neovim's `:terminal` (so `$NVIM` is set)
- That's it

## Available Tools

| Tool | Description |
|------|-------------|
| `nvim_save_baseline` | Save file state before changes |
| `nvim_notify_change` | Notify of changes with line info |
| `nvim_get_open_buffers` | List open files |
| `nvim_reload_buffer` | Trigger reload |
| `nvim_clear_highlights` | Clear highlights |

## Cross-platform

The plugin handles path resolution for:
- macOS/Darwin
- Linux/*nix/BSD
- Windows

## Technical Details

- MCP server is pure Lua, runs via `nvim --headless -l server.lua`
- Uses Neovim's built-in Lua runtime (vim.json, vim.fn.sockconnect)
- Connects to running Neovim via `$NVIM` socket
- No Python, no pip, no external dependencies

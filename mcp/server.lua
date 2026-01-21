#!/usr/bin/env -S nvim -l
-- MCP Server for Neovim integration with Cursor
-- Pure Lua, runs via: nvim --headless -l server.lua
--
-- No external dependencies - uses Neovim's built-in Lua runtime

local M = {}

-- Connection to the main Neovim instance
M.nvim_channel = nil

-- ============================================================================
-- Neovim RPC Connection
-- ============================================================================

---Connect to the running Neovim instance via $NVIM socket
---@return boolean success
function M.connect_to_nvim()
  local nvim_socket = os.getenv('NVIM')
  if not nvim_socket or nvim_socket == '' then
    M.log_error('$NVIM environment variable not set. Run from Neovim terminal.')
    return false
  end

  local ok, channel = pcall(vim.fn.sockconnect, 'pipe', nvim_socket, { rpc = true })
  if not ok or not channel or channel == 0 then
    M.log_error('Failed to connect to Neovim at: ' .. nvim_socket)
    return false
  end

  M.nvim_channel = channel
  M.log_info('Connected to Neovim')
  return true
end

---Call a function in the main Neovim instance
---@param fn string Vim function or Lua code
---@param ... any Arguments
---@return any result
function M.nvim_call(fn, ...)
  if not M.nvim_channel then
    return nil
  end
  local ok, result = pcall(vim.fn.rpcrequest, M.nvim_channel, 'nvim_call_function', fn, { ... })
  if not ok then
    M.log_error('RPC call failed: ' .. tostring(result))
    return nil
  end
  return result
end

---Execute Lua code in the main Neovim instance
---@param code string Lua code
---@param ... any Arguments (accessible as ... in the code)
---@return any result
function M.nvim_exec_lua(code, ...)
  if not M.nvim_channel then
    return nil
  end
  local args = { ... }
  local ok, result = pcall(vim.fn.rpcrequest, M.nvim_channel, 'nvim_exec_lua', code, args)
  if not ok then
    M.log_error('Lua exec failed: ' .. tostring(result))
    return nil
  end
  return result
end

-- ============================================================================
-- Logging (to stderr, visible in Cursor MCP logs)
-- ============================================================================

function M.log_error(msg)
  io.stderr:write('[cursor-agent-mcp] ERROR: ' .. msg .. '\n')
  io.stderr:flush()
end

function M.log_info(msg)
  io.stderr:write('[cursor-agent-mcp] ' .. msg .. '\n')
  io.stderr:flush()
end

-- ============================================================================
-- JSON-RPC over stdio
-- ============================================================================

function M.send_response(id, result, error)
  local response = { jsonrpc = '2.0', id = id }
  if error then
    response.error = error
  else
    response.result = result
  end
  local json = vim.json.encode(response)
  io.stdout:write(json .. '\n')
  io.stdout:flush()
end

function M.send_notification(method, params)
  local notification = { jsonrpc = '2.0', method = method }
  if params then
    notification.params = params
  end
  local json = vim.json.encode(notification)
  io.stdout:write(json .. '\n')
  io.stdout:flush()
end

-- ============================================================================
-- MCP Tools
-- ============================================================================

M.TOOLS = {
  {
    name = 'nvim_save_baseline',
    description = 'Save the current content of a file as a baseline before making changes. Call this BEFORE modifying any file so Neovim can track what changed.',
    inputSchema = {
      type = 'object',
      properties = {
        filepath = {
          type = 'string',
          description = 'Absolute or relative path to the file',
        },
      },
      required = { 'filepath' },
    },
  },
  {
    name = 'nvim_notify_change',
    description = 'Notify Neovim that a file was changed, with optional line range information. Call this AFTER modifying a file.',
    inputSchema = {
      type = 'object',
      properties = {
        filepath = {
          type = 'string',
          description = 'Path to the modified file',
        },
        hunks = {
          type = 'array',
          description = 'Array of change hunks with start_line and end_line',
          items = {
            type = 'object',
            properties = {
              start_line = { type = 'integer' },
              end_line = { type = 'integer' },
              type = { type = 'string', enum = { 'add', 'modify', 'delete' } },
            },
          },
        },
      },
      required = { 'filepath' },
    },
  },
  {
    name = 'nvim_get_open_buffers',
    description = 'Get list of files currently open in Neovim buffers.',
    inputSchema = {
      type = 'object',
      properties = {},
      required = {},
    },
  },
  {
    name = 'nvim_reload_buffer',
    description = 'Tell Neovim to reload a file from disk after external modifications.',
    inputSchema = {
      type = 'object',
      properties = {
        filepath = {
          type = 'string',
          description = 'Path to the file to reload',
        },
      },
      required = { 'filepath' },
    },
  },
  {
    name = 'nvim_clear_highlights',
    description = 'Clear all change highlights in Neovim.',
    inputSchema = {
      type = 'object',
      properties = {},
      required = {},
    },
  },
}

---Handle tool invocation
---@param name string Tool name
---@param arguments table Tool arguments
---@return table result
function M.handle_tool_call(name, arguments)
  arguments = arguments or {}

  if name == 'nvim_save_baseline' then
    local filepath = arguments.filepath
    if not filepath then
      return { error = 'filepath is required' }
    end

    -- Get absolute path
    local abs_path = vim.fn.fnamemodify(filepath, ':p')

    local ok = M.nvim_exec_lua(
      [[
      local mcp = require('cursor-agent.mcp')
      mcp.save_baseline(...)
      return true
    ]],
      abs_path
    )

    return {
      success = ok == true,
      message = ok and ('Baseline saved for ' .. filepath) or 'Failed (Neovim not connected?)',
    }
  elseif name == 'nvim_notify_change' then
    local filepath = arguments.filepath
    local hunks = arguments.hunks or {}

    if not filepath then
      return { error = 'filepath is required' }
    end

    local abs_path = vim.fn.fnamemodify(filepath, ':p')

    local ok = M.nvim_exec_lua(
      [[
      local mcp = require('cursor-agent.mcp')
      mcp.on_file_changed(...)
      return true
    ]],
      abs_path,
      hunks
    )

    return {
      success = ok == true,
      message = ok and ('Notified change for ' .. filepath) or 'Failed',
    }
  elseif name == 'nvim_get_open_buffers' then
    local buffers = M.nvim_exec_lua [[
      local bufs = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == '' then
          local name = vim.api.nvim_buf_get_name(bufnr)
          if name and name ~= '' then
            table.insert(bufs, {
              bufnr = bufnr,
              filepath = name,
              modified = vim.bo[bufnr].modified,
            })
          end
        end
      end
      return bufs
    ]]

    return {
      connected = M.nvim_channel ~= nil,
      buffers = buffers or {},
    }
  elseif name == 'nvim_reload_buffer' then
    local filepath = arguments.filepath
    if not filepath then
      return { error = 'filepath is required' }
    end

    local abs_path = vim.fn.fnamemodify(filepath, ':p')

    local ok = M.nvim_exec_lua(
      [[
      local mcp = require('cursor-agent.mcp')
      mcp.reload_file(...)
      return true
    ]],
      abs_path
    )

    return {
      success = ok == true,
      message = ok and ('Reload triggered for ' .. filepath) or 'Failed',
    }
  elseif name == 'nvim_clear_highlights' then
    local ok = M.nvim_exec_lua [[
      local mcp = require('cursor-agent.mcp')
      mcp.clear_all()
      return true
    ]]

    return {
      success = ok == true,
      message = ok and 'Highlights cleared' or 'Failed',
    }
  else
    return { error = 'Unknown tool: ' .. name }
  end
end

-- ============================================================================
-- MCP Protocol Handlers
-- ============================================================================

function M.handle_initialize(params)
  return {
    protocolVersion = '2024-11-05',
    capabilities = {
      tools = {},
    },
    serverInfo = {
      name = 'cursor-agent-nvim',
      version = '0.1.0',
    },
  }
end

function M.handle_request(method, params, id)
  if method == 'initialize' then
    M.send_response(id, M.handle_initialize(params))
  elseif method == 'tools/list' then
    M.send_response(id, { tools = M.TOOLS })
  elseif method == 'tools/call' then
    local tool_name = params.name or ''
    local arguments = params.arguments or {}
    local result = M.handle_tool_call(tool_name, arguments)
    -- MCP expects content array for tool results
    M.send_response(id, {
      content = { { type = 'text', text = vim.json.encode(result) } },
    })
  elseif method == 'ping' then
    M.send_response(id, {})
  else
    M.send_response(id, nil, { code = -32601, message = 'Method not found: ' .. method })
  end
end

function M.handle_notification(method, params)
  if method == 'notifications/initialized' then
    M.log_info('MCP client initialized')
    -- Try to connect to Neovim
    M.connect_to_nvim()
  elseif method == 'notifications/cancelled' then
    M.log_info('Request cancelled')
  end
end

-- ============================================================================
-- Main Loop
-- ============================================================================

function M.main()
  M.log_info('Starting cursor-agent-nvim MCP server (pure Lua)')

  -- Read JSON-RPC messages from stdin
  for line in io.stdin:lines() do
    if line and line ~= '' then
      local ok, message = pcall(vim.json.decode, line)
      if not ok then
        M.log_error('Invalid JSON: ' .. line)
      else
        local method = message.method
        local params = message.params or {}
        local msg_id = message.id

        if msg_id ~= nil then
          -- Request (has id, expects response)
          M.handle_request(method, params, msg_id)
        else
          -- Notification (no id)
          M.handle_notification(method, params)
        end
      end
    end
  end
end

-- Run
M.main()

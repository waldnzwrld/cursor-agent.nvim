-- MCP integration module for cursor-agent.nvim
-- Handles commands from the MCP server for buffer management

local M = {}

local util = require('cursor-agent.util')

---Setup (no-op, kept for compatibility)
function M.setup()
  -- No setup needed without highlighting
end

---Save baseline for a file (no-op, kept for MCP compatibility)
---@param filepath string
function M.save_baseline(filepath)
  -- No-op: baseline tracking removed with highlighting
end

---Get buffer number for a filepath, or nil if not loaded
---@param filepath string Absolute path
---@return number|nil bufnr
local function get_bufnr(filepath)
  local bufnr = vim.fn.bufnr(filepath)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return bufnr
  end
  return nil
end

---Handle file change notification from MCP server
---@param filepath string
---@param hunks table[]|nil Array of {start_line, end_line, type} (unused without highlighting)
function M.on_file_changed(filepath, hunks)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = get_bufnr(filepath)
  
  if bufnr then
    M.reload_file(filepath)
  else
    util.notify('File modified (not open): ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
  end
end

---Reload a file from disk using native API
---@param filepath string
function M.reload_file(filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = get_bufnr(filepath)
  
  if not bufnr then
    return
  end
  
  -- Don't reload if buffer has unsaved changes
  if vim.bo[bufnr].modified then
    util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
    return
  end
  
  -- Read file from disk
  local ok, lines = pcall(vim.fn.readfile, filepath)
  if not ok or not lines then
    util.notify('Failed to read: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.ERROR)
    return
  end
  
  -- Save cursor positions for all windows showing this buffer
  local wins = vim.fn.win_findbuf(bufnr)
  local cursors = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
  end
  
  -- Update buffer content directly via API
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  
  -- Restore cursor positions, clamping to valid range
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for win, pos in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) then
      local row = math.min(pos[1], line_count)
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
      local col = math.min(pos[2], #line)
      pcall(vim.api.nvim_win_set_cursor, win, { row, col })
    end
  end
  
  util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
end

---Clear all (no-op, kept for MCP compatibility)
function M.clear_all()
  -- No-op: highlighting removed
end

---Called when a new cursor agent request starts (no-op, kept for compatibility)
function M.on_new_request()
  -- No-op: highlighting removed
end

---Record a pending change for a file not currently open (no-op, kept for compatibility)
---@param filepath string
function M.record_pending_change(filepath)
  -- No-op: highlighting removed
end

return M

-- Marker file watcher for Cursor Agent
-- Watches a marker file for file modification notifications
local M = {}

local uv = vim.uv or vim.loop
local highlight = require('cursor-agent.highlight')

-- Marker file location (in the project root)
local MARKER_FILENAME = '.cursor-agent-changes'

-- State
M._watcher = nil
M._marker_path = nil
M._last_mtime = 0

---Process the marker file content
---@param content string
local function process_marker_content(content)
  -- Each line is a filepath that was modified
  for filepath in content:gmatch('[^\r\n]+') do
    filepath = vim.fn.fnamemodify(filepath, ':p')
    
    -- Find buffer for this file
    local target_bufnr = nil
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local bufname = vim.api.nvim_buf_get_name(bufnr)
        if bufname == filepath then
          target_bufnr = bufnr
          break
        end
      end
    end
    
    if not target_bufnr then
      -- File not open, skip
      goto continue
    end
    
    -- Don't reload if buffer has unsaved changes
    if vim.bo[target_bufnr].modified then
      local util = require('cursor-agent.util')
      util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
      goto continue
    end
    
    -- Capture old content for diff highlighting
    local old_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
    
    -- Save cursor positions
    local wins = vim.fn.win_findbuf(target_bufnr)
    local cursors = {}
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        cursors[win] = vim.api.nvim_win_get_cursor(win)
      end
    end
    
    -- Mark reload in progress
    highlight.begin_reload(target_bufnr)
    
    -- Reload the buffer
    local ok = pcall(function()
      vim.api.nvim_buf_call(target_bufnr, function()
        vim.cmd('silent! edit!')
      end)
    end)
    
    if ok then
      -- Restore cursor positions
      local line_count = vim.api.nvim_buf_line_count(target_bufnr)
      for win, pos in pairs(cursors) do
        if vim.api.nvim_win_is_valid(win) then
          local row = math.min(pos[1], line_count)
          local line = vim.api.nvim_buf_get_lines(target_bufnr, row - 1, row, false)[1] or ''
          local col = math.min(pos[2], #line)
          pcall(vim.api.nvim_win_set_cursor, win, { row, col })
        end
      end
      
      -- Apply highlights
      highlight.highlight_buffer_changes(target_bufnr, old_lines)
      highlight.end_reload(target_bufnr)
      
      local util = require('cursor-agent.util')
      util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
    else
      highlight.end_reload(target_bufnr)
    end
    
    ::continue::
  end
end

---Handle marker file change
local function on_marker_change()
  if not M._marker_path then return end
  
  local stat = uv.fs_stat(M._marker_path)
  if not stat then return end
  
  -- Check if file was actually modified (not just accessed)
  local mtime = stat.mtime.sec
  if mtime <= M._last_mtime then return end
  M._last_mtime = mtime
  
  -- Read the marker file
  local fd = uv.fs_open(M._marker_path, 'r', 438)
  if not fd then return end
  
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  
  if content and content ~= '' then
    vim.schedule(function()
      process_marker_content(content)
      -- Clear the marker file after processing
      local wfd = uv.fs_open(M._marker_path, 'w', 438)
      if wfd then
        uv.fs_write(wfd, '', 0)
        uv.fs_close(wfd)
      end
    end)
  end
end

---Start watching for marker file changes
---@param project_root string
function M.start(project_root)
  if M._watcher then
    M.stop()
  end
  
  M._marker_path = project_root .. '/' .. MARKER_FILENAME
  M._last_mtime = 0
  
  -- Create the marker file if it doesn't exist
  local fd = uv.fs_open(M._marker_path, 'a', 438)
  if fd then
    uv.fs_close(fd)
  end
  
  -- Watch the marker file
  M._watcher = uv.new_fs_event()
  if not M._watcher then return end
  
  local ok = pcall(function()
    M._watcher:start(M._marker_path, {}, function(err, filename, events)
      if err then return end
      vim.schedule(on_marker_change)
    end)
  end)
  
  if not ok and M._watcher then
    M._watcher:close()
    M._watcher = nil
  end
end

---Stop watching
function M.stop()
  if M._watcher then
    pcall(function()
      M._watcher:stop()
      M._watcher:close()
    end)
    M._watcher = nil
  end
  M._marker_path = nil
end

---Get the marker file path
---@return string|nil
function M.get_marker_path()
  return M._marker_path
end

return M

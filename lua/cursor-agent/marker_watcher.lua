-- File watcher for Cursor Agent
-- Watches open buffer files for external modifications and reloads them
local M = {}

local uv = vim.uv or vim.loop

-- Global marker file location (not project-specific)
-- This allows Cursor Agent to write to a known location regardless of project
local MARKER_PATH = vim.fn.expand('~/.cache/cursor-agent-changes')

-- State
M._watcher = nil
M._last_mtime = 0

-- File watchers for individual buffers: { [bufnr] = { watcher = fs_event, filepath = string, mtime = number } }
M._buffer_watchers = {}

-- Debounce timers to avoid rapid-fire reloads
M._debounce_timers = {}

---Process the marker file content
---@param content string
local function process_marker_content(content)
  local mcp = require('cursor-agent.mcp')
  local util = require('cursor-agent.util')
  
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
      -- File not open - record for highlighting when opened
      mcp.record_pending_change(filepath)
      goto continue
    end
    
    -- Don't reload if buffer has unsaved changes
    if vim.bo[target_bufnr].modified then
      util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
      goto continue
    end
    
    -- Capture baseline BEFORE reload - but only if we don't have one yet
    -- This preserves the original state across multiple saves in one session
    local baseline = mcp._baselines[filepath]
    if not baseline then
      baseline = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
    end
    
    -- Save cursor positions
    local wins = vim.fn.win_findbuf(target_bufnr)
    local cursors = {}
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        cursors[win] = vim.api.nvim_win_get_cursor(win)
      end
    end
    
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
      
      -- Diff and apply highlights
      local new_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
      local changed = mcp._diff_lines(baseline, new_lines)
      if #changed > 0 then
        mcp._store_and_highlight(target_bufnr, filepath, baseline, changed)
      end
      
      util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
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
---@param project_root string (unused - kept for API compatibility)
function M.start(project_root)
  if M._watcher then
    M.stop()
  end
  
  -- Use the global marker path (not project-specific)
  M._marker_path = MARKER_PATH
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

---Reload a buffer from disk
---@param bufnr integer
---@param filepath string
local function reload_buffer(bufnr, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  local mcp = require('cursor-agent.mcp')
  local util = require('cursor-agent.util')
  
  -- Don't reload if buffer has unsaved changes
  if vim.bo[bufnr].modified then
    util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
    return
  end
  
  -- Capture baseline BEFORE reload - but only if we don't have one yet
  -- This preserves the original state across multiple saves in one session
  local abs_filepath = vim.fn.fnamemodify(filepath, ':p')
  local baseline = mcp._baselines[abs_filepath]
  if not baseline then
    baseline = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  
  -- Save cursor positions
  local wins = vim.fn.win_findbuf(bufnr)
  local cursors = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
  end
  
  -- Reload the buffer
  local ok = pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd('silent! edit!')
    end)
  end)
  
  if ok then
    -- Restore cursor positions
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for win, pos in pairs(cursors) do
      if vim.api.nvim_win_is_valid(win) then
        local row = math.min(pos[1], line_count)
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
        local col = math.min(pos[2], #line)
        pcall(vim.api.nvim_win_set_cursor, win, { row, col })
      end
    end
    
    -- Diff and apply highlights
    local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local changed = mcp._diff_lines(baseline, new_lines)
    if #changed > 0 then
      mcp._store_and_highlight(bufnr, filepath, baseline, changed)
    end
    
    util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
  end
end

---Handle file change for a watched buffer
---@param bufnr integer
local function on_buffer_file_change(bufnr)
  local info = M._buffer_watchers[bufnr]
  if not info then return end
  
  local stat = uv.fs_stat(info.filepath)
  if not stat then return end
  
  -- Check if file was actually modified (not just accessed)
  local mtime = stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000
  if mtime <= info.mtime then return end
  info.mtime = mtime
  
  -- Debounce rapid changes
  if M._debounce_timers[bufnr] then
    M._debounce_timers[bufnr]:stop()
  end
  
  M._debounce_timers[bufnr] = vim.defer_fn(function()
    M._debounce_timers[bufnr] = nil
    vim.schedule(function()
      reload_buffer(bufnr, info.filepath)
    end)
  end, 100)
end

---Start watching a buffer's file for external changes
---@param bufnr integer
function M.watch_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  -- Only watch normal file buffers
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= '' then return end
  
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == '' then return end
  
  -- Already watching this buffer
  if M._buffer_watchers[bufnr] then return end
  
  -- Get initial mtime
  local stat = uv.fs_stat(filepath)
  if not stat then return end
  
  local mtime = stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000
  
  -- Create watcher
  local watcher = uv.new_fs_event()
  if not watcher then return end
  
  local ok = pcall(function()
    watcher:start(filepath, {}, function(err, filename, events)
      if err then return end
      vim.schedule(function()
        on_buffer_file_change(bufnr)
      end)
    end)
  end)
  
  if ok then
    M._buffer_watchers[bufnr] = {
      watcher = watcher,
      filepath = filepath,
      mtime = mtime,
    }
  else
    pcall(function() watcher:close() end)
  end
end

---Stop watching a buffer's file
---@param bufnr integer
function M.unwatch_buffer(bufnr)
  local info = M._buffer_watchers[bufnr]
  if info then
    pcall(function()
      info.watcher:stop()
      info.watcher:close()
    end)
    M._buffer_watchers[bufnr] = nil
  end
  
  if M._debounce_timers[bufnr] then
    M._debounce_timers[bufnr]:stop()
    M._debounce_timers[bufnr] = nil
  end
end

---Set up autocmds to watch buffers automatically
function M.setup_buffer_watchers()
  local group = vim.api.nvim_create_augroup('CursorAgentBufferWatch', { clear = true })
  
  -- Watch buffers when they are read/opened
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    callback = function(ev)
      M.watch_buffer(ev.buf)
    end,
  })
  
  -- Stop watching when buffer is deleted
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      M.unwatch_buffer(ev.buf)
    end,
  })
  
  -- Watch all currently open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.watch_buffer(bufnr)
    end
  end
end

---Manually process the marker file (for debugging)
function M.process_now()
  if not M._marker_path then
    local util = require('cursor-agent.util')
    util.notify('Marker watcher not started', vim.log.levels.WARN)
    return
  end
  
  local stat = uv.fs_stat(M._marker_path)
  if not stat then
    local util = require('cursor-agent.util')
    util.notify('Marker file not found: ' .. M._marker_path, vim.log.levels.WARN)
    return
  end
  
  local fd = uv.fs_open(M._marker_path, 'r', 438)
  if not fd then
    local util = require('cursor-agent.util')
    util.notify('Could not open marker file', vim.log.levels.WARN)
    return
  end
  
  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  
  if content and content ~= '' then
    local util = require('cursor-agent.util')
    util.notify('Processing: ' .. content, vim.log.levels.INFO)
    process_marker_content(content)
    -- Clear the file
    local wfd = uv.fs_open(M._marker_path, 'w', 438)
    if wfd then
      uv.fs_write(wfd, '', 0)
      uv.fs_close(wfd)
    end
  else
    local util = require('cursor-agent.util')
    util.notify('Marker file is empty', vim.log.levels.INFO)
  end
end

return M

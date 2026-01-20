-- File watcher for Cursor Agent
-- Watches open buffer files for external modifications and reloads with highlighting
local M = {}

local uv = vim.uv or vim.loop
local highlight = require('cursor-agent.highlight')

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

-- Content cache for files (persists across buffer close/open)
-- { [filepath] = { lines = string[], mtime = number } }
M._content_cache = {}

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
      -- File not open - check if we have cached content to compute diff
      local cached = M._content_cache[filepath]
      if cached then
        -- Read new content from disk
        local new_lines = {}
        local fd = uv.fs_open(filepath, 'r', 438)
        if fd then
          local stat = uv.fs_stat(filepath)
          if stat then
            local file_content = uv.fs_read(fd, stat.size, 0)
            if file_content then
              for line in (file_content .. '\n'):gmatch('([^\n]*)\n') do
                table.insert(new_lines, line)
              end
              -- Remove trailing empty line if file doesn't end with newline
              if #new_lines > 0 and new_lines[#new_lines] == '' and not file_content:match('\n$') then
                table.remove(new_lines)
              end
            end
          end
          uv.fs_close(fd)
        end
        
        if #new_lines > 0 then
          -- Compute diff and store pending highlights
          local changed_lines = highlight.compute_changed_lines(cached.lines, new_lines)
          highlight.store_pending_highlights(filepath, changed_lines)
          
          -- Update cache with new content
          local stat = uv.fs_stat(filepath)
          M._content_cache[filepath] = {
            lines = new_lines,
            mtime = stat and (stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000) or 0,
          }
          
          local total = #(changed_lines.modified or {}) + #(changed_lines.added or {})
          if total > 0 then
            local util = require('cursor-agent.util')
            util.notify('Stored ' .. total .. ' pending highlight(s) for ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
          end
        end
      end
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
      
      -- Update content cache
      local new_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
      local stat = uv.fs_stat(filepath)
      M._content_cache[filepath] = {
        lines = new_lines,
        mtime = stat and (stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000) or 0,
      }
      
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

---Reload a buffer from disk with highlighting
---@param bufnr integer
---@param filepath string
local function reload_buffer_with_highlight(bufnr, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  -- Don't reload if buffer has unsaved changes
  if vim.bo[bufnr].modified then
    local util = require('cursor-agent.util')
    util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
    return
  end
  
  -- Capture old content for diff highlighting
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Save cursor positions
  local wins = vim.fn.win_findbuf(bufnr)
  local cursors = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
  end
  
  -- Mark reload in progress
  highlight.begin_reload(bufnr)
  
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
    
    -- Apply highlights
    highlight.highlight_buffer_changes(bufnr, old_lines)
    highlight.end_reload(bufnr)
    
    -- Update content cache
    filepath = vim.fn.fnamemodify(filepath, ':p')
    local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local stat = uv.fs_stat(filepath)
    M._content_cache[filepath] = {
      lines = new_lines,
      mtime = stat and (stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000) or 0,
    }
    
    local util = require('cursor-agent.util')
    util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
  else
    highlight.end_reload(bufnr)
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
      reload_buffer_with_highlight(bufnr, info.filepath)
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

---Cache content for a buffer
---@param bufnr integer
function M.cache_buffer_content(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= '' then return end
  
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == '' then return end
  
  filepath = vim.fn.fnamemodify(filepath, ':p')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local stat = uv.fs_stat(filepath)
  
  M._content_cache[filepath] = {
    lines = lines,
    mtime = stat and (stat.mtime.sec * 1000 + (stat.mtime.nsec or 0) / 1000000) or 0,
  }
end

---Set up autocmds to watch buffers automatically
function M.setup_buffer_watchers()
  local group = vim.api.nvim_create_augroup('CursorAgentBufferWatch', { clear = true })
  
  -- Watch buffers when they are read/opened, cache content, apply pending highlights
  vim.api.nvim_create_autocmd({ 'BufReadPost' }, {
    group = group,
    callback = function(ev)
      M.watch_buffer(ev.buf)
      
      -- Apply any pending highlights first (before caching new content)
      local applied = highlight.apply_pending_highlights(ev.buf)
      
      -- Cache content (for future diffs when file isn't open)
      -- Only cache if we didn't just apply pending highlights
      -- (because pending highlights means the content was already cached and we want to keep it current)
      if not applied then
        M.cache_buffer_content(ev.buf)
      else
        -- Still update cache with current content after applying highlights
        vim.defer_fn(function()
          M.cache_buffer_content(ev.buf)
        end, 100)
      end
    end,
  })
  
  -- Cache content for new files too
  vim.api.nvim_create_autocmd({ 'BufNewFile' }, {
    group = group,
    callback = function(ev)
      M.watch_buffer(ev.buf)
      M.cache_buffer_content(ev.buf)
    end,
  })
  
  -- Update cache when buffer is written
  vim.api.nvim_create_autocmd({ 'BufWritePost' }, {
    group = group,
    callback = function(ev)
      M.cache_buffer_content(ev.buf)
    end,
  })
  
  -- Stop watching when buffer is deleted (but keep cache for future opens)
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      M.unwatch_buffer(ev.buf)
      -- Note: We intentionally keep the content cache
    end,
  })
  
  -- Watch and cache all currently open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.watch_buffer(bufnr)
      M.cache_buffer_content(bufnr)
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

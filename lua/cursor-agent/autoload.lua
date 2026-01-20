-- Automatic buffer reloading when files are modified externally
local M = {}

local uv = vim.uv or vim.loop
local highlight = require('cursor-agent.highlight')

-- State for file watchers
M._watchers = {} -- { [filepath] = { handle = uv.fs_event, bufnr = number } }
M._enabled = false
M._debounce_timers = {} -- { [filepath] = timer_handle }
M._reloading = {} -- { [filepath] = true } -- Guard against re-entrancy
M._cooldown = {} -- { [filepath] = timestamp } -- Cooldown after reload

local DEBOUNCE_MS = 100 -- Debounce file change events
local COOLDOWN_MS = 1000 -- Ignore events for this long after a reload

---Check if a buffer should be auto-reloaded
---@param bufnr integer
---@return boolean
local function should_reload_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return false end
  
  -- Don't reload modified buffers (user has unsaved changes)
  if vim.bo[bufnr].modified then return false end
  
  -- Only reload normal file buffers
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= '' then return false end
  
  return true
end

---Reload a buffer from disk
---@param bufnr integer
---@param filepath string
local function reload_buffer(bufnr, filepath)
  if not should_reload_buffer(bufnr) then return end
  
  -- Guard: Don't reload if already reloading this file
  if M._reloading[filepath] then return end
  
  -- Cooldown: Don't reload if we just reloaded this file
  local cooldown_time = M._cooldown[filepath]
  if cooldown_time and (uv.now() - cooldown_time) < COOLDOWN_MS then
    return
  end
  
  -- Check if file still exists
  local stat = uv.fs_stat(filepath)
  if not stat then return end
  
  -- Set reloading guard
  M._reloading[filepath] = true
  
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M._reloading[filepath] = nil
      return
    end
    if vim.bo[bufnr].modified then
      M._reloading[filepath] = nil
      return
    end
    
    -- Capture buffer contents BEFORE reload for highlighting
    local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    
    -- Save cursor position
    local wins = vim.fn.win_findbuf(bufnr)
    local cursors = {}
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        cursors[win] = vim.api.nvim_win_get_cursor(win)
      end
    end
    
    -- Reload the buffer silently
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd('silent! edit!')
      end)
    end)
    
    -- Set cooldown timestamp BEFORE clearing guard
    M._cooldown[filepath] = uv.now()
    M._reloading[filepath] = nil
    
    if ok then
      -- Restore cursor positions (clamped to valid range)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      for win, pos in pairs(cursors) do
        if vim.api.nvim_win_is_valid(win) then
          local row = math.min(pos[1], line_count)
          local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
          local col = math.min(pos[2], #line)
          pcall(vim.api.nvim_win_set_cursor, win, { row, col })
        end
      end
      
      -- Highlight the changes
      highlight.highlight_buffer_changes(bufnr, old_lines)
    end
  end)
end

---Start watching a file for changes
---@param filepath string
---@param bufnr integer
local function watch_file(filepath, bufnr)
  if M._watchers[filepath] then return end -- Already watching
  
  local stat = uv.fs_stat(filepath)
  if not stat or stat.type ~= 'file' then return end
  
  local handle = uv.new_fs_event()
  if not handle then return end
  
  local ok = pcall(function()
    handle:start(filepath, {}, function(err, filename, events)
      if err then return end
      
      -- Debounce rapid file changes
      if M._debounce_timers[filepath] then
        M._debounce_timers[filepath]:stop()
        M._debounce_timers[filepath]:close()
      end
      
      local timer = uv.new_timer()
      M._debounce_timers[filepath] = timer
      
      timer:start(DEBOUNCE_MS, 0, function()
        timer:stop()
        timer:close()
        M._debounce_timers[filepath] = nil
        
        -- Schedule to main loop - nvim API calls not allowed in fast event context
        vim.schedule(function()
          -- Re-check watcher still exists and buffer is valid
          local watcher = M._watchers[filepath]
          if watcher and vim.api.nvim_buf_is_valid(watcher.bufnr) then
            reload_buffer(watcher.bufnr, filepath)
          end
        end)
      end)
    end)
  end)
  
  if ok then
    M._watchers[filepath] = { handle = handle, bufnr = bufnr }
  else
    handle:close()
  end
end

---Stop watching a file
---@param filepath string
local function unwatch_file(filepath)
  local watcher = M._watchers[filepath]
  if not watcher then return end
  
  if watcher.handle then
    pcall(function()
      watcher.handle:stop()
      watcher.handle:close()
    end)
  end
  
  if M._debounce_timers[filepath] then
    pcall(function()
      M._debounce_timers[filepath]:stop()
      M._debounce_timers[filepath]:close()
    end)
    M._debounce_timers[filepath] = nil
  end
  
  M._watchers[filepath] = nil
end

---Watch all currently open file buffers in the project
---@param project_root string|nil
function M.watch_project_buffers(project_root)
  local root = project_root or vim.fn.getcwd()
  
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath and filepath ~= '' and not filepath:match('^%w+://') then
        -- Only watch files within the project root
        if filepath:sub(1, #root) == root then
          watch_file(filepath, bufnr)
        end
      end
    end
  end
end

---Set up autocmds for automatic buffer watching
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup('CursorAgentAutoload', { clear = true })
  
  -- Watch new buffers as they're opened
  vim.api.nvim_create_autocmd('BufRead', {
    group = group,
    callback = function(args)
      if not M._enabled then return end
      local filepath = args.file
      if filepath and filepath ~= '' and not filepath:match('^%w+://') then
        watch_file(filepath, args.buf)
      end
    end,
  })
  
  -- Unwatch buffers when they're deleted/wiped
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(args)
      local filepath = vim.api.nvim_buf_get_name(args.buf)
      if filepath and filepath ~= '' then
        unwatch_file(filepath)
      end
    end,
  })
  
  -- NOTE: Removed BufEnter checktime - it caused reload loops.
  -- File watchers are sufficient for detecting external changes.
end

---Enable automatic buffer reloading
---@param project_root string|nil
function M.enable(project_root)
  if M._enabled then return end
  M._enabled = true
  
  -- Ensure autoread is set
  vim.o.autoread = true
  
  M.setup_autocmds()
  M.watch_project_buffers(project_root)
end

---Disable automatic buffer reloading and clean up watchers
function M.disable()
  M._enabled = false
  
  -- Stop all watchers
  for filepath, _ in pairs(M._watchers) do
    unwatch_file(filepath)
  end
  
  -- Clean up state
  M._reloading = {}
  M._cooldown = {}
  
  -- Clean up the autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, 'CursorAgentAutoload')
end

---Check if autoloading is currently enabled
---@return boolean
function M.is_enabled()
  return M._enabled
end

---Manually trigger a reload check on all watched buffers
function M.check_all()
  pcall(vim.cmd, 'silent! checktime')
end

return M

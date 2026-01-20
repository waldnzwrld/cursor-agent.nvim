-- Terminal output monitoring for Cursor Agent markers
-- Watches for structured markers in terminal output to trigger precise buffer reloads
local M = {}

local highlight = require('cursor-agent.highlight')

-- Pattern to match file modification markers
-- Format: <<<CURSOR_AGENT_MODIFIED:/absolute/path/to/file>>>
local MARKER_PATTERN = "<<<CURSOR_AGENT_MODIFIED:([^>]+)>>>"

-- Track monitored terminal buffers
M._monitored_buffers = {} -- { [bufnr] = true }

-- Track files we've been notified about (to avoid duplicate processing)
M._processed_markers = {} -- { [marker_string] = timestamp }
local MARKER_COOLDOWN_MS = 2000 -- Don't process same marker within 2 seconds

---Process a detected file modification marker
---@param filepath string The path to the modified file
local function process_file_modification(filepath)
  -- Normalize the path
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Check cooldown
  local now = vim.loop.now()
  local last_processed = M._processed_markers[filepath]
  if last_processed and (now - last_processed) < MARKER_COOLDOWN_MS then
    return -- Skip, recently processed
  end
  M._processed_markers[filepath] = now
  
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
    -- File not open in any buffer, nothing to do
    return
  end
  
  -- Don't reload if buffer has unsaved changes
  if vim.bo[target_bufnr].modified then
    local util = require('cursor-agent.util')
    util.notify('Skipping reload of ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (has unsaved changes)', vim.log.levels.WARN)
    return
  end
  
  -- Capture old content for diff highlighting
  local old_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
  
  -- Save cursor positions in all windows showing this buffer
  local wins = vim.fn.win_findbuf(target_bufnr)
  local cursors = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
  end
  
  -- Mark reload in progress (prevent highlight clearing)
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
    
    -- End reload (with delay to let TextChanged events pass)
    highlight.end_reload(target_bufnr)
  else
    highlight.end_reload(target_bufnr)
  end
end

---Scan terminal buffer content for markers
---@param bufnr integer Terminal buffer number
local function scan_buffer_for_markers(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  -- Get the last N lines of the terminal buffer (don't scan entire history)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(0, line_count - 50) -- Check last 50 lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, line_count, false)
  
  for _, line in ipairs(lines) do
    local filepath = line:match(MARKER_PATTERN)
    if filepath then
      -- Schedule to avoid issues with terminal buffer updates
      vim.schedule(function()
        process_file_modification(filepath)
      end)
    end
  end
end

---Start monitoring a terminal buffer for markers
---@param bufnr integer Terminal buffer number
function M.start_monitoring(bufnr)
  if M._monitored_buffers[bufnr] then return end
  M._monitored_buffers[bufnr] = true
  
  local group_name = 'CursorAgentTerminalMonitor_' .. bufnr
  local group = vim.api.nvim_create_augroup(group_name, { clear = true })
  
  -- Monitor terminal output changes
  -- TerminalUpdate event fires when terminal content changes (Neovim 0.10+)
  -- For older versions, we use a timer-based approach
  local has_terminal_update = vim.fn.exists('##TerminalUpdate') == 1
  
  if has_terminal_update then
    vim.api.nvim_create_autocmd('TerminalUpdate', {
      group = group,
      buffer = bufnr,
      callback = function()
        scan_buffer_for_markers(bufnr)
      end,
    })
  else
    -- Fallback: poll the terminal buffer periodically
    local timer = vim.loop.new_timer()
    timer:start(500, 500, vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) and M._monitored_buffers[bufnr] then
        scan_buffer_for_markers(bufnr)
      else
        timer:stop()
        timer:close()
      end
    end))
  end
  
  -- Clean up when buffer is deleted
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      M.stop_monitoring(bufnr)
    end,
  })
end

---Stop monitoring a terminal buffer
---@param bufnr integer
function M.stop_monitoring(bufnr)
  M._monitored_buffers[bufnr] = nil
  local group_name = 'CursorAgentTerminalMonitor_' .. bufnr
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

---Clean up old processed markers (memory management)
function M.cleanup_old_markers()
  local now = vim.loop.now()
  local cutoff = now - (MARKER_COOLDOWN_MS * 10) -- Keep for 10x cooldown period
  for marker, timestamp in pairs(M._processed_markers) do
    if timestamp < cutoff then
      M._processed_markers[marker] = nil
    end
  end
end

return M

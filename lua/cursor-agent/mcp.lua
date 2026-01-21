-- MCP integration module for cursor-agent.nvim
-- Handles commands from the MCP server for baseline management and highlighting

local M = {}

local util = require('cursor-agent.util')

-- Baseline storage: { [filepath] = string[] (lines) }
M._baselines = {}

-- Change tracking: { [filepath] = { lines = number[], hunks = table[] } }
M._changes = {}

-- Highlight namespace
M.NS_ID = vim.api.nvim_create_namespace('cursor_agent_mcp')
M.HL_GROUP = 'CursorAgentChange'

-- Track highlighted buffers for cleanup
M._highlighted_buffers = {}

---Setup highlight group
function M.setup()
  vim.api.nvim_set_hl(0, M.HL_GROUP, {
    bg = '#2a3a2a',
    default = true,
  })
  M._setup_autocmds()
end

---Save baseline for a file (called by MCP server before changes)
---@param filepath string
function M.save_baseline(filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Check if file is in a buffer
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.fn.fnamemodify(bufname, ':p') == filepath then
        -- Save buffer content as baseline
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        M._baselines[filepath] = lines
        util.notify('Baseline saved: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.DEBUG)
        return
      end
    end
  end
  
  -- File not in buffer, read from disk
  local lines = {}
  local fd = io.open(filepath, 'r')
  if fd then
    for line in fd:lines() do
      table.insert(lines, line)
    end
    fd:close()
    M._baselines[filepath] = lines
    util.notify('Baseline saved (from disk): ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.DEBUG)
  end
end

---Handle file change notification from MCP server
---@param filepath string
---@param hunks table[] Array of {start_line, end_line, type}
function M.on_file_changed(filepath, hunks)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Store the change info
  M._changes[filepath] = {
    hunks = hunks or {},
    timestamp = os.time(),
  }
  
  -- Find buffer for this file
  local target_bufnr = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.fn.fnamemodify(bufname, ':p') == filepath then
        target_bufnr = bufnr
        break
      end
    end
  end
  
  if target_bufnr then
    -- Buffer is open - reload and highlight
    M.reload_file(filepath)
  else
    -- Buffer not open - changes will be highlighted when file is opened
    util.notify('File modified (not open): ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
  end
end

---Reload a file and apply highlights
---@param filepath string
function M.reload_file(filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Find buffer
  local target_bufnr = nil
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.fn.fnamemodify(bufname, ':p') == filepath then
        target_bufnr = bufnr
        break
      end
    end
  end
  
  if not target_bufnr then
    return
  end
  
  -- Don't reload if buffer has unsaved changes
  if vim.bo[target_bufnr].modified then
    util.notify('Skipping reload: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' (unsaved changes)', vim.log.levels.WARN)
    return
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
    
    -- Apply highlights
    M._apply_highlights(target_bufnr, filepath)
    
    util.notify('Reloaded: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
  end
end

---Apply highlights to a buffer based on stored changes/baseline
---@param bufnr number
---@param filepath string
function M._apply_highlights(bufnr, filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Clear existing highlights
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_ID, 0, -1)
  
  local change_info = M._changes[filepath]
  local baseline = M._baselines[filepath]
  
  local lines_to_highlight = {}
  
  -- If we have hunks from MCP, use those directly
  if change_info and change_info.hunks and #change_info.hunks > 0 then
    for _, hunk in ipairs(change_info.hunks) do
      local start_line = hunk.start_line or hunk[1]
      local end_line = hunk.end_line or hunk[2] or start_line
      for lnum = start_line, end_line do
        lines_to_highlight[lnum] = true
      end
    end
  -- Otherwise, diff against baseline if we have one
  elseif baseline then
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local changed = M._diff_lines(baseline, current_lines)
    for _, lnum in ipairs(changed) do
      lines_to_highlight[lnum] = true
    end
  end
  
  -- Apply highlights
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for lnum, _ in pairs(lines_to_highlight) do
    if lnum >= 1 and lnum <= line_count then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, M.NS_ID, M.HL_GROUP, lnum - 1, 0, -1)
    end
  end
  
  if next(lines_to_highlight) then
    M._highlighted_buffers[bufnr] = true
  end
end

---Diff two sets of lines using vim.diff
---@param old_lines string[]
---@param new_lines string[]
---@return number[] changed line numbers in new content
function M._diff_lines(old_lines, new_lines)
  local old_text = table.concat(old_lines, '\n')
  local new_text = table.concat(new_lines, '\n')
  
  local ok, hunks = pcall(vim.diff, old_text, new_text, { result_type = 'indices' })
  if not ok or not hunks then
    return {}
  end
  
  local changed = {}
  for _, hunk in ipairs(hunks) do
    local start_b = hunk[3]
    local count_b = hunk[4]
    if count_b > 0 then
      for lnum = start_b, start_b + count_b - 1 do
        table.insert(changed, lnum)
      end
    end
  end
  
  return changed
end

---Store baseline and apply highlights to a buffer
---@param bufnr number Buffer number
---@param filepath string Absolute file path
---@param baseline string[] Original lines before change
---@param changed number[] Line numbers that changed
function M._store_and_highlight(bufnr, filepath, baseline, changed)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Store baseline for potential future diffs
  M._baselines[filepath] = baseline
  
  -- Merge with existing changed lines (accumulate across multiple saves)
  local existing = M._changes[filepath]
  local line_set = {}
  
  if existing and existing.lines then
    for _, lnum in ipairs(existing.lines) do
      line_set[lnum] = true
    end
  end
  
  for _, lnum in ipairs(changed) do
    line_set[lnum] = true
  end
  
  -- Convert back to sorted array
  local merged = {}
  for lnum, _ in pairs(line_set) do
    table.insert(merged, lnum)
  end
  table.sort(merged)
  
  M._changes[filepath] = {
    lines = merged,
    timestamp = os.time(),
  }
  
  -- Apply highlights
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_ID, 0, -1)
  
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, lnum in ipairs(merged) do
    if lnum >= 1 and lnum <= line_count then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, M.NS_ID, M.HL_GROUP, lnum - 1, 0, -1)
    end
  end
  
  if #merged > 0 then
    M._highlighted_buffers[bufnr] = true
  end
end

---Record a pending change for a file not currently open
---@param filepath string Absolute file path
function M.record_pending_change(filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  -- Read file from disk as baseline (before external change)
  -- Note: by the time we get here, the file is already changed on disk
  -- So we can only mark it as changed, not provide accurate line info
  if not M._changes[filepath] then
    M._changes[filepath] = {
      lines = {},  -- Empty means "whole file changed" when opened
      pending = true,
      timestamp = os.time(),
    }
  end
end

---Clear highlights for a file
---@param filepath string
function M.clear_highlights(filepath)
  filepath = vim.fn.fnamemodify(filepath, ':p')
  
  M._changes[filepath] = nil
  M._baselines[filepath] = nil
  
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.fn.fnamemodify(bufname, ':p') == filepath then
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_ID, 0, -1)
        M._highlighted_buffers[bufnr] = nil
      end
    end
  end
end

---Clear all highlights
function M.clear_all()
  for bufnr, _ in pairs(M._highlighted_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.NS_ID, 0, -1)
    end
  end
  M._highlighted_buffers = {}
  M._changes = {}
  M._baselines = {}
end

-- Track git index mtime for commit detection
M._git_index_mtime = nil
M._git_watcher = nil

---Setup autocmds
function M._setup_autocmds()
  local group = vim.api.nvim_create_augroup('CursorAgentMCP', { clear = true })
  
  -- Apply pending highlights when file is opened
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(ev)
      local buftype = vim.bo[ev.buf].buftype
      if buftype ~= '' then return end
      
      local filepath = vim.api.nvim_buf_get_name(ev.buf)
      if not filepath or filepath == '' then return end
      
      filepath = vim.fn.fnamemodify(filepath, ':p')
      
      -- Check if we have pending changes for this file
      local change_info = M._changes[filepath]
      if change_info then
        if change_info.pending then
          -- File was changed while closed - we don't have baseline
          -- Notify user but don't highlight (can't determine specific lines)
          local util = require('cursor-agent.util')
          util.notify('File was modified: ' .. vim.fn.fnamemodify(filepath, ':t'), vim.log.levels.INFO)
          M._changes[filepath] = nil  -- Clear pending state
        elseif change_info.lines and #change_info.lines > 0 then
          vim.defer_fn(function()
            M._apply_highlights(ev.buf, filepath)
          end, 10)
        end
      end
    end,
  })
  
  -- Clear highlights when user modifies buffer
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    callback = function(ev)
      local filepath = vim.api.nvim_buf_get_name(ev.buf)
      if filepath and filepath ~= '' and vim.bo[ev.buf].modified then
        filepath = vim.fn.fnamemodify(filepath, ':p')
        M.clear_highlights(filepath)
      end
    end,
  })
  
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    callback = function(ev)
      local filepath = vim.api.nvim_buf_get_name(ev.buf)
      if filepath and filepath ~= '' and vim.bo[ev.buf].modified then
        filepath = vim.fn.fnamemodify(filepath, ':p')
        M.clear_highlights(filepath)
      end
    end,
  })
  
  -- Clear highlights on FocusGained (check for git commits)
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M._check_git_commit()
    end,
  })
  
  -- Start git index watcher
  M._start_git_watcher()
end

---Start watching git index for commits
function M._start_git_watcher()
  local util = require('cursor-agent.util')
  local git_dir = util.get_project_root() .. '/.git'
  local index_path = git_dir .. '/index'
  
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(index_path)
  if stat then
    M._git_index_mtime = stat.mtime.sec
  end
  
  -- Watch the git index file
  if M._git_watcher then
    pcall(function()
      M._git_watcher:stop()
      M._git_watcher:close()
    end)
  end
  
  M._git_watcher = uv.new_fs_event()
  if M._git_watcher and stat then
    pcall(function()
      M._git_watcher:start(index_path, {}, function(err, filename, events)
        if err then return end
        vim.schedule(function()
          M._check_git_commit()
        end)
      end)
    end)
  end
end

---Check if git index changed (commit occurred) and clear highlights
function M._check_git_commit()
  local util = require('cursor-agent.util')
  local git_dir = util.get_project_root() .. '/.git'
  local index_path = git_dir .. '/index'
  
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(index_path)
  if not stat then return end
  
  local new_mtime = stat.mtime.sec
  if M._git_index_mtime and new_mtime > M._git_index_mtime then
    -- Git index changed, likely a commit - clear all highlights
    M.clear_all()
    util.notify('Highlights cleared (git commit detected)', vim.log.levels.INFO)
  end
  M._git_index_mtime = new_mtime
end

---Called when a new cursor agent request starts
function M.on_new_request()
  M.clear_all()
end

return M

local config = require('cursor-agent.config')
local context = require('cursor-agent.context')
local util = require('cursor-agent.util')
local termui = require('cursor-agent.ui.term')
local marker_watcher = require('cursor-agent.marker_watcher')

local M = {}

-- State for a single persistent terminal window
M._term_state = {
  win = nil,
  bufnr = nil,
  job_id = nil,
}

function M.setup(user_config)
  config.setup(user_config or {})
  M._register_commands()
  M._ensure_keymaps()
  
  -- Start watching for file modification markers (legacy mechanism)
  marker_watcher.start(util.get_project_root())
  
  -- Set up direct file watchers on open buffers (more reliable)
  marker_watcher.setup_buffer_watchers()
end

function M._register_commands()
  -- Primary entrypoint: toggle interactive terminal
  vim.api.nvim_create_user_command('CursorAgent', function()
    M.toggle_terminal()
  end, { desc = 'Toggle Cursor Agent terminal' })

  -- Backwards compatibility: old name now toggles terminal
  vim.api.nvim_create_user_command('CursorAgentPrompt', function()
    util.notify('CursorAgentPrompt is deprecated; use :CursorAgent', vim.log.levels.WARN)
    M.toggle_terminal()
  end, { desc = 'Deprecated: use :CursorAgent' })

  vim.api.nvim_create_user_command('CursorAgentSelection', function()
    local sel_ctx = context.get_visual_selection_with_context()
    if not sel_ctx or not sel_ctx.content or sel_ctx.content == '' then
      util.notify('No visual selection', vim.log.levels.WARN)
      return
    end
    -- Format with file context like haunt.sidekick: @/path:L1-L10
    local line_ref = sel_ctx.start_line == sel_ctx.end_line
      and string.format(":L%d", sel_ctx.start_line)
      or string.format(":L%d-L%d", sel_ctx.start_line, sel_ctx.end_line)
    local header = string.format("@/%s%s", sel_ctx.filepath, line_ref)
    local formatted = string.format("%s\n```%s\n%s\n```\n", header, sel_ctx.filetype or "", sel_ctx.content)
    M.send_to_terminal(formatted)
  end, { range = true, desc = 'Send current visual selection to Cursor Agent' })

  vim.api.nvim_create_user_command('CursorAgentBuffer', function()
    local bufctx = context.get_buffer_context()
    local title = ('%s → Cursor Agent'):format(vim.fn.fnamemodify(bufctx.filepath, ':t'))
    local tmp = util.write_tempfile(bufctx.content, '.txt')
    M.ask({ file = tmp, title = title })
  end, { desc = 'Send current buffer contents to Cursor Agent' })

  -- Debug command to check marker watcher status
  vim.api.nvim_create_user_command('CursorAgentDebug', function()
    local path = marker_watcher.get_marker_path()
    util.notify('Marker path: ' .. (path or 'nil'), vim.log.levels.INFO)
    util.notify('Project root: ' .. util.get_project_root(), vim.log.levels.INFO)
    
    -- Try to manually process the marker file
    if path then
      local uv = vim.uv or vim.loop
      local stat = uv.fs_stat(path)
      if stat then
        util.notify('Marker file exists, size: ' .. stat.size, vim.log.levels.INFO)
        local fd = uv.fs_open(path, 'r', 438)
        if fd then
          local content = uv.fs_read(fd, stat.size, 0)
          uv.fs_close(fd)
          util.notify('Marker content: ' .. (content or 'empty'), vim.log.levels.INFO)
        end
      else
        util.notify('Marker file does not exist', vim.log.levels.WARN)
      end
    end
  end, { desc = 'Debug Cursor Agent marker watcher' })

  -- Command to manually trigger reload from marker file
  vim.api.nvim_create_user_command('CursorAgentProcessMarkers', function()
    marker_watcher.process_now()
  end, { desc = 'Manually process marker file' })
end

function M.ask(opts)
  opts = opts or {}
  local title = opts.title or 'Cursor Agent'
  local cfg = config.get()

  local base = util.to_argv(cfg.cmd)
  if not base or #base == 0 then
    util.err('Invalid cmd configured')
    return
  end
  local argv = util.concat_argv(base, cfg.args)

  if opts.file and opts.file ~= '' then
    table.insert(argv, opts.file)
  elseif opts.prompt and opts.prompt ~= '' then
    table.insert(argv, opts.prompt)
  end

  local root = util.get_project_root()
  
  if cfg.window_mode == "attached" then
    termui.open_split_term({
      argv = argv,
      position = cfg.position,
      width = cfg.width,
      cwd = root,
      on_exit = function(code)
        if code ~= 0 then
          util.notify(('cursor-agent exited with code %d'):format(code), vim.log.levels.WARN)
        end
      end,
    })
  else
    termui.open_float_term({
      argv = argv,
      title = title,
      border = 'rounded',
      width = 0.6,
      height = 0.6,
      cwd = root,
      on_exit = function(code)
        if code ~= 0 then
          util.notify(('cursor-agent exited with code %d'):format(code), vim.log.levels.WARN)
        end
      end,
    })
  end
end

-- Toggle a long-lived cursor-agent terminal at project root
function M.toggle_terminal()
  local st = M._term_state
  local cfg = config.get()

  -- If window is open, close it (toggle off)
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
    st.win = nil
    return
  end

  -- Helper: check if the terminal job is still alive
  local function job_is_alive(job_id)
    if not job_id or job_id == 0 then return false end
    local ok, res = pcall(vim.fn.jobwait, { job_id }, 0)
    if not ok or type(res) ~= 'table' then return false end
    return res[1] == -1
  end

  -- If we have a valid buffer with a live job, just reopen a window for it
  if st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) and job_is_alive(st.job_id) then
    if cfg.window_mode == "attached" then
      st.win = termui.open_split_win_for_buf(st.bufnr, {
        position = cfg.position,
        width = cfg.width,
      })
    else
      st.win = termui.open_float_win_for_buf(st.bufnr, {
        title = 'Cursor Agent',
        border = 'rounded',
        width = 0.6,
        height = 0.6,
      })
    end
    return st.bufnr, st.win
  end

  -- Spawn a fresh terminal
  local argv = util.concat_argv(util.to_argv(cfg.cmd), cfg.args)
  local root = util.get_project_root()
  local bufnr, win, job_id
  
  if cfg.window_mode == "attached" then
    bufnr, win, job_id = termui.open_split_term({
      argv = argv,
      position = cfg.position,
      width = cfg.width,
      cwd = root,
      on_exit = function(code)
        if M._term_state then M._term_state.job_id = nil end
        if code ~= 0 then
          util.notify(('cursor-agent exited with code %d'):format(code), vim.log.levels.WARN)
        end
      end,
    })
  else
    bufnr, win, job_id = termui.open_float_term({
      argv = argv,
      title = 'Cursor Agent',
      border = 'rounded',
      width = 0.6,
      height = 0.6,
      cwd = root,
      on_exit = function(code)
        if M._term_state then M._term_state.job_id = nil end
        if code ~= 0 then
          util.notify(('cursor-agent exited with code %d'):format(code), vim.log.levels.WARN)
        end
      end,
    })
  end
  
  st.bufnr, st.win, st.job_id = bufnr, win, job_id
  return bufnr, win
end

function M._ensure_keymaps()
  if not vim.g.cursor_agent_mapped then
    vim.keymap.set('n', '<leader>ca', function()
      require('cursor-agent').toggle_terminal()
    end, { desc = 'Cursor Agent: Toggle terminal' })
    vim.g.cursor_agent_mapped = true
  end
end

--- Send text to the existing cursor-agent terminal without submitting
--- Opens the terminal if not already open, then sends the text
---@param text string The text to send to the terminal
function M.send_to_terminal(text)
  local st = M._term_state
  local cfg = config.get()
  
  -- Helper: check if the terminal job is still alive
  local function job_is_alive(job_id)
    if not job_id or job_id == 0 then return false end
    local ok, res = pcall(vim.fn.jobwait, { job_id }, 0)
    if not ok or type(res) ~= 'table' then return false end
    return res[1] == -1
  end
  
  -- If no live terminal, open one first
  if not st.job_id or not job_is_alive(st.job_id) then
    M.toggle_terminal()
    -- Wait a moment for the terminal to initialize
    vim.defer_fn(function()
      if st.job_id and job_is_alive(st.job_id) then
        -- Send text without trailing newline (no auto-submit)
        vim.fn.chansend(st.job_id, text)
      end
    end, 100)
    return
  end
  
  -- If terminal exists but window is closed, reopen it
  if not st.win or not vim.api.nvim_win_is_valid(st.win) then
    if cfg.window_mode == "attached" then
      st.win = termui.open_split_win_for_buf(st.bufnr, {
        position = cfg.position,
        width = cfg.width,
      })
    else
      st.win = termui.open_float_win_for_buf(st.bufnr, {
        title = 'Cursor Agent',
        border = 'rounded',
        width = 0.6,
        height = 0.6,
      })
    end
  end
  
  -- Send text without trailing newline (no auto-submit)
  vim.fn.chansend(st.job_id, text)
  
  -- Focus the terminal window and enter insert mode
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_set_current_win(st.win)
    vim.schedule(function()
      pcall(vim.cmd, 'startinsert')
    end)
  end
end

return M

local M = {}

local function resolve_size(value, total)
  if type(value) == "number" then
    if value > 0 and value < 1 then
      return math.floor(total * value)
    end
    return math.floor(value)
  end
  return math.floor(total * 0.6)
end

---Open a split (attached) terminal window and run the provided argv command
---@param opts table
---@field argv string[]|string Command to execute (argv table preferred)
---@field title string|nil Window title (not used in split mode)
---@field position string|nil "left" or "right" (defaults to "right")
---@field width number|nil Width in columns or 0-1 float for percentage (defaults to 0.2)
---@field on_exit fun(code: integer)|nil Optional on-exit callback
---@field cwd string|nil Working directory for the terminal process
---@return integer bufnr, integer win, integer job_id
function M.open_split_term(opts)
  opts = opts or {}
  local position = opts.position or "right"
  local width = resolve_size(opts.width or 0.2, vim.o.columns)
  
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Keep the terminal buffer around when the window closes so it can be reused
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  
  -- Create the split window
  local split_cmd = position == "left" and "leftabove vertical " or "rightbelow vertical "
  split_cmd = split_cmd .. width .. "split"
  
  vim.cmd(split_cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local argv = opts.argv

  -- Validate cwd. Fall back to current working directory when invalid
  local function resolve_cwd(cwd)
    if type(cwd) ~= 'string' or cwd == '' then return vim.fn.getcwd() end
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(cwd)
    if stat and stat.type == 'directory' then return cwd end
    return vim.fn.getcwd()
  end

  local job_id = vim.fn.termopen(argv, {
    cwd = resolve_cwd(opts.cwd),
    on_exit = function(_, code)
      if type(opts.on_exit) == "function" then
        pcall(opts.on_exit, code)
      end
    end,
  })

  pcall(vim.keymap.set, 'n', 'q', function()
    M.close(win)
  end, { buffer = bufnr, nowait = true, silent = true })

  -- Jump to bottom and enter terminal-mode for immediate typing
  local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if ok_lines then pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 }) end
  vim.schedule(function()
    pcall(vim.cmd, 'startinsert')
  end)

  return bufnr, win, job_id
end

---Open a split window for an existing buffer (no new job is started)
---@param bufnr integer Existing buffer number (e.g. a terminal buffer)
---@param opts table|nil Same window options as open_split_term (position/width)
---@return integer win
function M.open_split_win_for_buf(bufnr, opts)
  opts = opts or {}
  local position = opts.position or "right"
  local width = resolve_size(opts.width or 0.2, vim.o.columns)
  
  -- Create the split window
  local split_cmd = position == "left" and "leftabove vertical " or "rightbelow vertical "
  split_cmd = split_cmd .. width .. "split"
  
  vim.cmd(split_cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)

  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  -- Ensure the convenience close mapping exists on this buffer
  pcall(vim.keymap.set, 'n', 'q', function()
    M.close(win)
  end, { buffer = bufnr, nowait = true, silent = true })

  -- Jump to bottom and enter terminal-mode for immediate typing
  local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if ok_lines then pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 }) end
  vim.schedule(function()
    pcall(vim.cmd, 'startinsert')
  end)

  return win
end

---Open a floating terminal window and run the provided argv command
---@param opts table
---@field argv string[]|string Command to execute (argv table preferred)
---@field title string|nil Window title
---@field title_pos string|nil Title position (e.g. "center")
---@field border string|nil Border style (e.g. "rounded")
---@field width number|nil Width in columns or 0-1 float for percentage
---@field height number|nil Height in rows or 0-1 float for percentage
---@field on_exit fun(code: integer)|nil Optional on-exit callback
---@field cwd string|nil Working directory for the terminal process
---@return integer bufnr, integer win, integer job_id
function M.open_float_term(opts)
  opts = opts or {}
  local width = resolve_size(opts.width or 0.6, vim.o.columns)
  local height = resolve_size(opts.height or 0.6, vim.o.lines - vim.o.cmdheight)
  local row = math.floor(((vim.o.lines - vim.o.cmdheight) - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Keep the terminal buffer around when the window closes so it can be reused
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title or "Cursor Agent",
    title_pos = opts.title_pos or "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local argv = opts.argv

  -- Validate cwd. Fall back to current working directory when invalid
  local function resolve_cwd(cwd)
    if type(cwd) ~= 'string' or cwd == '' then return vim.fn.getcwd() end
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(cwd)
    if stat and stat.type == 'directory' then return cwd end
    return vim.fn.getcwd()
  end

  local job_id = vim.fn.termopen(argv, {
    cwd = resolve_cwd(opts.cwd),
    on_exit = function(_, code)
      if type(opts.on_exit) == "function" then
        pcall(opts.on_exit, code)
      end
    end,
  })

  pcall(vim.keymap.set, 'n', 'q', function()
    M.close(win)
  end, { buffer = bufnr, nowait = true, silent = true })

  -- Jump to bottom and enter terminal-mode for immediate typing
  local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if ok_lines then pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 }) end
  vim.schedule(function()
    pcall(vim.cmd, 'startinsert')
  end)

  return bufnr, win, job_id
end

---Open a floating window for an existing buffer (no new job is started)
---@param bufnr integer Existing buffer number (e.g. a terminal buffer)
---@param opts table|nil Same window options as open_float_term (title/border/size)
---@return integer win
function M.open_float_win_for_buf(bufnr, opts)
  opts = opts or {}
  local width = resolve_size(opts.width or 0.6, vim.o.columns)
  local height = resolve_size(opts.height or 0.6, vim.o.lines - vim.o.cmdheight)
  local row = math.floor(((vim.o.lines - vim.o.cmdheight) - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title or "Cursor Agent",
    title_pos = opts.title_pos or "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  -- Ensure the convenience close mapping exists on this buffer
  pcall(vim.keymap.set, 'n', 'q', function()
    M.close(win)
  end, { buffer = bufnr, nowait = true, silent = true })

  -- Jump to bottom and enter terminal-mode for immediate typing
  local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if ok_lines then pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 }) end
  vim.schedule(function()
    pcall(vim.cmd, 'startinsert')
  end)

  return win
end

function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

return M

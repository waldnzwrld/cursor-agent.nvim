local M = {}

function M.is_list(value)
  return type(value) == "table" and (#value > 0 or next(value) ~= nil)
end

function M.to_argv(cmd)
  if type(cmd) == "string" then
    return { cmd }
  end
  return vim.deepcopy(cmd)
end

function M.concat_argv(a, b)
  local result = {}
  if a then for _, v in ipairs(a) do table.insert(result, v) end end
  if b then for _, v in ipairs(b) do table.insert(result, v) end end
  return result
end

function M.executable_exists(exe)
  return vim.fn.executable(exe) == 1
end

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "cursor-agent" })
end

function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

-- Prefer jobstart for streaming; fall back to vim.system for simple runs
function M.run_job(cmd_argv, opts)
  opts = opts or {}
  local on_stdout = opts.on_stdout
  local on_stderr = opts.on_stderr
  local on_exit = opts.on_exit
  local input = opts.input

  local job_id = vim.fn.jobstart(cmd_argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if on_stdout and data then
        for _, line in ipairs(data) do
          if line ~= nil and line ~= "" then on_stdout(line, false) end
        end
      end
    end,
    on_stderr = function(_, data)
      if on_stderr and data then
        for _, line in ipairs(data) do
          if line ~= nil and line ~= "" then on_stderr(line, true) end
        end
      end
    end,
    on_exit = function(_, code)
      if on_exit then on_exit(code) end
    end,
  })

  if job_id <= 0 then
    return nil, "Failed to start job"
  end

  if input and input ~= "" then
    vim.fn.chansend(job_id, input)
    vim.fn.chanclose(job_id, "stdin")
  end

  return job_id
end

function M.run_system(cmd_argv, opts, on_complete)
  opts = opts or {}
  local input = opts.input or ""
  local timeout = opts.timeout_ms or 60000
  if vim.system then
    vim.system(cmd_argv, { text = true, stdin = input, timeout = timeout }, function(res)
      on_complete({
        code = res.code,
        stdout = res.stdout or "",
        stderr = res.stderr or "",
      })
    end)
  else
    -- Fallback to blocking systemlist; not ideal but keeps compatibility
    local cmd = table.concat(cmd_argv, " ")
    if input ~= "" then
      -- Best-effort: write to a temp file and redirect as stdin
      local tmp = vim.fn.tempname()
      local fd = assert(io.open(tmp, "w"))
      fd:write(input)
      fd:close()
      cmd = cmd .. " < " .. tmp
    end
    local out = vim.fn.systemlist(cmd)
    local code = vim.v.shell_error
    on_complete({ code = code, stdout = table.concat(out, "\n"), stderr = "" })
  end
end

---Write content to a temporary file and return its path
---@param content string
---@param suffix string|nil Optional suffix or extension (e.g. ".txt")
---@return string filepath
function M.write_tempfile(content, suffix)
  local name = vim.fn.tempname()
  if suffix and suffix ~= '' then
    name = name .. suffix
  end
  local ok, err
  local fd
  ok, fd = pcall(io.open, name, "w")
  if not ok or not fd then
    error("Failed to create tempfile: " .. tostring(err))
  end
  fd:write(content or "")
  fd:close()
  return name
end

local function path_dirname(path)
  if not path or path == '' then return '' end
  return path:match("^(.*)/[^/]*$") or path
end

local function path_join(a, b)
  if a:sub(-1) == '/' then return a .. b end
  return a .. '/' .. b
end

local function path_exists(p)
  local stat = vim.loop.fs_stat(p)
  return stat ~= nil
end

local function is_directory(p)
  if not p or p == '' then return false end
  local stat = (vim.uv or vim.loop).fs_stat(p)
  return stat and stat.type == 'directory'
end

---Find the project root by walking up for markers
---@param startpath string|nil
---@param markers string[]|nil
---@return string
function M.find_root(startpath, markers)
  local uv = vim.uv or vim.loop
  local path = startpath or vim.fn.getcwd()
  if not path or path == '' then path = (uv.cwd and uv.cwd()) or '.' end
  markers = markers or { '.git', 'package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'Makefile' }

  -- If startpath is a file, use its directory
  local stat = uv.fs_stat(path)
  if stat and stat.type == 'file' then
    path = path_dirname(path)
  end

  local function has_marker(dir)
    for _, m in ipairs(markers) do
      if path_exists(path_join(dir, m)) then return true end
    end
    return false
  end

  -- Prefer vim.fs.find when available
  if vim.fs and vim.fs.find then
    local found = vim.fs.find(markers, { upward = true, path = path, stop = '/' })
    if type(found) == 'table' and #found > 0 then
      local root = path_dirname(found[1])
      if is_directory(root) then return root end
    end
  end

  -- Manual walk up to look for markers
  local prev = nil
  while path and path ~= prev do
    if has_marker(path) then return path end
    prev = path
    local parent = path_dirname(path)
    if parent == path or parent == '' then break end
    path = parent
  end

  -- Fallbacks: prefer cwd, else directory of startpath, and ensure it's a directory
  local cwd = vim.fn.getcwd()
  if is_directory(cwd) then return cwd end

  if startpath and startpath ~= '' then
    local s = uv.fs_stat(startpath)
    if s and s.type == 'file' then
      local dir = path_dirname(startpath)
      if is_directory(dir) then return dir end
    elseif s and s.type == 'directory' then
      return startpath
    end
  end
  return '.'
end

---Get best-effort project root for current buffer
function M.get_project_root()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  -- Prefer LSP root when available
  local lsp = vim.lsp or nil
  local function lsp_root()
    if not lsp then return nil end
    local get_clients = lsp.get_clients or lsp.get_active_clients
    if not get_clients then return nil end
    local clients = get_clients({ bufnr = buf }) or {}
    for _, client in ipairs(clients) do
      local root = client.config and client.config.root_dir or client.root_dir
      if type(root) == 'string' and root ~= '' and is_directory(root) then
        return root
      end
    end
    return nil
  end

  local lsp_root_dir = lsp_root()
  if lsp_root_dir then return lsp_root_dir end

  -- Some special buffers (e.g. terminals, plugins) have non-file names
  if not name or name == '' or name:match('^%w+://') then
    return M.find_root(vim.fn.getcwd())
  end
  return M.find_root(name)
end

return M

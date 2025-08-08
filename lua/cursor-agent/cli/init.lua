local config = require('cursor-agent.config')
local util = require('cursor-agent.util')

local M = {}

local function build_argv(extra_args)
  local cfg = config.get()
  local base = util.to_argv(cfg.cmd)
  if not base or #base == 0 then
    return nil, "Invalid cmd configured"
  end
  local exe = base[1]
  if not util.executable_exists(exe) then
    return nil, string.format("Executable not found: %s", exe)
  end
  local argv = util.concat_argv(base, cfg.args)
  argv = util.concat_argv(argv, extra_args)
  return argv
end

-- Run the CLI and return full output via callback
function M.run(opts, on_complete)
  opts = opts or {}
  local argv, err = build_argv(opts.args)
  if not argv then
    util.err(err)
    if on_complete then on_complete({ code = -1, stdout = '', stderr = err }) end
    return
  end
  local cfg = config.get()
  util.run_system(argv, { input = cfg.use_stdin and (opts.input or '') or '', timeout_ms = cfg.timeout_ms }, function(res)
    if on_complete then on_complete(res) end
  end)
end

-- Stream stdout/stderr lines to callbacks
function M.run_stream(opts, on_data, on_exit)
  opts = opts or {}
  local argv, err = build_argv(opts.args)
  if not argv then
    util.err(err)
    if on_exit then on_exit(-1) end
    return
  end
  local cfg = config.get()
  local function on_stdout(line)
    if on_data then on_data(line, false) end
  end
  local function on_stderr(line)
    if on_data then on_data(line, true) end
  end
  util.run_job(argv, {
    input = cfg.use_stdin and (opts.input or '') or '',
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = function(code)
      if on_exit then on_exit(code) end
    end,
  })
end

return M

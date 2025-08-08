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

function M.open_float(opts)
  opts = opts or {}
  local width = resolve_size(opts.width or 0.5, vim.o.columns)
  local height = resolve_size(opts.height or 0.6, vim.o.lines - vim.o.cmdheight)
  local row = math.floor(((vim.o.lines - vim.o.cmdheight) - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "cursor-agent-output")

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

  return bufnr, win
end

function M.set_lines(bufnr, lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Append raw text (can include newlines) and optionally scroll to end
function M.append_text(bufnr, win, text, opts)
  opts = opts or {}
  local auto_scroll = opts.auto_scroll
  local is_err = opts.is_err
  if not text or text == '' then return end

  local prefix = is_err and "[stderr] " or ""
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if is_err then
    -- For stderr, always add new prefixed lines
    local lines = {}
    for s in (prefix .. text):gmatch("([^\n]*)\n?") do
      table.insert(lines, s)
    end
    if #lines > 0 and lines[#lines] == '' then table.remove(lines, #lines) end
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, lines)
  else
    -- For normal output, append to the current last line when no newline present
    local parts = {}
    for s in text:gmatch("([^\n]*)\n?") do table.insert(parts, s) end
    if #parts == 0 then return end
    -- Fetch last line text
    local last_index = math.max(line_count, 1)
    local last_line = ''
    if line_count > 0 then
      last_line = vim.api.nvim_buf_get_lines(bufnr, last_index - 1, last_index, false)[1] or ''
    end
    -- First part extends the last line
    local new_last = last_line .. parts[1]
    vim.api.nvim_buf_set_lines(bufnr, last_index - 1, last_index, false, { new_last })
    -- Remaining parts become new lines
    if #parts > 1 then
      local tail = {}
      for i = 2, #parts do table.insert(tail, parts[i]) end
      -- Remove trailing empty line if split produced one at end
      if #tail > 0 and tail[#tail] == '' then table.remove(tail, #tail) end
      if #tail > 0 then
        local lc = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, lc, lc, false, tail)
      end
    end
  end

  if auto_scroll and win and vim.api.nvim_win_is_valid(win) then
    local last = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(win, { last, 0 })
  end
end

-- Backwards compat for previous callsites
function M.append_line(bufnr, line, is_err)
  M.append_text(bufnr, nil, line, { is_err = is_err })
end

function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

return M

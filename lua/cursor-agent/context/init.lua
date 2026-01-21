local M = {}

--- Validate that a buffer can have selections extracted
--- Rejects terminal, help, and other special buffers
---@param bufnr number Buffer number to validate
---@return boolean valid True if buffer is a normal file buffer
local function validate_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local buftype = vim.bo[bufnr].buftype
  -- Only allow normal file buffers (empty buftype)
  if buftype ~= "" then
    return false
  end
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  -- Reject special buffer schemes (term://, fugitive://, etc.)
  if filepath:match("^%w+://") then
    return false
  end
  return true
end

local function get_visual_marks()
  local ok_s, cs = pcall(vim.api.nvim_buf_get_mark, 0, "<")
  local ok_e, ce = pcall(vim.api.nvim_buf_get_mark, 0, ">")
  if not ok_s or not ok_e then return nil end
  if not cs or not ce then return nil end
  -- Validate mark positions are sensible
  if cs[1] <= 0 or ce[1] <= 0 then return nil end
  return { start_row = cs[1], start_col = cs[2], end_row = ce[1], end_col = ce[2] }
end

--- Get visual selection content
---@return string|nil content The selected text, or nil if invalid
function M.get_visual_selection()
  local result = M.get_visual_selection_with_context()
  if not result then return nil end
  return result.content
end

--- Get visual selection with full context (file path, line numbers)
---@return table|nil result Table with content, filepath, start_line, end_line, filetype
function M.get_visual_selection_with_context()
  local bufnr = vim.api.nvim_get_current_buf()
  
  -- Validate buffer type (reject terminal, help, etc.)
  if not validate_buffer(bufnr) then
    return nil
  end
  
  local marks = get_visual_marks()
  if not marks then return nil end
  
  -- Store original 1-indexed line numbers for context
  local start_line = marks.start_row
  local end_line = marks.end_row
  
  -- Convert to 0-indexed for nvim_buf_get_lines
  local srow, scol = marks.start_row - 1, marks.start_col
  local erow, ecol = marks.end_row - 1, marks.end_col
  
  -- Swap if selection was made backwards
  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
    start_line, end_line = end_line, start_line
  end
  
  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false)
  if #lines == 0 then return nil end
  
  -- Bound ecol to actual line length to prevent issues with vim.v.maxcol
  local last_line_len = #lines[#lines]
  if ecol > last_line_len then
    ecol = last_line_len
  end
  
  -- Check what visual mode was used
  local mode = vim.fn.visualmode()
  local content
  
  if mode == "V" then
    -- Line-wise: return full lines as-is
    content = table.concat(lines, "\n")
  elseif mode == "v" then
    -- Character-wise: trim to selection bounds
    if #lines == 1 then
      -- ecol + 1 to include the character under cursor
      lines[1] = string.sub(lines[1], scol + 1, ecol + 1)
    else
      lines[1] = string.sub(lines[1], scol + 1)
      lines[#lines] = string.sub(lines[#lines], 1, ecol + 1)
    end
    content = table.concat(lines, "\n")
  elseif mode == "\22" then
    -- Block-wise (Ctrl-V): extract the rectangular block
    local first_line_len = #lines[1]
    if scol > first_line_len then scol = first_line_len end
    local result = {}
    for _, line in ipairs(lines) do
      local line_len = #line
      local start_col = math.min(scol + 1, line_len + 1)
      local end_col = math.min(ecol + 1, line_len)
      if start_col <= line_len then
        table.insert(result, string.sub(line, start_col, end_col))
      else
        table.insert(result, "")
      end
    end
    content = table.concat(result, "\n")
  else
    -- Fallback: return full lines
    content = table.concat(lines, "\n")
  end
  
  -- Get file context
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  
  -- Convert to relative path from cwd
  local relative_path = vim.fn.fnamemodify(filepath, ":.")
  if relative_path == "" then
    relative_path = filepath
  end
  
  return {
    content = content,
    filepath = relative_path,
    absolute_path = filepath,
    start_line = start_line,
    end_line = end_line,
    filetype = filetype,
  }
end

function M.get_buffer_context()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local filetype = vim.bo[buf].filetype
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return {
    filepath = name,
    filetype = filetype,
    content = table.concat(lines, "\n"),
  }
end

return M

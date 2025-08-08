local M = {}

local function get_visual_marks()
  local _, cs = pcall(vim.api.nvim_buf_get_mark, 0, "<")
  local _, ce = pcall(vim.api.nvim_buf_get_mark, 0, ">")
  if not cs or not ce then return nil end
  return { start_row = cs[1], start_col = cs[2], end_row = ce[1], end_col = ce[2] }
end

function M.get_visual_selection()
  local marks = get_visual_marks()
  if not marks then return nil end
  local srow, scol = marks.start_row - 1, marks.start_col
  local erow, ecol = marks.end_row - 1, marks.end_col
  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
  end
  local lines = vim.api.nvim_buf_get_lines(0, srow, erow + 1, false)
  if #lines == 0 then return nil end
  if #lines == 1 then
    lines[1] = string.sub(lines[1], scol + 1, ecol)
  else
    lines[1] = string.sub(lines[1], scol + 1)
    lines[#lines] = string.sub(lines[#lines], 1, ecol)
  end
  return table.concat(lines, "\n")
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

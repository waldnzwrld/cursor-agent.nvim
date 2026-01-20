-- Highlight management for Cursor Agent modified lines
local M = {}

local config = require('cursor-agent.config')

-- Namespace for our highlights
local ns_id = nil

-- Track which buffers have active highlights
M._highlighted_buffers = {} -- { [bufnr] = true }

-- Pending highlights for files that weren't open when modified
-- { [filepath] = { modified = {line_nr, ...}, added = {line_nr, ...}, timestamp = number } }
M._pending_highlights = {}

---Get or create the highlight namespace
---@return integer
local function get_namespace()
  if not ns_id then
    ns_id = vim.api.nvim_create_namespace('CursorAgentHighlight')
  end
  return ns_id
end

---Ensure the highlight group exists
local function ensure_highlight_group()
  local cfg = config.get()
  local group = cfg.highlight_group or 'CursorAgentChange'
  
  -- Check if the highlight group already has a definition
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
  if not ok or (type(hl) == 'table' and vim.tbl_isempty(hl)) then
    -- Define a default highlight (light green background for changes)
    vim.api.nvim_set_hl(0, group, {
      bg = '#2d4f2d',  -- Dark green background
      default = true,  -- Allow user to override
    })
  end
end

---Compute which lines changed between old and new content
---@param old_lines string[] Lines before reload
---@param new_lines string[] Lines after reload
---@return table changed_lines { added = {line_nr, ...}, modified = {line_nr, ...} }
function M.compute_changed_lines(old_lines, new_lines)
  local result = {
    added = {},
    modified = {},
  }
  
  -- Use vim.diff if available (Neovim 0.6+)
  if vim.diff then
    local old_text = table.concat(old_lines, '\n')
    local new_text = table.concat(new_lines, '\n')
    
    local diff = vim.diff(old_text, new_text, {
      result_type = 'indices',
      algorithm = 'histogram',
    })
    
    if diff and type(diff) == 'table' then
      for _, hunk in ipairs(diff) do
        -- hunk format: {old_start, old_count, new_start, new_count}
        local new_start, new_count = hunk[3], hunk[4]
        
        if new_count > 0 then
          for i = new_start, new_start + new_count - 1 do
            if i <= #new_lines then
              table.insert(result.modified, i)
            end
          end
        end
      end
    end
  else
    -- Fallback: simple line-by-line comparison
    local max_lines = math.max(#old_lines, #new_lines)
    for i = 1, max_lines do
      local old_line = old_lines[i] or ''
      local new_line = new_lines[i] or ''
      
      if old_line ~= new_line then
        if i > #old_lines then
          table.insert(result.added, i)
        else
          table.insert(result.modified, i)
        end
      end
    end
  end
  
  return result
end

---Apply highlights to changed lines in a buffer
---@param bufnr integer Buffer number
---@param changed_lines table { added = {...}, modified = {...} }
function M.apply_highlights(bufnr, changed_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  local cfg = config.get()
  if not cfg.highlight_changes then return end
  
  ensure_highlight_group()
  local ns = get_namespace()
  local group = cfg.highlight_group or 'CursorAgentChange'
  
  -- Clear existing highlights first
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  
  -- Apply highlights to modified lines
  local all_changed = {}
  for _, line_nr in ipairs(changed_lines.modified or {}) do
    table.insert(all_changed, line_nr)
  end
  for _, line_nr in ipairs(changed_lines.added or {}) do
    table.insert(all_changed, line_nr)
  end
  
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, line_nr in ipairs(all_changed) do
    if line_nr >= 1 and line_nr <= line_count then
      -- Use extmarks for more robust highlighting
      vim.api.nvim_buf_set_extmark(bufnr, ns, line_nr - 1, 0, {
        end_row = line_nr - 1,
        end_col = 0,
        line_hl_group = group,
        priority = 100,
      })
    end
  end
  
  if #all_changed > 0 then
    M._highlighted_buffers[bufnr] = true
    M.setup_clear_on_modify(bufnr)
  end
end

---Highlight changes between old and new buffer content
---@param bufnr integer Buffer number
---@param old_lines string[] Lines before reload
function M.highlight_buffer_changes(bufnr, old_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  local cfg = config.get()
  if not cfg.highlight_changes then return end
  
  -- Get new lines from buffer
  local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Compute what changed
  local changed_lines = M.compute_changed_lines(old_lines, new_lines)
  
  -- Apply highlights
  M.apply_highlights(bufnr, changed_lines)
  
  -- Notify user of changes
  local total_changed = #(changed_lines.modified or {}) + #(changed_lines.added or {})
  if total_changed > 0 then
    local util = require('cursor-agent.util')
    util.notify(string.format('Highlighted %d modified line(s)', total_changed), vim.log.levels.INFO)
  end
end

---Clear highlights from a buffer
---@param bufnr integer|nil Buffer number (nil for current buffer)
function M.clear_highlights(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  
  local ns = get_namespace()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  M._highlighted_buffers[bufnr] = nil
end

---Clear highlights from all buffers
function M.clear_all_highlights()
  local ns = get_namespace()
  for bufnr, _ in pairs(M._highlighted_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
  M._highlighted_buffers = {}
end

-- Track if we're in a reload-triggered TextChanged event (don't clear highlights)
M._reload_in_progress = {} -- { [bufnr] = true }

---Mark that a reload is starting (to ignore TextChanged events from edit!)
---@param bufnr integer
function M.begin_reload(bufnr)
  M._reload_in_progress[bufnr] = true
end

---Mark that a reload has completed
---@param bufnr integer
function M.end_reload(bufnr)
  -- Use a longer delay to ensure all TextChanged events from edit! have fired
  vim.defer_fn(function()
    M._reload_in_progress[bufnr] = nil
  end, 300)
end

---Set up autocmds to clear highlights when buffer is modified BY THE USER
---@param bufnr integer
function M.setup_clear_on_modify(bufnr)
  local group_name = 'CursorAgentHighlightClear_' .. bufnr
  
  -- Clear existing group if it exists
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
  
  -- Defer autocmd setup to avoid catching the TextChanged event from the reload itself.
  -- Use a longer delay (500ms) to let edit! finish all its events.
  vim.defer_fn(function()
    -- Guard: buffer may have become invalid or highlights may have been cleared
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not M._highlighted_buffers[bufnr] then return end
    
    local group = vim.api.nvim_create_augroup(group_name, { clear = true })
    
    -- Clear highlights when user modifies the buffer (not from reload)
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = group,
      buffer = bufnr,
      callback = function()
        -- Ignore TextChanged events triggered by reload/edit!
        if M._reload_in_progress[bufnr] then
          return
        end
        
        M.clear_highlights(bufnr)
        -- Clean up this autocmd group
        pcall(vim.api.nvim_del_augroup_by_name, group_name)
        return true -- Remove this autocmd after it fires
      end,
    })
    
    -- Also clear on buffer delete
    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
      group = group,
      buffer = bufnr,
      once = true,
      callback = function()
        M._highlighted_buffers[bufnr] = nil
        pcall(vim.api.nvim_del_augroup_by_name, group_name)
      end,
    })
  end, 500) -- Longer delay to ensure edit! events have fully cleared
end

---Check if a buffer has active highlights
---@param bufnr integer|nil
---@return boolean
function M.has_highlights(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M._highlighted_buffers[bufnr] == true
end

---Store pending highlights for a file that isn't currently open
---@param filepath string Absolute path to the file
---@param changed_lines table { added = {...}, modified = {...} }
function M.store_pending_highlights(filepath, changed_lines)
  local total = #(changed_lines.modified or {}) + #(changed_lines.added or {})
  if total == 0 then return end
  
  M._pending_highlights[filepath] = {
    modified = changed_lines.modified or {},
    added = changed_lines.added or {},
    timestamp = os.time(),
  }
end

---Check and apply pending highlights when a buffer is opened
---@param bufnr integer Buffer number
---@return boolean applied Whether highlights were applied
function M.apply_pending_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  
  local cfg = config.get()
  if not cfg.highlight_changes then return false end
  
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == '' then return false end
  
  filepath = vim.fn.fnamemodify(filepath, ':p')
  local pending = M._pending_highlights[filepath]
  
  if not pending then return false end
  
  -- Clear pending (we're about to apply them)
  M._pending_highlights[filepath] = nil
  
  -- Apply the highlights
  M.apply_highlights(bufnr, {
    modified = pending.modified,
    added = pending.added,
  })
  
  local total = #pending.modified + #pending.added
  if total > 0 then
    local util = require('cursor-agent.util')
    util.notify(string.format('Applied %d pending highlight(s)', total), vim.log.levels.INFO)
  end
  
  return total > 0
end

---Clear pending highlights for a file
---@param filepath string|nil Absolute path (nil clears all)
function M.clear_pending_highlights(filepath)
  if filepath then
    M._pending_highlights[filepath] = nil
  else
    M._pending_highlights = {}
  end
end

---Check if a file has pending highlights
---@param filepath string
---@return boolean
function M.has_pending_highlights(filepath)
  return M._pending_highlights[filepath] ~= nil
end

return M

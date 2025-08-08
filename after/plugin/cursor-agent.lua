pcall(function()
  require('cursor-agent').setup({})
end)

-- Optional: Keep mapping here too if users don't load plugin via setup
vim.keymap.set('n', '<leader>ca', function()
  require('cursor-agent').toggle_terminal()
end, { desc = 'Cursor Agent: Toggle terminal' })

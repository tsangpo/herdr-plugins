-- Neovim plugin managers install the repository root. Keep the implementation
-- in the Herdr plugin's runtime directory and expose the same module here.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
local runtime = root .. "/ime-keeper/nvim"
vim.opt.runtimepath:prepend(runtime)
return dofile(runtime .. "/lua/ime_keeper/init.lua")

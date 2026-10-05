-- Optional smoke test with an already-installed LazyVim dependency cache.
-- IME_KEEPER_LAZY_ROOT=/path/to/nvim/lazy nvim --headless -u NONE -i NONE -l nvim/tests/lazyvim.lua
local cache = assert(vim.env.IME_KEEPER_LAZY_ROOT, "set IME_KEEPER_LAZY_ROOT to an installed LazyVim plugin cache")
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local init = string.format([[
vim.opt.runtimepath:prepend(%q .. '/lazy.nvim')
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'
_G.ime_events = {}
_G.ime_errors = {}
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then table.insert(_G.ime_errors, tostring(message)) end
end
require('lazy').setup({
  root = %q,
  lockfile = %q .. '/lazy-lock.json',
  spec = {
    { dir = %q .. '/LazyVim', import = 'lazyvim.plugins', opts = { colorscheme = 'habamax' } },
    {
      'tsangpo/herdr-plugins', name = 'ime-keeper', dir = %q,
      main = 'ime_keeper', lazy = false,
      opts = { reporter = function(event)
        table.insert(_G.ime_events, event)
        return true
      end },
    },
  },
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
})
]], cache, cache, temp, cache, root)
vim.fn.writefile(vim.split(init, "\n"), temp .. "/init.lua")
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", temp .. "/init.lua", "-i", "NONE" }, {
  rpc = true,
  env = { XDG_CONFIG_HOME = temp .. "/config", XDG_DATA_HOME = temp .. "/data", XDG_STATE_HOME = temp .. "/state", XDG_CACHE_HOME = temp .. "/cache" },
})
assert(child > 0)
local function lua(code) return vim.rpcrequest(child, "nvim_exec_lua", code, {}) end
local ok, err = pcall(function()
  assert(vim.wait(5000, function() return lua("return #(_G.ime_events or {}) > 0") end, 10), "LazyVim startup did not report")
  assert(lua("return require('lazy.core.config').plugins['ime-keeper']._.loaded ~= nil"))
  assert(lua("return _G.ime_events[1].event == 'start'"))
  vim.rpcrequest(child, "nvim_input", "i")
  assert(vim.wait(2000, function() return lua("return _G.ime_events[#_G.ime_events].mode == 'edit'") end, 5))
  vim.rpcrequest(child, "nvim_input", "<Esc>")
  assert(vim.wait(2000, function() return lua("return _G.ime_events[#_G.ime_events].mode == 'command'") end, 5))
  assert(lua("return type(require('ime_keeper.local_transport').connect) == 'function'"))
  assert(lua("return type(require('ime_keeper.remote_transport').connect) == 'function'"))
  assert(lua("return require('ime_keeper') == require('ime_keeper').setup({})"))
  local errors = lua("return _G.ime_errors")
  assert(#errors == 0, table.concat(errors, "\n"))
  vim.rpcnotify(child, "nvim_command", "qa!")
  assert(vim.fn.jobwait({ child }, 2000)[1] == 0)
end)
if not ok then vim.fn.jobstop(child) end
vim.fn.delete(temp, "rf")
assert(ok, err)
print("LazyVim eager loading and mode transitions passed")

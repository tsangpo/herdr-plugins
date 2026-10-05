-- Run from ime-keeper: nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
local root = vim.fn.getcwd() .. "/nvim"
vim.opt.runtimepath:prepend(root)
local events_file = vim.fn.tempname()
local setup = string.format([[
  vim.opt.runtimepath:prepend(%q)
  _G.ime_events = {}
  require('ime_keeper').setup({ reporter = function(event)
    event.testParentPID = (vim.uv or vim.loop).os_getppid()
    table.insert(_G.ime_events, event)
    vim.fn.writefile({vim.json.encode(event)}, %q, 'a')
    return true
  end })
]], root, events_file)
local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "--cmd", "lua " .. setup }, { rpc = true })
assert(child > 0, "could not start embedded Neovim")

local function rpc(method, ...) return vim.rpcrequest(child, method, ...) end
local function lua(code, ...) return rpc("nvim_exec_lua", code, { ... }) end
local function events() return lua("return _G.ime_events") end
local function wait_for(predicate, message)
  assert(vim.wait(2000, predicate, 5), message)
end
local function input(keys, mode)
  rpc("nvim_input", keys)
  wait_for(function() return rpc("nvim_get_mode").mode:sub(1, #mode) == mode end, "mode after " .. keys .. " should be " .. mode)
end
local function last(kind, mode)
  local list = events()
  local event = list[#list]
  assert(event.event == kind and event.mode == mode, vim.inspect(event))
end

local ok, err = pcall(function()
  wait_for(function() return #events() > 0 end, "missing startup snapshot")
  last("start", "command")
  local count = lua("return #vim.api.nvim_get_autocmds({group='ImeKeeper'})")
  lua("require('ime_keeper').setup({reporter=function() error('duplicate setup') end})")
  assert(lua("return #vim.api.nvim_get_autocmds({group='ImeKeeper'})") == count)

  input("i", "i"); last("mode", "edit")
  input("hello<Esc>", "n"); last("mode", "command")
  input("a", "i"); last("mode", "edit")
  input("<C-o>", "ni"); last("mode", "command")
  input("h", "i"); last("mode", "edit")
  input("<C-c>", "n"); last("mode", "command")
  input("R", "R"); last("mode", "edit")
  input("<Esc>", "n"); last("mode", "command")
  local previous = #events()
  input("v", "v")
  input("<Esc>", "n")
  input(":", "c")
  input("<Esc>", "n")
  assert(#events() == previous, "same-category modes should not report again")
  lua("vim.api.nvim_exec_autocmds('FocusGained', {})")
  last("snapshot", "command")
  lua("vim.api.nvim_exec_autocmds('VimSuspend', {})")
  last("suspend", "command")
  lua("vim.api.nvim_exec_autocmds('VimResume', {})")
  last("resume", "command")
  local list = events()
  for i, event in ipairs(list) do
    assert(event.sequence == i and event.version == 1 and event.pid > 0)
    assert(event.instanceID == list[1].instanceID)
  end
  -- An actual quit exercises VimLeavePre, not a synthetic exit notification.
  vim.rpcnotify(child, "nvim_command", "qa!")
  assert(vim.fn.jobwait({ child }, 2000)[1] == 0)
  local lines = vim.fn.readfile(events_file)
  assert(vim.json.decode(lines[#lines]).event == "exit")
end)
if not ok then vim.fn.jobstop(child) end
vim.fn.delete(events_file)
assert(ok, err)

-- A real TUI may run the Lua core in a separate `nvim --embed` child. Cover
-- that startup shape as well as the directly embedded/headless cases above.
local tui = vim.fn.jobstart({
  vim.v.progpath, "-u", "NONE", "-i", "NONE", "--cmd", "lua " .. setup,
  "-c", "lua vim.defer_fn(function() vim.api.nvim_input('i') end, 100)",
  "-c", "lua vim.defer_fn(function() vim.api.nvim_input('<Esc>') end, 250)",
  "-c", "lua vim.defer_fn(function() vim.cmd('qa!') end, 500)",
}, { pty = true, width = 80, height = 24, on_stdout = function() end })
assert(tui > 0)
local tui_pid = vim.fn.jobpid(tui)
local tui_exit = vim.fn.jobwait({ tui }, 4000)[1]
if tui_exit == -1 then vim.fn.jobstop(tui) end
assert(tui_exit == 0, "TUI Neovim did not exit successfully")
local tui_events = vim.tbl_map(vim.json.decode, vim.fn.readfile(events_file))
vim.fn.delete(events_file)
assert(tui_events[1].event == "start")
assert(tui_events[1].pid == tui_pid or tui_events[1].testParentPID == tui_pid, "unexpected TUI/core process relationship")
assert(vim.iter(tui_events):any(function(event) return event.event == "mode" and event.mode == "edit" end))
assert(tui_events[#tui_events].event == "exit")

-- Exercise context polling, argv handling, timeout/error propagation without
-- touching the user's Herdr registration or macOS input source.
local original_system = vim.system
local original_socket, original_pane = vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID
vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID = "/tmp/ime-test.sock", "w:p"
local calls = {}
local context = {
  version = "1", sourceID = "local", socketPath = vim.env.HERDR_SOCKET_PATH,
  configDirectory = "/tmp/config with spaces", stateDirectory = "/tmp/state with spaces",
  executable = "/tmp/plugin with spaces/ime-keeper", herdrExecutable = "/tmp/herdr",
}
vim.system = function(argv, opts)
  table.insert(calls, { argv = argv, opts = opts })
  return { wait = function(_, timeout)
    assert(timeout > 0 and timeout <= 2000)
    if argv[3] == "action" then
      return { code = 0, stdout = vim.json.encode({ result = { log = { log_id = "123", status = "running" } } }) }
    elseif argv[3] == "log" then
      return { code = 0, stdout = vim.json.encode({ result = { logs = {
        { log_id = "other", status = "succeeded", stdout = "not our result" },
        { log_id = "123", status = "succeeded", stdout = vim.json.encode(context) },
      } } }) }
    end
    return { code = 0, stdout = "" }
  end }
end
local reporter = require("ime_keeper.local_transport").connect({})
reporter({ event = "mode", mode = "edit" })
assert(#calls == 3)
assert(calls[3].argv[1] == context.executable and calls[3].argv[2] == "editor-event")
assert(vim.json.decode(calls[3].argv[3]).mode == "edit")
assert(calls[3].opts.env.HERDR_PANE_ID == "w:p")
assert(calls[3].opts.env.HERDR_PLUGIN_STATE_DIR == context.stateDirectory)
vim.system = function() return { wait = function() return { code = 124, stderr = "timeout" } end } end
assert(not pcall(reporter, { event = "mode" }), "transport failures must propagate")
vim.system = original_system
vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID = original_socket, original_pane

-- Late loading (including a LazyVim config loaded after VimEnter) synchronizes
-- immediately, and failed reports recover by sending a snapshot.
child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE" }, { rpc = true })
ok, err = pcall(function()
  wait_for(function() return rpc("nvim_eval", "v:vim_did_enter") == 1 end, "late-loading child did not start")
  lua([[
    vim.opt.runtimepath:prepend(...)
    local late, fail = {}, false
    require('ime_keeper').setup({ reporter = function(event)
      table.insert(late, event)
      if fail then return false, 'test failure' end
      return true
    end })
    assert(late[1].event == 'start')
    fail = true
    vim.api.nvim_exec_autocmds('FocusGained', {})
    fail = false
    vim.api.nvim_exec_autocmds('FocusGained', {})
    assert(late[#late].event == 'snapshot')
    assert(require('ime_keeper').status().error == nil)
  ]], root)
  vim.rpcnotify(child, "nvim_command", "qa!")
  assert(vim.fn.jobwait({ child }, 2000)[1] == 0)
end)
if not ok then vim.fn.jobstop(child) end
assert(ok, err)
print("Neovim mode collection and local transport tests passed")

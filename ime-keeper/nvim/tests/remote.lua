-- Run from ime-keeper; a real Unix socket fake exercises the asynchronous adapter.
local uv = vim.uv or vim.loop
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/nvim")
local path = "/tmp/ik-lua-" .. uv.os_getpid() .. ".sock"
local server = uv.new_pipe(false)
local peers, reports = {}, {}
local pane, terminal = "w:p1", "terminal-1"
local reject, malformed = true, false
assert(server:bind(path))
server:listen(32, function(err)
  assert(not err, err)
  local peer = uv.new_pipe(false)
  peers[#peers + 1] = peer
  server:accept(peer)
  local buffer = ""
  peer:read_start(function(read_err, data)
    assert(not read_err, read_err)
    if not data then if not peer:is_closing() then peer:close() end; return end
    buffer = buffer .. data
    local line = buffer:match("^(.-)\n")
    if not line then return end
    local request = vim.json.decode(line)
    local response = { id = request.id }
    if request.method == "pane.current" then
      if request.params.caller_pane_id == pane then
        response.result = { pane = { pane_id = pane, terminal_id = terminal } }
      else
        response.error = { message = "pane not found" }
      end
    elseif request.method == "session.snapshot" then
      response.result = { snapshot = { panes = { { pane_id = pane, terminal_id = terminal } } } }
    elseif request.method == "pane.report_metadata" then
      if reject then
        reject = false
        response.error = { message = "temporary report failure" }
      else
        reports[#reports + 1] = request.params
        response.result = { type = "ok" }
      end
    else
      error("unexpected method " .. request.method)
    end
    local break_frame = malformed and request.method == "pane.report_metadata"
    local text = break_frame and "bad json\n" or vim.json.encode(response) .. "\n"
    if break_frame then malformed = false end
    -- Force fragmented responses, including the trailing newline.
    peer:write(text:sub(1, 4))
    peer:write(text:sub(5))
  end)
end)
local saved_socket, saved_pane = vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID
vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID = path, pane
local reporter, status = require("ime_keeper.remote_transport").connect({ timeout_ms = 200 })
local function event(seq, mode, kind)
  return { version = 1, instanceID = "test-instance", pid = uv.os_getpid(),
    sequence = seq, event = kind or "mode", mode = mode }
end
local function wait(predicate, message)
  assert(vim.wait(4000, predicate, 5), message .. ": " .. vim.inspect(status()))
end
local ok, failure = pcall(function()
  local began = uv.hrtime()
  reporter(event(1, "command", "start"))
  assert(uv.hrtime() - began < 100000000, "reporter blocked the editor")
  wait(function() return status().connection == "retrying" end, "failure was not surfaced")
  reporter(event(2, "edit"))
  reporter(event(3, "command"))
  wait(function() return status().acknowledged_sequence == 3 end, "did not reconnect with latest state")
  assert(#reports == 1 and reports[1].tokens.ime_keeper_sequence == "3", "replayed stale queued modes")
  assert(reports[1].ttl_ms == 5000 and reports[1].source == "ime-keeper:nvim")
  assert(reports[1].seq == nil, "must not consume Herdr sequenced-source slots")
  wait(function() return #reports >= 2 end, "heartbeat did not renew TTL")
  assert(reports[2].tokens.ime_keeper_sequence == "3")
  pane = "w2:p1"
  reporter(event(4, "edit"))
  wait(function() return status().acknowledged_sequence == 4 end, "pane move was not resolved")
  assert(reports[#reports].pane_id == pane)
  malformed = true
  reporter(event(5, "command"))
  wait(function() return status().connection == "retrying" end, "malformed response was not rejected")
  reporter(event(6, "edit"))
  wait(function() return status().acknowledged_sequence == 6 end, "malformed-response recovery failed")
  reporter(event(7, "command", "exit"))
  wait(function() return status().acknowledged_sequence == 7 end, "best-effort exit did not publish")
  local count = #reports
  vim.wait(1100, function() return false end, 10)
  assert(#reports == count, "exit continued refreshing its lease")
end)
server:close()
for _, peer in ipairs(peers) do if not peer:is_closing() then peer:close() end end
uv.fs_unlink(path)
vim.env.HERDR_SOCKET_PATH, vim.env.HERDR_PANE_ID = saved_socket, saved_pane
assert(ok, failure)
print("Remote Lua socket, recovery, heartbeat and pane-move tests passed")

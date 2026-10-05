local M = {}
local uv = vim.uv or vim.loop

-- Herdr uses one request/response per connection. No subprocess or blocking
-- wait runs on ModeChanged. Only the latest unsent state survives a failure.
function M.connect(opts)
  local socket_path = assert(vim.env.HERDR_SOCKET_PATH, "missing HERDR_SOCKET_PATH")
  local pane_id = assert(vim.env.HERDR_PANE_ID, "missing HERDR_PANE_ID")
  local terminal_id, latest, busy
  local diagnostic = { transport = "remote", connection = "waiting", acknowledged_sequence = 0 }
  local timer = uv.new_timer()
  local request_id = 0
  local retry_at, failures = 0, 0
  local publish

  local function request(method, params, callback)
    request_id = request_id + 1
    local id = "ime-" .. request_id
    local pipe, deadline = uv.new_pipe(false), uv.new_timer()
    local finished, buffer = false, ""
    local function finish(err, result)
      if finished then return end
      finished = true
      deadline:stop(); deadline:close()
      if not pipe:is_closing() then pipe:close() end
      vim.schedule(function() callback(err, result) end)
    end
    deadline:start(opts.timeout_ms or 1500, 0, function() finish("Herdr request timed out") end)
    pipe:connect(socket_path, function(err)
      if finished then return end
      if err then finish(tostring(err)); return end
      pipe:read_start(function(read_err, data)
        if finished then return end
        if read_err then finish(tostring(read_err)); return end
        if not data then finish("Herdr socket disconnected"); return end
        buffer = buffer .. data
        if #buffer > 8 * 1024 * 1024 then finish("Herdr response exceeds 8 MiB"); return end
        local line = buffer:match("^(.-)\n")
        if not line then return end
        local ok, response = pcall(vim.json.decode, line)
        if not ok or type(response) ~= "table" or response.id ~= id then
          finish("invalid Herdr response")
        elseif response.error then
          finish(response.error.message or "Herdr rejected request")
        elseif not response.result then
          finish("Herdr response has no result")
        else
          finish(nil, response.result)
        end
      end)
      pipe:write(vim.json.encode({ id = id, method = method, params = params }) .. "\n", function(write_err)
        if write_err then finish(tostring(write_err)) end
      end)
    end)
  end

  local function resolve(callback)
    request("pane.current", { caller_pane_id = pane_id }, function(err, result)
      local pane = result and result.pane
      if not err and pane and (not terminal_id or terminal_id == pane.terminal_id) then
        pane_id, terminal_id = pane.pane_id, pane.terminal_id
        callback()
        return
      end
      request("session.snapshot", {}, function(snapshot_err, snapshot_result)
        local panes = snapshot_result and snapshot_result.snapshot and snapshot_result.snapshot.panes or {}
        for _, row in ipairs(panes) do
          if (terminal_id and row.terminal_id == terminal_id)
            or (latest and row.tokens and row.tokens.ime_keeper_instance == latest.instanceID) then
            pane_id, terminal_id = row.pane_id, row.terminal_id
            callback()
            return
          end
        end
        callback(snapshot_err or err or "editor pane no longer exists")
      end)
    end)
  end

  local function complete(err, event)
    busy = false
    if err then
      failures = failures + 1
      retry_at = uv.now() + math.min(8000, 250 * 2 ^ math.min(failures, 5))
      diagnostic.connection, diagnostic.error = "retrying", tostring(err)
    else
      failures, retry_at = 0, 0
      diagnostic.connection, diagnostic.error = "connected", nil
      diagnostic.acknowledged_sequence = event.sequence
      if latest and latest.sequence ~= event.sequence then publish() end
    end
  end

  publish = function()
    if busy or not latest or uv.now() < retry_at then return end
    busy = true
    local event = latest
    resolve(function(err)
      if err then complete(err, event); return end
      local tokens = {
        ime_keeper_version = tostring(event.version), ime_keeper_instance = event.instanceID,
        ime_keeper_pid = tostring(event.pid), ime_keeper_sequence = tostring(event.sequence),
        ime_keeper_event = event.event, ime_keeper_mode = event.mode,
      }
      for _, value in pairs(tokens) do
        if #value > 80 then complete("editor metadata exceeds Herdr's 80-byte value limit", event); return end
      end
      request("pane.report_metadata", {
        pane_id = pane_id, source = "ime-keeper:nvim", tokens = tokens, ttl_ms = 5000,
      }, function(report_err) complete(report_err, event) end)
    end)
  end

  -- A heartbeat renews TTL with the same sequence and values. Herdr can emit
  -- pane.updated for renewed deadlines; the Mac deduplicates editor sequences.
  timer:start(1000, 1000, vim.schedule_wrap(function() publish() end))
  local function reporter(event)
    latest = vim.deepcopy(event)
    diagnostic.sequence = event.sequence
    publish()
    if event.event == "exit" then
      -- Best effort only: never wait for networking during VimLeavePre. The
      -- five-second lease also handles crashes and interrupted final writes.
      timer:stop()
    end
    return true
  end
  local function status()
    diagnostic.pane = pane_id
    return vim.deepcopy(diagnostic)
  end
  return reporter, status
end

return M

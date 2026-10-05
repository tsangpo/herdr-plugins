local M = {}
local uv = vim.uv or vim.loop
local active

local function category(mode)
  return mode:match("^[iR]") and "edit" or "command"
end

local function report(state, kind, mode)
  if active ~= state or state.reporting then
    return
  end
  local normalized = category(mode or vim.api.nvim_get_mode().mode)
  if kind == "mode" and normalized == state.mode and not state.needs_snapshot then
    return
  end
  state.sequence = state.sequence + 1
  state.reporting = true
  local ok, result, err = pcall(state.reporter, {
    version = 1,
    instanceID = state.instance,
    pid = uv.os_getpid(),
    sequence = state.sequence,
    event = kind == "mode" and state.needs_snapshot and "snapshot" or kind,
    mode = normalized,
  })
  state.reporting = false
  if ok and result ~= false then
    state.mode = normalized
    state.needs_snapshot = false
    state.last_error = nil
  else
    -- Keep the previous acknowledged category so the next event can retry.
    state.last_error = tostring(ok and err or result)
    state.needs_snapshot = true
    if not state.warned then
      state.warned = true
      local message = state.last_error
      vim.schedule(function()
        vim.notify("IME Keeper: " .. message, vim.log.levels.WARN)
      end)
    end
  end
end

--- Set up mode collection. A reporter receives only portable editor events;
--- transport adapters own pane/session identity and input-source operations.
--- @param opts? {reporter?: function, timeout_ms?: integer, herdr?: string, transport?: string}
function M.setup(opts)
  opts = opts or {}
  if active then
    return M
  end
  local reporter = opts.reporter
  local transport_status
  if not reporter then
    if not vim.env.HERDR_SOCKET_PATH or not vim.env.HERDR_PANE_ID then
      return M
    end
    local remote = opts.transport == "remote" or uv.os_uname().sysname ~= "Darwin"
    if remote and vim.env.NVIM_IME == "0" then return M end
    local module = remote and "ime_keeper.remote_transport" or "ime_keeper.local_transport"
    local ok, value, status = pcall(require(module).connect, opts)
    if not ok then
      vim.schedule(function()
        vim.notify("IME Keeper: " .. tostring(value), vim.log.levels.WARN)
      end)
      return M
    end
    reporter = value
    transport_status = status
  end
  local state = {
    reporter = reporter,
    instance = tostring(uv.os_getpid()) .. ":" .. tostring(uv.hrtime()),
    sequence = 0,
    transport_status = transport_status,
  }
  active = state
  local group = vim.api.nvim_create_augroup("ImeKeeper", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function() report(state, "mode", vim.v.event.new_mode) end,
  })
  for event, kind in pairs({
    FocusGained = "snapshot",
    VimSuspend = "suspend",
    VimResume = "resume",
    VimLeavePre = "exit",
  }) do
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = function() report(state, kind) end,
    })
  end
  -- VimEnter also follows `nvim +startinsert`; querying the real mode avoids
  -- assuming every startup begins in Normal mode.
  if vim.v.vim_did_enter == 1 then
    report(state, "start")
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function() report(state, "start") end,
    })
  end
  return M
end

function M.status()
  if not active then return { enabled = false } end
  local value = { sequence = active.sequence, mode = active.mode, error = active.last_error }
  if active.transport_status then value.transport = active.transport_status() end
  return value
end

return M

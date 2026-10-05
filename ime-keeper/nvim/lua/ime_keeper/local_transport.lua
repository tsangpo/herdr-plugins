local M = {}
local uv = vim.uv or vim.loop
local plugin = "tsangpo.ime-keeper"

local function command(argv, timeout, env)
  local result = vim.system(argv, { text = true, env = env }):wait(timeout)
  if result.code ~= 0 then
    error((result.stderr and result.stderr ~= "" and result.stderr) or ("command failed or timed out: " .. argv[1]))
  end
  return result.stdout
end

local function payload(text)
  local value = vim.json.decode(text)
  return value.result or value
end

function M.connect(opts)
  if not vim.system then
    error("Neovim 0.10 or newer is required")
  end
  local herdr = opts.herdr or vim.env.HERDR_BIN_PATH or "herdr"
  local deadline = uv.hrtime() + 2000000000
  local function remaining()
    local ms = math.floor((deadline - uv.hrtime()) / 1000000)
    if ms <= 0 then error("editor-context initialization timed out") end
    return ms
  end
  local invocation = payload(command({ herdr, "plugin", "action", "invoke", "editor-context", "--plugin", plugin }, remaining()))
  local log = assert(invocation.log, "missing editor-context log")
  local log_id = assert(log.log_id, "missing editor-context log_id")
  while log.status == "running" do
    vim.wait(math.min(25, remaining()))
    local result = payload(command({ herdr, "plugin", "log", "list", "--plugin", plugin, "--limit", "100" }, remaining()))
    for _, row in ipairs(result.logs or {}) do
      if row.log_id == log_id then log = row; break end
    end
  end
  if log.status ~= "succeeded" then error(log.stderr or log.error or "editor-context failed") end
  local stdout = assert(log.stdout, "missing editor-context output")
  local context = vim.json.decode(stdout)
  if context.version ~= "1" or context.sourceID ~= "local" or context.socketPath ~= vim.env.HERDR_SOCKET_PATH then
    error("incompatible editor-context or session mismatch")
  end
  local env = {
    HERDR_PLUGIN_CONFIG_DIR = assert(context.configDirectory),
    HERDR_PLUGIN_STATE_DIR = assert(context.stateDirectory),
    HERDR_SOCKET_PATH = context.socketPath,
    HERDR_BIN_PATH = assert(context.herdrExecutable),
    -- Capture the originating pane; the Swift adapter resolves pane moves by instance.
    HERDR_PANE_ID = vim.env.HERDR_PANE_ID,
  }
  local executable = assert(context.executable)
  return function(event)
    command({ executable, "editor-event", vim.json.encode(event) }, opts.timeout_ms or 1500, env)
    return true
  end
end

return M

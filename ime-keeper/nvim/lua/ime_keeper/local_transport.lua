local M = {}
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
  -- GitHub installs move to a new plugin_root on `herdr plugin update`, so the
  -- executable is re-resolved (once per failure) if its path disappears.
  local function resolve()
    local result = payload(command({ herdr, "plugin", "list", "--json" }, 2000))
    local root
    for _, entry in ipairs(result.plugins or {}) do
      if entry.plugin_id == plugin and entry.enabled == true then
        root = entry.plugin_root
        break
      end
    end
    if type(root) ~= "string" or root == "" then
      error("IME Keeper is not installed and enabled in this Herdr session")
    end
    local path = root .. "/.build/release/ime-keeper"
    if vim.fn.executable(path) ~= 1 then
      error("IME Keeper executable not found; build or reinstall the Herdr plugin: " .. path)
    end
    return path
  end
  local executable = resolve()
  return function(event)
    if vim.fn.executable(executable) ~= 1 then
      executable = resolve()
    end
    command({ executable, "editor-event", vim.json.encode(event) }, opts.timeout_ms or 1500)
    return true
  end
end

return M

# IME Keeper

Remembers the selected macOS input source for each Herdr pane and restores it on focus.

Optional Neovim / LazyVim integration switches to ABC in command modes and restores
your editing input source in Insert / Replace. Requires macOS, Neovim 0.10+, and
the enabled Herdr plugin. Vim is not supported.

## Setup

```sh
swift build -c release
herdr plugin link .
cp config.example.json "$(herdr plugin config-dir tsangpo.ime-keeper)/config.json"
```

Edit `config.json` to set first-focus defaults. Rules are case-sensitive, evaluated in order, and match either a foreground process name or the basename of its `argv[0]`.

```json
{
  "version": 1,
  "rules": [
    { "command": "codex", "inputSourceID": "com.apple.keylayout.ABC" }
  ]
}
```

Use the `list-input-sources` action to discover selectable source IDs. Runtime state is stored per `HERDR_SOCKET_PATH` in Herdr's plugin state directory.

## Neovim / LazyVim

Build and link this plugin using the setup commands above. If an older copy is
already registered, run `herdr plugin unlink tsangpo.ime-keeper` before linking
the new manifest. Keep ABC enabled in macOS input sources.

For plain Neovim, add this to `init.lua`, replacing the path with your checkout:

```lua
vim.opt.runtimepath:prepend("/absolute/path/to/herdr-plugins/ime-keeper/nvim")
require("ime_keeper").setup()
```

For LazyVim, create `lua/plugins/ime-keeper.lua`:

```lua
return {
  {
    name = "ime-keeper",
    dir = "/absolute/path/to/herdr-plugins/ime-keeper/nvim",
    lazy = false,
    config = function()
      require("ime_keeper").setup()
    end,
  },
}
```

For a GitHub-managed Herdr installation, use its installed `ime-keeper/nvim`
directory instead. Do not point LazyVim at the Swift package root: `nvim` is the
Neovim runtime directory. The configuration snippets are opt-in; this plugin
does not edit your Neovim configuration.

| Situation | Input source |
| --- | --- |
| Start Neovim in Normal mode | Save the current source, then select ABC |
| Insert / Replace, including Virtual Replace | Restore the last editing source |
| Normal / Visual / Select / command line / terminal modes | ABC |
| Manually change the source while editing | Remember it when leaving editing or the pane |
| Return to the pane | Apply its editor mode and editing memory |
| Exit or suspend Neovim | Restore the source from before entering the editor |
| Resume Neovim | Save the shell source for the next return; retain editing memory |

`Ctrl-C` and `Ctrl-O` are handled through `ModeChanged`. The integration does not
rewrite mappings or Neovim's `iminsert` / `imsearch` settings. Input-source IDs,
not an IME's internal Chinese/English toggle, are remembered. Mode switching is
event-driven, not continuous enforcement of ABC after a manual change in Normal.

The Lua module does nothing outside a local macOS Herdr pane. It obtains connection
context through the `editor-context` action once, waiting at most two seconds for
the matching command log. Mode reports call the Swift executable directly, in
order, with a 1500ms timeout (customizable as `setup({ timeout_ms = 1500 })`).
Failures warn once in Neovim and are available through
`:lua vim.print(require("ime_keeper").status())`; a later event retries with a
snapshot. If initialization failed, call `require("ime_keeper").setup()` again
after fixing the connection. Reloading an initialized module with `setup()` is
idempotent.

The Herdr `status` action includes editor identity, mode, lifecycle, and both
input-source memories. Forget actions clear the memories but retain identity and
ordering information until the pane closes. Existing pane rules and state files
remain compatible. Disable other automatic IME-switching Neovim plugins to avoid
two integrations selecting different sources.

## Remote roadmap (not implemented)

The intended future entry point is `ime-keeper remote workbox --session dev`.
It will launch the unmodified `herdr --remote` client and manage a separate SSH
channel for reading the remote Herdr API. There is no `remote` subcommand yet.

The planned remote Lua reporter will publish editor state through Herdr metadata
tokens; the local wrapper will subscribe to pane events and read the current
pane's mode, initially at 100ms intervals. Input-source selection and memory stay
on the local Mac. The wrapper will stop switching on disconnect, reconcile a
snapshot on reconnect, and clean up its auxiliary connection on exit without
stopping the remote session. The initial remote scope is one interactive client
per session: Herdr focus events do not identify the originating client.

The current implementation separates portable Lua events, local transport,
session-scoped policy, and Carbon execution. A reporter passed to
`setup({ reporter = function(event) ... end })` receives version 1 events with
`instanceID`, `pid`, increasing `sequence`, `event` (`start`, `mode`, `snapshot`,
`suspend`, `resume`, `exit`), and `mode` (`edit`, `command`). Return `false, error`
or throw on failure. Transport adapters supply source/session/pane identity;
they must verify that identity before applying an event. Remote transport,
reconnection, multi-host operation, and nested editors are not supported yet.

## Development

```sh
swift test
swift build -c release
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
```

The headless test runner exercises embedded Neovim and a real TUI in a PTY with a
recording reporter and a mocked Herdr transport; it does not change the macOS input source. Swift tests
exercise memory, event ordering, failures, namespace isolation, and old-state
compatibility. Manual desktop acceptance should additionally verify immediate
Chinese input after Insert, switching between two panes with different sources,
and background editor events while another pane is focused.

If you already have a LazyVim dependency cache, test the eager-loading plugin
spec against it without downloading dependencies or changing your configuration:

```sh
IME_KEEPER_LAZY_ROOT=/absolute/path/to/nvim/lazy \
  NVIM_LOG_FILE=/tmp/ime-keeper-lazyvim-tests.log \
  nvim --headless -u NONE -i NONE -l nvim/tests/lazyvim.lua
```

Unload the locally linked plugin without deleting its source, config, or state:

```sh
herdr plugin unlink tsangpo.ime-keeper
```

After changing `herdr-plugin.toml`, rebuild and run `herdr plugin link .` again. Swift-only changes need only a release rebuild.

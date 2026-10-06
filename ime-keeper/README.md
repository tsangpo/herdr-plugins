# IME Keeper

Remembers the selected macOS input source for each Herdr pane and restores it on focus.

Optional Neovim / LazyVim integration switches to ABC in command modes and restores
your editing input source in Insert / Replace. Requires macOS, Herdr 0.9.3+, Neovim 0.10+, and
the enabled Herdr plugin for local integration. Remote mode requires Herdr 0.9.3+
on both hosts, system OpenSSH with Unix socket forwarding, and Linux Neovim. Vim is not supported.

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

For LazyVim / lazy.nvim, create `lua/plugins/ime-keeper.lua` on each host
where you run Neovim:

```lua
return {
  {
    "tsangpo/herdr-plugins",
    name = "ime-keeper",
    main = "ime_keeper",
    lazy = false,
    opts = {},
  },
}
```

Run `:Lazy sync` to download the Lua integration, then restart Neovim. Update
with `:Lazy update ime-keeper`; lazy.nvim records the revision in `lazy-lock.json`.
The repository-root loader exposes the runtime in `ime-keeper/nvim`, so no
manual clone, file copying, absolute runtime path, or Swift build is required
on the remote host. The Mac Herdr plugin and the Neovim integration are installed
and updated separately; keep both on compatible revisions.

If replacing an older local `dir` specification, remove that specification and
any manual `runtimepath:prepend` for IME Keeper to avoid loading a stale copy.
For local development, replace the repository string with
`dir = "/absolute/path/to/herdr-plugins"`; keep `main`, `lazy`, and `opts` as above.
Directly adding `ime-keeper/nvim` to runtimepath also remains supported.

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

For local macOS Herdr panes, the Lua module finds the enabled plugin with one
`herdr plugin list --json` call (two-second timeout). Mode reports call the
Swift executable directly, in order, with a 1500ms timeout (customizable as
`setup({ timeout_ms = 1500 })`). Swift queries the pane and foreground processes
directly over `HERDR_SOCKET_PATH`, sharing a one-second socket deadline per
local operation; it does not launch Herdr CLI processes for mode reports.
Configuration and state use `HERDR_PLUGIN_CONFIG_DIR` / `HERDR_PLUGIN_STATE_DIR`
when set, otherwise Herdr's XDG defaults. Keep these directory settings consistent
between the Herdr server and pane environment.
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

## Remote Neovim / LazyVim

Fish users can use the bundled [ime-remote function](fish/ime-remote.fish)
instead of adding the executable to PATH. After installing or linking the
plugin, run this once in fish (requires `jq`):

```fish
set -l ime_root (herdr plugin list --json | jq -er '.result.plugins[] | select(.plugin_id == "tsangpo.ime-keeper") | .plugin_root')
source "$ime_root/fish/ime-remote.fish"
funcsave ime-remote
```

Then, from a **Ghostty shell outside local Herdr**:

```fish
ime-remote ubuntu
ime-remote ubuntu --session dev
```

The function looks up the installed plugin root on every invocation, so it
works with both GitHub installs and local links. Local links still require
`swift build -c release` in the plugin directory before use.

For other shells, or to invoke the executable directly:

On the Mac, build the plugin and expose the executable in your shell's PATH.
Run this from the `ime-keeper` directory (for GitHub installs, find `plugin_root`
in `herdr plugin list --json`):

```sh
swift build -c release
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/.build/release/ime-keeper" "$HOME/.local/bin/ime-keeper"
export PATH="$HOME/.local/bin:$PATH"
```

Keep the PATH addition in your shell configuration. If the link already exists,
inspect its target before replacing it. This entry uses the same configuration
and state directories as the Herdr plugin without requiring a running local
Herdr server or manually exported plugin variables.

Start from a **Ghostty shell outside local Herdr**:

```sh
ime-keeper remote ubuntu
# Or choose a named remote session:
ime-keeper remote ubuntu --session dev
```

The wrapper starts the official `herdr --remote` client and an auxiliary SSH
connection forwarding only the remote public API socket. It discovers that
socket with `herdr status server --json`; use `--remote-herdr /absolute/path/to/herdr`
if the auxiliary SSH shell cannot find it. That option controls API discovery;
the official Herdr client continues using its own remote executable discovery.
SSH authentication uses your existing config/agent. The helper uses BatchMode;
if authentication fails, first make sure `ssh ubuntu true` succeeds.

On Ubuntu, add the GitHub LazyVim specification above and run `:Lazy sync`.
No file copying, Swift build, or Herdr plugin installation is needed there.
Launch participating editors inside remote Herdr panes with:

```sh
nvim
```

Reporting starts automatically when the Lua plugin is loaded inside a remote
Herdr pane. Several panes can each run their own Neovim instance. Use
`NVIM_IME=0 nvim` or remove the Lua setup to disable remote mode reporting;
ordinary pane input-source memory continues working. Outside Herdr, setup
remains inactive. Existing `NVIM_IME=1` launch commands still work.

Local Neovim continues calling Swift directly. Remote Neovim asynchronously
publishes the same version 1 editor events through `pane.report_metadata`.
The Mac subscribes to `pane.updated` and pane lifecycle events. There is no
reverse SSH forward, separate mode socket, system service, or 100ms mode polling.
Pane focus retains its 100ms stable window. Relevant events wake the worker
immediately; identical heartbeats, titles, cwd and unrelated tokens do not trigger
reconciliation. A separate two-second health schedule detects lost editor
foreground ownership even during continuous mode changes. Each editor reconcile
still queries foreground processes and revalidates the focused pane and IME tokens
before applying. Kernel TUI/core identity is cached for at most one second and
refreshed on health checks, focus entry and terminal reacquisition. Both transports share the editor
policy: command modes use ABC, editing restores the editing source, and
exit/suspend restores the pre-editor shell source.

The six `ime_keeper_*` tokens contain version, instance, PID, sequence, event
and mode.
Each report atomically patches only these keys under source `ime-keeper:nvim`.
Reports are serialized, and the Mac ignores old sequences. A one-second heartbeat
renews a five-second TTL. Herdr can emit updates for heartbeat renewals; those
do not change the editor mode. An interrupted exit expires automatically. Token
capacity errors are shown in Lua status and never evict another plugin's tokens.

| Token suffix | Value |
| --- | --- |
| `version` | `1` |
| `instance` | Neovim instance identity |
| `pid` | Lua core PID |
| `sequence` | Increasing event sequence |
| `event` | `start`, `mode`, `snapshot`, `suspend`, `resume`, `exit` |
| `mode` | `edit` or `command` |

The wrapper records the selected Ghostty terminal when it starts and pauses
input-source control when another tab or split is selected, Ghostty is not
frontmost, or the auxiliary connection fails. Terminal detection uses Ghostty's
AppleScript interface (tested with Ghostty 1.3.1); allow macOS Automation access
if prompted. If terminal detection fails, input-source control pauses. On reconnect it resubscribes and reads a fresh
snapshot. Because Herdr exposes no stable server incarnation identifier, it
conservatively starts fresh pane/editor memories on each auxiliary reconnect;
mode reporting resumes from current metadata. Closing the wrapper stops only
its own client and helper, leaving the remote Herdr server running.

Scope: one remote Ghostty terminal, one wrapper, one
interactive client per remote session, and one participating editor per pane.
Multiple editors in different panes are supported. Nested local Herdr launches
are rejected. Local Herdr can remain open in other Ghostty tabs or windows:
local hooks run when the remote terminal is not selected, and the remote
wrapper controls input only while its terminal is selected. The global switch
lock is held only during input-source operations.

### Diagnostics and manual acceptance

```sh
ime-keeper remote-status
```

Status includes the wrapper PID, registered Ghostty terminal ID, connection
state, terminal detection errors, last error, remote socket,
pane memories and editor modes. It remains available after exit and reports
whether the recorded process is alive. Diagnostics are written to the plugin
state directory instead of overwriting the interactive terminal. Unchanged session
state is not rewritten. Status changes are written immediately; updates that only
change metrics are flushed at most once every two seconds.

The `metrics` object contains received/ignored event counts, reconcile attempts,
revision discards, snapshot/process/current/SSH identity query counts, and
`lastReconcileMs`. `lastModeApplyMs` measures local event receipt through successful
mode application, including queueing and retries; `appliedModeEvents` counts those
applications. It does not measure remote keystroke latency or the first Chinese
character. Counters cover the wrapper lifetime, including auxiliary reconnects.

An optional SSH integration test creates an isolated temporary Herdr server and
two real Neovim TUIs, checks 30 seconds of idle event filtering, suspend/resume,
exit/crash TTL cleanup and auxiliary reconnect. It needs Herdr and Neovim on the
SSH target and never changes the desktop input source:

```sh
IME_KEEPER_REMOTE_TEST_HOST=ubuntu swift test --filter remoteRealTUIsAndIdleEventFiltering
```

In Neovim:

```vim
:lua vim.print(require("ime_keeper").status())
```

Remote transport status distinguishes the last event queued from the sequence
acknowledged by Herdr; acknowledgement does not mean macOS has already switched.

For desktop acceptance, select Pinyin in Insert, leave with Esc and Ctrl-C,
open which-key in Normal, then re-enter Insert and immediately type Chinese.
Repeat across two Neovims and a shell pane, including manual source changes,
Ctrl-O, Replace, suspend/resume, exit, pane moves, and switching away from Ghostty.
Verify actual characters/candidates, not only the menu-bar indicator. Network and
macOS activation latency mean first-character behavior needs this manual check.

## Development

```sh
swift test
swift build -c release
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/remote.lua
# Optional: starts and stops only an isolated temporary Herdr server.
IME_KEEPER_LIVE_TESTS=1 swift test
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

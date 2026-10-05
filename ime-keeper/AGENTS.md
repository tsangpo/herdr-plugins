# IME Keeper Development Guide

## Scope

- Keep this a macOS-only Herdr plugin with ID `tsangpo.ime-keeper` and minimum Herdr version `0.8.2`.
- Use one dependency-free SwiftPM executable. Do not add Python, `macism`, daemons, dashboards, TUIs, or a rules engine.
- Use Foundation for JSON/files/processes, Carbon TIS for input sources, and AppKit only for the post-switch input-context refresh.

## Behavior to Preserve

- Store user configuration in `HERDR_PLUGIN_CONFIG_DIR/config.json` and runtime state in `HERDR_PLUGIN_STATE_DIR`; never write state into the plugin checkout.
- Isolate state by a stable hash of `HERDR_SOCKET_PATH` and write it atomically.
- For panes without a verified active Neovim instance, restore in this order: saved pane source, first matching command rule, current source unchanged.
- For a verified foreground Neovim instance, apply editor mode policy before ordinary pane restoration. Keep its editing and pre-editor input-source memories separate; forced ABC must not replace either memory.
- Keep mode events transport-independent and versioned. The current local adapter validates pane/PID and uses the existing socket-scoped store. Remote support is a future IME Keeper launcher around unmodified `herdr --remote`, not a Herdr source change or system daemon.
- Match rules case-sensitively against foreground process `name` or the basename of `argv0`, in array order.
- Capture the departure input source immediately when a focus event starts. Keep the 100ms stable window, session focus lock, and global switch lock before restoring the revalidated current pane.
- A successfully applied rule becomes pane memory; a later manual input-source change overrides it when leaving the pane.
- Evaluate command rules only on focus. Clean state on pane/tab/workspace close and migrate it on pane move.
- Log Herdr/config/TIS failures and leave the current source unchanged. Never overwrite corrupt config or state.

## Neovim and Herdr Integration

- Interactive Neovim can run its TUI as the pane's foreground process and its Lua core as a separate `nvim --embed` child. The reported core PID need not appear in `foreground_processes`. Use the shared `editorIsForeground` check for both mode events and pane focus: accept a direct PID match or a kernel-verified Neovim core whose direct parent is the foreground Neovim TUI. Do not replace this with process-name-only matching or an unrestricted ancestor search.
- `herdr pane current` uses inherited `HERDR_PANE_ID` as caller context. Remove that variable when querying actual UI focus; preserve it when resolving the reporting editor's pane. Background editor events must never sample or switch another pane's input source.
- Keep reported mode separate from successfully applied input-source policy. A background mode/exit event can arrive before the 100ms focus worker samples departure. Retain the applied policy until a switch succeeds or departure is sampled, so forced ABC and failed restores cannot overwrite user memory.
- `herdr plugin action invoke` returns a started log record, not necessarily completed action output. Match `log_id` while polling, require success, and then decode `stdout`; bound initialization and subprocess waits. Drain subprocess stdout and stderr while the process runs to avoid pipe deadlocks.
- Use `ModeChanged` rather than only `InsertLeave`, which misses `Ctrl-C`. Keep Lua setup idempotent and send a current snapshot when recovering from a failed report. A moved pane's inherited ID can be stale; retain editor identity across moves and resolve caller context for new instances.

## Validation

Run from this directory:

```sh
swift test
swift build -c release
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
```

Keep tests for rule order and basename matching, saved-memory priority, manual overrides, no-rule behavior, close/move cleanup, malformed config, and Herdr CLI response unwrapping.

For editor changes, exercise both embedded/headless Neovim and a real TUI in a PTY. Headless tests alone missed the TUI/core PID split. Keep positive and negative foreground-identity tests, plus mode/focus races and failed-switch memory tests. The Lua integration suite covers both startup shapes; when a LazyVim dependency cache is available, also run `nvim/tests/lazyvim.lua` with `IME_KEEPER_LAZY_ROOT` set to that cache.

Use an isolated named Herdr session for end-to-end tests, with `XDG_CONFIG_HOME` and `XDG_STATE_HOME` under a short temporary path such as `/tmp/ik-...`. `HERDR_CONFIG_PATH` alone does not isolate plugin directories, and long temporary paths can exceed the Unix socket path limit. Verify the resolved directories before linking, and stop only the test session afterward. Background-pane tests can validate real mode reporting without selecting a desktop input source; they do not replace manual Chinese-input acceptance testing.

For local Herdr testing, build before `herdr plugin link .`; linking does not run the manifest build command. Unload with `herdr plugin unlink tsangpo.ime-keeper`. Swift-only changes need only a release rebuild; after manifest changes, unlink and link again.

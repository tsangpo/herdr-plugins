# IME Keeper Development Guide

## Scope

- Keep this a macOS-only Herdr plugin with ID `tsangpo.ime-keeper` and minimum Herdr version `0.9.3`.
- Use one dependency-free SwiftPM executable. Do not add Python, `macism`, daemons, dashboards, TUIs, or a rules engine.
- Use Foundation for JSON/files/processes, Carbon TIS for input sources, and AppKit for post-switch refresh and remote Ghostty foreground detection.

## Behavior to Preserve

- Store user configuration in `HERDR_PLUGIN_CONFIG_DIR/config.json` and runtime state in `HERDR_PLUGIN_STATE_DIR`; never write state into the plugin checkout.
- Isolate state by a stable hash of `HERDR_SOCKET_PATH` and write it atomically.
- For panes without a verified active Neovim instance, restore in this order: saved pane source, first matching command rule, current source unchanged.
- For a verified foreground Neovim instance, apply editor mode policy before ordinary pane restoration. Keep its editing and pre-editor input-source memories separate; forced ABC must not replace either memory.
- Keep mode events transport-independent and versioned. The current local adapter validates pane/PID and uses the existing socket-scoped store. Remote support is a connection-lived IME Keeper launcher around unmodified `herdr --remote`, not a Herdr source change or system daemon.
- Match rules case-sensitively against foreground process `name` or the basename of `argv0`, in array order.
- Capture the departure input source immediately when a focus event starts. Keep the 100ms stable window, session focus lock, and global switch lock before restoring the revalidated current pane.
- A successfully applied rule becomes pane memory; a later manual input-source change overrides it when leaving the pane.
- Evaluate command rules only on focus. Clean state on pane/tab/workspace close and migrate it on pane move.
- Log Herdr/config/TIS failures and leave the current source unchanged. Never overwrite corrupt config or state.

## Neovim and Herdr Integration

- Keep the repository-root `lua/ime_keeper.lua` entry a thin loader for `ime-keeper/nvim`. GitHub lazy.nvim specs use `main = "ime_keeper"`, `lazy = false`, and `opts`; no build hook or manual directory copying. Preserve direct runtimepath use for local development. The LazyVim smoke test must load the repository root through this public entry.

- Interactive Neovim can run its TUI as the pane's foreground process and its Lua core as a separate `nvim --embed` child. The reported core PID need not appear in `foreground_processes`. Use the shared `editorIsForeground` check for both mode events and pane focus: accept a direct PID match or a kernel-verified Neovim core whose direct parent is the foreground Neovim TUI. Do not replace this with process-name-only matching or an unrestricted ancestor search.
- Local Swift queries Herdr directly through `HerdrAPI`. For actual UI focus, omit `caller_pane_id`; set it explicitly from `HERDR_PANE_ID` when resolving the reporting editor's pane. Keep one shared one-second socket deadline across the local operation. Background editor events must never sample or switch another pane's input source.
- Keep reported mode separate from successfully applied input-source policy. A background mode/exit event can arrive before the 100ms focus worker samples departure. Retain the applied policy until a switch succeeds or departure is sampled, so forced ABC and failed restores cannot overwrite user memory.
- Local Lua discovers the enabled plugin with one bounded `herdr plugin list --json` call, then invokes Swift directly with inherited pane environment. Use shared `PluginDirectories` resolution for hooks and editor calls (explicit plugin directories, then XDG/HOME). Do not reintroduce an action/log handshake. Drain subprocess stdout and stderr while the process runs to avoid pipe deadlocks.
- Use `ModeChanged` rather than only `InsertLeave`, which misses `Ctrl-C`. Keep Lua setup idempotent and send a current snapshot when recovering from a failed report. A moved pane's inherited ID can be stale; retain editor identity across moves and resolve caller context for new instances.

## Remote Integration

The behavior guarantees below prevent input-source corruption. Timing values and
implementation choices describe the current design and may be revised with tests;
changing them must preserve those guarantees.

- Preserve local direct Swift reporting. Remote Lua writes six `ime_keeper_*` tokens through `pane.report_metadata`; the Mac subscribes to `pane.updated`. Herdr 0.9.3 excludes `pane.updated` from plugin hooks, so a local wrapper is not required or introduced.
- Remote reporting starts automatically when the Lua plugin is loaded inside a remote Herdr pane; `NVIM_IME=0` opts out. The remote host needs only the Lua runtime, not the macOS plugin or Swift. The Mac wrapper forwards the remote public API socket over auxiliary SSH; do not introduce reverse forwarding or a separate editor-event socket.
- Report one atomic token patch with a fixed source and no Herdr `seq`. Ordering belongs to the editor instance/sequence fields. Unique sequenced sources exhaust Herdr's 32-source lifetime limit; individual token values are limited to 80 characters.
- Renew the five-second TTL every second without incrementing the editor sequence. TTL renewal itself can emit `pane.updated` in Herdr 0.9.3: do not assume unchanged values suppress the event. Deduplicate mode application on the Mac.
- Deduplicate subscription `pane.updated` using IME tokens plus pane/workspace/tab/terminal identity and focus. Share that projection with final `pane.current` verification; unrelated tokens must not invalidate a candidate. The reader owns received-state deduplication, separately from applied policy. Structural events or unparseable pane observations invalidate conservatively; reconnect starts with an empty cache. Invalid editor token contents are deduplicated by their raw values just like valid reports: first appearance, changes, recovery and TTL removal trigger reconciliation, but repeated bad heartbeats must not clear other panes' deduplication state. Validate editor semantics during reconciliation.
- Wake the remote worker with a condition and revision predicate under the same lock. Coalesce notifications, preserve pending departure sampling and the 100ms focus window, and wait until the next focus/terminal/health deadline. Do not accumulate semaphore permits or restore 20ms polling.
- Schedule two-second health work independently of event reconciliations while the registered terminal has input-source control. Only real health work advances its deadline; cache hits and mode events must not postpone it. Keep `pane.process_info` and final `pane.current` checks. Kernel identity cache hits must not extend the two-second lookup lifetime; health checks force a fresh lookup. Clear on focus entry, terminal ownership changes, lifecycle/identity changes, moves and reconnect.
- Pause remote queries when the terminal loses control, but keep consuming the subscription and detecting errors. Cancel pending departure samples with a generation change; late callbacks must not revive them. Do not wait on an expired health deadline while paused. On return, reconcile the current snapshot with fresh identity and input-source observations; retain activation across debounce and rejected candidates until reconciliation succeeds.
- Malformed or unsupported editor metadata releases only that pane's editor control, never the connection or other pane memories. Track diagnostics separately in `metadataErrors`; successful input-source switching must not erase them. Clear each diagnostic when valid metadata returns, tokens disappear or the pane closes.
- Subscription failures arrive as error responses with `error.code`, including `events_lost`. Invalidate pending applications immediately on that frame rather than waiting for EOF, and report its code/message before reconnecting.
- Save unchanged session/status data only once; update the last-written cache only after a successful write. Business status changes flush immediately, metrics alone at most every two seconds. Measure local event receipt through successful mode application separately from reconciliation duration and actual Chinese-input latency. Count identity cache hits and classify SSH lookup counts/duration by health, focus and other events; total lookups divided by applied modes is not a cache miss rate.
- On TTL expiry, stop editor control but retain dormant instance identity and editing memory for a verified resume. Keep this distinct from auxiliary reconnection, which clears memories when server continuity cannot be established. Namespace remote state by SSH target, session, and remote socket.
- Keep Lua asynchronous and bounded. A Herdr acknowledgement is distinct from successful macOS application. Reconnect sends the latest state; stale pending modes are not replayed. Resolve pane moves through terminal identity.
- Validate foreground PIDs on the remote host, including the direct Neovim TUI/core parent relationship. Never pass remote PIDs to macOS process inspection. Metadata is current state, so a new subscriber can bootstrap from a mode report rather than waiting for a start event.
- Subscribe before taking a snapshot and revalidate focus, tokens, and the subscription generation before switching. Sample only while the registered Ghostty terminal is selected and Ghostty is frontmost. Recheck the terminal immediately before switching; an unknown terminal or Automation failure must fail closed. Background terminals must not seed editor memories with fallback ABC.
- On remote focus arrival, invalidate pending switches before dispatching departure sampling to the main thread. Reconciliation must wait for that sample, even if the 100ms stable window has elapsed. Recheck the event generation after acquiring the switch lock and querying Ghostty: both can block while a newer focus event arrives.
- Capture the departure input source before querying Ghostty. For ordinary panes, compare that source with the source immediately before restoration: a changed source is a manual destination-pane choice and takes precedence over the pending restore. Keep departure memory separate. Reuse the in-process Ghostty AppleScript, and skip remote process queries when an ordinary pane already has saved memory; editor identity validation remains mandatory.
- Keep the lifetime remote-instance lock separate from the short global input-source switch lock. The former prevents duplicate wrappers and must never suppress local hooks. Register the selected Ghostty surface ID through its AppleScript interface so local and remote tabs can coexist. Ignore stale registrations when the instance lock is free. Clear applied-policy observations on controller handoff without discarding remembered editing sources. Mark lock/socket descriptors close-on-exec, so a child cannot retain ownership after the wrapper exits.
- Scope is a Ghostty shell outside local Herdr, one remote terminal and one interactive client, with multiple editor panes. Auxiliary failures must not terminate the official client. Only clean resources created by this invocation. Clear remembered state conservatively on reconnect when server continuity cannot be established; never overwrite corrupt files.
- Write diagnostics to `remote-status.json` in the plugin state directory, not the interactive terminal; keep `remote-status` usable after exit. Wrapper shutdown stops only its own client, helper, and temporary resources, never the remote Herdr server.

## Validation

Run from this directory:

```sh
swift test
swift build -c release
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/remote.lua
# Opt-in real API test; only its temporary named server is stopped.
IME_KEEPER_LIVE_TESTS=1 swift test
# Optional isolated SSH test (Herdr and Neovim must be installed on the target).
IME_KEEPER_REMOTE_TEST_HOST=ubuntu swift test --filter remoteRealTUIsAndIdleEventFiltering
```

Keep tests for rule order and basename matching, saved-memory priority, manual overrides, no-rule behavior, close/move cleanup, malformed config, and socket caller/focus separation, shared query deadlines, and config/state directory consistency.

For editor changes, exercise both embedded/headless Neovim and a real TUI in a PTY. Headless tests alone missed the TUI/core PID split. Keep positive and negative foreground-identity tests, plus mode/focus races and failed-switch memory tests. The Lua integration suite covers both startup shapes; when a LazyVim dependency cache is available, also run `nvim/tests/lazyvim.lua` with `IME_KEEPER_LAZY_ROOT` set to that cache.

Herdr control keys use `ctrl+z` spelling. Send Neovim Ex commands as individual keys followed by `enter`; reserve `pane run` for shell commands. A suspended Lua loop may not flush an asynchronous report, so verify foreground loss and TTL release as well as suspend/resume metadata.

Continuously drain the PTY master during automated TUI tests; otherwise output backpressure can prevent the child from exiting. Test remote mode reporting with two real Neovim TUIs, background panes, helper disconnect/reconnect, and exit/TTL cleanup in an isolated remote session. A substitute-client wrapper test validates transport and lifecycle, not the official client's desktop input behavior. Verify actual Chinese characters and candidates immediately after entering Insert; menu-bar indicators and headless tests are insufficient. Report query-path benchmarks separately from Swift startup, TIS switching, and first-character latency.

Use an isolated named Herdr session for end-to-end tests, with `XDG_CONFIG_HOME` and `XDG_STATE_HOME` under a short temporary path such as `/tmp/ik-...`. `HERDR_CONFIG_PATH` alone does not isolate plugin directories, and long temporary paths can exceed the Unix socket path limit. Verify the resolved directories before linking, and stop only the test session afterward. Background-pane tests can validate real mode reporting without selecting a desktop input source; they do not replace manual Chinese-input acceptance testing.

For local Herdr testing, build before `herdr plugin link .`; linking does not run the manifest build command. Unload with `herdr plugin unlink tsangpo.ime-keeper`. Swift-only changes need only a release rebuild; after manifest changes, refresh the plugin link. Restart existing Neovim instances after Lua initialization changes. Linking a headless server does not guarantee startup hooks run; explicitly invoke an action when testing Herdr's injected plugin environment.

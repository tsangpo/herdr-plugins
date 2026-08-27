# IME Keeper Development Guide

## Scope

- Keep this a macOS-only Herdr plugin with ID `tsangpo.ime-keeper` and minimum Herdr version `0.8.2`.
- Use one dependency-free SwiftPM executable. Do not add Python, `macism`, daemons, dashboards, TUIs, or a rules engine.
- Use Foundation for JSON/files/processes, Carbon TIS for input sources, and AppKit only for the post-switch input-context refresh.

## Behavior to Preserve

- Store user configuration in `HERDR_PLUGIN_CONFIG_DIR/config.json` and runtime state in `HERDR_PLUGIN_STATE_DIR`; never write state into the plugin checkout.
- Isolate state by a stable hash of `HERDR_SOCKET_PATH` and write it atomically.
- Restore in this order: saved pane source, first matching command rule, current source unchanged.
- Match rules case-sensitively against foreground process `name` or the basename of `argv0`, in array order.
- Capture the departure input source immediately when a focus event starts. Keep the 100ms stable window, session focus lock, and global switch lock before restoring the revalidated current pane.
- A successfully applied rule becomes pane memory; a later manual input-source change overrides it when leaving the pane.
- Evaluate command rules only on focus. Clean state on pane/tab/workspace close and migrate it on pane move.
- Log Herdr/config/TIS failures and leave the current source unchanged. Never overwrite corrupt config or state.

## Validation

Run from this directory:

```sh
swift test
swift build -c release
```

Keep tests for rule order and basename matching, saved-memory priority, manual overrides, no-rule behavior, close/move cleanup, malformed config, and Herdr CLI response unwrapping.

For local Herdr testing, build before `herdr plugin link .`; linking does not run the manifest build command. Unload with `herdr plugin unlink tsangpo.ime-keeper`. Swift-only changes need only a release rebuild; after manifest changes, unlink and link again.

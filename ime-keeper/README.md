# IME Keeper

Remembers the selected macOS input source for each Herdr pane and restores it on focus.

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

## Development

Unload the locally linked plugin without deleting its source, config, or state:

```sh
herdr plugin unlink tsangpo.ime-keeper
```

After changing `herdr-plugin.toml`, rebuild and run `herdr plugin link .` again. Swift-only changes need only a release rebuild.

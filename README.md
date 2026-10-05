# Herdr Plugins

## IME Keeper

Install the macOS per-pane input-source memory plugin with:

```sh
herdr plugin install tsangpo/herdr-plugins/ime-keeper
```

See [`ime-keeper/README.md`](ime-keeper/README.md) for configuration and development instructions.

For Neovim / LazyVim, install the Lua integration directly from this repository
with lazy.nvim. Add this to `lua/plugins/ime-keeper.lua`:

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

Run `:Lazy sync` to install; update with `:Lazy update ime-keeper`. No manual
copy or Swift build is needed for the Lua integration on the remote host.
Inside remote Herdr panes, run `nvim` to report modes automatically (`NVIM_IME=0 nvim` disables reporting); on the Mac,
connect from a Ghostty shell using `ime-keeper remote <ssh-target>`.

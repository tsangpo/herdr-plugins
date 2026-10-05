function ime-remote --description 'Start IME Keeper remote Herdr'
    set -l ime_root (herdr plugin list --json | jq -er '.result.plugins[] | select(.plugin_id == "tsangpo.ime-keeper") | .plugin_root')
    or return 1
    "$ime_root/.build/release/ime-keeper" remote $argv
end

#!/bin/bash

set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
adapter="$project_dir/bin/omarchy-crash-watch-adapter"
lifecycle="$project_dir/bin/plugin-lifecycle"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/omarchy"

cat >"$tmp/bin/plugin-watcher" <<'EOF'
#!/bin/bash
printf 'plugin\n' >>"$TEST_ADAPTER_RESULT"
EOF
cat >"$tmp/bin/stock-watcher" <<'EOF'
#!/bin/bash
printf 'stock\n' >>"$TEST_ADAPTER_RESULT"
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
EOF
chmod +x "$tmp/bin"/*

export TEST_ADAPTER_RESULT="$tmp/adapter-result"
export TEST_SYSTEMCTL_LOG="$tmp/systemctl-log"
export OMARCHY_PLUGIN_CRASH_WATCH="$tmp/bin/plugin-watcher"
export OMARCHY_STOCK_CRASH_WATCH="$tmp/bin/stock-watcher"
export OMARCHY_SHELL_CONFIG="$tmp/home/.config/omarchy/shell.json"

# Enabled plugins route to their bundled watcher.
printf '%s\n' '{"version":1,"plugins":[{"id":"io.github.cylon58.codex-crash-model-picker"}]}' >"$OMARCHY_SHELL_CONFIG"
"$adapter"
[[ $(tail -n 1 "$TEST_ADAPTER_RESULT") == plugin ]] || fail "enabled plugin did not select its watcher"

# Disabled or removed plugins safely fall back to Omarchy's packaged watcher.
printf '%s\n' '{"version":1,"plugins":[]}' >"$OMARCHY_SHELL_CONFIG"
"$adapter"
[[ $(tail -n 1 "$TEST_ADAPTER_RESULT") == stock ]] || fail "disabled plugin did not select stock watcher"

OMARCHY_PLUGIN_CRASH_WATCH="$tmp/missing-watcher" "$adapter"
[[ $(tail -n 1 "$TEST_ADAPTER_RESULT") == stock ]] || fail "removed plugin did not select stock watcher"

# Activation installs only user-owned adapter/drop-in files and restarts the
# watcher; uninstall removes both and restores the stock service definition.
HOME="$tmp/home" SYSTEMCTL_BIN="$tmp/bin/systemctl" "$lifecycle" activate
installed_adapter="$tmp/home/.local/bin/omarchy-crash-watch-plugin-adapter"
installed_override="$tmp/home/.config/systemd/user/omarchy-crash-watch.service.d/override.conf"
[[ -x $installed_adapter ]] || fail "activation did not install the adapter"
[[ -f $installed_override ]] || fail "activation did not install the systemd drop-in"
grep -Fx 'ExecStart=%h/.local/bin/omarchy-crash-watch-plugin-adapter' "$installed_override" >/dev/null || fail "drop-in uses the wrong command"
grep -Fx -- '--user daemon-reload' "$TEST_SYSTEMCTL_LOG" >/dev/null || fail "activation did not reload user units"
grep -Fx -- '--user restart omarchy-crash-watch.service' "$TEST_SYSTEMCTL_LOG" >/dev/null || fail "activation did not restart the watcher"

HOME="$tmp/home" SYSTEMCTL_BIN="$tmp/bin/systemctl" "$lifecycle" uninstall
[[ ! -e $installed_adapter ]] || fail "uninstall left the adapter installed"
[[ ! -e $installed_override ]] || fail "uninstall left the drop-in installed"

printf 'PASS: plugin lifecycle and safe fallback behavior\n'

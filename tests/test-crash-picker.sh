#!/bin/bash

set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
picker="$project_dir/bin/codex-crash-diagnose"
dispatcher="$project_dir/bin/codex-crash-dispatch"
watcher="$project_dir/bin/omarchy-crash-watch"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file=$1 expected=$2
  grep -F -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"
}

make_fake_commands() {
  local bin_dir=$1

  cat >"$bin_dir/gum" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"$TEST_GUM_INPUT"
call=1
[[ ! -f $TEST_GUM_COUNTER ]] || call=$(<"$TEST_GUM_COUNTER")
selection=$(sed -n "${call}p" "$TEST_GUM_SELECTIONS")
printf '%s\n' "$selection"
printf '%s\n' $((call + 1)) >"$TEST_GUM_COUNTER"
EOF

  cat >"$bin_dir/codex" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"$TEST_CODEX_ARGS"
EOF

  cat >"$bin_dir/coredumpctl" <<'EOF'
#!/bin/bash
printf 'Wed 2026-09-16 12:50:25 EDT 2337144 1000 1000 SIGILL present /usr/lib/chromium/chromium 660M\n'
EOF

  cat >"$bin_dir/omarchy-launch-tui" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"$TEST_LAUNCH_ARGS"
EOF

  cat >"$bin_dir/omarchy-notification-wait" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$bin_dir/omarchy-notification-send" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"$TEST_NOTIFICATION_ARGS"
EOF

  cat >"$bin_dir/omarchy-default-agent" <<'EOF'
#!/bin/bash
printf '%s\n' "${TEST_DEFAULT_AGENT:-codex}"
EOF

  cat >"$bin_dir/omarchy-agent-crash" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >"$TEST_GENERIC_ARGS"
EOF

  chmod +x "$bin_dir"/*
}

run_picker_test() {
  local tmp=$1
  export TEST_GUM_SELECTIONS="$tmp/selections"
  export TEST_GUM_COUNTER="$tmp/counter"
  export TEST_GUM_INPUT="$tmp/gum-input"
  export TEST_CODEX_ARGS="$tmp/codex-args"
  export TEST_LAUNCH_ARGS="$tmp/launch-args"
  export TEST_NOTIFICATION_ARGS="$tmp/notification-args"
  export TEST_GENERIC_ARGS="$tmp/generic-args"
  export PATH="$tmp/bin:$PATH"
  rm -f "$TEST_GUM_COUNTER"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
make_fake_commands "$tmp/bin"
run_picker_test "$tmp"

# A model and reasoning selection must reach Codex as explicit overrides, while
# retaining the crash details in the prompt.
printf '%s\n' 'GPT-5.6 Terra — balanced' 'medium' >"$TEST_GUM_SELECTIONS"
"$picker" --terminal 2337144 chromium /usr/lib/chromium/chromium SIGILL
mapfile -d '' -t codex_args <"$TEST_CODEX_ARGS"
[[ ${codex_args[*]} == *'--model gpt-5.6-terra'* ]] || fail "Codex did not receive the selected model"
[[ ${codex_args[*]} == *'model_reasoning_effort="medium"'* ]] || fail "Codex did not receive the selected reasoning level"
[[ ${codex_args[*]} == *'PID:      2337144'* ]] || fail "Codex prompt omitted the PID"
[[ ${codex_args[*]} == *'process:  chromium'* ]] || fail "Codex prompt omitted the process"

# Astra must not offer the unsupported `none` level.
: >"$TEST_GUM_INPUT"
printf '%s\n' 'GPT-6 Astra — hardest investigations' 'high' >"$TEST_GUM_SELECTIONS"
rm -f "$TEST_GUM_COUNTER"
"$picker" --terminal 2337144 chromium /usr/lib/chromium/chromium SIGILL
if grep -Fx 'none' "$TEST_GUM_INPUT" >/dev/null; then
  fail "Astra reasoning picker offered unsupported level none"
fi

# Cancelling model selection must not launch Codex.
rm -f "$TEST_CODEX_ARGS"
cat >"$tmp/bin/gum" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$tmp/bin/gum"
"$picker" --terminal 2337144 chromium /usr/lib/chromium/chromium SIGILL
[[ ! -e $TEST_CODEX_ARGS ]] || fail "Codex launched after picker cancellation"

# The outer invocation must open the picker in the standard Omarchy agent terminal.
"$picker" 2337144 chromium /usr/lib/chromium/chromium SIGILL
mapfile -d '' -t launch_args <"$TEST_LAUNCH_ARGS"
[[ ${launch_args[0]} == '--app-id=org.omarchy.agent' ]] || fail "picker used the wrong terminal app id"
[[ ${launch_args[2]} == '--terminal' ]] || fail "picker did not enter terminal mode"
[[ ${launch_args[3]} == '2337144' ]] || fail "picker lost crash arguments"

# The watcher announcement contract is the user-facing behavior being changed.
"$watcher" --announce 2337144 chromium /usr/lib/chromium/chromium SIGILL
mapfile -d '' -t notification_args <"$TEST_NOTIFICATION_ARGS"
[[ ${notification_args[*]} == *'Left-click diagnose · Right-click dismiss.'* ]] || fail "notification lacks dismissal guidance"
expected_dispatcher="$project_dir/bin/codex-crash-dispatch"
[[ ${notification_args[*]} == *"--exec $expected_dispatcher 2337144 chromium /usr/lib/chromium/chromium SIGILL"* ]] || fail "notification does not launch the click-time dispatcher"

# The dispatcher checks the default at click time: Codex gets the picker, while
# another agent retains Omarchy's generic diagnosis path.
rm -f "$TEST_LAUNCH_ARGS" "$TEST_GENERIC_ARGS"
TEST_DEFAULT_AGENT=codex "$dispatcher" 2337144 chromium /usr/lib/chromium/chromium SIGILL
[[ -e $TEST_LAUNCH_ARGS ]] || fail "Codex default did not open the model picker"
[[ ! -e $TEST_GENERIC_ARGS ]] || fail "Codex default incorrectly used generic diagnosis"

rm -f "$TEST_LAUNCH_ARGS" "$TEST_GENERIC_ARGS"
TEST_DEFAULT_AGENT=claude "$dispatcher" 2337144 chromium /usr/lib/chromium/chromium SIGILL
mapfile -d '' -t generic_args <"$TEST_GENERIC_ARGS"
[[ ${generic_args[*]} == *'2337144 chromium /usr/lib/chromium/chromium SIGILL'* ]] || fail "non-Codex agent did not retain the generic diagnosis path"
[[ ! -e $TEST_LAUNCH_ARGS ]] || fail "non-Codex default incorrectly opened the Codex picker"

printf 'PASS: crash notification and Codex picker behavior\n'

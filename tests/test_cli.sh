#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

begin_test_file "test_cli"

CLI="${BASHCLAW_ROOT}/bashclaw"

# ---- bashclaw --version ----

test_start "bashclaw --version outputs version"
setup_test_env
result="$(bash "$CLI" --version 2>&1)"
assert_contains "$result" "BashClaw"
assert_match "$result" '[0-9]+\.[0-9]+\.[0-9]+'
teardown_test_env

test_start "bashclaw version outputs version"
setup_test_env
result="$(bash "$CLI" version 2>&1)"
assert_contains "$result" "BashClaw"
teardown_test_env

# ---- bashclaw --help ----

test_start "bashclaw --help shows usage"
setup_test_env
result="$(bash "$CLI" --help 2>&1)"
assert_contains "$result" "Usage:"
assert_contains "$result" "Commands:"
assert_contains "$result" "config"
assert_contains "$result" "session"
assert_contains "$result" "doctor"
teardown_test_env

test_start "bashclaw help shows usage"
setup_test_env
result="$(bash "$CLI" help 2>&1)"
assert_contains "$result" "Usage:"
teardown_test_env

test_start "bashclaw with no args shows usage"
setup_test_env
result="$(bash "$CLI" 2>&1)"
assert_contains "$result" "Usage:"
teardown_test_env

# ---- bashclaw config init ----

test_start "bashclaw config init creates config"
setup_test_env
result="$(bash "$CLI" config init 2>&1)"
assert_file_exists "$BASHCLAW_CONFIG"
content="$(cat "$BASHCLAW_CONFIG")"
assert_json_valid "$content"
teardown_test_env

# ---- bashclaw config show ----

test_start "bashclaw config show outputs JSON"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
result="$(bash "$CLI" config show 2>&1)"
assert_contains "$result" "agents"
teardown_test_env

# ---- bashclaw config get ----

test_start "bashclaw config get returns values"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
result="$(bash "$CLI" config get '.gateway.port' 2>&1)"
assert_contains "$result" "18789"
teardown_test_env

# ---- bashclaw config set ----

test_start "bashclaw config set updates values"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
bash "$CLI" config set '.gateway.port' '9999' >/dev/null 2>&1
result="$(bash "$CLI" config get '.gateway.port' 2>&1)"
assert_contains "$result" "9999"
teardown_test_env

# ---- bashclaw session list ----

test_start "bashclaw session list works with no sessions"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
result="$(bash "$CLI" session list 2>&1)"
# May output "No sessions found." or JSON array
assert_contains "$result" "session"
teardown_test_env

# ---- bashclaw doctor ----

test_start "bashclaw doctor checks dependencies"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
result="$(bash "$CLI" doctor 2>&1)" || true
assert_contains "$result" "BashClaw doctor"
assert_contains "$result" "bash"
assert_contains "$result" "jq"
assert_contains "$result" "curl"
teardown_test_env

# ---- bashclaw status ----

test_start "bashclaw status shows state"
setup_test_env
bash "$CLI" config init >/dev/null 2>&1
result="$(bash "$CLI" status 2>&1)"
assert_contains "$result" "BashClaw status"
assert_contains "$result" "Version:"
assert_contains "$result" "State dir:"
teardown_test_env

# ---- Unknown command ----

test_start "bashclaw unknown command shows error"
setup_test_env
result="$(bash "$CLI" nonexistent_command 2>&1)" || true
# The error goes to stderr via log_error, then usage is printed
# Check that usage is shown (which means the error path was hit)
assert_contains "$result" "Usage:"
teardown_test_env

report_results

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-bootstrap"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

begin_test_file "test_channels"

BASH_MAJOR="${BASH_VERSINFO[0]}"

# Helper: try to source a channel file safely on bash 3.2
_try_source_channel() {
  local file="$1"
  local rc=0
  set +e
  source "$file" 2>/dev/null
  rc=$?
  set -e
  return $rc
}

# ---- Channel scripts can be sourced ----

test_start "telegram.sh can be sourced without error"
setup_test_env
if _try_source_channel "${BASHCLAW_ROOT}/channels/telegram.sh"; then
  _test_pass
else
  if (( BASH_MAJOR < 4 )); then
    printf '  SKIP bash %s lacks declare -gA\n' "$BASH_VERSION"
    _test_pass
  else
    _test_fail "telegram.sh failed to source"
  fi
fi
teardown_test_env

test_start "discord.sh can be sourced without error"
setup_test_env
if _try_source_channel "${BASHCLAW_ROOT}/channels/discord.sh"; then
  _test_pass
else
  if (( BASH_MAJOR < 4 )); then
    printf '  SKIP bash %s lacks declare -gA\n' "$BASH_VERSION"
    _test_pass
  else
    _test_fail "discord.sh failed to source"
  fi
fi
teardown_test_env

test_start "slack.sh can be sourced without error"
setup_test_env
if [[ -f "${BASHCLAW_ROOT}/channels/slack.sh" ]]; then
  if _try_source_channel "${BASHCLAW_ROOT}/channels/slack.sh"; then
    _test_pass
  else
    if (( BASH_MAJOR < 4 )); then
      printf '  SKIP bash %s lacks declare -gA\n' "$BASH_VERSION"
      _test_pass
    else
      _test_fail "slack.sh failed to source"
    fi
  fi
else
  _test_pass
fi
teardown_test_env

# ---- Message constants via _channel_max_length ----

test_start "telegram max message length is 4096"
setup_test_env
result="$(_channel_max_length "telegram")"
assert_eq "$result" "4096"
teardown_test_env

test_start "discord max message length is 2000"
setup_test_env
result="$(_channel_max_length "discord")"
assert_eq "$result" "2000"
teardown_test_env

# ---- Message truncation (telegram) ----

test_start "telegram reply truncation uses 4096 limit"
setup_test_env
long_msg="$(python3 -c "print('A' * 5000)")"
result="$(routing_format_reply "telegram" "$long_msg")"
len="${#result}"
assert_ge 4200 "$len" "telegram reply should be roughly truncated to 4096"
assert_contains "$result" "[message truncated]"
teardown_test_env

# ---- Message truncation (discord) ----

test_start "discord reply truncation uses 2000 limit"
setup_test_env
long_msg="$(python3 -c "print('B' * 3000)")"
result="$(routing_format_reply "discord" "$long_msg")"
len="${#result}"
assert_ge 2100 "$len" "discord reply should be roughly truncated to 2000"
assert_contains "$result" "[message truncated]"
teardown_test_env

# ---- Channel max length map via function ----

test_start "_channel_max_length telegram=4096"
setup_test_env
assert_eq "$(_channel_max_length "telegram")" "4096"
teardown_test_env

test_start "_channel_max_length discord=2000"
setup_test_env
assert_eq "$(_channel_max_length "discord")" "2000"
teardown_test_env

test_start "_channel_max_length slack=40000"
setup_test_env
assert_eq "$(_channel_max_length "slack")" "40000"
teardown_test_env

test_start "_channel_max_length default=4096"
setup_test_env
assert_eq "$(_channel_max_length "unknown_channel")" "4096"
teardown_test_env

report_results

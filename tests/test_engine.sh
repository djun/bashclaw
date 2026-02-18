#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-engine"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

begin_test_file "test_engine"

# ---- engine_detect ----

test_start "engine_detect returns a valid engine name"
setup_test_env
result="$(engine_detect)"
case "$result" in
  builtin|claude|codex)
    _test_pass
    ;;
  *)
    _test_fail "unexpected engine: $result"
    ;;
esac
teardown_test_env

# ---- engine_resolve ----

test_start "engine_resolve reads config defaults"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
assert_eq "$result" "builtin"
teardown_test_env

test_start "engine_resolve reads per-agent engine"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": [{"id": "research", "engine": "claude"}]
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "research")"
assert_eq "$result" "claude"
teardown_test_env

test_start "engine_resolve auto falls back to valid engine"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "auto"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
case "$result" in
  builtin|claude|codex)
    _test_pass
    ;;
  *)
    _test_fail "unexpected engine from auto: $result"
    ;;
esac
teardown_test_env

test_start "engine_resolve unknown engine falls back to builtin"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "nonexistent-engine"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_resolve "main")"
assert_eq "$result" "builtin"
teardown_test_env

# ---- engine_info ----

test_start "engine_info returns valid JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "auto"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
result="$(engine_info)"
assert_json_valid "$result"
# Must contain detected and engines fields
detected="$(printf '%s' "$result" | jq -r '.detected')"
assert_ne "$detected" "null"
has_builtin="$(printf '%s' "$result" | jq -r '.engines.builtin.available')"
assert_eq "$has_builtin" "true"
teardown_test_env

# ---- engine_claude_available ----

test_start "engine_claude_available returns without error"
setup_test_env
# Just test it doesn't crash
engine_claude_available || true
_test_pass
teardown_test_env

# ---- engine_claude_session_id ----

test_start "engine_claude_session_id reads from session metadata"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
local_sess="${BASHCLAW_STATE_DIR}/sessions/test_cc.jsonl"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
# Write metadata with cc_session_id
session_meta_update "$local_sess" "cc_session_id" '"abc-123-def"'
result="$(engine_claude_session_id "$local_sess")"
assert_eq "$result" "abc-123-def"
teardown_test_env

test_start "engine_claude_session_id returns empty for no metadata"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"session": {"scope": "global"}}
EOF
_CONFIG_CACHE=""
config_load
local_sess="${BASHCLAW_STATE_DIR}/sessions/test_cc_empty.jsonl"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
result="$(engine_claude_session_id "$local_sess")"
assert_eq "$result" ""
teardown_test_env

# ---- engine_claude_version ----

test_start "engine_claude_version does not crash"
setup_test_env
# Returns version string or empty, should not error
result="$(engine_claude_version)" || true
_test_pass
teardown_test_env

# ---- engine_run with builtin engine calls agent_run ----

test_start "engine_run with builtin engine calls agent_run"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
# Mock agent_run to return a known value
agent_run() {
  printf 'mock_agent_response'
}
result="$(engine_run "main" "test message" "web" "tester")"
assert_eq "$result" "mock_agent_response"
# Restore original agent_run
for _lib in "${BASHCLAW_ROOT}"/lib/agent.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
teardown_test_env

# ---- engine_run with unknown agent falls back to builtin ----

test_start "engine_run with unknown agent falls back to builtin"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {
    "defaults": {"engine": "builtin"},
    "list": []
  }
}
EOF
_CONFIG_CACHE=""
config_load
# Mock agent_run to confirm builtin path is taken
agent_run() {
  printf 'fallback_builtin_response'
}
result="$(engine_run "nonexistent_agent_xyz" "hello" "web" "tester")"
assert_eq "$result" "fallback_builtin_response"
# Restore original agent_run
for _lib in "${BASHCLAW_ROOT}"/lib/agent.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
teardown_test_env

# ---- engine_claude_run with mock claude CLI ----

test_start "engine_claude_run parses successful JSON result"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Create a mock claude command that outputs valid JSON
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"duration_ms":5000,"num_turns":2,"result":"Hello from Claude engine","session_id":"sess-abc-123","total_cost_usd":0.05,"usage":{"input_tokens":100,"output_tokens":50}}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
# Override claude command
claude() { "$mock_claude_bin" "$@"; }
export -f claude
# Override is_command_available to find mock claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test message" "default" "tester")"
assert_eq "$result" "Hello from Claude engine"
# Verify session metadata was persisted
local_sess="$(session_file "main" "default" "tester")"
cc_sid="$(engine_claude_session_id "$local_sess")"
assert_eq "$cc_sid" "sess-abc-123"
# Restore
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles error result"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_err"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","subtype":"success","is_error":true,"duration_ms":1000,"num_turns":1,"result":"Auth failed: 401","session_id":"sess-err-456","total_cost_usd":0,"usage":{}}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester")"
assert_eq "$result" "Auth failed: 401"
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles empty output"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_empty"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
# Output nothing
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester" 2>/dev/null)" || true
assert_eq "$result" ""
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run handles invalid JSON output"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_bad"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'not valid json at all'
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_claude_run "main" "test" "default" "tester" 2>/dev/null)" || true
assert_eq "$result" ""
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run with session resume passes --resume flag"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Pre-populate session with cc_session_id
local_sess="$(session_file "main" "default" "resume_tester")"
mkdir -p "$(dirname "$local_sess")"
touch "$local_sess"
session_meta_update "$local_sess" "cc_session_id" '"existing-sess-789"'
# Create mock that captures args
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_resume"
args_capture="${BASHCLAW_STATE_DIR}/claude_args_captured"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"resumed ok","session_id":"existing-sess-789","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "continue" "default" "resume_tester" >/dev/null 2>&1
# Check that --resume was passed
if grep -q "existing-sess-789" "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "--resume flag not passed with existing session_id"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_run dispatches to claude engine when configured"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_dispatch"
cat > "$mock_claude_bin" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"result","is_error":false,"result":"dispatched to claude","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
result="$(engine_run "main" "test dispatch" "default" "tester")"
assert_eq "$result" "dispatched to claude"
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run injects bashclaw-context into message"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
# Mock claude that captures its -p argument
args_capture="${BASHCLAW_STATE_DIR}/claude_ctx_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_ctx"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
# Capture all args to file
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"s1","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "hello world" "default" "ctx_tester" >/dev/null 2>&1
# Check that the -p arg contains <bashclaw-context> and the user message
prompt_arg="$(cat "$args_capture" 2>/dev/null)"
if printf '%s' "$prompt_arg" | grep -q '<bashclaw-context>'; then
  _test_pass
else
  _test_fail "Message does not contain <bashclaw-context> tag"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run passes --setting-sources empty"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_ss_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_ss"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "ss_tester" >/dev/null 2>&1
if grep -q '\-\-setting-sources' "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "Missing --setting-sources flag"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

test_start "engine_claude_run includes bashclaw tool path in context"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{
  "agents": {"defaults": {"engine": "claude"}, "list": []},
  "session": {"scope": "global"}
}
EOF
_CONFIG_CACHE=""
config_load
args_capture="${BASHCLAW_STATE_DIR}/claude_tool_args"
mock_claude_bin="${BASHCLAW_STATE_DIR}/mock_claude_tool"
cat > "$mock_claude_bin" <<MOCKEOF
#!/usr/bin/env bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$args_capture"
cat <<'JSON'
{"type":"result","is_error":false,"result":"ok","session_id":"","total_cost_usd":0,"num_turns":1}
JSON
MOCKEOF
chmod +x "$mock_claude_bin"
claude() { "$mock_claude_bin" "$@"; }
export -f claude
is_command_available() { [[ "$1" == "claude" ]] && return 0; command -v "$1" &>/dev/null; }
engine_claude_run "main" "test" "default" "tool_tester" >/dev/null 2>&1
if grep -q 'bashclaw tool' "$args_capture" 2>/dev/null; then
  _test_pass
else
  _test_fail "Context does not contain bashclaw tool invocation pattern"
fi
unset -f claude
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do [[ -f "$_lib" ]] && source "$_lib"; done
teardown_test_env

# ---- bashclaw tool CLI subcommand ----

test_start "bashclaw tool memory executes with flags"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory --action set --key test_key --value test_val 2>/dev/null)"
assert_contains "$result" "test_key"
result2="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory --action get --key test_key 2>/dev/null)"
assert_contains "$result2" "test_val"
teardown_test_env

test_start "bashclaw tool memory also accepts raw JSON"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
config_load
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory '{"action":"set","key":"json_key","value":"json_val"}' 2>/dev/null)"
assert_contains "$result" "json_key"
result2="$(bash "${BASHCLAW_ROOT}/bashclaw" tool memory '{"action":"get","key":"json_key"}' 2>/dev/null)"
assert_contains "$result2" "json_val"
teardown_test_env

test_start "bashclaw tool unknown tool returns error"
setup_test_env
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool nonexistent_tool --foo bar 2>&1)" || true
assert_contains "$result" "unknown tool"
teardown_test_env

test_start "bashclaw tool with no args shows usage"
setup_test_env
result="$(bash "${BASHCLAW_ROOT}/bashclaw" tool 2>&1)" || true
assert_contains "$result" "Usage:"
teardown_test_env

# ---- tools_describe_bridge_only ----

test_start "tools_describe_bridge_only mentions bashclaw tool CLI"
setup_test_env
result="$(tools_describe_bridge_only)"
assert_contains "$result" "bashclaw tool"
teardown_test_env

report_results

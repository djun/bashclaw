#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/framework.sh"

export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-mcp"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

MCP_SERVER="${BASHCLAW_ROOT}/mcp/server.sh"

begin_test_file "test_mcp_server"

# Helper: send a JSON-RPC request to MCP server and capture response
_mcp_call() {
  local input="$1"
  export BASHCLAW_STATE_DIR BASHCLAW_CONFIG LOG_LEVEL
  printf '%s\n' "$input" | bash "$MCP_SERVER" 2>/dev/null
}

# Helper: send multiple requests
_mcp_call_multi() {
  export BASHCLAW_STATE_DIR BASHCLAW_CONFIG LOG_LEVEL
  bash "$MCP_SERVER" 2>/dev/null
}

# ---- MCP server exists ----

test_start "MCP server script exists"
setup_test_env
assert_file_exists "$MCP_SERVER"
teardown_test_env

# ---- initialize ----

test_start "MCP initialize returns protocolVersion and serverInfo"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}')"
assert_json_valid "$result"
proto="$(printf '%s' "$result" | jq -r '.result.protocolVersion')"
assert_eq "$proto" "2024-11-05"
name="$(printf '%s' "$result" | jq -r '.result.serverInfo.name')"
assert_eq "$name" "bashclaw"
teardown_test_env

# ---- tools/list ----

test_start "MCP tools/list returns tool array"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | _mcp_call_multi | tail -1)"
assert_json_valid "$result"
tool_count="$(printf '%s' "$result" | jq '.result.tools | length')"
assert_gt "$tool_count" 0
# Check memory tool is present
has_memory="$(printf '%s' "$result" | jq '[.result.tools[] | select(.name == "memory")] | length')"
assert_eq "$has_memory" "1"
teardown_test_env

test_start "MCP tools/list includes inputSchema"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | _mcp_call_multi | tail -1)"
schema_type="$(printf '%s' "$result" | jq -r '.result.tools[0].inputSchema.type')"
assert_eq "$schema_type" "object"
teardown_test_env

# ---- tools/call ----

test_start "MCP tools/call memory set and get"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
mkdir -p "${BASHCLAW_STATE_DIR}/memory"
# Set a key
result="$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory","arguments":{"action":"set","key":"mcp_test","value":"hello_mcp"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory","arguments":{"action":"get","key":"mcp_test"}}}' \
  | _mcp_call_multi)"
# Check the get response (last line)
get_resp="$(printf '%s' "$result" | tail -1)"
assert_json_valid "$get_resp"
content="$(printf '%s' "$get_resp" | jq -r '.result.content[0].text')"
assert_contains "$content" "hello_mcp"
teardown_test_env

test_start "MCP tools/call returns error for unknown tool"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}')"
assert_json_valid "$result"
err_code="$(printf '%s' "$result" | jq '.error.code')"
assert_eq "$err_code" "-32601"
teardown_test_env

test_start "MCP tools/call validates tool name format"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"../etc/passwd","arguments":{}}}')"
assert_json_valid "$result"
err_msg="$(printf '%s' "$result" | jq -r '.error.message')"
assert_contains "$err_msg" "Invalid tool name"
teardown_test_env

# ---- resources/list and prompts/list ----

test_start "MCP resources/list returns empty array"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{}}')"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq '.result.resources | length')"
assert_eq "$count" "0"
teardown_test_env

test_start "MCP prompts/list returns empty array"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"prompts/list","params":{}}')"
assert_json_valid "$result"
count="$(printf '%s' "$result" | jq '.result.prompts | length')"
assert_eq "$count" "0"
teardown_test_env

# ---- Unknown method ----

test_start "MCP unknown method returns error -32601"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","id":99,"method":"completions/create","params":{}}')"
assert_json_valid "$result"
err_code="$(printf '%s' "$result" | jq '.error.code')"
assert_eq "$err_code" "-32601"
teardown_test_env

# ---- Notifications are silent ----

test_start "MCP notifications/initialized produces no response"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(_mcp_call '{"jsonrpc":"2.0","method":"notifications/initialized"}')"
assert_eq "$result" ""
teardown_test_env

# ---- Empty/whitespace lines are skipped ----

test_start "MCP server skips empty lines"
setup_test_env
cat > "$BASHCLAW_CONFIG" <<'EOF'
{"agents":{"defaults":{},"list":[]}}
EOF
_CONFIG_CACHE=""
result="$(printf '\n\n%s\n\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | _mcp_call_multi)"
assert_json_valid "$result"
assert_contains "$result" "protocolVersion"
teardown_test_env

report_results

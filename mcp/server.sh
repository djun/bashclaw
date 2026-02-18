#!/usr/bin/env bash
# BashClaw MCP Server
# Exposes BashClaw-specific tools to Claude Code CLI via MCP stdio protocol (JSON-RPC 2.0 / NDJSON).
# Each line on stdin is a complete JSON-RPC 2.0 message; each response is a single line on stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export BASHCLAW_STATE_DIR="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR must be set}"
export LOG_LEVEL="${LOG_LEVEL:-silent}"

for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

if [[ -n "${BASHCLAW_CONFIG:-}" && -f "$BASHCLAW_CONFIG" ]]; then
  _CONFIG_CACHE=""
  config_load 2>/dev/null || true
fi

# Tools exposed via MCP bridge (BashClaw-specific, not mapped to Claude native tools)
MCP_BRIDGE_TOOLS="memory cron message agents_list session_status sessions_list agent_message spawn spawn_status"

# Cached tools/list response (built once on first request)
_MCP_TOOLS_CACHE=""

# ---- JSON-RPC Helpers ----

_mcp_response() {
  local id="$1" result="$2"
  printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$result"
}

_mcp_error() {
  local id="$1" code="$2" msg="$3"
  local escaped
  escaped="$(printf '%s' "$msg" | jq -Rs '.')"
  printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}\n' "$id" "$code" "$escaped"
}

# ---- Tool Spec Builder ----

_mcp_build_tools_cache() {
  if [[ -n "$_MCP_TOOLS_CACHE" ]]; then
    return
  fi

  local full_spec
  full_spec="$(_tools_build_full_spec 2>/dev/null)" || full_spec="[]"

  local tools_array="[]"
  local tool_name
  for tool_name in $MCP_BRIDGE_TOOLS; do
    local tool_spec
    tool_spec="$(printf '%s' "$full_spec" | jq -c --arg name "$tool_name" \
      '[.[] | select(.name == $name)] | if length > 0 then .[0] | {name, description, inputSchema: .input_schema} else empty end' 2>/dev/null)"
    if [[ -n "$tool_spec" ]]; then
      tools_array="$(printf '%s' "$tools_array" | jq -c --argjson t "$tool_spec" '. + [$t]')"
    fi
  done

  _MCP_TOOLS_CACHE="$tools_array"
}

# ---- MCP Protocol Handlers ----

_handle_initialize() {
  local id="$1"
  _mcp_response "$id" '{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"bashclaw","version":"1.0.0"}}'
}

_handle_tools_list() {
  local id="$1"
  _mcp_build_tools_cache
  _mcp_response "$id" "$(printf '{"tools":%s}' "$_MCP_TOOLS_CACHE")"
}

_handle_resources_list() {
  local id="$1"
  _mcp_response "$id" '{"resources":[]}'
}

_handle_prompts_list() {
  local id="$1"
  _mcp_response "$id" '{"prompts":[]}'
}

_handle_tools_call() {
  local id="$1" request="$2"

  local tool_name arguments
  tool_name="$(printf '%s' "$request" | jq -r '.params.name // empty')"
  arguments="$(printf '%s' "$request" | jq -c '.params.arguments // {}' 2>/dev/null)"

  if [[ -z "$tool_name" ]]; then
    _mcp_error "$id" -32602 "Missing tool name"
    return
  fi

  # Validate tool name: alphanumeric and underscore only
  if ! [[ "$tool_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    _mcp_error "$id" -32602 "Invalid tool name format: $tool_name"
    return
  fi

  # Verify tool is in bridge list
  local found="false"
  local t
  for t in $MCP_BRIDGE_TOOLS; do
    if [[ "$t" == "$tool_name" ]]; then
      found="true"
      break
    fi
  done

  if [[ "$found" != "true" ]]; then
    _mcp_error "$id" -32601 "Tool not found: $tool_name"
    return
  fi

  # Execute via BashClaw tool dispatcher
  local result="" tool_rc=0
  result="$(tool_execute "$tool_name" "$arguments" 2>/dev/null)" || tool_rc=$?

  if [[ $tool_rc -ne 0 && -z "$result" ]]; then
    result="tool execution failed with code $tool_rc"
  fi

  # Normalize: collapse newlines for NDJSON safety, then JSON-stringify
  local content_text
  content_text="$(printf '%s' "$result" | tr '\n' ' ' | jq -Rs '.')"

  local is_error="false"
  if [[ $tool_rc -ne 0 ]]; then
    is_error="true"
  fi

  _mcp_response "$id" "$(printf '{"content":[{"type":"text","text":%s}],"isError":%s}' "$content_text" "$is_error")"
}

# ---- Main Loop (NDJSON) ----

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  # Skip stray HTTP framing from some transports
  [[ "$line" == "Content-Length:"* ]] && continue

  method="$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null)" || continue
  id="$(printf '%s' "$line" | jq -r '.id // "null"' 2>/dev/null)"

  case "$method" in
    initialize)
      _handle_initialize "$id"
      ;;
    notifications/initialized|notifications/*)
      # Notifications need no response
      ;;
    tools/list)
      _handle_tools_list "$id"
      ;;
    tools/call)
      _handle_tools_call "$id" "$line"
      ;;
    resources/list)
      _handle_resources_list "$id"
      ;;
    prompts/list)
      _handle_prompts_list "$id"
      ;;
    "")
      ;;
    *)
      _mcp_error "$id" -32601 "Method not found: $method"
      ;;
  esac
done

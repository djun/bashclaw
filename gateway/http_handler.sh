#!/usr/bin/env bash
# HTTP handler for socat-based gateway
# This script is executed per-connection by socat

# Source the main bashclaw if not already loaded
if ! declare -f log_info &>/dev/null; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${SCRIPT_DIR}/lib/log.sh"
  source "${SCRIPT_DIR}/lib/utils.sh"
  source "${SCRIPT_DIR}/lib/config.sh"
  source "${SCRIPT_DIR}/lib/session.sh"
  source "${SCRIPT_DIR}/lib/tools.sh"
  source "${SCRIPT_DIR}/lib/agent.sh"
  source "${SCRIPT_DIR}/lib/routing.sh"

  # Load .env if present
  env_file="${BASHCLAW_STATE_DIR:?}/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    source "$env_file"
    set +a
  fi
fi

BASHCLAW_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ui"

# ---- HTTP Request Parser ----

_http_read_request() {
  local line
  IFS= read -r line
  line="${line%%$'\r'}"

  HTTP_METHOD=""
  HTTP_PATH=""
  HTTP_VERSION=""
  HTTP_BODY=""
  HTTP_CONTENT_LENGTH=0
  HTTP_QUERY=""

  # Parse request line
  IFS=' ' read -r HTTP_METHOD HTTP_PATH HTTP_VERSION <<< "$line"

  # Split path and query string
  if [[ "$HTTP_PATH" == *"?"* ]]; then
    HTTP_QUERY="${HTTP_PATH#*\?}"
    HTTP_PATH="${HTTP_PATH%%\?*}"
  fi

  # Read headers
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" ]] && break

    local lower_line
    lower_line="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_line" == content-length:* ]]; then
      HTTP_CONTENT_LENGTH="${line#*: }"
      HTTP_CONTENT_LENGTH="${HTTP_CONTENT_LENGTH%%$'\r'}"
    fi
  done

  # Read body if present
  if (( HTTP_CONTENT_LENGTH > 0 )); then
    HTTP_BODY="$(head -c "$HTTP_CONTENT_LENGTH")"
  fi
}

# ---- HTTP Response Writer ----

_http_respond() {
  local status="$1"
  local content_type="${2:-application/json}"
  local body="$3"

  local status_text
  case "$status" in
    200) status_text="OK" ;;
    304) status_text="Not Modified" ;;
    400) status_text="Bad Request" ;;
    401) status_text="Unauthorized" ;;
    404) status_text="Not Found" ;;
    405) status_text="Method Not Allowed" ;;
    500) status_text="Internal Server Error" ;;
    *) status_text="Unknown" ;;
  esac

  local body_length="${#body}"

  printf 'HTTP/1.1 %s %s\r\n' "$status" "$status_text"
  printf 'Content-Type: %s\r\n' "$content_type"
  printf 'Content-Length: %d\r\n' "$body_length"
  printf 'Connection: close\r\n'
  printf 'Access-Control-Allow-Origin: *\r\n'
  printf 'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n'
  printf 'Access-Control-Allow-Headers: Content-Type, Authorization\r\n'
  printf '\r\n'
  printf '%s' "$body"
}

_http_respond_json() {
  local status="$1"
  local json="$2"
  _http_respond "$status" "application/json" "$json"
}

# Serve a static file with proper MIME type
_http_serve_file() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    _http_respond_json 404 '{"error":"file not found"}'
    return
  fi

  local mime_type="application/octet-stream"
  case "$file_path" in
    *.html) mime_type="text/html; charset=utf-8" ;;
    *.css)  mime_type="text/css; charset=utf-8" ;;
    *.js)   mime_type="application/javascript; charset=utf-8" ;;
    *.json) mime_type="application/json; charset=utf-8" ;;
    *.svg)  mime_type="image/svg+xml" ;;
    *.png)  mime_type="image/png" ;;
    *.ico)  mime_type="image/x-icon" ;;
  esac

  local body
  body="$(cat "$file_path")"
  _http_respond 200 "$mime_type" "$body"
}

# ---- Auth Check ----

_http_check_auth() {
  local auth_token
  auth_token="$(config_get '.gateway.auth.token' '')"

  # No token configured = no auth required
  if [[ -z "$auth_token" ]]; then
    return 0
  fi

  # Check Authorization header from request headers
  # In socat mode, we need to extract it during header parsing
  # For now, skip auth in the minimal handler
  return 0
}

# ---- Route Handler ----

handle_request() {
  _http_read_request

  # Handle CORS preflight
  if [[ "$HTTP_METHOD" == "OPTIONS" ]]; then
    _http_respond 200 "text/plain" ""
    return
  fi

  log_debug "HTTP request: $HTTP_METHOD $HTTP_PATH"

  # Static file serving for /ui paths
  case "$HTTP_PATH" in
    /ui|/ui/)
      _http_serve_file "${BASHCLAW_UI_DIR}/index.html"
      return
      ;;
    /ui/*)
      # Path traversal protection
      local rel_path="${HTTP_PATH#/ui/}"
      case "$rel_path" in
        *..*)
          _http_respond_json 400 '{"error":"path traversal not allowed"}'
          return
          ;;
      esac
      _http_serve_file "${BASHCLAW_UI_DIR}/${rel_path}"
      return
      ;;
  esac

  case "$HTTP_METHOD:$HTTP_PATH" in
    # Legacy routes (backward compatible)
    GET:/status|GET:/health|GET:/healthz)
      _handle_status
      ;;
    POST:/chat)
      _handle_chat
      ;;
    POST:/session/clear)
      _handle_session_clear
      ;;
    POST:/message/send)
      _handle_message_send
      ;;

    # REST API: status
    GET:/api/status)
      _handle_status
      ;;

    # REST API: config
    GET:/api/config)
      _handle_api_config_get
      ;;
    PUT:/api/config)
      _handle_api_config_set
      ;;

    # REST API: models
    GET:/api/models)
      _handle_api_models
      ;;

    # REST API: sessions
    GET:/api/sessions)
      _handle_api_sessions_list
      ;;
    POST:/api/sessions/clear)
      _handle_session_clear
      ;;

    # REST API: chat
    POST:/api/chat)
      _handle_chat
      ;;

    # REST API: channels
    GET:/api/channels)
      _handle_api_channels
      ;;

    # REST API: env (API keys management)
    GET:/api/env)
      _handle_api_env_get
      ;;
    PUT:/api/env)
      _handle_api_env_set
      ;;

    # Root redirects to UI
    GET:/)
      _http_serve_file "${BASHCLAW_UI_DIR}/index.html"
      ;;

    *)
      _http_respond_json 404 '{"error":"not found"}'
      ;;
  esac
}

# ---- Legacy Route Implementations ----

_handle_status() {
  require_command jq "status handler requires jq"

  local uptime_info=""
  if [[ -f "${BASHCLAW_STATE_DIR}/gateway.pid" ]]; then
    local pid
    pid="$(cat "${BASHCLAW_STATE_DIR}/gateway.pid" 2>/dev/null)"
    uptime_info="$(jq -nc --arg pid "$pid" '{pid: $pid, running: true}')"
  else
    uptime_info='{"running": false}'
  fi

  local session_count=0
  if [[ -d "${BASHCLAW_STATE_DIR}/sessions" ]]; then
    session_count="$(find "${BASHCLAW_STATE_DIR}/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  local model
  model="$(agent_resolve_model "main" 2>/dev/null)" || model="unknown"
  local provider
  provider="$(agent_resolve_provider "$model" 2>/dev/null)" || provider="unknown"

  local channels_configured="[]"
  channels_configured="$(config_get_raw '.channels | keys // []' 2>/dev/null)" || channels_configured="[]"

  local response
  response="$(jq -nc \
    --arg status "ok" \
    --arg version "${BASHCLAW_VERSION:-1.0.0}" \
    --arg model "$model" \
    --arg provider "$provider" \
    --argjson sessions "$session_count" \
    --argjson gateway "$uptime_info" \
    --argjson channels "$channels_configured" \
    '{status: $status, version: $version, model: $model, provider: $provider, sessions: $sessions, gateway: $gateway, channels: $channels}')"

  _http_respond_json 200 "$response"
}

_handle_chat() {
  require_command jq "chat handler requires jq"

  if [[ -z "$HTTP_BODY" ]]; then
    _http_respond_json 400 '{"error":"request body required"}'
    return
  fi

  # Parse all fields from body in a single jq call
  local parsed
  parsed="$(printf '%s' "$HTTP_BODY" | jq -r '[
    (.message // ""),
    (.agent // "main"),
    (.channel // "web"),
    (.sender // "http")
  ] | join("\n")' 2>/dev/null)"

  local message agent_id channel sender
  {
    IFS= read -r message
    IFS= read -r agent_id
    IFS= read -r channel
    IFS= read -r sender
  } <<< "$parsed"

  if [[ -z "$message" ]]; then
    _http_respond_json 400 '{"error":"message field is required"}'
    return
  fi

  local response
  response="$(agent_run "$agent_id" "$message" "$channel" "$sender" 2>/dev/null)"

  if [[ -n "$response" ]]; then
    local json
    json="$(jq -nc --arg r "$response" --arg a "$agent_id" \
      '{response: $r, agent: $a}')"
    _http_respond_json 200 "$json"
  else
    _http_respond_json 500 '{"error":"agent returned empty response"}'
  fi
}

_handle_session_clear() {
  require_command jq "session clear handler requires jq"

  local agent_id="main"
  local channel="web"
  local sender="http"

  if [[ -n "$HTTP_BODY" ]]; then
    local parsed
    parsed="$(printf '%s' "$HTTP_BODY" | jq -r '[
      (.agent // "main"),
      (.channel // "web"),
      (.sender // "http")
    ] | join("\n")' 2>/dev/null)"

    {
      IFS= read -r agent_id
      IFS= read -r channel
      IFS= read -r sender
    } <<< "$parsed"
  fi

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"
  session_clear "$sess_file"

  _http_respond_json 200 '{"cleared": true}'
}

_handle_message_send() {
  require_command jq "message send handler requires jq"

  if [[ -z "$HTTP_BODY" ]]; then
    _http_respond_json 400 '{"error":"request body required"}'
    return
  fi

  local parsed
  parsed="$(printf '%s' "$HTTP_BODY" | jq -r '[
    (.channel // ""),
    (.target // ""),
    (.message // "")
  ] | join("\n")' 2>/dev/null)"

  local ch target text
  {
    IFS= read -r ch
    IFS= read -r target
    IFS= read -r text
  } <<< "$parsed"

  if [[ -z "$ch" || -z "$target" || -z "$text" ]]; then
    _http_respond_json 400 '{"error":"channel, target, and message are required"}'
    return
  fi

  local send_func="channel_${ch}_send"
  if ! declare -f "$send_func" &>/dev/null; then
    # Try to load channel
    local ch_script
    ch_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels/${ch}.sh"
    if [[ -f "$ch_script" ]]; then
      source "$ch_script"
    fi
  fi

  if declare -f "$send_func" &>/dev/null; then
    local result
    result="$("$send_func" "$target" "$text" 2>/dev/null)"
    _http_respond_json 200 "$(jq -nc --arg ch "$ch" --arg r "$result" \
      '{sent: true, channel: $ch, result: $r}')"
  else
    _http_respond_json 400 "$(jq -nc --arg ch "$ch" \
      '{error: "unknown channel", channel: $ch}')"
  fi
}

# ---- REST API: Config ----

_handle_api_config_get() {
  require_command jq "config API requires jq"

  _config_ensure_loaded

  # Return config with sensitive fields masked
  local safe_config
  safe_config="$(printf '%s' "$_CONFIG_CACHE" | jq '
    walk(
      if type == "string" and (
        test("^(sk-|key-|token-)"; "i") or
        test("^[A-Za-z0-9]{20,}$")
      ) then "***"
      else .
      end
    )
  ' 2>/dev/null)" || safe_config="$_CONFIG_CACHE"

  _http_respond_json 200 "$safe_config"
}

_handle_api_config_set() {
  require_command jq "config API requires jq"

  if [[ -z "$HTTP_BODY" ]]; then
    _http_respond_json 400 '{"error":"request body required"}'
    return
  fi

  # Validate JSON
  if ! printf '%s' "$HTTP_BODY" | jq empty 2>/dev/null; then
    _http_respond_json 400 '{"error":"invalid JSON"}'
    return
  fi

  # Merge partial updates into existing config
  _config_ensure_loaded
  local merged
  merged="$(printf '%s\n%s' "$_CONFIG_CACHE" "$HTTP_BODY" | jq -s '.[0] * .[1]' 2>/dev/null)"

  if [[ -z "$merged" ]]; then
    _http_respond_json 500 '{"error":"config merge failed"}'
    return
  fi

  # Backup before write
  config_backup

  local path
  path="$(_config_resolve_path)"
  ensure_dir "$(dirname "$path")"
  printf '%s\n' "$merged" > "$path"
  chmod 600 "$path" 2>/dev/null || true

  # Reload cache
  _CONFIG_CACHE=""
  config_load

  _http_respond_json 200 '{"updated": true}'
}

# ---- REST API: Models ----

_handle_api_models() {
  require_command jq "models API requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  # Return models with provider info and aliases
  local response
  response="$(printf '%s' "$catalog" | jq '{
    models: [.providers | to_entries[] | .key as $prov | .value.models[]? | {
      id: .id,
      name: .name,
      provider: $prov,
      max_tokens: .max_tokens,
      context_window: .context_window,
      reasoning: .reasoning,
      input: .input
    }],
    aliases: .aliases,
    providers: [.providers | to_entries[] | {
      id: .key,
      api: .value.api,
      api_key_env: .value.api_key_env,
      has_key: false
    }]
  }' 2>/dev/null)"

  # Check which providers have API keys configured
  local providers_with_keys="[]"
  local p_list
  p_list="$(printf '%s' "$catalog" | jq -r '.providers | to_entries[] | "\(.key)|\(.value.api_key_env // "")"' 2>/dev/null)"
  while IFS='|' read -r p_id p_env; do
    [[ -z "$p_id" ]] && continue
    local has_key="false"
    if [[ -n "$p_env" ]]; then
      local key_val
      eval "key_val=\"\${${p_env}:-}\""
      if [[ -n "$key_val" ]]; then
        has_key="true"
      fi
    fi
    providers_with_keys="$(printf '%s' "$providers_with_keys" | jq --arg p "$p_id" --arg h "$has_key" '. + [{id: $p, has_key: ($h == "true")}]')"
  done <<< "$p_list"

  # Merge has_key info into response
  response="$(printf '%s' "$response" | jq --argjson pk "$providers_with_keys" '
    .providers = [.providers[] | . as $p | ($pk[] | select(.id == $p.id)) as $k | $p + {has_key: ($k.has_key // false)}]
  ' 2>/dev/null)"

  _http_respond_json 200 "$response"
}

# ---- REST API: Sessions ----

_handle_api_sessions_list() {
  require_command jq "sessions API requires jq"

  local sessions="[]"
  local session_dir="${BASHCLAW_STATE_DIR}/sessions"

  if [[ -d "$session_dir" ]]; then
    local f
    for f in "${session_dir}"/*.jsonl; do
      [[ -f "$f" ]] || continue
      local name
      name="$(basename "$f" .jsonl)"
      local msg_count
      msg_count="$(wc -l < "$f" | tr -d ' ')"
      local size
      size="$(wc -c < "$f" | tr -d ' ')"
      sessions="$(printf '%s' "$sessions" | jq --arg n "$name" --argjson c "$msg_count" --argjson s "$size" \
        '. + [{name: $n, messages: $c, size: $s}]')"
    done
  fi

  _http_respond_json 200 "$(jq -nc --argjson s "$sessions" '{sessions: $s, count: ($s | length)}')"
}

# ---- REST API: Channels ----

_handle_api_channels() {
  require_command jq "channels API requires jq"

  local channel_dir
  channel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels"

  local channels="[]"
  if [[ -d "$channel_dir" ]]; then
    local f
    for f in "${channel_dir}"/*.sh; do
      [[ -f "$f" ]] || continue
      local ch_name
      ch_name="$(basename "$f" .sh)"
      local enabled
      enabled="$(config_channel_get "$ch_name" "enabled" "false")"
      channels="$(printf '%s' "$channels" | jq --arg n "$ch_name" --arg e "$enabled" \
        '. + [{name: $n, enabled: ($e == "true"), installed: true}]')"
    done
  fi

  _http_respond_json 200 "$(jq -nc --argjson c "$channels" '{channels: $c, count: ($c | length)}')"
}

# ---- REST API: Env (API Keys) ----

_handle_api_env_get() {
  require_command jq "env API requires jq"

  local catalog
  catalog="$(_models_catalog_load)"

  # List provider env vars and whether they are set (never expose actual values)
  local env_status="[]"
  local p_list
  p_list="$(printf '%s' "$catalog" | jq -r '.providers | to_entries[] | "\(.key)|\(.value.api_key_env // "")"' 2>/dev/null)"
  while IFS='|' read -r p_id p_env; do
    [[ -z "$p_id" ]] && continue
    local is_set="false"
    if [[ -n "$p_env" ]]; then
      local key_val
      eval "key_val=\"\${${p_env}:-}\""
      if [[ -n "$key_val" ]]; then
        is_set="true"
      fi
    fi
    env_status="$(printf '%s' "$env_status" | jq --arg p "$p_id" --arg e "$p_env" --arg s "$is_set" \
      '. + [{provider: $p, env_var: $e, is_set: ($s == "true")}]')"
  done <<< "$p_list"

  # Also check search API keys
  for search_key in BRAVE_SEARCH_API_KEY PERPLEXITY_API_KEY; do
    local sk_val
    eval "sk_val=\"\${${search_key}:-}\""
    local sk_set="false"
    if [[ -n "$sk_val" ]]; then
      sk_set="true"
    fi
    env_status="$(printf '%s' "$env_status" | jq --arg e "$search_key" --arg s "$sk_set" \
      '. + [{provider: "search", env_var: $e, is_set: ($s == "true")}]')"
  done

  _http_respond_json 200 "$(jq -nc --argjson e "$env_status" '{env: $e}')"
}

_handle_api_env_set() {
  require_command jq "env API requires jq"

  if [[ -z "$HTTP_BODY" ]]; then
    _http_respond_json 400 '{"error":"request body required"}'
    return
  fi

  local env_file="${BASHCLAW_STATE_DIR:?}/.env"
  ensure_dir "$(dirname "$env_file")"

  # Parse key-value pairs from body
  local pairs
  pairs="$(printf '%s' "$HTTP_BODY" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)"
  if [[ -z "$pairs" ]]; then
    _http_respond_json 400 '{"error":"expected JSON object with key-value pairs"}'
    return
  fi

  # Validate keys are known env vars
  local catalog
  catalog="$(_models_catalog_load)"
  local known_keys
  known_keys="$(printf '%s' "$catalog" | jq -r '[.providers[].api_key_env // empty] | join(" ")' 2>/dev/null)"
  known_keys="$known_keys BRAVE_SEARCH_API_KEY PERPLEXITY_API_KEY"

  local updated=0
  while IFS='=' read -r env_key env_val; do
    [[ -z "$env_key" ]] && continue

    # Check if key is known
    local is_known="false"
    local k
    for k in $known_keys; do
      if [[ "$k" == "$env_key" ]]; then
        is_known="true"
        break
      fi
    done

    if [[ "$is_known" != "true" ]]; then
      continue
    fi

    # Update or append to .env file
    if [[ -f "$env_file" ]] && grep -q "^${env_key}=" "$env_file" 2>/dev/null; then
      # Update existing line (use temp file for portability)
      local tmp_env
      tmp_env="$(mktemp 2>/dev/null || mktemp -t bashclaw_env)"
      while IFS= read -r line; do
        if [[ "$line" == "${env_key}="* ]]; then
          printf '%s=%s\n' "$env_key" "$env_val"
        else
          printf '%s\n' "$line"
        fi
      done < "$env_file" > "$tmp_env"
      mv "$tmp_env" "$env_file"
    else
      printf '%s=%s\n' "$env_key" "$env_val" >> "$env_file"
    fi

    # Export to current process
    export "${env_key}=${env_val}"
    updated=$((updated + 1))
  done <<< "$pairs"

  chmod 600 "$env_file" 2>/dev/null || true

  _http_respond_json 200 "$(jq -nc --argjson n "$updated" '{updated: $n}')"
}

# If executed directly (by socat), run the handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  handle_request
fi

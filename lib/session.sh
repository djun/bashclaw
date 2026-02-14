#!/usr/bin/env bash
# JSONL session management for bashclaw

session_dir() {
  local base="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}/sessions"
  ensure_dir "$base"
  printf '%s' "$base"
}

session_file() {
  local agent_id="$1"
  local channel="${2:-default}"
  local sender="${3:-}"

  local scope
  scope="$(config_get '.session.scope' 'per-sender')"
  local dir
  dir="$(session_dir)"

  case "$scope" in
    per-sender)
      if [[ -n "$sender" ]]; then
        ensure_dir "${dir}/${agent_id}/${channel}"
        printf '%s/%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel" "$sender"
      else
        ensure_dir "${dir}/${agent_id}"
        printf '%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel"
      fi
      ;;
    per-channel)
      ensure_dir "${dir}/${agent_id}"
      printf '%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel"
      ;;
    global)
      printf '%s/%s.jsonl' "$dir" "$agent_id"
      ;;
    *)
      ensure_dir "${dir}/${agent_id}/${channel}"
      printf '%s/%s/%s/%s.jsonl' "$dir" "$agent_id" "$channel" "${sender:-_global}"
      ;;
  esac
}

session_key() {
  local agent_id="$1"
  local channel="${2:-default}"
  local sender="${3:-}"
  printf 'agent:%s:%s:%s' "$agent_id" "$channel" "$sender"
}

session_append() {
  local file="$1"
  local role="$2"
  local content="$3"

  require_command jq "session_append requires jq"
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc --arg r "$role" --arg c "$content" --arg t "$ts" \
    '{role: $r, content: $c, ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"
}

session_append_tool_call() {
  local file="$1"
  local tool_name="$2"
  local tool_input="$3"
  local tool_id="${4:-$(uuid_generate)}"

  require_command jq "session_append_tool_call requires jq"
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc \
    --arg tn "$tool_name" \
    --arg ti "$tool_input" \
    --arg tid "$tool_id" \
    --arg t "$ts" \
    '{role: "assistant", type: "tool_call", tool_name: $tn, tool_input: ($ti | fromjson? // $ti), tool_id: $tid, ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"
}

session_append_tool_result() {
  local file="$1"
  local tool_id="$2"
  local result="$3"
  local is_error="${4:-false}"

  require_command jq "session_append_tool_result requires jq"
  local ts
  ts="$(timestamp_ms)"
  local line
  line="$(jq -nc \
    --arg tid "$tool_id" \
    --arg r "$result" \
    --arg err "$is_error" \
    --arg t "$ts" \
    '{role: "tool", type: "tool_result", tool_id: $tid, content: $r, is_error: ($err == "true"), ts: ($t | tonumber)}')"
  printf '%s\n' "$line" >> "$file"
}

session_load() {
  local file="$1"
  local max_lines="${2:-0}"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_load requires jq"
  if (( max_lines > 0 )); then
    tail -n "$max_lines" "$file" | jq -s '.'
  else
    jq -s '.' < "$file"
  fi
}

session_load_as_messages() {
  local file="$1"
  local max_lines="${2:-0}"

  if [[ ! -f "$file" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_load_as_messages requires jq"
  local raw
  if (( max_lines > 0 )); then
    raw="$(tail -n "$max_lines" "$file" | jq -s '.')"
  else
    raw="$(jq -s '.' < "$file")"
  fi

  printf '%s' "$raw" | jq '[.[] | {role: .role, content: .content}]'
}

session_clear() {
  local file="$1"
  if [[ -f "$file" ]]; then
    : > "$file"
    log_debug "Session cleared: $file"
  fi
}

session_delete() {
  local file="$1"
  if [[ -f "$file" ]]; then
    rm -f "$file"
    log_debug "Session deleted: $file"
  fi
}

session_prune() {
  local file="$1"
  local keep="${2:-100}"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  local total
  total="$(wc -l < "$file" | tr -d ' ')"
  if (( total <= keep )); then
    return 0
  fi

  local tmp
  tmp="$(tmpfile "session_prune")"
  tail -n "$keep" "$file" > "$tmp"
  mv "$tmp" "$file"
  log_debug "Session pruned to $keep entries: $file"
}

session_list() {
  local base_dir
  base_dir="$(session_dir)"

  if [[ ! -d "$base_dir" ]]; then
    printf '[]'
    return 0
  fi

  require_command jq "session_list requires jq"
  local result="[]"
  local f
  while IFS= read -r -d '' f; do
    local relative="${f#${base_dir}/}"
    local count
    count="$(wc -l < "$f" | tr -d ' ')"
    result="$(printf '%s' "$result" | jq --arg p "$relative" --arg c "$count" \
      '. + [{"path": $p, "count": ($c | tonumber)}]')"
  done < <(find "$base_dir" -name '*.jsonl' -print0 2>/dev/null)

  printf '%s' "$result"
}

session_check_idle_reset() {
  local file="$1"
  local idle_minutes="${2:-}"

  if [[ -z "$idle_minutes" ]]; then
    idle_minutes="$(config_get '.session.idleResetMinutes' '30')"
  fi

  if [[ ! -f "$file" ]] || (( idle_minutes <= 0 )); then
    return 1
  fi

  local last_line
  last_line="$(tail -n 1 "$file")"
  if [[ -z "$last_line" ]]; then
    return 1
  fi

  require_command jq "session_check_idle_reset requires jq"
  local last_ts
  last_ts="$(printf '%s' "$last_line" | jq -r '.ts // 0' 2>/dev/null)"
  if [[ "$last_ts" == "0" || -z "$last_ts" ]]; then
    return 1
  fi

  local now_ms
  now_ms="$(timestamp_ms)"
  local diff_minutes=$(( (now_ms - last_ts) / 60000 ))

  if (( diff_minutes >= idle_minutes )); then
    session_clear "$file"
    log_info "Session idle-reset after ${diff_minutes}m: $file"
    return 0
  fi
  return 1
}

session_export() {
  local file="$1"
  local format="${2:-json}"

  if [[ ! -f "$file" ]]; then
    log_warn "Session file not found: $file"
    return 1
  fi

  case "$format" in
    json)
      session_load "$file"
      ;;
    text)
      require_command jq "session_export text requires jq"
      jq -r '"\(.role // "unknown"): \(.content // "")"' < "$file"
      ;;
    *)
      log_error "Unknown export format: $format (use json or text)"
      return 1
      ;;
  esac
}

session_count() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '0'
    return 0
  fi
  wc -l < "$file" | tr -d ' '
}

session_last_role() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf ''
    return 0
  fi
  require_command jq "session_last_role requires jq"
  local last_line
  last_line="$(tail -n 1 "$file")"
  if [[ -z "$last_line" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$last_line" | jq -r '.role // ""' 2>/dev/null
}

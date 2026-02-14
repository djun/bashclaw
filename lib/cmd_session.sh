#!/usr/bin/env bash
# Session management command for bashclaw

cmd_session() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    list) _cmd_session_list "$@" ;;
    show) _cmd_session_show "$@" ;;
    clear) _cmd_session_clear "$@" ;;
    delete) _cmd_session_delete "$@" ;;
    export) _cmd_session_export "$@" ;;
    -h|--help|help|"") _cmd_session_usage ;;
    *) log_error "Unknown session subcommand: $subcommand"; _cmd_session_usage; return 1 ;;
  esac
}

_cmd_session_list() {
  local agent_filter="" channel_filter="" sender_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent) agent_filter="$2"; shift 2 ;;
      -c|--channel) channel_filter="$2"; shift 2 ;;
      -s|--sender) sender_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  require_command jq "session list requires jq"

  local sessions
  sessions="$(session_list)"

  # Apply filters
  if [[ -n "$agent_filter" ]]; then
    sessions="$(printf '%s' "$sessions" | jq --arg a "$agent_filter" \
      '[.[] | select(.path | startswith($a + "/"))]')"
  fi
  if [[ -n "$channel_filter" ]]; then
    sessions="$(printf '%s' "$sessions" | jq --arg c "$channel_filter" \
      '[.[] | select(.path | contains("/" + $c + "/") or contains("/" + $c + "."))]')"
  fi

  local count
  count="$(printf '%s' "$sessions" | jq 'length')"

  if (( count == 0 )); then
    printf 'No sessions found.\n'
    return 0
  fi

  printf 'Sessions (%s):\n' "$count"
  printf '%s' "$sessions" | jq -r '.[] | "  \(.path) (\(.count) messages)"'
}

_cmd_session_show() {
  local agent_id="" channel="" sender="" lines=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent) agent_id="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -s|--sender) sender="$2"; shift 2 ;;
      -n|--lines) lines="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  agent_id="${agent_id:-main}"
  channel="${channel:-default}"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  if [[ ! -f "$sess_file" ]]; then
    printf 'Session not found: %s\n' "$sess_file"
    return 1
  fi

  require_command jq "session show requires jq"

  local total
  total="$(session_count "$sess_file")"
  printf 'Session: %s (%s messages)\n\n' "$sess_file" "$total"

  session_load "$sess_file" "$lines" | jq -r '.[] |
    if .type == "tool_call" then
      "[tool_call] \(.tool_name) \(.tool_input | tostring | .[0:80])"
    elif .type == "tool_result" then
      "[tool_result] \(.content | .[0:80])"
    else
      "\(.role): \(.content | .[0:200])"
    end
  '
}

_cmd_session_clear() {
  local agent_id="" channel="" sender=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent) agent_id="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -s|--sender) sender="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  agent_id="${agent_id:-main}"
  channel="${channel:-default}"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  if [[ ! -f "$sess_file" ]]; then
    printf 'Session not found: %s\n' "$sess_file"
    return 1
  fi

  session_clear "$sess_file"
  printf 'Session cleared: %s\n' "$sess_file"
}

_cmd_session_delete() {
  local agent_id="" channel="" sender=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent) agent_id="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -s|--sender) sender="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  agent_id="${agent_id:-main}"
  channel="${channel:-default}"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  if [[ ! -f "$sess_file" ]]; then
    printf 'Session not found: %s\n' "$sess_file"
    return 1
  fi

  session_delete "$sess_file"
  printf 'Session deleted: %s\n' "$sess_file"
}

_cmd_session_export() {
  local agent_id="" channel="" sender="" format="json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent) agent_id="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -s|--sender) sender="$2"; shift 2 ;;
      -f|--format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  agent_id="${agent_id:-main}"
  channel="${channel:-default}"

  local sess_file
  sess_file="$(session_file "$agent_id" "$channel" "$sender")"

  if [[ ! -f "$sess_file" ]]; then
    printf 'Session not found: %s\n' "$sess_file"
    return 1
  fi

  session_export "$sess_file" "$format"
}

_cmd_session_usage() {
  cat <<'EOF'
Usage: bashclaw session <subcommand> [options]

Subcommands:
  list              List all sessions
  show              Show session contents
  clear             Clear session (keep file)
  delete            Delete session file
  export            Export session data

Options:
  -a, --agent ID      Agent ID filter (default: main)
  -c, --channel NAME  Channel filter (default: default)
  -s, --sender ID     Sender filter
  -f, --format FMT    Export format: json or text (default: json)
  -n, --lines N       Number of lines to show (default: 20)

Examples:
  bashclaw session list
  bashclaw session list -a main -c telegram
  bashclaw session show -a main -c telegram -s 123456
  bashclaw session clear -a main
  bashclaw session export -a main -f text
EOF
}

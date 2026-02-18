#!/usr/bin/env bash
# Message send command for bashclaw

cmd_message() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    send) _cmd_message_send "$@" ;;
    -h|--help|help|"") _cmd_message_usage ;;
    *) log_error "Unknown message subcommand: $subcommand"; _cmd_message_usage; return 1 ;;
  esac
}

_cmd_message_send() {
  local channel="" target="" text="" agent_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--channel) channel="$2"; shift 2 ;;
      -t|--to) target="$2"; shift 2 ;;
      -m|--message) text="$2"; shift 2 ;;
      -a|--agent) agent_id="$2"; shift 2 ;;
      -h|--help) _cmd_message_usage; return 0 ;;
      *) text="$*"; break ;;
    esac
  done

  if [[ -z "$text" ]]; then
    log_error "Message text is required"
    _cmd_message_usage
    return 1
  fi

  if [[ -z "$channel" ]]; then
    log_error "Channel is required (-c telegram|discord|slack)"
    return 1
  fi

  if [[ -z "$target" ]]; then
    log_error "Target is required (-t chat_id/channel_id)"
    return 1
  fi

  # If an agent is specified, run the agent first and send its response
  if [[ -n "$agent_id" ]]; then
    local response
    response="$(engine_run "$agent_id" "$text" "$channel" "cli")"
    if [[ -n "$response" ]]; then
      text="$response"
    else
      log_warn "Agent returned empty response, sending original message"
    fi
  fi

  # Load channel script if needed
  local channel_dir
  channel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels"
  local ch_script="${channel_dir}/${channel}.sh"
  if [[ -f "$ch_script" ]]; then
    source "$ch_script"
  fi

  # Try channel-specific send function
  local send_func="channel_${channel}_send"
  if declare -f "$send_func" &>/dev/null; then
    local result
    result="$("$send_func" "$target" "$text")"
    if [[ -n "$result" ]]; then
      printf 'Sent via %s (id: %s)\n' "$channel" "$result"
    else
      log_error "Failed to send message via $channel"
      return 1
    fi
  else
    log_error "No send handler for channel: $channel"
    return 1
  fi
}

_cmd_message_usage() {
  cat <<'EOF'
Usage: bashclaw message send [options]

Options:
  -c, --channel NAME    Channel to send via (telegram, discord, slack)
  -t, --to ID           Target chat/channel/user ID
  -m, --message TEXT     Message text to send
  -a, --agent ID        Run agent first and send response
  -h, --help            Show this help

Example:
  bashclaw message send -c telegram -t 123456789 -m "Hello!"
  bashclaw message send -c discord -t 987654321 -m "Hi there" -a main
EOF
}

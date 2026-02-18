#!/usr/bin/env bash
# Logging module for BashClaw
# Compatible with bash 3.2+ (no associative arrays)

LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
LOG_COLOR="${LOG_COLOR:-auto}"

_log_level_num() {
  case "$1" in
    debug)  echo 0 ;;
    info)   echo 1 ;;
    warn)   echo 2 ;;
    error)  echo 3 ;;
    fatal)  echo 4 ;;
    silent) echo 5 ;;
    *)      echo 1 ;;
  esac
}

_log_color_code() {
  case "$1" in
    debug) printf '\033[36m' ;;
    info)  printf '\033[32m' ;;
    warn)  printf '\033[33m' ;;
    error) printf '\033[31m' ;;
    fatal) printf '\033[35m' ;;
  esac
}

_LOG_RESET='\033[0m'

_log_should_color() {
  case "$LOG_COLOR" in
    always) return 0 ;;
    never) return 1 ;;
    *)
      [[ -t 2 ]] && return 0
      return 1
      ;;
  esac
}

_log_ts() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

_log() {
  local level="$1"
  shift
  local msg="$*"

  local current_num
  current_num="$(_log_level_num "$LOG_LEVEL")"
  local msg_num
  msg_num="$(_log_level_num "$level")"
  if [ "$msg_num" -lt "$current_num" ]; then
    return 0
  fi

  local ts
  ts="$(_log_ts)"
  local upper
  upper="$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')"

  if _log_should_color; then
    local color
    color="$(_log_color_code "$level")"
    printf '%b[%s] %s: %s%b\n' "$color" "$ts" "$upper" "$msg" "$_LOG_RESET" >&2
  else
    printf '[%s] %s: %s\n' "$ts" "$upper" "$msg" >&2
  fi

  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] %s: %s\n' "$ts" "$upper" "$msg" >> "$LOG_FILE"
  fi
}

log_debug() { _log debug "$@"; }
log_info()  { _log info "$@"; }
log_warn()  { _log warn "$@"; }
log_error() { _log error "$@"; }

log_fatal() {
  _log fatal "$@"
  exit 1
}

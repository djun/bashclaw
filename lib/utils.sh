#!/usr/bin/env bash
# Utility functions for bashclaw

_TMPFILES=()

ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

ensure_state_dir() {
  local base="${BASHCLAW_STATE_DIR:?BASHCLAW_STATE_DIR not set}"
  local dirs=(
    "$base"
    "$base/logs"
    "$base/sessions"
    "$base/config"
    "$base/agents"
    "$base/cache"
  )
  for d in "${dirs[@]}"; do
    ensure_dir "$d"
  done
}

is_command_available() {
  command -v "$1" &>/dev/null
}

require_command() {
  local cmd="$1"
  local msg="${2:-Required command not found: $cmd}"
  if ! is_command_available "$cmd"; then
    log_fatal "$msg"
  fi
}

url_encode() {
  local input="$1"
  if is_command_available python3; then
    python3 -c "import urllib.parse; print(urllib.parse.quote('$input', safe=''))"
  elif is_command_available jq; then
    printf '%s' "$input" | jq -sRr '@uri'
  else
    log_error "url_encode requires python3 or jq"
    return 1
  fi
}

json_escape() {
  local input="$1"
  require_command jq "json_escape requires jq"
  printf '%s' "$input" | jq -Rs '.'
}

trim() {
  local input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  printf '%s' "$input"
}

timestamp_ms() {
  if is_command_available python3; then
    python3 -c "import time; print(int(time.time() * 1000))"
  elif is_command_available perl; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
  else
    printf '%s000' "$(date +%s)"
  fi
}

timestamp_s() {
  date +%s
}

uuid_generate() {
  if is_command_available uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif is_command_available python3; then
    python3 -c "import uuid; print(uuid.uuid4())"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    log_error "uuid_generate requires uuidgen or python3"
    return 1
  fi
}

tmpfile() {
  local prefix="${1:-bashclaw}"
  local f
  f="$(mktemp "/tmp/${prefix}.XXXXXX")"
  _TMPFILES+=("$f")
  printf '%s' "$f"
}

cleanup_tmpfiles() {
  local f
  for f in "${_TMPFILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
  _TMPFILES=()
}

file_size_bytes() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '0'
    return 1
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f%z "$file"
  else
    stat -c%s "$file"
  fi
}

hash_string() {
  local input="$1"
  printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1
}

retry_with_backoff() {
  local max_attempts="${1:?max_attempts required}"
  local base_delay="${2:-1}"
  shift 2
  local cmd=("$@")

  local attempt=0
  while (( attempt < max_attempts )); do
    if "${cmd[@]}"; then
      return 0
    fi
    attempt=$((attempt + 1))
    if (( attempt >= max_attempts )); then
      return 1
    fi
    local delay=$((base_delay * (1 << (attempt - 1))))
    local jitter=$((RANDOM % (delay + 1)))
    local total=$((delay + jitter))
    log_warn "Retry ${attempt}/${max_attempts} in ${total}s..."
    sleep "$total"
  done
  return 1
}

is_port_available() {
  local port="$1"
  if is_command_available lsof; then
    ! lsof -i :"$port" &>/dev/null
  elif is_command_available ss; then
    ! ss -tlnp | grep -q ":${port} "
  elif is_command_available netstat; then
    ! netstat -tlnp 2>/dev/null | grep -q ":${port} "
  else
    return 0
  fi
}

wait_for_port() {
  local port="$1"
  local timeout="${2:-30}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if ! is_port_available "$port"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

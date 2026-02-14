#!/usr/bin/env bash
# Config management command for bashclaw

cmd_config() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    show) _cmd_config_show ;;
    get) _cmd_config_get "$@" ;;
    set) _cmd_config_set "$@" ;;
    init) _cmd_config_init ;;
    validate) _cmd_config_validate ;;
    edit) _cmd_config_edit ;;
    path) _cmd_config_path ;;
    -h|--help|help|"") _cmd_config_usage ;;
    *) log_error "Unknown config subcommand: $subcommand"; _cmd_config_usage; return 1 ;;
  esac
}

_cmd_config_show() {
  local path
  path="$(config_path)"
  if [[ ! -f "$path" ]]; then
    log_warn "Config file not found: $path"
    printf '{}\n'
    return 1
  fi
  require_command jq "config show requires jq"
  jq '.' < "$path"
}

_cmd_config_get() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    log_error "Key is required"
    printf 'Usage: bashclaw config get KEY\n'
    return 1
  fi

  # Ensure key starts with .
  if [[ "$key" != .* ]]; then
    key=".$key"
  fi

  local value
  value="$(config_get "$key" "")"
  if [[ -z "$value" ]]; then
    # Try raw (for objects/arrays)
    value="$(config_get_raw "$key")"
    if [[ "$value" == "null" ]]; then
      log_warn "Key not found: $key"
      return 1
    fi
  fi
  printf '%s\n' "$value"
}

_cmd_config_set() {
  local key="${1:-}"
  local value="${2:-}"

  if [[ -z "$key" || -z "$value" ]]; then
    log_error "Key and value are required"
    printf 'Usage: bashclaw config set KEY VALUE\n'
    return 1
  fi

  # Ensure key starts with .
  if [[ "$key" != .* ]]; then
    key=".$key"
  fi

  # Auto-detect value type
  local jq_value
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    jq_value="$value"
  elif [[ "$value" == "true" || "$value" == "false" ]]; then
    jq_value="$value"
  elif [[ "$value" == "null" ]]; then
    jq_value="null"
  elif printf '%s' "$value" | jq empty 2>/dev/null; then
    # Valid JSON
    jq_value="$value"
  else
    # Treat as string
    jq_value="$(printf '%s' "$value" | jq -Rs '.')"
  fi

  config_backup
  config_set "$key" "$jq_value"
  log_info "Config set: $key = $jq_value"
  printf 'Set %s = %s\n' "$key" "$jq_value"
}

_cmd_config_init() {
  config_init_default
}

_cmd_config_validate() {
  if config_validate; then
    printf 'Config is valid.\n'
  else
    printf 'Config validation failed.\n'
    return 1
  fi
}

_cmd_config_edit() {
  local editor="${EDITOR:-${VISUAL:-vi}}"
  local path
  path="$(config_path)"

  if [[ ! -f "$path" ]]; then
    log_info "Config file does not exist, creating default..."
    config_init_default
  fi

  config_backup
  "$editor" "$path"

  # Validate after edit
  if config_validate; then
    config_reload
    printf 'Config updated and validated.\n'
  else
    printf 'Warning: Config may have validation issues.\n'
  fi
}

_cmd_config_path() {
  config_path
  printf '\n'
}

_cmd_config_usage() {
  cat <<'EOF'
Usage: bashclaw config <subcommand> [args]

Subcommands:
  show              Display full config as JSON
  get KEY           Get a config value (dot-notation key)
  set KEY VALUE     Set a config value
  init              Create default config file
  validate          Validate config file
  edit              Open config in editor ($EDITOR)
  path              Print config file path

Examples:
  bashclaw config show
  bashclaw config get gateway.port
  bashclaw config set gateway.port 8080
  bashclaw config init
EOF
}

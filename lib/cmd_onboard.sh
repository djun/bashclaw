#!/usr/bin/env bash
# Onboarding setup wizard for bashclaw

cmd_onboard() {
  printf 'Bashclaw Setup Wizard\n'
  printf '=====================\n\n'

  local step=1

  # Step 1: Config initialization
  printf 'Step %d/4: Configuration\n' "$step"
  printf '------------------------\n'
  _onboard_config
  step=$((step + 1))
  printf '\n'

  # Step 2: API key setup
  printf 'Step %d/4: API Key\n' "$step"
  printf '-----------------\n'
  _onboard_api_key
  step=$((step + 1))
  printf '\n'

  # Step 3: Channel setup
  printf 'Step %d/4: Channel Setup\n' "$step"
  printf '----------------------\n'
  _onboard_channel
  step=$((step + 1))
  printf '\n'

  # Step 4: Gateway token
  printf 'Step %d/4: Gateway\n' "$step"
  printf '-----------------\n'
  _onboard_gateway
  printf '\n'

  printf 'Setup complete!\n'
  printf 'Run "bashclaw gateway" to start the server.\n'
  printf 'Run "bashclaw agent -i" for interactive mode.\n'
}

_onboard_config() {
  local cfg_path
  cfg_path="$(config_path)"

  if [[ -f "$cfg_path" ]]; then
    printf 'Config already exists: %s\n' "$cfg_path"
    printf 'Overwrite? [y/N]: '
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      printf 'Keeping existing config.\n'
      return 0
    fi
    config_backup
    rm -f "$cfg_path"
  fi

  config_init_default
}

_onboard_api_key() {
  local env_file="${BASHCLAW_STATE_DIR:?}/.env"

  # Check existing
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    printf 'ANTHROPIC_API_KEY is already set in environment.\n'
    return 0
  fi

  if [[ -f "$env_file" ]] && grep -q 'ANTHROPIC_API_KEY' "$env_file" 2>/dev/null; then
    printf 'API key already configured in %s\n' "$env_file"
    return 0
  fi

  printf 'Choose provider:\n'
  printf '  1) Anthropic (Claude)\n'
  printf '  2) OpenAI (GPT)\n'
  printf 'Choice [1]: '
  local choice
  read -r choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      printf 'Enter your Anthropic API key: '
      local api_key
      read -r -s api_key
      printf '\n'
      if [[ -z "$api_key" ]]; then
        log_warn "No API key provided, skipping"
        return 0
      fi
      printf 'ANTHROPIC_API_KEY=%s\n' "$api_key" >> "$env_file"
      chmod 600 "$env_file"
      printf 'API key saved to %s\n' "$env_file"
      ;;
    2)
      printf 'Enter your OpenAI API key: '
      local api_key
      read -r -s api_key
      printf '\n'
      if [[ -z "$api_key" ]]; then
        log_warn "No API key provided, skipping"
        return 0
      fi
      printf 'OPENAI_API_KEY=%s\n' "$api_key" >> "$env_file"
      chmod 600 "$env_file"
      config_set '.agents.defaults.model' '"gpt-4o"'
      printf 'API key saved to %s\n' "$env_file"
      ;;
    *)
      log_warn "Invalid choice, skipping API key setup"
      ;;
  esac
}

_onboard_channel() {
  printf 'Configure a messaging channel?\n'
  printf '  1) Telegram\n'
  printf '  2) Discord\n'
  printf '  3) Slack\n'
  printf '  4) Skip\n'
  printf 'Choice [4]: '
  local choice
  read -r choice
  choice="${choice:-4}"

  case "$choice" in
    1) onboard_channel "telegram" ;;
    2) onboard_channel "discord" ;;
    3) onboard_channel "slack" ;;
    4) printf 'Skipping channel setup.\n' ;;
    *) printf 'Skipping channel setup.\n' ;;
  esac
}

onboard_channel() {
  local channel="$1"

  case "$channel" in
    telegram)
      printf 'Enter Telegram Bot Token (from @BotFather): '
      local token
      read -r token
      if [[ -z "$token" ]]; then
        log_warn "No token provided"
        return 0
      fi
      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      printf 'BASHCLAW_TELEGRAM_TOKEN=%s\n' "$token" >> "$env_file"
      chmod 600 "$env_file"
      config_set '.channels.telegram' '{"enabled": true}'
      printf 'Telegram configured.\n'
      ;;
    discord)
      printf 'Enter Discord Bot Token: '
      local token
      read -r token
      if [[ -z "$token" ]]; then
        log_warn "No token provided"
        return 0
      fi
      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      printf 'BASHCLAW_DISCORD_TOKEN=%s\n' "$token" >> "$env_file"
      chmod 600 "$env_file"

      printf 'Enter Discord channel IDs to monitor (comma-separated): '
      local channel_ids
      read -r channel_ids
      if [[ -n "$channel_ids" ]]; then
        local json_array
        json_array="$(printf '%s' "$channel_ids" | tr ',' '\n' | jq -R '.' | jq -s '.')"
        config_set '.channels.discord' "$(jq -nc --argjson ids "$json_array" \
          '{enabled: true, monitorChannels: $ids}')"
      else
        config_set '.channels.discord' '{"enabled": true, "monitorChannels": []}'
      fi
      printf 'Discord configured.\n'
      ;;
    slack)
      printf 'Choose Slack mode:\n'
      printf '  1) Bot Token (recommended)\n'
      printf '  2) Webhook URL\n'
      printf 'Choice [1]: '
      local mode
      read -r mode
      mode="${mode:-1}"

      local env_file="${BASHCLAW_STATE_DIR:?}/.env"
      case "$mode" in
        1)
          printf 'Enter Slack Bot Token (xoxb-...): '
          local token
          read -r token
          if [[ -z "$token" ]]; then
            log_warn "No token provided"
            return 0
          fi
          printf 'BASHCLAW_SLACK_TOKEN=%s\n' "$token" >> "$env_file"
          chmod 600 "$env_file"

          printf 'Enter Slack channel IDs to monitor (comma-separated): '
          local channel_ids
          read -r channel_ids
          if [[ -n "$channel_ids" ]]; then
            local json_array
            json_array="$(printf '%s' "$channel_ids" | tr ',' '\n' | jq -R '.' | jq -s '.')"
            config_set '.channels.slack' "$(jq -nc --argjson ids "$json_array" \
              '{enabled: true, monitorChannels: $ids}')"
          else
            config_set '.channels.slack' '{"enabled": true, "monitorChannels": []}'
          fi
          ;;
        2)
          printf 'Enter Slack Webhook URL: '
          local url
          read -r url
          if [[ -z "$url" ]]; then
            log_warn "No URL provided"
            return 0
          fi
          printf 'BASHCLAW_SLACK_WEBHOOK_URL=%s\n' "$url" >> "$env_file"
          chmod 600 "$env_file"
          config_set '.channels.slack' '{"enabled": true}'
          ;;
      esac
      printf 'Slack configured.\n'
      ;;
    *)
      log_warn "Unknown channel: $channel"
      return 1
      ;;
  esac
}

_onboard_gateway() {
  printf 'Configure gateway authentication token? [y/N]: '
  local answer
  read -r answer

  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    printf 'Skipping gateway auth.\n'
    return 0
  fi

  local token
  token="$(uuid_generate)"
  config_set '.gateway.auth.token' "\"${token}\""
  printf 'Gateway auth token generated: %s\n' "$token"
  printf 'Use this token in the Authorization header for API requests.\n'

  # Install as daemon?
  printf '\nInstall as system service? [y/N]: '
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    onboard_install_daemon
  fi
}

onboard_install_daemon() {
  local os
  os="$(uname -s)"

  case "$os" in
    Darwin)
      _onboard_install_launchd
      ;;
    Linux)
      _onboard_install_systemd
      ;;
    *)
      printf 'Automatic daemon install not supported on %s.\n' "$os"
      printf 'Use "bashclaw gateway -d" to run as daemon.\n'
      ;;
  esac
}

_onboard_install_launchd() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_file="${plist_dir}/com.bashclaw.gateway.plist"
  local bashclaw_bin
  bashclaw_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bashclaw"
  local log_file="${BASHCLAW_STATE_DIR:?}/logs/gateway.log"

  ensure_dir "$plist_dir"
  ensure_dir "$(dirname "$log_file")"

  cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.bashclaw.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>bash</string>
        <string>${bashclaw_bin}</string>
        <string>gateway</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BASHCLAW_STATE_DIR</key>
        <string>${BASHCLAW_STATE_DIR}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_file}</string>
    <key>StandardErrorPath</key>
    <string>${log_file}</string>
</dict>
</plist>
EOF

  printf 'LaunchAgent plist created: %s\n' "$plist_file"
  printf 'Load with: launchctl load %s\n' "$plist_file"
  printf 'Unload with: launchctl unload %s\n' "$plist_file"

  printf 'Load now? [y/N]: '
  local answer
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    launchctl load "$plist_file" 2>/dev/null
    printf 'LaunchAgent loaded.\n'
  fi
}

_onboard_install_systemd() {
  local unit_dir="$HOME/.config/systemd/user"
  local unit_file="${unit_dir}/bashclaw-gateway.service"
  local bashclaw_bin
  bashclaw_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bashclaw"

  ensure_dir "$unit_dir"

  cat > "$unit_file" <<EOF
[Unit]
Description=Bashclaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=bash ${bashclaw_bin} gateway
Environment=BASHCLAW_STATE_DIR=${BASHCLAW_STATE_DIR}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

  printf 'Systemd unit created: %s\n' "$unit_file"
  printf 'Enable with: systemctl --user enable bashclaw-gateway\n'
  printf 'Start with: systemctl --user start bashclaw-gateway\n'

  printf 'Enable and start now? [y/N]: '
  local answer
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    systemctl --user daemon-reload
    systemctl --user enable bashclaw-gateway
    systemctl --user start bashclaw-gateway
    printf 'Systemd service enabled and started.\n'
  fi
}

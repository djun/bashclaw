# bashclaw

Pure Bash reimplementation of the [OpenClaw](https://github.com/openclaw/openclaw) AI assistant platform.

Same architecture, same module flow, same functionality -- zero Node.js, zero npm. Just Bash + jq + curl.

## Why

OpenClaw is a powerful personal AI assistant gateway written in TypeScript (~20k lines). It has:

- 52 npm dependencies including heavy ones (playwright, sharp, baileys)
- 40+ sequential initialization steps on startup
- 234 redundant `.strict()` Zod schema calls
- 6+ separate config validation passes
- Uncached avatar resolution doing synchronous file I/O per request
- Complex retry/fallback logic spanning 800+ lines

**bashclaw** strips all that away:

| Metric | OpenClaw (TS) | bashclaw |
|---|---|---|
| Lines of code | ~20,000+ | ~4,900 |
| Dependencies | 52 npm packages | jq, curl, socat (optional) |
| Startup time | 2-5s (Node cold start) | <100ms |
| Memory usage | 200-400MB | <10MB |
| Config validation | 6 passes + Zod | Single jq parse |
| Runtime | Node.js 22+ | Bash 3.2+ |

## Architecture

```sh
bashclaw/
  bashclaw              # Main entry point and CLI router
  lib/
    log.sh              # Logging subsystem (levels, color, file output)
    utils.sh            # General utilities (retry, port check, uuid, etc.)
    config.sh           # Configuration (jq-based, env var substitution)
    session.sh          # JSONL session persistence (per-sender/channel/global)
    agent.sh            # Agent runtime (Anthropic/OpenAI API, tool loop)
    tools.sh            # Built-in tools (web_fetch, shell, memory, cron, etc.)
    routing.sh          # Message routing and dispatch
    cmd_agent.sh        # CLI: agent command (interactive mode)
    cmd_gateway.sh      # CLI: gateway server (WebSocket/HTTP)
    cmd_config.sh       # CLI: config management
    cmd_session.sh      # CLI: session management
    cmd_message.sh      # CLI: send messages
    cmd_onboard.sh      # CLI: setup wizard
  channels/
    telegram.sh         # Telegram Bot API (long-poll)
    discord.sh          # Discord Bot API (HTTP poll)
    slack.sh            # Slack Bot API (conversations poll)
  gateway/
    http_handler.sh     # HTTP request handler for socat gateway
  tests/
    framework.sh        # Test framework (assert_eq, setup/teardown)
    test_*.sh           # 9 test suites, 165+ test cases
    run_all.sh          # Test runner
```

### Module Flow (same as OpenClaw)

```sh
Channel (Telegram/Discord/Slack/CLI)
  -> Routing (allowlist, mention-gating, agent resolution)
    -> Agent Runtime (model selection, API call, tool loop)
      -> Tools (web_fetch, shell, memory, cron, message)
    -> Session (JSONL append, prune, idle reset)
  -> Delivery (format reply, split long messages, send)
```

## Installation

```sh
git clone https://github.com/$(gh api user -q .login)/bashclaw.git
cd bashclaw
chmod +x bashclaw
```

### Requirements

- **bash** 3.2+ (macOS default works)
- **jq** - JSON processing
- **curl** - HTTP requests
- **socat** (optional) - gateway HTTP server
- **websocat** (optional) - gateway WebSocket server

```sh
# macOS
brew install jq curl socat

# Linux
apt install jq curl socat
```

## Quick Start

```sh
# Setup (interactive wizard)
./bashclaw onboard

# Or manual: set API key
export ANTHROPIC_API_KEY="your-key"

# Interactive chat
./bashclaw agent -i

# Single message
./bashclaw agent -m "What is the capital of France?"

# Check system health
./bashclaw doctor
```

## Configuration

Config file: `~/.bashclaw/bashclaw.json`

```json
{
  "agents": {
    "defaults": {
      "model": "claude-sonnet-4-20250514",
      "maxTokens": 8192,
      "systemPrompt": "You are a helpful personal AI assistant.",
      "temperature": 0.7,
      "tools": ["web_fetch", "web_search", "memory", "shell", "message", "cron"]
    },
    "main": {}
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "$TELEGRAM_BOT_TOKEN"
    }
  },
  "gateway": {
    "port": 18789,
    "auth": { "token": "$BASHCLAW_GATEWAY_TOKEN" }
  },
  "session": {
    "scope": "per-sender",
    "maxHistory": 100,
    "idleResetMinutes": 0
  }
}
```

### Environment Variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic Claude API key |
| `ANTHROPIC_BASE_URL` | Custom API base URL (for proxies/compatible APIs) |
| `MODEL_ID` | Override default model name |
| `OPENAI_API_KEY` | OpenAI API key |
| `BRAVE_SEARCH_API_KEY` | Brave Search API |
| `PERPLEXITY_API_KEY` | Perplexity API |
| `BASHCLAW_STATE_DIR` | State directory (default: ~/.bashclaw) |
| `BASHCLAW_CONFIG` | Config file path override |

### Custom API Endpoints

bashclaw supports any Anthropic-compatible API via `ANTHROPIC_BASE_URL`:

```sh
# Use with BigModel/GLM
export ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic
export MODEL_ID=glm-5

# Use with any compatible proxy
export ANTHROPIC_BASE_URL=https://your-proxy.example.com
```

## Commands

```sh
bashclaw agent [-m MSG] [-i] [-a AGENT]  # Chat with agent
bashclaw gateway [-p PORT] [-d] [--stop]  # Start/stop gateway
bashclaw message send -c CH -t TO -m MSG  # Send to channel
bashclaw config [show|get|set|init|validate|edit|path]
bashclaw session [list|show|clear|delete|export]
bashclaw onboard [--install-daemon]       # Setup wizard
bashclaw status                           # System status
bashclaw doctor                           # Diagnose issues
bashclaw version                          # Version info
```

## Channel Setup

### Telegram

```sh
./bashclaw config set '.channels.telegram.botToken' '"YOUR_BOT_TOKEN"'
./bashclaw config set '.channels.telegram.enabled' 'true'
./bashclaw gateway  # starts Telegram long-poll listener
```

### Discord

```sh
./bashclaw config set '.channels.discord.botToken' '"YOUR_BOT_TOKEN"'
./bashclaw config set '.channels.discord.enabled' 'true'
./bashclaw gateway
```

### Slack

```sh
./bashclaw config set '.channels.slack.botToken' '"xoxb-YOUR-TOKEN"'
./bashclaw config set '.channels.slack.enabled' 'true'
./bashclaw gateway
```

## Built-in Tools

| Tool | Description |
|---|---|
| `web_fetch` | HTTP requests with SSRF protection |
| `web_search` | Web search (Brave/Perplexity) |
| `shell` | Execute commands (with safety filters) |
| `memory` | Persistent key-value store |
| `message` | Send to channels |
| `cron` | Schedule recurring tasks |

## Testing

```sh
# Run all tests (165+ test cases)
bash tests/run_all.sh

# Run specific test suite
bash tests/test_config.sh
bash tests/test_session.sh
bash tests/test_tools.sh
bash tests/test_integration.sh  # requires API key in .env

# Run with verbose output
bash tests/run_all.sh --verbose
```

## Design Decisions

### Eliminated Redundancies from OpenClaw

1. **Config validation**: Single jq parse replaces 6 Zod validation passes with 234 `.strict()` calls
2. **Session management**: Direct JSONL file ops replace complex merging/caching layers
3. **Avatar resolution**: Eliminated entirely (no base64 encoding of images per request)
4. **Logging**: Simple level check + printf replaces 10,000+ line tslog subsystem with per-log color hashing
5. **Tool loading**: Direct function dispatch replaces lazy-loaded module registry
6. **Channel routing**: Simple case/function pattern replaces 8-adapter-type polymorphic interfaces
7. **Startup**: Instant (source scripts) replaces 40+ sequential async initialization steps

### Bash 3.2 Compatibility

All code works on macOS default bash (3.2). No associative arrays (`declare -A`) in core code. Channel polling uses file-based state tracking for compatibility.

## License

MIT

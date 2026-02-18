#!/usr/bin/env bash
# API calling functions: 3 endpoint implementations (anthropic, openai, google)
# All responses normalized to Anthropic message format as internal protocol.

# ---- Shared Retry Logic ----

_api_call_with_retry() {
  local max_retries="${1:-3}"
  local url="$2"
  local headers_file="$3"
  local body="$4"
  local response_file="$5"
  local provider_label="${6:-API}"

  local attempt=0
  local http_code
  while (( attempt < max_retries )); do
    attempt=$((attempt + 1))

    http_code="$(curl -sS --max-time 120 \
      -o "$response_file" -w '%{http_code}' \
      -H @"$headers_file" \
      -d "$body" \
      "$url" 2>/dev/null)" || http_code="000"

    case "$http_code" in
      200|201) printf '%s' "$http_code"; return 0 ;;
      429|500|502|503)
        if (( attempt < max_retries )); then
          local delay=$((2 * (1 << (attempt - 1)) + RANDOM % 3))
          log_warn "$provider_label HTTP $http_code, retry ${attempt}/${max_retries} in ${delay}s"
          sleep "$delay"
          continue
        fi
        ;;
    esac
    break
  done
  printf '%s' "$http_code"
  return 1
}

_api_write_headers() {
  local headers_file="$1"
  shift
  : > "$headers_file"
  local header
  for header in "$@"; do
    printf '%s\n' "$header" >> "$headers_file"
  done
}

_api_check_response() {
  local response="$1"
  local http_code="$2"
  local provider_label="$3"

  if [[ -z "$response" ]]; then
    log_error "$provider_label API request failed (HTTP $http_code)"
    printf '{"error": {"message": "API request failed", "status": "%s"}}' "$http_code"
    return 1
  fi

  local error_msg
  error_msg="$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)"
  if [[ -n "$error_msg" ]]; then
    log_error "$provider_label API error: $error_msg"
    printf '%s' "$response"
    return 1
  fi

  return 0
}

# ---- Unified API Dispatch ----

# Unified entry point: resolves provider/format and dispatches to the correct caller.
# All callers return Anthropic-format response: {stop_reason, content: [{type, text}], usage}
agent_call_api() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  local provider
  provider="$(agent_resolve_provider "$model")"
  provider="$(_provider_with_proxy_fallback "$provider")"

  local api_format
  api_format="$(_provider_api_format "$provider")"

  case "$api_format" in
    anthropic) agent_call_anthropic "$model" "$system_prompt" "$messages" "$max_tokens" "$temperature" "$tools_json" ;;
    openai)    agent_call_openai "$model" "$system_prompt" "$messages" "$max_tokens" "$temperature" "$tools_json" ;;
    google)    agent_call_google "$model" "$system_prompt" "$messages" "$max_tokens" "$temperature" "$tools_json" ;;
    *)         log_error "Unsupported API format: $api_format (provider=$provider)"; return 1 ;;
  esac
}

# ---- Anthropic API ----
# Handles: anthropic, xiaomi, and any provider with api="anthropic"

agent_call_anthropic() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_anthropic requires curl"
  require_command jq "agent_call_anthropic requires jq"

  local provider
  provider="$(agent_resolve_provider "$model")"
  provider="$(_provider_with_proxy_fallback "$provider")"

  local api_base
  api_base="$(_provider_api_url "$provider")"
  if [[ -z "$api_base" ]]; then
    api_base="https://api.anthropic.com/v1"
  fi

  local api_key
  api_key="$(agent_resolve_api_key "$provider")"

  local api_version
  api_version="$(_provider_api_version "$provider")"
  if [[ -z "$api_version" ]]; then
    api_version="2023-06-01"
  fi

  local api_url="${api_base}/messages"

  local body
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    body="$(jq -nc \
      --arg model "$model" \
      --arg system "$system_prompt" \
      --argjson messages "$messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$tools_json" \
      '{
        model: $model,
        system: $system,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp,
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg model "$model" \
      --arg system "$system_prompt" \
      --argjson messages "$messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      '{
        model: $model,
        system: $system,
        messages: $messages,
        max_tokens: $max_tokens,
        temperature: $temp
      }')"
  fi

  log_debug "Anthropic API call: model=$model provider=$provider url=$api_url"

  local response_file headers_file
  response_file="$(tmpfile "anthropic_resp")"
  headers_file="$(tmpfile "anthropic_headers")"

  _api_write_headers "$headers_file" \
    "x-api-key: ${api_key}" \
    "anthropic-version: ${api_version}" \
    "content-type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "Anthropic")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "Anthropic"; then
    return 1
  fi

  printf '%s' "$response"
}

# ---- OpenAI-compatible API ----
# Handles: openai, deepseek, qwen, zhipu, moonshot, minimax, groq, xai, mistral,
# nvidia, together, openrouter, ollama, vllm, qianfan, and any provider with api="openai"

agent_call_openai() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_openai requires curl"
  require_command jq "agent_call_openai requires jq"

  local provider
  provider="$(agent_resolve_provider "$model")"
  provider="$(_provider_with_proxy_fallback "$provider")"

  local api_base
  api_base="$(_provider_api_url "$provider")"
  if [[ -z "$api_base" ]]; then
    api_base="https://api.openai.com/v1"
  fi

  local api_key
  api_key="$(agent_resolve_api_key "$provider")"

  local api_url="${api_base}/chat/completions"

  local max_tokens_field="max_tokens"
  local compat_field
  compat_field="$(_model_get_compat_field "$model" "max_tokens_field")"
  if [[ -n "$compat_field" ]]; then
    max_tokens_field="$compat_field"
  fi

  local oai_messages
  oai_messages="$(printf '%s' "$messages" | jq --arg sys "$system_prompt" \
    '[{role: "system", content: $sys}] + .')"

  local oai_tools=""
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    oai_tools="$(printf '%s' "$tools_json" | jq '[.[] | {
      type: "function",
      function: {
        name: .name,
        description: .description,
        parameters: .input_schema
      }
    }]')"
  fi

  local body
  if [[ -n "$oai_tools" && "$oai_tools" != "[]" ]]; then
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$oai_tools" \
      --arg mtf "$max_tokens_field" \
      '{
        model: $model,
        messages: $messages,
        ($mtf): $max_tokens,
        temperature: $temp,
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg model "$model" \
      --argjson messages "$oai_messages" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --arg mtf "$max_tokens_field" \
      '{
        model: $model,
        messages: $messages,
        ($mtf): $max_tokens,
        temperature: $temp
      }')"
  fi

  log_debug "OpenAI API call: model=$model provider=$provider url=$api_url"

  local response_file headers_file
  response_file="$(tmpfile "openai_resp")"
  headers_file="$(tmpfile "openai_headers")"

  _api_write_headers "$headers_file" \
    "Authorization: Bearer ${api_key}" \
    "Content-Type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "OpenAI")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "OpenAI"; then
    return 1
  fi

  _openai_normalize_response "$response"
}

# Normalize OpenAI response to Anthropic internal format
_openai_normalize_response() {
  local response="$1"

  local stop_reason
  stop_reason="$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // "stop"')"

  local mapped_reason="end_turn"
  case "$stop_reason" in
    tool_calls) mapped_reason="tool_use" ;;
    length)     mapped_reason="max_tokens" ;;
    *)          mapped_reason="end_turn" ;;
  esac

  local has_tool_calls
  has_tool_calls="$(printf '%s' "$response" | jq '.choices[0].message.tool_calls | length > 0')"

  if [[ "$has_tool_calls" == "true" ]]; then
    printf '%s' "$response" | jq --arg sr "$mapped_reason" '{
      stop_reason: $sr,
      content: [
        (if .choices[0].message.content then {type: "text", text: .choices[0].message.content} else empty end),
        (.choices[0].message.tool_calls[]? | {
          type: "tool_use",
          id: .id,
          name: .function.name,
          input: (.function.arguments | fromjson? // {})
        })
      ],
      usage: .usage
    }'
  else
    local text
    text="$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""')"
    # Strip inline reasoning tags (e.g. MiniMax <think>...</think>, DeepSeek <think>...</think>)
    if [[ "$text" == *"<think>"* ]]; then
      text="$(printf '%s' "$text" | awk '
        BEGIN { skip=0 }
        /<think>/ { skip=1; next }
        /<\/think>/ { skip=0; next }
        !skip { print }
      ' | sed '/^[[:space:]]*$/d')"
      text="${text#"${text%%[![:space:]]*}"}"
    fi
    printf '%s' "$response" | jq --arg sr "$mapped_reason" --arg text "$text" '{
      stop_reason: $sr,
      content: [{type: "text", text: $text}],
      usage: .usage
    }'
  fi
}

# ---- Google Gemini API ----
# Handles: google, and any provider with api="google"

agent_call_google() {
  local model="$1"
  local system_prompt="$2"
  local messages="$3"
  local max_tokens="${4:-4096}"
  local temperature="${5:-$AGENT_DEFAULT_TEMPERATURE}"
  local tools_json="${6:-}"

  require_command curl "agent_call_google requires curl"
  require_command jq "agent_call_google requires jq"

  local provider
  provider="$(agent_resolve_provider "$model")"

  local api_base
  api_base="$(_provider_api_url "$provider")"
  if [[ -z "$api_base" ]]; then
    api_base="https://generativelanguage.googleapis.com/v1beta"
  fi

  local api_key
  api_key="$(agent_resolve_api_key "$provider")"

  local api_url="${api_base}/models/${model}:generateContent?key=${api_key}"

  local gemini_contents
  gemini_contents="$(printf '%s' "$messages" | jq '[
    .[] |
    if .role == "user" then
      {role: "user", parts: [{text: .content}]}
    elif .role == "assistant" then
      {role: "model", parts: [{text: .content}]}
    else
      empty
    end
  ]')"

  local gemini_tools=""
  if [[ -n "$tools_json" && "$tools_json" != "[]" ]]; then
    gemini_tools="$(printf '%s' "$tools_json" | jq '[{
      function_declarations: [.[] | {
        name: .name,
        description: .description,
        parameters: .input_schema
      }]
    }]')"
  fi

  local body
  if [[ -n "$gemini_tools" && "$gemini_tools" != "[]" ]]; then
    body="$(jq -nc \
      --arg sys "$system_prompt" \
      --argjson contents "$gemini_contents" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      --argjson tools "$gemini_tools" \
      '{
        system_instruction: {parts: [{text: $sys}]},
        contents: $contents,
        generationConfig: {maxOutputTokens: $max_tokens, temperature: $temp},
        tools: $tools
      }')"
  else
    body="$(jq -nc \
      --arg sys "$system_prompt" \
      --argjson contents "$gemini_contents" \
      --argjson max_tokens "$max_tokens" \
      --argjson temp "$temperature" \
      '{
        system_instruction: {parts: [{text: $sys}]},
        contents: $contents,
        generationConfig: {maxOutputTokens: $max_tokens, temperature: $temp}
      }')"
  fi

  log_debug "Google API call: model=$model provider=$provider url=$api_url"

  local response_file headers_file
  response_file="$(tmpfile "google_resp")"
  headers_file="$(tmpfile "google_headers")"

  _api_write_headers "$headers_file" \
    "Content-Type: application/json"

  local http_code
  http_code="$(_api_call_with_retry 3 "$api_url" "$headers_file" "$body" "$response_file" "Google")" || true
  local response
  response="$(cat "$response_file" 2>/dev/null)"

  rm -f "$response_file" "$headers_file"

  if ! _api_check_response "$response" "$http_code" "Google"; then
    return 1
  fi

  _google_normalize_response "$response"
}

# Normalize Google Gemini response to Anthropic internal format
_google_normalize_response() {
  local response="$1"

  local finish_reason
  finish_reason="$(printf '%s' "$response" | jq -r '.candidates[0].finishReason // "STOP"')"

  local mapped_reason="end_turn"
  case "$finish_reason" in
    STOP)           mapped_reason="end_turn" ;;
    MAX_TOKENS)     mapped_reason="max_tokens" ;;
    SAFETY)         mapped_reason="end_turn" ;;
    *)              mapped_reason="end_turn" ;;
  esac

  local has_function_calls
  has_function_calls="$(printf '%s' "$response" | jq '
    [.candidates[0].content.parts[]? | select(.functionCall)] | length > 0
  ')"

  if [[ "$has_function_calls" == "true" ]]; then
    printf '%s' "$response" | jq --arg sr "$mapped_reason" '{
      stop_reason: $sr,
      content: [
        (.candidates[0].content.parts[]? |
          if .text then {type: "text", text: .text}
          elif .functionCall then {
            type: "tool_use",
            id: ("gemini_" + .functionCall.name + "_" + (now | tostring)),
            name: .functionCall.name,
            input: (.functionCall.args // {})
          }
          else empty
          end
        )
      ],
      usage: {
        input_tokens: (.usageMetadata.promptTokenCount // 0),
        output_tokens: (.usageMetadata.candidatesTokenCount // 0)
      }
    }'
  else
    local text
    text="$(printf '%s' "$response" | jq -r '
      [.candidates[0].content.parts[]? | select(.text) | .text] | join("")
    ')"
    printf '%s' "$response" | jq --arg sr "$mapped_reason" --arg text "$text" '{
      stop_reason: $sr,
      content: [{type: "text", text: $text}],
      usage: {
        input_tokens: (.usageMetadata.promptTokenCount // 0),
        output_tokens: (.usageMetadata.candidatesTokenCount // 0)
      }
    }'
  fi
}

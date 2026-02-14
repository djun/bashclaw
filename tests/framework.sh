#!/usr/bin/env bash
# Minimal test framework for bashclaw

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0
CURRENT_TEST_FILE=""
CURRENT_TEST_NAME=""

_TEST_VERBOSE="${TEST_VERBOSE:-false}"
_TEST_TMPDIR=""
_TEST_FAILURES=()

# ---- Test Lifecycle ----

test_start() {
  CURRENT_TEST_NAME="$1"
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if [[ "$_TEST_VERBOSE" == "true" ]]; then
    printf '  RUN  %s\n' "$CURRENT_TEST_NAME"
  fi
}

test_end() {
  # Called implicitly by the next test_start or report_results
  :
}

_test_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  if [[ "$_TEST_VERBOSE" == "true" ]]; then
    printf '  PASS %s\n' "$CURRENT_TEST_NAME"
  fi
}

_test_fail() {
  local msg="${1:-assertion failed}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  _TEST_FAILURES+=("${CURRENT_TEST_FILE}::${CURRENT_TEST_NAME}: ${msg}")
  printf '  FAIL %s: %s\n' "$CURRENT_TEST_NAME" "$msg" >&2
}

# ---- Assertions ----

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="${3:-expected '$expected', got '$actual'}"
  if [[ "$actual" == "$expected" ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_ne() {
  local actual="$1"
  local expected="$2"
  local msg="${3:-expected value != '$expected', but they are equal}"
  if [[ "$actual" != "$expected" ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-expected to contain '$needle'}"
  if [[ "$haystack" == *"$needle"* ]]; then
    _test_pass
  else
    _test_fail "$msg (haystack: '${haystack:0:200}')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-expected NOT to contain '$needle'}"
  if [[ "$haystack" != *"$needle"* ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_file_exists() {
  local path="$1"
  local msg="${2:-expected file to exist: $path}"
  if [[ -f "$path" ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_file_not_exists() {
  local path="$1"
  local msg="${2:-expected file NOT to exist: $path}"
  if [[ ! -f "$path" ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_exit_code() {
  local expected="$1"
  shift
  local cmd=("$@")
  local actual
  "${cmd[@]}" >/dev/null 2>&1 || true
  actual=$?
  # Re-run to get exit code properly
  set +e
  "${cmd[@]}" >/dev/null 2>&1
  actual=$?
  set -e
  local msg="expected exit code $expected, got $actual (cmd: ${cmd[*]})"
  if [[ "$actual" -eq "$expected" ]]; then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_json_valid() {
  local json_string="$1"
  local msg="${2:-expected valid JSON}"
  if printf '%s' "$json_string" | jq empty 2>/dev/null; then
    _test_pass
  else
    _test_fail "$msg (got: '${json_string:0:200}')"
  fi
}

assert_match() {
  local actual="$1"
  local pattern="$2"
  local msg="${3:-expected to match pattern '$pattern'}"
  if [[ "$actual" =~ $pattern ]]; then
    _test_pass
  else
    _test_fail "$msg (got: '${actual:0:200}')"
  fi
}

assert_gt() {
  local actual="$1"
  local threshold="$2"
  local msg="${3:-expected $actual > $threshold}"
  if (( actual > threshold )); then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

assert_ge() {
  local actual="$1"
  local threshold="$2"
  local msg="${3:-expected $actual >= $threshold}"
  if (( actual >= threshold )); then
    _test_pass
  else
    _test_fail "$msg"
  fi
}

# ---- Test Environment Setup ----

setup_test_env() {
  _TEST_TMPDIR="$(mktemp -d "/tmp/bashclaw-test.XXXXXX")"
  export BASHCLAW_STATE_DIR="$_TEST_TMPDIR"
  export BASHCLAW_CONFIG="${_TEST_TMPDIR}/bashclaw.json"
  export LOG_LEVEL="silent"
  mkdir -p "${_TEST_TMPDIR}/sessions"
  mkdir -p "${_TEST_TMPDIR}/memory"
  mkdir -p "${_TEST_TMPDIR}/config"
  mkdir -p "${_TEST_TMPDIR}/cron"
  mkdir -p "${_TEST_TMPDIR}/logs"
  mkdir -p "${_TEST_TMPDIR}/agents"
  mkdir -p "${_TEST_TMPDIR}/cache"

  # Reset config cache
  _CONFIG_CACHE=""
  _CONFIG_PATH=""
}

teardown_test_env() {
  if [[ -n "$_TEST_TMPDIR" && -d "$_TEST_TMPDIR" ]]; then
    rm -rf "$_TEST_TMPDIR"
  fi
  _TEST_TMPDIR=""
}

# ---- Results ----

report_results() {
  printf '\n=== Test Results: %s ===\n' "$CURRENT_TEST_FILE"
  printf '  Total:  %d\n' "$TESTS_TOTAL"
  printf '  Passed: %d\n' "$TESTS_PASSED"
  printf '  Failed: %d\n' "$TESTS_FAILED"

  if (( TESTS_FAILED > 0 )); then
    printf '\nFailures:\n'
    local f
    for f in "${_TEST_FAILURES[@]}"; do
      printf '  - %s\n' "$f"
    done
    printf '\n'
    return 1
  fi

  printf '\n'
  return 0
}

# ---- File Header ----

begin_test_file() {
  local name="$1"
  CURRENT_TEST_FILE="$name"
  TESTS_PASSED=0
  TESTS_FAILED=0
  TESTS_TOTAL=0
  _TEST_FAILURES=()
  printf '\n--- %s ---\n' "$name"
}

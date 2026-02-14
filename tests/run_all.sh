#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
VERBOSE=false
SINGLE_FILE=""
SKIP_INTEGRATION=false

for arg in "$@"; do
  case "$arg" in
    --verbose|-v)
      VERBOSE=true
      ;;
    --skip-integration)
      SKIP_INTEGRATION=true
      ;;
    *)
      SINGLE_FILE="$arg"
      ;;
  esac
done

export TEST_VERBOSE="$VERBOSE"

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_TESTS=0
FAILED_FILES=()

printf '====================================\n'
printf '  bashclaw test suite\n'
printf '====================================\n'

run_test_file() {
  local file="$1"
  local name
  name="$(basename "$file")"

  if ! bash "$file"; then
    FAILED_FILES+=("$name")
  fi

  # Read the counters from the subshell output (not possible directly).
  # Instead, we rely on the exit code from report_results.
}

# Collect test files
if [[ -n "$SINGLE_FILE" ]]; then
  if [[ -f "$SINGLE_FILE" ]]; then
    TEST_FILES=("$SINGLE_FILE")
  elif [[ -f "${SCRIPT_DIR}/${SINGLE_FILE}" ]]; then
    TEST_FILES=("${SCRIPT_DIR}/${SINGLE_FILE}")
  elif [[ -f "${SCRIPT_DIR}/${SINGLE_FILE}.sh" ]]; then
    TEST_FILES=("${SCRIPT_DIR}/${SINGLE_FILE}.sh")
  else
    printf 'ERROR: Test file not found: %s\n' "$SINGLE_FILE"
    exit 1
  fi
else
  TEST_FILES=(
    "${SCRIPT_DIR}/test_utils.sh"
    "${SCRIPT_DIR}/test_config.sh"
    "${SCRIPT_DIR}/test_session.sh"
    "${SCRIPT_DIR}/test_tools.sh"
    "${SCRIPT_DIR}/test_routing.sh"
    "${SCRIPT_DIR}/test_agent.sh"
    "${SCRIPT_DIR}/test_channels.sh"
    "${SCRIPT_DIR}/test_cli.sh"
  )

  if [[ "$SKIP_INTEGRATION" != "true" ]]; then
    TEST_FILES+=("${SCRIPT_DIR}/test_integration.sh")
  fi
fi

FILE_RESULTS=()

for file in "${TEST_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    printf 'WARNING: Skipping missing file: %s\n' "$file"
    continue
  fi

  name="$(basename "$file")"

  # Run in subshell and capture output + exit code
  set +e
  output="$(bash "$file" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$output"

  # Parse passed/failed from output (macOS-compatible sed)
  file_passed="$(printf '%s\n' "$output" | sed -n 's/.*Passed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  file_failed="$(printf '%s\n' "$output" | sed -n 's/.*Failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  file_total="$(printf '%s\n' "$output" | sed -n 's/.*Total:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"

  file_passed="${file_passed:-0}"
  file_failed="${file_failed:-0}"
  file_total="${file_total:-0}"

  TOTAL_PASSED=$((TOTAL_PASSED + file_passed))
  TOTAL_FAILED=$((TOTAL_FAILED + file_failed))
  TOTAL_TESTS=$((TOTAL_TESTS + file_total))

  if (( rc != 0 )); then
    FAILED_FILES+=("$name")
    FILE_RESULTS+=("FAIL $name ($file_passed/$file_total passed)")
  else
    FILE_RESULTS+=("PASS $name ($file_passed/$file_total passed)")
  fi
done

# Final summary
printf '\n====================================\n'
printf '  FINAL SUMMARY\n'
printf '====================================\n\n'

for line in "${FILE_RESULTS[@]}"; do
  printf '  %s\n' "$line"
done

printf '\n'
printf '  Total tests:  %d\n' "$TOTAL_TESTS"
printf '  Passed:       %d\n' "$TOTAL_PASSED"
printf '  Failed:       %d\n' "$TOTAL_FAILED"

if (( ${#FAILED_FILES[@]} > 0 )); then
  printf '\n  Failed files:\n'
  for f in "${FAILED_FILES[@]}"; do
    printf '    - %s\n' "$f"
  done
fi

printf '\n'

if (( TOTAL_FAILED > 0 )); then
  printf 'RESULT: FAIL\n'
  exit 1
else
  printf 'RESULT: PASS\n'
  exit 0
fi

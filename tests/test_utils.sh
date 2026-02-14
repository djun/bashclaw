#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHCLAW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source framework
source "$SCRIPT_DIR/framework.sh"

# Source libs (set required env before sourcing)
export BASHCLAW_STATE_DIR="/tmp/bashclaw-test-bootstrap"
export LOG_LEVEL="silent"
mkdir -p "$BASHCLAW_STATE_DIR"
for _lib in "${BASHCLAW_ROOT}"/lib/*.sh; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

begin_test_file "test_utils"

# ---- trim ----

test_start "trim removes leading spaces"
setup_test_env
result="$(trim "   hello")"
assert_eq "$result" "hello"
teardown_test_env

test_start "trim removes trailing spaces"
setup_test_env
result="$(trim "hello   ")"
assert_eq "$result" "hello"
teardown_test_env

test_start "trim removes both leading and trailing spaces"
setup_test_env
result="$(trim "  hello world  ")"
assert_eq "$result" "hello world"
teardown_test_env

test_start "trim handles tabs and mixed whitespace"
setup_test_env
result="$(trim "$(printf '\t  hello\t  ')")"
assert_eq "$result" "hello"
teardown_test_env

test_start "trim handles empty string"
setup_test_env
result="$(trim "")"
assert_eq "$result" ""
teardown_test_env

# ---- timestamp_s ----

test_start "timestamp_s returns a number"
setup_test_env
ts="$(timestamp_s)"
assert_match "$ts" '^[0-9]+$'
teardown_test_env

test_start "timestamp_s returns a reasonable epoch value"
setup_test_env
ts="$(timestamp_s)"
assert_gt "$ts" 1700000000
teardown_test_env

# ---- uuid_generate ----

test_start "uuid_generate produces a value"
setup_test_env
uid="$(uuid_generate)"
assert_ne "$uid" ""
teardown_test_env

test_start "uuid_generate produces unique values"
setup_test_env
uid1="$(uuid_generate)"
uid2="$(uuid_generate)"
assert_ne "$uid1" "$uid2"
teardown_test_env

test_start "uuid_generate format looks like a UUID"
setup_test_env
uid="$(uuid_generate)"
assert_match "$uid" '^[0-9a-f-]+$'
teardown_test_env

# ---- json_escape ----

test_start "json_escape handles plain text"
setup_test_env
result="$(json_escape "hello")"
assert_eq "$result" '"hello"'
teardown_test_env

test_start "json_escape handles double quotes"
setup_test_env
result="$(json_escape 'say "hello"')"
assert_contains "$result" '\"hello\"'
teardown_test_env

test_start "json_escape handles backslashes"
setup_test_env
result="$(json_escape 'path\to\file')"
assert_contains "$result" '\\'
teardown_test_env

test_start "json_escape handles newlines"
setup_test_env
result="$(json_escape "$(printf 'line1\nline2')")"
assert_contains "$result" '\n'
teardown_test_env

# ---- hash_string ----

test_start "hash_string produces consistent output"
setup_test_env
h1="$(hash_string "test")"
h2="$(hash_string "test")"
assert_eq "$h1" "$h2"
teardown_test_env

test_start "hash_string produces different output for different input"
setup_test_env
h1="$(hash_string "test1")"
h2="$(hash_string "test2")"
assert_ne "$h1" "$h2"
teardown_test_env

test_start "hash_string produces hex string"
setup_test_env
h="$(hash_string "test")"
assert_match "$h" '^[0-9a-f]+$'
teardown_test_env

# ---- ensure_dir ----

test_start "ensure_dir creates nested directories"
setup_test_env
target="${BASHCLAW_STATE_DIR}/a/b/c/d"
ensure_dir "$target"
assert_eq "$([ -d "$target" ] && echo "yes" || echo "no")" "yes"
teardown_test_env

test_start "ensure_dir is idempotent"
setup_test_env
target="${BASHCLAW_STATE_DIR}/existing"
mkdir -p "$target"
ensure_dir "$target"
assert_eq "$([ -d "$target" ] && echo "yes" || echo "no")" "yes"
teardown_test_env

# ---- file_size_bytes ----

test_start "file_size_bytes on known file"
setup_test_env
testfile="${BASHCLAW_STATE_DIR}/size_test.txt"
printf '12345' > "$testfile"
size="$(file_size_bytes "$testfile")"
assert_eq "$size" "5"
teardown_test_env

test_start "file_size_bytes on nonexistent file returns 0"
setup_test_env
size="$(file_size_bytes "/nonexistent/file" 2>/dev/null || true)"
assert_eq "$size" "0"
teardown_test_env

# ---- tmpfile ----

test_start "tmpfile creates a temp file"
setup_test_env
f="$(tmpfile "testprefix")"
assert_file_exists "$f"
rm -f "$f"
teardown_test_env

test_start "tmpfile creates file with correct prefix"
setup_test_env
f="$(tmpfile "mytest")"
assert_contains "$f" "mytest"
rm -f "$f"
teardown_test_env

# ---- is_command_available ----

test_start "is_command_available finds bash"
setup_test_env
if is_command_available bash; then
  _test_pass
else
  _test_fail "bash should be available"
fi
teardown_test_env

test_start "is_command_available returns false for nonexistent"
setup_test_env
if is_command_available "nonexistent_command_xyz_12345"; then
  _test_fail "nonexistent command should not be found"
else
  _test_pass
fi
teardown_test_env

report_results

#!/usr/bin/env bash
# ===========================================================================
# Integration tests for ee.sh
# ===========================================================================
#
# Strategy
# --------
# * Non-destructive by construction: every case runs in a subshell with a
#   private temporary store and a fake HOME. The suite never reads or writes
#   ~/.cloud-env, ~/.bashrc, or the caller's exported credentials. A path
#   guard in ce() refuses to source ee.sh if the store is outside TEST_TMP.
# * Password handling is simulated through danger mode: exporting
#   CLOUD_ENV_MASTER_PASSWORD (+ CLOUD_ENV_DANGER=1) is exactly the state that
#   `ee danger on` leaves behind after reading the password from the
#   hidden stdin prompt. This makes every openssl call non-interactive.
#   Danger mode itself is additionally tested for real by piping the password
#   into `ee danger on` via stdin.
# * The script is exercised the same way users run it: sourced
#   (`. ee.sh ...`) for commands that mutate the shell environment,
#   and executed (`bash ee.sh ...`) for standalone store operations.
#
# Run: ./test.sh   (exit code 0 = all tests passed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_ENV_SH="$SCRIPT_DIR/ee.sh"
MASTER_PASS='integration-test-master-pass'

# Drop anything inherited from the developer's shell so a forgotten
# init_store_env cannot operate on a real store or cached password.
unset CLOUD_ENV_STORE_PATH CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER
unset CLOUD_ENV_ACTIVE_VARS CLOUD_ENV_ACTIVE_TYPES CLOUD_PS1_KEY
unset CLOUD_KEY_NAME CLOUD_ENV_TYPE
# Sentinel path: missing init_store_env fails loudly instead of touching
# ~/.cloud-env/credentials.json.enc.
export CLOUD_ENV_STORE_PATH="/no-such-dir/ee-tests-must-call-init_store_env/store.enc"

# Snapshot the developer's real files so the suite can prove it never
# touched them. Taken before HOME is redirected inside test subshells.
DEVELOPER_HOME="$HOME"
file_fingerprint() {
  if [[ -e "$1" ]]; then
    cksum "$1"
  else
    echo "ABSENT $1"
  fi
}
BEFORE_BASHRC=$(file_fingerprint "$DEVELOPER_HOME/.bashrc")
BEFORE_STORE=$(file_fingerprint "$DEVELOPER_HOME/.cloud-env/credentials.json.enc")
BEFORE_STORE_DIR=0
[[ -d "$DEVELOPER_HOME/.cloud-env" ]] && BEFORE_STORE_DIR=1

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=""

# ---------------------------------------------------------------------------
# Test-harness helpers
# ---------------------------------------------------------------------------

# Run one test function in a subshell (via command substitution); report
# pass/fail and show the captured output on failure.
run_test() {
  local name="$1"
  shift

  TESTS_RUN=$((TESTS_RUN + 1))
  local output rc
  output=$("$@" 2>&1)
  rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "  ok   - $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "  FAIL - $name"
    printf '%s\n' "$output" | sed 's/^/         | /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
  fi
}

section() {
  echo
  echo "== $1 =="
}

# --- assertions (each aborts the current test subshell on failure) ----------

fail() { echo "assert failed: $*"; exit 1; }

assert_eq() {           # assert_eq <expected> <actual> <message>
  [[ "$2" == "$1" ]] || fail "$3 (expected '$1', got '$2')"
}

assert_contains() {     # assert_contains <haystack> <needle> <message>
  case "$1" in *"$2"*) ;; *) fail "$3 (needle '$2' not found in: $1)" ;; esac
}

assert_not_contains() { # assert_not_contains <haystack> <needle> <message>
  case "$1" in *"$2"*) fail "$3 (unexpected needle '$2' found in: $1)" ;; esac
}

assert_ok() {           # assert last RC was 0
  [[ "$RC" -eq 0 ]] || fail "$1 (rc=$RC, output: $OUT)"
}

assert_fails() {        # assert last RC was non-zero
  [[ "$RC" -ne 0 ]] || fail "$1 (expected failure but rc=0, output: $OUT)"
}

assert_unset() {        # assert_unset <var-name> <message>
  [[ -z "${!1:-}" ]] || fail "$2 (variable $1 still set to '${!1}')"
}

# --- environment setup -------------------------------------------------------

# Fresh temp store + fake HOME + master password already cached in the
# environment (the danger-mode simulation described in the header).
# HOME is pointed at TEST_TMP so install cannot touch the real ~/.bashrc
# and a forgotten CLOUD_ENV_STORE_PATH override still cannot write to
# the developer's ~/.cloud-env.
init_store_env() {
  TEST_TMP=$(mktemp -d) || exit 1
  trap 'rm -rf "$TEST_TMP"' EXIT
  mkdir -p "$TEST_TMP/home"
  export HOME="$TEST_TMP/home"
  export CLOUD_ENV_STORE_PATH="$TEST_TMP/store.enc"
  export CLOUD_ENV_MASTER_PASSWORD="$MASTER_PASS"
  export CLOUD_ENV_DANGER=1
  # Defensive: make sure no state leaks in from the invoking shell.
  unset CLOUD_ENV_ACTIVE_VARS CLOUD_ENV_ACTIVE_TYPES CLOUD_PS1_KEY CLOUD_KEY_NAME CLOUD_ENV_TYPE
}

# Fresh temp store but *no* cached password — used by the danger-mode tests
# that must start from a clean slate.
init_plain_env() {
  init_store_env
  unset CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER
}

# Source ee.sh with the given arguments, capturing combined output in
# $OUT and the exit code in $RC while KEEPING environment side effects in the
# current (sub)shell — exactly what the `ee` alias does.
#
# Refuses to run unless the store path and HOME are inside TEST_TMP, so a
# buggy test cannot encrypt over the real store or append to ~/.bashrc.
ce() {
  [[ -n "${TEST_TMP:-}" ]] || fail "ce() called without init_store_env"
  case "${CLOUD_ENV_STORE_PATH:-}" in
    "$TEST_TMP"/*) ;;
    *) fail "refusing to run against store outside TEST_TMP: ${CLOUD_ENV_STORE_PATH:-unset}" ;;
  esac
  case "${HOME:-}" in
    "$TEST_TMP"/*) ;;
    *) fail "refusing to run with HOME outside TEST_TMP: ${HOME:-unset}" ;;
  esac
  . "$CLOUD_ENV_SH" "$@" >"$TEST_TMP/ce.out" 2>&1
  RC=$?
  OUT=$(cat "$TEST_TMP/ce.out")
}

# Convenience record creators (fail the test immediately if creation fails).
add_aws()    { ce add "$1" --type=AWS --AWS_ACCESS_KEY_ID="${2:-AKIA-id}" --AWS_SECRET_ACCESS_KEY="${3:-aws-sec}" --AWS_DEFAULT_REGION="${4:-us-east-1}"; assert_ok "add AWS record $1"; }
add_gcp()    { ce add "$1" --type=GCP --CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${2:-/tmp/gcp.json}" --CLOUDSDK_CORE_PROJECT="${3:-proj-1}"; assert_ok "add GCP record $1"; }
add_azure()  { ce add "$1" --type=Azure --AZURE_CLIENT_ID=cid --AZURE_CLIENT_SECRET=csec --AZURE_TENANT_ID=tid --AZURE_SUBSCRIPTION_ID=sid; assert_ok "add Azure record $1"; }
add_custom() { ce add "$1" --type="${2:-qqq}" --set "CUSTOM_TOKEN=${3:-tok-1}"; assert_ok "add custom record $1"; }

# ===========================================================================
# Section A — CLI basics
# ===========================================================================

# Running with no arguments opens the tui (the default mode).
test_no_args_launches_tui() {
  init_store_env
  add_aws aws-main
  unset CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER
  ce <<<"$(printf '%s\nq' "$MASTER_PASS")"
  assert_ok "bare 'ee' launches tui"
  assert_contains "$OUT" "ee tui --" "tui list header"
  assert_contains "$OUT" "aws-main" "existing record shown in tui"
}

# `ee help` (and --help / -h) prints usage covering every command.
test_help_prints_usage() {
  init_store_env
  ce help
  assert_ok "help"
  for word in inject ls off save add danger test tui install --storage; do
    assert_contains "$OUT" "$word" "usage must mention '$word'"
  done
  ce --help
  assert_ok "--help"
  ce -h
  assert_ok "-h"
}

# A token that isn't a known subcommand is treated as a key name to inject
# (`ee myenv` behaves like `ee inject myenv`) rather than being rejected.
test_unknown_command_falls_back_to_inject() {
  init_store_env
  ce frobnicate
  assert_fails "injecting a nonexistent key must fail"
  assert_contains "$OUT" "Credential store not found" "falls back to inject, not 'unknown command'"

  add_aws aws-main
  ce aws-main
  assert_ok "bare key name injects like 'inject'"
  assert_eq "AKIA-id" "${AWS_ACCESS_KEY_ID:-}" "record injected via default-command fallback"
}

# ===========================================================================
# Section B — danger mode (the real password prompt path)
# ===========================================================================

# `danger on` reads the password from hidden stdin; afterwards the password
# is cached in the environment and the DANGER badge appears in the prompt.
test_danger_on_reads_password_from_stdin() {
  init_plain_env
  ce danger on <<<"$MASTER_PASS"
  assert_ok "danger on via stdin"
  assert_contains "$OUT" "Danger mode enabled" "confirmation message"
  assert_eq "$MASTER_PASS" "${CLOUD_ENV_MASTER_PASSWORD:-}" "password cached in env"
  assert_eq "1" "${CLOUD_ENV_DANGER:-}" "danger flag set"
  assert_contains "${CLOUD_PS1_KEY:-}" "DANGER" "DANGER badge in prompt"
}

# Passing the password as a CLI argument is forbidden (it would leak into
# shell history and the process list).
test_danger_on_rejects_cli_password() {
  init_plain_env
  ce danger on "$MASTER_PASS"
  assert_fails "danger on with CLI password must fail"
  assert_contains "$OUT" "hidden stdin prompt" "explains why"
  assert_unset CLOUD_ENV_MASTER_PASSWORD "password must not be cached"
}

# An empty password from stdin is rejected.
test_danger_on_rejects_empty_password() {
  init_plain_env
  ce danger on <<<""
  assert_fails "empty password must fail"
  assert_contains "$OUT" "Master password is required" "error message"
  assert_unset CLOUD_ENV_DANGER "danger flag must not be set"
}

# `danger off` clears the cached password and removes the DANGER badge while
# keeping active cloud contexts (their badges stay).
test_danger_off_clears_password_and_badge() {
  init_plain_env
  ce danger on <<<"$MASTER_PASS"
  add_aws aws-main
  ce inject aws-main
  assert_ok "set with danger password"
  ce danger off
  assert_ok "danger off"
  assert_unset CLOUD_ENV_MASTER_PASSWORD "password cleared"
  assert_unset CLOUD_ENV_DANGER "danger flag cleared"
  assert_not_contains "${CLOUD_PS1_KEY:-}" "DANGER" "DANGER badge removed"
  assert_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-main" "AWS badge kept"
}

# `danger` requires a mode argument, and only on|off are valid.
test_danger_argument_validation() {
  init_plain_env
  ce danger
  assert_fails "danger without mode must fail"
  ce danger maybe
  assert_fails "danger with unknown mode must fail"
  assert_contains "$OUT" "danger on|off" "usage hint shown"
}

# danger is an environment command, not a store command — --storage is invalid.
test_danger_rejects_storage_option() {
  init_plain_env
  ce danger on --storage "$TEST_TMP/other.enc" <<<"$MASTER_PASS"
  assert_fails "danger with --storage must fail"
  assert_contains "$OUT" "--storage is not supported" "clear error"
}

# ===========================================================================
# Section C — add (record creation and validation)
# ===========================================================================

# A full AWS record can be added and shows up in `ls` with its type.
test_add_aws_and_ls() {
  init_store_env
  add_aws proj-aws
  ce ls
  assert_ok "ls"
  assert_contains "$OUT" "proj-aws	AWS" "record listed with AWS type"
}

# AWS records demand both the access key and the secret.
test_add_aws_requires_key_and_secret() {
  init_store_env
  ce add half-aws --type=AWS --AWS_ACCESS_KEY_ID=only-key
  assert_fails "AWS without secret must fail"
  assert_contains "$OUT" "AWS record requires" "explains required fields"
}

# GCP records demand creds file + project.
test_add_gcp_validation() {
  init_store_env
  add_gcp proj-gcp
  ce ls
  assert_contains "$OUT" "proj-gcp	GCP" "GCP record listed"
  ce add half-gcp --type=GCP --CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=/tmp/x.json
  assert_fails "GCP without project must fail"
  assert_contains "$OUT" "GCP record requires" "explains required fields"
}

# Azure records demand all four identifiers.
test_add_azure_validation() {
  init_store_env
  add_azure proj-az
  ce ls
  assert_contains "$OUT" "proj-az	Azure" "Azure record listed"
  ce add half-az --type=Azure --AZURE_CLIENT_ID=c --AZURE_CLIENT_SECRET=s --AZURE_TENANT_ID=t
  assert_fails "Azure without subscription id must fail"
  assert_contains "$OUT" "Azure record requires" "explains required fields"
}

# README: unknown types like `qqq` are allowed; all fields come via --set.
test_add_custom_type_with_set() {
  init_store_env
  ce add proj-custom --type=qqq --set FOO=bar --set BAZ=quux
  assert_ok "custom type add"
  ce ls
  assert_contains "$OUT" "proj-custom	qqq" "custom record listed with its type"
}

# Explicit --VAR_NAME=value flags work the same as --set for custom types.
test_add_custom_type_via_explicit_flag() {
  init_store_env
  ce add via-flag --type=qqq --CUSTOM_TOKEN=tok-2
  assert_ok "custom type add via explicit flag"
  ce inject via-flag
  assert_eq "tok-2" "${CUSTOM_TOKEN:-}" "explicit flag field exported"
}

# Required fields of known types may also be satisfied via --set (README:
# --set is still supported for advanced/custom fields).
test_add_known_type_fields_via_set() {
  init_store_env
  ce add via-set --type=AWS --set AWS_ACCESS_KEY_ID=id --set AWS_SECRET_ACCESS_KEY=sec --set AWS_SESSION_TOKEN=tok
  assert_ok "AWS record built purely from --set"
  ce inject via-set
  assert_ok "set via-set"
  assert_eq "tok" "${AWS_SESSION_TOKEN:-}" "extra --set field exported"
}

# --set validates its argument shape (NAME=VALUE with a sane variable name).
test_add_set_argument_validation() {
  init_store_env
  ce add bad-set --type=qqq --set NOEQUALS
  assert_fails "--set without '=' must fail"
  ce add bad-set2 --type=qqq --set "BAD NAME=v"
  assert_fails "--set with invalid variable name must fail"
}

# Both option syntaxes (`--opt value` and `--opt=value`) are equivalent.
test_add_space_and_equals_forms() {
  init_store_env
  ce add eq-form --type=AWS --AWS_ACCESS_KEY_ID=same-id --AWS_SECRET_ACCESS_KEY=same-sec
  assert_ok "equals form"
  ce add sp-form --type AWS --AWS_ACCESS_KEY_ID same-id --AWS_SECRET_ACCESS_KEY same-sec
  assert_ok "space form"
  ce inject eq-form
  local eq_id="$AWS_ACCESS_KEY_ID"
  ce inject sp-form
  assert_eq "$eq_id" "$AWS_ACCESS_KEY_ID" "both forms store identical values"
}

# Type matching is case-insensitive and normalized to canonical spelling.
test_add_type_case_insensitive() {
  init_store_env
  ce add lower-aws --type=aws --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "lowercase type accepted"
  ce ls
  assert_contains "$OUT" "lower-aws	AWS" "type normalized to AWS"
}

# Adding the same key again overwrites the record (add == add/update).
test_add_overwrites_existing_record() {
  init_store_env
  add_aws dup-key first-id
  add_aws dup-key second-id
  ce inject dup-key
  assert_eq "second-id" "${AWS_ACCESS_KEY_ID:-}" "record was overwritten"
}

# Argument errors: missing key name, unknown option, missing option value.
test_add_argument_errors() {
  init_store_env
  ce add --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_fails "add without key name must fail"
  assert_contains "$OUT" "Key name is required" "clear error"
  ce add k1 --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s --123bad=1
  assert_fails "malformed option name must fail"
  ce add k2 --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY
  assert_fails "missing option value must fail"
  ce add k3 extra-positional --type=qqq --set A=1
  assert_fails "second positional argument must fail"
}

# ===========================================================================
# Section D — set / off / PS1 badges
# ===========================================================================

# `set` exports the record's variables plus bookkeeping vars and a badge.
test_inject_exports_aws_context() {
  init_store_env
  add_aws aws-main the-id the-secret eu-west-1
  ce inject aws-main
  assert_ok "set aws-main"
  assert_contains "$OUT" "Environment set for AWS key: aws-main" "confirmation"
  assert_eq "the-id" "${AWS_ACCESS_KEY_ID:-}" "access key exported"
  assert_eq "the-secret" "${AWS_SECRET_ACCESS_KEY:-}" "secret exported"
  assert_eq "eu-west-1" "${AWS_DEFAULT_REGION:-}" "region exported"
  assert_eq "aws-main" "${CLOUD_KEY_NAME:-}" "CLOUD_KEY_NAME set"
  assert_eq "AWS" "${CLOUD_ENV_TYPE:-}" "CLOUD_ENV_TYPE set"
  assert_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-main" "AWS badge present"
}

# AWS records without a region fall back to CLOUD_ENV_DEFAULT_REGION.
test_inject_applies_default_region() {
  init_store_env
  export CLOUD_ENV_DEFAULT_REGION="fallback-region-1"
  ce add no-region --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s   # note: no --AWS_DEFAULT_REGION
  assert_ok "add without region"
  ce inject no-region
  assert_eq "fallback-region-1" "${AWS_DEFAULT_REGION:-}" "default region applied"
}

# README: active contexts are tracked per cloud type — AWS, GCP, Azure and a
# custom type can all be active at the same time, each with its own badge.
test_inject_all_types_coexist() {
  init_store_env
  add_aws aws-main
  add_gcp gcp-main
  add_azure az-main
  add_custom custom-main qqq tok-x
  ce inject aws-main;    assert_ok "set aws"
  ce inject gcp-main;    assert_ok "set gcp"
  ce inject az-main;     assert_ok "set azure"
  ce inject custom-main; assert_ok "set custom"
  # every context's variables are simultaneously present
  assert_eq "AKIA-id" "${AWS_ACCESS_KEY_ID:-}" "AWS vars active"
  assert_eq "/tmp/gcp.json" "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" "GCP vars active"
  assert_eq "cid" "${AZURE_CLIENT_ID:-}" "Azure vars active"
  assert_eq "tok-x" "${CUSTOM_TOKEN:-}" "custom vars active"
  # one badge per active type
  assert_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-main" "AWS badge"
  assert_contains "${CLOUD_PS1_KEY:-}" "GCP:gcp-main" "GCP badge"
  assert_contains "${CLOUD_PS1_KEY:-}" "Azure:az-main" "Azure badge"
  assert_contains "${CLOUD_PS1_KEY:-}" "qqq:custom-main" "custom badge"
}

# README: setting another key of the same type replaces only that type's
# context — including variables the new record does not define.
test_inject_same_type_replaces_only_that_type() {
  init_store_env
  ce add aws-one --type=AWS --AWS_ACCESS_KEY_ID=id-1 --AWS_SECRET_ACCESS_KEY=sec-1 --set AWS_SESSION_TOKEN=token-1
  assert_ok "add aws-one"
  add_aws aws-two id-2 sec-2
  add_gcp gcp-main
  ce inject aws-one
  ce inject gcp-main
  assert_eq "token-1" "${AWS_SESSION_TOKEN:-}" "session token from aws-one active"
  ce inject aws-two
  assert_ok "set aws-two"
  assert_eq "id-2" "${AWS_ACCESS_KEY_ID:-}" "AWS context replaced"
  assert_unset AWS_SESSION_TOKEN "stale var from previous AWS record removed"
  assert_eq "/tmp/gcp.json" "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" "GCP untouched"
  assert_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-two" "badge shows new AWS key"
  assert_not_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-one" "old AWS badge replaced"
  assert_contains "${CLOUD_PS1_KEY:-}" "GCP:gcp-main" "GCP badge kept"
}

# Same-type replacement also works for custom types.
test_inject_custom_type_replacement() {
  init_store_env
  ce add c1 --type=qqq --set FIRST_ONLY=1 --set SHARED=a
  assert_ok "add c1"
  ce add c2 --type=qqq --set SHARED=b
  assert_ok "add c2"
  ce inject c1
  ce inject c2
  assert_eq "b" "${SHARED:-}" "shared field replaced"
  assert_unset FIRST_ONLY "field unique to previous record removed"
  assert_contains "${CLOUD_PS1_KEY:-}" "qqq:c2" "badge updated"
}

# Setting a nonexistent key fails WITHOUT destroying the current context.
test_inject_missing_key_keeps_context() {
  init_store_env
  add_aws aws-main
  ce inject aws-main
  ce inject does-not-exist
  assert_fails "missing key must fail"
  assert_contains "$OUT" "Key not found" "error message"
  assert_eq "AKIA-id" "${AWS_ACCESS_KEY_ID:-}" "existing context untouched"
  assert_contains "${CLOUD_PS1_KEY:-}" "AWS:aws-main" "badge untouched"
}

# `off` unsets every variable the tool exported, across all active types.
test_off_clears_everything() {
  init_store_env
  add_aws aws-main
  add_gcp gcp-main
  add_custom custom-main
  ce inject aws-main
  ce inject gcp-main
  ce inject custom-main
  ce off
  assert_ok "off"
  assert_unset AWS_ACCESS_KEY_ID "AWS vars cleared"
  assert_unset AWS_DEFAULT_REGION "AWS region cleared"
  assert_unset CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE "GCP vars cleared"
  assert_unset CUSTOM_TOKEN "custom vars cleared"
  assert_unset CLOUD_KEY_NAME "bookkeeping cleared"
  assert_unset CLOUD_ENV_TYPE "bookkeeping cleared"
  assert_unset CLOUD_ENV_ACTIVE_TYPES "type registry cleared"
  assert_unset CLOUD_PS1_KEY "prompt badge cleared"
}

# `off` after a real `danger on` also drops the cached master password
# (danger-mode variables are tracked like any other exported state).
test_off_also_clears_danger_mode() {
  init_plain_env
  ce danger on <<<"$MASTER_PASS"
  add_aws aws-main
  ce inject aws-main
  ce off
  assert_ok "off"
  assert_unset CLOUD_ENV_MASTER_PASSWORD "master password cleared by off"
  assert_unset CLOUD_ENV_DANGER "danger flag cleared by off"
}

# `off` accepts no extra arguments and no --storage.
test_off_argument_validation() {
  init_store_env
  ce off extra-arg
  assert_fails "off with extra args must fail"
  ce off --storage "$TEST_TMP/x.enc"
  assert_fails "off with --storage must fail"
  assert_contains "$OUT" "--storage is not supported" "clear error"
}

# ===========================================================================
# Section E — --storage placement (anywhere on the command line)
# ===========================================================================

# --storage may precede the command.
test_storage_before_command() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  ce --storage "$alt" add alt-key --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add with --storage before command"
  ce --storage "$alt" ls
  assert_ok "ls with --storage before command"
  assert_contains "$OUT" "alt-key	AWS" "record in alternate store"
}

# --storage may follow the command (the classic position).
test_storage_after_command() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  ce add --storage "$alt" alt-key --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add with --storage after command"
  ce ls --storage "$alt"
  assert_contains "$OUT" "alt-key	AWS" "record in alternate store"
}

# --storage may appear after positional args and between other options.
test_storage_between_options() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  ce add alt-key --type=AWS --AWS_ACCESS_KEY_ID=k --storage "$alt" --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add with --storage between options"
  ce inject alt-key --storage "$alt"
  assert_ok "set with --storage after key name"
  assert_eq "k" "${AWS_ACCESS_KEY_ID:-}" "record loaded from alternate store"
}

# The --storage=<path> form works too.
test_storage_equals_form() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  ce add alt-key --storage="$alt" --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add with --storage=path"
  ce --storage="$alt" ls
  assert_contains "$OUT" "alt-key	AWS" "record in alternate store"
}

# `ee --storage <path>` with no command opens the tui against that store.
test_storage_only_launches_tui() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  ce add alt-key --storage "$alt" --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add to alternate store"
  unset CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER
  ce --storage "$alt" <<<"$(printf '%s\nq' "$MASTER_PASS")"
  assert_ok "ee --storage path with no command launches tui"
  assert_contains "$OUT" "ee tui --" "tui list header"
  assert_contains "$OUT" "alt-key" "tui opened the alternate store"
}

# --storage argument validation: at most once, and never without a value.
test_storage_argument_validation() {
  init_store_env
  ce ls --storage "$TEST_TMP/a.enc" --storage "$TEST_TMP/b.enc"
  assert_fails "duplicate --storage must fail"
  assert_contains "$OUT" "only once" "clear error"
  ce ls --storage
  assert_fails "--storage without value must fail"
  assert_contains "$OUT" "Missing value for --storage" "clear error"
}

# The default store and an alternate store are fully independent.
test_storage_isolation() {
  init_store_env
  local alt="$TEST_TMP/alt.enc"
  add_aws default-key
  ce add alt-key --storage "$alt" --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s
  assert_ok "add to alternate store"
  ce ls
  assert_contains     "$OUT" "default-key" "default store has its record"
  assert_not_contains "$OUT" "alt-key" "default store lacks alternate record"
  ce ls --storage "$alt"
  assert_contains     "$OUT" "alt-key" "alternate store has its record"
  assert_not_contains "$OUT" "default-key" "alternate store lacks default record"
}

# ===========================================================================
# Section F — save & encryption behavior
# ===========================================================================

# `save` encrypts a plaintext JSON file into the store; the result round-trips
# through ls/set and the plaintext never appears in the encrypted file.
test_save_encrypts_plaintext() {
  init_store_env
  cat >"$TEST_TMP/records.json" <<'JSON'
{
  "imported": {
    "type": "AWS",
    "AWS_ACCESS_KEY_ID": "PLAINTEXT_MARKER_ID",
    "AWS_SECRET_ACCESS_KEY": "PLAINTEXT_MARKER_SECRET"
  }
}
JSON
  ce save "$TEST_TMP/records.json"
  assert_ok "save"
  assert_contains "$OUT" "saved and encrypted" "confirmation"
  [[ -f "$CLOUD_ENV_STORE_PATH" ]] || fail "store file was not created"
  if LC_ALL=C grep -aq "PLAINTEXT_MARKER" "$CLOUD_ENV_STORE_PATH"; then
    fail "store file still contains plaintext credentials"
  fi
  ce inject imported
  assert_ok "set from saved store"
  assert_eq "PLAINTEXT_MARKER_ID" "${AWS_ACCESS_KEY_ID:-}" "round-trip decrypt"
}

# `save` input validation: file must exist and be valid JSON.
test_save_input_validation() {
  init_store_env
  ce save "$TEST_TMP/nope.json"
  assert_fails "save of missing file must fail"
  assert_contains "$OUT" "does not exist" "clear error"
  echo "this is not json {" >"$TEST_TMP/garbage.json"
  ce save "$TEST_TMP/garbage.json"
  assert_fails "save of invalid JSON must fail"
  assert_contains "$OUT" "not valid JSON" "clear error"
}

# `save` over an existing store warns and asks for confirmation; declining
# leaves the store untouched.
test_save_warns_before_overwrite() {
  init_store_env
  add_aws original-key
  cat >"$TEST_TMP/new.json" <<'JSON'
{"replacement": {"type": "AWS", "AWS_ACCESS_KEY_ID": "REPLACED_ID", "AWS_SECRET_ACCESS_KEY": "REPLACED_SECRET"}}
JSON

  ce save "$TEST_TMP/new.json" <<<"n"
  assert_fails "declining the overwrite prompt must fail"
  assert_contains "$OUT" "Warning" "warns before overwriting"
  ce ls
  assert_contains "$OUT" "original-key" "original store left untouched after declining"

  ce save "$TEST_TMP/new.json" <<<"y"
  assert_ok "confirming the overwrite prompt proceeds"
  ce ls
  assert_contains "$OUT" "replacement" "store replaced after confirming"
  assert_not_contains "$OUT" "original-key" "old record gone after overwrite"
}

# `--force` skips the confirmation prompt entirely.
test_save_force_skips_prompt() {
  init_store_env
  add_aws original-key
  cat >"$TEST_TMP/new.json" <<'JSON'
{"replacement": {"type": "AWS", "AWS_ACCESS_KEY_ID": "REPLACED_ID", "AWS_SECRET_ACCESS_KEY": "REPLACED_SECRET"}}
JSON
  ce save "$TEST_TMP/new.json" --force
  assert_ok "save --force proceeds without a prompt"
  ce ls
  assert_contains "$OUT" "replacement" "store replaced by forced save"
}

# A wrong master password must fail decryption, not return garbage.
test_wrong_password_fails() {
  init_store_env
  add_aws aws-main
  export CLOUD_ENV_MASTER_PASSWORD="totally-wrong-password"
  ce ls
  assert_fails "ls with wrong password must fail"
  assert_contains "$OUT" "Error decrypting file" "clear error"
}

# Operating on a store that does not exist yields a clear error.
test_missing_store_fails() {
  init_store_env
  ce ls
  assert_fails "ls without a store must fail"
  assert_contains "$OUT" "Credential store not found" "clear error"
}

# Legacy records without a "type" field default to AWS (backwards compat).
test_record_without_type_defaults_to_aws() {
  init_store_env
  cat >"$TEST_TMP/legacy.json" <<'JSON'
{"legacy-key": {"AWS_ACCESS_KEY_ID": "legacy-id", "AWS_SECRET_ACCESS_KEY": "legacy-sec"}}
JSON
  ce save "$TEST_TMP/legacy.json"
  assert_ok "save legacy store"
  ce ls
  assert_contains "$OUT" "legacy-key	AWS" "untyped record listed as AWS"
  ce inject legacy-key
  assert_eq "AWS" "${CLOUD_ENV_TYPE:-}" "untyped record treated as AWS"
}

# Arg-count validation for the store commands.
test_store_command_argument_counts() {
  init_store_env
  ce inject
  assert_fails "inject without key must fail"
  ce inject a b
  assert_fails "inject with two keys must fail"
  ce ls unexpected
  assert_fails "ls with args must fail"
  ce save
  assert_fails "save without file must fail"
}

# ===========================================================================
# Section G — executed (non-sourced) mode & built-in self-test
# ===========================================================================

# Store-only operations also work when the script is executed rather than
# sourced (exit codes instead of return codes).
test_executed_mode_store_ops() {
  init_store_env
  bash "$CLOUD_ENV_SH" add exec-key --type=AWS --AWS_ACCESS_KEY_ID=k --AWS_SECRET_ACCESS_KEY=s >/dev/null 2>&1 \
    || fail "executed add failed"
  local out
  out=$(bash "$CLOUD_ENV_SH" ls 2>&1) || fail "executed ls failed"
  assert_contains "$out" "exec-key	AWS" "executed ls sees the record"
  bash "$CLOUD_ENV_SH" definitely-not-a-key >/dev/null 2>&1 \
    && fail "executed default-command fallback for a nonexistent key must exit non-zero"
  return 0
}

# The built-in self-test (`ee test`) must pass.
test_builtin_self_test() {
  init_store_env
  local out
  out=$(bash "$CLOUD_ENV_SH" test 2>&1) || fail "self-test failed: $out"
  assert_contains "$out" "Self-test passed" "self-test success message"
}

# Sourced `ee test` must not clobber the caller's injected credentials,
# danger-mode cache, or prompt badge (it runs in an isolated subshell).
test_selftest_does_not_clobber_caller_env() {
  init_store_env
  add_aws aws-main KEEP-THIS-ID
  ce inject aws-main
  assert_ok "inject before self-test"
  local keep_id="$AWS_ACCESS_KEY_ID"
  local keep_ps1="$CLOUD_PS1_KEY"
  local keep_pass="$CLOUD_ENV_MASTER_PASSWORD"
  local keep_store="$CLOUD_ENV_STORE_PATH"

  ce test
  assert_ok "sourced self-test"
  assert_contains "$OUT" "Self-test passed" "self-test success message"
  assert_eq "$keep_id" "${AWS_ACCESS_KEY_ID:-}" "self-test must not overwrite caller's AWS_ACCESS_KEY_ID"
  assert_eq "$keep_ps1" "${CLOUD_PS1_KEY:-}" "self-test must not overwrite caller's prompt badge"
  assert_eq "$keep_pass" "${CLOUD_ENV_MASTER_PASSWORD:-}" "self-test must not drop caller's cached password"
  assert_eq "$keep_store" "${CLOUD_ENV_STORE_PATH:-}" "self-test must not change CLOUD_ENV_STORE_PATH"
}

# `test` is environment-only — --storage is invalid (it uses a temp store).
test_selftest_rejects_storage() {
  init_store_env
  ce test --storage "$TEST_TMP/x.enc"
  assert_fails "test with --storage must fail"
  assert_contains "$OUT" "--storage is not supported" "clear error"
}

# ===========================================================================
# Section H — tui (scripted keystrokes)
# ===========================================================================
#
# tui is a raw-terminal interactive screen, which the sourced/captured `ce()`
# harness can't fully exercise (no real tty, so stty/redraw behavior isn't
# tested here — see the plan's manual verification step for that). What IS
# tested: the keystroke-driven control flow and its side effects. Keystrokes
# are fed as a single here-string (`<<<`), never a pipe — piping into a
# sourced command runs it in a subshell, silently discarding every exported
# side effect, which is exactly what these tests need to observe.

# From a missing store: tui prompts for a new master password, then ADD (a)
# walks name -> type (AWS, accepted via Enter) -> its three required fields
# -> no extra custom fields (blank line) -> notification dismissed -> quit.
# The record must be readable afterwards with the same password.
test_tui_create_store_and_add_record() {
  init_store_env
  ce tui <<<"$(printf 'tuipass1\namyaws\n\nAKIA_TUI\nus-tui-1\nsecret-tui\n\nzq')"
  assert_ok "tui create-store + add flow"
  assert_contains "$OUT" "Added myaws" "tui reports the record was added"

  export CLOUD_ENV_MASTER_PASSWORD="tuipass1"
  export CLOUD_ENV_DANGER=1
  ce ls
  assert_contains "$OUT" "myaws	AWS" "record written by tui is visible via ls"
}

# From the LIST screen, 'i' injects the highlighted record exactly like
# `ee inject` and ends the tui session. The tui-local password must not
# survive the session (it never touches danger mode).
test_tui_inject_exports_and_forgets_password() {
  init_store_env
  add_aws tui-target AKIA_INJECT
  unset CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER

  ce tui <<<"$(printf '%s\ni' "$MASTER_PASS")"
  assert_ok "tui inject flow"
  assert_contains "$OUT" "Environment set for AWS key: tui-target" "tui injected via 'i'"
  assert_eq "AKIA_INJECT" "${AWS_ACCESS_KEY_ID:-}" "injected record's vars land in the calling shell"
  assert_unset CLOUD_ENV_MASTER_PASSWORD "tui's password does not leak after it exits"
  assert_unset CLOUD_ENV_DANGER "tui never turns on real danger mode"
}

# ===========================================================================
# Section I — install
# ===========================================================================
#
# install writes to ~/.bashrc, so every test here points HOME at an isolated
# fake home directory inside TEST_TMP -- never the real one.

# With no existing alias, install appends one pointing at ee.sh's real path.
test_install_adds_alias_to_bashrc() {
  init_store_env
  local fake_home="$TEST_TMP/fakehome"
  mkdir -p "$fake_home"

  HOME="$fake_home" ce install
  assert_ok "install adds the alias"
  assert_contains "$OUT" "Added alias" "confirmation printed"
  grep -qF "alias ee='. $CLOUD_ENV_SH'" "$fake_home/.bashrc" \
    || fail "bashrc does not contain the expected alias line (got: $(cat "$fake_home/.bashrc" 2>&1))"
}

# An existing `alias ee=` in .bashrc is left untouched, and install fails.
test_install_refuses_existing_alias() {
  init_store_env
  local fake_home="$TEST_TMP/fakehome2"
  mkdir -p "$fake_home"
  echo "alias ee='something-else'" >"$fake_home/.bashrc"

  HOME="$fake_home" ce install
  assert_fails "install must refuse when an alias already exists"
  assert_contains "$OUT" "already defined" "clear error"
  assert_eq "alias ee='something-else'" "$(cat "$fake_home/.bashrc")" "bashrc left untouched"
}

# install takes no arguments and no --storage (it isn't a store command).
test_install_argument_validation() {
  init_store_env
  local fake_home="$TEST_TMP/fakehome3"
  mkdir -p "$fake_home"

  HOME="$fake_home" ce install extra-arg
  assert_fails "install with extra args must fail"
  HOME="$fake_home" ce install --storage "$TEST_TMP/x.enc"
  assert_fails "install with --storage must fail"
  assert_contains "$OUT" "--storage is not supported" "clear error"
}

# ===========================================================================
# Runner
# ===========================================================================

echo "ee.sh integration tests"
echo "script under test: $CLOUD_ENV_SH"

section "A: CLI basics"
run_test "no args launches tui"                          test_no_args_launches_tui
run_test "help prints usage"                             test_help_prints_usage
run_test "unknown command falls back to inject"          test_unknown_command_falls_back_to_inject

section "B: danger mode"
run_test "danger on reads password from stdin"           test_danger_on_reads_password_from_stdin
run_test "danger on rejects CLI password"                test_danger_on_rejects_cli_password
run_test "danger on rejects empty password"              test_danger_on_rejects_empty_password
run_test "danger off clears password and badge"          test_danger_off_clears_password_and_badge
run_test "danger argument validation"                    test_danger_argument_validation
run_test "danger rejects --storage"                      test_danger_rejects_storage_option

section "C: add"
run_test "add AWS record and ls"                         test_add_aws_and_ls
run_test "add AWS requires key and secret"               test_add_aws_requires_key_and_secret
run_test "add GCP validation"                            test_add_gcp_validation
run_test "add Azure validation"                          test_add_azure_validation
run_test "add custom type with --set"                    test_add_custom_type_with_set
run_test "add custom type via explicit flag"             test_add_custom_type_via_explicit_flag
run_test "add known-type fields via --set"               test_add_known_type_fields_via_set
run_test "add --set argument validation"                 test_add_set_argument_validation
run_test "add space and equals option forms"             test_add_space_and_equals_forms
run_test "add type is case-insensitive"                  test_add_type_case_insensitive
run_test "add overwrites existing record"                test_add_overwrites_existing_record
run_test "add argument errors"                           test_add_argument_errors

section "D: inject / off / PS1"
run_test "inject exports AWS context"                    test_inject_exports_aws_context
run_test "inject applies default region"                 test_inject_applies_default_region
run_test "all types coexist with badges"                 test_inject_all_types_coexist
run_test "same type replaces only that type"             test_inject_same_type_replaces_only_that_type
run_test "custom type replacement"                       test_inject_custom_type_replacement
run_test "inject missing key keeps context"              test_inject_missing_key_keeps_context
run_test "off clears everything"                         test_off_clears_everything
run_test "off also clears danger mode"                   test_off_also_clears_danger_mode
run_test "off argument validation"                       test_off_argument_validation

section "E: --storage placement"
run_test "--storage before command"                      test_storage_before_command
run_test "--storage after command"                       test_storage_after_command
run_test "--storage between options"                     test_storage_between_options
run_test "--storage= equals form"                        test_storage_equals_form
run_test "--storage with no command launches tui"        test_storage_only_launches_tui
run_test "--storage argument validation"                 test_storage_argument_validation
run_test "stores are isolated"                           test_storage_isolation

section "F: save & encryption"
run_test "save encrypts plaintext JSON"                  test_save_encrypts_plaintext
run_test "save input validation"                         test_save_input_validation
run_test "save warns before overwriting existing store"  test_save_warns_before_overwrite
run_test "save --force skips overwrite prompt"           test_save_force_skips_prompt
run_test "wrong password fails decryption"               test_wrong_password_fails
run_test "missing store fails clearly"                   test_missing_store_fails
run_test "untyped records default to AWS"                test_record_without_type_defaults_to_aws
run_test "store command argument counts"                 test_store_command_argument_counts

section "G: executed mode & self-test"
run_test "executed (non-sourced) store operations"       test_executed_mode_store_ops
run_test "built-in self-test passes"                     test_builtin_self_test
run_test "self-test does not clobber caller env"         test_selftest_does_not_clobber_caller_env
run_test "test rejects --storage"                        test_selftest_rejects_storage

section "H: tui"
run_test "tui creates a store and adds a record"          test_tui_create_store_and_add_record
run_test "tui inject exports vars and forgets password"   test_tui_inject_exports_and_forgets_password

section "I: install"
run_test "install adds alias to bashrc"                   test_install_adds_alias_to_bashrc
run_test "install refuses existing alias"                 test_install_refuses_existing_alias
run_test "install argument validation"                    test_install_argument_validation

echo
echo "----------------------------------------"
echo "total: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"

AFTER_BASHRC=$(file_fingerprint "$DEVELOPER_HOME/.bashrc")
AFTER_STORE=$(file_fingerprint "$DEVELOPER_HOME/.cloud-env/credentials.json.enc")
if [[ "$BEFORE_BASHRC" != "$AFTER_BASHRC" ]]; then
  echo "DESTRUCTIVE: ~/.bashrc changed during the test suite"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
if [[ "$BEFORE_STORE" != "$AFTER_STORE" ]]; then
  echo "DESTRUCTIVE: ~/.cloud-env/credentials.json.enc changed during the test suite"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
if [[ $BEFORE_STORE_DIR -eq 0 && -d "$DEVELOPER_HOME/.cloud-env" ]]; then
  echo "DESTRUCTIVE: tests created ~/.cloud-env"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo "failed:$FAILED_NAMES"
  exit 1
fi
echo "All tests passed."
exit 0

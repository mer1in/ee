#!/usr/bin/env bash
# ee.sh — load cloud credentials from an encrypted JSON store into the
# current shell as environment variables.
#
# The script is designed to be *sourced* so exported variables reach the
# calling shell:
#
#   alias ee='. ~/.local/bin/ee.sh'
#
# Store format: a single JSON object encrypted with OpenSSL (AES-256-CBC,
# PBKDF2). Every top-level key is a record name; every record contains a
# "type" field plus the environment variables to export for that record.

CLOUD_ENV_STORE_PATH="${CLOUD_ENV_STORE_PATH:-$HOME/.cloud-env/credentials.json.enc}"
CLOUD_ENV_DEFAULT_REGION="${CLOUD_ENV_DEFAULT_REGION:-eu-central-1}"

PARSED_STORAGE_PATH=""
PARSED_ARGS=()

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Return when sourced, exit when executed as a standalone script.
script_exit() {
  local code="${1:-0}"
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return "$code"
  fi

  exit "$code"
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

require_tools() {
  local missing=0
  local tool_name

  for tool_name in openssl jq mktemp grep dirname tr; do
    if ! command -v "$tool_name" >/dev/null 2>&1; then
      echo "Missing required tool: $tool_name" >&2
      missing=1
    fi
  done

  return "$missing"
}

print_credential_pages() {
  cat <<'PAGES'
Credential creation pages (long-lived credentials):
  AWS   IAM access keys: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html#Using_CreateAccessKey
  GCP   Service account keys: https://cloud.google.com/iam/docs/keys-create-delete
  Azure App registration client secret/certificate: https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal
PAGES
}

print_add_usage() {
  cat <<'USAGE'
Usage:
  ee add <key-name> [--type=AWS|GCP|Azure|<custom>] [--storage <path>]
      AWS:    --AWS_ACCESS_KEY_ID=<val> --AWS_SECRET_ACCESS_KEY=<val>
              [--AWS_DEFAULT_REGION=<val>]
      GCP:    --CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=<path>
              --CLOUDSDK_CORE_PROJECT=<id>
      Azure:  --AZURE_CLIENT_ID=<id> --AZURE_CLIENT_SECRET=<secret>
              --AZURE_TENANT_ID=<id> --AZURE_SUBSCRIPTION_ID=<id>
      Any:    --VAR_NAME=<val> (any explicit env var name) or
              --set NAME=VALUE (equivalent; the only way to define fields
              for custom types)
USAGE
  print_credential_pages
}

print_usage() {
  cat <<'USAGE'
Usage:
  ee <key-name>                (shortcut for: ee inject <key-name>)
  ee inject <key-name>
  ee ls
  ee off
  ee save <filename.json> [--force]
  ee add <key-name> [--type=AWS|GCP|Azure|<custom>]
            [AWS:   --AWS_ACCESS_KEY_ID=<val> --AWS_SECRET_ACCESS_KEY=<val> --AWS_DEFAULT_REGION=<val>]
            [GCP:   --CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=<path> --CLOUDSDK_CORE_PROJECT=<id>]
            [Azure: --AZURE_CLIENT_ID=<id> --AZURE_CLIENT_SECRET=<secret> --AZURE_TENANT_ID=<id> --AZURE_SUBSCRIPTION_ID=<id>]
            [--set NAME=VALUE]
  ee tui
  ee install
  ee danger on
  ee danger off
  ee test

Options:
  --storage <path>  Use an alternate encrypted store (inject/ls/add/save/tui).
                    May appear anywhere on the command line.
  --force           With 'save': skip the overwrite confirmation.

USAGE
  print_credential_pages
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Extract --storage <path> / --storage=<path> from the argument list, wherever
# it appears (before the command, after it, or between other options). The
# remaining arguments are collected in PARSED_ARGS.
parse_storage_option() {
  PARSED_STORAGE_PATH=""
  PARSED_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --storage)
        shift
        [[ -z "${1:-}" ]] && { echo "Missing value for --storage" >&2; return 1; }
        [[ -n "$PARSED_STORAGE_PATH" ]] && { echo "--storage can be provided only once" >&2; return 1; }
        PARSED_STORAGE_PATH="$1"
        ;;
      --storage=*)
        [[ -n "$PARSED_STORAGE_PATH" ]] && { echo "--storage can be provided only once" >&2; return 1; }
        PARSED_STORAGE_PATH="${1#--storage=}"
        [[ -z "$PARSED_STORAGE_PATH" ]] && { echo "Missing value for --storage" >&2; return 1; }
        ;;
      *)
        PARSED_ARGS+=("$1")
        ;;
    esac
    shift
  done

  return 0
}

# Run a command with CLOUD_ENV_STORE_PATH temporarily overridden.
run_with_storage_override() {
  local storage_path="$1"
  shift

  local original_store_path="$CLOUD_ENV_STORE_PATH"
  if [[ -n "$storage_path" ]]; then
    CLOUD_ENV_STORE_PATH="$storage_path"
  fi

  "$@"
  local rc=$?

  CLOUD_ENV_STORE_PATH="$original_store_path"
  return "$rc"
}

require_no_storage() {
  [[ -z "$PARSED_STORAGE_PATH" ]] && return 0
  echo "--storage is not supported for 'ee $1'" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Record types
# ---------------------------------------------------------------------------

# Known types get option shortcuts and required-field validation; any other
# ("custom") type is stored as-is with fields provided via --set NAME=VALUE.
supported_types() {
  local configured_types="${CLOUD_ENV_SUPPORTED_TYPES:-AWS GCP Azure}"
  printf '%s\n' "$configured_types"
}

# Normalize a record type: known types match case-insensitively and are mapped
# to their canonical spelling; unknown (custom) types pass through unchanged.
canonical_type() {
  local candidate="$1"
  local candidate_upper supported

  if [[ -z "$candidate" ]]; then
    echo "Record type is required" >&2
    return 1
  fi

  candidate_upper=$(to_upper "$candidate")
  for supported in $(supported_types); do
    if [[ "$candidate_upper" == "$(to_upper "$supported")" ]]; then
      printf '%s\n' "$supported"
      return 0
    fi
  done

  printf '%s\n' "$candidate"
}

# Turn a record type into a token safe for use inside variable names
# (e.g. "Azure" -> AZURE, "my-cloud" -> MY_CLOUD).
type_token() {
  local record_type="$1"
  local token

  token=$(printf '%s' "$record_type" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_')
  [[ -z "$token" ]] && token="GENERIC"
  printf '%s\n' "$token"
}

# ---------------------------------------------------------------------------
# Word-list helpers (space-separated lists kept in scalar variables)
# ---------------------------------------------------------------------------

has_word() {
  local haystack=" $1 "
  local needle="$2"
  [[ "$haystack" == *" $needle "* ]]
}

append_unique_word() {
  local list="$1"
  local item="$2"

  if has_word "$list" "$item"; then
    printf '%s\n' "$list"
  elif [[ -z "$list" ]]; then
    printf '%s\n' "$item"
  else
    printf '%s %s\n' "$list" "$item"
  fi
}

remove_word() {
  local list="$1"
  local item="$2"
  local result=""
  local current

  for current in $list; do
    [[ "$current" == "$item" ]] && continue
    if [[ -z "$result" ]]; then
      result="$current"
    else
      result="$result $current"
    fi
  done

  printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# Active-variable tracking (what `ee off` will clean up)
# ---------------------------------------------------------------------------

track_active_var() {
  local var_name="$1"
  CLOUD_ENV_ACTIVE_VARS=$(append_unique_word "${CLOUD_ENV_ACTIVE_VARS:-}" "$var_name")
}

untrack_active_var() {
  local var_name="$1"
  CLOUD_ENV_ACTIVE_VARS=$(remove_word "${CLOUD_ENV_ACTIVE_VARS:-}" "$var_name")
}

unset_active_vars() {
  local active_vars="${CLOUD_ENV_ACTIVE_VARS:-}"
  local var_name
  local type_tok

  for var_name in $active_vars; do
    unset "$var_name"
  done

  for type_tok in ${CLOUD_ENV_ACTIVE_TYPES:-}; do
    unset "CLOUD_ENV_TYPE_VARS_${type_tok}" "CLOUD_ENV_ACTIVE_KEY_${type_tok}" "CLOUD_ENV_ACTIVE_TYPE_${type_tok}"
  done

  unset CLOUD_ENV_ACTIVE_VARS CLOUD_ENV_ACTIVE_TYPES CLOUD_KEY_NAME CLOUD_ENV_TYPE CLOUD_PS1_KEY
}

# ---------------------------------------------------------------------------
# Encryption / store I/O
# ---------------------------------------------------------------------------

# Single place for the openssl invocation; uses the cached master password
# from danger mode when available, otherwise openssl prompts interactively.
openssl_crypt() {
  if [[ -n "${CLOUD_ENV_MASTER_PASSWORD:-}" ]]; then
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass env:CLOUD_ENV_MASTER_PASSWORD "$@"
  else
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 "$@"
  fi
}

decrypt_file() {
  local file_path="${1:-$CLOUD_ENV_STORE_PATH}"
  openssl_crypt -d -in "$file_path"
}

encrypt_file() {
  local file_content="$1"
  local file_path="${2:-$CLOUD_ENV_STORE_PATH}"

  mkdir -p "$(dirname "$file_path")"
  printf '%s' "$file_content" | openssl_crypt -salt -out "$file_path"
}

load_store() {
  local file_content

  if [[ ! -f "$CLOUD_ENV_STORE_PATH" ]]; then
    echo "Credential store not found: $CLOUD_ENV_STORE_PATH" >&2
    return 1
  fi

  file_content=$(decrypt_file) || {
    echo "Error decrypting file" >&2
    return 1
  }

  printf '%s\n' "$file_content"
}

save_store() {
  local file_content="$1"

  encrypt_file "$file_content" || {
    echo "Failed to encrypt credentials" >&2
    return 1
  }

  return 0
}

# ---------------------------------------------------------------------------
# PS1 badges
# ---------------------------------------------------------------------------

format_ps1_key() {
  local type_tok="$1"
  local key_type="$2"
  local key_name="$3"
  local icon="󱞁"
  local bg="244"

  case "$type_tok" in
    AWS) icon=""; bg="166" ;;
    GCP) icon="󱇶"; bg="33" ;;
    AZURE) icon="󰠅"; bg="26" ;;
  esac

  echo -e "\e[38;5;15m\e[48;5;${bg}m ${icon} ${key_type}:${key_name} \e[0m"
}

format_danger_badge() {
  echo -e "\e[38;5;15m\e[48;5;160m  DANGER \e[0m"
}

# Rebuild CLOUD_PS1_KEY: one badge per active cloud type, plus a DANGER badge
# while danger mode is enabled.
refresh_ps1_key() {
  local badge_output=""
  local type_tok key_var type_var key_name key_type

  if [[ "${CLOUD_ENV_DANGER:-0}" == "1" ]]; then
    badge_output="$(format_danger_badge)"
  fi

  for type_tok in ${CLOUD_ENV_ACTIVE_TYPES:-}; do
    key_var="CLOUD_ENV_ACTIVE_KEY_${type_tok}"
    type_var="CLOUD_ENV_ACTIVE_TYPE_${type_tok}"
    key_name="${!key_var:-}"
    key_type="${!type_var:-$type_tok}"

    [[ -z "$key_name" ]] && continue

    if [[ -z "$badge_output" ]]; then
      badge_output="$(format_ps1_key "$type_tok" "$key_type" "$key_name")"
    else
      badge_output="$badge_output $(format_ps1_key "$type_tok" "$key_type" "$key_name")"
    fi
  done

  export CLOUD_PS1_KEY="$badge_output"
  track_active_var CLOUD_PS1_KEY
}

# Remember which variables belong to a cloud type so that setting another key
# of the same type replaces exactly that type's context.
register_type_context() {
  local key_type="$1"
  local key_name="$2"
  local new_vars="$3"
  local token vars_var key_var type_var

  token=$(type_token "$key_type")
  vars_var="CLOUD_ENV_TYPE_VARS_${token}"
  key_var="CLOUD_ENV_ACTIVE_KEY_${token}"
  type_var="CLOUD_ENV_ACTIVE_TYPE_${token}"

  printf -v "$vars_var" '%s' "$new_vars"
  printf -v "$key_var" '%s' "$key_name"
  printf -v "$type_var" '%s' "$key_type"
  export "$vars_var" "$key_var" "$type_var"

  track_active_var "$vars_var"
  track_active_var "$key_var"
  track_active_var "$type_var"

  CLOUD_ENV_ACTIVE_TYPES=$(append_unique_word "${CLOUD_ENV_ACTIVE_TYPES:-}" "$token")
  track_active_var CLOUD_ENV_ACTIVE_TYPES
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

list_records() {
  local file_content

  file_content=$(load_store) || return 1

  printf '%s\n' "$file_content" | jq -r 'to_entries[] | "\(.key)\t\(.value.type // "AWS")"'
}

show_record() {
  local key_name="$1"
  local store_content record_json record_type field_name field_value region_loaded=0
  local token vars_var old_vars
  local record_vars=""

  store_content=$(load_store) || return 1

  record_json=$(printf '%s\n' "$store_content" | jq -c --arg key "$key_name" '.[$key] // empty')
  if [[ -z "$record_json" ]]; then
    echo "Key not found" >&2
    return 1
  fi

  record_type=$(printf '%s\n' "$record_json" | jq -r '.type // "AWS"')
  record_type=$(canonical_type "$record_type") || return 1

  # Replace only this type's previous context; other clouds stay untouched.
  token=$(type_token "$record_type")
  vars_var="CLOUD_ENV_TYPE_VARS_${token}"
  old_vars="${!vars_var:-}"
  for field_name in $old_vars; do
    unset "$field_name"
    untrack_active_var "$field_name"
  done

  while IFS= read -r field_name; do
    [[ "$field_name" == "type" ]] && continue
    field_value=$(printf '%s\n' "$record_json" | jq -r --arg field "$field_name" '.[$field] // empty')
    export "$field_name=$field_value"
    [[ "$field_name" == "AWS_DEFAULT_REGION" ]] && region_loaded=1
    track_active_var "$field_name"
    record_vars=$(append_unique_word "$record_vars" "$field_name")
  done < <(printf '%s\n' "$record_json" | jq -r 'keys[]')

  if [[ "$record_type" == "AWS" && "$region_loaded" -eq 0 ]]; then
    export AWS_DEFAULT_REGION="$CLOUD_ENV_DEFAULT_REGION"
    track_active_var AWS_DEFAULT_REGION
    record_vars=$(append_unique_word "$record_vars" AWS_DEFAULT_REGION)
  fi

  register_type_context "$record_type" "$key_name" "$record_vars"

  export CLOUD_KEY_NAME="$key_name"
  export CLOUD_ENV_TYPE="$record_type"
  track_active_var CLOUD_KEY_NAME
  track_active_var CLOUD_ENV_TYPE

  refresh_ps1_key

  echo "Environment set for ${record_type} key: ${key_name}"
}

enable_danger_mode_with_password() {
  local master_password="$1"

  if [[ -z "$master_password" ]]; then
    echo "Master password is required" >&2
    return 1
  fi

  export CLOUD_ENV_MASTER_PASSWORD="$master_password"
  export CLOUD_ENV_DANGER=1
  track_active_var CLOUD_ENV_MASTER_PASSWORD
  track_active_var CLOUD_ENV_DANGER
  refresh_ps1_key
  echo "Danger mode enabled"
}

disable_danger_mode() {
  unset CLOUD_ENV_MASTER_PASSWORD CLOUD_ENV_DANGER
  untrack_active_var CLOUD_ENV_MASTER_PASSWORD
  untrack_active_var CLOUD_ENV_DANGER
  refresh_ps1_key
  echo "Danger mode disabled"
}

set_danger_mode() {
  local mode="${1:-}"
  local arg2="${2:-}"
  local master_password=""

  case "$mode" in
    on)
      # The password is deliberately only accepted via the hidden stdin
      # prompt, never as a command-line argument (would leak into history
      # and the process list).
      if [[ -n "$arg2" ]]; then
        echo "Usage: ee danger on" >&2
        echo "Password must be entered via hidden stdin prompt" >&2
        return 1
      fi

      read -r -s -p "Master password: " master_password
      echo
      enable_danger_mode_with_password "$master_password"
      ;;
    off)
      disable_danger_mode
      ;;
    *)
      echo "Usage: ee danger on|off" >&2
      return 1
      ;;
  esac
}

# Register the `ee` alias in ~/.bashrc, pointing at wherever this script
# currently lives. Refuses to touch the file if an `ee` alias is already
# defined there.
install_alias() {
  local bashrc="$HOME/.bashrc"
  local script_path existing_line

  script_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

  if [[ -f "$bashrc" ]]; then
    existing_line=$(grep -nE '^[[:space:]]*alias[[:space:]]+ee=' "$bashrc" | head -1)
    if [[ -n "$existing_line" ]]; then
      echo "alias 'ee' is already defined in $bashrc:" >&2
      echo "  $existing_line" >&2
      echo "Remove or rename it, then re-run 'ee install'." >&2
      return 1
    fi
  fi

  {
    echo ""
    echo "# Added by 'ee install' on $(date +%F)"
    echo "alias ee='. $script_path'"
  } >> "$bashrc"

  echo "Added alias to $bashrc:"
  echo "  alias ee='. $script_path'"
  echo "Run 'source $bashrc' (or restart your shell) to start using it."
}

save_file() {
  local input_file="$1"
  local force="${2:-0}"
  local answer

  [[ ! -f "$input_file" ]] && { echo "File $input_file does not exist" >&2; return 1; }

  jq empty "$input_file" >/dev/null 2>&1 || {
    echo "File $input_file is not valid JSON" >&2
    return 1
  }

  if [[ "$force" -ne 1 && -f "$CLOUD_ENV_STORE_PATH" ]]; then
    echo "Warning: $CLOUD_ENV_STORE_PATH already exists and will be overwritten." >&2
    read -r -p "Overwrite existing store at $CLOUD_ENV_STORE_PATH? [y/N] " answer
    case "$answer" in
      y|Y) ;;
      *) echo "Aborted: store left unchanged" >&2; return 1 ;;
    esac
  fi

  save_store "$(cat "$input_file")" && echo "Credentials saved and encrypted"
}

# Check whether record_pairs (dynamically scoped from add_record) already
# contains a field with the given NAME.
record_pairs_have() {
  local wanted="$1"
  local pair

  for pair in "${record_pairs[@]}"; do
    [[ "${pair%%=*}" == "$wanted" ]] && return 0
  done

  return 1
}

# Per-type required-field lists, shared by CLI `add` validation and the tui
# ADD flow.
required_fields_for_type() {
  case "$1" in
    AWS)   printf '%s\n' AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION AWS_SECRET_ACCESS_KEY ;;
    GCP)   printf '%s\n' CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_CORE_PROJECT ;;
    Azure) printf '%s\n' AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID ;;
  esac
}

# Build the record's JSON and merge it into the store. Shared by add_record
# (CLI) and the tui ADD flow. record_pairs entries are "NAME=VALUE".
write_record() {
  local key_name="$1"
  local record_type="$2"
  shift 2
  local -a record_pairs=("$@")
  local store_content updated_content record_json option_name option_value

  if [[ -f "$CLOUD_ENV_STORE_PATH" ]]; then
    store_content=$(load_store) || return 1
  else
    store_content='{}'
  fi

  record_json=$(jq -n --arg type "$record_type" '{type: $type}')
  for option_value in "${record_pairs[@]}"; do
    option_name="${option_value%%=*}"
    option_value="${option_value#*=}"
    record_json=$(printf '%s\n' "$record_json" | jq --arg name "$option_name" --arg value "$option_value" '. + {($name): $value}')
  done

  updated_content=$(printf '%s\n' "$store_content" | jq --arg key "$key_name" --argjson record "$record_json" '. + {($key): $record}')
  save_store "$updated_content" && echo "Key $key_name added/updated successfully"
}

add_record() {
  local key_name=""
  local record_type="AWS"
  local -a record_pairs=()
  local option_name option_value set_name field_name

  # Uniform option parsing: every option accepts both `--opt value` and
  # `--opt=value`; the key name is the single non-option argument and may
  # appear anywhere. Known fields are set with their explicit env var name
  # (e.g. --AWS_ACCESS_KEY_ID=...); --set NAME=VALUE is an equivalent form
  # and the only way to define fields for custom (unknown) types.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*=*)
        option_name="${1%%=*}"
        option_value="${1#*=}"
        shift
        ;;
      --*)
        option_name="$1"
        option_value="${2:-}"
        shift
        [[ $# -gt 0 ]] && shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        if [[ -n "$key_name" ]]; then
          echo "Unexpected argument: $1 (key name already given: $key_name)" >&2
          return 1
        fi
        key_name="$1"
        shift
        continue
        ;;
    esac

    if [[ -z "$option_value" ]]; then
      echo "Missing value for $option_name" >&2
      return 1
    fi

    case "$option_name" in
      --type) record_type="$option_value" ;;

      --set)
        set_name="${option_value%%=*}"
        if [[ "$option_value" != *=* || -z "$set_name" ]]; then
          echo "--set expects NAME=VALUE, got: $option_value" >&2
          return 1
        fi
        if ! [[ "$set_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          echo "--set NAME must be a valid environment variable name, got: $set_name" >&2
          return 1
        fi
        record_pairs+=("$option_value")
        ;;

      --*)
        field_name="${option_name#--}"
        if ! [[ "$field_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          echo "Unknown option: $option_name" >&2
          return 1
        fi
        record_pairs+=("$field_name=$option_value")
        ;;

      *)
        echo "Unknown option: $option_name" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$key_name" ]]; then
    echo "Key name is required" >&2
    return 1
  fi

  record_type=$(canonical_type "$record_type") || return 1

  # Per-type validation: known types demand their defined set of fields
  # (which may be supplied via --VAR_NAME=... or --set); custom types have
  # no specific fields demanded.
  case "$record_type" in
    AWS|GCP|Azure)
      local missing_msg="" required_field
      for required_field in $(required_fields_for_type "$record_type"); do
        [[ "$required_field" == "AWS_DEFAULT_REGION" ]] && continue
        record_pairs_have "$required_field" || missing_msg="$missing_msg $required_field"
      done
      if [[ -n "$missing_msg" ]]; then
        echo "$record_type record requires:$missing_msg" >&2
        return 1
      fi
      ;;
  esac

  write_record "$key_name" "$record_type" "${record_pairs[@]}"
}

# ---------------------------------------------------------------------------
# tui — interactive browser/editor for the credential store
# ---------------------------------------------------------------------------
#
# Session state (TUI_STORE_JSON, TUI_QUIT_FLAG, TUI_KEY, TUI_INPUT,
# CLOUD_ENV_MASTER_PASSWORD, orig_stty, prev_int_trap) all live as `local`
# variables in run_tui. Every helper below is only ever called while run_tui
# is on the call stack, so bash's dynamic scoping makes them visible without
# passing them around explicitly, and they vanish (including the tui-local
# master password) the moment run_tui returns.

# Read one keypress, resolving arrow-key escape sequences. Sets $TUI_KEY to
# one of: a literal character, ENTER, ESC, UP, DOWN, LEFT, RIGHT. Sets
# TUI_QUIT_FLAG=1 if input can no longer be read (e.g. Ctrl-C interrupted it,
# or stdin closed).
tui_read_key() {
  local b rest

  if ! IFS= read -r -s -n 1 b; then
    TUI_KEY="ESC"
    TUI_QUIT_FLAG=1
    return
  fi

  if [[ "$b" == $'\x1b' ]]; then
    if IFS= read -r -s -n 2 -t 0.05 rest 2>/dev/null; then
      case "$rest" in
        '[A') TUI_KEY="UP" ;;
        '[B') TUI_KEY="DOWN" ;;
        '[C') TUI_KEY="RIGHT" ;;
        '[D') TUI_KEY="LEFT" ;;
        *)    TUI_KEY="ESC" ;;
      esac
    else
      TUI_KEY="ESC"
    fi
  elif [[ -z "$b" ]]; then
    TUI_KEY="ENTER"
  else
    TUI_KEY="$b"
  fi
}

# Temporarily leave raw mode for a normal, visible line prompt. Sets
# $TUI_INPUT.
tui_read_line() {
  local prompt="$1"
  stty "$orig_stty" 2>/dev/null
  read -r -p "$prompt" TUI_INPUT
  stty -echo -icanon min 1 time 0 2>/dev/null
}

# A yes/no line prompt; returns success only on y/Y.
tui_confirm() {
  local prompt="$1" answer
  stty "$orig_stty" 2>/dev/null
  read -r -p "$prompt" answer
  stty -echo -icanon min 1 time 0 2>/dev/null
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Print a message and wait for any keypress before the next redraw.
tui_notify() {
  echo
  echo "$1"
  echo "(press any key to continue)"
  tui_read_key
}

# Add a new field to an existing record (tui section-view 'a'); refuses to
# clobber an existing field name — the user has 'u' (update) for that.
tui_flow_add_field() {
  local key="$1" field_name field_value exists

  tui_read_line "New field name (blank to cancel): "
  field_name="$TUI_INPUT"
  [[ -z "$field_name" ]] && return

  if ! [[ "$field_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    tui_notify "Invalid field name: $field_name"
    return
  fi

  exists=$(printf '%s' "$TUI_STORE_JSON" | jq -r --arg k "$key" --arg f "$field_name" '.[$k] | has($f)')
  if [[ "$exists" == "true" ]]; then
    tui_notify "Field '$field_name' already exists on $key -- use 'u' to update it."
    return
  fi

  tui_read_line "$field_name value: "
  field_value="$TUI_INPUT"
  TUI_STORE_JSON=$(printf '%s' "$TUI_STORE_JSON" | jq --arg k "$key" --arg f "$field_name" --arg v "$field_value" '.[$k][$f] = $v')
  save_store "$TUI_STORE_JSON"
  tui_notify "Added $field_name to $key"
}

# Create a brand-new top-level record: name, type (picked from known types +
# types already present in the store + a free-text "other"), its required
# fields if the type is known, then any extra custom name=value pairs.
tui_flow_add() {
  local name existing record_type type_choice extra_type field value
  local -a type_choices=() pairs=()
  local type_cursor=0 tcount row

  tui_read_line "New key name (blank to cancel): "
  name="$TUI_INPUT"
  [[ -z "$name" ]] && return

  existing=$(printf '%s' "$TUI_STORE_JSON" | jq -r --arg k "$name" 'has($k)')
  if [[ "$existing" == "true" ]]; then
    tui_notify "A key named '$name' already exists."
    return
  fi

  type_choices=(AWS GCP Azure)
  while IFS= read -r extra_type; do
    [[ -z "$extra_type" ]] && continue
    case " ${type_choices[*]} " in *" $extra_type "*) continue ;; esac
    type_choices+=("$extra_type")
  done < <(printf '%s' "$TUI_STORE_JSON" | jq -r '[.[].type] | unique[]')
  type_choices+=("other (enter a new type)")
  tcount=${#type_choices[@]}

  while true; do
    clear
    echo "ee tui -- new key: $name"
    echo
    echo "Select a type:"
    for ((row = 0; row < tcount; row++)); do
      if [[ $row -eq $type_cursor ]]; then
        printf '> %s\n' "${type_choices[$row]}"
      else
        printf '  %s\n' "${type_choices[$row]}"
      fi
    done
    echo
    echo "j/k h/l up/down move   Enter select   Esc/q cancel"

    tui_read_key
    [[ "$TUI_QUIT_FLAG" -eq 1 ]] && return
    case "$TUI_KEY" in
      j|DOWN) type_cursor=$(( (type_cursor + 1) % tcount )) ;;
      k|UP)   type_cursor=$(( (type_cursor - 1 + tcount) % tcount )) ;;
      l|ENTER) break ;;
      q|ESC) return ;;
    esac
  done

  type_choice="${type_choices[$type_cursor]}"
  if [[ "$type_choice" == "other (enter a new type)" ]]; then
    tui_read_line "New type name: "
    record_type="$TUI_INPUT"
    [[ -z "$record_type" ]] && { tui_notify "Type name cannot be empty."; return; }
  else
    record_type="$type_choice"
  fi
  record_type=$(canonical_type "$record_type") || { tui_notify "Invalid type"; return; }

  case "$record_type" in
    AWS|GCP|Azure)
      for field in $(required_fields_for_type "$record_type"); do
        tui_read_line "$field: "
        value="$TUI_INPUT"
        [[ -z "$value" && "$field" == "AWS_DEFAULT_REGION" ]] && continue
        pairs+=("$field=$value")
      done
      ;;
  esac

  local more_name more_value
  while true; do
    tui_read_line "Add custom field (name, blank to finish): "
    more_name="$TUI_INPUT"
    [[ -z "$more_name" ]] && break
    if ! [[ "$more_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      tui_notify "Invalid field name: $more_name"
      continue
    fi
    tui_read_line "$more_name value: "
    more_value="$TUI_INPUT"
    pairs+=("$more_name=$more_value")
  done

  write_record "$name" "$record_type" "${pairs[@]}" >/dev/null
  TUI_STORE_JSON=$(load_store)
  tui_notify "Added $name"
}

# Section view: browse/reveal/update a single record's fields, or add a new
# one to it.
tui_screen_section() {
  local key="$1"
  local -a fields=()
  local cursor=0 revealed_fields=""
  local field_count row fname fval

  while true; do
    fields=()
    while IFS= read -r fname; do
      [[ -z "$fname" ]] && continue
      fields+=("$fname")
    done < <(printf '%s' "$TUI_STORE_JSON" | jq -r --arg k "$key" '.[$k] | keys[] | select(. != "type")')
    field_count=${#fields[@]}
    [[ $cursor -ge $field_count ]] && cursor=$((field_count - 1))
    [[ $cursor -lt 0 ]] && cursor=0

    clear
    echo "ee tui -- $key"
    echo
    if [[ $field_count -eq 0 ]]; then
      echo "  (no fields)"
    else
      for ((row = 0; row < field_count; row++)); do
        fname="${fields[$row]}"
        if has_word "$revealed_fields" "$fname"; then
          fval=$(printf '%s' "$TUI_STORE_JSON" | jq -r --arg k "$key" --arg f "$fname" '.[$k][$f]')
        else
          fval='***'
        fi
        if [[ $row -eq $cursor ]]; then
          printf '> %-30s %s\n' "$fname" "$fval"
        else
          printf '  %-30s %s\n' "$fname" "$fval"
        fi
      done
    fi
    echo
    echo "j/k up/down move   v view   u update   a add field   h/Esc/q back"

    tui_read_key
    [[ "$TUI_QUIT_FLAG" -eq 1 ]] && return
    case "$TUI_KEY" in
      j|DOWN) [[ $field_count -gt 0 ]] && cursor=$(( (cursor + 1) % field_count )) ;;
      k|UP)   [[ $field_count -gt 0 ]] && cursor=$(( (cursor - 1 + field_count) % field_count )) ;;
      v)
        if [[ $field_count -gt 0 ]]; then
          fname="${fields[$cursor]}"
          if has_word "$revealed_fields" "$fname"; then
            revealed_fields=$(remove_word "$revealed_fields" "$fname")
          else
            revealed_fields=$(append_unique_word "$revealed_fields" "$fname")
          fi
        fi
        ;;
      u)
        if [[ $field_count -gt 0 ]]; then
          fname="${fields[$cursor]}"
          tui_read_line "New value for $fname: "
          TUI_STORE_JSON=$(printf '%s' "$TUI_STORE_JSON" | jq --arg k "$key" --arg f "$fname" --arg v "$TUI_INPUT" '.[$k][$f] = $v')
          save_store "$TUI_STORE_JSON"
          tui_notify "Updated $fname on $key"
        fi
        ;;
      a) tui_flow_add_field "$key" ;;
      h|LEFT|q|ESC) return ;;
    esac
  done
}

# Top-level LIST screen: browse records, inject/delete/open one, or add a
# new one. Returns (and sets TUI_QUIT_FLAG=1) when the user quits or
# injects — both terminate the tui session.
tui_screen_list() {
  local -a keys=()
  local cursor=0 key_count row selected rtype

  while true; do
    keys=()
    while IFS= read -r selected; do
      [[ -z "$selected" ]] && continue
      keys+=("$selected")
    done < <(printf '%s' "$TUI_STORE_JSON" | jq -r 'keys[]')
    key_count=${#keys[@]}
    [[ $cursor -ge $key_count ]] && cursor=$((key_count - 1))
    [[ $cursor -lt 0 ]] && cursor=0

    clear
    echo "ee tui -- $CLOUD_ENV_STORE_PATH"
    echo
    if [[ $key_count -eq 0 ]]; then
      echo "  (no records yet -- press 'a' to add one)"
    else
      for ((row = 0; row < key_count; row++)); do
        rtype=$(printf '%s' "$TUI_STORE_JSON" | jq -r --arg k "${keys[$row]}" '.[$k].type // "AWS"')
        if [[ $row -eq $cursor ]]; then
          printf '> %-30s %s\n' "${keys[$row]}" "$rtype"
        else
          printf '  %-30s %s\n' "${keys[$row]}" "$rtype"
        fi
      done
    fi
    echo
    echo "j/k up/down move   Enter/l open   i inject   a add   d delete   q/Esc quit"

    tui_read_key
    [[ "$TUI_QUIT_FLAG" -eq 1 ]] && return
    case "$TUI_KEY" in
      j|DOWN) [[ $key_count -gt 0 ]] && cursor=$(( (cursor + 1) % key_count )) ;;
      k|UP)   [[ $key_count -gt 0 ]] && cursor=$(( (cursor - 1 + key_count) % key_count )) ;;
      l|RIGHT|ENTER)
        [[ $key_count -gt 0 ]] && tui_screen_section "${keys[$cursor]}"
        ;;
      i)
        if [[ $key_count -gt 0 ]]; then
          selected="${keys[$cursor]}"
          stty "$orig_stty" 2>/dev/null
          echo
          show_record "$selected"
          TUI_QUIT_FLAG=1
          return
        fi
        ;;
      d)
        if [[ $key_count -gt 0 ]]; then
          selected="${keys[$cursor]}"
          if tui_confirm "Delete $selected? [y/N] "; then
            TUI_STORE_JSON=$(printf '%s' "$TUI_STORE_JSON" | jq --arg k "$selected" 'del(.[$k])')
            save_store "$TUI_STORE_JSON"
            tui_notify "Deleted $selected"
          fi
        fi
        ;;
      a) tui_flow_add ;;
      q|ESC) TUI_QUIT_FLAG=1; return ;;
    esac
  done
}

# Entry point for `ee tui`. Authenticates once (password is held only for
# this function's lifetime -- see the note above), then loops the LIST
# screen until the user quits or injects a key.
run_tui() {
  local orig_stty prev_int_trap tui_password
  local TUI_STORE_JSON TUI_QUIT_FLAG=0 TUI_KEY TUI_INPUT
  # -x (export) so openssl subprocesses can see it via `-pass env:...`; being
  # `local` still means it -- and its export binding -- disappear the moment
  # run_tui returns, regardless of danger mode's own (separately exported)
  # CLOUD_ENV_MASTER_PASSWORD.
  local -x CLOUD_ENV_MASTER_PASSWORD

  if [[ ! -f "$CLOUD_ENV_STORE_PATH" ]]; then
    echo "No store found at $CLOUD_ENV_STORE_PATH -- creating a new one."
    read -r -s -p "Set a new master password: " tui_password
    echo
    if [[ -z "$tui_password" ]]; then
      echo "Master password is required" >&2
      return 1
    fi
    CLOUD_ENV_MASTER_PASSWORD="$tui_password"
    TUI_STORE_JSON='{}'
  else
    read -r -s -p "Master password: " tui_password
    echo
    CLOUD_ENV_MASTER_PASSWORD="$tui_password"
    TUI_STORE_JSON=$(load_store) || return 1
  fi

  orig_stty=$(stty -g 2>/dev/null)
  prev_int_trap=$(trap -p INT)
  trap 'stty "$orig_stty" 2>/dev/null; if [[ -n "$prev_int_trap" ]]; then eval "$prev_int_trap"; else trap - INT; fi; TUI_QUIT_FLAG=1' INT
  trap 'stty "$orig_stty" 2>/dev/null; if [[ -n "$prev_int_trap" ]]; then eval "$prev_int_trap"; else trap - INT; fi' RETURN

  stty -echo -icanon min 1 time 0 2>/dev/null

  while [[ "$TUI_QUIT_FLAG" -ne 1 ]]; do
    tui_screen_list
  done
}

# ---------------------------------------------------------------------------
# Self-test (runs against a throwaway temp store)
# ---------------------------------------------------------------------------

run_self_test() {
  local tmp_dir tmp_store original_store original_password original_danger original_active original_key original_type original_ps1
  local original_active_types
  local test_pass='test-pass'

  require_tools || {
    echo "Install missing tools and rerun: ee test" >&2
    return 1
  }

  tmp_dir=$(mktemp -d) || return 1
  tmp_store="$tmp_dir/credentials.json.enc"

  original_store="$CLOUD_ENV_STORE_PATH"
  original_password="${CLOUD_ENV_MASTER_PASSWORD:-}"
  original_danger="${CLOUD_ENV_DANGER:-}"
  original_active="${CLOUD_ENV_ACTIVE_VARS:-}"
  original_active_types="${CLOUD_ENV_ACTIVE_TYPES:-}"
  original_key="${CLOUD_KEY_NAME:-}"
  original_type="${CLOUD_ENV_TYPE:-}"
  original_ps1="${CLOUD_PS1_KEY:-}"

  trap 'rm -rf "$tmp_dir"; CLOUD_ENV_STORE_PATH="$original_store"; export CLOUD_ENV_MASTER_PASSWORD="$original_password"; export CLOUD_ENV_DANGER="$original_danger"; CLOUD_ENV_ACTIVE_VARS="$original_active"; CLOUD_ENV_ACTIVE_TYPES="$original_active_types"; CLOUD_KEY_NAME="$original_key"; CLOUD_ENV_TYPE="$original_type"; CLOUD_PS1_KEY="$original_ps1"' RETURN

  CLOUD_ENV_STORE_PATH="$tmp_store"
  unset_active_vars
  enable_danger_mode_with_password "$test_pass" || return 1

  save_store "$(jq -n '{
    "aws-main": {type: "AWS", AWS_ACCESS_KEY_ID: "aws-id", AWS_SECRET_ACCESS_KEY: "aws-secret", AWS_DEFAULT_REGION: "us-west-2"},
    "aws-next": {type: "AWS", AWS_ACCESS_KEY_ID: "aws-id-2", AWS_SECRET_ACCESS_KEY: "aws-secret-2", AWS_DEFAULT_REGION: "eu-west-1"},
    "gcp-main": {type: "GCP", CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE: "/tmp/gcp.json", CLOUDSDK_CORE_PROJECT: "demo-project"},
    "azure-main": {type: "Azure", AZURE_TENANT_ID: "tenant", AZURE_CLIENT_ID: "client", AZURE_CLIENT_SECRET: "secret", AZURE_SUBSCRIPTION_ID: "sub"}
  }')" || return 1

  show_record aws-main || return 1
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id" ]] || { echo "AWS credentials were not loaded"; return 1; }
  [[ "${CLOUD_ENV_TYPE:-}" == "AWS" ]] || { echo "AWS type was not preserved"; return 1; }

  show_record gcp-main || return 1
  [[ "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" == "/tmp/gcp.json" ]] || { echo "GCP credentials were not loaded"; return 1; }
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id" ]] || { echo "AWS variables should remain untouched when loading GCP"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"AWS:aws-main"* && "$CLOUD_PS1_KEY" == *"GCP:gcp-main"* ]] || { echo "Prompt marker should include both AWS and GCP"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"DANGER"* ]] || { echo "Danger marker should be visible in prompt"; return 1; }

  show_record aws-next || return 1
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id-2" ]] || { echo "AWS context should be replaced by type"; return 1; }
  [[ "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" == "/tmp/gcp.json" ]] || { echo "GCP context should remain untouched"; return 1; }

  set_danger_mode off || return 1
  [[ -z "${CLOUD_ENV_DANGER:-}" && -z "${CLOUD_ENV_MASTER_PASSWORD:-}" ]] || { echo "Danger mode was not disabled"; return 1; }
  [[ "$CLOUD_PS1_KEY" != *"DANGER"* ]] || { echo "Danger marker should be removed"; return 1; }

  set_danger_mode on "$test_pass" >/dev/null 2>&1 && { echo "danger on should reject command-line password"; return 1; }
  enable_danger_mode_with_password "$test_pass" || return 1

  add_record azure-extra --type=Azure --AZURE_CLIENT_ID=cid --AZURE_CLIENT_SECRET=csec --AZURE_TENANT_ID=tid --AZURE_SUBSCRIPTION_ID=sid || return 1
  list_records | grep -q '^azure-extra[[:space:]]Azure$' || { echo "Typed record listing failed"; return 1; }

  # Custom (unknown) types: fields come exclusively from --set NAME=VALUE.
  add_record custom-extra --type=qqq --set CUSTOM_TOKEN=tok --set CUSTOM_URL=https://example.test || return 1
  list_records | grep -q '^custom-extra[[:space:]]qqq$' || { echo "Custom record listing failed"; return 1; }
  show_record custom-extra || return 1
  [[ "${CUSTOM_TOKEN:-}" == "tok" ]] || { echo "Custom-type fields were not loaded"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"qqq:custom-extra"* ]] || { echo "Custom type badge missing from prompt"; return 1; }

  unset_active_vars
  echo "Self-test passed"
}

# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

cloud_env_main() {
  local cmd
  local -a args=()

  if [[ $# -eq 0 ]]; then
    print_usage
    return 1
  fi

  # --storage is a global option: it may appear anywhere on the command line.
  parse_storage_option "$@" || return 1

  if [[ ${#PARSED_ARGS[@]} -eq 0 ]]; then
    print_usage
    return 1
  fi

  cmd="${PARSED_ARGS[0]}"
  args=("${PARSED_ARGS[@]:1}")

  # Any command that isn't one of the known subcommands is treated as a key
  # name to inject, e.g. `ee myenv` behaves exactly like `ee inject myenv`
  # (reusing inject's own arg-count validation and --storage handling).
  case "$cmd" in
    off|ls|save|add|inject|danger|test|tui|install) ;;
    *)
      cmd="inject"
      args=("${PARSED_ARGS[@]}")
      ;;
  esac

  case "$cmd" in
    off)
      require_no_storage off || return 1
      if [[ ${#args[@]} -ne 0 ]]; then
        echo "Usage: ee off" >&2
        return 1
      fi
      unset_active_vars
      ;;
    ls)
      if [[ ${#args[@]} -ne 0 ]]; then
        echo "Usage: ee ls [--storage <path>]" >&2
        return 1
      fi
      run_with_storage_override "$PARSED_STORAGE_PATH" list_records
      ;;
    save)
      local -a save_args=()
      local save_force=0
      local save_arg
      for save_arg in "${args[@]}"; do
        if [[ "$save_arg" == "--force" ]]; then
          save_force=1
        else
          save_args+=("$save_arg")
        fi
      done
      if [[ ${#save_args[@]} -ne 1 ]]; then
        echo "Usage: ee save [--storage <path>] <filename.json> [--force]" >&2
        return 1
      fi
      run_with_storage_override "$PARSED_STORAGE_PATH" save_file "${save_args[0]}" "$save_force"
      ;;
    add)
      if [[ ${#args[@]} -eq 0 ]]; then
        print_add_usage
        return 1
      fi
      run_with_storage_override "$PARSED_STORAGE_PATH" add_record "${args[@]}"
      ;;
    inject)
      if [[ ${#args[@]} -ne 1 ]]; then
        echo "Usage: ee inject [--storage <path>] <key-name>" >&2
        return 1
      fi
      run_with_storage_override "$PARSED_STORAGE_PATH" show_record "${args[0]}"
      ;;
    tui)
      if [[ ${#args[@]} -ne 0 ]]; then
        echo "Usage: ee tui [--storage <path>]" >&2
        return 1
      fi
      run_with_storage_override "$PARSED_STORAGE_PATH" run_tui
      ;;
    install)
      require_no_storage install || return 1
      if [[ ${#args[@]} -ne 0 ]]; then
        echo "Usage: ee install" >&2
        return 1
      fi
      install_alias
      ;;
    danger)
      require_no_storage danger || return 1
      if [[ ${#args[@]} -eq 0 ]]; then
        echo "Usage: ee danger on|off" >&2
        return 1
      fi
      set_danger_mode "${args[@]}"
      ;;
    test)
      require_no_storage test || return 1
      run_self_test
      ;;
    *)
      print_usage
      return 1
      ;;
  esac
}

cloud_env_main "$@"
script_exit $?

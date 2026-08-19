#!/usr/bin/env bash
# Export cloud credentials from an encrypted JSON store.

CLOUD_ENV_STORE_PATH="${CLOUD_ENV_STORE_PATH:-$HOME/.cloud-env/credentials.json.enc}"
CLOUD_ENV_DEFAULT_REGION="${CLOUD_ENV_DEFAULT_REGION:-eu-central-1}"

script_exit() {
  local code="${1:-0}"
  return "$code" 2> /dev/null || exit "$code"
}

print_usage() {
  cat <<'EOF'
Usage:
  cloud-env.sh set [--storage <path>] <key-name>
  cloud-env.sh ls [--storage <path>]
  cloud-env.sh off
  cloud-env.sh save [--storage <path>] <filename.json>
  cloud-env.sh add [--storage <path>] <key-name> [--type=AWS|GCP|Azure] [--key=<val>] [--secret=<val>] [--region=<val>] [--set NAME=VALUE]
  cloud-env.sh danger on
  cloud-env.sh danger off
  cloud-env.sh test
EOF
}

require_tools() {
  local missing=0
  local tool_name

  for tool_name in openssl jq mktemp grep dirname tr; do
    if ! command -v "$tool_name" >/dev/null 2>&1; then
      echo "Missing required tool: $tool_name"
      missing=1
    fi
  done

  return "$missing"
}

PARSED_STORAGE_PATH=""
PARSED_ARGS=()

parse_storage_option() {
  PARSED_STORAGE_PATH=""
  PARSED_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --storage)
        shift
        if [[ -z "${1:-}" ]]; then
          echo "Missing value for --storage"
          return 1
        fi
        if [[ -n "$PARSED_STORAGE_PATH" ]]; then
          echo "--storage can be provided only once"
          return 1
        fi
        PARSED_STORAGE_PATH="$1"
        ;;
      --storage=*)
        if [[ -n "$PARSED_STORAGE_PATH" ]]; then
          echo "--storage can be provided only once"
          return 1
        fi
        PARSED_STORAGE_PATH="${1#--storage=}"
        if [[ -z "$PARSED_STORAGE_PATH" ]]; then
          echo "Missing value for --storage"
          return 1
        fi
        ;;
      *)
        PARSED_ARGS+=("$1")
        ;;
    esac
    shift
  done

  return 0
}

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

validate_type() {
  normalize_type "$1" >/dev/null
}

supported_types() {
  local configured_types="${CLOUD_ENV_SUPPORTED_TYPES:-AWS GCP Azure}"
  printf '%s\n' "$configured_types"
}

normalize_type() {
  local candidate="$1"
  local candidate_upper
  local supported configured_types supported_upper

  [[ -z "$candidate" ]] && {
    echo "Record type is required"
    return 1
  }

  candidate_upper=$(printf '%s' "$candidate" | tr '[:lower:]' '[:upper:]')
  configured_types=$(supported_types)

  for supported in $configured_types; do
    supported_upper=$(printf '%s' "$supported" | tr '[:lower:]' '[:upper:]')
    if [[ "$candidate_upper" == "$supported_upper" ]]; then
      printf '%s\n' "$supported"
      return 0
    fi
  done

  echo "Unsupported record type: $candidate"
  echo "Supported types: $configured_types"
  return 1
}

type_token() {
  local record_type="$1"
  local token

  token=$(printf '%s' "$record_type" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_')
  [[ -z "$token" ]] && token="GENERIC"
  printf '%s\n' "$token"
}

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
  local type_token
  local vars_var key_var type_var

  for var_name in $active_vars; do
    unset "$var_name"
  done

  for type_token in ${CLOUD_ENV_ACTIVE_TYPES:-}; do
    vars_var="CLOUD_ENV_TYPE_VARS_${type_token}"
    key_var="CLOUD_ENV_ACTIVE_KEY_${type_token}"
    type_var="CLOUD_ENV_ACTIVE_TYPE_${type_token}"
    unset "$vars_var"
    unset "$key_var"
    unset "$type_var"
  done

  unset CLOUD_ENV_ACTIVE_VARS
  unset CLOUD_ENV_ACTIVE_TYPES
  unset CLOUD_KEY_NAME
  unset CLOUD_ENV_TYPE
  unset CLOUD_PS1_KEY
}

rmkeys() {
  unset_active_vars
}

decrypt_file() {
  local file_path="${1:-$CLOUD_ENV_STORE_PATH}"

  if [[ -n "${CLOUD_ENV_MASTER_PASSWORD:-}" ]]; then
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass env:CLOUD_ENV_MASTER_PASSWORD -d -in "$file_path"
  else
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -in "$file_path"
  fi
}

encrypt_file() {
  local file_content="$1"
  local file_path="${2:-$CLOUD_ENV_STORE_PATH}"

  mkdir -p "$(dirname "$file_path")"

  if [[ -n "${CLOUD_ENV_MASTER_PASSWORD:-}" ]]; then
    printf '%s' "$file_content" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass env:CLOUD_ENV_MASTER_PASSWORD -salt -out "$file_path"
  else
    printf '%s' "$file_content" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -out "$file_path"
  fi
}

format_ps1_key() {
  local type_token="$1"
  local key_type="$2"
  local key_name="$3"
  local icon="󱞁"
  local bg="244"

  case "$type_token" in
    AWS)
      icon=""
      bg="166"
      ;;
    GCP)
      icon="󱇶"
      bg="33"
      ;;
    AZURE)
      icon="󰠅"
      bg="26"
      ;;
  esac

  echo -e "\e[38;5;15m\e[48;5;${bg}m ${icon} ${key_type}:${key_name} \e[0m"
}

format_danger_badge() {
  echo -e "\e[38;5;15m\e[48;5;160m  DANGER \e[0m"
}

refresh_ps1_key() {
  local badge_output=""
  local type_token key_var type_var
  local key_name key_type

  if [[ "${CLOUD_ENV_DANGER:-0}" == "1" ]]; then
    badge_output="$(format_danger_badge)"
  fi

  for type_token in ${CLOUD_ENV_ACTIVE_TYPES:-}; do
    key_var="CLOUD_ENV_ACTIVE_KEY_${type_token}"
    type_var="CLOUD_ENV_ACTIVE_TYPE_${type_token}"
    key_name="${!key_var:-}"
    key_type="${!type_var:-$type_token}"

    [[ -z "$key_name" ]] && continue

    if [[ -z "$badge_output" ]]; then
      badge_output="$(format_ps1_key "$type_token" "$key_type" "$key_name")"
    else
      badge_output="$badge_output $(format_ps1_key "$type_token" "$key_type" "$key_name")"
    fi
  done

  export CLOUD_PS1_KEY="$badge_output"
  track_active_var CLOUD_PS1_KEY
}

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

load_store() {
  local file_content

  file_content=$(decrypt_file) || {
    echo "Error decrypting file"
    return 1
  }

  printf '%s\n' "$file_content"
}

save_store() {
  local file_content="$1"
  encrypt_file "$file_content" || {
    echo "Failed to encrypt credentials"
    return 1
  }

  return 0
}

list_records() {
  local file_content

  file_content=$(load_store) || {
    unset_active_vars
    return 1
  }

  printf '%s\n' "$file_content" | jq -r 'to_entries[] | "\(.key)\t\(.value.type // "AWS")"'
}

show_record() {
  local key_name="$1"
  local store_content record_json record_type field_name field_value region_loaded=0
  local token vars_var old_vars normalized_type
  local record_vars=""

  store_content=$(load_store) || {
    return 1
  }

  record_json=$(printf '%s\n' "$store_content" | jq -c --arg key "$key_name" '.[$key] // empty')
  if [[ -z "$record_json" ]]; then
    echo "Key not found"
    unset_active_vars
    return 1
  fi

  record_type=$(printf '%s\n' "$record_json" | jq -r '.type // "AWS"')
  normalized_type=$(normalize_type "$record_type") || return 1
  record_type="$normalized_type"

  token=$(type_token "$record_type")
  vars_var="CLOUD_ENV_TYPE_VARS_${token}"
  old_vars="${!vars_var:-}"
  for field_name in $old_vars; do
    unset "$field_name"
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
    echo "Master password is required"
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
  unset CLOUD_ENV_MASTER_PASSWORD
  unset CLOUD_ENV_DANGER
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
      if [[ -n "$arg2" ]]; then
        echo "Usage: $0 danger on"
        echo "Password must be entered via hidden stdin prompt"
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
      echo "Usage: $0 danger on|off"
      return 1
      ;;
  esac
}

save_file() {
  local input_file="$1"

  [[ ! -f "$input_file" ]] && { echo "File $input_file does not exist"; return 1; }

  save_store "$(cat "$input_file")" && echo "Credentials saved and encrypted"
}

add_record() {
  local key_name="$1"
  shift

  local record_type="AWS"
  local normalized_type
  local -a record_pairs=()
  local option_name option_value

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)
        record_type="${1#--type=}"
        ;;
      --key=*)
        record_pairs+=("AWS_ACCESS_KEY_ID=${1#--key=}")
        ;;
      --secret=*)
        record_pairs+=("AWS_SECRET_ACCESS_KEY=${1#--secret=}")
        ;;
      --region=*)
        record_pairs+=("AWS_DEFAULT_REGION=${1#--region=}")
        ;;
      --set=*)
        record_pairs+=("${1#--set=}")
        ;;
      --set)
        shift
        [[ -z "$1" ]] && { echo "Missing value for --set"; return 1; }
        record_pairs+=("$1")
        ;;
      *)
        echo "Unknown option: $1"
        return 1
        ;;
    esac
    shift
  done

  normalized_type=$(normalize_type "$record_type") || return 1
  record_type="$normalized_type"

  local store_content updated_content record_json
  store_content=$(load_store) || store_content='{}'
  record_json=$(jq -n --arg type "$record_type" '{type: $type}')

  for option_name in "${record_pairs[@]}"; do
    option_value="${option_name#*=}"
    option_name="${option_name%%=*}"
    record_json=$(printf '%s\n' "$record_json" | jq --arg name "$option_name" --arg value "$option_value" '. + {($name): $value}')
  done

  updated_content=$(printf '%s\n' "$store_content" | jq --arg key "$key_name" --argjson record "$record_json" '. + {($key): $record}')
  save_store "$updated_content" && echo "Key $key_name added/updated successfully"
}

run_self_test() {
  local tmp_dir tmp_store original_store original_password original_danger original_active original_key original_type original_ps1
  local original_active_types
  local test_pass='test-pass'

  require_tools || {
    echo "Install missing tools and rerun: $0 test"
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

  trap 'rm -rf "$tmp_dir"; CLOUD_ENV_STORE_PATH="$original_store"; CLOUD_ENV_MASTER_PASSWORD="$original_password"; CLOUD_ENV_DANGER="$original_danger"; CLOUD_ENV_ACTIVE_VARS="$original_active"; CLOUD_ENV_ACTIVE_TYPES="$original_active_types"; CLOUD_KEY_NAME="$original_key"; CLOUD_ENV_TYPE="$original_type"; CLOUD_PS1_KEY="$original_ps1"' RETURN

  CLOUD_ENV_STORE_PATH="$tmp_store"
  unset_active_vars
  enable_danger_mode_with_password "$test_pass" || return 1

  save_store "$(jq -n '{
    "aws-main": {type: "AWS", AWS_ACCESS_KEY_ID: "aws-id", AWS_SECRET_ACCESS_KEY: "aws-secret", AWS_DEFAULT_REGION: "us-west-2"},
    "aws-next": {type: "AWS", AWS_ACCESS_KEY_ID: "aws-id-2", AWS_SECRET_ACCESS_KEY: "aws-secret-2", AWS_DEFAULT_REGION: "eu-west-1"},
    "gcp-main": {type: "GCP", GCP_PROJECT: "demo-project", GOOGLE_APPLICATION_CREDENTIALS: "/tmp/gcp.json"},
    "azure-main": {type: "Azure", AZURE_TENANT_ID: "tenant", AZURE_CLIENT_ID: "client", AZURE_CLIENT_SECRET: "secret"}
  }')" || return 1

  show_record aws-main || return 1
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id" ]] || { echo "AWS credentials were not loaded"; return 1; }
  [[ "${CLOUD_ENV_TYPE:-}" == "AWS" ]] || { echo "AWS type was not preserved"; return 1; }

  local aws_ps1="$CLOUD_PS1_KEY"

  show_record gcp-main || return 1
  [[ "${GOOGLE_APPLICATION_CREDENTIALS:-}" == "/tmp/gcp.json" ]] || { echo "GCP credentials were not loaded"; return 1; }
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id" ]] || { echo "AWS variables should remain untouched when loading GCP"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"AWS:aws-main"* && "$CLOUD_PS1_KEY" == *"GCP:gcp-main"* ]] || { echo "Prompt marker should include both AWS and GCP"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"DANGER"* ]] || { echo "Danger marker should be visible in prompt"; return 1; }

  show_record aws-next || return 1
  [[ "${AWS_ACCESS_KEY_ID:-}" == "aws-id-2" ]] || { echo "AWS context should be replaced by type"; return 1; }
  [[ "${GOOGLE_APPLICATION_CREDENTIALS:-}" == "/tmp/gcp.json" ]] || { echo "GCP context should remain untouched"; return 1; }
  [[ "$CLOUD_PS1_KEY" == *"AWS:aws-next"* && "$CLOUD_PS1_KEY" != *"AWS:aws-main"* ]] || { echo "Prompt should replace only the AWS entry"; return 1; }

  set_danger_mode off || return 1
  [[ -z "${CLOUD_ENV_DANGER:-}" && -z "${CLOUD_ENV_MASTER_PASSWORD:-}" ]] || { echo "Danger mode was not disabled"; return 1; }
  [[ "$CLOUD_PS1_KEY" != *"DANGER"* ]] || { echo "Danger marker should be removed"; return 1; }

  set_danger_mode on "$test_pass" >/dev/null 2>&1 && { echo "danger on should reject command-line password"; return 1; }
  enable_danger_mode_with_password "$test_pass" || return 1

  add_record azure-extra --type=Azure --set=AZURE_SUBSCRIPTION_ID=sub-123 --set=AZURE_TENANT_ID=tenant-123 --set=AZURE_CLIENT_ID=client-123 --set=AZURE_CLIENT_SECRET=secret-123 || return 1
  list_records | grep -q '^azure-extra[[:space:]]Azure$' || { echo "Typed record listing failed"; return 1; }

  echo "Self-test passed"
}

if [[ $# -eq 0 ]]; then
  print_usage
  script_exit 1
fi

command="$1"
shift

case "$command" in
  off)
    rmkeys
    script_exit 0
    ;;
  ls)
    parse_storage_option "$@" || script_exit 1
    if [[ ${#PARSED_ARGS[@]} -ne 0 ]]; then
      echo "Usage: $0 ls [--storage <path>]"
      script_exit 1
    fi

    run_with_storage_override "$PARSED_STORAGE_PATH" list_records
    script_exit "$?"
    ;;
  save)
    parse_storage_option "$@" || script_exit 1
    if [[ ${#PARSED_ARGS[@]} -ne 1 ]]; then
      echo "Usage: $0 save [--storage <path>] <filename.json>"
      script_exit 1
    fi

    run_with_storage_override "$PARSED_STORAGE_PATH" save_file "${PARSED_ARGS[0]}"
    script_exit "$?"
    ;;
  add)
    parse_storage_option "$@" || script_exit 1
    if [[ ${#PARSED_ARGS[@]} -eq 0 ]]; then
      echo "Usage: $0 add [--storage <path>] <key-name> [--type=AWS|GCP|Azure] [--key=<val>] [--secret=<val>] [--region=<val>] [--set NAME=VALUE]"
      script_exit 1
    fi

    run_with_storage_override "$PARSED_STORAGE_PATH" add_record "${PARSED_ARGS[@]}"
    script_exit "$?"
    ;;
  set)
    parse_storage_option "$@" || script_exit 1
    if [[ ${#PARSED_ARGS[@]} -ne 1 ]]; then
      echo "Usage: $0 set [--storage <path>] <key-name>"
      script_exit 1
    fi

    run_with_storage_override "$PARSED_STORAGE_PATH" show_record "${PARSED_ARGS[0]}"
    script_exit "$?"
    ;;
  danger)
    if [[ -z "${1:-}" ]]; then
      echo "Usage: $0 danger on|off"
      script_exit 1
    fi

    set_danger_mode "$1" "${2:-}"
    script_exit "$?"
    ;;
  test)
    run_self_test
    script_exit "$?"
    ;;
  *)
    print_usage
    script_exit 1
    ;;
esac

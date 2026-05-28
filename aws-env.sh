#!/bin/bash
# Export AWS access keys from file saved and encrypted with `openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in credentials.json -out credentials.json.enc`

rmkeys() {
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_DEFAULT_REGION
  unset AWS_KEY_NAME
  unset AWS_PS1_KEY
}

if [ -z "$1" ]; then
  echo "Usage: $0 <key-name|ls|off|save <filename.json>|add <KEYNAME> --key=<val> --secret=<val>>"
  return 1 2> /dev/null || exit 1
fi

command=$1
shift

decrypt_file() {
  openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in ~/.aws/credentials.json.enc
}

encrypt_file() {
  local file_content=$1
  echo "$file_content" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -out ~/.aws/credentials.json.enc
}

format_ps1_key() {
  local key_name=$1
  # White text on dark orange background
  echo -e "\e[38;5;15m\e[48;5;166m⬢ $key_name\e[0m"
}

if [[ $command == "off" ]]; then
  rmkeys
  return 0 2> /dev/null || exit 0
fi

if [[ $command == "ls" ]]; then
  FILE_CONTENT=$(decrypt_file)
  [[ $? -ne 0 ]] && { echo "Error decrypting file"; rmkeys; return 0 2> /dev/null || exit 0; }
  echo "$FILE_CONTENT" | jq -r 'keys[]'
  return 0 2> /dev/null || exit 0
fi

if [[ $command == "save" ]]; then
  if [ -z "$1" ]; then
    echo "Usage: $0 save <filename.json>"
    return 1 2> /dev/null || exit 1
  fi

  input_file=$1
  [[ ! -f $input_file ]] && { echo "File $input_file does not exist"; return 1 2> /dev/null || exit 1; }

  file_content=$(cat "$input_file")
  encrypt_file "$file_content"
  [[ $? -eq 0 ]] && echo "Credentials saved and encrypted" || echo "Failed to encrypt credentials"
  return 0 2> /dev/null || exit 0
fi


if [[ $command == "add" ]]; then
  if [ -z "$1" ]; then
    echo "Usage: $0 add <KEYNAME> --key=<val> --secret=<val>"
    return 1 2> /dev/null || exit 1
  fi

  key_name=$1
  shift
  aws_access_key_id=""
  aws_secret_access_key=""
  while [[ "$1" =~ --key=.* ]] || [[ "$1" =~ --secret=.* ]]; do
    case $1 in
      --key=*) aws_access_key_id="${1#--key=}" ;;
      --secret=*) aws_secret_access_key="${1#--secret=}" ;;
    esac
    shift
  done

  if [[ -z $aws_access_key_id || -z $aws_secret_access_key ]]; then
    echo "Both --key and --secret must be provided"
    return 1 2> /dev/null || exit 1
  fi

  FILE_CONTENT=$(decrypt_file)
  [[ $? -ne 0 ]] && { echo "Error decrypting file"; rmkeys; return 0 2> /dev/null || exit 0; }

  updated_content=$(echo "$FILE_CONTENT" | jq --arg key "$key_name" --arg id "$aws_access_key_id" --arg secret "$aws_secret_access_key" \
    '. + {($key): {AWS_ACCESS_KEY_ID: $id, AWS_SECRET_ACCESS_KEY: $secret}}')

  encrypt_file "$updated_content"
  [[ $? -eq 0 ]] && echo "Key $key_name added/updated successfully" || echo "Failed to update key"
  return 0 2> /dev/null || exit 0
fi

FILE_CONTENT=$(decrypt_file)
[[ $? -ne 0 ]] && { echo "Error decrypting file"; rmkeys; return 0 2> /dev/null || exit 0; }

export AWS_ACCESS_KEY_ID=$(echo "$FILE_CONTENT" | jq -r ".$command.AWS_ACCESS_KEY_ID")
export AWS_SECRET_ACCESS_KEY=$(echo "$FILE_CONTENT" | jq -r ".$command.AWS_SECRET_ACCESS_KEY")
[[ "$AWS_ACCESS_KEY_ID" == null || "$AWS_SECRET_ACCESS_KEY" == null ]] && \
  echo "Key not found" && rmkeys && { return 0 2> /dev/null || exit 0; }

export AWS_DEFAULT_REGION=$(echo "$FILE_CONTENT" | jq -r ".$command.AWS_DEFAULT_REGION")
[[ "$AWS_DEFAULT_REGION" == null ]] && export AWS_DEFAULT_REGION=eu-central-1

export AWS_KEY_NAME=$command
export AWS_PS1_KEY=$(format_ps1_key "$command")

echo "AWS environment set for key: $command"

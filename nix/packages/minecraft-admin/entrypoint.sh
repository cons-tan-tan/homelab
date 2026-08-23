# shellcheck shell=bash
set -euo pipefail

readonly config_dir=/config
readonly runtime_dir=/run/minecraft-admin
readonly home_dir=/home/minecraft
readonly authorized_keys_source="${config_dir}/authorized_keys"
readonly authorized_keys="${runtime_dir}/authorized_keys"
readonly host_key_source=/host-key/ssh_host_ed25519_key
readonly host_key="${runtime_dir}/ssh_host_ed25519_key"
readonly sshd_config_source=/etc/ssh/sshd_config
readonly sshd_config="${runtime_dir}/sshd_config"
readonly -a session_environment=(
  MINECRAFT_NAMESPACE
  MINECRAFT_DEPLOYMENT
  MINECRAFT_DATA_DIR
  MINECRAFT_BACKUP_DIR
  MINECRAFT_WAIT_TIMEOUT
  MINECRAFT_POD_SELECTOR
  MINECRAFT_RESTORE_ROOTS
)
declare -a session_environment_settings=()

if [[ ! -s "${authorized_keys_source}" ]]; then
  echo "${authorized_keys_source} is missing or empty" >&2
  exit 1
fi
if [[ ! -s "${host_key_source}" ]]; then
  echo "${host_key_source} is missing or empty" >&2
  exit 1
fi

install -d -m 0755 "${home_dir}"
chown 1000:3000 "${home_dir}"
install -d -m 0755 -o 0 -g 0 "${runtime_dir}"
install -m 0600 "${authorized_keys_source}" "${authorized_keys}"
chown 1000:3000 "${authorized_keys}"
install -m 0600 "${host_key_source}" "${host_key}"
install -m 0644 "${sshd_config_source}" "${sshd_config}"

# sshd creates a clean environment for each login. Forward only the admin
# settings declared by the Pod instead of enabling user-controlled environment
# files or forwarding arbitrary container variables.
for variable in "${session_environment[@]}"; do
  if [[ ! -v "${variable}" ]]; then
    continue
  fi

  value="${!variable}"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "${variable} must not contain a line break" >&2
    exit 1
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  session_environment_settings+=("${variable}=\"${value}\"")
done

if (( ${#session_environment_settings[@]} > 0 )); then
  {
    printf 'SetEnv'
    printf ' %s' "${session_environment_settings[@]}"
    printf '\n'
  } >> "${sshd_config}"
fi

exec "$(command -v sshd)" -D -e -f "${sshd_config}"

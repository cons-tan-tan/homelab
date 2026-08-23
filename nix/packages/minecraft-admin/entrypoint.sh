# shellcheck shell=bash
set -euo pipefail

readonly config_dir=/config
readonly runtime_dir=/run/minecraft-admin
readonly home_dir=/home/minecraft
readonly authorized_keys_source="${config_dir}/authorized_keys"
readonly authorized_keys="${runtime_dir}/authorized_keys"
readonly host_key_source=/host-key/ssh_host_ed25519_key
readonly host_key="${runtime_dir}/ssh_host_ed25519_key"

if [[ ! -s "${authorized_keys_source}" ]]; then
  echo "${authorized_keys_source} is missing or empty" >&2
  exit 1
fi
if [[ ! -s "${host_key_source}" ]]; then
  echo "${host_key_source} is missing or empty" >&2
  exit 1
fi

install -d -m 0755 -o 1000 -g 3000 "${home_dir}"
install -d -m 0755 -o 0 -g 0 "${runtime_dir}"
install -m 0600 "${authorized_keys_source}" "${authorized_keys}"
chown 1000:3000 "${authorized_keys}"
install -m 0600 "${host_key_source}" "${host_key}"

exec "$(command -v sshd)" -D -e -f /etc/ssh/sshd_config

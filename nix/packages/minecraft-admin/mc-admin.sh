# shellcheck shell=bash
set -euo pipefail

main_help() {
  cat <<'EOF'
Usage: mc-admin <command> [options]

Operate a Minecraft server and restore its data from local ZIP backups.

Commands:
  status    Show desired and available server replicas
  stop      Stop the server and wait for its Pods to terminate
  start     Start the server and wait for it to become available
  backups   List available ZIP backups, newest first
  restore   Restore configured data roots from a ZIP backup

Run 'mc-admin <command> --help' for command-specific help.
EOF
}

status_help() {
  cat <<'EOF'
Usage: mc-admin status

Show the configured server Deployment and its desired and available replicas.
EOF
}

stop_help() {
  cat <<'EOF'
Usage: mc-admin stop

Scale the configured server Deployment to zero and wait for all matching Pods
to terminate before returning.
EOF
}

start_help() {
  cat <<'EOF'
Usage: mc-admin start

Scale the configured server Deployment to one replica and wait for it to become
available before returning.
EOF
}

backups_help() {
  cat <<'EOF'
Usage: mc-admin backups

List ZIP files in the configured backup directory, newest first.
EOF
}

restore_help() {
  cat <<'EOF'
Usage: mc-admin restore [--yes] <backup.zip|latest>

Restore the configured data roots from a ZIP file in the backup directory.
The server must first be stopped with 'mc-admin stop'. Current data is retained
under .minecraft-admin-rollbacks, and the server is not started automatically.
Use 'latest' to select the newest ZIP by modification time. Run
'mc-admin backups' to list the available filenames.

Options:
  -y, --yes  Skip the confirmation prompt
  -h, --help Show this help

Examples:
  mc-admin restore latest
  mc-admin restore --yes backup-20260822.zip
EOF
}

if (( $# == 0 )); then
  main_help >&2
  exit 2
fi

readonly subcommand="$1"
shift

case "${subcommand}" in
  --help|-h)
    if (( $# != 0 )); then
      echo "Unexpected argument after ${subcommand}: $1" >&2
      main_help >&2
      exit 2
    fi
    main_help
    exit 0
    ;;
  status|stop|start|backups)
    if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
      "${subcommand}_help"
      exit 0
    fi
    if (( $# != 0 )); then
      echo "mc-admin ${subcommand} does not accept arguments" >&2
      "${subcommand}_help" >&2
      exit 2
    fi
    ;;
  restore)
    if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
      restore_help
      exit 0
    fi
    ;;
  *)
    echo "Unknown command: ${subcommand}" >&2
    main_help >&2
    exit 2
    ;;
esac

readonly deployment="${MINECRAFT_DEPLOYMENT:?MINECRAFT_DEPLOYMENT is required}"
readonly data_dir="${MINECRAFT_DATA_DIR:-/data}"
readonly backup_dir="${MINECRAFT_BACKUP_DIR:-${data_dir}/backups}"
readonly wait_timeout="${MINECRAFT_WAIT_TIMEOUT:-180}"
readonly pod_selector="${MINECRAFT_POD_SELECTOR:?MINECRAFT_POD_SELECTOR is required}"
readonly restore_roots_config="${MINECRAFT_RESTORE_ROOTS:-}"
readonly operation_lock="${data_dir}/.minecraft-admin-operation.lock"
declare -a restore_roots=()

if [[ -n "${MINECRAFT_NAMESPACE:-}" ]]; then
  namespace="${MINECRAFT_NAMESPACE}"
else
  readonly namespace_file=/var/run/secrets/kubernetes.io/serviceaccount/namespace
  if [[ ! -s "${namespace_file}" ]]; then
    echo "${namespace_file} is missing; set MINECRAFT_NAMESPACE explicitly" >&2
    exit 1
  fi
  namespace="$(<"${namespace_file}")"
fi
readonly namespace

with_operation_lock() {
  local lock_fd

  exec {lock_fd}> "${operation_lock}"
  if ! flock --exclusive --wait "${wait_timeout}" "${lock_fd}"; then
    echo "Timed out waiting for another Minecraft admin operation" >&2
    return 1
  fi
  "$@"
}

deployment_field() {
  local jsonpath="$1"
  kubectl --namespace "${namespace}" get deployment "${deployment}" \
    --output "jsonpath=${jsonpath}"
}

desired_replicas() {
  local replicas
  if ! replicas="$(deployment_field '{.spec.replicas}')"; then
    echo "Failed to read desired replicas for ${deployment}" >&2
    return 1
  fi
  if [[ ! "${replicas}" =~ ^[0-9]+$ ]]; then
    echo "Invalid desired replica count for ${deployment}: ${replicas}" >&2
    return 1
  fi
  printf '%s\n' "${replicas:-0}"
}

available_replicas() {
  local replicas
  if ! replicas="$(deployment_field '{.status.availableReplicas}')"; then
    echo "Failed to read available replicas for ${deployment}" >&2
    return 1
  fi
  replicas="${replicas:-0}"
  if [[ ! "${replicas}" =~ ^[0-9]+$ ]]; then
    echo "Invalid available replica count for ${deployment}: ${replicas}" >&2
    return 1
  fi
  printf '%s\n' "${replicas:-0}"
}

server_pods() {
  kubectl --namespace "${namespace}" get pods \
    --selector "${pod_selector}" --output name
}

wait_for_replicas() {
  local expected="$1"
  local deadline=$((SECONDS + wait_timeout))
  local actual

  while (( SECONDS < deadline )); do
    if [[ "${expected}" == 0 ]]; then
      if ! actual="$(deployment_field '{.status.replicas}')"; then
        echo "Failed to read current replicas for ${deployment}" >&2
        return 1
      fi
      actual="${actual:-0}"
      if [[ ! "${actual}" =~ ^[0-9]+$ ]]; then
        echo "Invalid current replica count for ${deployment}: ${actual}" >&2
        return 1
      fi
    else
      actual="$(available_replicas)" || return 1
    fi
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for ${deployment} replicas to become ${expected}" >&2
  return 1
}

wait_for_no_server_pods() {
  local deadline=$((SECONDS + wait_timeout))
  local pods

  while (( SECONDS < deadline )); do
    pods="$(server_pods)" || return 1
    if [[ -z "${pods}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for ${deployment} Pods to terminate" >&2
  return 1
}

assert_server_stopped() {
  local failure_message="$1"
  local desired
  local available
  local pods

  desired="$(desired_replicas)" || return 1
  available="$(available_replicas)" || return 1
  pods="$(server_pods)" || return 1
  if [[ "${desired}" != 0 || "${available}" != 0 || -n "${pods}" ]]; then
    echo "${failure_message}" >&2
    return 1
  fi
}

status() {
  local desired
  local available

  desired="$(desired_replicas)" || return 1
  available="$(available_replicas)" || return 1
  printf 'Deployment: %s/%s\n' "${namespace}" "${deployment}"
  printf 'Desired replicas: %s\n' "${desired}"
  printf 'Available replicas: %s\n' "${available}"
}

stop_server() {
  local desired

  desired="$(desired_replicas)" || return 1
  if [[ "${desired}" == 0 ]]; then
    echo "${deployment} is already stopped"
  else
    kubectl --namespace "${namespace}" scale deployment "${deployment}" --replicas 0
  fi
  wait_for_replicas 0
  wait_for_no_server_pods
  echo "${deployment} is stopped"
}

start_server() {
  local desired

  desired="$(desired_replicas)" || return 1
  if [[ "${desired}" == 1 ]]; then
    echo "${deployment} is already configured for one replica"
  else
    kubectl --namespace "${namespace}" scale deployment "${deployment}" --replicas 1
  fi
  wait_for_replicas 1
  echo "${deployment} is available"
}

list_backups() {
  if [[ ! -d "${backup_dir}" ]]; then
    echo "Backup directory ${backup_dir} does not exist" >&2
    return 1
  fi

  find "${backup_dir}" -maxdepth 1 -type f -name '*.zip' \
    -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' | sort --reverse
}

newest_backup() {
  find "${backup_dir}" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %f\n' \
    | sort --numeric-sort --reverse \
    | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }'
}

parse_restore_roots() {
  local root
  local -A seen=()

  if [[ -z "${restore_roots_config}" ]]; then
    echo 'MINECRAFT_RESTORE_ROOTS is required for mc-admin restore' >&2
    return 1
  fi
  read -r -a restore_roots <<< "${restore_roots_config}"
  if (( ${#restore_roots[@]} == 0 )); then
    echo 'MINECRAFT_RESTORE_ROOTS must contain at least one root' >&2
    return 1
  fi
  for root in "${restore_roots[@]}"; do
    if [[ ! "${root}" =~ ^[A-Za-z0-9._-]+$ || "${root}" == . || "${root}" == .. ]]; then
      echo "Invalid restore root: ${root}" >&2
      return 1
    fi
    if [[ -n "${seen[${root}]:-}" ]]; then
      echo "Duplicate restore root: ${root}" >&2
      return 1
    fi
    seen["${root}"]=1
  done
}

validate_archive_entries() {
  local archive="$1"
  local entries_file="$2"
  local metadata_file="$3"
  local entry
  local root
  local -A expected=()
  local -A seen=()

  for root in "${restore_roots[@]}"; do
    expected["${root}"]=1
  done

  unzip -Z -l "${archive}" > "${metadata_file}"
  if awk '$1 ~ /^l/ { found = 1 } END { exit !found }' "${metadata_file}"; then
    echo 'Archive contains a symbolic link' >&2
    return 1
  fi

  unzip -Z1 "${archive}" > "${entries_file}"
  while IFS= read -r entry; do
    if [[ -z "${entry}" ]]; then
      echo "Archive contains an empty entry" >&2
      return 1
    fi
    case "${entry}" in
      /*|*\\*|..|../*|*/../*|*/..)
        echo "Archive contains an unsafe path: ${entry}" >&2
        return 1
        ;;
      *)
        root="${entry%%/*}"
        if [[ ! "${root}" =~ ^[A-Za-z0-9._-]+$ ]]; then
          echo "Archive contains an invalid root: ${entry}" >&2
          return 1
        fi
        if [[ -z "${expected[${root}]:-}" ]]; then
          echo "Archive contains an unexpected root: ${entry}" >&2
          return 1
        fi
        seen["${root}"]=1
        ;;
    esac
  done < "${entries_file}"

  for root in "${restore_roots[@]}"; do
    if [[ -z "${seen[${root}]:-}" ]]; then
      echo "Archive must contain ${root}/" >&2
      return 1
    fi
  done
}

restore_backup() (
  local assume_yes=false
  local requested_backup=''
  local archive
  local archive_fd
  local archive_fd_path
  local archive_identity
  local archive_name
  local archive_snapshot
  local staging_dir
  local rollback_dir
  local entries_file
  local metadata_file
  local root
  local timestamp
  local -a installed_roots=()
  local -a moved_roots=()

  staging_dir=''
  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_restore() {
    [[ -z "${staging_dir}" ]] || rm -rf -- "${staging_dir}"
  }
  trap cleanup_restore EXIT

  while (( $# > 0 )); do
    case "$1" in
      --yes|-y)
        assume_yes=true
        ;;
      --help|-h)
        echo "$1 cannot be combined with other arguments" >&2
        restore_help >&2
        return 2
        ;;
      -* )
        echo "Unknown option: $1" >&2
        restore_help >&2
        return 2
        ;;
      *)
        if [[ -n "${requested_backup}" ]]; then
          echo 'Only one backup may be specified' >&2
          return 2
        fi
        requested_backup="$1"
        ;;
    esac
    shift
  done

  if [[ -z "${requested_backup}" ]]; then
    restore_help >&2
    return 2
  fi
  parse_restore_roots
  assert_server_stopped \
    "${deployment} must be stopped with mc-admin stop before restoring a backup" || return 1

  if [[ "${requested_backup}" == latest ]]; then
    requested_backup="$(newest_backup)"
    if [[ -z "${requested_backup}" ]]; then
      echo "No ZIP backups found in ${backup_dir}" >&2
      return 1
    fi
  fi
  if [[ "${requested_backup}" == */* || "${requested_backup}" != *.zip ]]; then
    echo 'Specify a ZIP filename from the backup directory, not a path' >&2
    return 2
  fi

  archive_name="${requested_backup}"
  archive="${backup_dir}/${archive_name}"
  if [[ ! -f "${archive}" || -L "${archive}" ]]; then
    echo "Backup ${archive_name} is not a regular file" >&2
    return 1
  fi

  archive_identity="$(stat --format '%d:%i' -- "${archive}")"
  exec {archive_fd}< "${archive}"
  archive_fd_path="/proc/self/fd/${archive_fd}"
  if [[ "$(stat --dereference --format '%d:%i' -- "${archive_fd_path}")" != "${archive_identity}" ]]; then
    echo "Backup ${archive_name} changed while being opened" >&2
    return 1
  fi

  staging_dir="$(mktemp -d "${data_dir}/.minecraft-admin-restore.XXXXXX")"
  archive_snapshot="${staging_dir}/.archive.zip"
  # The backup producer may still have the source open. Validate and extract a
  # stable copy so later writes cannot change what is being restored.
  cp --reflink=auto -- "${archive_fd_path}" "${archive_snapshot}"
  entries_file="${staging_dir}/.archive-entries"
  metadata_file="${staging_dir}/.archive-metadata"
  echo "Testing ${archive_name}"
  unzip -tqq "${archive_snapshot}"
  validate_archive_entries "${archive_snapshot}" "${entries_file}" "${metadata_file}"

  if [[ "${assume_yes}" != true ]]; then
    printf 'Replace %s with %s? [y/N] ' "${restore_roots[*]}" "${archive_name}"
    read -r confirmation
    if [[ "${confirmation}" != y && "${confirmation}" != Y ]]; then
      echo 'Restore cancelled'
      return 1
    fi
  fi

  unzip -q "${archive_snapshot}" -d "${staging_dir}"
  for root in "${restore_roots[@]}"; do
    if [[ ! -d "${staging_dir}/${root}" || -L "${staging_dir}/${root}" ]]; then
      echo "Validated root ${root}/ was not extracted as a directory" >&2
      return 1
    fi
  done

  # The server may have been changed outside these helpers while the archive was
  # being checked and extracted. Never switch live world data in that state.
  assert_server_stopped \
    "${deployment} was started while preparing the restore; refusing to continue" || return 1

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${data_dir}/.minecraft-admin-rollbacks"
  rollback_dir="$(mktemp -d "${data_dir}/.minecraft-admin-rollbacks/${timestamp}.XXXXXX")"

  restore_previous_data() {
    local rollback_root

    for rollback_root in "${installed_roots[@]}"; do
      [[ ! -e "${data_dir}/${rollback_root}" ]] \
        || mv "${data_dir}/${rollback_root}" "${staging_dir}/${rollback_root}"
    done
    for rollback_root in "${moved_roots[@]}"; do
      [[ ! -e "${rollback_dir}/${rollback_root}" ]] \
        || mv "${rollback_dir}/${rollback_root}" "${data_dir}/${rollback_root}"
    done
  }

  for root in "${restore_roots[@]}"; do
    if [[ -e "${data_dir}/${root}" ]]; then
      if ! mv "${data_dir}/${root}" "${rollback_dir}/${root}"; then
        restore_previous_data
        return 1
      fi
      moved_roots+=("${root}")
    fi
  done

  for root in "${restore_roots[@]}"; do
    if ! mv "${staging_dir}/${root}" "${data_dir}/${root}"; then
      restore_previous_data
      return 1
    fi
    installed_roots+=("${root}")
  done

  echo "Restored ${archive_name}"
  echo "Previous data is retained at ${rollback_dir}"
  echo 'Run mc-admin start after inspecting the restored files.'
)

case "${subcommand}" in
  status) status ;;
  stop) with_operation_lock stop_server ;;
  start) with_operation_lock start_server ;;
  backups) list_backups ;;
  restore) with_operation_lock restore_backup "$@" ;;
esac

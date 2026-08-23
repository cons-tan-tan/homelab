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
  rollback  List, apply, or delete retained data states

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
available before returning. Refuse to start while an interrupted restore or
rollback requires manual recovery.
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

rollback_help() {
  cat <<'EOF'
Usage: mc-admin rollback <command> [options]

Manage data retained before a restore or rollback.

Commands:
  list    List rollback IDs, newest first
  apply   Replace current data with a rollback
  delete  Permanently delete a rollback

Run 'mc-admin rollback <command> --help' for command-specific help.
EOF
}

rollback_list_help() {
  cat <<'EOF'
Usage: mc-admin rollback list

List rollback IDs, status, sizes, and retained data roots, newest first.
INCOMPLETE indicates an interrupted operation. INVALID indicates missing or
unsafe metadata. Neither status can be applied.
EOF
}

rollback_apply_help() {
  cat <<'EOF'
Usage: mc-admin rollback apply [--yes] <id|latest>

Replace the configured data roots with a rollback. The server must first be
stopped with 'mc-admin stop'. The current data is retained as a new rollback,
and the server is not started automatically.

Use 'latest' to select the newest rollback.

Options:
  -y, --yes  Skip the confirmation prompt
  -h, --help Show this help
EOF
}

rollback_delete_help() {
  cat <<'EOF'
Usage: mc-admin rollback delete [--yes] <id>

Permanently delete one rollback. Run 'mc-admin rollback list' to find its ID.

Options:
  -y, --yes  Skip the confirmation prompt
  -h, --help Show this help
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
  rollback)
    if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
      rollback_help
      exit 0
    fi
    if (( $# == 2 )) && [[ "$2" == --help || "$2" == -h ]]; then
      case "$1" in
        list|apply|delete)
          "rollback_${1}_help"
          exit 0
          ;;
      esac
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
readonly rollback_root="${data_dir}/.minecraft-admin-rollbacks"
readonly rollback_incomplete_marker=.incomplete
readonly rollback_roots_manifest=.roots
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

  assert_no_incomplete_data_operations
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
    echo 'MINECRAFT_RESTORE_ROOTS is required for restore and rollback operations' >&2
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
    case "${root}" in
      .roots|.incomplete|.minecraft-admin-*)
        echo "Reserved restore root: ${root}" >&2
        return 1
        ;;
    esac
    if [[ -n "${seen[${root}]:-}" ]]; then
      echo "Duplicate restore root: ${root}" >&2
      return 1
    fi
    seen["${root}"]=1
  done
}

valid_rollback_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]
}

validate_rollback_root() {
  if [[ -e "${rollback_root}" || -L "${rollback_root}" ]] \
    && [[ ! -d "${rollback_root}" || -L "${rollback_root}" ]]; then
    echo "Rollback root is not a directory: ${rollback_root}" >&2
    return 1
  fi
}

assert_no_incomplete_data_operations() {
  local incomplete_path=''

  validate_rollback_root
  if [[ -d "${rollback_root}" ]]; then
    incomplete_path="$(
      find "${rollback_root}" -mindepth 2 -maxdepth 2 \
        -name "${rollback_incomplete_marker}" -print -quit
    )"
  fi
  if [[ -z "${incomplete_path}" ]]; then
    incomplete_path="$(
      find "${data_dir}" -mindepth 1 -maxdepth 1 \
        -name '.minecraft-admin-restore.*' -print -quit
    )"
  fi
  if [[ -n "${incomplete_path}" ]]; then
    echo "Refusing to start while an incomplete data operation exists: ${incomplete_path}" >&2
    echo 'Inspect the retained and live data before removing the incomplete operation.' >&2
    return 1
  fi
}

create_rollback_dir() {
  local rollback_dir
  local timestamp

  validate_rollback_root
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p -- "${rollback_root}"
  rollback_dir="$(mktemp -d "${rollback_root}/${timestamp}.XXXXXX")"
  if ! touch -- "${rollback_dir}/${rollback_incomplete_marker}"; then
    rmdir -- "${rollback_dir}"
    return 1
  fi
  if ! printf '%s\n' "${restore_roots[@]}" > "${rollback_dir}/${rollback_roots_manifest}"; then
    rm -- "${rollback_dir}/${rollback_incomplete_marker}"
    rmdir -- "${rollback_dir}"
    return 1
  fi
  printf '%s\n' "${rollback_dir}"
}

finalize_rollback_dir() {
  local rollback_dir="$1"
  local marker="${rollback_dir}/${rollback_incomplete_marker}"

  if [[ ! -f "${marker}" || -L "${marker}" ]]; then
    echo "Rollback transaction marker is missing: ${rollback_dir##*/}" >&2
    return 1
  fi
  rm -- "${marker}"
}

rollback_ids() {
  local id

  validate_rollback_root
  [[ -d "${rollback_root}" ]] || return 0
  while IFS= read -r id; do
    valid_rollback_id "${id}" || continue
    printf '%s\n' "${id}"
  done < <(
    find "${rollback_root}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | sort --reverse
  )
}

complete_rollback_ids() {
  local id
  local marker
  local manifest

  while IFS= read -r id; do
    marker="${rollback_root}/${id}/${rollback_incomplete_marker}"
    manifest="${rollback_root}/${id}/${rollback_roots_manifest}"
    if [[ ! -e "${marker}" && ! -L "${marker}" \
      && -f "${manifest}" && ! -L "${manifest}" ]]; then
      printf '%s\n' "${id}"
    fi
  done < <(rollback_ids)
}

newest_rollback_id() {
  complete_rollback_ids | awk 'NR == 1 { print; exit }'
}

resolve_rollback_dir() {
  local requested_id="$1"

  validate_rollback_root
  if [[ "${requested_id}" == latest ]]; then
    requested_id="$(newest_rollback_id)"
    if [[ -z "${requested_id}" ]]; then
      echo "No rollbacks found in ${rollback_root}" >&2
      return 1
    fi
  fi
  if ! valid_rollback_id "${requested_id}"; then
    echo "Invalid rollback ID: ${requested_id}" >&2
    return 2
  fi
  if [[ ! -d "${rollback_root}/${requested_id}" || -L "${rollback_root}/${requested_id}" ]]; then
    echo "Rollback does not exist: ${requested_id}" >&2
    return 1
  fi
  printf '%s\n' "${rollback_root}/${requested_id}"
}

validate_live_roots() {
  local root

  for root in "${restore_roots[@]}"; do
    if [[ -e "${data_dir}/${root}" || -L "${data_dir}/${root}" ]] \
      && [[ ! -d "${data_dir}/${root}" || -L "${data_dir}/${root}" ]]; then
      echo "Current data root is not a directory: ${root}" >&2
      return 1
    fi
  done
}

validate_rollback_dir() {
  local rollback_dir="$1"
  local entry
  local entry_name
  local entries_file
  local index
  local root
  local valid_entry
  local validation_failed=false
  local -a saved_roots=()

  if [[ -e "${rollback_dir}/${rollback_incomplete_marker}" \
    || -L "${rollback_dir}/${rollback_incomplete_marker}" ]]; then
    echo "Rollback transaction is incomplete: ${rollback_dir##*/}" >&2
    return 1
  fi
  if [[ ! -f "${rollback_dir}/${rollback_roots_manifest}" \
    || -L "${rollback_dir}/${rollback_roots_manifest}" ]]; then
    echo "Rollback roots manifest is missing: ${rollback_dir##*/}" >&2
    return 1
  fi
  mapfile -t saved_roots < "${rollback_dir}/${rollback_roots_manifest}"
  if (( ${#saved_roots[@]} != ${#restore_roots[@]} )); then
    echo "Rollback roots do not match MINECRAFT_RESTORE_ROOTS: ${rollback_dir##*/}" >&2
    return 1
  fi
  for index in "${!restore_roots[@]}"; do
    if [[ "${saved_roots[${index}]}" != "${restore_roots[${index}]}" ]]; then
      echo "Rollback roots do not match MINECRAFT_RESTORE_ROOTS: ${rollback_dir##*/}" >&2
      return 1
    fi
  done
  entries_file="$(mktemp /tmp/mc-admin-rollback-entries.XXXXXX)"
  if ! find "${rollback_dir}" -mindepth 1 -maxdepth 1 -print0 > "${entries_file}"; then
    rm -- "${entries_file}"
    echo "Failed to read rollback: ${rollback_dir##*/}" >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    entry_name="${entry##*/}"
    if [[ "${entry_name}" == "${rollback_roots_manifest}" ]]; then
      continue
    fi
    valid_entry=false
    for root in "${restore_roots[@]}"; do
      if [[ "${entry_name}" == "${root}" ]]; then
        valid_entry=true
        break
      fi
    done
    if [[ "${valid_entry}" != true ]]; then
      echo "Rollback contains an unexpected root: ${entry_name}" >&2
      validation_failed=true
      break
    fi
    if [[ ! -d "${entry}" || -L "${entry}" ]]; then
      echo "Rollback root is not a directory: ${entry_name}" >&2
      validation_failed=true
      break
    fi
  done < "${entries_file}"
  rm -- "${entries_file}"
  [[ "${validation_failed}" != true ]]
}

list_rollbacks() {
  local id
  local entries
  local rollback_dir
  local size
  local status
  local found=false

  validate_rollback_root
  printf '%-24s %10s %8s  %s\n' ID STATUS SIZE ROOTS
  while IFS= read -r id; do
    found=true
    rollback_dir="${rollback_root}/${id}"
    status=READY
    if [[ -e "${rollback_dir}/${rollback_incomplete_marker}" \
      || -L "${rollback_dir}/${rollback_incomplete_marker}" ]]; then
      status=INCOMPLETE
    elif [[ ! -f "${rollback_dir}/${rollback_roots_manifest}" \
      || -L "${rollback_dir}/${rollback_roots_manifest}" ]]; then
      status=INVALID
    fi
    size="$(du -sh -- "${rollback_dir}" | awk '{ print $1 }')"
    entries="$(
      find "${rollback_dir}" -mindepth 1 -maxdepth 1 \
        ! -name "${rollback_incomplete_marker}" \
        ! -name "${rollback_roots_manifest}" -printf '%f\n' \
        | sort | paste -sd ' ' -
    )"
    printf '%-24s %10s %8s  %s\n' "${id}" "${status}" "${size}" "${entries:--}"
  done < <(rollback_ids)
  if [[ "${found}" != true ]]; then
    echo 'No rollbacks found'
  fi
}

apply_rollback() (
  local assume_yes=false
  local requested_id=''
  local rollback_dir
  local rollback_id
  local replacement_dir=''
  local root
  local committed=false
  local transaction_active=false
  local -a installed_roots=()
  local -a moved_roots=()

  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  restore_pre_apply_data() {
    local recovery_failed=false
    local rollback_root_name

    for rollback_root_name in "${installed_roots[@]}"; do
      if [[ -e "${data_dir}/${rollback_root_name}" \
        || -L "${data_dir}/${rollback_root_name}" ]]; then
        if [[ -e "${rollback_dir}/${rollback_root_name}" \
          || -L "${rollback_dir}/${rollback_root_name}" ]] \
          || ! mv -T -- "${data_dir}/${rollback_root_name}" \
            "${rollback_dir}/${rollback_root_name}"; then
          recovery_failed=true
        fi
      fi
    done
    for rollback_root_name in "${moved_roots[@]}"; do
      if [[ -e "${replacement_dir}/${rollback_root_name}" \
        || -L "${replacement_dir}/${rollback_root_name}" ]]; then
        if [[ -e "${data_dir}/${rollback_root_name}" \
          || -L "${data_dir}/${rollback_root_name}" ]] \
          || ! mv -T -- "${replacement_dir}/${rollback_root_name}" \
            "${data_dir}/${rollback_root_name}"; then
          recovery_failed=true
        fi
      fi
    done
    if [[ "${recovery_failed}" != true ]]; then
      if ! rm -f -- "${rollback_dir}/${rollback_incomplete_marker}"; then
        recovery_failed=true
      fi
      if [[ -n "${replacement_dir}" && -d "${replacement_dir}" ]]; then
        if ! rm -f -- "${replacement_dir}/${rollback_incomplete_marker}" \
          "${replacement_dir}/${rollback_roots_manifest}" \
          || ! rmdir -- "${replacement_dir}"; then
          recovery_failed=true
        fi
      fi
    fi
    [[ "${recovery_failed}" != true ]]
  }

  remove_consumed_rollback() {
    if ! rm -- "${rollback_dir}/${rollback_incomplete_marker}" \
      "${rollback_dir}/${rollback_roots_manifest}"; then
      return 1
    fi
    rmdir -- "${rollback_dir}"
  }

  # shellcheck disable=SC2329
  cleanup_apply() {
    local exit_status=$?

    trap - EXIT HUP INT TERM
    if [[ "${transaction_active}" == true ]]; then
      if ! restore_pre_apply_data; then
        echo "Rollback recovery failed; inspect ${rollback_dir} and ${replacement_dir}" >&2
      fi
    elif [[ "${committed}" == true ]]; then
      remove_consumed_rollback || true
    fi
    exit "${exit_status}"
  }
  trap cleanup_apply EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  while (( $# > 0 )); do
    case "$1" in
      --yes|-y)
        assume_yes=true
        ;;
      --help|-h)
        echo "$1 cannot be combined with other arguments" >&2
        rollback_apply_help >&2
        return 2
        ;;
      -* )
        echo "Unknown option: $1" >&2
        rollback_apply_help >&2
        return 2
        ;;
      *)
        if [[ -n "${requested_id}" ]]; then
          echo 'Only one rollback may be specified' >&2
          return 2
        fi
        requested_id="$1"
        ;;
    esac
    shift
  done

  if [[ -z "${requested_id}" ]]; then
    rollback_apply_help >&2
    return 2
  fi
  parse_restore_roots
  rollback_dir="$(resolve_rollback_dir "${requested_id}")"
  rollback_id="${rollback_dir##*/}"
  validate_rollback_dir "${rollback_dir}"
  validate_live_roots
  assert_server_stopped \
    "${deployment} must be stopped with mc-admin stop before applying a rollback" || return 1

  if [[ "${assume_yes}" != true ]]; then
    printf 'Replace %s with rollback %s? [y/N] ' "${restore_roots[*]}" "${rollback_id}"
    read -r confirmation
    if [[ "${confirmation}" != y && "${confirmation}" != Y ]]; then
      echo 'Rollback cancelled'
      return 1
    fi
  fi

  assert_server_stopped \
    "${deployment} was started while preparing the rollback; refusing to continue" || return 1
  validate_rollback_dir "${rollback_dir}"
  validate_live_roots
  touch -- "${rollback_dir}/${rollback_incomplete_marker}"
  transaction_active=true
  replacement_dir="$(create_rollback_dir)"

  for root in "${restore_roots[@]}"; do
    if [[ -e "${data_dir}/${root}" || -L "${data_dir}/${root}" ]]; then
      moved_roots+=("${root}")
      if ! mv -T -- "${data_dir}/${root}" "${replacement_dir}/${root}"; then
        return 1
      fi
    fi
  done

  for root in "${restore_roots[@]}"; do
    if [[ -e "${rollback_dir}/${root}" || -L "${rollback_dir}/${root}" ]]; then
      installed_roots+=("${root}")
      if ! mv -T -- "${rollback_dir}/${root}" "${data_dir}/${root}"; then
        return 1
      fi
    fi
  done
  finalize_rollback_dir "${replacement_dir}"
  committed=true
  transaction_active=false
  if ! remove_consumed_rollback; then
    echo "Applied rollback but failed to remove ${rollback_dir}" >&2
  fi
  committed=false

  echo "Applied rollback ${rollback_id}"
  echo "Previous data is retained at ${replacement_dir}"
  echo 'Run mc-admin start after inspecting the restored files.'
)

delete_rollback() {
  local assume_yes=false
  local requested_id=''
  local rollback_dir
  local rollback_id

  while (( $# > 0 )); do
    case "$1" in
      --yes|-y)
        assume_yes=true
        ;;
      --help|-h)
        echo "$1 cannot be combined with other arguments" >&2
        rollback_delete_help >&2
        return 2
        ;;
      -* )
        echo "Unknown option: $1" >&2
        rollback_delete_help >&2
        return 2
        ;;
      *)
        if [[ -n "${requested_id}" ]]; then
          echo 'Only one rollback may be specified' >&2
          return 2
        fi
        requested_id="$1"
        ;;
    esac
    shift
  done

  if [[ -z "${requested_id}" || "${requested_id}" == latest ]]; then
    echo 'Specify an explicit rollback ID to delete' >&2
    rollback_delete_help >&2
    return 2
  fi
  rollback_dir="$(resolve_rollback_dir "${requested_id}")"
  rollback_id="${rollback_dir##*/}"

  if [[ "${assume_yes}" != true ]]; then
    printf 'Permanently delete rollback %s? [y/N] ' "${rollback_id}"
    read -r confirmation
    if [[ "${confirmation}" != y && "${confirmation}" != Y ]]; then
      echo 'Delete cancelled'
      return 1
    fi
  fi

  rm -rf -- "${rollback_dir}"
  echo "Deleted rollback ${rollback_id}"
}

rollback_command() {
  local action

  if (( $# == 0 )); then
    rollback_help >&2
    return 2
  fi
  action="$1"
  shift
  case "${action}" in
    list)
      if (( $# != 0 )); then
        echo 'mc-admin rollback list does not accept arguments' >&2
        rollback_list_help >&2
        return 2
      fi
      list_rollbacks
      ;;
    apply) apply_rollback "$@" ;;
    delete) delete_rollback "$@" ;;
    *)
      echo "Unknown rollback command: ${action}" >&2
      rollback_help >&2
      return 2
      ;;
  esac
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
  local staging_dir=''
  local rollback_dir=''
  local entries_file
  local metadata_file
  local root
  local transaction_active=false
  local -a installed_roots=()
  local -a moved_roots=()

  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  restore_previous_data() {
    local recovery_failed=false
    local rollback_root_name

    for rollback_root_name in "${installed_roots[@]}"; do
      if [[ -e "${data_dir}/${rollback_root_name}" \
        || -L "${data_dir}/${rollback_root_name}" ]]; then
        if [[ -e "${staging_dir}/${rollback_root_name}" \
          || -L "${staging_dir}/${rollback_root_name}" ]] \
          || ! mv -T -- "${data_dir}/${rollback_root_name}" \
            "${staging_dir}/${rollback_root_name}"; then
          recovery_failed=true
        fi
      fi
    done
    for rollback_root_name in "${moved_roots[@]}"; do
      if [[ -e "${rollback_dir}/${rollback_root_name}" \
        || -L "${rollback_dir}/${rollback_root_name}" ]]; then
        if [[ -e "${data_dir}/${rollback_root_name}" \
          || -L "${data_dir}/${rollback_root_name}" ]] \
          || ! mv -T -- "${rollback_dir}/${rollback_root_name}" \
            "${data_dir}/${rollback_root_name}"; then
          recovery_failed=true
        fi
      fi
    done
    if [[ "${recovery_failed}" != true ]]; then
      if ! rm -f -- "${rollback_dir}/${rollback_incomplete_marker}" \
        "${rollback_dir}/${rollback_roots_manifest}" \
        || ! rmdir -- "${rollback_dir}"; then
        recovery_failed=true
      fi
    fi
    [[ "${recovery_failed}" != true ]]
  }

  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_restore() {
    local exit_status=$?
    local recovery_failed=false

    trap - EXIT HUP INT TERM
    if [[ "${transaction_active}" == true ]] && ! restore_previous_data; then
      recovery_failed=true
      echo "Restore recovery failed; inspect ${rollback_dir} and ${staging_dir}" >&2
    fi
    if [[ "${recovery_failed}" != true && -n "${staging_dir}" ]] \
      && ! rm -rf -- "${staging_dir}"; then
      echo "Failed to remove restore staging directory: ${staging_dir}" >&2
      (( exit_status != 0 )) || exit_status=1
    fi
    [[ "${recovery_failed}" != true ]] || exit_status=1
    exit "${exit_status}"
  }
  trap cleanup_restore EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

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
  validate_live_roots

  rollback_dir="$(create_rollback_dir)"
  transaction_active=true

  for root in "${restore_roots[@]}"; do
    if [[ -e "${data_dir}/${root}" || -L "${data_dir}/${root}" ]]; then
      moved_roots+=("${root}")
      if ! mv -T -- "${data_dir}/${root}" "${rollback_dir}/${root}"; then
        return 1
      fi
    fi
  done

  for root in "${restore_roots[@]}"; do
    installed_roots+=("${root}")
    if ! mv -T -- "${staging_dir}/${root}" "${data_dir}/${root}"; then
      return 1
    fi
  done
  finalize_rollback_dir "${rollback_dir}"
  transaction_active=false

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
  rollback) with_operation_lock rollback_command "$@" ;;
esac

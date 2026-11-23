readonly WAIT_SECONDS=10

log() {
  echo "[pve-power-profile] $*"
}

write_value() {
  local file="$1"
  local value="$2"
  local actual

  if [[ ! -e "$file" ]]; then
    log "missing: $file"
    return 2
  fi

  if [[ ! -w "$file" ]]; then
    log "not writable: $file"
    return 2
  fi

  if ! printf '%s\n' "$value" > "$file"; then
    log "failed to write $file=$value"
    return 1
  fi

  if [[ -r "$file" ]]; then
    actual="$(<"$file")"
    if [[ "$actual" != "$value" ]]; then
      log "read-back mismatch for $file: expected '$value', got '$actual'"
      return 1
    fi
  fi

  log "set $file=$value"
  return 0
}

set_cpu_governor() {
  local desired_governor="powersave"
  local attempt
  local gov_file
  local available_file
  local available
  local applied=0
  local failed=0
  local skipped=0
  local files=()

  for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
    shopt -s nullglob
    files=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor)
    shopt -u nullglob

    if (( ${#files[@]} > 0 )); then
      break
    fi

    sleep 1
  done

  if (( ${#files[@]} == 0 )); then
    log "failed: no CPU scaling_governor files found after ${WAIT_SECONDS}s"
    return 1
  fi

  for gov_file in "${files[@]}"; do
    available_file="$(dirname "$gov_file")/scaling_available_governors"
    available=""
    [[ -r "$available_file" ]] && available="$(<"$available_file")"

    if [[ -n "$available" ]] && ! grep -qw -- "$desired_governor" <<< "$available"; then
      log "skip $gov_file: governor '$desired_governor' not in available list: $available"
      skipped=$((skipped + 1))
      continue
    fi

    if write_value "$gov_file" "$desired_governor"; then
      applied=$((applied + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if (( applied == 0 )); then
    log "failed: CPU governor '$desired_governor' was not applied to any CPU"
    return 1
  fi

  if (( failed > 0 )); then
    log "failed: CPU governor write failed for ${failed} file(s)"
    return 1
  fi

  if (( skipped > 0 )); then
    log "failed: CPU governor '$desired_governor' was unavailable for ${skipped} file(s)"
    return 1
  fi

  log "CPU governor '$desired_governor' applied to ${applied} file(s)"
  return 0
}

set_cpu_epp() {
  local desired_epp="balance_power"
  local fallback_epps=(power balance_performance default performance)
  local attempt
  local epp_file
  local available_file
  local available
  local option
  local chosen
  local applied=0
  local failed=0
  local files=()

  for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
    shopt -s nullglob
    files=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference)
    shopt -u nullglob

    if (( ${#files[@]} > 0 )); then
      break
    fi

    sleep 1
  done

  if (( ${#files[@]} == 0 )); then
    log "failed: no CPU energy_performance_preference files found after ${WAIT_SECONDS}s"
    return 1
  fi

  for epp_file in "${files[@]}"; do
    available_file="$(dirname "$epp_file")/energy_performance_available_preferences"
    if [[ ! -r "$available_file" ]]; then
      log "failed: missing available preferences for $epp_file"
      failed=$((failed + 1))
      continue
    fi

    available="$(<"$available_file")"
    chosen=""

    for option in "$desired_epp" "${fallback_epps[@]}"; do
      if grep -qw -- "$option" <<< "$available"; then
        chosen="$option"
        break
      fi
    done

    if [[ -z "$chosen" ]]; then
      log "failed: none of desired/fallback EPP values are available for $epp_file: $available"
      failed=$((failed + 1))
      continue
    fi

    if write_value "$epp_file" "$chosen"; then
      applied=$((applied + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if (( applied == 0 )); then
    log "failed: CPU EPP 'balance_power' was not applied to any CPU"
    return 1
  fi

  if (( failed > 0 )); then
    log "failed: CPU EPP write/selection failed for ${failed} file(s)"
    return 1
  fi

  log "CPU EPP applied to ${applied} file(s)"
  return 0
}

set_amdgpu_profile() {
  local gpu_path="/sys/bus/pci/drivers/amdgpu/0000:05:00.0"
  local attempt
  local applied=0
  local failed=0

  # amdgpu can appear slightly later during boot on some systems.
  for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
    if [[ -d "$gpu_path" ]]; then
      break
    fi

    sleep 1
  done

  if [[ ! -d "$gpu_path" ]]; then
    log "failed: amdgpu path not found after ${WAIT_SECONDS}s: $gpu_path"
    return 1
  fi

  if write_value "$gpu_path/power_dpm_force_performance_level" "auto"; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
  fi

  if write_value "$gpu_path/power_dpm_state" "balanced"; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
  fi

  if (( applied == 0 )); then
    log "failed: amdgpu power profile was not applied"
    return 1
  fi

  if (( failed > 0 )); then
    log "failed: amdgpu power profile write failed for ${failed} file(s)"
    return 1
  fi

  log "amdgpu power profile applied to ${applied} file(s)"
  return 0
}

main() {
  local rc=0

  log "applying power profile"

  # Set governor first. On amd-pstate-epp, this can make additional EPP choices appear.
  set_cpu_governor || rc=1
  sleep 1
  set_cpu_epp || rc=1
  set_amdgpu_profile || rc=1

  if (( rc != 0 )); then
    log "failed to apply complete power profile"
    return "$rc"
  fi

  log "done"
}

main "$@"

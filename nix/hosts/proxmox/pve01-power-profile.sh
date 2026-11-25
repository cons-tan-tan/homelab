paths_present() {
  local attribute="$1" policy file
  shift
  local -a policies=("$cpuFreq"/policy[0-9]*)
  (( ${#policies[@]} > 0 )) || return 1
  for policy in "${policies[@]}"; do
    [[ -e "$policy/$attribute" ]] || return 1
  done
  for file in "$@"; do
    [[ -e "$file" ]] || return 1
  done
}

wait_for_paths() {
  local deadline=$((SECONDS + 10))
  until paths_present "$@" || (( SECONDS >= deadline )); do
    sleep 1
  done
}

verify_value() {
  local file="$1" expected="$2"
  if [[ ! -r "$file" ]]; then
    echo "Cannot read $file" >&2
    return 1
  fi

  local actual
  actual=$(<"$file")
  if [[ "$actual" != "$expected" ]]; then
    echo "$file: expected '$expected', got '$actual'" >&2
    return 1
  fi
}

set_policy_epp() {
  local policy="$1" preference
  local choices="$policy/energy_performance_available_preferences"
  local target="$policy/energy_performance_preference"
  local -a supported
  if ! read -r -a supported < "$choices"; then
    echo "Cannot read EPP choices for $policy" >&2
    return 1
  fi

  for preference in "${eppPreferences[@]}"; do
    if [[ " ${supported[*]} " == *" $preference "* ]]; then
      if [[ ! -w "$target" ]] || ! printf '%s\n' "$preference" > "$target"; then
        echo "Cannot set $target to '$preference'" >&2
        return 1
      fi
      verify_value "$target" "$preference"
      return
    fi
  done

  echo "No configured EPP is available for $policy: ${supported[*]}" >&2
  return 1
}

main() {
  local result=0 file policy
  local -a policies
  shopt -s nullglob
  wait_for_paths scaling_governor "${!fixedSettings[@]}"
  /usr/bin/systemd-tmpfiles --create "$ruleFile" || result=1
  for file in "${!fixedSettings[@]}"; do
    verify_value "$file" "${fixedSettings[$file]}" || result=1
  done

  # amd-pstate-epp can expose more EPP choices after the governor changes.
  sleep 1
  wait_for_paths energy_performance_preference
  policies=("$cpuFreq"/policy[0-9]*)
  if (( ${#policies[@]} == 0 )); then
    echo "No CPU frequency policies under $cpuFreq" >&2
    return 1
  fi
  for policy in "${policies[@]}"; do
    verify_value "$policy/scaling_governor" "$governor" || result=1
    set_policy_epp "$policy" || result=1
  done
  return "$result"
}

main

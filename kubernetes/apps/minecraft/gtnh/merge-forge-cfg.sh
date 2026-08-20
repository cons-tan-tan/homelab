#!/bin/sh

set -eu

usage() {
  echo "Usage: $0 [--check] BASE_CFG PATCH_CFG" >&2
  exit 64
}

check_only=false
if [ "${1:-}" = "--check" ]; then
  check_only=true
  shift
fi

[ "$#" -eq 2 ] || usage

base_cfg=$1
patch_cfg=$2

[ -f "$base_cfg" ] || {
  echo "forge-cfg: base file does not exist: $base_cfg" >&2
  exit 66
}
[ -f "$patch_cfg" ] || {
  echo "forge-cfg: patch file does not exist: $patch_cfg" >&2
  exit 66
}

run_merge() {
  awk -v check_only="$check_only" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function fail(message) {
      print "forge-cfg: " message > "/dev/stderr"
      failed = 1
      exit 65
    }

    function current_path(    path, i) {
      path = ""
      for (i = 1; i <= depth; i++) {
        path = path (i == 1 ? "" : "/") category[i]
      }
      return path
    }

    function parse_category(line,    value) {
      value = trim(line)
      if (value !~ /\{[[:space:]]*$/) {
        return 0
      }

      sub(/[[:space:]]*\{[[:space:]]*$/, "", value)
      value = trim(value)

      if (value ~ /^"[^"]+"$/) {
        value = substr(value, 2, length(value) - 2)
      } else if (value !~ /^[[:alnum:]_.-]+$/) {
        return 0
      }

      parsed_category = value
      return 1
    }

    function parse_property(line,    value, equals_at, key) {
      value = trim(line)
      if (length(value) < 4 || substr(value, 2, 1) != ":") {
        return 0
      }

      parsed_type = substr(value, 1, 1)
      if (parsed_type !~ /^[BIDS]$/) {
        return 0
      }

      equals_at = index(value, "=")
      if (equals_at == 0) {
        return 0
      }

      key = trim(substr(value, 3, equals_at - 3))
      if (key !~ /^[[:alnum:]_.-]+$/) {
        return 0
      }

      parsed_key = key
      parsed_value = trim(substr(value, equals_at + 1))
      return 1
    }

    function valid_value(type, value) {
      if (type == "B") {
        return value == "true" || value == "false"
      }
      if (type == "I") {
        return value ~ /^[-+]?[0-9]+$/
      }
      if (type == "D") {
        return value ~ /^[-+]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][-+]?[0-9]+)?$/
      }
      return type == "S"
    }

    function leading_space(value,    result) {
      result = value
      sub(/[^[:space:]].*$/, "", result)
      return result
    }

    function trailing_space(value,    result) {
      result = value
      sub(/^.*[^[:space:]]/, "", result)
      return result
    }

    function finish_patch(    i) {
      if (depth != 0) {
        fail("unbalanced category braces in patch " ARGV[1])
      }
      if (patch_count == 0) {
        fail("patch contains no scalar properties: " ARGV[1])
      }
      for (i in category) {
        delete category[i]
      }
      depth = 0
      patch_finished = 1
    }

    FILENAME == ARGV[1] {
      value = trim($0)
      if (value == "" || value ~ /^#/) {
        next
      }

      if (parse_category($0)) {
        depth++
        category[depth] = parsed_category
        next
      }

      if (value ~ /^\}[[:space:]]*$/) {
        if (depth == 0) {
          fail("unexpected closing brace in patch " ARGV[1] " at line " FNR)
        }
        delete category[depth]
        depth--
        next
      }

      if (!parse_property($0)) {
        fail("unsupported patch syntax in " ARGV[1] " at line " FNR ": " value)
      }
      if (!valid_value(parsed_type, parsed_value)) {
        fail("invalid " parsed_type " value for " parsed_key " in " ARGV[1] " at line " FNR)
      }

      path = current_path()
      id = path SUBSEP parsed_key
      if (id in wanted_type) {
        fail("duplicate patch property " path "." parsed_key)
      }

      wanted_type[id] = parsed_type
      wanted_value[id] = parsed_value
      wanted_name[id] = (path == "" ? parsed_key : path "." parsed_key)
      patch_count++
      next
    }

    FILENAME == ARGV[2] {
      if (!patch_finished) {
        finish_patch()
      }

      value = trim($0)
      if (parse_category($0)) {
        depth++
        category[depth] = parsed_category
      } else if (value ~ /^\}[[:space:]]*$/) {
        if (depth == 0) {
          fail("unexpected closing brace in base " ARGV[2] " at line " FNR)
        }
        delete category[depth]
        depth--
      } else if (value ~ /\{[[:space:]]*$/ && value !~ /^#/) {
        fail("unsupported category syntax in base " ARGV[2] " at line " FNR ": " value)
      } else if (parse_property($0)) {
        path = current_path()
        id = path SUBSEP parsed_key
        if (id in wanted_type) {
          seen[id]++
          if (seen[id] > 1) {
            fail("duplicate base property " wanted_name[id])
          }
          if (parsed_type != wanted_type[id]) {
            fail("type mismatch for " wanted_name[id] ": patch=" wanted_type[id] ", base=" parsed_type)
          }
          if (!valid_value(parsed_type, parsed_value)) {
            fail("invalid existing " parsed_type " value for " wanted_name[id] ": " parsed_value)
          }
          if (check_only == "true" && parsed_value != wanted_value[id]) {
            fail("value drift for " wanted_name[id] ": expected=" wanted_value[id] ", actual=" parsed_value)
          }
          if (check_only != "true") {
            equals_at = index($0, "=")
            remainder = substr($0, equals_at + 1)
            $0 = substr($0, 1, equals_at) leading_space(remainder) wanted_value[id] trailing_space(remainder)
          }
        }
      }

      if (check_only != "true") {
        print
      }
    }

    END {
      if (failed) {
        exit 65
      }
      if (!patch_finished) {
        finish_patch()
      }
      if (depth != 0) {
        print "forge-cfg: unbalanced category braces in base " ARGV[2] > "/dev/stderr"
        exit 65
      }
      for (id in wanted_type) {
        if (!(id in seen)) {
          print "forge-cfg: patch target is missing from base: " wanted_name[id] > "/dev/stderr"
          missing = 1
        }
      }
      if (missing) {
        exit 65
      }
    }
  ' "$patch_cfg" "$base_cfg"
}

if [ "$check_only" = true ]; then
  run_merge >/dev/null
  echo "forge-cfg: verified $base_cfg against $patch_cfg"
  exit 0
fi

temporary_cfg=$(mktemp "${base_cfg}.tmp.XXXXXX")
trap 'rm -f "$temporary_cfg"' EXIT HUP INT TERM
cp -p "$base_cfg" "$temporary_cfg"

if run_merge >"$temporary_cfg"; then
  :
else
  status=$?
  exit "$status"
fi

if cmp -s "$base_cfg" "$temporary_cfg"; then
  rm -f "$temporary_cfg"
  echo "forge-cfg: $base_cfg already matches $patch_cfg"
else
  mv -f "$temporary_cfg" "$base_cfg"
  echo "forge-cfg: merged $patch_cfg into $base_cfg"
fi

trap - EXIT HUP INT TERM

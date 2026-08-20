#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
merger="$script_dir/merge-forge-cfg.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

write_file() {
  output=$1
  shift
  printf '%s\n' "$@" >"$output"
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

base="$test_dir/base.cfg"
patch="$test_dir/patch.cfg"
expected="$test_dir/expected.cfg"

write_file "$base" \
  '# Configuration file' \
  '' \
  'world {' \
  '    B:chunk_claiming=false' \
  '    B:chunk_loading=true' \
  '    logging {' \
  '        B:chunk_claiming=false' \
  '    }' \
  '}'
write_file "$patch" \
  'world {' \
  '    B:chunk_claiming=true' \
  '    B:chunk_loading=true' \
  '}'
write_file "$expected" \
  '# Configuration file' \
  '' \
  'world {' \
  '    B:chunk_claiming=true' \
  '    B:chunk_loading=true' \
  '    logging {' \
  '        B:chunk_claiming=false' \
  '    }' \
  '}'

"$merger" "$base" "$patch" >/dev/null
cmp "$base" "$expected"
"$merger" --check "$base" "$patch" >/dev/null
"$merger" "$base" "$patch" >/dev/null
cmp "$base" "$expected"
set -- "$base".tmp.*
if [ -e "$1" ]; then
  echo "temporary file was not cleaned up: $1" >&2
  exit 1
fi

write_file "$base" \
  'world {' \
  '    B:chunk_claiming=false' \
  '    B:chunk_loading=true' \
  '}'
expect_failure "$merger" --check "$base" "$patch"

write_file "$base" \
  'world {' \
  '    B:another_property=false' \
  '}'
cp "$base" "$expected"
expect_failure "$merger" "$base" "$patch"
cmp "$base" "$expected"

write_file "$base" \
  'world {' \
  '    B:chunk_claiming=false' \
  '    B:chunk_claiming=false' \
  '    B:chunk_loading=true' \
  '}'
cp "$base" "$expected"
expect_failure "$merger" "$base" "$patch"
cmp "$base" "$expected"

write_file "$base" \
  'world {' \
  '    I:chunk_claiming=1' \
  '    B:chunk_loading=true' \
  '}'
expect_failure "$merger" "$base" "$patch"

write_file "$patch" \
  'world {' \
  '    B:chunk_claiming=true' \
  '    B:chunk_claiming=false' \
  '}'
expect_failure "$merger" "$base" "$patch"

write_file "$base" \
  'world {' \
  '    logging {' \
  '        B:enabled=false' \
  '    }' \
  '}'
write_file "$patch" \
  'world {' \
  '    logging {' \
  '        B:enabled=true' \
  '    }' \
  '}'
"$merger" "$base" "$patch" >/dev/null
"$merger" --check "$base" "$patch" >/dev/null

write_file "$patch" \
  'world {' \
  '    B:enabled=not-a-boolean' \
  '}'
expect_failure "$merger" "$base" "$patch"

echo "merge-forge-cfg tests passed"

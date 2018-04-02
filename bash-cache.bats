#!/usr/bin/env bats
#
# Integration tests of overall caching behavior. See bc-unit-tests.bats for per-function tests.
#
# Note most of these tests assumes the test takes less than 10 seconds (the background-refresh time)
# ideally we could configure the stale cache threshold for the test so this is less brittle.

# Ensure each test has its own cache
BC_TESTONLY_CACHE_DIR=$(mktemp -d "$BATS_TMPDIR/bash-cache-XXXXXXXXXX")
source $BATS_TEST_DIRNAME/bash-cache.sh

# Similar to Bats' run function, but invokes the given command in the same
# shell rather than a subshell. Bats' is MIT licensed.
run_sameshell() {
  local e E T oldIFS
  [[ ! "$-" =~ e ]] || e=1
  [[ ! "$-" =~ E ]] || E=1
  [[ ! "$-" =~ T ]] || T=1
  set +e
  set +E
  set +T
  "$@" > "$BATS_TMPDIR/bats$$.output" 2> "$BATS_TMPDIR/bats$$.error"
  status="$?"
  stdout=$(cat "$BATS_TMPDIR/bats$$.output")
  stderr=$(cat "$BATS_TMPDIR/bats$$.error")
  oldIFS=$IFS
  IFS=$'\n' lines=($output)
  [ -z "$e" ] || set -e
  [ -z "$E" ] || set -E
  [ -z "$T" ] || set -T
  IFS=$oldIFS
}

# Paired with run_sameshell, checks that the command behaved as expected.
expected() {
  local exp_status=${1?:status}
  local exp_stdout=${2?:stdout}
  local exp_stderr=${3?:stderr}

  if (( status != exp_status )); then
    echo "Expected status: $exp_status - was $status"
    return 1
  fi
  if [[ "$exp_stdout" != "$stdout" ]]; then
    printf "Expected stdout:\n%s\nWas:\n%s\n" "$exp_stdout" "$stdout"
    return 2
  fi
  if [[ "$exp_stderr" != "$stderr" ]]; then
    printf "Expected stderr:\n%s\nWas:\n%s\n" "$exp_stderr" "$stderr"
    return 3
  fi
}

# Use a file to track the number of invocations of expensive_func in order to support subshells
# Number of lines in the file indicates the number of times it's been called
CALL_COUNT_FILE="$BC_TESTONLY_CACHE_DIR/call_count_file"
touch "$CALL_COUNT_FILE"

expensive_func() {
  # Output the expected new count before actually writing, since there could be a race
  # This way the echo'ed count will never be *higher* than expected (it could be lower)
  echo "$(($(call_count) + 1))"
  echo >> "$CALL_COUNT_FILE" # atomically write one more line to the file

}

call_count() {
  wc -l < "$CALL_COUNT_FILE" || echo 0
}

@test "without cache call count increases every time" {
  expensive_func
  expensive_func
  (( $(call_count) == 2 ))
  expensive_func
  expensive_func
  (( $(call_count) == 4 ))
}

@test "cached" {
  bc::cache expensive_func
  expensive_func
  expensive_func
  expensive_func
  (( $(call_count) == 1 ))
}

@test "caching on and off" {
  bc::cache expensive_func
  expensive_func
  expensive_func
  expensive_func
  (( $(call_count) == 1 ))
  bc::off
  expensive_func
  expensive_func
  (( $(call_count) == 3 ))
  bc::on
  expensive_func
  (( $(call_count) == 3 ))
}


@test "refresh cache in backgound" {
  bc::cache expensive_func
  expensive_func
  # mark whole cache stale
  if touch -A 00 . &> /dev/null; then
    find "$BC_TESTONLY_CACHE_DIR" -exec touch -A -11 {} + # OSX
  else
    find "$BC_TESTONLY_CACHE_DIR" -exec touch -d "11 seconds ago" {} + # linux
  fi

  expensive_func > "$BATS_TMPDIR/call_count"
  output_call_count=$(cat "$BATS_TMPDIR/call_count")
  echo OCC $output_call_count
  (( output_call_count == 1 )) # cached result
  # somehow need to synchronize on the cache being refreshed - just wait for it to update
  for i in {1..2}; do
    echo $(call_count) $i
    if (( $(call_count) == 2 )); then break; fi
    sleep 1
  done
  (( $(call_count) == 2 )) # cache was ultimately refreshed
  expensive_func
  (( $(call_count) == 2 )) # still cached
}

@test "newline-sensitive" {
  sensitive_func() {
    printf foo
    echo bar >&2
  }
  sensitive_func > "$BATS_TMPDIR/exp_out" 2> "$BATS_TMPDIR/exp_err"

  bc::cache sensitive_func
  sensitive_func > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"

  diff "$BATS_TMPDIR/exp_out" "$BATS_TMPDIR/out"
  diff "$BATS_TMPDIR/exp_err" "$BATS_TMPDIR/err"
}

@test "exit status" {
  failing_func() {
    return 10
  }
  bc::cache failing_func

  set +e
  failing_func
  status=$?
  set -e

  (( status == 10 ))
}
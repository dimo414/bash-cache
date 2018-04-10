#!/usr/bin/env bats
#
# Integration tests of overall caching behavior. See bc-unit-tests.bats for per-function tests.
#
# Note most of these tests assumes the test takes less than 10 seconds (the background-refresh time)
# ideally we could configure the stale cache threshold for the test so this is less brittle.

# Ensure each test has its own cache
_BC_TESTONLY_CACHE_DIR=$(mktemp -d "$BATS_TMPDIR/bash-cache-XXXXXXXXXX")
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
CALL_COUNT_FILE=$(mktemp)

expensive_func() {
  # Output the expected new count before actually writing, since there could be a race
  # This way the echo'ed count will never be *higher* than expected (it could be lower)
  echo "$(($(call_count) + 1))"
  echo >> "$CALL_COUNT_FILE" # atomically write one more line to the file
}

call_count() {
  wc -l < "$CALL_COUNT_FILE" || echo 0
}

wait_for_call_count() {
  # somehow need to synchronize on the cache being refreshed - just wait for it to update
  for i in {1..2}; do
    echo $(call_count) $i
    if (( $(call_count) == $1 )); then break; fi
    sleep 1
  done
  (( $(call_count) == $1 )) # cache was ultimately refreshed
}

# mark whole cache stale
stale_cache() {
  : ${1:?number of seconds old}
  if touch -A 00 . &> /dev/null; then
    find "$_BC_TESTONLY_CACHE_DIR" -exec touch -A "-$1" {} + # OSX
  else
    find "$_BC_TESTONLY_CACHE_DIR" -exec touch -d "$1 seconds ago" {} + # linux
  fi
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

@test "cached respects args" {
  bc::cache expensive_func
  expensive_func
  expensive_func a
  (( $(call_count) == 2 ))
  expensive_func a
  (( $(call_count) == 2 ))
}

@test "cached respects env" {
  env_var=foo
  bc::cache expensive_func env_var
  expensive_func
  env_var=bar
  expensive_func
  (( $(call_count) == 2 ))
  expensive_func
  (( $(call_count) == 2 ))
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
  stale_cache 11


  output_call_count=$(expensive_func)
  echo OCC $output_call_count
  (( output_call_count == 1 )) # cached result
  wait_for_call_count 2
  expensive_func
  (( $(call_count) == 2 )) # still cached
}

@test "cleanup stale cache data" {
  bc::cache expensive_func
  expensive_func
  expensive_func a
  expensive_func b

  call_count=$(call_count)
  cached_files=$(find "$_BC_TESTONLY_CACHE_DIR" | wc -l)

  bc::_cleanup # does nothing
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) == cached_files ))

  stale_cache 61
  expensive_func
  while ! bc::_newer_than "$_BC_TESTONLY_CACHE_DIR/cleanup" 60; do :; done
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) < cached_files ))

  stale_cache 61
  bc::_cleanup
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) == 2 ))
}

@test "no debug output" {
  noop_func() { :; }

  bc::cache noop_func
  noop_func > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"

  diff <(:) "$BATS_TMPDIR/out"
  diff <(:) "$BATS_TMPDIR/err"
}

@test "args preserved" {
  args_func() {
    # TODO this fails because of the extra space. Need to figure out why.
    #echo "args[$#]: $*"
    echo "args[$#]:$*"
  }
  bc::cache args_func

  check_same_output() {
    bc::orig::args_func "$@" > "$BATS_TMPDIR/exp_out" 2> "$BATS_TMPDIR/exp_err"
    args_func "$@" > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"
    diff -u "$BATS_TMPDIR/exp_out" "$BATS_TMPDIR/out"
    diff "$BATS_TMPDIR/exp_err" "$BATS_TMPDIR/err"
  }

  check_same_output
  check_same_output 1
  check_same_output "1 2" 3
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

@test "warm cache" {
  bc::cache expensive_func
  bc::warm::expensive_func > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"
  wait_for_call_count 1

  diff /dev/null "$BATS_TMPDIR/out"
  diff /dev/null "$BATS_TMPDIR/err"

  expensive_func
  (( $(call_count) == 1 )) # already cached
}

@test "benchmark" {
  bc::_time() { "$@" &> /dev/null; echo 1234; }
  check_output() {
    diff <(printf 'Original:\t%s\nCold Cache:\t%s\nWarm Cache:\t%s\n' 1234 1234 1234) \
      "$BATS_TMPDIR/out"
    diff /dev/null "$BATS_TMPDIR/err"
  }

  bc::benchmark expensive_func > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"
  ! declare -F bc::orig::expensive_func
  (( $(call_count) == 2 ))
  check_output

  bc::cache expensive_func
  bc::benchmark expensive_func > "$BATS_TMPDIR/out" 2> "$BATS_TMPDIR/err"
  (( $(call_count) == 4 ))
  check_output
}

@test "benchmark uses-args" {
  # writes n lines to the call count file
  multi_expensive_func() {
    echo "args: $*"
    local num=${1:-1}
    while (( num > 0 )); do
      : $(( num-- ))
      echo >> "$CALL_COUNT_FILE"
   done
  }

  multi_expensive_func 2
  (( $(call_count) == 2 ))

  # each benchmark call should trigger 2x writes, for the raw and cold calls
  bc::benchmark multi_expensive_func
  call_count
  (( $(call_count) == 4 ))
  bc::benchmark multi_expensive_func 3
  call_count
  (( $(call_count) == 10 ))
}
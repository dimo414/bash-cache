#!/usr/bin/env bats
#
# Integration tests of overall caching behavior. See bc-unit-tests.bats for per-function tests.
#
# Note most of these tests assumes the test takes less than 10 seconds (the background-refresh time)
# ideally we could configure the stale cache threshold for the test so this is less brittle.

set -u  # Treat unset variables as an error

# Ensure each test has its own cache
TEST_DIR=$(mktemp -d "${BATS_TMPDIR}/bash-cache-XXXXXXXXXX")
_BC_TESTONLY_CACHE_DIR="${TEST_DIR}/cache"
source "${BATS_TEST_DIRNAME}/../bash-cache.sh"

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
  "$@" > "$TEST_DIR/bats$$.output" 2> "$TEST_DIR/bats$$.error"
  status="$?"
  stdout=$(cat "$TEST_DIR/bats$$.output")
  stderr=$(cat "$TEST_DIR/bats$$.error")
  [ -z "$e" ] || set -e
  [ -z "$E" ] || set -E
  [ -z "$T" ] || set -T
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
  # This way the echo'ed count shouldn't be *higher* than expected (it could be lower)
  echo "$(($(call_count) + 1))"
  echo >> "$CALL_COUNT_FILE" # atomically write one more line to the file
}

slow_expensive_func() {
  sleep 1
  expensive_func
}

call_count() {
  wc -l < "$CALL_COUNT_FILE" || echo 0
}

wait_for_call_count() {
  # somehow need to synchronize on the cache being refreshed - just wait for it to update
  local i
  for i in {1..20}; do
    echo "Wait loop ${i}; need:${1}, is:$(call_count)"
    if (( $(call_count) == $1 )); then break; fi
    sleep .1
  done
  (( $(call_count) == $1 )) # cache was ultimately refreshed
}

# mark whole cache stale
stale_cache() {
  local _seconds
  bc::_to_seconds "$1" || return
  if touch -A 00 . &> /dev/null; then
    find "$_BC_TESTONLY_CACHE_DIR" -exec touch -A "-${_seconds}" {} + # OSX
  else
    find "$_BC_TESTONLY_CACHE_DIR" -exec touch -d "${_seconds} seconds ago" {} + # linux
  fi
  bc::_cleanup
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
  bc::cache expensive_func 60s 10s
  expensive_func
  expensive_func
  expensive_func
  (( $(call_count) == 1 ))
}

@test "cached respects args" {
  bc::cache expensive_func 60s 10s
  expensive_func
  expensive_func a
  (( $(call_count) == 2 ))
  expensive_func a
  (( $(call_count) == 2 ))
}

@test "cached respects similar args" {
  bc::cache expensive_func 60s 10s
  expensive_func
  expensive_func a b
  expensive_func 'a b'
  (( $(call_count) == 3 ))
}

@test "cached respects env" {
  env_var=foo
  bc::cache expensive_func 60s 10s env_var
  expensive_func
  env_var=bar
  expensive_func
  (( $(call_count) == 2 ))
  expensive_func
  (( $(call_count) == 2 ))
}

@test "bc::cache catches invalid env" {
  ! bc::cache expensive_func 60s 10s 'env"_var'
  ! bc::cache expensive_func 60s 10s '(echo foo)' # command substitution
}

@test "caching on and off" {
  bc::cache expensive_func 60s 10s
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
  bc::cache expensive_func 60s 10s
  expensive_func
  stale_cache 11s

  output_call_count=$(expensive_func)
  (( output_call_count == 1 )) # cached result
  wait_for_call_count 2
  expensive_func
  (( $(call_count) == 2 )) # still cached
}

@test "differing cache expirations" {
  # TODO it would be nice to improve this test to not need bc::_do_cleanup
  cheap_count=0
  something_cheap() { echo "$(( ++cheap_count ))"; }
  bc::cache expensive_func 2m 1m
  bc::cache something_cheap 30s 10s
  expensive_func
  something_cheap
  stale_cache 31s
  bc::_do_cleanup # force cleanup

  expensive_func
  (( $(call_count) == 1 )) # cached result
  something_cheap
  (( cheap_count == 2 )) # not cached

  stale_cache 121s # now cache is invalidated
  bc::_do_cleanup # force cleanup
  expensive_func
  (( $(call_count) == 2 ))
  something_cheap
  (( cheap_count == 3 )) # not cached
}

@test "concurrent calls race" {
    bc::cache slow_expensive_func 60s 10s

    slow_expensive_func &
    slow_expensive_func &
    wait
    (( $(call_count) == 2 ))
    slow_expensive_func
    (( $(call_count) == 2 )) # still cached
}

@test "concurrent locked calls respect mutex" {
    (( BASH_VERSINFO[0] >= 4 )) || skip "locked_cache depends on Bash 4.1 features"
    command -v flock &>/dev/null || skip "locked_cache depends on flock"
    bc::locked_cache slow_expensive_func

    slow_expensive_func &
    slow_expensive_func &
    wait
    (( $(call_count) == 1 ))
    slow_expensive_func
    (( $(call_count) == 1 )) # still cached
}

@test "cleanup stale cache data" {
  bc::cache expensive_func 60s 10s
  expensive_func
  expensive_func a
  expensive_func b

  cached_files=$(find "$_BC_TESTONLY_CACHE_DIR" | wc -l)

  bc::_cleanup # does nothing
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) == cached_files ))

  stale_cache 61s
  expensive_func
  while ! bc::_newer_than "$_BC_TESTONLY_CACHE_DIR/cleanup" 60; do :; done
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) < cached_files ))

  stale_cache 61s
  # bc/, bc/cleanup, bc/data, and bc/data/60
  (( $(find "$_BC_TESTONLY_CACHE_DIR" | wc -l) == 4 ))
}

@test "cleanup frequency adjusts" {
  bc::cache expensive_func 10s 0s
  expensive_func
  stale_cache 11s
  expensive_func
  (( $(call_count) == 2 )) # cache evicted after 11s instead of 60s
}

@test "no debug output" {
  noop_func() { :; }

  (
    bc::cache noop_func 60s 10s
    noop_func
  ) > "$TEST_DIR/out" 2> "$TEST_DIR/err"

  diff -u /dev/null "$TEST_DIR/out"
  diff -u /dev/null "$TEST_DIR/err"

  (
    bc::memoize noop_func
    noop_func
  ) > "$TEST_DIR/out" 2> "$TEST_DIR/err"

  diff -u /dev/null "$TEST_DIR/out"
  diff -u /dev/null "$TEST_DIR/err"
}

@test "args preserved" {
  args_func() {
    echo "args[$#]: $*"
  }
  bc::cache args_func 60s 10s

  check_same_output() {
    bc::orig::args_func "$@" > "$TEST_DIR/exp_out" 2> "$TEST_DIR/exp_err"
    args_func "$@" > "$TEST_DIR/out" 2> "$TEST_DIR/err"
    diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out"
    diff -u "$TEST_DIR/exp_err" "$TEST_DIR/err"
  }

  check_same_output
  check_same_output 1
  check_same_output "1 2" 3
}

@test "file descriptors respected" {
  fd_test() {
    cat <&3
    cat <&4
    cat <&5
    echo err >&2
  }

  # '<<<... x<&0' writes ... to x instead of stdin
  # See https://mywiki.wooledge.org/FileDescriptor#Juggling_FDs
  fd_test <<<333 3<&0 <<<444 4<&0 <<<555 5<&0 > "$TEST_DIR/exp_out" 2> "$TEST_DIR/exp_err"

  bc::cache fd_test 60s 10s
  fd_test <<<333 3<&0 <<<444 4<&0 <<<555 5<&0 > "$TEST_DIR/out" 2> "$TEST_DIR/err"

  diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out"
  diff -u "$TEST_DIR/exp_err" "$TEST_DIR/err"
}

@test "sensitive output: terminal newlines" {
  sensitive_func() {
    printf 'foo'
    printf 'bar\n' >&2
  }
  sensitive_func > "$TEST_DIR/exp_out" 2> "$TEST_DIR/exp_err"

  bc::cache sensitive_func 60s 10s
  sensitive_func > "$TEST_DIR/out" 2> "$TEST_DIR/err"

  diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out"
  diff -u "$TEST_DIR/exp_err" "$TEST_DIR/err"
}

@test "sensitive output: NULs" {
  sensitive_func() {
    printf 'foo\0bar'
    printf 'bar\0baz\n' >&2
  }
  sensitive_func > "$TEST_DIR/exp_out" 2> "$TEST_DIR/exp_err"

  bc::cache sensitive_func 60s 10s
  sensitive_func > "$TEST_DIR/out" 2> "$TEST_DIR/err"

  diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out"
  diff -u "$TEST_DIR/exp_err" "$TEST_DIR/err"
}

@test "exit status" {
  failing_func() {
    return 10
  }
  bc::cache failing_func 60s 10s

  set +e
  failing_func
  status=$?
  set -e

  (( status == 10 ))
}

@test "warm cache" {
  bc::cache expensive_func 60s 10s
  bc::warm::expensive_func > "$TEST_DIR/out" 2> "$TEST_DIR/err"
  wait_for_call_count 1

  diff -u /dev/null "$TEST_DIR/out"
  diff -u /dev/null "$TEST_DIR/err"

  expensive_func
  (( $(call_count) == 1 )) # already cached
}

@test "force cache" {
  bc::cache expensive_func 60s 10s
  expensive_func
  expensive_func
  (( $(call_count) == 1 )) # cached

  bc::force::expensive_func
  (( $(call_count) == 2 )) # invalidated
}

@test "benchmark" {
  bc::_time() { "$@" &> /dev/null; echo 1234; }
  check_output() {
    diff -u <(printf 'Benchmarking expensive_func with bc::cache\nOriginal:\t%s\nCold Cache:\t%s\nWarm Cache:\t%s\n' 1234 1234 1234) \
      "$TEST_DIR/out"
    diff -u /dev/null "$TEST_DIR/err"
  }

  bc::benchmark expensive_func > "$TEST_DIR/out" 2> "$TEST_DIR/err"
  ! declare -F bc::orig::expensive_func
  (( $(call_count) == 2 ))
  check_output

  bc::cache expensive_func 60s 10s
  bc::benchmark expensive_func > "$TEST_DIR/out" 2> "$TEST_DIR/err"
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

@test "memoize" {
  bc::memoize expensive_func ENV_VAR

  expensive_func
  (( $(call_count) == 1 ))
  expensive_func
  (( $(call_count) == 1 ))

  expensive_func a
  (( $(call_count) == 2 ))

  expensive_func a b c
  (( $(call_count) == 3 ))

  expensive_func a b c
  (( $(call_count) == 3 ))

  ENV_VAR=something

  expensive_func a b c
  (( $(call_count) == 4 ))
}

@test "memoize: sensitive output" {
  sensitive_func() {
    printf '%s' "$TEXT"
  }

  for TEXT in '' 'word' $'foo\nbar\n' $'\n\n' '; echo WHOOPS; return 1'; do
    (
    sensitive_func > "$TEST_DIR/exp_out"
    bc::memoize sensitive_func
    sensitive_func > "$TEST_DIR/out_cold"
    sensitive_func > "$TEST_DIR/out_cached"

    diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out_cold"
    diff -u "$TEST_DIR/exp_out" "$TEST_DIR/out_cached"
    )
  done
}

@test "memoized: stderr isn't cached" {
  err_func() { echo stdout; echo stderr >&2; } && bc::memoize err_func

  run_sameshell err_func
  expected 0 stdout stderr

  run_sameshell err_func
  expected 0 stdout ''

  run_sameshell err_func abc
  expected 0 stdout stderr
}

@test "memoized: failures aren't cached" {
  bad_func() { echo stderr >&2; return "${code:-127}"; } && bc::memoize bad_func

  run_sameshell bad_func
  expected 127 "" "stderr"

  code=10
  run_sameshell bad_func
  expected 10 "" "stderr" # not memoized

  code=0
  run_sameshell bad_func
  expected 0 "" "stderr"

  run_sameshell bad_func
  expected 0 "" "" # memoized
}

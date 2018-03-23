#!/usr/bin/env bats

TMPDIR=$BATS_TMPDIR/cache$$ # ensures each test has its own cache
source $BATS_TEST_DIRNAME/bash-cache.sh

# Similar to Bats' run function, but invokes the given command in the same
# shell rather than a subshell. MIT licensed.
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

CALL_COUNT=0
expensive_func() {
  : $(( CALL_COUNT++ ))
}

@test "without cache call count increases every time" {
  expensive_func
  expensive_func
  (( CALL_COUNT == 2 ))
  expensive_func
  expensive_func
  (( CALL_COUNT == 4 ))
}

@test "cached" {
  bc::cache expensive_func
  expensive_func
  expensive_func
  expensive_func
  (( CALL_COUNT == 1 ))
}

@test "caching on and off" {
  bc::cache expensive_func
  expensive_func
  expensive_func
  expensive_func
  echo $CALL_COUNT
  (( CALL_COUNT == 1 ))
  bc::off
  expensive_func
  expensive_func
  (( CALL_COUNT == 3 ))
  bc::on
  expensive_func
  (( CALL_COUNT == 3 ))
}

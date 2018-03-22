#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/bash-cache.sh
CACHE_DIR=$BATS_TMPDIR/cache$$
ENABLE_CACHED_COMMANDS=true

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

ALREADY_DONE=false
one_and_done() {
  if "$ALREADY_DONE"; then
    echo "one_and_done already called!"
    return 1
  fi
  ALREADY_DONE=true
  echo once
  return 0
}

@test "without cache second call fails" {
  one_and_done
  if one_and_done; then false; fi
}

@test "cached" {
  echo caching
  _cache one_and_done
  # currently need run_sameshell since the cached function is not -e -safe.
  run_sameshell one_and_done
  echo "RES - $status - $stdout - $stderr"
  expected 0 "once" ""
  run_sameshell one_and_done
  expected 0 "once" ""
}
#!/usr/bin/env bats
#
# Unit tests of individual bash-cache functions, not overall caching semantics.

source $BATS_TEST_DIRNAME/bash-cache.sh

skip_osx() {
  if [[ "$(uname -s)" =~ Darwin ]]; then
    skip "$@"
  fi
}

@test "_hash" {
  hashed=$(bc::_hash "several dangerous/special'chars&#!")
  [[ "$hashed" =~ ^[0-9a-fA-F]+$ ]]
}

@test "_modtime" {
  skip_osx "This test relies on GNU date"
  local timestamp=201801011211.10
  touch -m -t "$timestamp" "$BATS_TMPDIR/_modtime_test"
  modtime=$(bc::_modtime "$BATS_TMPDIR/_modtime_test")
  [[ "$(date -d "@$modtime" +'%Y%m%d%H%M.%S')" == "$timestamp" ]]
}

@test "_modtime missing file" {
  run bc::_modtime "$BATS_TMPDIR/_modtime_missing_test"
  (( status == 1 ))
  [[ "$output" == '0' ]]
}

@test "_now" {
  (( $(bc::_now) > 0 )) # not worth testing further...
}

@test "_newer_than" {
  skip_osx "This test relies on GNU touch" # need some other approach for this to pass on OSX
  touch -d '1 minute ago' "$BATS_TMPDIR/_newer_than_test"
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_test" 59
  (( status != 0 ))
  [[ -z "$output" ]]
  sleep 5
  # low-risk race that this this test takes 60+ sec...
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_test" 120
  (( $status == 0 ))
  [[ -z "$output" ]]
}

@test "_newer_than missing file" {
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_missing_test" 1000000
  (( status != 0 ))
  [[ -z "$output" ]]
}

@test "_read_input" {
  skip_osx "Bash read's \0-handling behavior is different on OSX"
  bc::_read_input contents < <(echo foo; printf baz)
  [[ "$contents" == foo$'\n'baz ]]

  bc::_read_input contents < <(echo foo; echo baz)
  [[ "$contents" == foo$'\n'baz$'\n' ]]

  bc::_read_input contents < <(printf "foo\0bar")
  [[ "$contents" == foobar ]] # null char is still dropped
}

@test "_time" {
  true=1
  duration=$(bc::_time sleep 1)
  [[ "$(bc <<<"$duration >= 1")" == $true ]]
}
#!/usr/bin/env bats
#
# Unit tests of individual bash-cache functions, not overall caching semantics.

source "${BATS_TEST_DIRNAME}/../bash-cache.sh"

skip_osx() {
  if [[ "$(uname -s)" =~ Darwin ]]; then
    skip "$@"
  fi
}

@test "_hash special chars" {
  hashed=$(bc::_hash "several dangerous/special'chars&#!")
  [[ "$hashed" =~ ^[0-9a-fA-F]+$ ]]
}

@test "_hash similar args" {
  [[ "$(bc::_hash a b)" != "$(bc::_hash 'a b')" ]]
  [[ "$(bc::_hash a b)" != "$(bc::_hash 'ab')" ]]
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
  bc::_now
  (( _now > 0 )) # not worth testing further...
}

@test "_to_seconds" {
  # Note: unsupported patterns that happen to parse today, like '10s 5m' or
  # '10s10s', are intentionally not tested; if the parser becomes stricter in
  # the future the tests should still pass.
  check_duration() { # TODO https://github.com/bats-core/bats-core/issues/241
    run bc::_to_seconds "$1"
    (( status == 0 ))
    [[ -z "$output" ]]
    bc::_to_seconds "$1" # re-run in the same shell
    (( _seconds == $2 ))
  }
  check_duration 10s 10
  check_duration 10m $((10*60))
  check_duration 10h $((10*60*60))
  check_duration 10d $((10*24*60*60))
  check_duration 10d10s $((10*24*60*60 + 10))
  check_duration 1m10s $((1*60 + 10))
  check_duration '1m 10s' $((1*60 + 10))
  check_duration 1d2h3m4s $((1*24*60*60 + 2*60*60 + 3*60 + 4))
  check_duration '1d  2h  3m  4s' $((1*24*60*60 + 2*60*60 + 3*60 + 4))
}

@test "_to_seconds invalid" {
  invalid_durations=('' '  ' 's' '10' '10m5' '10S' '10w' '10seconds' '10 s')
  for invalid in "${invalid_durations[@]}"; do
    ! bc::_to_seconds "$invalid"
  done
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
  bc::_read_input contents < <(printf ' foo \nbaz ')
  [[ "$contents" == $' foo \nbaz ' ]]

  bc::_read_input contents < <(printf ' foo \nbaz \n')
  [[ "$contents" == $' foo \nbaz \n' ]]

  bc::_read_input contents < <(printf ' foo \rbaz \r\n\r')
  [[ "$contents" == $' foo \rbaz \r\n\r' ]]
}

@test "_read_input null chars" {
  # Bash read's \0-handling behavior changed in v4"
  if (( BASH_VERSINFO[0] >= 4 )); then
    bc::_read_input contents < <(printf 'foo\0bar')
    [[ "$contents" == foobar ]] # null char is dropped, but remaining text preserved
  else
    bc::_read_input contents < <(printf 'foo\0bar')
    [[ "$contents" == foo ]]
  fi
}

@test "_time" {
  true=1
  duration=$(bc::_time sleep 1)
  [[ "$(bc <<<"$duration >= 1")" == $true ]]
}
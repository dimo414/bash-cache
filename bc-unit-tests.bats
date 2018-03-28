#!/usr/bin/env bats
#
# Unit tests of individual bash-cache functions, not overall caching semantics.

source $BATS_TEST_DIRNAME/bash-cache.sh

@test "_hash" {
  hashed=$(bc::_hash "several dangerous/special'chars&#!")
  [[ "$hashed" =~ ^[0-9a-fA-F]+$ ]]
}

@test "_modtime" {
  touch -m -t '201801011211.10' "$BATS_TMPDIR/_modtime_test"
  modtime=$(bc::_modtime "$BATS_TMPDIR/_modtime_test")
  [[ "$modtime" == "1514837470" ]]
}

@test "_modtime missing file" {
  run bc::_modtime "$BATS_TMPDIR/_modtime_missing_test"
  (( $status == 1 ))
  [[ "$output" == '0' ]]
}

@test "_newer_than" {
  # This relies on GNU touch, would need something else for this to pass on OSX
  touch -d '1 minute ago' "$BATS_TMPDIR/_newer_than_test"
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_test" 59
  (( $status != 0 ))
  [[ -z "$output" ]]
  sleep 5
  # low-risk race that this this test takes 60+ sec...
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_test" 120
  (( $status == 0 ))
  [[ -z "$output" ]]
}

@test "_newer_than missing file" {
  run bc::_newer_than "$BATS_TMPDIR/_newer_than_missing_test" 1000000
  (( $status != 0 ))
  [[ -z "$output" ]]
}

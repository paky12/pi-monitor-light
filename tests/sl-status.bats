#!/usr/bin/env bats

@test "sl-status passes shellcheck" {
  run shellcheck -x bin/sl-status
  [ "$status" -eq 0 ]
}

@test "sl-status runs without args and exits 0" {
  run bin/sl-status
  [ "$status" -eq 0 ]
}

@test "sl-status reports (none active) when no logger units" {
  run bin/sl-status
  [[ "$output" == *"(none active)"* ]]
}

@test "sl-status reports (empty) when log dir exists but empty" {
  tmp=$(mktemp -d)
  LOG_DIR=$tmp run bin/sl-status
  rmdir "$tmp"
  [[ "$output" == *"(empty)"* ]]
}

#!/usr/bin/env bats

@test "sl-status passes shellcheck" {
  run shellcheck -x bin/sl-status
  [ "$status" -eq 0 ]
}

@test "sl-status runs without args" {
  run bin/sl-status
  [ "$status" -le 4 ]
}

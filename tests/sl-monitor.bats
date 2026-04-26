#!/usr/bin/env bats

@test "sl-monitor with no args prints usage and exits 2" {
  run bin/sl-monitor
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "sl-monitor unknown command exits 2" {
  run bin/sl-monitor frobnicate
  [ "$status" -eq 2 ]
}

@test "sl-monitor passes shellcheck" {
  run shellcheck -x bin/sl-monitor
  [ "$status" -eq 0 ]
}

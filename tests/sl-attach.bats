#!/usr/bin/env bats

@test "sl-attach passes shellcheck" {
  run shellcheck -x bin/sl-attach
  [ "$status" -eq 0 ]
}

@test "sl-attach prints help on -h" {
  run bin/sl-attach -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux"* ]]
}

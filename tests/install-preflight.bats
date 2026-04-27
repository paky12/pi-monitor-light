#!/usr/bin/env bats

@test "install.sh passes shellcheck" {
  run shellcheck -x install.sh
  [ "$status" -eq 0 ]
}

@test "install.sh refuses to run as non-root unless DRY_RUN=1" {
  run bash install.sh preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

@test "install.sh DRY_RUN=1 preflight succeeds without root" {
  run bash -c 'DRY_RUN=1 ./install.sh preflight'
  [ "$status" -eq 0 ]
}

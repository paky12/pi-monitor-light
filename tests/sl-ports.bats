#!/usr/bin/env bats

@test "sl-ports passes shellcheck" {
  run shellcheck -x bin/sl-ports
  [ "$status" -eq 0 ]
}

@test "sl-ports exits 0 even when no /dev/ttyUSB* present (off-Pi env)" {
  CONF=/dev/null run bin/sl-ports
  [ "$status" -eq 0 ]
}

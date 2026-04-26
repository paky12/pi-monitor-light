#!/usr/bin/env bats

setup() {
  source lib/parse-ports.sh
}

@test "parse_ports emits one line per port: <dev> <name> <baud>" {
  run parse_ports tests/fixtures/ports-valid.conf
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
  [ "${lines[1]}" = "ttyUSB1 EL 115200" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "parse_ports skips comments and blank lines" {
  run parse_ports tests/fixtures/ports-comments.conf
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
  [ "${lines[1]}" = "ttyACM0 BOOTLOADER 9600" ]
}

@test "parse_ports rejects more than 4 ports" {
  run parse_ports tests/fixtures/ports-too-many.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"max 4 ports"* ]]
}

@test "parse_ports rejects non-numeric baud" {
  run parse_ports tests/fixtures/ports-bad-baud.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"baud"* ]]
}

@test "parse_ports fails on missing file" {
  run parse_ports /no/such/file.conf
  [ "$status" -ne 0 ]
}

@test "parse_ports rejects malformed line (return code 3)" {
  run parse_ports tests/fixtures/ports-malformed.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"malformed"* ]]
}

@test "parse_ports rejects trailing garbage" {
  run parse_ports tests/fixtures/ports-trailing-garbage.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"trailing garbage"* ]]
}

@test "parse_ports allows trailing # comments on data lines" {
  run parse_ports tests/fixtures/ports-trailing-comment.conf
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
}

@test "parse_ports rejects invalid device name" {
  run parse_ports tests/fixtures/ports-bad-dev.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"invalid device name"* ]]
}

@test "parse_ports rejects name with path traversal" {
  run parse_ports tests/fixtures/ports-bad-name.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"invalid name"* ]]
}

@test "parse_ports rejects duplicate names (return code 6)" {
  run parse_ports tests/fixtures/ports-dup-name.conf
  [ "$status" -eq 6 ]
  [[ "$output" == *"duplicate name"* ]]
}

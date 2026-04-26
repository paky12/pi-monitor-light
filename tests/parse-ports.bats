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

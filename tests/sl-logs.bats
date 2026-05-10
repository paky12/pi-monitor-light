#!/usr/bin/env bats

@test "sl-logs passes shellcheck" {
  run shellcheck -x bin/sl-logs
  [ "$status" -eq 0 ]
}

@test "sl-logs prints help on -h" {
  run bin/sl-logs -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "sl-logs errors when LOG_DIR doesn't exist" {
  tmp=$(mktemp -d); rmdir "$tmp"
  LOG_DIR=$tmp run bin/sl-logs
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "sl-logs reports (no log files) when LOG_DIR is empty" {
  tmp=$(mktemp -d)
  LOG_DIR=$tmp run bin/sl-logs
  rmdir "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log files"* ]]
}

@test "sl-logs lists files when LOG_DIR has session files" {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/STM"
  echo body > "$tmp/STM/2026-05-08_14-23-01.log"
  echo body > "$tmp/STM/2026-05-08_19-45-12.log"
  LOG_DIR=$tmp run bin/sl-logs
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STM/2026-05-08_14-23-01.log"* ]]
  [[ "$output" == *"STM/2026-05-08_19-45-12.log"* ]]
}

@test "sl-logs filters to a single port subdir when given a name" {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/STM" "$tmp/EL"
  echo body > "$tmp/STM/2026-05-08_14-23-01.log"
  echo body > "$tmp/EL/2026-05-09_10-00-00.log"
  LOG_DIR=$tmp run bin/sl-logs STM
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STM/2026-05-08_14-23-01.log"* ]]
  [[ "$output" != *"EL/"* ]]
}

@test "sl-logs errors when given a nonexistent port name" {
  tmp=$(mktemp -d)
  LOG_DIR=$tmp run bin/sl-logs DOES_NOT_EXIST
  rmdir "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no log directory"* ]]
}

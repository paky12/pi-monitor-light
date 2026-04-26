#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export FW_DIR="$TMPDIR/firmware"
  export OPENOCD=/bin/echo   # mock openocd
  mkdir -p "$FW_DIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "sl-flash passes shellcheck" {
  run shellcheck -x bin/sl-flash
  [ "$status" -eq 0 ]
}

@test "sl-flash with no args prints usage and exits 2" {
  run bin/sl-flash
  [ "$status" -eq 2 ]
}

@test "sl-flash rejects file outside firmware dir" {
  echo dummy > "$TMPDIR/elsewhere.bin"
  run bin/sl-flash "$TMPDIR/elsewhere.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$FW_DIR"* ]]
}

@test "sl-flash rejects non-.bin file" {
  echo dummy > "$FW_DIR/x.elf"
  run bin/sl-flash "$FW_DIR/x.elf"
  [ "$status" -ne 0 ]
}

@test "sl-flash rejects file with spaces or special chars in name" {
  echo dummy > "$FW_DIR/bad name.bin"
  run bin/sl-flash "$FW_DIR/bad name.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported characters"* ]]
}

@test "sl-flash rejects symlink resolving outside firmware dir" {
  echo dummy > "$TMPDIR/outside.bin"
  ln -s "$TMPDIR/outside.bin" "$FW_DIR/link.bin"
  run bin/sl-flash "$FW_DIR/link.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$FW_DIR"* ]]
}

@test "sl-flash invokes openocd with canonical command for valid .bin" {
  echo dummy > "$FW_DIR/firmware.bin"
  run bin/sl-flash "$FW_DIR/firmware.bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"interface/stlink.cfg"* ]]
  [[ "$output" == *"target/stm32c0x.cfg"* ]]
  [[ "$output" == *"firmware.bin"* ]]
  [[ "$output" == *"0x08000000"* ]]
}

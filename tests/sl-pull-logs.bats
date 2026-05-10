#!/usr/bin/env bats

@test "sl-pull-logs passes shellcheck" {
  run shellcheck -x gui/sl-pull-logs
  [ "$status" -eq 0 ]
}

@test "sl-pull-logs prints help on -h" {
  run gui/sl-pull-logs -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"serial_monitor_outputs"* ]]
}

@test "sl-pull-logs --dry-run prints the rsync command without running" {
  run gui/sl-pull-logs --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"--exclude=findings.md"* ]]
  [[ "$output" == *"--delete"* ]]
  [[ "$output" == *"/var/log/pi-monitor/"* ]]
}

@test "sl-pull-logs --dry-run --host overrides the SSH target" {
  run gui/sl-pull-logs --dry-run --host alice@bob.local
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice@bob.local:/var/log/pi-monitor/"* ]]
}

@test "sl-pull-logs --dry-run with positional arg overrides destination" {
  run gui/sl-pull-logs --dry-run /tmp/some/dest
  [ "$status" -eq 0 ]
  [[ "$output" == *"/tmp/some/dest"* ]]
}

@test "sl-pull-logs --dry-run respects SL_LOG_DEST env var" {
  SL_LOG_DEST=/tmp/env/dest run gui/sl-pull-logs --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/tmp/env/dest"* ]]
}

@test "sl-pull-logs rejects unknown flag" {
  run gui/sl-pull-logs --bogus-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

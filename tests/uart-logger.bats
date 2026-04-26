#!/usr/bin/env bats

@test "systemd unit file passes systemd-analyze verify" {
  # NOTE: dropped --root=. from the spec'd command — that flag tells
  # systemd-analyze to look for units under <root>/etc/systemd/system/
  # (not to resolve the file argument relative to <root>), so it cannot
  # find a unit that lives at ./systemd/. Verifying the file by path
  # directly is the documented in-tree verification mode.
  run systemd-analyze verify --recursive-errors=no \
      systemd/uart-logger@.service
  [ "$status" -eq 0 ]
}

@test "unit file declares User=pi-monitor" {
  grep -q '^User=pi-monitor$' systemd/uart-logger@.service
}

@test "unit uses BindsTo for device lifecycle" {
  grep -q '^BindsTo=dev-%i.device$' systemd/uart-logger@.service
}

@test "unit uses Restart=on-failure (NOT always — see design §6)" {
  grep -q '^Restart=on-failure$' systemd/uart-logger@.service
  ! grep -q '^Restart=always' systemd/uart-logger@.service
}

@test "ExecStopPost emits SESSION END marker" {
  grep -q 'SESSION END' systemd/uart-logger@.service
}

@test "RuntimeDirectory is pi-monitor" {
  grep -q '^RuntimeDirectory=pi-monitor$' systemd/uart-logger@.service
}

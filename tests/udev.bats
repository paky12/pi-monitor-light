#!/usr/bin/env bats

@test "udev rule covers ttyUSB devices" {
  grep -q 'KERNEL=="ttyUSB\[0-9\]\*"' udev/99-pi-monitor.rules
}

@test "udev rule covers ttyACM devices" {
  grep -q 'KERNEL=="ttyACM\[0-9\]\*"' udev/99-pi-monitor.rules
}

@test "udev rule tags device for systemd" {
  grep -q 'TAG+="systemd"' udev/99-pi-monitor.rules
}

@test "udev rule sets SYSTEMD_WANTS to start the per-device unit" {
  grep -q 'ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"' udev/99-pi-monitor.rules
}

@test "udev rule only fires on add (not change/remove)" {
  ! grep -q 'ACTION=="change"' udev/99-pi-monitor.rules
  ! grep -q 'ACTION=="remove"' udev/99-pi-monitor.rules
  grep -q 'ACTION=="add"' udev/99-pi-monitor.rules
}

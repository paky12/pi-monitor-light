#!/usr/bin/env bats

@test "logrotate config uses copytruncate" {
  grep -q copytruncate etc/logrotate.d/pi-monitor
}

@test "config.txt fragment disables BT" {
  grep -q '^dtoverlay=disable-bt$' boot-overlay/config.txt.fragment
}

@test "config.txt fragment does NOT reference pwr_led (no PWR LED on Zero 2 W)" {
  ! grep -q 'pwr_led' boot-overlay/config.txt.fragment
}

@test "cmdline fragment is single line" {
  [ "$(wc -l < boot-overlay/cmdline.txt.fragment)" -le 1 ]
}

@test "cmdline fragment contains maxcpus=2" {
  grep -q 'maxcpus=2' boot-overlay/cmdline.txt.fragment
}

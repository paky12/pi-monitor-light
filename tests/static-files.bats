#!/usr/bin/env bats

@test "logrotate config uses copytruncate" {
  grep -q copytruncate etc/logrotate.d/pi-monitor
}

@test "config.txt fragment has all 4 power-tweak directives" {
  grep -q '^dtoverlay=disable-bt$' boot-overlay/config.txt.fragment
  grep -q '^dtparam=act_led_trigger=none$' boot-overlay/config.txt.fragment
  grep -q '^dtparam=act_led_activelow=off$' boot-overlay/config.txt.fragment
  grep -q '^disable_splash=1$' boot-overlay/config.txt.fragment
}

@test "config.txt fragment does NOT reference pwr_led (no PWR LED on Zero 2 W)" {
  ! grep -q 'pwr_led' boot-overlay/config.txt.fragment
}

@test "cmdline fragment has zero newlines (single token sequence, no trailing \n)" {
  [ "$(wc -l < boot-overlay/cmdline.txt.fragment)" -eq 0 ]
}

@test "cmdline fragment contains maxcpus=2 and consoleblank=0" {
  grep -q 'maxcpus=2' boot-overlay/cmdline.txt.fragment
  grep -q 'consoleblank=0' boot-overlay/cmdline.txt.fragment
}

#!/usr/bin/env bats

@test "install.sh passes shellcheck" {
  run shellcheck -x install.sh
  [ "$status" -eq 0 ]
}

@test "install.sh refuses to run as non-root unless DRY_RUN=1" {
  run bash install.sh preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

@test "install.sh DRY_RUN=1 preflight succeeds without root" {
  run bash -c 'DRY_RUN=1 ./install.sh preflight'
  [ "$status" -eq 0 ]
}

@test "install.sh DRY_RUN=1 apt-deps lists key build deps" {
  run bash -c 'DRY_RUN=1 ./install.sh apt-deps'
  [ "$status" -eq 0 ]
  [[ "$output" == *"libusb-1.0-0-dev"* ]]
  [[ "$output" == *"libhidapi-dev"* ]]
  [[ "$output" == *"libjim-dev"* ]]
  [[ "$output" == *"DEBIAN_FRONTEND=noninteractive"* ]]
}

@test "install.sh DRY_RUN=1 install-files prints expected installs" {
  run bash -c 'DRY_RUN=1 ./install.sh install-files'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sl-monitor"* ]]
  [[ "$output" == *"uart-logger@.service"* ]]
  [[ "$output" == *"99-pi-monitor.rules"* ]]
}

@test "install.sh DRY_RUN=1 power-tweaks prints config.txt edits" {
  run bash -c 'DRY_RUN=1 ./install.sh power-tweaks'
  [ "$status" -eq 0 ]
  [[ "$output" == *"config.txt"* ]]
  [[ "$output" == *"cmdline.txt"* ]]
}

@test "install.sh DRY_RUN=1 openocd plans the from-source build" {
  run bash -c 'DRY_RUN=1 ./install.sh openocd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"openocd-src"* ]]
  [[ "$output" == *"./bootstrap"* ]]
  [[ "$output" == *"--enable-stlink"* ]]
}

@test "install.sh DRY_RUN=1 tailscale prints install + up command" {
  run bash -c 'DRY_RUN=1 ./install.sh tailscale'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pkgs.tailscale.com"* ]]
  [[ "$output" == *"--ssh"* ]]
  [[ "$output" == *"--hostname=pi-monitor"* ]]
}

@test "install.sh openocd uses GitHub mirror not SourceForge web URL" {
  run bash -c 'DRY_RUN=1 ./install.sh openocd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/openocd-org/openocd"* ]]
  [[ "$output" != *"sourceforge.net/p/openocd/code"* ]]
}

@test "install.sh rpi-connect honors INSTALL_RPI_CONNECT in DRY_RUN message" {
  run bash -c 'DRY_RUN=1 ./install.sh rpi-connect'
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_RPI_CONNECT"* ]]
}

@test "install.sh adds operator to plugdev and dialout groups" {
  grep -q 'usermod -aG.*plugdev.*dialout' install.sh
}

@test "install.sh installs openocd udev rule from contrib" {
  grep -q '60-openocd.rules' install.sh
}

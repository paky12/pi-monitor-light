#!/usr/bin/env bash
# install.sh — one-shot installer for pi-monitor-light.
# Idempotent: safe to re-run.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=/usr/local
SHARE_DIR=$PREFIX/share/pi-monitor-light
ETC_DIR=/etc/pi-monitor-light
LOG_DIR=/var/log/pi-monitor
FW_DIR=/var/lib/pi-monitor/firmware
SVC_USER=pi-monitor

DRY_RUN=${DRY_RUN:-0}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

require_root() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must be run as root (or with DRY_RUN=1 to dry-run)" >&2
    exit 1
  fi
}

step() { printf '\n=== %s ===\n' "$*"; }

preflight() {
  require_root
  step 'preflight'
  if [ ! -f /etc/os-release ]; then
    echo 'preflight: /etc/os-release missing' >&2; exit 1
  fi
  . /etc/os-release
  case ${VERSION_CODENAME:-} in
    bookworm|trixie) ;;
    *) echo "preflight: only Bookworm/Trixie supported (found: ${VERSION_CODENAME:-?})" >&2
       [ "$DRY_RUN" = "1" ] || exit 1 ;;
  esac
  echo 'preflight OK'
}

install_apt_deps() {
  step 'apt deps'
  run apt-get update
  if [ "$DRY_RUN" = "1" ]; then
    printf '+ DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold tmux moreutils logrotate libtool autoconf automake pkg-config texinfo libusb-1.0-0-dev libhidapi-dev git ca-certificates curl\n'
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      tmux moreutils logrotate \
      libtool autoconf automake pkg-config texinfo \
      libusb-1.0-0-dev libhidapi-dev \
      git ca-certificates curl
  fi
}

create_user_and_dirs() {
  step 'system user + directories'
  if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    run useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
  fi
  # Always ensure required supplementary groups (idempotent — usermod -aG is additive).
  run usermod -aG dialout,plugdev "$SVC_USER"
  # Add operator (the user that ran sudo) to pi-monitor (logs) + plugdev (ST-Link) + dialout (UART).
  if [ -n "${SUDO_USER:-}" ] && [ "$DRY_RUN" != "1" ]; then
    if ! usermod -aG "$SVC_USER",plugdev,dialout "$SUDO_USER"; then
      echo "warning: failed to add $SUDO_USER to required groups; sl-flash and log access may fail" >&2
    fi
  fi
  for d in "$SHARE_DIR" "$ETC_DIR" "$LOG_DIR" "$FW_DIR"; do
    run install -d -m 2775 -o "$SVC_USER" -g "$SVC_USER" "$d"
  done
}

install_files() {
  step 'install scripts + lib + unit + udev + logrotate'
  for s in sl-monitor sl-attach sl-flash sl-ports sl-status; do
    run install -m 0755 "$REPO_DIR/bin/$s" "$PREFIX/bin/$s"
  done
  run install -m 0644 "$REPO_DIR/lib/parse-ports.sh" "$SHARE_DIR/parse-ports.sh"
  run install -m 0644 "$REPO_DIR/systemd/uart-logger@.service" \
              /etc/systemd/system/uart-logger@.service
  run install -m 0644 "$REPO_DIR/udev/99-pi-monitor.rules" \
              /etc/udev/rules.d/99-pi-monitor.rules
  run install -m 0644 "$REPO_DIR/etc/logrotate.d/pi-monitor" \
              /etc/logrotate.d/pi-monitor

  if [ ! -f "$ETC_DIR/ports.conf" ]; then
    run install -m 0644 "$REPO_DIR/etc/ports.conf.example" "$ETC_DIR/ports.conf"
  fi

  run systemctl daemon-reload
  run udevadm control --reload-rules
}

apply_power_tweaks() {
  step 'power tweaks (/boot/firmware/config.txt + cmdline.txt)'
  local cfg=/boot/firmware/config.txt
  local cmd=/boot/firmware/cmdline.txt
  local marker='# pi-monitor-light power tweaks'

  if [ "$DRY_RUN" = "1" ]; then
    echo "+ append boot-overlay/config.txt.fragment to $cfg (if marker absent)"
    echo "+ append '$(cat "$REPO_DIR/boot-overlay/cmdline.txt.fragment")' to $cmd (if maxcpus=2 absent)"
    echo "+ systemctl disable --now hciuart.service (best-effort)"
    return
  fi

  if ! grep -qF "$marker" "$cfg"; then
    {
      echo
      cat "$REPO_DIR/boot-overlay/config.txt.fragment"
    } >> "$cfg"
  fi

  if ! grep -q 'maxcpus=2' "$cmd"; then
    # cmdline.txt MUST stay one line — append, no newline.
    sed -i "$ s/$/ $(cat "$REPO_DIR/boot-overlay/cmdline.txt.fragment")/" "$cmd"
  fi

  systemctl disable --now hciuart.service 2>/dev/null || true
}

build_openocd() {
  step 'build OpenOCD from master (Bookworm package is too old for STM32C0)'
  if [ -x "$PREFIX/bin/openocd" ] && "$PREFIX/bin/openocd" --version 2>&1 \
       | grep -qE 'Open On-Chip Debugger ([1-9][0-9]*\.|0\.(1[3-9]|[2-9][0-9]))'; then
    echo 'openocd already built and recent enough; skipping'
    return
  fi
  local src=$REPO_DIR/openocd-src
  if [ ! -d "$src" ]; then
    run git clone --depth=1 https://github.com/openocd-org/openocd.git "$src"
  fi
  # shellcheck disable=SC2086  # OPENOCD_JOBS may be empty or contain flags
  run sh -c "cd '$src' && ./bootstrap && ./configure --enable-stlink --disable-werror && make ${OPENOCD_JOBS:--j2} && make install"
  # OpenOCD's `make install` doesn't drop the contrib udev rule; do it ourselves.
  if [ -f "$src/contrib/60-openocd.rules" ]; then
    run install -m 0644 "$src/contrib/60-openocd.rules" /etc/udev/rules.d/60-openocd.rules
    run udevadm control --reload-rules
    run udevadm trigger
  fi
}

install_tailscale() {
  step 'tailscale'
  if ! command -v tailscale >/dev/null 2>&1; then
    run sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  fi
  echo
  echo 'Run the following manually to authenticate this Pi (interactive):'
  echo '  sudo tailscale up --ssh --hostname=pi-monitor'
}

maybe_install_rpi_connect() {
  step 'rpi-connect-lite (optional)'
  if [ "$DRY_RUN" = "1" ]; then
    echo '+ prompt user (or honor INSTALL_RPI_CONNECT={yes,no}); if yes, apt install rpi-connect-lite + enable-linger'
    return
  fi
  local ans
  case ${INSTALL_RPI_CONNECT:-prompt} in
    yes) ans=y ;;
    no)  ans=n ;;
    prompt)
      printf 'Install rpi-connect-lite as fallback browser-shell access? [y/N] '
      read -r ans || ans=n
      ;;
    *) echo "INSTALL_RPI_CONNECT must be yes/no/prompt (got: $INSTALL_RPI_CONNECT)" >&2; return 1 ;;
  esac
  case $ans in
    y|Y|yes|YES)
      apt-get install -y rpi-connect-lite
      if [ -n "${SUDO_USER:-}" ]; then
        loginctl enable-linger "$SUDO_USER"
        echo "Run as $SUDO_USER (not root): rpi-connect signin && rpi-connect on"
      fi
      ;;
    *) echo 'skipped' ;;
  esac
}

case ${1:-all} in
  preflight)             preflight ;;
  apt-deps)              require_root; install_apt_deps ;;
  user-dirs)             require_root; create_user_and_dirs ;;
  install-files)         require_root; install_files ;;
  power-tweaks)          require_root; apply_power_tweaks ;;
  openocd)               require_root; build_openocd ;;
  tailscale)             require_root; install_tailscale ;;
  rpi-connect)           require_root; maybe_install_rpi_connect ;;
  all)
    preflight
    install_apt_deps
    create_user_and_dirs
    install_files
    apply_power_tweaks
    build_openocd
    install_tailscale
    maybe_install_rpi_connect
    cat <<'EOF'

============================================================
install.sh: complete.

Next steps:
  1. Edit /etc/pi-monitor-light/ports.conf for your wiring.
  2. Run: sudo sl-monitor up
  3. Run: sudo tailscale up --ssh --hostname=pi-monitor
  4. Reboot to apply boot-overlay power tweaks: sudo reboot
============================================================
EOF
    ;;
  *) echo "install.sh: unknown step: $1" >&2; exit 2 ;;
esac

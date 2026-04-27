#!/usr/bin/env bash
# install.sh — one-shot installer for pi-monitor-light.
# Idempotent: safe to re-run.
set -euo pipefail

# shellcheck disable=SC2034  # REPO_DIR is consumed by file-install/units in later tasks.
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
  # Add operator (the user that ran sudo) to the pi-monitor group so they can read logs.
  if [ -n "${SUDO_USER:-}" ] && [ "$DRY_RUN" != "1" ]; then
    if ! usermod -aG "$SVC_USER" "$SUDO_USER"; then
      echo "warning: failed to add $SUDO_USER to $SVC_USER group; logs may not be readable" >&2
    fi
  fi
  for d in "$SHARE_DIR" "$ETC_DIR" "$LOG_DIR" "$FW_DIR"; do
    run install -d -m 2775 -o "$SVC_USER" -g "$SVC_USER" "$d"
  done
}

case ${1:-all} in
  preflight)             preflight ;;
  apt-deps)              require_root; install_apt_deps ;;
  user-dirs)             require_root; create_user_and_dirs ;;
  all)
    preflight
    install_apt_deps
    create_user_and_dirs
    echo
    echo 'install.sh: preflight + deps + dirs done.'
    echo 'Subsequent steps (openocd build, units, tailscale) added in later tasks.'
    ;;
  *) echo "install.sh: unknown step: $1" >&2; exit 2 ;;
esac

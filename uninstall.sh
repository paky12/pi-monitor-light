#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.
# Logs (/var/log/pi-monitor) and config (/etc/pi-monitor-light) are PRESERVED unless --purge.
set -euo pipefail

PREFIX=/usr/local
SHARE_DIR=$PREFIX/share/pi-monitor-light
ETC_DIR=/etc/pi-monitor-light
LOG_DIR=/var/log/pi-monitor
FW_DIR=/var/lib/pi-monitor/firmware
SVC_USER=pi-monitor

DRY_RUN=${DRY_RUN:-0}
PURGE=0
[ "${1:-}" = '--purge' ] && PURGE=1

run() {
  if [ "$DRY_RUN" = "1" ]; then printf '+ %s\n' "$*"
  else "$@"
  fi
}

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  echo 'uninstall.sh: must be run as root' >&2; exit 1
fi

# Stop + disable units
for u in $(systemctl list-units --no-legend --type=service 'uart-logger@*' \
           | awk '{print $1}'); do
  run systemctl disable --now "$u" || true
done

# Remove scripts + lib + unit + udev + logrotate
for s in sl-monitor sl-attach sl-flash sl-ports sl-status; do
  run rm -f "$PREFIX/bin/$s"
done
run rm -f "$SHARE_DIR/parse-ports.sh"
run rmdir --ignore-fail-on-non-empty "$SHARE_DIR" 2>/dev/null || true
run rm -f /etc/systemd/system/uart-logger@.service
run rm -f /etc/udev/rules.d/99-pi-monitor.rules
# Note: this rule was installed by openocd's source build; we own it on uninstall.
run rm -f /etc/udev/rules.d/60-openocd.rules
run rm -f /etc/logrotate.d/pi-monitor
run systemctl daemon-reload
run udevadm control --reload-rules

if [ $PURGE -eq 1 ]; then
  echo 'PURGE: removing config, logs, firmware dir, and pi-monitor user'
  # /var/lib/pi-monitor is a superset of $FW_DIR, listing it covers both.
  run rm -rf "$ETC_DIR" "$LOG_DIR" /var/lib/pi-monitor
  run userdel "$SVC_USER" || true
else
  echo 'Preserved: '"$ETC_DIR"', '"$LOG_DIR"', '"$FW_DIR"' (use --purge to remove)'
fi

# Note: power tweaks in /boot/firmware/* are intentionally not reverted —
# they're harmless and rolling them back risks corrupting the user's cmdline.
echo 'Note: boot-overlay tweaks not reverted — edit /boot/firmware/* by hand if desired.'

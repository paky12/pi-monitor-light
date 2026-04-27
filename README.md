# pi-monitor-light

SSH-only UART monitor + STM32C091 flashing station for Raspberry Pi Zero 2 W.
Power-budgeted for ≤2.3 W. Replaces the FastAPI-based `pi-monitor` for the Zero 2 W deployment.

## Quick start

On a fresh Raspberry Pi OS Bookworm Lite install:

    git clone <this repo> ~/pi-monitor-light
    cd ~/pi-monitor-light
    sudo ./install.sh           # ~30 min on Zero 2 W (openocd build dominates)
    sudo nano /etc/pi-monitor-light/ports.conf
    sudo sl-monitor up
    sudo tailscale up --ssh --hostname=pi-monitor
    sudo reboot                 # apply boot-overlay tweaks

**Group changes take effect on next login.** The reboot above handles this; if you skip the reboot, run `newgrp pi-monitor` (and similar for `plugdev`, `dialout`) or simply log out and back in before running `sl-flash`.

From your laptop (Tailscale-connected):

    ssh patrik@pi-monitor
    sl-attach                   # tmux session, one window per UART
    scp firmware.bin patrik@pi-monitor:/var/lib/pi-monitor/firmware/
    sl-flash /var/lib/pi-monitor/firmware/firmware.bin

## Optional install knobs

| Env var | Effect |
|---|---|
| `OPENOCD_JOBS=-j1` | Use 1 build job for OpenOCD source build (workaround for OOM on the Pi Zero 2 W's 512 MB RAM during link step) |
| `INSTALL_RPI_CONNECT={yes,no}` | Skip the interactive prompt for `rpi-connect-lite` install. Default: `prompt` (asks y/N) |
| `DRY_RUN=1` | Print all commands install.sh/uninstall.sh would run, without executing them |

Example: `OPENOCD_JOBS=-j1 INSTALL_RPI_CONNECT=no sudo ./install.sh`

## Commands

| Command | What it does |
|---|---|
| `sl-monitor up\|down\|restart [port]` | Start/stop the per-port logger units |
| `sl-attach` | tmux session with `journalctl -f` per active port |
| `sl-flash <bin>` | Flash a `.bin` from `/var/lib/pi-monitor/firmware/` |
| `sl-ports` | List configured + detected serial devices |
| `sl-status` | Show running loggers + log dir sizes |

## ports.conf format

One port per line, max 4 entries:

    # device       name           baud
    ttyUSB0        STM            115200
    ttyUSB1        EL             115200

- `device`: must be `ttyUSB<n>` or `ttyACM<n>` (no `/dev/` prefix)
- `name`: `[A-Za-z0-9_-]+` only (used as log subdirectory name)
- `baud`: positive integer
- duplicate names rejected
- trailing `# comment` allowed; other trailing tokens rejected

Run `sl-ports` to see configured ports + detected kernel devices side-by-side.

## Files

| Path | Purpose |
|---|---|
| `/etc/pi-monitor-light/ports.conf` | Port→name→baud mapping (max 4 entries) |
| `/var/log/pi-monitor/<name>/<ts>.log` | Per-session logs |
| `/var/lib/pi-monitor/firmware/*.bin` | Firmware staging dir |

## Design

See [`docs/plans/2026-04-26-pi-monitor-light-design.md`](docs/plans/2026-04-26-pi-monitor-light-design.md).

## Troubleshooting

**`sl-monitor up` fails with "permission denied" on /dev/ttyUSB0:**
The pi-monitor service user needs `dialout,plugdev` group membership. Re-run `sudo ./install.sh user-dirs` (idempotent — re-applies group membership without re-creating the user).

**OpenOCD build OOMs during `make`:**
Re-run with `OPENOCD_JOBS=-j1 sudo ./install.sh openocd`. Build resumes from where it stopped.

**Logger unit fails on every USB plug, journalctl shows "EnvironmentFile not found":**
The udev rule fires before `ports.conf` is configured, so `/etc/pi-monitor-light/ports.conf.env-<dev>` doesn't exist for that port. Add the device to `ports.conf` and run `sudo sl-monitor up`.

**Flash command hangs / ST-Link not detected:**
Check `lsusb` for the ST-Link entry. The pi-monitor user needs `plugdev` group access; verify with `id pi-monitor`. If permissions look right, unplug + replug the ST-Link.

## Uninstall

    sudo ./uninstall.sh            # keep logs + config
    sudo ./uninstall.sh --purge    # remove everything

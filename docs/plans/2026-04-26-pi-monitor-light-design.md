# pi-monitor-light — Design

**Date:** 2026-04-26
**Status:** Approved, ready for implementation
**Replaces:** `pi-monitor` (FastAPI/Python on Pi 4) for the Pi Zero 2 W deployment

---

## 1. Goal

A minimal, SSH-only UART monitor + STM32 flashing station for a Raspberry Pi Zero 2 W that:

- Runs reliably on **≤ 2.3 W total board power** including USB peripherals.
- Has **zero userspace polling loops** (no Python interpreter, no FastAPI, no SSE).
- Is reachable from anywhere on Earth over SSH (Tailscale tailnet).
- Logs **1–4 UART ports** continuously to dated files, surviving USB hot-plug, kernel resets, and SSH disconnects.
- Flashes STM32C091 firmware via ST-Link / OpenOCD on demand.

## 2. Non-goals

- No browser UI. (Pivot from `pi-monitor`.)
- No live preview / per-port command input over the wire.
- No multi-user role separation beyond `pi-monitor` (logger) and `patrik` (operator).
- No log aggregation off-box. Logs live on the Pi until rotated/wiped.

## 3. Hardware

| Item | Notes |
|---|---|
| Raspberry Pi Zero 2 W | Quad-core Cortex-A53 (RP3A0), 512 MB. Idles at ~0.5–0.7 W. |
| Powered USB hub | Required — Zero 2 W has one micro-USB OTG; hub fans out to ST-Link + 1–2 FTDIs. |
| ST-Link V2 | Flashes STM32C091 over SWD. |
| FTDI TTL-232R-3V3 ×1–2 | UART monitoring (CP210x or FTDI both fine; udev rule matches `ttyUSB[0-9]*` and `ttyACM[0-9]*`). |
| 24 V → 5 V buck on custom carrier | Same power architecture as the original Gemini plan. Total budget on the 24 V/0.2 A rail is 4.8 W; this design targets 2.3 W. |

## 4. Architecture

```
                     ┌─────────────────────────────────┐
                     │  Laptop, anywhere on Earth      │
                     └────────────┬────────────────────┘
                                  │ ssh patrik@pi-monitor (Tailscale SSH)
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  Pi Zero 2 W   (1.3–1.7 W idle, 2 cores enabled)                 │
│                                                                  │
│  tailscaled            ─── mesh VPN, MagicDNS = "pi-monitor"     │
│                                                                  │
│  udev rule (99-pi-monitor.rules):                                │
│    on /dev/ttyUSB* / ttyACM* add →                               │
│      TAG+="systemd", SYSTEMD_WANTS+="uart-logger@%k.service"     │
│                                                                  │
│  systemd template:  uart-logger@<port>.service                   │
│    User=pi-monitor, BindsTo=dev-<port>.device                    │
│    cat /dev/<port> | ts | tee /var/log/pi-monitor/<name>/<ts>.log │
│    ExecStopPost: appends SESSION END marker + duration           │
│                                                                  │
│  CLI wrappers in /usr/local/bin/:                                │
│    sl-monitor, sl-attach, sl-flash, sl-ports, sl-status          │
│                                                                  │
│  Config:    /etc/pi-monitor-light/ports.conf                     │
│  Logs:      /var/log/pi-monitor/<name>/<timestamp>.log           │
│  Firmware:  /var/lib/pi-monitor/firmware/*.bin                   │
└──────────────────────────────────────────────────────────────────┘
                                  │ USB
                                  ▼
                    ┌──────────────────────────┐
                    │ Hub: ST-Link + FTDI ×N   │
                    └──────────────────────────┘
```

**Core principle:** the kernel does all serial I/O. Nothing in userspace polls. Each `cat` instance sits in a `read()` blocked in the kernel until bytes arrive — zero CPU when idle.

## 5. File layout

### Repository
```
pi-monitor-light/
├── README.md
├── install.sh                          # one-shot, idempotent
├── uninstall.sh                        # reverse install.sh
├── bin/
│   ├── sl-monitor
│   ├── sl-attach
│   ├── sl-flash
│   ├── sl-ports
│   └── sl-status
├── systemd/
│   └── uart-logger@.service
├── udev/
│   └── 99-pi-monitor.rules
├── etc/
│   ├── ports.conf.example
│   └── logrotate.d/pi-monitor
├── boot-overlay/
│   ├── config.txt.fragment
│   └── cmdline.txt.fragment
└── docs/plans/
    └── 2026-04-26-pi-monitor-light-design.md
```

### On the Pi after install
```
/usr/local/bin/sl-*                          # operator CLI tools
/usr/local/bin/openocd                       # built from master, see §9
/etc/systemd/system/uart-logger@.service     # template unit
/etc/udev/rules.d/99-pi-monitor.rules        # USB hotplug → SYSTEMD_WANTS
/etc/pi-monitor-light/
    ports.conf                               # user config (port→name→baud)
    ports.conf.env-ttyUSB0                   # generated EnvironmentFile, one per port
    ports.conf.env-ttyUSB1
/var/log/pi-monitor/<name>/<timestamp>.log   # per-session logs
/var/lib/pi-monitor/firmware/*.bin           # flashable binaries (scp drop dir)
/etc/logrotate.d/pi-monitor                  # weekly rotation, copytruncate
```

## 6. systemd template unit

`/etc/systemd/system/uart-logger@.service`:

```ini
[Unit]
Description=UART logger on /dev/%i
After=dev-%i.device
BindsTo=dev-%i.device
ConditionPathExists=/etc/pi-monitor-light/ports.conf.env-%i

[Service]
Type=simple
User=pi-monitor
Group=pi-monitor
UMask=0002
RuntimeDirectory=pi-monitor
EnvironmentFile=/etc/pi-monitor-light/ports.conf.env-%i

ExecStartPre=/usr/bin/stty -F /dev/%i ${BAUD} cs8 -cstopb -parenb -crtscts -ixon -ixoff raw -echo
ExecStartPre=/bin/mkdir -p /var/log/pi-monitor/${NAME}

ExecStart=/bin/sh -ec 'set -o pipefail; \
  LOG="/var/log/pi-monitor/${NAME}/$(date +%%Y-%%m-%%d_%%H-%%M-%%S).log"; \
  echo "$LOG" > /run/pi-monitor/%i.current; \
  echo "============================================================" >> "$LOG"; \
  echo "=== SESSION START $(date -Iseconds)  name=${NAME}  dev=/dev/%i  baud=${BAUD}" >> "$LOG"; \
  echo "============================================================" >> "$LOG"; \
  exec /usr/bin/cat /dev/%i | /usr/bin/ts "%%Y-%%m-%%d %%H:%%M:%%.S" | /usr/bin/tee -a "$LOG"'

ExecStopPost=/bin/sh -ec '\
  LOG=$(cat /run/pi-monitor/%i.current 2>/dev/null) || exit 0; \
  [ -f "$LOG" ] || exit 0; \
  START=$(stat -c %%Y "$LOG"); \
  NOW=$(date +%%s); \
  D=$((NOW-START)); \
  echo "============================================================" >> "$LOG"; \
  echo "=== SESSION END $(date -Iseconds)  duration=$((D/60))m $((D%%60))s" >> "$LOG"; \
  echo "============================================================" >> "$LOG"'

# Safety net only — primary restart path is udev SYSTEMD_WANTS on device re-add.
# Restart= does NOT fire when systemd itself stopped the unit (BindsTo=).
Restart=on-failure
RestartSec=2

Nice=10
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/pi-monitor /run/pi-monitor
PrivateTmp=yes
NoNewPrivileges=yes

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Lifecycle (the corrected understanding)

| Event | What happens |
|---|---|
| Boot, device already present | udev fires `add` → `SYSTEMD_WANTS` starts the unit. |
| Boot, device absent | Unit not started. When device plugs in, udev fires → unit starts. |
| Device unplugged / STM resets hard enough to drop USB | `BindsTo=` triggers stop. `ExecStopPost` writes SESSION END marker. |
| Device returns | udev `add` event → `SYSTEMD_WANTS` re-instantiates the unit → new log file. |
| `cat` dies but device is still there | `Restart=on-failure` brings it back after 2 s. |

> **Why not `Restart=always`:** systemd treats a `BindsTo`-driven stop as a clean shutdown, so `Restart=` does not fire. Verified at [systemd.service(5) §Restart=](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Restart=). The udev `SYSTEMD_WANTS` path is the documented pattern for device-presence-driven units.

## 7. udev rule

`/etc/udev/rules.d/99-pi-monitor.rules`:

```
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", ACTION=="add", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"

SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", ACTION=="add", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"
```

`%k` expands to the kernel device name (e.g. `ttyUSB0`), which becomes the systemd instance name.

> Pattern verified at [systemd.device(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.device.html).

## 8. Power tweaks

`/boot/firmware/config.txt` (appended block):

```
# pi-monitor-light power tweaks
dtoverlay=disable-bt           # disable Bluetooth controller
dtparam=act_led_trigger=none   # turn off the green ACT LED at idle
dtparam=act_led_activelow=off
disable_splash=1               # skip rainbow boot splash
```

`/boot/firmware/cmdline.txt` (appended to existing line):

```
maxcpus=2 consoleblank=0
```

> No `pwr_led_*` lines: per the [official Pi Zero 2 W reduced schematic](https://datasheets.raspberrypi.com/rpizero2/raspberry-pi-zero-2-w-reduced-schematics.pdf), the board has only one LED (D7 ACT). Setting `pwr_led_*` is a no-op.
> `disable-bt` overlay docs: [raspberrypi/firmware overlays README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README).
> Bookworm boot file paths verified at [config.txt docs](https://www.raspberrypi.com/documentation/computers/config_txt.html) and [configuration docs](https://www.raspberrypi.com/documentation/computers/configuration.html).
> `maxcpus=` is a generic Linux kernel parameter (see [kernel-parameters.txt](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)), not a Pi-specific knob — to be measured after install.

`install.sh` should also `systemctl disable hciuart.service` (the `disable-bt` overlay restores UART0 but doesn't stop the bluetooth service from trying to attach).

## 9. OpenOCD (built from master)

> **Important:** Bookworm's `openocd` package is v0.12.0, which does **not** include `target/stm32c0x.cfg`. Verified at [packages.debian.org/bookworm/openocd](https://packages.debian.org/bookworm/openocd) and the [v0.12.0 source tree](https://sourceforge.net/p/openocd/code/ci/v0.12.0/tree/tcl/target/). STM32C0 support exists only on master.

`install.sh` builds OpenOCD from master (cloned from the official GitHub mirror — the SourceForge `/p/openocd/code` URL is the project web page, not a git repo URL, so `git clone` would fail against it):

```bash
sudo apt install -y libtool autoconf automake pkg-config \
                    libusb-1.0-0-dev libhidapi-dev texinfo
git clone --depth=1 https://github.com/openocd-org/openocd.git openocd-src
cd openocd-src
./bootstrap
./configure --enable-stlink --disable-werror
make -j2                         # ~25–40 min on Pi Zero 2 W with maxcpus=2
                                 # (override via OPENOCD_JOBS=-j1 if OOM-killed)
sudo make install                # installs to /usr/local/bin/openocd
```

Built once during install. `sl-flash` invokes `/usr/local/bin/openocd` explicitly.

The flash command itself:
```
openocd -f interface/stlink.cfg -f target/stm32c0x.cfg \
        -c "program <bin> verify reset exit 0x08000000"
```

## 10. Networking

### Tailscale (primary)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname=pi-monitor
```

`--ssh` enables Tailscale SSH (auth via tailnet identity, no per-host key management).
After auth, the Pi is reachable from any device on the tailnet as `ssh patrik@pi-monitor`.

> Verified at [Tailscale SSH docs](https://tailscale.com/kb/1193/tailscale-ssh) and [tailscale up flags](https://tailscale.com/kb/1241/tailscale-up). On Linux, `--accept-routes` defaults to false (we leave it default).

### rpi-connect-lite (optional fallback)

`install.sh` prompts: *"Install rpi-connect-lite as fallback browser-shell access? [y/N]"*.

If yes:
```bash
sudo apt install -y rpi-connect-lite
loginctl enable-linger patrik       # so the user service runs without an active login
rpi-connect signin                  # interactive: opens browser-flow URL
rpi-connect on
```

> Lite variant supports remote shell only, no screen sharing — confirmed at [Pi Connect docs](https://www.raspberrypi.com/documentation/services/connect.html). `enable-linger` is officially recommended for headless Lite.

## 11. CLI wrappers

All in `bash`, < 50 lines each, installed to `/usr/local/bin/`.

| Command | Behavior |
|---|---|
| `sl-monitor up` | Reads `ports.conf`, generates `ports.conf.env-<port>` files, enables matching `uart-logger@<port>.service` instances, starts them. |
| `sl-monitor down` | Stops + disables all `uart-logger@*` instances. |
| `sl-monitor restart [port]` | Restart one or all. |
| `sl-attach` | `tmux new -As pi-monitor` with one window per active port running `journalctl -u uart-logger@<port> -f`. |
| `sl-flash <bin>` | Validates `<bin>` is in `/var/lib/pi-monitor/firmware/`, runs OpenOCD with the canonical command, exits with OpenOCD's exit code. |
| `sl-ports` | Prints `ports.conf` contents + udev info (`udevadm info /dev/ttyUSB0`: vendor, product, serial) + warns about unconfigured `/dev/ttyUSB*` / `ttyACM*`. |
| `sl-status` | `systemctl status uart-logger@*` summary + per-port log dir size + service uptimes. |

## 12. ports.conf

`/etc/pi-monitor-light/ports.conf` — one port per line, max 4 entries. Lines starting with `#` are ignored.

```
# device       name           baud
ttyUSB0        STM            115200
ttyUSB1        EL             115200
```

**Format & validation rules** (enforced by `lib/parse-ports.sh`; `sl-monitor up` aborts on any violation rather than silently dropping the bad port):

- `<kernel-device>`: must match `ttyUSB<digits>` or `ttyACM<digits>` (no `/dev/` prefix). Matches the udev rule and the systemd template's instance-name expectations.
- `<name>`: `[A-Za-z0-9_-]+`. Used as a log subdirectory under `/var/log/pi-monitor/` and embedded in an `EnvironmentFile`, so it must be filesystem-safe and free of shell/path metacharacters.
- `<baud>`: positive integer (digits only).
- Duplicate `<name>` values across lines are rejected — two ports cannot share a log directory.
- Trailing `#`-prefixed comments on data lines are allowed (e.g. `ttyUSB0 STM 115200 # primary`); any other trailing tokens are rejected as garbage.

`sl-monitor up` parses this and writes one `EnvironmentFile` per port:
```
# /etc/pi-monitor-light/ports.conf.env-ttyUSB0
NAME=STM
BAUD=115200
```

## 13. Log layout & rotation

```
/var/log/pi-monitor/
├── STM/
│   ├── 2026-04-26_20-45-31.log
│   ├── 2026-04-27_08-12-04.log     # new file each time the device reconnects
│   └── 2026-04-27_08-12-04.log.gz  # rotated by logrotate
└── EL/
    └── ...
```

Each file:
```
============================================================
=== SESSION START 2026-04-26T20:45:31+02:00  name=STM  dev=/dev/ttyUSB0  baud=115200
============================================================
2026-04-26 20:45:31.412345 [AT>] AT
2026-04-26 20:45:31.415123 [AT<] OK
============================================================
=== SESSION END 2026-04-26T20:50:00+02:00  duration=4m 29s
============================================================
```

Logrotate (`/etc/logrotate.d/pi-monitor`):

```
/var/log/pi-monitor/*/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` avoids restarting the logger units to reopen the file descriptor.

## 14. Power budget (target)

| Component | Estimated draw |
|---|---|
| Pi Zero 2 W idle, BT off, LEDs off, 2 cores | 0.5–0.7 W |
| ST-Link V2 idle | 0.15–0.25 W |
| FTDI TTL-232R-3V3 (×2) | 0.10 W each (~0.20 W total) |
| Powered USB hub overhead | 0.10–0.20 W |
| **Total idle** | **~1.0–1.4 W** |
| **Brief peak during flash** | **~1.8–2.2 W** |

Headroom on the 2.3 W ceiling: ~0.1–0.5 W under flash load. **Verify with a USB power meter once assembled.** If over, fall back to `maxcpus=1` and/or `arm_freq=600`.

## 15. Trade-offs vs the old `pi-monitor`

| Concern | Old (Pi 4 + FastAPI) | New (Pi Zero 2 W + shell + systemd) |
|---|---|---|
| Power | ~3–4 W typical | Target ~1.0–1.4 W |
| Languages | Python | Bash + systemd unit files only |
| Userspace polling | tailer threads, SSE pumps | None — kernel `read()` blocks |
| UI | Browser, dual-pane SSE | `tmux attach` over SSH |
| Reconnect | Python exponential backoff, inline markers | New file per reconnection, START/END markers |
| Live preview | Yes | No (out of scope) |
| Flashing | OpenOCD via FastAPI subprocess | OpenOCD via `sl-flash` shell wrapper |
| Remote access | LAN only | Tailscale SSH (anywhere) |
| Install size | Python venv + deps | A few hundred KB of scripts |

## 16. Out of scope (deliberate)

- Browser UI of any kind.
- Sending input back to the device over UART. (If needed later: `screen /dev/ttyUSB0 115200` from an SSH session, after `sl-monitor down ttyUSB0` to release the port.)
- Per-port log search / filter / export (use `grep` and `scp`).
- Multi-Pi log aggregation.

## 17. Verification sources

- systemd directives: [systemd.unit(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html), [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html), [systemd.service(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html), [systemd.device(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.device.html)
- Pi Zero 2 W boot config: [config.txt](https://www.raspberrypi.com/documentation/computers/config_txt.html), [configuration](https://www.raspberrypi.com/documentation/computers/configuration.html), [overlays README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README), [Pi Zero 2 W product brief](https://datasheets.raspberrypi.com/rpizero2/raspberry-pi-zero-2-w-product-brief.pdf), [Pi Zero 2 W reduced schematic](https://datasheets.raspberrypi.com/rpizero2/raspberry-pi-zero-2-w-reduced-schematics.pdf)
- Tailscale: [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh), [tailscale up flags](https://tailscale.com/kb/1241/tailscale-up)
- OpenOCD: [openocd.org](https://openocd.org/), [v0.12.0 source tree (no STM32C0)](https://sourceforge.net/p/openocd/code/ci/v0.12.0/tree/tcl/target/), [master source tree (has STM32C0)](https://sourceforge.net/p/openocd/code/ci/master/tree/tcl/target/), [Bookworm openocd 0.12.0-1](https://packages.debian.org/bookworm/openocd), [program command syntax](https://openocd.org/doc/html/Flash-Commands.html)
- moreutils `ts`: [joeyh.name/code/moreutils](https://joeyh.name/code/moreutils/), [ts(1) man page](https://manpages.debian.org/bookworm/moreutils/ts.1.en.html)
- Raspberry Pi Connect: [Pi Connect docs](https://www.raspberrypi.com/documentation/services/connect.html)

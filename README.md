# pi-monitor-light

SSH-only UART monitor + STM32C091 flashing station for Raspberry Pi Zero 2 W.
Power-budgeted for ≤2.3 W. Replaces the FastAPI-based `pi-monitor` for the Zero 2 W deployment.

---

# Part 1 — Setup & configuration

## Prerequisites

- A Raspberry Pi Zero 2 W (production target). A Pi 4B works for testing too — see *Troubleshooting* for the one caveat.
- A microSD card (≥4 GB) and a card writer.
- USB-UART adapter(s) (e.g. CP2102) for the boards you want to monitor — up to 4.
- An ST-Link V2 if you also need to flash STM32C091 firmware.
- A laptop on the same LAN as the Pi for the initial setup, plus a [Tailscale](https://tailscale.com) account for remote access afterward.

## 1. Flash the SD card

Use the official [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write **Raspberry Pi OS Lite (64-bit), Bookworm** to the SD card. The installer rejects anything other than Bookworm or Trixie.

Click the **gear icon** to pre-configure headless settings *before* flashing:

| Setting | Value |
|---|---|
| Hostname | `pi-monitor` |
| Username + password | your choice (e.g. `patrik`) |
| Wireless LAN | Your WiFi SSID + password — for travelling Pis, see [Network bootstrap](#network-bootstrap-wifi-onboarding-for-travel) below |
| Services → Enable SSH | **Yes**, with public-key auth ideally |

## 2. First boot & SSH in

Insert the SD card, power on the Pi, and wait 1–2 minutes for it to join WiFi. From your laptop on the same LAN:

    ssh patrik@pi-monitor.local

If `pi-monitor.local` doesn't resolve, find the IP from your router and use that.

## 3. Clone & install

    git clone https://github.com/paky12/pi-monitor-light.git ~/pi-monitor-light
    cd ~/pi-monitor-light
    sudo ./install.sh

This takes **~30 min on a Zero 2 W** — most of that is the OpenOCD source build (no released OpenOCD tag supports STM32C0 yet, so the installer pins to a specific master commit). Faster on a Pi 4B. If the build OOMs on the Zero 2 W, see *Troubleshooting*.

## 4. Configure serial ports

Tell the tool which adapters you have plugged in and what to call them:

    sudo nano /etc/pi-monitor-light/ports.conf

One line per port, max 4 entries:

    # device       name           baud
    ttyUSB0        STM            115200
    ttyUSB1        EL             115200

- `device`: must be `ttyUSB<n>` or `ttyACM<n>` (no `/dev/` prefix)
- `name`: `[A-Za-z0-9_-]+` only — used as the log subdirectory name
- `baud`: positive integer
- duplicate names rejected; trailing `# comment` allowed

## 5. Bring up loggers, Tailscale, reboot

    sudo sl-monitor up
    sudo tailscale up --ssh --hostname=pi-monitor    # browser auth — log in once
    sudo reboot                                       # applies boot-overlay tweaks

After the reboot you have:

- One systemd unit per port writing UART traffic to `/var/log/pi-monitor/<name>/<timestamp>.log`
- The Pi reachable from anywhere via Tailscale at `pi-monitor`

> **Group memberships only take effect after a fresh login.** The reboot handles this. If you skip it, run `newgrp pi-monitor` (and `plugdev`, `dialout`) or log out and back in before running `sl-flash`.

> **Tailscale SSH.** `--ssh` works out of the box on a tailnet with the default ACL — you can `ssh patrik@pi-monitor` from any device on your tailnet without managing SSH keys. If you've customised your tailnet's ACL (tags, user groups, sharing, etc.), Tailscale SSH stops working until you add an explicit `ssh` rule block in the [admin console](https://login.tailscale.com/admin/acls).

## Network bootstrap (WiFi onboarding for travel)

The Pi runs headless and is reached over SSH via Tailscale. That requires it to be on the internet first — chicken-and-egg when the Pi travels to sites with different WiFi each time.

**Recommended pattern: phone hotspot as a stable bootstrap.**

1. Configure your phone's hotspot with a fixed SSID + password (e.g. `patrik-bootstrap`). Use the same credentials forever — it becomes your "always-known" network. Note the Pi Zero 2 W only supports **2.4 GHz** WiFi.
2. Pre-configure that SSID in the Imager (step 1 above). The Pi joins your hotspot on every first boot.
3. Once SSH'd in, add the new site's WiFi:

       sudo nmcli device wifi connect "SiteWiFi" password "sitepass"

   The credentials persist across reboots; future visits to the same site auto-connect with no phone needed.

**Useful `nmcli` commands** (Bookworm Lite uses NetworkManager by default):

| Command | What it does |
|---|---|
| `nmcli connection show` | List known networks |
| `sudo nmcli device wifi list` | Scan for nearby networks |
| `sudo nmcli device wifi connect "<SSID>" password "<pass>"` | Add + auto-connect |
| `sudo nmcli connection delete "<SSID>"` | Forget a network |
| `sudo nmcli connection modify "<SSID>" connection.autoconnect-priority 100` | Prefer this network when multiple are in range |

If you need fully zero-laptop-prep recovery (e.g. phone is dead, no known WiFi in range), install [`comitup`](https://davesteele.github.io/comitup/) — it makes the Pi spin up its own AP as a fallback so you can configure WiFi from any laptop's browser.

## Optional install knobs

| Env var | Effect |
|---|---|
| `OPENOCD_JOBS=-j1` | Use 1 build job for OpenOCD source build (workaround for OOM on the Zero 2 W's 512 MB RAM during link step) |
| `INSTALL_RPI_CONNECT={yes,no}` | Skip the interactive prompt for `rpi-connect-lite` install. Default: `prompt` (asks y/N) |
| `DRY_RUN=1` | Print all commands `install.sh` / `uninstall.sh` would run, without executing them |

Example: `OPENOCD_JOBS=-j1 INSTALL_RPI_CONNECT=no sudo ./install.sh`

---

# Part 2 — Day-to-day use

## Connect to the Pi

From any laptop logged into the same Tailscale account:

    ssh patrik@pi-monitor

`pi-monitor` resolves over Tailscale's MagicDNS regardless of which network you're on — coffee shop, mobile, home. No port forwarding, no public SSH endpoint.

## Commands

| Command | What it does |
|---|---|
| `sl-attach` | tmux session with one window per active port, live `journalctl -f` |
| `sl-status` | Running loggers + log directory sizes |
| `sl-ports` | Configured ports vs. kernel-detected USB devices |
| `sl-monitor up\|down\|restart [port]` | Start/stop/restart loggers (per port or all) |
| `sl-flash <bin>` | Flash a `.bin` from `/var/lib/pi-monitor/firmware/` via ST-Link |

## Typical debugging loop

1. Build `firmware.bin` on your laptop.
2. Stage it on the Pi:

       scp firmware.bin patrik@pi-monitor:/var/lib/pi-monitor/firmware/

3. Flash:

       ssh patrik@pi-monitor
       sl-flash /var/lib/pi-monitor/firmware/firmware.bin

4. Watch the live UART output:

       sl-attach

   Switch tmux windows with `Ctrl-b n` / `Ctrl-b p`. Detach (loggers keep running) with `Ctrl-b d`. Re-attach by running `sl-attach` again.

5. Session logs persist under `/var/log/pi-monitor/<name>/` and rotate via logrotate, so you can `grep` history later.

## Files & paths

| Path | Purpose |
|---|---|
| `/etc/pi-monitor-light/ports.conf` | Port → name → baud mapping (max 4 entries) |
| `/var/log/pi-monitor/<name>/<ts>.log` | Per-session logs |
| `/var/lib/pi-monitor/firmware/*.bin` | Firmware staging dir |
| `/etc/systemd/system/uart-logger@.service` | Templated logger unit |
| `/etc/udev/rules.d/99-pi-monitor.rules` | Auto-start logger on USB plug |

---

# Troubleshooting

**`sl-monitor up` fails with "permission denied" on `/dev/ttyUSB0`.**
The `pi-monitor` service user needs `dialout` + `plugdev` group membership. Re-run `sudo ./install.sh user-dirs` (idempotent — re-applies group membership without re-creating the user).

**OpenOCD build OOMs during `make`.**
Re-run with `OPENOCD_JOBS=-j1 sudo ./install.sh openocd`. The build resumes from where it stopped.

**Logger unit fails on every USB plug, journalctl shows "EnvironmentFile not found".**
The udev rule fires before `ports.conf` is configured, so `/etc/pi-monitor-light/ports.conf.env-<dev>` doesn't exist for that port. Add the device to `ports.conf` and run `sudo sl-monitor up`.

**`sl-flash` hangs / "ST-Link not detected".**
Check `lsusb` for the ST-Link entry. Verify the user has `plugdev` group access (`id`). If permissions look right, unplug + replug the ST-Link.

**Locale warnings on every command after SSH.**
Bookworm Lite ships only `C.UTF-8`, so SSH-forwarded `LC_*` from your laptop fail to set. Fix on the Pi: `sudo apt-get install -y locales-all` (or `sudo dpkg-reconfigure locales` and pick the locale you want), then re-SSH.

**Testing on a Pi 4B: `nproc` only shows 2 cores.**
The boot overlay sets `maxcpus=2` — a power-budgeting tweak that's correct for the Zero 2 W production target but wastes 2 of the 4B's 4 cores. To restore all 4 on a 4B test bench: edit `/boot/firmware/cmdline.txt`, remove the `maxcpus=2` token (keep the file as one line), and reboot.

---

# Uninstall

    sudo ./uninstall.sh            # keep logs + config
    sudo ./uninstall.sh --purge    # remove everything

# Design

For the why-and-how:

- [`docs/plans/2026-04-26-pi-monitor-light-design.md`](docs/plans/2026-04-26-pi-monitor-light-design.md) — design rationale
- [`docs/writeup/pi-monitor-light.pdf`](docs/writeup/pi-monitor-light.pdf) — 6-page LaTeX technical note

---

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)

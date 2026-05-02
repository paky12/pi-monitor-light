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

Once on, bring the system up to date and install `git` (Bookworm Lite ships without it, and the SD-card image can be months behind):

    sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get install -y git

Reboot if the upgrade pulled in a new kernel: `sudo reboot`.

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
| `sl-attach` | All ports in one tmux session (one window per port, live `journalctl -f`). |
| `sl-attach <name\|device>` | Live-tail one port (no tmux). Run in separate terminal tabs for side-by-side viewing. |
| `sl-status` | Running loggers + log directory sizes. |
| `sl-ports` | Configured ports vs. kernel-detected USB devices. |
| `sl-monitor up` | Enable + start the loggers, and arm them across reboots / device re-plugs. |
| `sl-monitor down` | Stop + disable all loggers — won't auto-resume on reboot or USB plug. |
| `sl-monitor restart [name\|device]` | Restart one or all loggers — closes the current log file, opens a fresh one. |
| `sl-flash <bin>` | Flash a `.bin` from `/var/lib/pi-monitor/firmware/` via ST-Link. |

For commands that take `<name|device>`, you can use either the friendly **name** from `ports.conf` (e.g. `STM`, `EL`) or the kernel **device** (e.g. `ttyUSB0`, `ttyACM1`).

## Watching live logs

Two viewing styles. Pick whichever fits your terminal habits — they don't conflict.

**All ports in one tmux session** (default `sl-attach`):

    sl-attach

Switch windows with `Ctrl-b n` / `Ctrl-b p` — press the prefix, release, *then* the next key (they're separate keystrokes, not held together). Detach with `Ctrl-b d`; loggers keep running, reattach with `sl-attach` again. `Ctrl-b ?` lists every keybinding.

**One terminal tab per port** (no tmux):

    sl-attach STM      # in laptop tab 1
    sl-attach EL       # in laptop tab 2
    # third tab stays a free shell for sl-flash, sl-status, etc.

Each invocation just runs `journalctl -f` for that one logger unit. `Ctrl-C` to exit. Use this style when you'd rather rely on your laptop's terminal app for layout than tmux's split-pane management.

## Log sessions: how the loggers structure the data

Each port's log file is a sequence of **sessions**. A session is one continuous capture, framed in the file by markers:

    === SESSION START 2026-05-03T13:01:42+00:00  name=STM  dev=/dev/ttyUSB0  baud=115200
    ...UART data...
    === SESSION END   2026-05-03T15:42:18+00:00  duration=160m 36s

A new session starts whenever the logger unit (re)starts. That happens **automatically** on:

- DUT or USB-UART briefly disconnects then reconnects (`BindsTo=` + udev re-add)
- the logger process crashes (`Restart=on-failure`)
- the Pi reboots and the units come back up

To **explicitly roll over** to a fresh log file (e.g. between two test runs you want filed separately):

    sudo sl-monitor restart           # all ports
    sudo sl-monitor restart STM       # one port (name or device)

To **stop logging entirely** (won't auto-resume on reboot or replug):

    sudo sl-monitor down

To **wipe all past log history** and start absolutely clean:

    sudo sl-monitor down
    sudo rm -rf /var/log/pi-monitor/*/*.log*
    sudo sl-monitor up

The `=== SESSION START` / `=== SESSION END` markers are what makes the log a structured **uptime record** rather than just a flat byte stream. They're how you reconstruct, after the fact, exactly when the DUT went down and came back.

## Workflow A — Iterative firmware development

The build → flash → attach loop:

1. Build `firmware.bin` on your laptop.
2. Stage it on the Pi:

       scp firmware.bin patrik@pi-monitor:/var/lib/pi-monitor/firmware/

3. Flash:

       ssh patrik@pi-monitor
       sl-flash /var/lib/pi-monitor/firmware/firmware.bin

4. Watch the UART output (see [Watching live logs](#watching-live-logs) above).

5. Repeat. Logs from each session persist under `/var/log/pi-monitor/<name>/` and rotate via logrotate, so you can `grep` history later.

## Workflow B — Long-running soak / stability tests

To find out *how stable a DUT is over days or weeks*, leave the loggers running and walk away. The architecture is built for this:

| Event | What survives |
|---|---|
| DUT crashes / resets but USB stays alive | Logger keeps the same session — bytes resume when the DUT recovers. |
| DUT power-cycle drops the USB-UART | Unit stops cleanly with a `=== SESSION END` marker; udev re-adds the device, unit re-instantiates with a fresh log file. |
| Pi reboot | Units are `WantedBy=multi-user.target` (set by `sl-monitor up`), so they come back automatically. |
| You SSH out / laptop sleeps / network drops | Loggers are system-level systemd units, tied to no shell. Run `sl-attach` again whenever you reconnect. |

**Kickoff (one command, then walk away):**

    sudo sl-monitor up

**After hours / days / weeks, on the Pi:**

    sl-attach STM                                       # live tail
    grep -c '=== SESSION START' /var/log/pi-monitor/STM/*.log   # disconnect count
    grep -h '=== SESSION ' /var/log/pi-monitor/STM/*.log | sort # disconnect timeline
    du -sh /var/log/pi-monitor/STM                              # space used so far

**When you're done:**

    sudo sl-monitor down

**Things to plan for in multi-week runs:**

- **Disk space.** A continuously-talking 115200-baud UART produces ~10 KB/s = ~12 GB/week uncompressed; logrotate gzip's it weekly down to ~1.5 GB/week. With the default `rotate 8`, that's roughly **12 GB peak storage** per chatty port. Use a 32 GB+ SD card, or lower `rotate` in `/etc/logrotate.d/pi-monitor`, or quiet down the firmware's printing.
- **SD card endurance.** Continuous-write workloads kill consumer cards in 3–12 months. For multi-month soak benches, use an industrial-rated card (e.g. SanDisk Industrial XI) or move `/var/log` onto a USB SSD on the Pi 4B.
- **journald cap.** Bookworm's defaults can be too generous on a small SD. Cap with:

      sudo mkdir -p /etc/systemd/journald.conf.d
      echo -e "[Journal]\nSystemMaxUse=500M" | sudo tee /etc/systemd/journald.conf.d/cap.conf
      sudo systemctl restart systemd-journald

- **Power loss.** Soft Pi reboot recovers cleanly (loggers come back). Hard outage can corrupt the SD filesystem; for unattended benches, consider a UPS HAT or periodic SD backups.

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

# Optional: laptop-side GUI

A NiceGUI control panel for driving the tool from your laptop instead of the CLI lives in [`gui/`](gui/). It SSHes into the Pi to drive the same `sl-*` commands and streams `journalctl -fu` per port into side-by-side log panes — buttons for flash / restart / wipe, drag-and-drop firmware upload, status indicators. **Pi side stays unchanged.** See [`gui/README.md`](gui/README.md) for setup.

# Uninstall

    sudo ./uninstall.sh            # keep logs + config
    sudo ./uninstall.sh --purge    # remove everything

# Design

For the why-and-how:

- [`docs/plans/2026-04-26-pi-monitor-light-design.md`](docs/plans/2026-04-26-pi-monitor-light-design.md) — design rationale
- [`docs/writeup/pi-monitor-light.pdf`](docs/writeup/pi-monitor-light.pdf) — 6-page LaTeX technical note

---

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)

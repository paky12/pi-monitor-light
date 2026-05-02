# pi-monitor-gui

Laptop-side control panel for `pi-monitor-light`. Built with [NiceGUI](https://nicegui.io/).

The GUI talks to the Pi over SSH only. **Nothing on the Pi changes.** All it does is wrap the existing `sl-*` commands and stream `journalctl -fu uart-logger@*` per port.

```
┌── pi-monitor · dev@pi-monitor ─────── ● connection ──┐
├── Actions ─────┬── STM ●        EL ●  ──────────────┤
│ Restart all    │  ┌────────────┐ ┌────────────┐      │
│ Restart STM    │  │ live log   │ │ live log   │      │
│ Restart EL     │  │ (ui.log)   │ │ (ui.log)   │      │
│ Start  / Stop  │  │            │ │            │      │
│ Wipe logs…     │  └────────────┘ └────────────┘      │
│                │                                     │
│ Firmware       │  Last action                        │
│ [Upload .bin]  │  ┌──────────────────────────┐       │
│ [select…    ▾] │  │ $ sudo sl-flash …        │       │
│ [Flash]        │  │ ** Verified OK **         │       │
└────────────────┴──┴──────────────────────────┘───────┘
```

## Prerequisites

You'll need:

1. **A working `pi-monitor-light` install on the Pi** — see the top-level [README](../README.md). The Pi side requires zero changes to support this GUI.
2. **Working SSH from your laptop to the Pi** — `ssh dev@pi-monitor` should already succeed (key-based or via Tailscale SSH).
3. **Passwordless `sudo` for the `sl-*` commands** on the Pi (see [setup](#one-time-pi-side-setup-passwordless-sl-) below).

## One-time Pi-side setup: passwordless `sl-*`

The GUI runs `sudo -n sl-monitor restart …` etc. over SSH. The `-n` flag means "fail immediately if a password is needed" — perfect for a GUI, but it requires that your Pi user can run `sl-monitor` and `sl-flash` without a password. Add a sudoers rule (run **on the Pi**):

```bash
sudo tee /etc/sudoers.d/pi-monitor-gui >/dev/null <<'EOF'
# pi-monitor-gui — passwordless sl-* for the GUI's `sudo -n` calls.
dev ALL=(root) NOPASSWD: /usr/local/bin/sl-monitor, /usr/local/bin/sl-flash, /bin/sh -c rm -f /var/log/pi-monitor/*/*.log*
EOF
sudo chmod 0440 /etc/sudoers.d/pi-monitor-gui
```

Replace `dev` with your actual Pi username if different.

If you skip this, every action button in the GUI will fail with "a password is required" — but the live logs and read-only commands (`sl-status`, `sl-ports`) will still work.

## Optional: SSH ControlMaster (latency improvement)

Reuses one TCP/SSH connection across many GUI commands — every button click feels instant instead of paying ~200 ms per action for a fresh handshake. Add to your laptop's `~/.ssh/config`:

```
Host pi-monitor
    User dev
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s
```

(Adjust `User` to match your Pi username.)

## Install + run

```bash
cd gui/
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# As a regular browser tab:
.venv/bin/python app.py --host dev@pi-monitor

# Or as a standalone desktop window (one-time: pip install pywebview):
.venv/bin/pip install pywebview
.venv/bin/python app.py --host dev@pi-monitor --native
```

Browser opens to `http://localhost:8080`. The first load fetches `ports.conf` and the firmware list from the Pi, then starts streaming.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--host` | `dev@pi-monitor` | `user@host` for SSH and SCP |
| `--native` | off | Open as a PyWebview desktop window instead of a browser tab |
| `--port` | `8080` | Local web server port |

## What the buttons do

| Button | Underneath |
|---|---|
| **Restart all** | `sudo sl-monitor restart` — rolls every active logger over to a new log file |
| **Restart \<name\>** | `sudo sl-monitor restart \<name\>` — rolls just that one |
| **Start loggers (up)** | `sudo sl-monitor up` — enables units, arms udev re-add path, persists across reboots |
| **Stop loggers (down)** | `sudo sl-monitor down` — disables units; won't auto-start on next boot |
| **Wipe past logs…** | `sl-monitor down` → `rm -f /var/log/pi-monitor/*/*.log*` → `sl-monitor up`. Confirm dialog before. |
| **Upload .bin** | SCP a `.bin` file from your laptop to `/var/lib/pi-monitor/firmware/` on the Pi |
| **Flash selected** | `sudo sl-flash /var/lib/pi-monitor/firmware/\<file\>.bin` |

The status dot in each port's header turns **green** when its logger unit is `active`, **grey** when stopped. The "connection" dot in the top-right header turns **red** when SSH is unreachable.

## Architecture (one-paragraph version)

`asyncio.create_subprocess_exec("ssh", host, cmd)` for everything. We use the OS `ssh` client because Tailscale SSH (the auth method used when you run `tailscale up --ssh` on the Pi) is not supported by `paramiko` or `asyncssh` — only OpenSSH knows how to delegate auth to the local `tailscaled`. ControlMaster (in your `~/.ssh/config`) keeps per-call latency near-zero. Each port gets a long-lived stream task running `journalctl -fu uart-logger@<dev> -o cat` and pushing lines into a `ui.log()` widget. Status badges are driven by a 3 s `ui.timer` that runs `systemctl is-active` for each unit.

## Limitations / known gaps

- **Single-host.** The GUI talks to one Pi at a time. No profile-switching UI yet — restart with `--host` to change targets.
- **Auto-reconnect on flaky networks** is best-effort: streams reconnect after 3 s, but the action buttons just fail for the duration of the outage. Re-click after the connection dot goes green.
- **Flash output streaming.** `sl-flash` output appears in the action log only after it completes (one-shot capture, not live). If you need to see flash progress live, use the CLI for now.
- **No persisted state.** Closing the GUI loses scrollback in the log panels. The Pi's `/var/log/pi-monitor/<name>/*.log` files are still authoritative.

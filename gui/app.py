"""pi-monitor-light GUI — laptop-side control panel + live log viewer.

Run:
    python app.py [--host dev@pi-monitor] [--native]

The GUI talks to the Pi over SSH only. Nothing on the Pi changes — we just
wrap the existing sl-* commands and stream `journalctl -fu` per port.

Default target is dev@pi-monitor (Tailscale MagicDNS). Override with --host.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import tempfile
from pathlib import Path
from typing import Optional

from nicegui import app, events, ui

import ssh

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

HOST: str = "dev@pi-monitor"
NATIVE: bool = False

# Per-port runtime state, populated when the page loads.
# Key is the friendly name from ports.conf (e.g. "STM").
log_panels: dict[str, ui.log] = {}
stream_procs: dict[str, asyncio.subprocess.Process] = {}
stream_tasks: dict[str, asyncio.Task] = {}
status_dots: dict[str, ui.icon] = {}

# Top-bar connection indicator + last-action panel (set during UI build).
conn_dot: Optional[ui.icon] = None
action_log: Optional[ui.log] = None
firmware_select: Optional[ui.select] = None

# Cached parse of remote /etc/pi-monitor-light/ports.conf
ports: list[tuple[str, str, int]] = []  # [(dev, name, baud), ...]

# ---------------------------------------------------------------------------
# Helpers — talking to the Pi
# ---------------------------------------------------------------------------

PORTS_CONF_PATH = "/etc/pi-monitor-light/ports.conf"
FIRMWARE_DIR = "/var/lib/pi-monitor/firmware"

_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_DEV_RE = re.compile(r"^tty(USB|ACM)\d+$")


def _parse_ports_conf(text: str) -> list[tuple[str, str, int]]:
    """Mirror of lib/parse-ports.sh validation. Returns [(dev, name, baud), ...]."""
    out: list[tuple[str, str, int]] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        dev, name, baud_s = parts[0], parts[1], parts[2]
        if not _DEV_RE.match(dev) or not _NAME_RE.match(name) or not baud_s.isdigit():
            continue
        out.append((dev, name, int(baud_s)))
        if len(out) >= 4:
            break
    return out


async def fetch_ports() -> list[tuple[str, str, int]]:
    res = await ssh.run(HOST, "cat", PORTS_CONF_PATH)
    if not res.ok:
        notify_error(f"failed to read ports.conf: {res.stderr.strip()}")
        return []
    return _parse_ports_conf(res.stdout)


async def fetch_firmwares() -> list[str]:
    """List .bin files staged in the firmware dir on the Pi."""
    res = await ssh.run(HOST, "ls", "-1", FIRMWARE_DIR)
    if not res.ok:
        return []
    return [f for f in res.stdout.splitlines() if f.endswith(".bin")]


async def fetch_unit_states() -> dict[str, bool]:
    """Return {name: is_active} for each port in the cached ports list."""
    if not ports:
        return {}
    units = " ".join(f"uart-logger@{dev}.service" for dev, _, _ in ports)
    res = await ssh.run(HOST, f"systemctl is-active {units} || true")
    states_per_unit = res.stdout.splitlines()
    out: dict[str, bool] = {}
    for (_, name, _), state in zip(ports, states_per_unit):
        out[name] = state.strip() == "active"
    return out


# ---------------------------------------------------------------------------
# Streaming a single port — long-lived task, restarts on stream end
# ---------------------------------------------------------------------------

async def _stream_port(name: str, dev: str) -> None:
    """Persistent task: stream journalctl -fu for one port into its ui.log panel.

    On any disconnect / SSH failure, sleep briefly and reconnect.
    """
    panel = log_panels[name]
    while True:
        try:
            proc, lines = await ssh.stream(
                HOST,
                "journalctl",
                "-fu", f"uart-logger@{dev}.service",
                "-o", "cat",
                "-n", "50",
                "--no-pager",
            )
        except Exception as e:  # noqa: BLE001
            panel.push(f"[gui] failed to start stream: {e!r}; retrying in 5 s")
            await asyncio.sleep(5)
            continue

        stream_procs[name] = proc
        try:
            async for line in lines:
                panel.push(line)
        except Exception as e:  # noqa: BLE001
            panel.push(f"[gui] stream error: {e!r}")
        finally:
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    proc.kill()
            stream_procs.pop(name, None)

        panel.push("[gui] stream ended; reconnecting in 3 s…")
        await asyncio.sleep(3)


# ---------------------------------------------------------------------------
# Action handlers — driven from sidebar buttons
# ---------------------------------------------------------------------------

def notify_error(msg: str) -> None:
    ui.notify(msg, type="negative", position="top-right")
    if action_log is not None:
        action_log.push(f"[error] {msg}")


def notify_ok(msg: str) -> None:
    ui.notify(msg, type="positive", position="top-right")
    if action_log is not None:
        action_log.push(msg)


async def _run_and_log(label: str, *cmd: str) -> bool:
    """Run a one-shot remote command, push its output to the action_log panel."""
    if action_log is not None:
        action_log.push(f"$ {label}")
    res = await ssh.run(HOST, *cmd)
    if action_log is not None:
        if res.stdout:
            for line in res.stdout.splitlines():
                action_log.push(f"  {line}")
        if res.stderr:
            for line in res.stderr.splitlines():
                action_log.push(f"  ! {line}")
        action_log.push(f"  [exit {res.returncode}]")
    return res.ok


async def action_restart(name: str) -> None:
    """Restart one logger unit (rolls over to a new log file)."""
    target = name if name else ""
    label = f"sudo sl-monitor restart {target}".strip()
    args = ["sudo", "-n", "sl-monitor", "restart"]
    if target:
        args.append(target)
    ok = await _run_and_log(label, *args)
    if ok:
        notify_ok(f"restart {target or 'all'} ok")
    else:
        notify_error(f"restart {target or 'all'} failed — see action log")


async def action_down() -> None:
    if not await _confirm("Stop all loggers? They won't auto-resume on reboot."):
        return
    ok = await _run_and_log("sudo sl-monitor down", "sudo", "-n", "sl-monitor", "down")
    if ok:
        notify_ok("loggers stopped")
    else:
        notify_error("sl-monitor down failed")


async def action_up() -> None:
    ok = await _run_and_log("sudo sl-monitor up", "sudo", "-n", "sl-monitor", "up")
    if ok:
        notify_ok("loggers started")
    else:
        notify_error("sl-monitor up failed")


async def action_wipe() -> None:
    if not await _confirm("Delete ALL past logs? This is irreversible."):
        return
    await _run_and_log("sudo sl-monitor down", "sudo", "-n", "sl-monitor", "down")
    await _run_and_log(
        "rm /var/log/pi-monitor/*/*.log*",
        "sudo", "-n", "sh", "-c", "rm -f /var/log/pi-monitor/*/*.log*",
    )
    ok = await _run_and_log("sudo sl-monitor up", "sudo", "-n", "sl-monitor", "up")
    if ok:
        notify_ok("logs wiped, loggers restarted")
    else:
        notify_error("wipe sequence had a step fail — see action log")


async def action_flash() -> None:
    if firmware_select is None or not firmware_select.value:
        notify_error("pick a firmware file first")
        return
    fname = firmware_select.value
    label = f"sudo sl-flash {FIRMWARE_DIR}/{fname}"
    ok = await _run_and_log(label, "sudo", "-n", "sl-flash", f"{FIRMWARE_DIR}/{fname}")
    if ok:
        notify_ok(f"flashed {fname}")
    else:
        notify_error(f"flash failed — see action log")


async def on_upload(e: events.UploadEventArguments) -> None:
    """Upload a firmware .bin: save locally, scp to the Pi, refresh the dropdown."""
    suffix = Path(e.name).suffix or ".bin"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(e.content.read())
        tmp_path = tmp.name
    try:
        if action_log is not None:
            action_log.push(f"$ scp {e.name} → {FIRMWARE_DIR}/")
        res = await ssh.upload(HOST, tmp_path, f"{FIRMWARE_DIR}/{e.name}")
        if res.ok:
            notify_ok(f"uploaded {e.name}")
            await refresh_firmwares()
        else:
            notify_error(f"upload failed: {res.stderr.strip() or 'rc != 0'}")
    finally:
        Path(tmp_path).unlink(missing_ok=True)


async def refresh_firmwares() -> None:
    if firmware_select is None:
        return
    fws = await fetch_firmwares()
    firmware_select.options = fws
    if fws and (firmware_select.value not in fws):
        firmware_select.value = fws[0]
    firmware_select.update()


async def _confirm(message: str) -> bool:
    """Show a modal yes/no dialog. Returns True if user clicked Confirm."""
    result_future: asyncio.Future[bool] = asyncio.get_event_loop().create_future()
    with ui.dialog() as dialog, ui.card():
        ui.label(message).classes("text-body1")
        with ui.row().classes("justify-end w-full"):
            ui.button("Cancel", on_click=lambda: (dialog.close(), result_future.set_result(False))).props("flat")
            ui.button("Confirm", on_click=lambda: (dialog.close(), result_future.set_result(True))).props("color=negative")
    dialog.open()
    return await result_future


# ---------------------------------------------------------------------------
# Status polling — runs every few seconds
# ---------------------------------------------------------------------------

async def refresh_status() -> None:
    try:
        states = await fetch_unit_states()
    except Exception:  # noqa: BLE001
        if conn_dot is not None:
            conn_dot.props("color=red")
        return
    if conn_dot is not None:
        conn_dot.props("color=green")
    for name, dot in status_dots.items():
        active = states.get(name, False)
        dot.props(f"color={'green' if active else 'grey'}")


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

@ui.page("/")
async def index() -> None:
    global ports, action_log, firmware_select, conn_dot

    # Initial fetches — done synchronously so the layout reflects real state.
    ports = await fetch_ports()
    firmwares = await fetch_firmwares()

    # Header
    with ui.header(elevated=True).classes("items-center"):
        ui.label("pi-monitor").classes("text-h6")
        ui.label(f"@ {HOST}").classes("text-caption ml-3")
        ui.space()
        conn_dot = ui.icon("circle", color="grey").classes("text-sm")
        ui.label("connection").classes("text-caption ml-1")

    # Sidebar — actions
    with ui.left_drawer(value=True, fixed=True).classes("bg-grey-2"):
        ui.label("Actions").classes("text-subtitle1 q-mt-sm")

        ui.button("Restart all", on_click=lambda: action_restart("")).classes("w-full")
        for _, name, _ in ports:
            ui.button(f"Restart {name}", on_click=lambda n=name: action_restart(n)).classes("w-full")

        ui.separator().classes("q-my-md")

        ui.button("Start loggers (up)", on_click=action_up).classes("w-full")
        ui.button("Stop loggers (down)", on_click=action_down).props("color=negative").classes("w-full")
        ui.button("Wipe past logs…", on_click=action_wipe).props("color=negative outline").classes("w-full")

        ui.separator().classes("q-my-md")
        ui.label("Firmware").classes("text-subtitle1")

        ui.upload(
            on_upload=on_upload,
            label="Upload .bin",
            max_files=1,
            auto_upload=True,
        ).classes("w-full")

        firmware_select = ui.select(
            options=firmwares,
            value=firmwares[0] if firmwares else None,
            label="staged firmware",
        ).classes("w-full")

        ui.button("Flash selected", on_click=action_flash).props("color=primary").classes("w-full")

    # Body — one column per port (live logs), then action_log at the bottom.
    if not ports:
        with ui.column().classes("w-full items-center q-mt-xl"):
            ui.icon("warning", color="orange").classes("text-h2")
            ui.label("No ports configured on the Pi.").classes("text-h6")
            ui.label(f"Edit {PORTS_CONF_PATH} and run sudo sl-monitor up.").classes("text-body2")
        return

    with ui.row().classes("w-full no-wrap").style("height: 70vh"):
        for dev, name, baud in ports:
            with ui.column().classes("flex-1 min-w-0"):
                with ui.row().classes("items-center"):
                    dot = ui.icon("circle", color="grey").classes("text-sm")
                    status_dots[name] = dot
                    ui.label(f"{name}").classes("text-h6")
                    ui.label(f"/dev/{dev}  {baud} baud").classes("text-caption ml-2")
                panel = ui.log(max_lines=2000).classes(
                    "w-full h-full bg-grey-9 text-grey-2 q-pa-sm"
                ).style("font-family: monospace; font-size: 12px")
                log_panels[name] = panel

    ui.label("Last action").classes("text-subtitle1 q-mt-md")
    action_log = ui.log(max_lines=400).classes(
        "w-full bg-grey-2 q-pa-sm"
    ).style("font-family: monospace; font-size: 12px; height: 18vh")

    # Kick off background work — one streaming task per port + a status poll.
    for dev, name, _ in ports:
        if name not in stream_tasks or stream_tasks[name].done():
            stream_tasks[name] = asyncio.create_task(_stream_port(name, dev))

    ui.timer(3.0, refresh_status, immediate=True)


# ---------------------------------------------------------------------------
# Lifecycle — clean up subprocesses when the server shuts down
# ---------------------------------------------------------------------------

@app.on_shutdown
async def _shutdown() -> None:
    for proc in list(stream_procs.values()):
        if proc.returncode is None:
            proc.terminate()
    for task in list(stream_tasks.values()):
        task.cancel()
    # let pending cancellations propagate
    await asyncio.sleep(0.1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global HOST, NATIVE
    parser = argparse.ArgumentParser(description="pi-monitor-light GUI control panel")
    parser.add_argument(
        "--host",
        default="dev@pi-monitor",
        help="user@host for SSH (default: dev@pi-monitor)",
    )
    parser.add_argument(
        "--native",
        action="store_true",
        help="open as a desktop window via PyWebview instead of a browser tab",
    )
    parser.add_argument("--port", type=int, default=8080, help="local web server port")
    args = parser.parse_args()
    HOST = args.host
    NATIVE = args.native
    ui.run(
        title=f"pi-monitor — {HOST}",
        port=args.port,
        native=NATIVE,
        reload=False,
        show=not NATIVE,
        favicon="🥧",
    )


if __name__ in ("__main__", "__mp_main__"):
    main()

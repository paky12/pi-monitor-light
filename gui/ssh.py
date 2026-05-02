"""Async SSH helpers for the pi-monitor-light GUI.

We use the OS `ssh` client via asyncio.create_subprocess_exec because Tailscale
SSH (`tailscale up --ssh` on the Pi) speaks a custom auth method that paramiko /
asyncssh do not implement (paramiko issue #2425). The OS ssh client knows how to
delegate auth to the local tailscaled, so subprocess is the only path that works
for both Tailscale SSH and plain key-based SSH.

OpenSSH ControlMaster (configured in ~/.ssh/config) makes per-call connection
overhead near-zero by sharing a single TCP/SSH connection across many commands.
"""

from __future__ import annotations

import asyncio
import shlex
from dataclasses import dataclass
from typing import AsyncIterator


SSH_OPTS = (
    "-o", "BatchMode=yes",          # never prompt for a password — fail fast instead
    "-o", "ServerAliveInterval=15", # detect dead connections within ~30 s
    "-o", "ServerAliveCountMax=2",
)


@dataclass(slots=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


async def run(host: str, *cmd: str, timeout: float = 30.0) -> CommandResult:
    """Run a one-shot remote command. Returns stdout/stderr/returncode.

    `cmd` is passed verbatim to ssh as separate argv entries (no shell on the
    laptop side). The remote side runs it through the user's login shell.
    """
    proc = await asyncio.create_subprocess_exec(
        "ssh", *SSH_OPTS, host, *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise
    return CommandResult(
        returncode=proc.returncode or 0,
        stdout=stdout.decode(errors="replace"),
        stderr=stderr.decode(errors="replace"),
    )


async def stream(
    host: str, *cmd: str
) -> tuple[asyncio.subprocess.Process, AsyncIterator[str]]:
    """Start a long-running remote command. Returns (process, line iterator).

    The caller is responsible for `proc.terminate()` when done — that closes
    the ssh channel, which in turn drops the remote command. Stdout and stderr
    are merged into the same stream so the GUI sees both.
    """
    proc = await asyncio.create_subprocess_exec(
        "ssh", *SSH_OPTS, host, *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    async def _lines() -> AsyncIterator[str]:
        assert proc.stdout is not None
        while True:
            chunk = await proc.stdout.readline()
            if not chunk:
                return
            yield chunk.decode(errors="replace").rstrip("\n")

    return proc, _lines()


async def upload(host: str, local_path: str, remote_path: str, timeout: float = 60.0) -> CommandResult:
    """SCP a single local file to the remote path."""
    proc = await asyncio.create_subprocess_exec(
        "scp", *SSH_OPTS, local_path, f"{host}:{remote_path}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise
    return CommandResult(
        returncode=proc.returncode or 0,
        stdout=stdout.decode(errors="replace"),
        stderr=stderr.decode(errors="replace"),
    )


def quote(s: str) -> str:
    """Shell-quote a single arg for inclusion in a remote shell command line."""
    return shlex.quote(s)

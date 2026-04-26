# pi-monitor-light Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a minimal SSH-only UART monitor + STM32C091 flasher for Raspberry Pi Zero 2 W using only shell scripts, systemd, and udev — no Python, no web framework.

**Architecture:** A systemd template unit (`uart-logger@.service`) is started by udev on USB device add and stopped via `BindsTo=` on remove. Each instance runs `cat /dev/ttyXXX | ts | tee logfile` — kernel does all I/O, no userspace polling. Operator interaction is via `sl-*` shell wrappers and `tmux attach` over SSH. Remote access via Tailscale.

**Tech Stack:** Bash, systemd (unit + udev), tmux, OpenOCD (built from master), Tailscale, moreutils (`ts`), logrotate. Tests use `shellcheck`, `systemd-analyze verify`, and `bats-core`.

**Reference design:** [`docs/plans/2026-04-26-pi-monitor-light-design.md`](2026-04-26-pi-monitor-light-design.md). All file paths, the systemd unit body, the udev rule, the OpenOCD build steps, the power tweaks, and the verification source URLs are documented there. Do not improvise — the design has already been verified against official sources, and any deviations should be flagged back to the user before being implemented.

---

## Test strategy (read this once before starting)

This project has almost no business logic — it's mostly orchestration of existing tools. So tests focus on:

1. **Static checks** for every shell script: `shellcheck -x <script>` must pass with zero warnings.
2. **Systemd verify** for unit files: `systemd-analyze verify <unit>` must report no errors.
3. **bats-core** unit tests for shell scripts that have logic worth testing (the ports.conf parser, `sl-flash` validation, `sl-monitor up/down`).
4. **Manual smoke test** on the real Pi at the end — there's no good substitute for running on the actual hardware.

You can run shellcheck and bats on your dev machine — no Pi required. Install once:
```bash
sudo apt install -y shellcheck bats systemd
```

`bats` test files live in `tests/`. Naming: `tests/<thing>.bats`. Run all with `bats tests/`. Run one file with `bats tests/parse-ports.bats`.

**Commit cadence:** one commit per task. Commit message format: `feat: <thing>` for new files, `fix: <thing>` for corrections, `docs: <thing>` for README/design changes.

---

## Task 1: Scaffold repo skeleton

**Files:**
- Create: `bin/.gitkeep`, `systemd/.gitkeep`, `udev/.gitkeep`, `etc/.gitkeep`, `etc/logrotate.d/.gitkeep`, `boot-overlay/.gitkeep`, `lib/.gitkeep`, `tests/.gitkeep`
- Create: `.gitignore`
- Create: `README.md` (stub — will be filled in Task 14)

**Step 1: Create directory structure**

```bash
mkdir -p bin systemd udev etc/logrotate.d boot-overlay lib tests
touch bin/.gitkeep systemd/.gitkeep udev/.gitkeep etc/.gitkeep \
      etc/logrotate.d/.gitkeep boot-overlay/.gitkeep lib/.gitkeep tests/.gitkeep
```

**Step 2: Write `.gitignore`**

```gitignore
*.swp
*.bak
*~
/openocd-src/
/build/
.DS_Store
```

**Step 3: Write README.md stub**

```markdown
# pi-monitor-light

SSH-only UART monitor + STM32 flashing station for Raspberry Pi Zero 2 W.

See `docs/plans/2026-04-26-pi-monitor-light-design.md` for the full design.

Implementation in progress.
```

**Step 4: Commit**

```bash
git add .gitignore README.md bin systemd udev etc boot-overlay lib tests
git commit -m "feat: scaffold repo directory layout"
```

---

## Task 2: Write the systemd template unit

**Files:**
- Create: `systemd/uart-logger@.service`
- Create: `tests/uart-logger.bats`

**Step 1: Write the failing test**

`tests/uart-logger.bats`:
```bash
#!/usr/bin/env bats

@test "systemd unit file passes systemd-analyze verify" {
  # Pass the file by path; --root= would look under <root>/etc/systemd/system/
  # for the unit name, not resolve the file argument. --recursive-errors=no
  # suppresses errors for EnvironmentFile= paths that exist only on the Pi.
  run systemd-analyze verify --recursive-errors=no \
      systemd/uart-logger@.service
  [ "$status" -eq 0 ]
}

@test "unit file declares User=pi-monitor" {
  grep -q '^User=pi-monitor$' systemd/uart-logger@.service
}

@test "unit uses BindsTo for device lifecycle" {
  grep -q '^BindsTo=dev-%i.device$' systemd/uart-logger@.service
}

@test "unit uses Restart=on-failure (NOT always — see design §6)" {
  grep -q '^Restart=on-failure$' systemd/uart-logger@.service
  ! grep -q '^Restart=always' systemd/uart-logger@.service
}

@test "ExecStopPost emits SESSION END marker" {
  grep -q 'SESSION END' systemd/uart-logger@.service
}

@test "RuntimeDirectory is pi-monitor" {
  grep -q '^RuntimeDirectory=pi-monitor$' systemd/uart-logger@.service
}
```

**Step 2: Run the tests — they should fail (no unit file yet)**

```bash
bats tests/uart-logger.bats
```
Expected: all tests fail.

**Step 3: Create the unit file**

Copy the unit body from `docs/plans/2026-04-26-pi-monitor-light-design.md` §6 verbatim into `systemd/uart-logger@.service`. Do not modify it — it has already been verified.

**Step 4: Run tests — should pass**

```bash
bats tests/uart-logger.bats
```
Expected: all 6 tests pass.

**Step 5: Commit**

```bash
git add systemd/uart-logger@.service tests/uart-logger.bats
git commit -m "feat: add uart-logger systemd template unit"
```

---

## Task 3: Write the udev rule

**Files:**
- Create: `udev/99-pi-monitor.rules`
- Create: `tests/udev.bats`

**Step 1: Write the failing test**

`tests/udev.bats`:
```bash
#!/usr/bin/env bats

@test "udev rule covers ttyUSB devices" {
  grep -q 'KERNEL=="ttyUSB\[0-9\]\*"' udev/99-pi-monitor.rules
}

@test "udev rule covers ttyACM devices" {
  grep -q 'KERNEL=="ttyACM\[0-9\]\*"' udev/99-pi-monitor.rules
}

@test "udev rule tags device for systemd" {
  grep -q 'TAG+="systemd"' udev/99-pi-monitor.rules
}

@test "udev rule sets SYSTEMD_WANTS to start the per-device unit" {
  grep -q 'ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"' udev/99-pi-monitor.rules
}

@test "udev rule only fires on add (not change/remove)" {
  ! grep -q 'ACTION=="change"' udev/99-pi-monitor.rules
  ! grep -q 'ACTION=="remove"' udev/99-pi-monitor.rules
  grep -q 'ACTION=="add"' udev/99-pi-monitor.rules
}
```

**Step 2: Run tests — should fail**

```bash
bats tests/udev.bats
```

**Step 3: Write the rule file**

Copy verbatim from design §7:
```
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", ACTION=="add", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"

SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", ACTION=="add", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}+="uart-logger@%k.service"
```

**Step 4: Run tests — should pass**

**Step 5: Commit**

```bash
git add udev/99-pi-monitor.rules tests/udev.bats
git commit -m "feat: add udev rule to start logger on USB add"
```

---

## Task 4: ports.conf parser library

This is the only piece with real logic worth careful TDD.

**Files:**
- Create: `lib/parse-ports.sh`
- Create: `etc/ports.conf.example`
- Create: `tests/parse-ports.bats`
- Create: `tests/fixtures/ports-valid.conf`
- Create: `tests/fixtures/ports-comments.conf`
- Create: `tests/fixtures/ports-too-many.conf`
- Create: `tests/fixtures/ports-bad-baud.conf`
- Create: `tests/fixtures/ports-malformed.conf`
- Create: `tests/fixtures/ports-trailing-garbage.conf`
- Create: `tests/fixtures/ports-trailing-comment.conf`
- Create: `tests/fixtures/ports-bad-dev.conf`
- Create: `tests/fixtures/ports-bad-name.conf`
- Create: `tests/fixtures/ports-dup-name.conf`

**Step 1: Write the test fixtures**

`tests/fixtures/ports-valid.conf`:
```
ttyUSB0 STM 115200
ttyUSB1 EL  115200
```

`tests/fixtures/ports-comments.conf`:
```
# this is a comment
ttyUSB0 STM 115200

# another comment
ttyACM0 BOOTLOADER 9600
```

`tests/fixtures/ports-too-many.conf`:
```
ttyUSB0 A 115200
ttyUSB1 B 115200
ttyUSB2 C 115200
ttyUSB3 D 115200
ttyUSB4 E 115200
```

`tests/fixtures/ports-bad-baud.conf`:
```
ttyUSB0 STM notanumber
```

**Step 2: Write the failing tests**

`tests/parse-ports.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source lib/parse-ports.sh
}

@test "parse_ports emits one line per port: <dev> <name> <baud>" {
  run parse_ports tests/fixtures/ports-valid.conf
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
  [ "${lines[1]}" = "ttyUSB1 EL 115200" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "parse_ports skips comments and blank lines" {
  run parse_ports tests/fixtures/ports-comments.conf
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
  [ "${lines[1]}" = "ttyACM0 BOOTLOADER 9600" ]
}

@test "parse_ports rejects more than 4 ports" {
  run parse_ports tests/fixtures/ports-too-many.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"max 4 ports"* ]]
}

@test "parse_ports rejects non-numeric baud" {
  run parse_ports tests/fixtures/ports-bad-baud.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"baud"* ]]
}

@test "parse_ports fails on missing file" {
  run parse_ports /no/such/file.conf
  [ "$status" -ne 0 ]
}

@test "parse_ports rejects malformed line (return code 3)" {
  run parse_ports tests/fixtures/ports-malformed.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"malformed"* ]]
}

@test "parse_ports rejects trailing garbage" {
  run parse_ports tests/fixtures/ports-trailing-garbage.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"trailing garbage"* ]]
}

@test "parse_ports allows trailing # comments on data lines" {
  run parse_ports tests/fixtures/ports-trailing-comment.conf
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ttyUSB0 STM 115200" ]
}

@test "parse_ports rejects invalid device name" {
  run parse_ports tests/fixtures/ports-bad-dev.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"invalid device name"* ]]
}

@test "parse_ports rejects name with path traversal" {
  run parse_ports tests/fixtures/ports-bad-name.conf
  [ "$status" -eq 3 ]
  [[ "$output" == *"invalid name"* ]]
}

@test "parse_ports rejects duplicate names (return code 6)" {
  run parse_ports tests/fixtures/ports-dup-name.conf
  [ "$status" -eq 6 ]
  [[ "$output" == *"duplicate name"* ]]
}
```

Additional fixtures for the new tests:

`tests/fixtures/ports-malformed.conf`:
```
ttyUSB0 STM
```

`tests/fixtures/ports-trailing-garbage.conf`:
```
ttyUSB0 STM 115200 garbage trailing words
```

`tests/fixtures/ports-trailing-comment.conf`:
```
ttyUSB0 STM 115200 # primary device
```

`tests/fixtures/ports-bad-dev.conf`:
```
eth0 STM 115200
```

`tests/fixtures/ports-bad-name.conf`:
```
ttyUSB0 ../etc 115200
```

`tests/fixtures/ports-dup-name.conf`:
```
ttyUSB0 STM 115200
ttyUSB1 STM 115200
```

**Step 3: Run tests — should fail (lib/parse-ports.sh doesn't exist)**

```bash
bats tests/parse-ports.bats
```

**Step 4: Implement `lib/parse-ports.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# parse-ports.sh — parse /etc/pi-monitor-light/ports.conf
# Format per line: <kernel-device> <name> <baud>
# Lines starting with # are ignored. Blank lines are ignored. Max 4 ports.
# Emits one validated line per port to stdout.

parse_ports() {
  local file=$1
  if [ ! -f "$file" ]; then
    echo "parse_ports: file not found: $file" >&2
    return 2
  fi

  local count=0
  local seen=''
  local dev name baud rest
  while read -r dev name baud rest; do
    case $dev in ''|\#*) continue ;; esac
    case $dev in
      ttyUSB[0-9]*|ttyACM[0-9]*) ;;
      *) echo "parse_ports: invalid device name (must be ttyUSB<n> or ttyACM<n>): $dev" >&2
         return 3 ;;
    esac
    if [ -z "$name" ] || [ -z "$baud" ]; then
      echo "parse_ports: malformed line: $dev $name $baud" >&2
      return 3
    fi
    case $name in
      *[!A-Za-z0-9_-]*|'')
        echo "parse_ports: invalid name (allowed chars: A-Z a-z 0-9 _ -): $name" >&2
        return 3 ;;
    esac
    case $baud in *[!0-9]*)
      echo "parse_ports: invalid baud (not numeric): $baud" >&2
      return 4
    ;; esac
    case $rest in
      ''|\#*) ;;
      *) echo "parse_ports: trailing garbage on line: $dev $name $baud $rest" >&2
         return 3 ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt 4 ]; then
      echo "parse_ports: max 4 ports allowed" >&2
      return 5
    fi
    case " $seen " in
      *" $name "*)
        echo "parse_ports: duplicate name: $name" >&2
        return 6 ;;
    esac
    seen="$seen $name"
    echo "$dev $name $baud"
  done < "$file"
}

# If sourced, expose the function. If executed directly, run on $1.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -lt 1 ]; then
    echo "Usage: parse-ports.sh <ports.conf>" >&2
    exit 64
  fi
  parse_ports "$1"
fi
```

**Step 5: Run tests — should pass**

```bash
bats tests/parse-ports.bats
```
Expected: all 5 tests pass.

**Step 6: shellcheck**

```bash
shellcheck -x lib/parse-ports.sh
```
Expected: no output (clean).

**Step 7: Write `etc/ports.conf.example`**

```
# pi-monitor-light port configuration
# One port per line, max 4 entries.
# Format: <kernel-device> <name> <baud>
# - <kernel-device>: ttyUSB0..3 or ttyACM0..3 (no /dev/ prefix)
# - <name>: short label, used as log subdirectory name
# - <baud>: integer
# Lines starting with # and blank lines are ignored.

ttyUSB0 STM 115200
ttyUSB1 EL  115200
```

**Step 8: Commit**

```bash
git add lib/parse-ports.sh etc/ports.conf.example tests/parse-ports.bats tests/fixtures/
git commit -m "feat: add ports.conf parser with validation"
```

---

## Task 5: `sl-monitor` script

**Files:**
- Create: `bin/sl-monitor`
- Create: `tests/sl-monitor.bats`

**Step 1: Write the failing test**

`tests/sl-monitor.bats`:
```bash
#!/usr/bin/env bats

@test "sl-monitor with no args prints usage and exits 2" {
  run bin/sl-monitor
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "sl-monitor unknown command exits 2" {
  run bin/sl-monitor frobnicate
  [ "$status" -eq 2 ]
}

@test "sl-monitor passes shellcheck" {
  run shellcheck -x bin/sl-monitor
  [ "$status" -eq 0 ]
}

@test "sl-monitor restart with invalid port name exits 2" {
  run bin/sl-monitor restart 'foo;bar'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid port"* ]]
}
```

**Step 2: Run tests — should fail**

**Step 3: Implement `bin/sl-monitor`**

```bash
#!/usr/bin/env bash
# sl-monitor — start/stop UART logger systemd units based on /etc/pi-monitor-light/ports.conf
set -eu
set -o pipefail

CONF=/etc/pi-monitor-light/ports.conf
ENV_DIR=/etc/pi-monitor-light
LIB=/usr/local/share/pi-monitor-light/parse-ports.sh

usage() {
  cat >&2 <<EOF
Usage: sl-monitor up|down|restart [port]

  up               enable + start logger units for all ports in $CONF
  down             stop + disable all uart-logger@* units
  restart [port]   restart one or all units
EOF
  exit 2
}

write_env_files() {
  # shellcheck source=/dev/null
  . "$LIB"
  # Pre-check: parse_ports failures inside `< <(...)` process substitution
  # do not propagate under set -e (subshell). Run once first to abort early
  # with a clear non-zero exit if the config is invalid.
  parse_ports "$CONF" >/dev/null
  while read -r dev name baud; do
    local tmp="$ENV_DIR/.ports.conf.env-$dev.$$"
    printf 'NAME=%s\nBAUD=%s\n' "$name" "$baud" > "$tmp"
    # rename(2) is atomic on the same filesystem — readers see either
    # the old file or the complete new file, never a torn write.
    mv -f "$tmp" "$ENV_DIR/ports.conf.env-$dev"
  done < <(parse_ports "$CONF")
}

active_units() {
  systemctl list-units --type=service --no-legend 'uart-logger@*' \
    | awk '{print $1}'
}

cmd_up() {
  write_env_files
  # Pre-check: same set -e / process-substitution gotcha as in write_env_files.
  parse_ports "$CONF" >/dev/null
  while read -r dev _ _; do
    systemctl enable --now "uart-logger@${dev}.service"
  done < <(parse_ports "$CONF")
}

cmd_down() {
  for u in $(active_units); do
    systemctl disable --now "$u" || true
  done
}

cmd_restart() {
  if [ -n "${1:-}" ]; then
    # Defensive re-validation — the top-level pre-flight already validated
    # this for the non-root path, but check again here in case cmd_restart
    # is ever called from a different code path.
    case $1 in
      ttyUSB[0-9]*|ttyACM[0-9]*) ;;
      *) echo "sl-monitor: invalid port (must be ttyUSB<n> or ttyACM<n>): $1" >&2; exit 2 ;;
    esac
    systemctl restart "uart-logger@${1}.service"
  else
    for u in $(active_units); do
      systemctl restart "$u"
    done
  fi
}

case ${1:-} in
  up|down|restart) ;;
  *) usage ;;
esac

# Pre-validate restart's port arg before sudo, so error reporting is clean
# and the bats tests can exercise this path as a regular user.
if [ "$1" = "restart" ] && [ -n "${2:-}" ]; then
  case $2 in
    ttyUSB[0-9]*|ttyACM[0-9]*) ;;
    *) echo "sl-monitor: invalid port (must be ttyUSB<n> or ttyACM<n>): $2" >&2; exit 2 ;;
  esac
fi

# Privilege escalation must happen before we shift the subcommand off,
# otherwise sudo re-execs the script with empty argv and falls into usage.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo --preserve-env=PATH "$0" "$@"
fi

case $1 in
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "$@" ;;
  restart) shift; cmd_restart "$@" ;;
esac
```

**Step 4: `chmod +x bin/sl-monitor`**

**Step 5: Run tests — should pass**

```bash
bats tests/sl-monitor.bats
```

**Step 6: Commit**

```bash
git add bin/sl-monitor tests/sl-monitor.bats
git commit -m "feat: add sl-monitor up/down/restart wrapper"
```

---

## Task 6: `sl-ports` script

**Files:**
- Create: `bin/sl-ports`
- Create: `tests/sl-ports.bats`

**Step 1: Write the failing test**

`tests/sl-ports.bats`:
```bash
#!/usr/bin/env bats

@test "sl-ports passes shellcheck" {
  run shellcheck -x bin/sl-ports
  [ "$status" -eq 0 ]
}

@test "sl-ports exits 0 even when no /dev/ttyUSB* present (off-Pi env)" {
  # Override CONF to a known-empty file via env var
  CONF=/dev/null run bin/sl-ports
  [ "$status" -eq 0 ]
}
```

**Step 2: Implement `bin/sl-ports`**

```bash
#!/usr/bin/env bash
# sl-ports — list configured + detected serial ports
set -eu

CONF=${CONF:-/etc/pi-monitor-light/ports.conf}
LIB=${LIB:-/usr/local/share/pi-monitor-light/parse-ports.sh}

print_configured() {
  printf '== Configured (%s) ==\n' "$CONF"
  if [ ! -f "$CONF" ]; then
    echo '  (no config file)'
    return
  fi
  # shellcheck source=/dev/null
  . "$LIB" 2>/dev/null || { echo "  (parser missing: $LIB)"; return; }
  parse_ports "$CONF" | while read -r dev name baud; do
    printf '  /dev/%-10s name=%-10s baud=%s\n' "$dev" "$name" "$baud"
  done
}

print_detected() {
  printf '\n== Detected (kernel) ==\n'
  local found=0
  for d in /dev/ttyUSB[0-9]* /dev/ttyACM[0-9]*; do
    [ -e "$d" ] || continue
    found=1
    info=$(udevadm info --query=property --name="$d" 2>/dev/null \
      | awk -F= '/^ID_VENDOR=|^ID_MODEL=|^ID_SERIAL_SHORT=/ {print $2}' \
      | paste -sd' ' -)
    printf '  %s  %s\n' "$d" "$info"
  done
  [ $found -eq 0 ] && echo '  (none)'
}

print_configured
print_detected
```

**Step 3: chmod +x and run tests**

```bash
chmod +x bin/sl-ports
bats tests/sl-ports.bats
```

**Step 4: Commit**

```bash
git add bin/sl-ports tests/sl-ports.bats
git commit -m "feat: add sl-ports listing wrapper"
```

---

## Task 7: `sl-status` script

**Files:**
- Create: `bin/sl-status`
- Create: `tests/sl-status.bats`

**Step 1: Tests**

```bash
#!/usr/bin/env bats

@test "sl-status passes shellcheck" {
  run shellcheck -x bin/sl-status
  [ "$status" -eq 0 ]
}

@test "sl-status runs without args and exits 0" {
  run bin/sl-status
  [ "$status" -eq 0 ]
}

@test "sl-status reports (none active) when no logger units" {
  run bin/sl-status
  [[ "$output" == *"(none active)"* ]]
}

@test "sl-status reports (empty) when log dir exists but empty" {
  tmp=$(mktemp -d)
  LOG_DIR=$tmp run bin/sl-status
  rmdir "$tmp"
  [[ "$output" == *"(empty)"* ]]
}
```

**Step 2: Implement `bin/sl-status`**

```bash
#!/usr/bin/env bash
# sl-status — show running loggers + log dir sizes
set -u

LOG_DIR=${LOG_DIR:-/var/log/pi-monitor}

echo '== Logger units =='
units=$(systemctl --no-pager --no-legend list-units --type=service 'uart-logger@*' 2>/dev/null || true)
if [ -n "$units" ]; then
  printf '%s\n' "$units"
else
  echo '  (none active)'
fi

echo
echo '== Log sizes =='
if [ ! -d "$LOG_DIR" ]; then
  echo "  ($LOG_DIR does not exist yet)"
else
  shopt -s nullglob
  files=("$LOG_DIR"/*)
  shopt -u nullglob
  if [ ${#files[@]} -gt 0 ]; then
    du -sh "${files[@]}" 2>/dev/null | sort -h
  else
    echo '  (empty)'
  fi
fi
```

**Step 3: chmod +x, test, commit**

```bash
chmod +x bin/sl-status
bats tests/sl-status.bats
git add bin/sl-status tests/sl-status.bats
git commit -m "feat: add sl-status overview wrapper"
```

---

## Task 8: `sl-attach` script

**Files:**
- Create: `bin/sl-attach`
- Create: `tests/sl-attach.bats`

**Step 1: Tests** — `tests/sl-attach.bats`:

```bash
#!/usr/bin/env bats

@test "sl-attach passes shellcheck" {
  run shellcheck -x bin/sl-attach
  [ "$status" -eq 0 ]
}

@test "sl-attach prints help on -h" {
  run bin/sl-attach -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux"* ]]
}
```

**Step 2: Implement `bin/sl-attach`**

```bash
#!/usr/bin/env bash
# sl-attach — open or attach a tmux session with one window per active logger
set -euo pipefail

SESSION=${SESSION:-pi-monitor}

usage() {
  cat <<EOF
Usage: sl-attach

Opens (or attaches to) tmux session "$SESSION" with one window per
active uart-logger@* unit, each running journalctl -f for that unit.

EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

active_ports() {
  systemctl list-units --no-legend --type=service 'uart-logger@*' \
    | awk '{print $1}' \
    | sed -e 's/^uart-logger@//' -e 's/\.service$//'
}

ports=$(active_ports)
if [ -z "$ports" ]; then
  echo 'No active uart-logger@* units. Run: sl-monitor up' >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
fi

first=1
for port in $ports; do
  cmd="journalctl -u uart-logger@${port} -f --output=cat"
  if [ $first -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n "$port" "$cmd"
    first=0
  else
    tmux new-window -t "$SESSION" -n "$port" "$cmd"
  fi
done

exec tmux attach -t "$SESSION"
```

**Step 3: chmod +x, test, commit**

```bash
chmod +x bin/sl-attach
bats tests/sl-attach.bats
git add bin/sl-attach tests/sl-attach.bats
git commit -m "feat: add sl-attach tmux wrapper"
```

---

## Task 9: `sl-flash` script

**Files:**
- Create: `bin/sl-flash`
- Create: `tests/sl-flash.bats`

**Step 1: Tests**

`tests/sl-flash.bats`:
```bash
#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export FW_DIR="$TMPDIR/firmware"
  export OPENOCD=/bin/echo   # mock openocd
  mkdir -p "$FW_DIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "sl-flash passes shellcheck" {
  run shellcheck -x bin/sl-flash
  [ "$status" -eq 0 ]
}

@test "sl-flash with no args prints usage and exits 2" {
  run bin/sl-flash
  [ "$status" -eq 2 ]
}

@test "sl-flash rejects file outside firmware dir" {
  echo dummy > "$TMPDIR/elsewhere.bin"
  run bin/sl-flash "$TMPDIR/elsewhere.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$FW_DIR"* ]]
}

@test "sl-flash rejects non-.bin file" {
  echo dummy > "$FW_DIR/x.elf"
  run bin/sl-flash "$FW_DIR/x.elf"
  [ "$status" -ne 0 ]
}

@test "sl-flash invokes openocd with canonical command for valid .bin" {
  echo dummy > "$FW_DIR/firmware.bin"
  run bin/sl-flash "$FW_DIR/firmware.bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"interface/stlink.cfg"* ]]
  [[ "$output" == *"target/stm32c0x.cfg"* ]]
  [[ "$output" == *"firmware.bin"* ]]
  [[ "$output" == *"0x08000000"* ]]
}
```

**Step 2: Implement `bin/sl-flash`**

```bash
#!/usr/bin/env bash
# sl-flash — flash an STM32C091 .bin via OpenOCD over ST-Link
set -eu

FW_DIR=${FW_DIR:-/var/lib/pi-monitor/firmware}
OPENOCD=${OPENOCD:-/usr/local/bin/openocd}

usage() {
  cat >&2 <<EOF
Usage: sl-flash <binary.bin>

  <binary.bin> must reside under $FW_DIR
  Drop firmware there with: scp firmware.bin pi-monitor:$FW_DIR/
EOF
  exit 2
}

[ $# -eq 1 ] || usage
BIN=$1

case $BIN in *.bin) ;; *) echo "sl-flash: not a .bin file: $BIN" >&2; exit 3 ;; esac

# Realpath check: refuse anything outside FW_DIR (no path traversal via symlinks).
ABS=$(readlink -f -- "$BIN") || { echo "sl-flash: cannot resolve $BIN" >&2; exit 3; }
case $ABS in
  "$FW_DIR"/*) ;;
  *) echo "sl-flash: $BIN is not under $FW_DIR" >&2; exit 3 ;;
esac

[ -r "$ABS" ] || { echo "sl-flash: cannot read $ABS" >&2; exit 3; }

exec "$OPENOCD" \
  -f interface/stlink.cfg \
  -f target/stm32c0x.cfg \
  -c "program $ABS verify reset exit 0x08000000"
```

**Step 3: chmod +x, test, commit**

```bash
chmod +x bin/sl-flash
bats tests/sl-flash.bats
git add bin/sl-flash tests/sl-flash.bats
git commit -m "feat: add sl-flash openocd wrapper with path validation"
```

---

## Task 10: logrotate config + boot-overlay fragments

**Files:**
- Create: `etc/logrotate.d/pi-monitor`
- Create: `boot-overlay/config.txt.fragment`
- Create: `boot-overlay/cmdline.txt.fragment`
- Create: `tests/static-files.bats`

**Step 1: Tests**

`tests/static-files.bats`:
```bash
#!/usr/bin/env bats

@test "logrotate config uses copytruncate" {
  grep -q copytruncate etc/logrotate.d/pi-monitor
}

@test "config.txt fragment disables BT" {
  grep -q '^dtoverlay=disable-bt$' boot-overlay/config.txt.fragment
}

@test "config.txt fragment does NOT reference pwr_led (no PWR LED on Zero 2 W)" {
  ! grep -q 'pwr_led' boot-overlay/config.txt.fragment
}

@test "cmdline fragment is single line" {
  [ "$(wc -l < boot-overlay/cmdline.txt.fragment)" -le 1 ]
}

@test "cmdline fragment contains maxcpus=2" {
  grep -q 'maxcpus=2' boot-overlay/cmdline.txt.fragment
}
```

**Step 2: Create the files**

`etc/logrotate.d/pi-monitor`:
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

`boot-overlay/config.txt.fragment`:
```
# pi-monitor-light power tweaks (appended by install.sh)
dtoverlay=disable-bt
dtparam=act_led_trigger=none
dtparam=act_led_activelow=off
disable_splash=1
```

`boot-overlay/cmdline.txt.fragment` (single line, no trailing newline — install.sh will append it to the existing cmdline):
```
maxcpus=2 consoleblank=0
```

**Step 3: Test, commit**

```bash
bats tests/static-files.bats
git add etc/logrotate.d/pi-monitor boot-overlay/ tests/static-files.bats
git commit -m "feat: add logrotate + boot-overlay fragments"
```

---

## Task 11: `install.sh` — preflight + dirs + deps

`install.sh` is large enough that we split it across three tasks (Task 11 / 12 / 13).

**Files:**
- Create: `install.sh`
- Create: `tests/install-preflight.bats`

**Step 1: Tests for the preflight portion only**

`tests/install-preflight.bats`:
```bash
#!/usr/bin/env bats

@test "install.sh passes shellcheck" {
  run shellcheck -x install.sh
  [ "$status" -eq 0 ]
}

@test "install.sh refuses to run as non-root unless DRY_RUN=1" {
  run bash install.sh preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

@test "install.sh DRY_RUN=1 preflight succeeds without root" {
  run bash -c 'DRY_RUN=1 ./install.sh preflight'
  [ "$status" -eq 0 ]
}
```

**Step 2: Implement `install.sh` skeleton (preflight + dirs + deps only)**

```bash
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
  run apt-get install -y \
    tmux moreutils logrotate \
    libtool autoconf automake pkg-config texinfo \
    libusb-1.0-0-dev libhidapi-dev \
    git ca-certificates curl
}

create_user_and_dirs() {
  step 'system user + directories'
  if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    run useradd --system --no-create-home --shell /usr/sbin/nologin \
                --groups dialout,plugdev "$SVC_USER"
  fi
  # Add operator (the user that ran sudo) to the pi-monitor group so they can read logs.
  if [ -n "${SUDO_USER:-}" ] && [ "$DRY_RUN" != "1" ]; then
    usermod -aG "$SVC_USER" "$SUDO_USER" || true
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
```

**Step 3: Test, commit**

```bash
bats tests/install-preflight.bats
git add install.sh tests/install-preflight.bats
git commit -m "feat: install.sh preflight + apt deps + user/dirs"
```

---

## Task 12: `install.sh` — files + units + udev + power tweaks

Extend `install.sh` with the steps that drop config/scripts in place.

**Files:**
- Modify: `install.sh`
- Modify: `tests/install-preflight.bats` (add cases)

**Step 1: New tests**

Append to `tests/install-preflight.bats`:
```bash
@test "install.sh DRY_RUN=1 install-files prints expected installs" {
  run bash -c 'DRY_RUN=1 ./install.sh install-files'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sl-monitor"* ]]
  [[ "$output" == *"uart-logger@.service"* ]]
  [[ "$output" == *"99-pi-monitor.rules"* ]]
}

@test "install.sh DRY_RUN=1 power-tweaks prints config.txt edits" {
  run bash -c 'DRY_RUN=1 ./install.sh power-tweaks'
  [ "$status" -eq 0 ]
  [[ "$output" == *"config.txt"* ]]
  [[ "$output" == *"cmdline.txt"* ]]
}
```

**Step 2: Add the new functions**

Insert before the `case` block:

```bash
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
    echo "+ append 'maxcpus=2 consoleblank=0' to $cmd (if absent)"
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
```

Add to the case block:
```bash
  install-files)         require_root; install_files ;;
  power-tweaks)          require_root; apply_power_tweaks ;;
```

And to `all)` (after `create_user_and_dirs`):
```bash
    install_files
    apply_power_tweaks
```

**Step 3: Test, commit**

```bash
bats tests/install-preflight.bats
shellcheck -x install.sh
git add install.sh tests/install-preflight.bats
git commit -m "feat: install.sh file install + power tweaks step"
```

---

## Task 13: `install.sh` — openocd source build + tailscale + rpi-connect

**Files:**
- Modify: `install.sh`
- Modify: `tests/install-preflight.bats` (add cases)

**Step 1: New tests**

```bash
@test "install.sh DRY_RUN=1 openocd plans the from-source build" {
  run bash -c 'DRY_RUN=1 ./install.sh openocd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"openocd-src"* ]]
  [[ "$output" == *"./bootstrap"* ]]
  [[ "$output" == *"--enable-stlink"* ]]
}

@test "install.sh DRY_RUN=1 tailscale prints install + up command" {
  run bash -c 'DRY_RUN=1 ./install.sh tailscale'
  [ "$status" -eq 0 ]
  [[ "$output" == *"tailscale.com/install.sh"* ]]
  [[ "$output" == *"--ssh"* ]]
  [[ "$output" == *"--hostname=pi-monitor"* ]]
}
```

**Step 2: Add the new functions**

```bash
build_openocd() {
  step 'build OpenOCD from master (Bookworm package is too old for STM32C0)'
  if [ -x "$PREFIX/bin/openocd" ] && "$PREFIX/bin/openocd" --version 2>&1 \
       | grep -qE 'Open On-Chip Debugger 0\.(1[3-9]|[2-9][0-9])'; then
    echo 'openocd already built and recent enough; skipping'
    return
  fi
  local src=$REPO_DIR/openocd-src
  if [ ! -d "$src" ]; then
    run git clone --depth=1 https://sourceforge.net/p/openocd/code "$src"
  fi
  run sh -c "cd '$src' && ./bootstrap && ./configure --enable-stlink --disable-werror && make -j2 && make install"
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
    echo '+ prompt user; if yes, apt install rpi-connect-lite + enable-linger'
    return
  fi
  printf 'Install rpi-connect-lite as fallback browser-shell access? [y/N] '
  read -r ans
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
```

Add to case:
```bash
  openocd)               require_root; build_openocd ;;
  tailscale)             require_root; install_tailscale ;;
  rpi-connect)           require_root; maybe_install_rpi_connect ;;
```

Add to `all)` (after `apply_power_tweaks`):
```bash
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
```

**Step 3: Test, commit**

```bash
bats tests/install-preflight.bats
shellcheck -x install.sh
git add install.sh tests/install-preflight.bats
git commit -m "feat: install.sh openocd build + tailscale + rpi-connect"
```

---

## Task 14: `uninstall.sh`

**Files:**
- Create: `uninstall.sh`
- Create: `tests/uninstall.bats`

**Step 1: Tests**

```bash
#!/usr/bin/env bats

@test "uninstall.sh passes shellcheck" {
  run shellcheck -x uninstall.sh
  [ "$status" -eq 0 ]
}

@test "uninstall.sh DRY_RUN=1 lists removals" {
  run bash -c 'DRY_RUN=1 ./uninstall.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sl-monitor"* ]]
  [[ "$output" == *"uart-logger@.service"* ]]
  [[ "$output" == *"99-pi-monitor.rules"* ]]
}
```

**Step 2: Implement**

```bash
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
run rm -f /etc/logrotate.d/pi-monitor
run systemctl daemon-reload
run udevadm control --reload-rules

if [ $PURGE -eq 1 ]; then
  echo 'PURGE: removing config, logs, firmware dir, and pi-monitor user'
  run rm -rf "$ETC_DIR" "$LOG_DIR" "$FW_DIR" /var/lib/pi-monitor
  run userdel "$SVC_USER" || true
else
  echo 'Preserved: '"$ETC_DIR"', '"$LOG_DIR"', '"$FW_DIR"' (use --purge to remove)'
fi

# Note: power tweaks in /boot/firmware/* are intentionally not reverted —
# they're harmless and rolling them back risks corrupting the user's cmdline.
echo 'Note: boot-overlay tweaks not reverted — edit /boot/firmware/* by hand if desired.'
```

**Step 3: Test, commit**

```bash
chmod +x uninstall.sh
bats tests/uninstall.bats
git add uninstall.sh tests/uninstall.bats
git commit -m "feat: add uninstall.sh"
```

---

## Task 15: README

**Files:**
- Modify: `README.md`

**Step 1: Replace the stub with operator documentation**

```markdown
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

From your laptop (Tailscale-connected):

    ssh patrik@pi-monitor
    sl-attach                   # tmux session, one window per UART
    scp firmware.bin patrik@pi-monitor:/var/lib/pi-monitor/firmware/
    sl-flash /var/lib/pi-monitor/firmware/firmware.bin

## Commands

| Command | What it does |
|---|---|
| `sl-monitor up\|down\|restart [port]` | Start/stop the per-port logger units |
| `sl-attach` | tmux session with `journalctl -f` per active port |
| `sl-flash <bin>` | Flash a `.bin` from `/var/lib/pi-monitor/firmware/` |
| `sl-ports` | List configured + detected serial devices |
| `sl-status` | Show running loggers + log dir sizes |

## Files

| Path | Purpose |
|---|---|
| `/etc/pi-monitor-light/ports.conf` | Port→name→baud mapping (max 4 entries) |
| `/var/log/pi-monitor/<name>/<ts>.log` | Per-session logs |
| `/var/lib/pi-monitor/firmware/*.bin` | Firmware staging dir |

## Design

See [`docs/plans/2026-04-26-pi-monitor-light-design.md`](docs/plans/2026-04-26-pi-monitor-light-design.md).

## Uninstall

    sudo ./uninstall.sh            # keep logs + config
    sudo ./uninstall.sh --purge    # remove everything
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: write operator README"
```

---

## Task 16: Manual Pi smoke test (the final acceptance gate)

**No code changes.** Documented here so the engineer remembers to do it.

After all the above tasks pass `bats tests/` + `shellcheck -x` on the dev box:

1. **Flash a fresh Raspberry Pi OS Bookworm Lite** to a microSD; first boot, set hostname, enable SSH, configure Wi-Fi.
2. `git clone` this repo, run `sudo ./install.sh`. Expect ~30 min.
3. `sudo nano /etc/pi-monitor-light/ports.conf` — set the real ports.
4. `sudo sl-monitor up` — verify with `sl-status` that the unit is `active (running)`.
5. Plug a UART device; verify `journalctl -u uart-logger@ttyUSB0 -f` shows live data.
6. Unplug it; verify the unit goes inactive AND the log file gets a `SESSION END` marker.
7. Re-plug; verify a *new* log file is created (not appended to the old one) and unit is active again.
8. `scp firmware.bin pi:/var/lib/pi-monitor/firmware/`, then `sl-flash`. Verify openocd output streams to the terminal and ends with `verified`.
9. **Power measurement:** with all loggers running and the ST-Link/FTDIs connected but idle, measure the 5 V rail current with a USB power meter. Target: ≤ 460 mA (= 2.3 W). If over, the design's fallback (`maxcpus=1`, `arm_freq=600`) is documented in design §14.
10. From a different network, `ssh patrik@pi-monitor`; verify Tailscale routing works.

Document any deviations as new tasks; don't silently fix them.

---

## End

After Task 16 passes, the project is complete. Suggested follow-up work (out of scope here): per-port log search/export, browser-uploaded firmware, sending input back to the device.

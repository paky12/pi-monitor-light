# sl-debug v2 — Revised Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Date:** 2026-05-10
**Status:** Approved, supersedes the 2026-05-03 design and implementation docs.
**Scope:** Phase 0a — LLM-assisted log analysis embedded directly in the firmware repo. No separate sibling repo. No batch analyzer in v2.

---

## Why this revision

The 2026-05-03 docs assumed two separate Claude sessions (an "analyzer Claude" in a new `~/Desktop/smartLock/sl-debug/` sibling repo + a "firmware Claude" in `stm-32-firmware/`) communicating through an append-only `shared.md` protocol. The whole append-only / no-edit-conflicts machinery existed to handle that separation.

In practice the user runs **one** Claude Code session in `~/Desktop/smartLock/stm-32-firmware/` and pulls logs into `stm-32-firmware/serial_monitor_outputs/`. The two-session protocol was solving a problem that doesn't exist for this workflow. v2 collapses everything into the firmware repo.

The original plan's good ideas — the schema, the three hard rules, the "verifier is the moat" thesis, the deferred phase 1 (rule library) — all carry over. Only the *placement* changes.

---

## Architecture

```
pi-monitor-light/                                 ← Pi side unchanged
└── gui/
    ├── sl-transfer-log                           ← existing (timestamped snapshots, archival)
    └── sl-pull-logs                              ← NEW (rolling rsync mirror)

stm-32-firmware/                                  ← single Claude session here
├── CLAUDE.md                                     ← extend with "Working with serial logs"
├── scripts/
│   └── lint-findings.sh                          ← NEW (schema validator)
└── serial_monitor_outputs/
    ├── STM/, EL/, …                              ← rsync target, --exclude=findings.md
    └── findings.md                               ← NEW (append-only finding store)
```

**Data flow.** User (or Claude on its behalf) runs `sl-pull-logs`. rsync incrementally syncs `pi-monitor:/var/log/pi-monitor/` → `stm-32-firmware/serial_monitor_outputs/`. The `--exclude=findings.md` flag keeps the finding store untouched; the `--delete` flag keeps the mirror tight (matches the user's "manual single-snapshot" preference). Claude in the firmware repo greps + reads + cites; appends findings to `findings.md` using the schema in CLAUDE.md.

---

## What stays from v1

- The `findings.md` schema (Sessions / Timeline / Quantitative observations / Hypothesis / Repro recipe / Status). Header format `## YYYY-MM-DD HH:MMZ — <port> <title> — [HIGH|MED|LOW] [unconfirmed|confirmed|fixed|wontfix]`.
- The three hard rules: **no paraphrase** (cite log lines by file+line), **append-only** (new findings reference old ones), **specific enough to become a rule** (Repro recipe slot must be regex/threshold/state-machine-shaped).
- The "verifier is the moat" thesis — phase 0a is **discovery**, phase 1 (rule library `verify.py`) only happens once findings accumulate.
- STM32C091 memory map reference (RM0490, RAM `0x2000_0000`–`0x2000_4FFF`, flash `0x0800_0000`+).
- LATS-style multi-hypothesis prompt pattern (added in v2): generate 2–3 competing hypotheses, cite log evidence for and against each, commit with confidence.

## What changes from v1

| v1 | v2 | Why |
|---|---|---|
| Separate `~/Desktop/smartLock/sl-debug/` repo | Lives inside `stm-32-firmware/` | Matches actual workflow |
| Two Claude sessions + protocol | One Claude session in firmware repo | Two was always speculative |
| 6 bash helpers (`list-sessions`, `get-session`, `search-session`, `tail-live`, `diff-sessions`, `pull-logs`) | 1 helper (`sl-pull-logs`) | Claude can grep/cat/zcat/diff/journalctl directly via Bash tool — helpers were only stable signatures for an analyzer-Claude that doesn't exist |
| `analyze.py` batch tool with Anthropic + OpenRouter providers | Deferred indefinitely | No multi-day soaks yet justify overnight catch-up |
| `tests/lint-shared.sh` | `stm-32-firmware/scripts/lint-findings.sh` | Same intent, lives with the file it lints |

---

## Test strategy

Light. The system is orchestration around rsync + grep + an LLM that the user already has.

1. **shellcheck** on `sl-pull-logs` and `lint-findings.sh` — must pass with zero warnings.
2. **bats** unit tests for `sl-pull-logs` (uses `--dry-run` mode; no real Pi needed).
3. **bats** unit tests for `lint-findings.sh` against fixture files (well-formed accepted, malformed rejected).
4. **Manual smoke test** at the end against the real Pi + a real Claude session.

No tests for CLAUDE.md content (it's prose). No tests for `findings.md` initial stub (it's six lines).

---

## Task 1: `pi-monitor-light/gui/sl-pull-logs`

**Files:**
- Create: `pi-monitor-light/gui/sl-pull-logs`
- Test: `pi-monitor-light/tests/sl-pull-logs.bats`

**Step 1: Failing test**

```bash
@test "sl-pull-logs prints help on -h" {
  run gui/sl-pull-logs -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"serial_monitor_outputs"* ]]
}

@test "sl-pull-logs --dry-run prints rsync command without running" {
  run gui/sl-pull-logs --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"--exclude=findings.md"* ]]
  [[ "$output" == *"/var/log/pi-monitor/"* ]]
}

@test "sl-pull-logs --dry-run --host overrides target" {
  run gui/sl-pull-logs --dry-run --host alice@bob.local
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice@bob.local"* ]]
}

@test "sl-pull-logs passes shellcheck" {
  run shellcheck -x gui/sl-pull-logs
  [ "$status" -eq 0 ]
}
```

**Step 2: Implement**

Bash script. Same `--host` flag pattern as `gui/sl-transfer-log` for consistency. Default `HOST=dev@pi-monitor`, default destination `~/Desktop/smartLock/stm-32-firmware/serial_monitor_outputs/`. `--dry-run` echoes the command without running it.

Core command: `rsync -av --delete --exclude=findings.md "$HOST:/var/log/pi-monitor/" "$DEST/"`.

Same SSH prereqs as `sl-transfer-log` (BatchMode + key auth or Tailscale SSH). Make executable (`chmod +x`).

**Step 3: Verify, commit**

```bash
shellcheck -x gui/sl-pull-logs && bats tests/sl-pull-logs.bats
git add gui/sl-pull-logs tests/sl-pull-logs.bats
git commit -m "feat(gui): add sl-pull-logs (rolling rsync mirror, sibling to sl-transfer-log)"
```

---

## Task 2: Extend `stm-32-firmware/CLAUDE.md`

**Files:**
- Modify: `~/Desktop/smartLock/stm-32-firmware/CLAUDE.md`

This is in a separate repo. Read the existing file first to understand structure and tone before adding a new section. Match the existing heading style and prose register.

**Step 1: Read current `stm-32-firmware/CLAUDE.md`**

**Step 2: Add a new section "Working with serial logs"**

Required content, in order:

1. **Where logs live** — `serial_monitor_outputs/<port>/<timestamp>.log` (and rotated `.log.gz`). Per-port subdirs (`STM/`, `EL/`, …) mirror the Pi's `/var/log/pi-monitor/`. Refresh by running `~/Desktop/smartLock/pi-monitor-light/gui/sl-pull-logs` (rsync with `--delete --exclude=findings.md`).
2. **SESSION marker format** — pi-monitor-light's systemd unit frames each capture:
   ```
   === SESSION START 2026-05-03T13:01:42+00:00  name=STM  dev=/dev/ttyUSB0  baud=115200
   ...UART data...
   === SESSION END   2026-05-03T15:42:18+00:00  duration=160m 36s
   ```
   A new session starts on logger restart, USB re-plug, or Pi reboot. Sessions without `=== SESSION END` are still being written.
3. **Big-log navigation pattern** — Claude's `Read` tool caps at 2000 lines. The pattern is **always**:
   - `wc -l <file>` to size first.
   - `grep -n '=== SESSION'` to find session boundaries by line number.
   - `sed -n 'A,Bp' <file>` to read a specific range.
   - `zcat <file>.log.gz | grep -n PATTERN` for rotated files.
   - Never try to read a multi-MB file whole.
4. **The `findings.md` schema.** Append-only. Each finding is one H2 section.

   **Header format:**
   ```
   ## <YYYY-MM-DD HH:MMZ> — <port> <one-line title> — [<severity>] [<state>]
   ```
   - **severity** ∈ `HIGH | MED | LOW`
   - **state** ∈ `unconfirmed | confirmed | fixed | wontfix`

   **Body slots, in this order:**

   | Slot | Purpose |
   |---|---|
   | **Sessions:** | File paths + line ranges + comparison baselines |
   | **Timeline (T = session start):** | Table: `T+` offset, wall-clock, event, log line |
   | **Quantitative observations:** | Cadences, gaps, addresses, counts — numbers, not adjectives |
   | **Hypothesis (analyzer, confidence):** | What's likely happening, and how sure |
   | **Repro recipe:** | Detector pattern + suggested instrumentation (must be regex/threshold/state-machine-shaped) |
   | **Status:** | `open` / `investigating` / `fixed` + commit ref if applicable |

   **Canonical example** — paste this verbatim into CLAUDE.md as the "what good looks like" reference:

   ```markdown
   ## 2026-05-03 14:22Z — STM heartbeat stops mid-session — [HIGH] [unconfirmed]

   **Sessions:**
   - `STM/2026-05-03T13:01:42.log` lines 14823–14881
   - baseline: `STM/2026-05-02T09:14:00.log` (24 h soak, no recurrence)

   **Timeline (T = session start):**
   | T+ | wall | event | log line |
   |---|---|---|---|
   | 00:00:00 | 13:01:42 | SESSION START | 1 |
   | 00:46:57 | 13:48:39 | last `tick=2818` | 14879 |
   | 00:46:58 | 13:48:40 | last printf `addr=0x20000378 val=0x4f` | 14880 |
   | 00:47:01 | 13:48:43 | SESSION END (`Restart=on-failure`) | 14881 |

   **Quantitative observations:**
   - Expected tick cadence: 1.000 s ± 0.05 (measured, baseline)
   - Gap from last tick → session end: 4.0 s (3 missed ticks)
   - Last reported address: `0x20000378` — RAM region per RM0490; distance from `_estack=0x20005000` is 3.2 KB

   **Hypothesis (analyzer, low confidence):** stack approaching reserved region during ISR. Not confirmed — could equally be UART TX FIFO stall or watchdog.

   **Repro recipe:**
   - Detector pattern: `tick=` cadence > 2× expected → mark suspect; followed by SESSION END within 5 s → confirm.
   - Suggested instrumentation: add `stack_hwm=` printf in main loop and re-soak.

   **Status:** open. Awaiting next soak after instrumentation.
   ```
5. **Three hard rules** — no paraphrase (cite log lines by file+line), append-only (state changes are new findings referencing old), specific enough to become a rule (Repro recipe is regex/threshold/state-machine-shaped).
6. **LATS-style multi-hypothesis prompting** — when analyzing, generate 2–3 competing hypotheses (e.g. memory corruption / race / watchdog / FIFO stall), cite raw log evidence both supporting and refuting each, then commit to the most likely with a confidence (low/med/high) in the Hypothesis slot.
7. **STM32C091 memory map reference** — RAM `0x2000_0000`–`0x2000_4FFF` (20 KB), flash `0x0800_0000`+, reset vector `0x0800_0000`. Cite [RM0490](https://www.st.com/resource/en/reference_manual/rm0490-stm32c0-series-advanced-armbased-32bit-mcus-stmicroelectronics.pdf).
8. **Schema validator** — point at `scripts/lint-findings.sh`. Run before committing edits to `findings.md`.

**Step 3: Commit (in the firmware repo)**

```bash
cd ~/Desktop/smartLock/stm-32-firmware
git add CLAUDE.md
git commit -m "docs(claude): add Working with serial logs section (sl-debug v2)"
```

---

## Task 3: Initial `serial_monitor_outputs/findings.md`

**Files:**
- Create: `~/Desktop/smartLock/stm-32-firmware/serial_monitor_outputs/findings.md`

**Step 1: Write the stub**

```markdown
# Firmware debug findings

Append-only. Each finding is one H2 section. See [`../CLAUDE.md`](../CLAUDE.md) for the schema, the three hard rules, and the LATS-style multi-hypothesis prompting guidance.

Validate this file with `scripts/lint-findings.sh serial_monitor_outputs/findings.md` before committing changes.

<!-- findings begin below this line -->
```

**Step 2: Commit (in the firmware repo)**

```bash
cd ~/Desktop/smartLock/stm-32-firmware
git add serial_monitor_outputs/findings.md
git commit -m "docs: initial findings.md (empty append-only finding store)"
```

---

## Task 4: `stm-32-firmware/scripts/lint-findings.sh`

**Files:**
- Create: `~/Desktop/smartLock/stm-32-firmware/scripts/lint-findings.sh`
- Create: `~/Desktop/smartLock/stm-32-firmware/scripts/tests/findings.example.md` (well-formed)
- Create: `~/Desktop/smartLock/stm-32-firmware/scripts/tests/findings.bad-no-repro.md` (missing Repro recipe slot)
- Test: `~/Desktop/smartLock/stm-32-firmware/scripts/tests/lint-findings.bats`

**Step 1: Failing test**

```bash
@test "lint-findings accepts a well-formed findings.md" {
  run scripts/lint-findings.sh scripts/tests/findings.example.md
  [ "$status" -eq 0 ]
}

@test "lint-findings rejects a finding missing the Repro recipe slot" {
  run scripts/lint-findings.sh scripts/tests/findings.bad-no-repro.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"Repro recipe"* ]]
}

@test "lint-findings passes shellcheck" {
  run shellcheck -x scripts/lint-findings.sh
  [ "$status" -eq 0 ]
}
```

**Step 2: Build fixtures**

`findings.example.md` = the canonical "STM heartbeat stops mid-session" example inlined in Task 2 step 2 above. `findings.bad-no-repro.md` = same content with the `**Repro recipe:**` block removed.

**Step 3: Implement**

Bash with `awk` to split on `^## `, then per-section regex:

1. Header pattern: `^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}Z — \S+ .* — \[(HIGH|MED|LOW)\] \[(unconfirmed|confirmed|fixed|wontfix)\]$`.
2. Body must contain literal strings: `**Sessions:**`, `**Timeline`, `**Quantitative observations:**`, `**Hypothesis`, `**Repro recipe`, `**Status:**`.

On failure, print which section + which slot is missing, exit non-zero. ~50 lines of bash.

**Step 4: Verify, commit (in the firmware repo)**

```bash
cd ~/Desktop/smartLock/stm-32-firmware
shellcheck -x scripts/lint-findings.sh && bats scripts/tests/lint-findings.bats
git add scripts/lint-findings.sh scripts/tests/
git commit -m "feat(scripts): add lint-findings.sh schema validator"
```

---

## Task 5: This document — DONE on commit

The two 2026-05-03 v1 docs were deleted in the same commit; their content remains in git history (`git log --all --diff-filter=D -- 'docs/plans/2026-05-03-smart-debugger-*.md'`).

```bash
cd ~/Desktop/smartLock/pi-monitor-light
git add docs/plans/2026-05-10-sl-debug-revised-plan.md
git rm docs/plans/2026-05-03-smart-debugger-design.md \
       docs/plans/2026-05-03-smart-debugger-implementation.md
git commit -m "docs(plans): supersede v1 sl-debug docs with v2 revised plan"
```

---

## Task 6: Manual smoke test

Run after Tasks 1–5 are green. Not automatable.

1. **Pull logs:** from a laptop terminal, `~/Desktop/smartLock/pi-monitor-light/gui/sl-pull-logs`. Verify `serial_monitor_outputs/STM/`, `EL/`, etc. populate.
2. **Verify findings.md survives:** confirm `serial_monitor_outputs/findings.md` is still present after the rsync (the `--exclude` flag should protect it).
3. **Open Claude Code in the firmware repo:** `cd ~/Desktop/smartLock/stm-32-firmware && claude`.
4. **Ask Claude to analyze the latest STM session.** Verify it: (a) uses the navigation pattern from CLAUDE.md (`wc -l` → `grep -n '=== SESSION'` → `sed -n` for ranges), (b) emits 2–3 hypotheses per the LATS guidance, (c) appends a finding to `findings.md` with all six schema slots and a `[severity]` + `[state]` header.
5. **Run the linter:** `scripts/lint-findings.sh serial_monitor_outputs/findings.md`. Expect pass.
6. **Commit the first real finding:**
   ```bash
   cd ~/Desktop/smartLock/stm-32-firmware
   git add serial_monitor_outputs/findings.md
   git commit -m "chore: first sl-debug finding from manual smoke test"
   ```

If any step fails, file an issue against this plan and stop — don't paper over with quick patches.

---

## Out of scope (deferred, not blocking v2)

- **`analyze.py` batch tool** — design spec'd in v1 §6 ("Batch" use case). Defer until a multi-day soak actually justifies overnight catch-up.
- **MCP toolbox (phase 0b)** — wrapping helpers as MCP tools. v2 has only one helper (`sl-pull-logs`); not enough surface to justify MCP.
- **Phase 1 rule library (`verify.py`)** — auto-derive deterministic rules from `[confirmed]` findings. Needs ≥10 confirmed findings before it's worth building.
- **Phase 2 autoresearcher loop** — gated on phase 1 verifier existing.
- **Cross-port correlation** — findings spanning STM and EL at the same wall-clock. Schema is per-port; cross-port is possible but not first-class.
- **Token-cost guardrails** — observe spend, add caps later if needed.

---

## References

- v1 docs (deleted, kept in git history): `git log --all --diff-filter=D -- 'docs/plans/2026-05-03-smart-debugger-*.md'` to retrieve. The v1 design's schema, hard rules, edge cases, and philosophy are all restated in this v2 plan; only the architecture (separate repo + two Claudes) changed.
- Upstream system: [`docs/plans/2026-04-26-pi-monitor-light-design.md`](2026-04-26-pi-monitor-light-design.md). The Pi-side is unchanged in v2.
- ST Microelectronics, [RM0490 STM32C0 reference manual](https://www.st.com/resource/en/reference_manual/rm0490-stm32c0-series-advanced-armbased-32bit-mcus-stmicroelectronics.pdf) — DUT memory map cited in CLAUDE.md.
- Karpathy, [autoresearch](https://github.com/karpathy/autoresearch); FeSens, [auto-arch-tournament](https://github.com/FeSens/auto-arch-tournament/blob/main/docs/auto-arch-tournament-blog-post.md) — "verifier is the moat" sources, still relevant for the deferred phase 1/2.

---

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)

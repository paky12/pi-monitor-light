# sl-debug — Smart Debugger for pi-monitor-light Logs — Design

**Date:** 2026-05-03
**Status:** Approved, ready for implementation
**Scope:** v1 = phase 0a only (CLI + bash helpers + Claude Code + `analyze.py` + `shared.md`). Phases 0b/1/2 are sketched as plug-points, not built.

---

## 1. Goal

An LLM-assisted debugging system that consumes the per-session UART log files produced by `pi-monitor-light` and accumulates structured findings into a shared, append-only `shared.md` consumed by a separate firmware-Claude session.

The system runs **entirely on the developer laptop**. Pi-monitor-light on the Pi is unmodified — same constraint as the existing `gui/` panel.

## 2. Non-goals

- **No optimizer mode.** Debugger only. Optimization (autoresearcher-shape loops over a metric) is deferred to phase 2 and explicitly out of scope for v1.
- **No Pi-side code, daemon, or service.** Logs flow Pi → laptop via `rsync` only.
- **No browser/web UI.** If wanted later, integrate as a tab in the existing `gui/` NiceGUI panel.
- **No vector DB / RAG / persistent index.** Files + grep + the model's context window.
- **No prompt-orchestration framework** (LangChain, Llama-Index, etc.). Straight provider SDK calls.
- **No automated firmware flash from analyzer findings.** Human-in-the-loop until the phase-1 verifier exists.
- **No multi-host / multi-Pi support.** Single Pi, single laptop.
- **No MCP server, no rule library, no agent loop in v1.** All deferred to later phases.

## 3. Background and approach

The system is shaped by two observations:

1. **The verifier is the moat.** Inspired by Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) and FeSens' [auto-arch-tournament](https://github.com/FeSens/auto-arch-tournament). Both projects work because the gate that decides "kept vs. discarded" is a sharp, mechanical, machine-readable verifier — not LLM judgment. An autoresearcher loop without a sharp verifier confidently climbs the wrong hill.
2. **For our DUT, the verifier doesn't exist yet.** Failure fingerprints in the smart-lock firmware's `printf` stream are unknown. Until we know what "broken" looks like, we cannot build a deterministic detector. Therefore v1 is a **discovery tool**, not a watchdog. Its findings *populate* the future verifier.

This drives a phased plan:

| Phase | What it produces | Built in |
|---|---|---|
| **0a** | LLM-assisted log exploration. Findings in `shared.md`. | **v1, this design** |
| **0b** | Helpers re-exposed as MCP tools for non-CLI Claude clients. | Future |
| **1** | Deterministic rule library derived from confirmed phase-0 findings (`verify.py`). | Future |
| **2** | Autoresearcher-style loop with phase-1 verifier as the rollback gate. | Future |

V1 ships with **plug points** for later phases (see §10) so they don't require a rewrite.

## 4. Architecture

```
                          ┌────────────────────────────┐
                          │  Pi (pi-monitor-light)     │
                          │  unchanged                 │
                          │  /var/log/pi-monitor/*/*.log
                          └─────────────┬──────────────┘
                                        │ ssh + rsync (laptop pulls)
                                        ▼
                          ┌────────────────────────────┐
                          │  laptop: sl-debug/ repo    │
                          │  ├ logs-mirror/ (gitignored)
                          │  ├ helpers/                │
                          │  ├ analyze/analyze.py      │
                          │  ├ CLAUDE.md               │
                          │  └ shared.md (append-only) │
                          └────┬──────────────────┬────┘
                               │                  │
            ┌──────────────────▼──┐   ┌───────────▼──────────────────┐
            │ Claude Code session │   │ analyze.py                   │
            │ (subscription)      │   │ (Anthropic or OpenRouter API)│
            │ interactive A+B     │   │ batch / overnight            │
            └──────────────────┬──┘   └───────────┬──────────────────┘
                               │                  │
                               └────append────────┘
                                        ▼
                          ┌────────────────────────────┐
                          │  shared.md                 │
                          │  (read by firmware-Claude  │
                          │   in the firmware repo)    │
                          └────────────────────────────┘
```

Both LLM harnesses use the same bash helpers and write to the same `shared.md` schema. The firmware-Claude — a *separate* Claude Code session in the firmware repo — reads `shared.md` for `[open]` findings and proposes fixes. **`shared.md` is the protocol**: append-only on the analyzer side, read-only on the firmware side. No bidirectional IPC, no edit-conflict races.

## 5. Components

A new repo at `~/Desktop/smartLock/sl-debug/`, sibling of `pi-monitor-light/`.

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Onboarding for any Claude Code session in the dir. Describes helpers, schema, hard rules. |
| `helpers/pull-logs` | `rsync -av pi-monitor:/var/log/pi-monitor/ ./logs-mirror/` |
| `helpers/list-sessions [port]` | Enumerate `logs-mirror/<port>/*.log[.gz]` with start/end times, mark `[live]` if no end marker. |
| `helpers/get-session <port> <id> [--lines a-b\|--head N\|--tail N]` | Print one session, transparently `zcat` rotated logs. |
| `helpers/search-session <port> <id> <regex>` | `grep -n` with context. |
| `helpers/tail-live <port>` | `ssh pi-monitor "journalctl -fu uart-logger@<dev> -o cat"` (mirrors `sl-attach`). |
| `helpers/diff-sessions <port> <id1> <id2>` | Unified diff. |
| `logs-mirror/` | rsync target, gitignored. |
| `analyze/analyze.py` | Read one session, call provider, append findings. Provider via env var (`LLM_PROVIDER={anthropic,openrouter}`, `LLM_MODEL=…`). |
| `analyze/prompts/system.md` | Analyzer system prompt — schema, citation rules, "specific enough to become a phase-1 rule" requirement, STM32C091 memory map. |
| `shared.md` | Append-only findings file. Committed to git. |
| `.analyzed-sessions` | Record of sessions already processed by `analyze.py` so re-runs skip them. |
| `.failed-sessions` | Sessions where the API call failed three times. Retried later. |
| `tests/` | Helper unit tests, schema lint, regression script. |

## 6. Data flow

**Post-hoc (use case B).** User runs `helpers/pull-logs`, opens Claude Code in the dir, asks *"summarize last STM session."* Claude reads `CLAUDE.md`, calls `list-sessions STM` → `get-session STM <id>`, identifies anomalies, calls `search-session` for raw line citations, appends a finding to `shared.md` via `Edit`. User commits.

**Live (use case A).** User runs `tail-live STM` in one terminal to watch. In a Claude Code tab, periodically asks *"anything weird in the latest STM session?"* — Claude calls `pull-logs` to refresh the local mirror, then analyzes the freshest session. Live monitoring is **human-triggered refresh**, not a daemon.

**Batch.** `python analyze/analyze.py --port STM --since 2026-05-01 --provider openrouter --model anthropic/claude-haiku-4.5` walks each session in the range, runs the analyzer prompt once per session, appends findings to `shared.md`. Skips sessions in `.analyzed-sessions`. Use case: catch up after a multi-day soak, or re-analyze after the system prompt is updated.

**Firmware-Claude side (use case D).** Separate Claude Code session opened in the firmware repo. Reads `../sl-debug/shared.md`, filters by `[open] [HIGH]`, proposes code changes, asks the human to flash and re-soak. Does **not** write back to `shared.md` — references finding IDs in firmware commit messages instead.

## 7. `shared.md` schema

Append-only. Each finding is one H2 section. Header format:

```
## <YYYY-MM-DD HH:MMZ> — <port> <one-line title> — [<severity>] [<state>]
```

Where:

- **severity** ∈ `HIGH | MED | LOW`
- **state** ∈ `unconfirmed | confirmed | fixed | wontfix`

Body slots, in order:

| Slot | Purpose | Becomes (phase 1) |
|---|---|---|
| **Sessions** | File paths + line ranges + comparison baselines | The corpus for rule unit-tests |
| **Timeline** | Table: `T+` offset, wall-clock, event, log line | Sequence templates for state-machine rules |
| **Quantitative observations** | Cadences, gaps, addresses, counts — numbers, not adjectives | Threshold values for rules |
| **Hypothesis (confidence)** | What Claude thinks is going on, and how sure | Discarded — rules don't carry hypotheses |
| **Repro recipe** | Detector pattern + suggested instrumentation | The literal source for the phase-1 rule |
| **Status** | `open` / `investigating` / `fixed` + commit ref if applicable | Triage filter |

### Hard rules (enforced via `CLAUDE.md`)

1. **No paraphrase.** Every observation cites a log line by file + line number; the analyzer copy-pastes the relevant raw line into the finding. Downstream readers (firmware-Claude, future-you) trust the citation, not the paraphrase.
2. **Append-only.** Findings are not edited after they are written. State changes happen by **appending a new finding** that references the old one. This avoids edit conflicts when two sessions touch the file and preserves the audit trail.
3. **Specific enough to become a rule.** Before appending, the analyzer asks itself: *could a regex / threshold / state-machine encode this?* If no, the finding goes back for more detail.

### Canonical example

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

**Hypothesis (Claude, low confidence):** stack approaching reserved region during ISR. Not confirmed — could equally be UART TX FIFO stall or watchdog.

**Repro recipe (for firmware-Claude / future detector):**
- Detector pattern: `tick=` cadence > 2× expected → mark suspect; followed by SESSION END within 5 s → confirm.
- Suggested instrumentation: add `stack_hwm=` printf in main loop and re-soak.

**Status:** open. Awaiting next soak after instrumentation.
```

## 8. Edge cases & error handling

| Situation | Behavior |
|---|---|
| Pi unreachable | `pull-logs` exits non-zero. Claude detects via exit code, falls back to existing local mirror, includes a warning in the finding ("based on logs through `<last-rsync-time>`, Pi unreachable since"). |
| Session in progress (no end marker) | `list-sessions` flags as `[live]`. Analyzer is told (in `CLAUDE.md`) not to draw timing conclusions from a session being actively written. |
| Log too big for context | `get-session` supports `--lines a-b`, `--head N`, `--tail N`. `analyze.py` chunks at SESSION-START markers for files >50 MB and produces per-chunk findings + a roll-up. |
| Concurrent writes to `shared.md` | Append-only handles common case. Simultaneous flushes resolve trivially in git — both blocks survive. |
| `analyze.py` killed mid-run | One finding per write + flush; `.analyzed-sessions` updated only after a successful append. Worst case on resume: one duplicate finding. |
| Log rotation (gz) | rsync mirrors both `.log` and `.log.N.gz`. `get-session` and `search-session` transparently `zcat`. |
| Address / register interpretation | System prompt includes a static reference block: "STM32C091 RAM 0x2000_0000–0x2000_4FFF (20 KB), flash 0x0800_0000–…, reset vector at 0x0800_0000." Sourced from ST [RM0490](https://www.st.com/resource/en/reference_manual/rm0490-stm32c0-series-advanced-armbased-32bit-mcus-stmicroelectronics.pdf). Maintained by hand. |
| API rate limit / outage | `analyze.py` retries with exponential backoff. After 3 failures, session ID goes into `.failed-sessions` and the script continues. |
| Provider divergence | Each finding's header records the analyzer (`claude-code` vs `analyze.py provider/model`) so cross-provider drift is visible. |

## 9. Testing

You **cannot** auto-evaluate "did Claude correctly identify the bug" in phase 0. That gap is the literal reason phase 1 exists. But you *can* test plumbing:

1. **Helper unit tests** — synthetic log fixtures in `tests/fixtures/` + expected outputs. `tests/run.sh` runs them all.
2. **Schema lint** — `tests/lint-shared.sh` greps `shared.md` for required H2 header structure (severity tag, state tag) and required body slots. Runs on every commit.
3. **Prompt dry-run** — `analyze.py --dry-run` builds the prompt and prints it without calling the API. Verifies prompt changes don't blow past context.
4. **Regression over confirmed findings** — `tests/regression.sh` re-runs `analyze.py` on a session that previously yielded a `[confirmed]` finding, then checks that the new finding's *Repro-recipe pattern* matches the old one's. Compares rule-shape, not prose. Drift means the prompt or model is slipping.
5. **Manual eval log** — `docs/eval.md`, free-form: "session X, expected analyzer to flag Y, did it / didn't it / partial." Cheap, manual, but it's the only honest content-quality signal in phase 0. This file justifies graduating to phase 1.

## 10. Plug points for later phases

| Future need | V1 affordance | Why no rewrite required |
|---|---|---|
| Phase 0b — MCP toolbox | `helpers/*` are plain bash with stable signatures. | Wrapping each helper in an MCP tool is a thin layer, not a redesign. |
| Phase 1 — rule library | Schema's `Repro recipe` slot is the literal input format for rule files. | A `verify.py` walks `shared.md` for `[confirmed]` findings, codegens regex / threshold / state-machine rules. |
| Phase 1 — verifier as gate | `shared.md` headers are greppable for `[open] [HIGH]` finding IDs. | `verify.py` exits non-zero if any known fingerprint reappears in a soak session. |
| Phase 2 — autoresearcher loop | `analyze.py` already takes provider/model via env var. | Phase 2's loop driver calls `analyze.py` + `verify.py` with different prompts/configs. |

## 11. Open questions (deferred, not blocking v1)

- Token budgets / cost guardrails — observe spend in v1, add caps later if needed.
- `shared.md` size — if it grows to thousands of findings, partition by year or status. No plan now.
- Multi-DUT — same laptop debugging multiple smart-lock variants in parallel. Possible by running multiple `sl-debug` repos; not designed for explicitly.
- Cross-port correlation — current schema is per-port. Findings spanning STM and EL are possible but not first-class. Address if it shows up in practice.

---

## References

- Karpathy, [autoresearch](https://github.com/karpathy/autoresearch) — single-GPU nanochat training automated research loop.
- FeSens, [auto-arch-tournament](https://github.com/FeSens/auto-arch-tournament/blob/main/docs/auto-arch-tournament-blog-post.md) — open RTL design tournament; "the verifier is the moat."
- digitalandrew, [wairz](https://github.com/digitalandrew/wairz) — firmware analysis platform; `wairz-uart-bridge.py` MCP pattern is the model for phase 0b.
- ST Microelectronics, [RM0490 STM32C0 reference manual](https://www.st.com/resource/en/reference_manual/rm0490-stm32c0-series-advanced-armbased-32bit-mcus-stmicroelectronics.pdf) — DUT memory map.
- `pi-monitor-light/docs/plans/2026-04-26-pi-monitor-light-design.md` — upstream system this design consumes.

---

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)

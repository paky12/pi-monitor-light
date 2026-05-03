# sl-debug Smart Debugger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the v1 (phase 0a) smart-debugger system: a laptop-side LLM-assisted log analyzer that consumes pi-monitor-light's per-session UART logs via rsync and accumulates structured findings in an append-only `shared.md` consumed by a separate firmware-Claude session.

**Architecture:** A new sibling repo at `~/Desktop/smartLock/sl-debug/`. A handful of small bash helpers (one job per file) wrap `ssh`/`rsync`/`grep`/`zcat` against the Pi's log files. An `analyze/analyze.py` script provides the same access programmatically and calls either the Anthropic API or OpenRouter to generate findings in batch. Both Claude Code (interactive) and `analyze.py` (batch) write to the same append-only `shared.md` using the same schema. Pi-monitor-light on the Pi is unchanged.

**Tech Stack:** Bash, rsync, ssh, GNU coreutils, gzip; Python 3.11+ with the official `anthropic` SDK and `requests` (for OpenRouter — its REST API is OpenAI-compatible). Tests use `shellcheck` + `bats-core` for shell, `pytest` for Python.

**Reference design:** [`docs/plans/2026-05-03-smart-debugger-design.md`](2026-05-03-smart-debugger-design.md). All schema details, hard rules, edge-case behavior, and rationale are documented there. Do not improvise structure — flag deviations back to the user before implementing them.

---

## Test strategy (read once before starting)

The system has almost no business logic — it's orchestration around existing tools (rsync, grep, zcat, an LLM API). Tests focus on:

1. **Static checks** for every shell script: `shellcheck -x <script>` must pass with zero warnings.
2. **bats-core** unit tests for helpers, using **synthetic log fixtures** in `tests/fixtures/`. No real Pi or SSH required.
3. **pytest** unit tests for `analyze.py`, with the LLM provider mocked via `unittest.mock` (`monkeypatch.setattr` on the `anthropic.Anthropic` and `requests.post` boundaries). No real API calls in CI.
4. **Schema lint** test: `tests/lint-shared.sh` greps a fixture `shared.md.example` and confirms required headers/slots are detected. Must reject malformed fixtures.
5. **Manual smoke test** at the end against a real Pi running pi-monitor-light — there is no substitute.

Install dev deps once:

```bash
sudo apt install -y shellcheck bats rsync gzip
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt   # pytest, anthropic, requests
```

Naming: shell tests `tests/<helper>.bats`, python tests `tests/test_<module>.py`.

---

## Task 1: Bootstrap repo

**Files:**
- Create: `~/Desktop/smartLock/sl-debug/.gitignore`
- Create: `~/Desktop/smartLock/sl-debug/README.md` (one-liner pointer to design doc; expanded in Task 16)
- Create: directory tree (`helpers/`, `analyze/prompts/`, `tests/fixtures/STM/`, `tests/fixtures/EL/`, `logs-mirror/`)

**Step 1: Create the repo and structure**

```bash
mkdir -p ~/Desktop/smartLock/sl-debug
cd ~/Desktop/smartLock/sl-debug
git init
mkdir -p helpers analyze/prompts tests/fixtures/STM tests/fixtures/EL logs-mirror
touch logs-mirror/.gitkeep
```

**Step 2: Write `.gitignore`**

```
logs-mirror/*
!logs-mirror/.gitkeep
.analyzed-sessions
.failed-sessions
.venv/
__pycache__/
*.pyc
```

**Step 3: Write minimal `README.md`**

```markdown
# sl-debug

Laptop-side LLM-assisted debugger for [pi-monitor-light](../pi-monitor-light) logs.

See [design doc](../pi-monitor-light/docs/plans/2026-05-03-smart-debugger-design.md).

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)
```

**Step 4: Initial commit**

```bash
git add .
git commit -m "init: sl-debug scaffolding"
```

---

## Task 2: `CLAUDE.md` (analyzer onboarding doc)

**Files:**
- Create: `~/Desktop/smartLock/sl-debug/CLAUDE.md`

`CLAUDE.md` is read by every Claude Code session that opens the dir. It must specify the schema, hard rules, available helpers, and workflow. Match the design doc §7 exactly.

**Step 1: Write `CLAUDE.md`**

Required sections:

1. **Purpose** (one paragraph): "You are an analyzer Claude. Your job is to read pi-monitor-light log sessions and append structured findings to `shared.md`. A separate firmware-Claude reads your findings and proposes fixes."
2. **Available helpers** — table of every script in `helpers/` with one-line descriptions. Reference each by its bash signature.
3. **Workflow**:
   - Run `helpers/pull-logs` first to refresh local mirror.
   - Use `helpers/list-sessions` and `helpers/get-session` to read.
   - When you find an anomaly, append to `shared.md` (never edit existing entries).
4. **`shared.md` schema** — copy the full schema spec from design doc §7 verbatim, including the canonical example.
5. **Three hard rules** (verbatim from design §7):
   - No paraphrase. Cite log lines by file+line number.
   - Append-only. State changes are new findings referencing the old.
   - Specific enough to become a rule. Repro recipe slot mandatory.
6. **STM32C091 memory map reference** — RAM `0x2000_0000`–`0x2000_4FFF` (20 KB), flash `0x0800_0000`+, reset vector `0x0800_0000`. Cite [RM0490](https://www.st.com/resource/en/reference_manual/rm0490-stm32c0-series-advanced-armbased-32bit-mcus-stmicroelectronics.pdf).

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with schema and hard rules"
```

---

## Task 3: `helpers/pull-logs`

**Files:**
- Create: `helpers/pull-logs`
- Test: `tests/pull-logs.bats`

**Step 1: Write the failing test**

```bash
# tests/pull-logs.bats
#!/usr/bin/env bats

@test "pull-logs prints rsync command and exits non-zero on unreachable host" {
    run env PI_HOST=nonexistent.invalid ./helpers/pull-logs
    [ "$status" -ne 0 ]
}

@test "pull-logs --dry-run shows the rsync command" {
    run ./helpers/pull-logs --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"rsync"* ]]
    [[ "$output" == *"/var/log/pi-monitor/"* ]]
}
```

**Step 2: Run, verify failure**

```bash
bats tests/pull-logs.bats
# Expected: file does not exist / not executable
```

**Step 3: Implement**

```bash
#!/usr/bin/env bash
# helpers/pull-logs — rsync pi-monitor's logs to ./logs-mirror/
set -euo pipefail
HOST="${PI_HOST:-pi-monitor}"
DEST="${SL_DEBUG_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/logs-mirror"
SRC_PATH="/var/log/pi-monitor/"

CMD=(rsync -av --delete "${HOST}:${SRC_PATH}" "${DEST}/")
if [ "${1:-}" = "--dry-run" ]; then
    echo "${CMD[*]}"
    exit 0
fi
"${CMD[@]}"
```

`chmod +x helpers/pull-logs`.

**Step 4: Run, verify pass**

```bash
shellcheck -x helpers/pull-logs && bats tests/pull-logs.bats
```

**Step 5: Commit**

```bash
git add helpers/pull-logs tests/pull-logs.bats
git commit -m "feat(helpers): add pull-logs (rsync from pi-monitor)"
```

---

## Task 4: `helpers/list-sessions`

**Files:**
- Create: `helpers/list-sessions`
- Create: `tests/fixtures/STM/2026-05-03T13:01:42.log`, `tests/fixtures/STM/2026-05-03T15:43:00.log`, `tests/fixtures/EL/2026-05-03T13:01:42.log`
- Test: `tests/list-sessions.bats`

**Step 1: Create fixtures**

Two STM session files: one with a SESSION END marker (ended cleanly), one without (still live). One EL session.

```
=== SESSION START 2026-05-03T13:01:42+00:00  name=STM  dev=/dev/ttyUSB0  baud=115200
boot ok
tick=1
=== SESSION END   2026-05-03T13:48:43+00:00  duration=47m 1s
```

**Step 2: Write failing test**

```bash
@test "list-sessions STM lists both sessions, marks one [live]" {
    run env SL_DEBUG_DIR="$BATS_TEST_DIRNAME" \
        SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" \
        ./helpers/list-sessions STM
    [ "$status" -eq 0 ]
    [[ "$output" == *"2026-05-03T13:01:42"* ]]
    [[ "$output" == *"2026-05-03T15:43:00"* ]]
    [[ "$output" == *"[live]"* ]]
}

@test "list-sessions with no port lists all ports" {
    run env SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" ./helpers/list-sessions
    [[ "$output" == *"STM"* ]]
    [[ "$output" == *"EL"* ]]
}
```

**Step 3: Implement**

```bash
#!/usr/bin/env bash
# helpers/list-sessions [port] — enumerate logs-mirror/<port>/*.log[.gz] with start/end times
set -euo pipefail
ROOT="${SL_DEBUG_MIRROR:-$(cd "$(dirname "$0")/.." && pwd)/logs-mirror}"

ports=("$@")
if [ ${#ports[@]} -eq 0 ]; then
    mapfile -t ports < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
fi

for port in "${ports[@]}"; do
    echo "## $port"
    shopt -s nullglob
    for f in "$ROOT/$port"/*.log "$ROOT/$port"/*.log.gz; do
        id=$(basename "$f" | sed 's/\.log\(\.gz\)\?$//')
        if [[ "$f" == *.gz ]]; then
            tail_line=$(zcat "$f" | tail -n 200 | grep -E '^=== SESSION END' | tail -n1 || true)
        else
            tail_line=$(tail -n 200 "$f" | grep -E '^=== SESSION END' | tail -n1 || true)
        fi
        if [ -z "$tail_line" ]; then
            echo "  $id  [live]"
        else
            echo "  $id  $tail_line"
        fi
    done
done
```

**Step 4: Verify pass**

```bash
shellcheck -x helpers/list-sessions && bats tests/list-sessions.bats
```

**Step 5: Commit**

```bash
git add helpers/list-sessions tests/list-sessions.bats tests/fixtures/
git commit -m "feat(helpers): add list-sessions with [live] marker"
```

---

## Task 5: `helpers/get-session`

**Files:**
- Create: `helpers/get-session`
- Test: `tests/get-session.bats`

Supports printing one session, plus `--lines a-b`, `--head N`, `--tail N`. Transparently `zcat`s rotated `.log.gz` files.

**Step 1: Failing test**

```bash
@test "get-session prints full session by id" {
    run env SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" \
        ./helpers/get-session STM 2026-05-03T13:01:42
    [ "$status" -eq 0 ]
    [[ "$output" == *"SESSION START"* ]]
    [[ "$output" == *"SESSION END"* ]]
}

@test "get-session --head 1 prints just the first line" {
    run env SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" \
        ./helpers/get-session STM 2026-05-03T13:01:42 --head 1
    [ $(echo "$output" | wc -l) -eq 1 ]
}

@test "get-session --lines 2-3 prints lines 2-3" {
    run env SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" \
        ./helpers/get-session STM 2026-05-03T13:01:42 --lines 2-3
    [ $(echo "$output" | wc -l) -eq 2 ]
}

@test "get-session works on .log.gz" {
    gzip -k "$BATS_TEST_DIRNAME/fixtures/STM/2026-05-03T13:01:42.log"
    rm "$BATS_TEST_DIRNAME/fixtures/STM/2026-05-03T13:01:42.log"
    run env SL_DEBUG_MIRROR="$BATS_TEST_DIRNAME/fixtures" \
        ./helpers/get-session STM 2026-05-03T13:01:42
    [[ "$output" == *"SESSION START"* ]]
    # restore for other tests
    gunzip "$BATS_TEST_DIRNAME/fixtures/STM/2026-05-03T13:01:42.log.gz"
}
```

**Step 2: Implement**

Use `cat` or `zcat` based on extension; pipe into `sed -n` for line ranges; `head`/`tail` for those modes. Print line numbers always (so the analyzer can cite them).

**Step 3: Verify, commit**

```bash
shellcheck -x helpers/get-session && bats tests/get-session.bats
git add helpers/get-session tests/get-session.bats
git commit -m "feat(helpers): add get-session with line-range and gz support"
```

---

## Task 6: `helpers/search-session`

**Files:**
- Create: `helpers/search-session`
- Test: `tests/search-session.bats`

Wrapper around `grep -n -C 3` (with context) over the same session resolution as `get-session`. Same gz handling.

**Step 1: Failing test, implementation, gz handling, line numbers in output, commit.**

(Pattern identical to Task 5 — write a test that searches for a known string in the fixture, asserts the line number is in output, then implement.)

```bash
git commit -m "feat(helpers): add search-session (grep with context)"
```

---

## Task 7: `helpers/tail-live`

**Files:**
- Create: `helpers/tail-live`
- Test: `tests/tail-live.bats` (structural only — does not actually SSH)

Wraps `ssh "$HOST" "journalctl -fu uart-logger@<dev> -o cat"`. Resolves the device from `ports.conf` lookup *or* takes a `--dev` override. Test only checks `--print-cmd` mode that echoes the resolved command.

**Step 1: Failing test**

```bash
@test "tail-live --print-cmd shows the SSH command" {
    run env PI_HOST=test-host ./helpers/tail-live --print-cmd STM --dev ttyUSB0
    [[ "$output" == *"ssh test-host"* ]]
    [[ "$output" == *"journalctl -fu uart-logger@ttyUSB0"* ]]
}
```

**Step 2: Implement, verify, commit**

```bash
git commit -m "feat(helpers): add tail-live (ssh journalctl wrapper)"
```

---

## Task 8: `helpers/diff-sessions`

**Files:**
- Create: `helpers/diff-sessions`
- Test: `tests/diff-sessions.bats`

`diff -u` between two sessions resolved by id. Same gz handling.

**Step 1–5: TDD pattern**

```bash
git commit -m "feat(helpers): add diff-sessions"
```

---

## Task 9: `tests/run.sh` aggregate runner

**Files:**
- Create: `tests/run.sh`

Runs `shellcheck -x helpers/*` then `bats tests/`. Exits non-zero on first failure.

**Step 1: Write**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "==> shellcheck"
find "$ROOT/helpers" -type f -executable -print0 | xargs -0 shellcheck -x
echo "==> bats"
bats "$ROOT/tests/"*.bats
echo "==> pytest"
( cd "$ROOT" && python -m pytest tests/ -q )
echo "==> shared.md schema lint"
"$ROOT/tests/lint-shared.sh" "$ROOT/tests/fixtures/shared.md.example"
echo "All tests passed."
```

**Step 2: Commit**

```bash
chmod +x tests/run.sh
git add tests/run.sh
git commit -m "test: add aggregate test runner"
```

---

## Task 10: `tests/lint-shared.sh` + fixture

**Files:**
- Create: `tests/lint-shared.sh`
- Create: `tests/fixtures/shared.md.example` (well-formed canonical example from design §7)
- Create: `tests/fixtures/shared.md.bad-no-repro` (missing Repro recipe slot — should fail lint)
- Test: `tests/test_lint_shared.bats`

**Step 1: Write fixtures** — copy canonical example from design §7 into `shared.md.example`. Make a copy with the `**Repro recipe`** block removed for `bad-no-repro`.

**Step 2: Failing test**

```bash
@test "lint-shared accepts canonical example" {
    run ./tests/lint-shared.sh tests/fixtures/shared.md.example
    [ "$status" -eq 0 ]
}

@test "lint-shared rejects file missing Repro recipe" {
    run ./tests/lint-shared.sh tests/fixtures/shared.md.bad-no-repro
    [ "$status" -ne 0 ]
}
```

**Step 3: Implement `lint-shared.sh`**

For each H2 section (split on `^## `), require:
1. Header matches `## YYYY-MM-DD HH:MMZ — \w+ .* — \[HIGH|MED|LOW\] \[unconfirmed|confirmed|fixed|wontfix\]$`.
2. Body contains the literal strings `**Sessions:**`, `**Timeline`, `**Quantitative observations:**`, `**Hypothesis`, `**Repro recipe`, `**Status:**`.

Bash with `awk` to split on `^## `, then per-section regex. ~40 lines.

**Step 4: Verify, commit**

```bash
git add tests/lint-shared.sh tests/fixtures/shared.md.* tests/test_lint_shared.bats
git commit -m "test: add shared.md schema linter and fixtures"
```

---

## Task 11: Initial `shared.md`

**Files:**
- Create: `~/Desktop/smartLock/sl-debug/shared.md`

**Step 1: Write**

```markdown
# sl-debug findings

Append-only. Each finding is one H2 section. See [`CLAUDE.md`](CLAUDE.md) for schema and hard rules.

<!-- findings begin below this line -->
```

**Step 2: Commit**

```bash
git add shared.md
git commit -m "docs: initial shared.md (empty findings file)"
```

---

## Task 12: `analyze/prompts/system.md`

**Files:**
- Create: `analyze/prompts/system.md`

The analyzer system prompt. Must include:

1. Role statement (you are a UART log analyzer).
2. The full schema from design §7 (so the prompt is self-contained).
3. The three hard rules.
4. The STM32C091 memory map reference.
5. The canonical example.
6. Output instruction: "Reply with exactly one finding in markdown, ready to append to `shared.md`. No prose before or after."

**Step 1: Write the prompt** — copy schema and rules from `CLAUDE.md` (Task 2). Add the "no prose before/after" instruction.

**Step 2: Commit**

```bash
git add analyze/prompts/system.md
git commit -m "feat(analyze): add system prompt for batch analyzer"
```

---

## Task 13: `analyze/analyze.py` skeleton + `--dry-run`

**Files:**
- Create: `analyze/analyze.py`
- Create: `requirements-dev.txt`
- Test: `tests/test_analyze.py`

This task: argparse, prompt construction, `--dry-run` that prints the constructed prompt and exits. **No actual API calls yet.**

**Step 1: Failing test**

```python
# tests/test_analyze.py
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

def test_dry_run_prints_prompt(tmp_path):
    fixture = REPO / "tests" / "fixtures" / "STM" / "2026-05-03T13:01:42.log"
    result = subprocess.run(
        [sys.executable, str(REPO / "analyze" / "analyze.py"),
         "--port", "STM", "--session", "2026-05-03T13:01:42",
         "--mirror", str(REPO / "tests" / "fixtures"),
         "--dry-run"],
        capture_output=True, text=True, check=True,
    )
    assert "SESSION START" in result.stdout
    assert "shared.md" in result.stdout  # schema is included
    assert "Repro recipe" in result.stdout  # rules are included
```

**Step 2: Implement skeleton**

```python
# analyze/analyze.py
"""sl-debug batch log analyzer. Reads one session, calls an LLM provider,
appends a finding to shared.md.

Usage:
    analyze.py --port STM --session 2026-05-03T13:01:42 [--dry-run]
    analyze.py --port STM --since 2026-05-01 [--provider openrouter --model ...]

Provider selected via env LLM_PROVIDER={anthropic,openrouter}, LLM_MODEL=...
"""
from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SYSTEM_PROMPT = (REPO / "analyze" / "prompts" / "system.md").read_text()

def build_prompt(port: str, session_id: str, log_text: str) -> tuple[str, str]:
    user = (
        f"Port: {port}\n"
        f"Session id: {session_id}\n"
        f"--- log begins ---\n{log_text}\n--- log ends ---\n"
    )
    return SYSTEM_PROMPT, user

def read_session(mirror: Path, port: str, session_id: str) -> str:
    plain = mirror / port / f"{session_id}.log"
    gz = mirror / port / f"{session_id}.log.gz"
    if plain.exists():
        return plain.read_text()
    if gz.exists():
        import gzip
        return gzip.decompress(gz.read_bytes()).decode("utf-8", errors="replace")
    raise FileNotFoundError(f"{port}/{session_id}")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--session", help="exact session id; omit with --since to walk")
    ap.add_argument("--since", help="ISO date; walk all sessions ≥ this date")
    ap.add_argument("--mirror", default=str(REPO / "logs-mirror"))
    ap.add_argument("--provider", default=os.environ.get("LLM_PROVIDER", "anthropic"))
    ap.add_argument("--model", default=os.environ.get("LLM_MODEL", "claude-haiku-4-5-20251001"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    mirror = Path(args.mirror)
    if args.session:
        log = read_session(mirror, args.port, args.session)
        sys_p, user_p = build_prompt(args.port, args.session, log)
        if args.dry_run:
            print("=== SYSTEM ===\n" + sys_p + "\n=== USER ===\n" + user_p)
            return 0
        # Real call deferred to Task 14/15
        raise NotImplementedError("provider integration is in next tasks")
    raise NotImplementedError("--since walk is in Task 16")

if __name__ == "__main__":
    sys.exit(main())
```

**Step 3: `requirements-dev.txt`**

```
anthropic>=0.40
requests>=2.31
pytest>=8
```

**Step 4: Verify, commit**

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest tests/test_analyze.py -v
git add analyze/analyze.py requirements-dev.txt tests/test_analyze.py
git commit -m "feat(analyze): analyzer skeleton with --dry-run"
```

---

## Task 14: `analyze.py` — Anthropic provider

**Files:**
- Modify: `analyze/analyze.py`
- Modify: `tests/test_analyze.py`

**Step 1: Failing test (mocks `anthropic.Anthropic`)**

```python
def test_anthropic_provider_appends_finding(tmp_path, monkeypatch):
    shared = tmp_path / "shared.md"
    shared.write_text("# sl-debug findings\n\n<!-- findings begin below this line -->\n")

    fake_response = type("R", (), {
        "content": [type("B", (), {"text": "## 2026-05-03 14:22Z — STM test — [LOW] [unconfirmed]\nbody\n"})()]
    })
    class FakeClient:
        def __init__(self, *_, **__): pass
        class messages:
            @staticmethod
            def create(**_): return fake_response
    monkeypatch.setattr("anthropic.Anthropic", FakeClient)

    from analyze.analyze import call_provider, append_finding
    text = call_provider("anthropic", "claude-haiku-4-5", "sys", "user")
    append_finding(shared, text)
    assert "## 2026-05-03 14:22Z — STM test" in shared.read_text()
```

**Step 2: Implement `call_provider` and `append_finding`**

```python
def call_provider(provider: str, model: str, system: str, user: str) -> str:
    if provider == "anthropic":
        import anthropic
        client = anthropic.Anthropic()
        resp = client.messages.create(
            model=model,
            system=system,
            max_tokens=4000,
            messages=[{"role": "user", "content": user}],
        )
        return resp.content[0].text
    raise ValueError(f"unknown provider: {provider}")

def append_finding(shared_md: Path, text: str) -> None:
    text = text.strip() + "\n\n"
    with shared_md.open("a") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
```

Wire into `main()` so `--session` (without `--dry-run`) calls the provider and appends.

**Step 3: Verify, commit**

```bash
git add analyze/analyze.py tests/test_analyze.py
git commit -m "feat(analyze): wire Anthropic provider with append-and-fsync"
```

---

## Task 15: `analyze.py` — OpenRouter provider

**Files:**
- Modify: `analyze/analyze.py`
- Modify: `tests/test_analyze.py`

OpenRouter exposes an OpenAI-compatible REST API at `https://openrouter.ai/api/v1/chat/completions`. Auth via `OPENROUTER_API_KEY`. Plain `requests.post`.

**Step 1: Failing test (mocks `requests.post`)**

```python
def test_openrouter_provider(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test")
    fake_resp = type("R", (), {
        "raise_for_status": lambda self: None,
        "json": lambda self: {"choices": [{"message": {"content": "## hi"}}]},
    })()
    monkeypatch.setattr("requests.post", lambda *a, **kw: fake_resp)
    from analyze.analyze import call_provider
    out = call_provider("openrouter", "anthropic/claude-haiku-4.5", "sys", "user")
    assert out == "## hi"
```

**Step 2: Extend `call_provider`**

```python
elif provider == "openrouter":
    import requests
    r = requests.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}"},
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        },
        timeout=120,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]
```

**Step 3: Verify, commit**

```bash
git commit -m "feat(analyze): add OpenRouter provider"
```

---

## Task 16: `--since` walking + `.analyzed-sessions` + retry

**Files:**
- Modify: `analyze/analyze.py`
- Modify: `tests/test_analyze.py`

**Step 1: Failing test** — fixture mirror with two sessions; mock provider returns a stub finding; assert both sessions get processed and both IDs land in `.analyzed-sessions`. Re-running skips them.

**Step 2: Implement**
- `walk_sessions(mirror, port, since)` → list of session ids ≥ `since`.
- `load_analyzed(path) / mark_analyzed(path, id)` for `.analyzed-sessions`.
- Retry with exponential backoff (3 attempts: 1s, 4s, 16s). After third failure, append to `.failed-sessions` and continue.

**Step 3: Verify, commit**

```bash
git commit -m "feat(analyze): --since walking, retry, .analyzed-sessions tracking"
```

---

## Task 17: Chunking for sessions >50 MB

**Files:**
- Modify: `analyze/analyze.py`
- Modify: `tests/test_analyze.py`

**Step 1: Failing test** — synthetic 60 MB session (procedurally generated in the test). Assert the analyzer chunks at SESSION-START markers (or every N MB if there's only one) and produces ≥2 findings.

**Step 2: Implement** — `chunk_session(text, max_bytes=50*1024*1024)` splits on `^=== SESSION START` boundaries; falls back to fixed-size split if a single session exceeds the limit. Each chunk gets analyzed independently and findings are appended in order. No roll-up summary in v1 (deferred — flag in design §11 covers it).

**Step 3: Verify, commit**

```bash
git commit -m "feat(analyze): chunk large sessions at SESSION-START markers"
```

---

## Task 18: `docs/eval.md` skeleton + `README.md` polish

**Files:**
- Create: `docs/eval.md`
- Modify: `README.md`

**Step 1: `docs/eval.md`**

```markdown
# sl-debug manual eval log

For each interesting session, log: did the analyzer flag what you expected? Hits, misses, false positives. This is the only honest content-quality signal in phase 0. When patterns emerge, they become phase-1 rules.

| Date | Session | Expected | Got | Notes |
|---|---|---|---|---|
```

**Step 2: Expand `README.md`**

Add: prerequisites, install, basic usage (Claude Code session in dir, batch via `analyze.py`), where `shared.md` lives, link to eval log, link to design and implementation plans, troubleshooting (Pi unreachable, API key missing, rsync permission). Keep under one screen.

**Step 3: Commit**

```bash
git add docs/eval.md README.md
git commit -m "docs: add eval log and expand README"
```

---

## Task 19: Manual smoke test against real Pi

**Not a code task — a procedure.** Run after Tasks 1–18 are green.

**Step 1: Confirm Pi reachable**

```bash
ssh pi-monitor true && echo OK
```

**Step 2: Pull logs**

```bash
cd ~/Desktop/smartLock/sl-debug
helpers/pull-logs
ls logs-mirror/
```

Expect: per-port subdirectories with `.log` and `.log.gz` files.

**Step 3: List sessions**

```bash
helpers/list-sessions STM
```

Expect: at least one session, optionally `[live]` if a logger is currently writing.

**Step 4: Run analyze.py on one session, dry-run**

```bash
.venv/bin/python analyze/analyze.py --port STM --session <id-from-step-3> --dry-run | head -100
```

Expect: full system prompt + user prompt (with log content) printed.

**Step 5: Run analyze.py for real (Anthropic)**

```bash
export ANTHROPIC_API_KEY=...   # from your env
.venv/bin/python analyze/analyze.py --port STM --session <id>
cat shared.md
```

Expect: one new H2 finding appended.

**Step 6: Run analyze.py for real (OpenRouter)**

```bash
export OPENROUTER_API_KEY=...
.venv/bin/python analyze/analyze.py --port STM --session <id> \
    --provider openrouter --model anthropic/claude-haiku-4.5
```

Expect: a *second* finding appended, header tagged with the OpenRouter model.

**Step 7: Lint shared.md**

```bash
tests/lint-shared.sh shared.md
```

Expect: pass.

**Step 8: Open Claude Code in the dir**

```bash
cd ~/Desktop/smartLock/sl-debug
claude
```

Ask: *"summarize the latest STM session and append a finding."* Verify it uses helpers, writes a finding, follows the schema. Lint passes.

**Step 9: Commit a snapshot of the smoke-tested `shared.md`**

```bash
git add shared.md
git commit -m "chore: first real findings from manual smoke test"
```

If any step fails, file an issue against this plan and stop — don't paper over with quick patches.

---

## Done

When all 19 tasks are green, v1 is shipped. Next steps (deferred to later plans):

- Phase 0b: port helpers to MCP — design covered, no plan yet.
- Phase 1: build deterministic rule library from confirmed findings — needs ≥10 confirmed entries first.
- Phase 2: autoresearcher loop with phase-1 verifier as the rollback gate.

---

Author: Patrik Drazic — [github.com/paky12](https://github.com/paky12)

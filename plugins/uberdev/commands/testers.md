---
description: "Read-only adversarial QA audit squad. Spawns 8 agents (6 personas + 2 monitors) over 3 coordinated waves against an auto-detected target (web/api/native/all). Findings are evidence-anchored against a 10-invariant oracle library and auto-filed as GitHub issues via findings-to-issues. The squad never writes app code."
argument-hint: "[<target>] [--target=web|api|native|all] [--watch] [--rounds=N] [--max-issues=N] [--persona=name,...] [--no-issues] [--rps-cap=N]"
allowed-tools: ["Bash", "Read", "Write", "Task"]
---

# Testers — Adversarial QA Audit Squad

Spawn an 8-agent read-only QA audit squad against the target in **$ARGUMENTS** (or auto-detect from CWD). Six distinct-persona testers (`panicked_grandma`, `power_user`, `adversarial_security`, `chaos_engineer`, `a11y_critic`, `mobile_thumb`) + two monitors (`monitor_primary`, `monitor_devils_advocate`) run three coordinated waves; monitors generate per-persona follow-up prompts between waves; findings without an `invariant_violated` field and an evidence anchor are dropped. Findings flow into `findings-to-issues` for durable GitHub-issue persistence.

**Usage:** `/uberdev:testers [<target>] [--target=...] [--watch] [--rounds=N] [--max-issues=N] [--persona=name,...] [--no-issues] [--rps-cap=N]`

- `<target>` — optional URL / OpenAPI path / binary path; auto-detect from CWD if omitted.
- `--target=<surface>` — explicit surface (`web | api | native | all`); overrides auto-detect.
- `--watch` — run the master inline in this session with non-headless browsers, instead of backgrounding via the dispatch backend.
- `--rounds=N` — wave count (default 3; minimum 1).
- `--max-issues=N` — cap for `findings-to-issues` (default 10).
- `--persona=name,...` — override default roster (drop a custom persona at `plugins/uberdev/agents/testers-<name>.md`).
- `--no-issues` — skip `findings-to-issues`; report only.
- `--rps-cap=N` — per-host RPS ceiling, [1, 1000], default 10. Enforced for curl traffic at lib/rate-limit-curl.sh; audited for Playwright/MCP traffic at Phase 5 (fail-the-run on breach).

**Read-only contract:** the squad has no `Edit` or general `Write` on app code; agent `allowed-tools` whitelists enforce it at the tool boundary.

Now invoke the `uberdev:testers-pipeline` skill — it owns the 6-phase pipeline (parse + auto-detect, dispatch master, three waves, report synthesis, findings persistence, summary). The skill renders inline, so `$ARGUMENTS` remains in scope.

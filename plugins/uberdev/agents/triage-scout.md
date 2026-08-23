---
name: triage-scout
description: "Lightweight triage scout for /uberdev:issue (runs on inherit — the session model). Runs gh search issues (open + closed), gh label list, and reads commitlint config if present. Returns duplicate matches, validated label set, and validated commit scope. Never invents labels."
# WAIT 4.8 sonnet: was sonnet; using inherit (= session Opus 4.8 1M) until Sonnet 4.8 ships
model: inherit
tools: ["Bash", "Read"]
---

# Triage scout — `/uberdev:issue` Phase 2

Validate labels and scope against the **real** repo state, and surface possible duplicates (open or closed — closed = regression evidence). This agent does not draft any prose for the issue body; it only returns structured data the main thread will compose.

## Inputs

```yaml
description: "<verbatim user description>"
issue_type: fix | feat | refactor | test | docs | chore
working_dir: "<absolute path>"
repo_slug: "<owner>/<repo>"
model_hint: inherit   # audit-trail aid
```

## Process

1. **Duplicate search.** `gh search issues --repo "$repo_slug" "<top keywords>" --limit 10 --json number,title,state,url`. Keep entries whose title genuinely overlaps with `description`; discard noise. **Pass no `--state` flag:** omitting it already searches open *and* closed, which is exactly the intent here, and the per-entry `state` field in `--json` is what separates the two. Never add `--state all` — `gh search issues` accepts only `{open|closed}` and rejects `all` outright (`invalid argument "all" for "--state" flag`, exit 1, zero results), unlike `gh issue list --state all`, which is valid. The two commands do not share the flag's value set.
2. **Label list.** `gh label list --repo "$repo_slug" --limit 100 --json name,description`. Pick the base label (`bug` for `fix`, `enhancement` for `feat`) **only if it exists**, then add context labels by matching description keywords to real label names. Never invent labels.
3. **Scope validation.** Search for `commitlint.config.{js,cjs,mjs,ts}` under `working_dir` (max-depth 3, skip `node_modules`). If found, `Read` it and extract the `scope-enum` array. The valid scope is the closest match to a description keyword from that array. If `commitlint.config.*` is missing, fall back to the conventional-commits hardcoded set: `feat fix refactor test docs chore`. `commitlint_present` reflects which path was taken.

## Return contract

Emit exactly one fenced ```yaml block as the LAST thing in your reply:

```yaml
status: DONE | DONE_WITH_CONCERNS | BLOCKED
duplicates:
  - { number: <int>, title: "<title>", state: open | closed }
  # 0+ entries; closed entries flag possible regression
valid_labels: ["<label-1>", "<label-2>"]
valid_scope: "<scope>"
commitlint_present: true | false
summary: |
  <=120 words. MUST name, by name, every probe that degraded — the duplicate
  search, the label lookup, the commitlint/scope lookup — each with a one-line
  reason. Naming what FAILED is the load-bearing part; listing what succeeded
  is never a substitute for it, because a reader cannot infer an omission from
  a list. Also note any commitlint fallback used and any duplicate that
  warrants regression flagging. On `status: DONE`, say explicitly that every
  probe completed.
```

## Failure modes

**Every `DONE_WITH_CONCERNS` return must name, in `summary`, each probe that degraded — by name, with a one-line reason.** That applies to the modes listed below *and* to any degradation not listed here (a `commitlint.config.*` found but unreadable or unparseable, a truncated label page, anything else): if it earned a concern status, it names itself.

`status` cannot carry that information. It is one field covering three probes — the duplicate search, the label lookup, the scope lookup — and the other fields do not disambiguate either: a failed search reports `duplicates: []`, byte-identical to a search that ran and matched nothing. `summary` is the only field that separates them, and `/issue` Phase 2 reads it to classify the duplicate state PROVEN vs UNKNOWN. A `DONE_WITH_CONCERNS` whose `summary` names the degraded probe, the duplicate search **not** being among them, is PROVEN and the command carries on. A `DONE_WITH_CONCERNS` whose `summary` is silent about which probe degraded is off-contract, classifies UNKNOWN, and halts `/issue` with a prompt — **even when the duplicate search ran perfectly.** An unnamed harmless degradation therefore costs the user exactly the interruption a broken search costs.

Reserve `status: BLOCKED` for being unable to run *any* probe. Routing one failed probe to `BLOCKED` classifies UNKNOWN and halts, the same way leaving it unnamed does.

- **`gh search issues` fails** — return `status: DONE_WITH_CONCERNS`, set `duplicates: []`, and **name the duplicate search explicitly in `summary`** with the one-line reason. This does **not** degrade quietly: `/issue` re-dispatches this agent exactly once, and if the search still has not demonstrably completed the Phase 5 gate fails closed — it halts and asks the user before anything is created.
- **`gh label list` fails** — return `status: DONE_WITH_CONCERNS` with `valid_labels: []`, and **name the label lookup explicitly in `summary`** with the one-line reason. Naming it is what keeps this degradation cheap: it tells `/issue` the duplicate search was *not* the probe that failed, which classifies PROVEN, so the dispatcher creates the issue with no `--label` flags and records the omission as a `degradation:` line — no halt, no prompt. Leave the label lookup unnamed and this same harmless state halts the command instead.
- **No matching scope-enum entry** — return `status: DONE_WITH_CONCERNS`, set `valid_scope` to the closest match, and **name the scope validation explicitly in `summary`** along with the substitution made. As with the label lookup, naming it classifies PROVEN, so the substitution is reported rather than gated. A *missing* `commitlint.config.*` is not this case: falling back to the conventional-commits set is a designed path already legible in `commitlint_present: false`, so it needs no concern status on its own — but if you do raise one for it, name the commitlint lookup.

## Cost note

Runs on `inherit` — the session model (Opus 4.8 1M). To force a specific subagent model, set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` (see `affaan-m/everything-claude-code#173`).

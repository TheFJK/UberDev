# RFC 0002 — `/review-pr` Tiered Halt + Trust-Trail-Aware Issue Persistence

| Field            | Value                                                                                                                                                                                                                  |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**       | Accepted (2026-05-14 — implemented in v0.26.0)                                                                                                                                                                         |
| **Author**       | TheFJK                                                                                                                                                                                                                 |
| **Created**      | 2026-05-14                                                                                                                                                                                                             |
| **Targets**      | `plugins/uberdev/commands/review-pr.md`, `plugins/uberdev/agents/findings-to-issues.md`, `plugins/uberdev/agents/ci-code-fixer.md`, `plugins/uberdev/agents/trust-trail-evaluator.md`, `plugins/uberdev/skills/merge-pipeline/SKILL.md` |
| **Supersedes**   | —                                                                                                                                                                                                                      |
| **Builds on**    | RFC 0001 (CI Health phase) · PR #112 (findings-to-issues sub-phase)                                                                                                                                                    |
| **Tracking**     | [Issue #114](https://github.com/TheFJK/UberDev/issues/114)                                                                                                                                                             |
| **Tier**         | Medium (multi-agent, multi-file, trust-trail contract change)                                                                                                                                                          |

---

## 1. Summary

Promote `/uberdev:review-pr`'s findings-to-issues sub-phase (added in PR #112) from purely-advisory to **severity-tiered gating**. Wire deferred-blocker filings into the trust-trail JSON so `/merge`'s trust-trail-evaluator can see them. Surface CI fixer refusals as user-visible halts instead of silent 3-iteration loop exhaustion. Net effect: a green `/review-pr` trail can no longer co-exist with unresolved blocker findings on the same HEAD.

## 2. Motivation

### 2.1 Three silent-drop paths

An audit of the post-PR-#112 review-pr flow surfaced three paths where review-pr exits cleanly — or worse, exits 1 silently — while leaving the PR in an unsafe state for `/merge`:

1. **CI fixer refusal** (`review-pr.md:370, 531`). When the CI classifier returns `code_bug` but `ci-code-fixer` returns `status: REFUSED` (forbidden-pattern guard), the Phase 3 loop retries up to 3× then exits 1 via `loop_cap_exhausted` with **no user-visible halt prose**. The user sees a bare non-zero exit; the failing test and classifier `signal_anchor` are lost.

2. **Blocker findings deferred** (`findings-to-issues.md:187`). The agent contract states explicitly: *"the sub-phase NEVER causes `/review-pr` or `/simplify` to exit non-zero. A `REFUSED` status is information for the final summary, not a parent-process failure."* The trust-trail anchor commit (`review-pr.md:614–635`) therefore lands unconditionally — GREEN label + `Reviewed-by:` trailer — even when 10 blocker issues were just filed. `/merge`'s trust-trail-evaluator can't see filed issues because the audit JSON lacks a `phases.phase2_5` block (`review-pr.md:682–694`), so the PR can be merged with open blocker issues attached.

3. **Severity gaps** (`findings-to-issues.md:51–66`). The filter accepts `{blocker, critical}` only. Phase 1's `major` severity and Phase 2's `important` severity are dropped on the floor — no issue filed, no audit-JSON record, no breadcrumb anywhere.

### 2.2 Practical consequence (solo-dev workflow)

In the personal-TODO-queue workflow ([[user_workflow_todo_queue]]), the cost of silent drops compounds. A blocker filed today gets discovered three PRs later when `gh issue list` happens to be eyeballed. The trust trail told the author "shipped, reviewed, green" — but it lied. By the time the issue surfaces, the original PR context is cold; `/solve` against the issue spends extra cycles rebuilding what the original review-pr run already knew.

### 2.3 Design tension to resolve

PR #112's "NEVER halts" stance was deliberate: review-pr should not become a third halting gate (after Phase 1's `code-fixer` and Phase 2's lens-fixer) that breaks the "land imperfect work + file TODOs" pattern. **That stance is correct for `major` / `important` findings. It is wrong for blockers** — by definition a blocker is something the review agents consider unshippable. The fix is severity-tiered halt, not blanket halt.

## 3. Design

### 3.1 Severity tiers and effects

| Severity              | Disposition  | Issue filed         | @author mention | Trust trail                                                                  | `/merge` requirement                                |
| --------------------- | ------------ | ------------------- | --------------- | ---------------------------------------------------------------------------- | --------------------------------------------------- |
| `blocker`             | not APPLIED  | YES (`Blocks: #PR`) | YES             | **RED** — no `Reviewed-by` trailer, no `uberdev-approved` label              | hard fail; requires `--accept-blocker-deferred`     |
| `critical`            | not APPLIED  | YES                 | YES             | **YELLOW** — trailer: `Reviewed-by: uberdev/review-pr@<sha> severity=critical-deferred count=N` | requires `--accept-critical-deferred`               |
| `important` / `major` | not APPLIED  | YES (silent)        | NO              | **GREEN** unaffected                                                         | passes                                              |
| `suggestion`          | any          | NO                  | NO              | **GREEN**                                                                    | passes                                              |
| any                   | APPLIED      | NO (already fixed)  | NO              | **GREEN**                                                                    | passes                                              |
| any                   | REJECTED     | NO (review decided wrong) | NO        | **GREEN**                                                                    | passes                                              |

Notes:
- "YELLOW" is a new trust-trail state — see §3.4.
- "Issue filed (silent)" for `major`/`important` matches the existing TODO-queue workflow without adding noise.
- The current `MAX_NEW=10` cap is preserved but tightened — see §3.3.4.

### 3.2 CI fixer refusal — user-visible halt

Replace the silent 3-iteration retry loop with single-attempt halt prose. The 3-iteration cap remains for genuine flake / transient state (`flaky_infra`, `env_drift`); for `REFUSED`, retrying is wasted compute that obscures the user-actionable signal.

**Current** (`review-pr.md:370, 531`):

```
ci-code-fixer status: REFUSED
  → emit ci_phase_outcome data.outcome=halted
  → exit 1
[on retry iteration, re-enters PROBE — same red CI, same classifier output, same REFUSED]
```

**Proposed**:

```
ci-code-fixer status: REFUSED
  → 1. File the failing test + classifier signal_anchor as a GH issue (severity: critical, tier 3.1)
    2. Render user-visible halt block (mirroring billing_quota / platform_outage pattern at review-pr.md:723)
       containing: failure_class, signal_anchor file:line, filed-issue URL, suggested next command
    3. AskUserQuestion: { Spawn /solve <issue> | Override (emit YELLOW trail) | Abort }
    4. Non-interactive mode → default Abort with prose summary, exit 1
    5. Do NOT retry — REFUSED is a deterministic decision, not flake
```

### 3.3 findings-to-issues contract changes

Extend `plugins/uberdev/agents/findings-to-issues.md`:

#### 3.3.1 Severity filter (replaces lines 51–66)

```bash
route_by_severity() {
  local severity="$1" disposition="$2"
  [ "$disposition" = "APPLIED" ]  && return 1   # already fixed inline
  [ "$disposition" = "REJECTED" ] && return 1   # review decided wrong
  case "$severity" in
    blocker)         tier="BLOCKER"  ; return 0 ;;
    critical)        tier="CRITICAL" ; return 0 ;;
    important|major) tier="MAJOR"    ; return 0 ;;
    *)               return 1 ;;   # suggestion, info, etc.
  esac
}
```

#### 3.3.2 Issue body — author mention + PR backlink (replaces lines 100–114)

```bash
case "$tier" in
  BLOCKER|CRITICAL)
    author=$(gh pr view "$PR_NUM" --json author --jq .author.login)
    blocks_line="Blocks: #${PR_NUM}"
    mention_line="@${author} — review-pr Phase 2.5 flagged a ${tier,,} finding on PR #${PR_NUM}."
    assignee_flag="--assignee @${author}"
    ;;
  MAJOR)
    blocks_line="Related: PR #${PR_NUM}"
    mention_line=""    # silent
    assignee_flag=""
    ;;
esac
```

#### 3.3.3 Enriched return contract (replaces lines 156–163)

```yaml
status: DONE | DONE_WITH_CONCERNS | REFUSED
issues_filed: <n>
by_severity:
  blocker:  <n>
  critical: <n>
  major:    <n>
overflow_count: <n>
halted: <bool>   # true iff (blocker_count > 0) OR (overflow_count > 0 AND any overflowed item is blocker/critical)
```

#### 3.3.4 MAX_NEW=10 cap with broken-feature overflow

When `MAX_NEW` truncates the candidate list:
- If any *truncated* item has severity `blocker` or `critical` → set `halted: true` regardless of how many fit under the cap. Rationale: > 10 deferred-critical findings indicates a broken feature, not a normal review pass.
- If only `major` items overflow → `halted` stays driven by `blocker_count > 0` only; `overflow_count` is recorded for the user but doesn't halt.

#### 3.3.5 Drop the "NEVER halts" clause (line 187)

Replace with:

> The sub-phase halts the parent run iff `halted == true` is in the return contract. Otherwise `/review-pr` and `/simplify` proceed normally. `halted` is set only when blocker findings (or broken-feature overflow of critical findings) are deferred — see §3.3.4 / §3.3.3 of RFC 0002.

### 3.4 Trust-trail JSON shape — new `phases.phase2_5` block

Audit JSON gains a `phase2_5` sibling alongside `phase1` / `phase2` / `phase3` (currently at `review-pr.md:682–694`):

```json
{
  "phases": {
    "phase2_5": {
      "status": "ran" | "skipped",
      "issues_filed": <n>,
      "by_severity": {
        "blocker":  <n>,
        "critical": <n>,
        "major":    <n>
      },
      "overflow_count":  <n>,
      "halted":          <bool>,
      "filed_issue_urls": ["https://github.com/.../issues/N", ...],
      "override_reason": null | "user-selected-emit-green-on-blocker-deferred"
    }
  }
}
```

**GREEN predicate** (replaces `review-pr.md:607`):

```
GREEN  := Phase 1 verdict == "APPROVE"
        AND Phase 2 status ∈ {"ran/APPROVE", "skipped"}
        AND Phase 2.5 by_severity.blocker == 0          [NEW]
        AND Phase 2.5 halted == false                   [NEW]
        AND Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"}

YELLOW := all GREEN preconditions satisfied
        AND Phase 2.5 by_severity.critical > 0

RED    := NOT GREEN AND NOT YELLOW
```

**Trailer encoding** (replaces `review-pr.md:614–635`):

```
GREEN:  Reviewed-by: uberdev/review-pr@<40-hex>
YELLOW: Reviewed-by: uberdev/review-pr@<40-hex> severity=critical-deferred count=<N>
RED:    (no trailer; existing trailer on prior anchor commit is NOT removed, but the new anchor commit lacks one — trust-trail-evaluator distinguishes HEAD trailer from ancestor)
```

**Label encoding**:

```
GREEN:  uberdev-approved
YELLOW: uberdev-approved-with-concerns
RED:    (no label; remove uberdev-approved if previously set on this PR)
```

### 3.5 AskUserQuestion on blocker halt

Inserted at `review-pr.md` Step 7, immediately after Phase 2.5 returns with `halted: true`:

```
AskUserQuestion(
  question: "Phase 2.5 filed N blocker issue(s) (severity: blocker, disposition: deferred). Trust trail will emit RED — /merge will block this PR until resolved. How to proceed?",
  options: [
    "Spawn /solve #<issue> in background (recommended for solo-dev workflow)",
    "Skip /solve — leave issues open, emit RED trail",
    "Override — emit GREEN trail (logs override_reason in audit JSON; /merge requires --i-know-what-im-doing)"
  ],
  multiSelect: false
)
```

Non-interactive mode (`--turbo`, CI env, no TTY): default to **option 2** with prose summary listing each filed issue URL. Option 3 (override) is interactive-only by design — an unattended override should never happen.

### 3.6 `/merge` trust-trail-evaluator changes

`plugins/uberdev/agents/trust-trail-evaluator.md` must:

1. Read `phases.phase2_5` from audit JSON.
2. If `phases.phase2_5.halted == true` AND no `--accept-blocker-deferred` flag on `/merge` → emit verdict `INVALID` with rationale: `"N blocker findings deferred (issues: #X, #Y, ...); resolve or override"`.
3. If `phases.phase2_5.by_severity.critical > 0` AND no `--accept-critical-deferred` flag → emit verdict `STALE` (softer than INVALID) with rationale: `"N critical findings deferred; pass --accept-critical-deferred or resolve"`.
4. If `phases.phase2_5` is absent (legacy audit JSON from pre-RFC versions) → emit `STALE` with rationale: `"audit predates phase2_5 schema; re-run /review-pr to refresh trail"`. **Do NOT silently treat absence as `blocker_count == 0`** — the audit predates the new gate.
5. `override_reason == "user-selected-emit-green-on-blocker-deferred"` → require `--i-know-what-im-doing` on `/merge`; otherwise emit `INVALID` with rationale: `"trust trail was overridden during /review-pr; explicit acknowledgment required"`.

### 3.7 Phase 3 (CI Health) precedence on simultaneous halt

If Phase 2.5 returns `halted: true` AND Phase 3 entry-probe finds CI red:

- Run Phase 2.5 halt-aggregation FIRST (file issues, surface prose, AskUserQuestion).
- THEN run Phase 3 — but `AskUserQuestion` is suppressed for Phase 3's classifier/router path; the user already chose a path in Phase 2.5. Phase 3 emits its outcome to the audit JSON normally.
- Final aggregation table (Step 7) merges both halts into one user-visible summary block.
- Exit code: 1 (parent halt wins).

This avoids the current "CI halt eats Phase 2.5 prose" bug (gap D in the audit).

## 4. File impact summary

| File                                                          | Change                                                                                                                                                                                                                                                |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plugins/uberdev/commands/review-pr.md`                       | New GREEN/YELLOW/RED predicate (§3.4) · audit JSON `phases.phase2_5` block (§3.4) · Step 7 AskUserQuestion on halt (§3.5) · CI fixer REFUSED user-visible halt + drop 3-retry on REFUSED (§3.2) · simultaneous-halt aggregation (§3.7) |
| `plugins/uberdev/agents/findings-to-issues.md`                | Extended severity filter (§3.3.1) · author @mention + `Blocks:` line (§3.3.2) · enriched return contract (§3.3.3) · broken-feature overflow (§3.3.4) · drop "NEVER halts" clause (§3.3.5)                                                              |
| `plugins/uberdev/agents/ci-code-fixer.md`                     | No behavior change; clarify in return-contract docstring that `status: REFUSED` → parent surfaces halt prose and does not retry                                                                                                                       |
| `plugins/uberdev/agents/trust-trail-evaluator.md`             | Read `phases.phase2_5`; INVALID on `halted == true` without override; STALE on critical without flag; STALE on legacy audit JSON; reject overridden-GREEN without `--i-know-what-im-doing` (§3.6)                                                     |
| `plugins/uberdev/skills/merge-pipeline/SKILL.md`              | Document `--accept-blocker-deferred` and `--accept-critical-deferred` flags; wire them in `/merge` arg-parse                                                                                                                                          |
| `CHANGELOG.md`                                                | New `## [X.Y.0]` section calling out BREAKING aspect of trust-trail contract                                                                                                                                                                          |
| Version bumps (per project CLAUDE.md)                         | `plugins/uberdev/.claude-plugin/plugin.json` · `.claude-plugin/marketplace.json` · `README.md` badge · `CHANGELOG.md` · git tag · GitHub Release                                                                                                       |

## 5. Migration

This is a trust-trail contract change. Existing PRs reviewed under the pre-RFC version have audit JSON without `phases.phase2_5`. Strategy:

- **In-flight PRs** (audit JSON exists, no `phase2_5`): trust-trail-evaluator emits `STALE` per §3.6.4, prompting re-run. User runs `/review-pr` once on each open PR after the version bump; the new trail picks up the new schema.
- **No data migration**: filed issues are durable in GitHub; audit JSON is ephemeral per-PR-head and refreshed on each `/review-pr` run.
- **No feature flag**: plugin code updates atomically when the marketplace pulls the new version. Solo-dev environment ([[user_workflow_todo_queue]]), no fleet-wide rollout concerns.

CHANGELOG must prominently flag the BREAKING aspect — semantically this tightens an existing gate rather than removing API surface, but downstream automation that depended on review-pr always emitting GREEN regardless of findings will break.

## 6. Alternatives considered

### 6.1 Blanket auto-halt on ANY deferred critical or blocker

- **Pros**: simpler — one path, no tiers, no override flags.
- **Cons**: breaks the "issues are personal TODO queue" workflow ([[user_workflow_todo_queue]]) for the `critical` severity, which is the "shippable but flag this" tier. Forces "/solve everything before merge" mode that was explicitly rejected when designing `findings-to-issues`.

### 6.2 Keep advisory model, only add @author mention to filed issues

- **Pros**: minimal change (one-line tweak to issue-create call).
- **Cons**: doesn't fix the core problem — trust trail still lies. Audit gap E (filed issues invisible to `/merge`) persists. Blockers still ship to main silently; @mention is a notification, not a gate.

### 6.3 Per-severity override flag on `/review-pr` itself (e.g., `/review-pr --accept-blocker-deferred`)

- **Pros**: decision-locality — the user overrides at review time, when context is fresh.
- **Cons**: invites override-by-default habit (the flag becomes muscle memory). Merge-time is the correct gate because the user might re-review after fixing; review-time override poisons the trust trail permanently with no second look.

### 6.4 Use GitHub PR review state (APPROVE / REQUEST_CHANGES) instead of trailer/label

- **Pros**: native GH UX; visible in the PR sidebar; integrates with branch-protection rules.
- **Cons**: requires a GH bot token in CI (the user runs review-pr locally as themselves; GH won't let a user "review" their own PR). The current trailer+label approach works without bot infra. Out of scope for this RFC; capture as a future enhancement.

### 6.5 Skip YELLOW tier (collapse to GREEN-or-RED only)

- **Pros**: simpler trust trail (binary).
- **Cons**: loses signal for the "shippable but watch this" case. `critical` findings are by definition not blockers — collapsing them to RED means more friction on routine merges; collapsing to GREEN means losing the signal entirely. YELLOW is the right intermediate.

## 7. Open questions

1. **`/turbo` interaction** — when `/solve` runs unattended under `/turbo`, should a Phase 2.5 halt auto-spawn a sibling `/solve` on the filed issue, or hard-stop? Auto-spawn risks cascading agent loops (issue spawns solve spawns review-pr spawns issue …). **Proposed default**: hard-stop. `/turbo` treats blocker-filings as terminal for that issue; user picks them up in a follow-up `/solve` run.

2. **`Blocks:` GH semantics** — GitHub renders `Blocks: #N` as a cross-reference but doesn't enforce it. Should the agent also call `gh pr edit <pr> --add-label "blocked-by:#issue"` to make the gate visible in the PR sidebar? **Defer to v2**; capture as follow-up issue.

3. **MAX_NEW=10 broken-feature overflow** — §3.3.4 treats `> 10 deferred critical+blocker` as broken-feature halt. Is 10 the right cliff? Could be 5 (tighter) or removed (let user judge). **Proposed default**: keep 10 to match current cap; revisit if false positives appear in dogfooding.

4. **YELLOW label name** — `uberdev-approved-with-concerns` is wordy. Alternatives: `uberdev-approved-yellow`, `uberdev-conditional`. **Proposed default**: `uberdev-approved-with-concerns` for clarity; doesn't affect contract.

5. **Override audit-trail schema** — when option 3 ("emit GREEN anyway") is selected, the audit JSON records `override_reason: "user-selected-emit-green-on-blocker-deferred"`. Should it also capture user agent string / timestamp / interactive-mode flag for forensics? **Proposed default**: timestamp + interactive flag, no agent string (no PII payoff).

## 8. Risk / rollout

| Risk                                                                              | Mitigation                                                                                                                                              |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Existing in-flight PRs see STALE trail after version bump → user confusion        | CHANGELOG callout + first-run prose: "trust trail schema updated; re-run /review-pr on each open PR". One-time friction, scoped to open PRs only.       |
| Override flag (`--accept-blocker-deferred`) becomes load-bearing → antipattern    | Audit JSON logs `override_reason`; flag name is intentionally verbose; spot-check via `/uberdev:simplify` periodically to flag overuse.                  |
| Phase 2.5 halt + Phase 3 halt double-prose overwhelms user                        | §3.7 mandates single aggregation block at Step 7; verify in implementation tests.                                                                       |
| YELLOW state misunderstood as "GREEN with caveat" → critical findings ignored      | YELLOW label visually distinct (`uberdev-approved-with-concerns`); trailer string explicit (`severity=critical-deferred count=N`); `/merge` requires explicit flag. |
| trust-trail-evaluator STALE-on-missing-phase2_5 too aggressive (legacy false positive) | One-time: each open PR re-runs `/review-pr` once after bump. Within a week of the version bump, no legacy audits remain.                                |

**Version bump**: MINOR (new gate, new audit JSON field, no API removal). Tag: TBD on release commit per project CLAUDE.md.

---

## 9. Decision log

| Date       | Decision                                                                                                                                                                                                 |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-05-14 | Draft authored after audit identified five gaps (A–E) in post-PR-#112 flow. Severity-tiered halt chosen over blanket auto-halt (alternative 6.1) and advisory-only @mention (alternative 6.2). Awaiting user sign-off before implementation. |

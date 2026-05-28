---
name: solve-pipeline
description: "Shared launcher pipeline for /uberdev:solve and /uberdev:turbo. Parses arguments, classifies tier, writes tier-appropriate prompt, dispatches a Claude agent into a fresh terminal session per issue. Invoked inline by both commands. Use when /solve or /turbo invokes this skill — never call directly."
---

# Solve Pipeline (shared body for /solve and /turbo)

This skill is invoked inline by `commands/solve.md` and `commands/turbo.md`. The caller exports `AUTO_MODE` (`0` for /solve interactive; `1` for /turbo unattended) before invocation; this skill reads `$AUTO_MODE` and `$ARGUMENTS` from the caller's shell scope.

`$ARGUMENTS` may contain **one or more issue numbers** (e.g. `42` or `5 6 7`). The skill validates every issue up front (Phase A) and then dispatches one autonomous Claude agent per issue (Phase B) via a platform-aware dispatch backend (`claude-bg` / `wezterm` / `background`; auto-selected per OS — cross-platform on macOS, WSL2, native Windows). Per-issue artifacts (`$UBERDEV_TMPDIR/solve-prompt-N.txt`, `$UBERDEV_TMPDIR/solve-bg-stdout-N.log`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch) are namespaced by `$ISSUE_NUM`, so concurrent spawns are collision-free. Override flags (`--trivial|--small|--full`, `--auto`, `--backend=<name>`) apply batch-wide. Monitor via `claude agents` (claude-bg) or visible panes (wezterm).

## Constants

| Name | Value (verbatim) | Where used |
|---|---|---|
| `TERMINAL_FLAG_DEPRECATED_NOTE` | `warning: --terminal=cmux\|ghostty\|iterm\|terminal\|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.` | Phase A stderr emission on first encounter; `commands/solve.md` / `commands/turbo.md` `## Deprecated Flags`. |
| `MIN_CLAUDE_VERSION` | `2.1.152` | Phase A `_uberdev_require_claude_version` hard gate. Bumped from `2.1.139` for #246: `--permission-mode bypassPermissions` requires Claude Code 2.1.152+; older versions hit `claude --bg ... --permission-mode bypassPermissions` → exit-2 unknown-flag, surfacing as `dispatch_setup_failed phase:dispatch rc:2` with the root cause buried in BG_STDOUT_LOG. The `claude --bg` minimum itself remains 2.1.139 (see line ~54 / ~149 / ~281 / ~787 — those references intentionally pin the old `--bg` floor because they describe `--bg`-flag availability or `--effort`-flag availability, not the new `--permission-mode bypassPermissions` requirement). |
| `DISPATCH_BACKEND_DEFAULT` | `auto` | Phase A `--backend=` parser default; `auto` defers to `lib/dispatch.sh` preflight. |
| `DISPATCH_BACKEND_ENUM` | `auto \| claude-bg \| wezterm \| background` | Phase A `uberdev_read_enum dispatch_backend` validation; also the `--backend=` flag's accepted set. |
| `FANOUT_CONCURRENCY_SOLVE_BG_DEFAULT` | `6` | Phase A `MAX_PARALLEL_BG_AGENTS` resolution default. |
| `EFFORT_LEVEL_DEFAULT` | `max` | Phase A `EFFORT_LEVEL` resolution; rationale: `/turbo` is unattended, quality > cost. |
| `EFFORT_LEVEL_ENUM` | `low \| medium \| high \| xhigh \| max` | Phase A `uberdev_read_enum` validation; matches `claude --effort <level>` accepted values in Claude Code 2.1.139. |
| `EFFORT_SOURCE_ENUM` | `cli \| env \| config \| default` | Audit telemetry source tag set by the Phase A `--effort=<level>` parser; emitted in the `effort_resolved` audit event payload. |
| `SOLVE_AUDIT_EVENT_ENUM` | `agent_dispatched`, `deprecated_flag_used`, `solve_bg_fanout_wave_started`, `effort_resolved`, `error`, `claim_acquired`, `claim_collision`, `claim_force_override`, `claim_write_failed`, `claim_released`, `dispatch_backend_resolved`, `dispatch_setup_failed` | Audit-log writers; consumers grep for `deprecated_flag_used` to identify migration laggards. `agent_returned` was removed in v0.22.0 — `claude --bg` does not synchronously report agent completion; use `claude agents` for status. The five `claim_*` events were added in v0.28.0 for the small-team issue-claim protocol (Step 4.5); grep `claim_force_override` to surface stale-claim recoveries, `claim_write_failed` to surface gh permission gaps. The `dispatch_backend_resolved` event was added in v0.29.0 (RFC 0004) — emitted once per invocation by `lib/dispatch.sh`'s preflight resolver with `{requested, resolved, os_class, reason}`. The `dispatch_setup_failed` event was added in v0.29.0 — emitted by every dispatch backend (`claude-bg`, `wezterm`, `background`) when a setup-phase prerequisite fails BEFORE the agent process is launched (config, worktree, prompt_read, status_write, id_extract, dispatch). The `id_extract` phase additionally carries a `subphase` discriminator (added v0.30.x for issue #154): `marker_absent` (the `backgrounded · <id>` marker was not found in the bg stdout log — output-format/version drift; **not retryable**) vs `pipeline_error` (the extraction `grep` itself exited rc≥2 — unreadable log / I/O error; **potentially retryable**). `subphase` is a closed enum of those two literal strings only; it is never derived from log content. Consumers may filter on `subphase` to route retryable infra failures separately from non-retryable format drift; the field is additive and absent on all other phases, so existing `phase`-keyed consumers are unaffected. The `error` event remains valid for non-setup failures. Uniform taxonomy across all three backends; consumers grep `dispatch_setup_failed` to surface silent-failure classes that would otherwise mask as `error` and bypass audit-log filters. |
| `UBERDEV_ACTIVE_LABEL` | `uberdev:active` | Step 4.5 claim protocol — applied to OPEN issues by `/solve` / `/turbo` on dispatch; cleared by `/merge` post-merge (`merge-pipeline/SKILL.md` post-merge cleanup phase) or by the dispatch-failure rollback in Step 5b'. NEVER set or removed by hand — the audit comment marker is the only safe parser surface. |
| `UBERDEV_ACTIVE_LABEL_COLOR` | `D93F0B` | Warning-orange; matches the GitHub default `bug` palette band so it reads as actionable. Created idempotently via `gh label create --force` in Step 4.5 on first encounter per repo, mirroring `finish-branch/SKILL.md:287` and `dev-pipeline/SKILL.md:279`. |
| `UBERDEV_ACTIVE_LABEL_DESCRIPTION` | `Issue currently being worked on by a /solve or /turbo dispatcher. Auto-managed; do not edit.` | Passed to `gh label create --description`. Must stay ≤100 chars (GitHub label-description limit; longer 422s on create/--force-update). The "Auto-managed" framing is the primary defence against well-meaning manual edits that would desync the claim comment from the label state. |
| `CLAIM_COMMENT_MARKER` | `<!-- uberdev-claim-comment v1 -->` | HTML-comment fingerprint at the top of every claim audit comment. Allows the validation loop to find the latest claim comment among arbitrary unrelated comments via a single `grep -F` pass. The collision check matches on the **version-stripped prefix** (`<!-- uberdev-claim-comment`) rather than the full v1-suffixed marker — without this, a rolling upgrade where teammate-A is on v1 and teammate-B is on v2 (`<!-- uberdev-claim-comment v2 -->`) would have each dispatcher see "no live claim" of the other's version, defeating the protocol (regression #123 B7). **Forward-compat policy:** **adding** new optional fields to the body schema is backward-compatible (the field-extraction loop pre-inits each field to `"?"` and conditionally overwrites only when the grep|sed pipeline emits a non-empty value, so missing fields stay at `"?"` without breaking the parse) and does NOT require a marker version bump. **Removing or renaming** fields is a breaking change — it MUST bump the marker version AND ship a migration path (e.g. a parser arm that handles both v1 and v2 bodies during the rollout window). The version-stripped-prefix matcher means future v2/v3 dispatchers will be visible to v1 dispatchers' collision check; semantic compatibility of the body schema is the writer's responsibility, not the parser's. |

## Triage heuristics (Phase A applies this table)

| Tier | Signals (any strong match) | Spawned workflow |
|------|----------------------------|------------------|
| **trivial** | Labels: `typo`, `docs`, `documentation`, `chore`, `good-first-issue`. Body <300 chars after stripping markdown. Title matches `typo\|rename\|bump\|version\|readme`. No stack trace. Single file named. | Read pre-collected research → minimal edit → test (if touched code is tested) → PR. **No brainstorm, no multi-step plan.** Phase 1 of `/uberdev:review-pr` runs the post-impl reviewer fanout and Phase 2 runs the simplify lenses after the PR opens. |
| **small** | Clear reproduction + error message. Localized to one module/package. Estimated ≤50 LOC. Labels: `bug` (scoped) or none. Not cross-cutting. | Read pre-collected research → lightweight TodoWrite plan (3–6 tasks) → TDD → PR. **No brainstorm.** Phase 1 of `/uberdev:review-pr` runs the post-impl reviewer fanout and Phase 2 runs the simplify lenses after the PR opens. |
| **medium/large** *(default)* | Labels: `epic`, `needs-discussion`, `architectural`, `infrastructure` (multi-service), `refactor`. ≥3 files/modules mentioned. Missing clear problem statement. Cross-package scope. | Full `/uberdev:brainstorm` → `/uberdev:write-plan` → `/uberdev:subagent-driven-dev` → `/uberdev:review-pr` pipeline. |

**When in doubt, default to medium/large.** Misclassification is recoverable.

## Steps

<!-- Prereqs (gh, jq) verified at session start by hooks/session-start. The
     previous `command -v gh` block here was theatre — Claude reads command
     files as instructions, not bash, so the check was never actually executed
     at command-invocation time. Real runtime guards live in the session-start
     hook (jq fails the hook fast; gh injects a one-time warning when missing). -->

### 1. Parse arguments

Extract one or more issue numbers + optional override flags. The parser scans every space-separated token in `$ARGUMENTS` and collects only those that are **purely numeric** (anchored regex `^[0-9]+$`); deduplicates so `/turbo 5 5 6` doesn't race two agents into the same worktree path; and rejects empty input.

```bash
# --- Phase A: claude version gate (NEW v0.22.0; floor raised to 2.1.152 for #246) ---
# Hard-require Claude Code >= 2.1.152. Two reasons stacked:
#   (1) `claude --bg` requires 2.1.139+ (the original v0.22.0 floor). Older
#       versions cannot dispatch background sessions and the entire /solve and
#       /turbo contract is voided.
#   (2) `--permission-mode bypassPermissions` (paired with `--dangerously-skip-permissions`
#       per #246 — see lib/dispatch.sh:192-198) requires 2.1.152+. On
#       2.1.139–2.1.151 the bg dispatch would hit `claude --bg ... --permission-mode
#       bypassPermissions` → exit-2 unknown-flag, surfacing as
#       `dispatch_setup_failed phase:dispatch rc:2` with the root-cause attribution
#       (your claude is too old) buried in BG_STDOUT_LOG.
# Fail loudly with an actionable npm install pointer; do not silently degrade.
_uberdev_require_claude_version() {
  local min="$1"
  local cur
  cur="$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$cur" ]]; then
    echo "error: \`claude --version\` returned no output; cannot verify version >= $min" >&2
    exit 1
  fi
  if [[ "$(printf '%s\n%s\n' "$min" "$cur" | sort -V | head -1)" != "$min" ]]; then
    echo "error: /solve and /turbo require Claude Code >= $min (found: $cur)" >&2
    echo "       install with: npm i -g @anthropic-ai/claude-code@latest" >&2
    exit 1
  fi
}

_uberdev_audit_emit() {
  # No-op if SOLVE_AUDIT_LOG is unset; otherwise append a JSON line.
  [[ -n "${SOLVE_AUDIT_LOG:-}" ]] || return 0
  local event="$1" data="${2-}"
  [[ -z "$data" ]] && data='{}'
  printf '{"ts":"%s","event":"%s","data":%s}\n' \
    "$(date -u +%FT%TZ)" "$event" "$data" >> "$SOLVE_AUDIT_LOG"
}

# Pipeline form (portable across bash and zsh). The naive `for token in
# $ARGUMENTS; do …` loop does NOT word-split scalar parameters in zsh —
# zsh's SH_WORD_SPLIT is off by default, so the loop runs ONCE with the entire
# argument string as a single token, the regex rejects it, and `/turbo 5 6 7`
# dies at the usage check. The pipeline below tokenizes via `tr ' ' '\n'`,
# filters to purely-numeric tokens (anchored `^[0-9]+$` rejects flag tokens
# like `--terminal=foo123` even when they contain digits), and dedupes
# preserving first-seen order (same-issue race would collide on the shared
# worktree path `.claude/worktrees/solve-issue-N/` — the second spawn's
# `git worktree remove --force` would nuke the first's checkout mid-run).
# Array assignment `arr=($(...))` word-splits on $IFS in BOTH bash and zsh.
ISSUE_NUMS=($(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk -v c0=0 '!seen[$c0]++'))

OVERRIDE=$(echo "$ARGUMENTS" | grep -oE '\-\-(trivial|small|full)' | head -1 | sed 's/--//')
# --- Phase A: --terminal= deprecation shim (NEW v0.22.0) ---
# The flag is parsed without error, emits TERMINAL_FLAG_DEPRECATED_NOTE once
# per run on first encounter, records `deprecated_flag_used` audit event, and
# has no behavioural effect. Mirrors merge-pipeline PR #49 (STRATEGY_FLAGS,
# BYPASS_PROTECTIONS) template.
#
# Bind the deprecation note shell-side (the Constants table is documentation;
# Claude reads it as prose, not bash). Regression guard:
# tests/dispatch-claude-bg.test.sh anchors on `^TERMINAL_FLAG_DEPRECATED_NOTE=`
# — keep this assignment present and at column 0.
TERMINAL_FLAG_DEPRECATED_NOTE='warning: --terminal=cmux|ghostty|iterm|terminal|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.'
TERMINAL_FLAG_USED="$(echo "$ARGUMENTS" | grep -oE '\-\-terminal=[a-z]+' | head -1 || true)"
if [[ -n "$TERMINAL_FLAG_USED" ]]; then
  echo "$TERMINAL_FLAG_DEPRECATED_NOTE" >&2
  _uberdev_audit_emit deprecated_flag_used \
    "{\"flag\":$(printf %s "$TERMINAL_FLAG_USED" | jq -Rs .)}" || true
fi
# Also swallow $SOLVE_TERMINAL env var with the same deprecation note.
if [[ -n "${SOLVE_TERMINAL:-}" ]]; then
  echo "$TERMINAL_FLAG_DEPRECATED_NOTE" >&2
  _uberdev_audit_emit deprecated_flag_used \
    "{\"env\":\"SOLVE_TERMINAL\",\"value\":$(printf %s "$SOLVE_TERMINAL" | jq -Rs .)}" || true
fi
AUTO_FLAG=$(echo "$ARGUMENTS" | grep -oE '\-\-auto' | head -1)
# --- Phase A: --force flag parser (NEW v0.28.0 — claim override) ---
# Accepts `--force` or `-f` as a stale-claim override for the per-issue claim
# protocol (Step 4.5 below). When set, dispatch proceeds even if the issue
# already carries the `uberdev:active` label from a prior /solve or /turbo
# spawn (e.g. teammate's machine crashed, or any other stale claim). Records
# `claim_force_override` audit event per issue overridden so post-hoc grep can
# distinguish intentional overrides from regressions. Anchored `^--force$` /
# `^-f$` token regex — flag fragments inside larger tokens (e.g. `--force-foo`)
# do NOT match. Batch-wide like every other override flag — no per-issue form.
FORCE_FLAG="$(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^(--force|-f)$' | head -1)"
if [[ -n "$FORCE_FLAG" ]]; then
  FORCE_CLAIM=1
else
  FORCE_CLAIM=0
fi
# --- Phase A: claim-protocol shell constants (NEW v0.28.0) ---
# Bind the Constants-table values shell-side. The Constants table is
# documentation prose (Claude reads it as Markdown, not bash); these
# assignments make the values available to the Step 4 collision check and
# the Step 4.5 claim-write loop. Keep at column 0 — the test suite
# (tests/solve-claim.test.sh) anchors on `^UBERDEV_ACTIVE_LABEL=` and
# `^CLAIM_COMMENT_MARKER=` to verify drift between the Constants table
# and the bound shell values.
UBERDEV_ACTIVE_LABEL='uberdev:active'
UBERDEV_ACTIVE_LABEL_COLOR='D93F0B'
UBERDEV_ACTIVE_LABEL_DESCRIPTION='Issue currently being worked on by a /solve or /turbo dispatcher. Auto-managed; do not edit.'
CLAIM_COMMENT_MARKER='<!-- uberdev-claim-comment v1 -->'
# --- Phase A: --effort=<level> parser (NEW v0.22.1) ---
# `claude --bg` does NOT inherit the parent session's /effort setting in
# Claude Code 2.1.139, so every background spawn must pass `--effort <level>`
# explicitly or the bg daemon picks its own default (regression silently
# downgraded /turbo quality before this parser landed). Precedence:
#   CLI flag (--effort=<level>) > env var (UBERDEV_SOLVE_EFFORT) >
#   per-repo config (solve_effort:) > EFFORT_LEVEL_DEFAULT (`max`).
# Default is `max` because /turbo is unattended — quality dominates wall-clock
# and cost. Interactive /solve callers who want to spend less can pass
# --effort=high or set solve_effort: in .claude/uberdev.local.md.
# Lowercase-only by design — strict casing rejection would surprise users; the
# validation `case` below catches in-enum typos.
EFFORT_FLAG_VALUE="$(echo "$ARGUMENTS" | grep -oE '\-\-effort=[a-z]+' | head -1 | sed 's/--effort=//')"
EFFORT_SOURCE=default
if [[ -n "$EFFORT_FLAG_VALUE" ]]; then
  EFFORT_LEVEL="$EFFORT_FLAG_VALUE"
  EFFORT_SOURCE=cli
elif [[ -n "${UBERDEV_SOLVE_EFFORT:-}" ]]; then
  EFFORT_LEVEL="$UBERDEV_SOLVE_EFFORT"
  EFFORT_SOURCE=env
else
  # Probe the config file directly so explicit `solve_effort: max` attributes to
  # `source=config`; identity-with-default of the resolved value cannot
  # disambiguate config-set-to-default from absent-config.
  if [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  fi
  if command -v _uberdev_read_nested >/dev/null 2>&1 \
    && [ -n "$(_uberdev_read_nested solve_effort "$UBERDEV_CONFIG_FILE")" ]; then
    EFFORT_SOURCE=config
  else
    EFFORT_SOURCE=default
  fi
  if command -v uberdev_read_enum >/dev/null 2>&1; then
    EFFORT_LEVEL="$(uberdev_read_enum solve_effort UBERDEV_SOLVE_EFFORT 'low|medium|high|xhigh|max' 'max')"
  else
    EFFORT_LEVEL=max
  fi
fi
# Explicit validation when the value came from CLI or env (uberdev_read_enum
# validates only when it reads the value itself). Reject loudly — a typoed
# `--effort=hgh` would otherwise pass through and `claude --effort hgh` would
# fail at the child with a less actionable error.
case "$EFFORT_LEVEL" in
  low|medium|high|xhigh|max) ;;
  *) echo "error: --effort='$EFFORT_LEVEL' not in {low,medium,high,xhigh,max}" >&2; exit 1 ;;
esac
# --- Phase A: --backend=<name> parser (NEW v0.29.0 — RFC 0004) ---
# Selects the dispatch backend. Precedence (the established config-read.sh
# order): --backend= CLI flag > UBERDEV_DISPATCH_BACKEND env > dispatch_backend:
# in .claude/uberdev.local.md > default `auto`. `auto` defers to the
# platform-aware fallback chain in lib/dispatch.sh (uberdev_dispatch_preflight).
BACKEND_FLAG_VALUE="$(echo "$ARGUMENTS" | grep -oE '\-\-backend=[a-z-]+' | head -1 | sed 's/--backend=//')"
if [[ -n "$BACKEND_FLAG_VALUE" ]]; then
  DISPATCH_BACKEND="$BACKEND_FLAG_VALUE"
elif [[ -n "${UBERDEV_DISPATCH_BACKEND:-}" ]]; then
  DISPATCH_BACKEND="$UBERDEV_DISPATCH_BACKEND"
else
  if [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  fi
  if command -v uberdev_read_enum >/dev/null 2>&1; then
    DISPATCH_BACKEND="$(uberdev_read_enum dispatch_backend UBERDEV_DISPATCH_BACKEND \
      'auto|claude-bg|wezterm|background' 'auto')"
  else
    DISPATCH_BACKEND=auto
  fi
fi
# Explicit validation when the value came from CLI or env (uberdev_read_enum
# validates only the value it reads itself) — reject loudly, mirroring the
# --effort parser's post-validation case.
case "$DISPATCH_BACKEND" in
  auto|claude-bg|wezterm|background) ;;
  *) echo "error: --backend='$DISPATCH_BACKEND' not in {auto,claude-bg,wezterm,background}" >&2; exit 1 ;;
esac
export UBERDEV_DISPATCH_BACKEND_REQUESTED="$DISPATCH_BACKEND"
if [[ ${#ISSUE_NUMS[@]} -eq 0 ]]; then
  echo "Usage: /uberdev:solve|/uberdev:turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto]"
  exit 1
fi
# --full is an alias for medium/large (keeps current behavior)
[[ "$OVERRIDE" == "full" ]] && OVERRIDE="medium"

# AUTO_PERMISSIONS precedence (controls --dangerously-skip-permissions on the
# spawned agent — see lib/dispatch.sh:uberdev_dispatch_resolve_env for the
# remap rationale: auto-mode is dead in practice, so AUTO now resolves to the
# same skip-permissions flag as SKIP_PERMISSIONS):
#   CLI flag > env var > per-repo config > default off.
# NOTE: AUTO_PERMISSIONS is distinct from AUTO_MODE. AUTO_MODE is set by the
# caller (solve.md=0, turbo.md=1) to gate turbo-vs-interactive behavior in
# Steps 4, 5a, 6. Naming kept disjoint to prevent collision.
if [[ -n "$AUTO_FLAG" ]]; then
  AUTO_PERMISSIONS=1
elif [[ "$SOLVE_AUTO" == "1" ]]; then
  AUTO_PERMISSIONS=1
elif [[ -f .claude/uberdev.local.md ]] && grep -qE '^solve_auto:[[:space:]]*true[[:space:]]*$' .claude/uberdev.local.md; then
  AUTO_PERMISSIONS=1
else
  AUTO_PERMISSIONS=0
fi

# Permission-mode description for the prompt heredocs. Flat-var if/else
# form (NOT the v0.21.0 one-liner `echo "Permission mode: $([[…]] && echo
# … || echo …)"` which trips zsh NOMATCH when re-emitted into a generated
# .sh — regression guard tests/audit-fixups.test.sh C8).
# Both SKIP_PERMISSIONS and AUTO_PERMISSIONS branches now resolve to the
# bypass tier (post-#241 follow-up — auto-mode is dead in practice; see
# lib/dispatch.sh:uberdev_dispatch_resolve_env doc block). The if/elif
# ordering is preserved for observability — the PERM_DESC string distinguishes
# which env var the caller set so post-hoc grep can attribute the bypass to
# /goal (SKIP) vs /turbo --auto / /solve --auto (AUTO).
if [[ "${SKIP_PERMISSIONS:-0}" == "1" ]]; then
  PERM_DESC="bypass (--dangerously-skip-permissions --permission-mode bypassPermissions; SKIP_PERMISSIONS tier — /goal autonomous loop)"
elif [[ "$AUTO_PERMISSIONS" == "1" ]]; then
  PERM_DESC="bypass (--dangerously-skip-permissions --permission-mode bypassPermissions; AUTO_PERMISSIONS tier — /turbo --auto / /solve --auto)"
else
  PERM_DESC="default (manual per-tool gating)"
fi
echo "Permission mode: $PERM_DESC"
```

`$OVERRIDE`, `$AUTO_FLAG`, and `$AUTO_PERMISSIONS` apply **batch-wide**. There is no per-issue override syntax — run separate `/turbo` invocations if you need different flags per issue.

### 2. Detect repo

```bash
gh repo view --json nameWithOwner --jq .nameWithOwner
```

### 3. (RETIRED v0.22.0 — terminal detection removed for #85)

The Phase A bg-dispatch probes (added near the top of the SKILL.md Phase A
block by the v0.22.0 refactor: the claude-version gate — originally 2.1.139,
raised to 2.1.152 for #246 to cover `--permission-mode bypassPermissions` — and the
`MAX_PARALLEL_BG_AGENTS` resolution, both still in SKILL.md Phase A) replace
the entire former Step 3 terminal-detection cascade. The hardcoded
prompt-mode (`BG_PROMPT_MODE=argv`) is now set by
`uberdev_dispatch_resolve_env` in `lib/dispatch.sh`, not inline here.
The terminal, real-claude-path, and permission-description variables no
longer exist; see `## Deprecated Flags` in `commands/solve.md` /
`commands/turbo.md` for the `--terminal=` migration pointer.

### 4. Validate all issues (Phase A — validate-all-first)

For every issue in `ISSUE_NUMS`, fetch via `gh issue view --json` (read-only), confirm `state == OPEN`, and classify the tier per the triage table above. Capture the truncated title for the workspace tab. **If any issue fails (closed, missing, gh error), print all errors and abort with `no agents dispatched` — partial dispatches are not allowed.**

```bash
declare -A TITLES TIERS
ERRORS=()
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  # Capture stderr separately. The previous `2>&1` form merged gh's stderr
  # into $ISSUE_JSON; gh's spinner (spinner=enabled is the default) renders
  # ANSI escape frames containing raw ESC (0x1B) on slow API calls, polluting
  # the JSON and tripping `jq` with "Invalid string: control characters from
  # U+0000 through U+001F must be escaped" (exit 5). Stdout must stay pure
  # JSON; stderr only gets read on the failure path.
  GH_ERR=$(mktemp)
  # JSON fields extended in v0.28.0 with `assignees,comments` to feed Step 4.5's
  # claim-collision check below — keeps Phase A to a single round-trip per issue.
  ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,state,body,labels,assignees,comments 2>"$GH_ERR") || {
    ERRORS+=("#$ISSUE_NUM: gh fetch failed: $(<"$GH_ERR")")
    rm -f "$GH_ERR"
    continue
  }
  rm -f "$GH_ERR"
  STATE=$(jq -r .state <<<"$ISSUE_JSON")
  # --- Phase A: stale-claim sweeper on closed issues (NEW v0.28.0; #123 B4) ---
  # If a `/solve` or `/turbo` dispatcher crashed AFTER its claim-write but BEFORE
  # PR open (or the PR was force-closed without merging), the `uberdev:active`
  # label can outlive the issue itself. /merge only clears the label on
  # successful merge of a PR carrying a closing keyword — there is no other
  # auto-cleanup path. Without this sweeper, the issue would carry the label
  # forever (cannot /solve a closed issue to trigger the dispatch-time check),
  # and a re-open + retry would force every teammate into the --force override
  # path. The sweep runs BEFORE the state-reject so closed issues with a stuck
  # label get pruned even though the dispatch ultimately refuses them. The
  # subsequent reject still fires — you cannot /solve a closed issue — but the
  # GitHub state is left clean for a future re-open.
  if [[ "$STATE" != "OPEN" ]]; then
    CLOSED_HAS_ACTIVE_LABEL=$(jq -r '[.labels[].name] | index("uberdev:active") // empty' <<<"$ISSUE_JSON")
    if [[ -n "$CLOSED_HAS_ACTIVE_LABEL" ]]; then
      if gh issue edit "$ISSUE_NUM" --remove-label "uberdev:active" >/dev/null 2>&1; then
        echo "notice: #$ISSUE_NUM is $STATE but carried a stale uberdev:active label — auto-pruned" >&2
        _uberdev_audit_emit claim_released \
          "{\"issue\":$ISSUE_NUM,\"reason\":\"stale_on_closed\",\"state\":\"$STATE\"}" || true
      fi
    fi
    ERRORS+=("#$ISSUE_NUM: state=$STATE (must be OPEN)")
    continue
  fi
  # --- Phase A: claim-collision check (NEW v0.28.0) ---
  # Single-round-trip design: piggybacks on $ISSUE_JSON above. If the
  # `uberdev:active` label is present, the issue is currently claimed by a
  # prior /solve or /turbo dispatcher; extract the latest claim comment
  # (fingerprinted with CLAIM_COMMENT_MARKER to disambiguate from any
  # arbitrary user comment that happens to mention the label) and either
  # refuse (default) or warn-and-proceed (when FORCE_CLAIM=1 from the
  # `--force` / `-f` Phase A flag). The refusal path appends to ERRORS so
  # the existing "no agents dispatched" gate at the end of Step 4 produces
  # the unified abort message — partial dispatches remain forbidden.
  # Latest claim parsing: jq filters .comments[] for bodies containing the
  # marker, then takes `last` (GitHub returns .comments in chronological
  # order — newest is .comments[-1]). The grep/sed extraction tolerates
  # malformed fields by falling back to "?" so the error message never
  # blanks out on a stale comment schema.
  HAS_ACTIVE_LABEL=$(jq -r '[.labels[].name] | index("uberdev:active") // empty' <<<"$ISSUE_JSON")
  if [[ -n "$HAS_ACTIVE_LABEL" ]]; then
    # Version-agnostic prefix match (regression #123 B7): the literal
    # CLAIM_COMMENT_MARKER carries a `v1` suffix, but during a rolling upgrade
    # a v2 dispatcher's marker (`<!-- uberdev-claim-comment v2 -->`) would NOT
    # contain the v1 string — both dispatchers would then see "no live claim"
    # of the other's version, the exact failure mode the protocol exists to
    # prevent. We pass the version-stripped prefix to jq instead so the parser
    # is forward-compatible across schema bumps. The minor cost is that a
    # stray comment body containing exactly that prefix could match —
    # acceptable because the prefix is plugin-namespaced and the grep field
    # extraction below tolerates malformed fields via the `?` fallback.
    # CLAIM_COMMENT_MARKER_PREFIX strips the trailing ` vN -->` suffix; the
    # bash parameter expansion is portable to zsh.
    CLAIM_COMMENT_MARKER_PREFIX="${CLAIM_COMMENT_MARKER% v* -->}"
    LATEST_CLAIM_BODY=$(jq -r --arg marker "$CLAIM_COMMENT_MARKER_PREFIX" \
      '[.comments[] | select(.body | contains($marker))] | last | .body // empty' \
      <<<"$ISSUE_JSON")
    CLAIM_USER="?"; CLAIM_HOST="?"; CLAIM_BRANCH="?"; CLAIM_TS="?"
    if [[ -n "$LATEST_CLAIM_BODY" ]]; then
      # Field-extraction: capture grep|sed output to a temp scalar, then assign
      # the field var ONLY when the temp is non-empty. The pre-init "?" defaults
      # above stay in place when the field is missing. The naive form
      #   FIELD=$(... | grep | sed || echo "?")
      # is broken: when grep finds nothing, sed still exits 0, so `||` never
      # short-circuits; FIELD comes out empty (NOT "?"), defeating the
      # ALL_PLACEHOLDER branch below. Capture + test + conditional-assign is the
      # portable fix (Q1; #123 Phase 2 simplify-lens blocker).
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^User: '    | sed 's/^User: //');     [[ -n "$_v" ]] && CLAIM_USER="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Host: '    | sed 's/^Host: //');     [[ -n "$_v" ]] && CLAIM_HOST="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Branch: '  | sed 's/^Branch: //');   [[ -n "$_v" ]] && CLAIM_BRANCH="$_v"
      _v=$(printf '%s\n' "$LATEST_CLAIM_BODY" | grep -m1 '^Started: ' | sed 's/^Started: //');  [[ -n "$_v" ]] && CLAIM_TS="$_v"
    fi
    # F4: distinguish "no live claim comment found" (label set but body
    # extraction yielded all ?s — likely a racing dispatcher whose claim
    # comment has not yet posted, OR a stale label from a hand-edit) from
    # "claim comment found with full metadata" (standard case). The all-?
    # case gets a different message that points the operator at the likely
    # cause and the right recovery path. The audit-event payload still
    # carries the raw values so log consumers can join on prior_user.
    if [[ "$CLAIM_USER" == "?" && "$CLAIM_HOST" == "?" && "$CLAIM_BRANCH" == "?" && "$CLAIM_TS" == "?" ]]; then
      ALL_PLACEHOLDER=1
    else
      ALL_PLACEHOLDER=0
    fi
    if [[ "$FORCE_CLAIM" == "1" ]]; then
      echo "warning: #$ISSUE_NUM already claimed (user=$CLAIM_USER host=$CLAIM_HOST branch=$CLAIM_BRANCH at=$CLAIM_TS) — --force override in effect" >&2
      _uberdev_audit_emit claim_force_override \
        "{\"issue\":$ISSUE_NUM,\"prior_user\":\"$CLAIM_USER\",\"prior_host\":\"$CLAIM_HOST\",\"prior_branch\":\"$CLAIM_BRANCH\",\"prior_started\":\"$CLAIM_TS\"}" || true
    else
      if [[ "$ALL_PLACEHOLDER" == "1" ]]; then
        ERRORS+=("#$ISSUE_NUM: uberdev:active label is set but no matching claim comment was found (racing dispatcher whose comment has not posted yet, or hand-edited label) — wait a moment and retry, or pass --force to override")
      else
        ERRORS+=("#$ISSUE_NUM: already claimed by $CLAIM_USER on $CLAIM_HOST (branch $CLAIM_BRANCH, started $CLAIM_TS) — pass --force to override")
      fi
      _uberdev_audit_emit claim_collision \
        "{\"issue\":$ISSUE_NUM,\"prior_user\":\"$CLAIM_USER\",\"prior_host\":\"$CLAIM_HOST\",\"prior_branch\":\"$CLAIM_BRANCH\"}" || true
      continue
    fi
  fi
  # Title: jq the raw value, then truncate to 40 chars (with ellipsis) so the
  # tab/workspace name fits. Refine at the word boundary if you can — the
  # naive char-cut below is a safe default that always produces a non-empty
  # string with a stable upper bound.
  TITLE_RAW=$(jq -r .title <<<"$ISSUE_JSON")
  if [[ ${#TITLE_RAW} -gt 40 ]]; then
    TITLE="${TITLE_RAW:0:40}…"
  else
    TITLE="$TITLE_RAW"
  fi
  # Tier: $OVERRIDE if the user passed --trivial|--small|--full, else default
  # to "medium" (the safe escalation tier — full brainstorm + plan + review
  # pipeline). Apply the triage table above to {title, body, labels} to
  # downgrade to "trivial" or "small" when the issue is genuinely scoped that
  # way; be honest about scope (a "refactor the whole auth module" body is
  # medium even with quiet labels). The default keeps the dispatch valid even
  # if the heuristic refinement is skipped — better to over-engineer a trivial
  # fix than to under-spec a real refactor.
  TIER="${OVERRIDE:-medium}"
  # Per-repo tier clamp: if `.claude/uberdev.local.md` defines
  # `solve_tier_floor` (env: SOLVE_TIER_FLOOR) or `solve_tier_ceiling` (env:
  # SOLVE_TIER_CEILING), the resolved $TIER is clamped into [floor, ceiling]
  # via `uberdev_clamp_tier` from `plugins/uberdev/lib/config-read.sh`. Both
  # keys take an enum from {trivial, small, medium, large}; absence on either
  # side is unbounded that side; floor > ceiling emits a `floor_gt_ceiling`
  # warning and is ignored.
  if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
    FLOOR="$(uberdev_read_enum solve_tier_floor   SOLVE_TIER_FLOOR   "trivial|small|medium|large" "")"
    CEILING="$(uberdev_read_enum solve_tier_ceiling SOLVE_TIER_CEILING "trivial|small|medium|large" "")"
    TIER="$(uberdev_clamp_tier "$TIER" "$FLOOR" "$CEILING")"
  fi
  TITLES[$ISSUE_NUM]="$TITLE"
  TIERS[$ISSUE_NUM]="$TIER"
done

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  printf 'error: %s\n' "${ERRORS[@]}" >&2
  echo "no agents dispatched" >&2
  exit 1
fi

# TURBO MODE banner — print once before the per-issue loop if any tier is medium
# (deduped: a batch of three medium issues should not stack three identical banners).
if [[ "$AUTO_MODE" == "1" ]]; then
  for n in "${ISSUE_NUMS[@]}"; do
    if [[ "${TIERS[$n]}" == "medium" ]]; then
      echo "⚠️  TURBO MODE — brainstorm questions auto-answered with lead-agent recommendations." >&2
      echo "    Spec and plan are still written to disk before implementation; review the artifacts to course-correct." >&2
      break
    fi
  done
fi

# --- Phase A: bg dispatch probes + fanout cap (NEW v0.22.0) ---
# All probes run ONCE per /solve or /turbo invocation. They are hoisted out
# of the Phase B per-issue loop because the resolved values are the same for
# every spawn.
_uberdev_require_claude_version "2.1.152"
# --- Phase A: portable temp dir (NEW v0.29.0 — RFC 0004 §3.8) ---
# One temp root resolved once; every per-issue artifact (prompt, stdout log,
# claim json, status file) lives under it. Git Bash on native Windows sets
# TMPDIR; fall back to /tmp on Unix. Exported so lib/dispatch.sh inherits it.
export UBERDEV_TMPDIR="${TMPDIR:-/tmp}"
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  MAX_PARALLEL_BG_AGENTS="$(uberdev_read_int_in_range fanout_concurrency.solve_bg UBERDEV_FANOUT_SOLVE_BG 1 50 6)"
else
  MAX_PARALLEL_BG_AGENTS=6
fi

# See `_uberdev_audit_emit` definition near the top of Phase A (anchor:
# `^_uberdev_audit_emit\(\)`); no-op when $SOLVE_AUDIT_LOG is unset.
_uberdev_audit_emit effort_resolved \
  "{\"source\":\"$EFFORT_SOURCE\",\"level\":\"$EFFORT_LEVEL\"}" || true

# --- Phase A: dispatch preflight + Windows guards (NEW v0.29.0 — RFC 0004) ---
# Native-Windows-no-bash fast-fail: this pipeline is bash; under the
# PowerShell tool it cannot parse. If we are on Windows and $BASH is unset,
# fail with an actionable pointer instead of a parse error downstream.
if [ -z "${BASH:-}" ] && { [ "${OS:-}" = "Windows_NT" ] || case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) true ;; *) false ;; esac; }; then
  echo "error: /solve and /turbo need a bash shell. On native Windows install" >&2
  echo "       Git for Windows (provides Git Bash), or use WSL2 (recommended)." >&2
  exit 1
fi
# WSL2 9P-slowness warning: a repo under /mnt/c is 10-50x slower (DrvFs).
if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
  case "$PWD" in
    /mnt/*) echo "warning: repo is under /mnt/ in WSL2 — 9P/DrvFs is 10-50x slower than ext4; move it under ~/ for best /solve performance." >&2 ;;
  esac
fi
# Source lib/dispatch.sh and resolve the backend ONCE for the whole batch.
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/dispatch.sh" ]; then
  # shellcheck source=/dev/null
  . "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh"
  uberdev_dispatch_preflight || exit 1
  uberdev_dispatch_resolve_env || exit 1
else
  echo "error: lib/dispatch.sh not found at ${CLAUDE_PLUGIN_ROOT:-}/lib/" >&2
  exit 1
fi
```

### 4.5. Claim protocol — mark issue ACTIVE (NEW v0.28.0)

For every validated issue, write a three-part claim **in sequence with rollback on partial failure** (label → assignee → comment): the `uberdev:active` label (queryable for `gh issue list --label uberdev:active`), the `@me` assignee (native GitHub UI signal), and an audit comment fingerprinted with `CLAIM_COMMENT_MARKER` (the only safe parser surface for the Step 4 collision check above). All writes are **fail-loud** — any gh permission gap aborts the batch and rolls back prior claims in the same run. A silent partial claim acquisition would break the collision-prevention promise the protocol exists to enforce (a teammate running `/turbo` on an unclaimed-from-their-view issue would race the dispatcher who half-claimed it).

**Known limitation — TOCTOU race window between Step 4 check and Step 4.5 write (#123 B2).** The Step 4 collision check reads the label and comments list once; the Step 4.5 write-pass then adds the label via `gh issue edit`, which is idempotent on the GitHub side. Two dispatchers running concurrently can both observe "no label present" in their separate Step 4 reads and both successfully add the label in Step 4.5 — the protocol is **best-effort, not atomic**. The race window is bounded by the gh round-trip latency between Step 4's read and Step 4.5's first write (typically tens to hundreds of milliseconds). In practice this is acceptable for the small-team usage the protocol targets (rare concurrent dispatches on the same issue), but operators on a larger team or with high-coordination workflows should NOT rely on the protocol as a strong distributed lock. A post-write verification step (re-fetch the latest claim comment, refuse if a different dispatcher's marker won) would close the window at the cost of one extra gh round-trip per issue — deferred until measured contention warrants it. See CHANGELOG `## [0.28.0]` Why for the design tradeoff.

The claim comment body lays the parser contract: each field is `^<Name>: <value>$` on its own line, prefixed by the `CLAIM_COMMENT_MARKER` HTML comment for filtering. The "Auto-clears on /merge or issue close" footer is documentation — the actual clear happens in `merge-pipeline/SKILL.md`'s post-merge cleanup phase (issue-close-by-merge) or by the Step 5b' dispatch-failure rollback (release on spawn failure).

Per-issue claim metadata is also persisted to `$UBERDEV_TMPDIR/solve-claim-N.json` so the Phase B dispatch-failure rollback in Step 5b' below can release just the one failed claim without re-parsing the audit comment.

```bash
# --- Phase A: claim-write pass (NEW v0.28.0 — Step 4.5) ---
# Runs AFTER the bg dispatch probes (claude version + timeout-binary
# guard) above so probe failures abort BEFORE we mutate any GitHub state.
# Order matters: label create → label add → assignee add → comment. If any
# step fails, rollback all prior claims in the batch and exit 1.
#
# FAIL-LOUD label provisioning (regression fix). The label MUST exist before
# the per-issue `gh issue edit --add-label … --add-assignee …` below: gh
# cannot auto-create a label from --add-label and fails that combined
# mutation ATOMICALLY when the label is missing — taking the --add-assignee
# half down with it. `--force` already makes this call idempotent (it updates
# an existing label's colour/description, never errors on "already exists"),
# so a non-zero exit here is ALWAYS a genuine failure — gh-auth gap, missing
# repo write/triage scope, or an API/network error — never the benign
# already-exists case. A prior `|| true` swallowed exactly that failure,
# which then resurfaced downstream as a misleading "failed to write claim
# (label or assignee) — check gh auth" abort pointing at the wrong cause.
# Unlike the fail-soft `gh label create --force` in finish-branch /
# dev-pipeline / findings-to-issues (where the dependent --add-label is ALSO
# fail-soft and the label is a nice-to-have signal), here the label is the
# canonical claim signal gating a fail-loud write, so its provisioning must
# be fail-loud too. Runs once, before any claim is written (CLAIMED is still
# empty), so a clean exit 1 needs no rollback. We capture gh's stderr so the
# operator sees the real cause instead of the generic downstream message.
if ! LABEL_PROVISION_ERR=$(gh label create --force "$UBERDEV_ACTIVE_LABEL" \
    --color "$UBERDEV_ACTIVE_LABEL_COLOR" \
    --description "$UBERDEV_ACTIVE_LABEL_DESCRIPTION" 2>&1); then
  echo "error: failed to provision the '$UBERDEV_ACTIVE_LABEL' label that the claim protocol requires (gh issue edit --add-label cannot auto-create it). Check gh auth and repo write/triage permission." >&2
  echo "  gh label create said: ${LABEL_PROVISION_ERR:-<no output>}" >&2
  _uberdev_audit_emit claim_write_failed "{\"step\":\"label_create\"}" || true
  exit 1
fi

# Dispatcher identity. `gh api user` returns the gh-CLI authenticated user's
# login (matches what `--add-assignee @me` resolves to). `hostname -s` gives
# the short hostname (macOS, Linux); fallback to `hostname` if the -s flag
# is unrecognised. ISO-8601 UTC timestamp is the GitHub-comment convention.
DISPATCHER_USER=$(gh api user --jq .login 2>/dev/null)
if [[ -z "$DISPATCHER_USER" ]]; then
  echo "error: gh api user returned empty login — run \`gh auth login\` first" >&2
  exit 1
fi
DISPATCHER_HOST=$(hostname -s 2>/dev/null || hostname)
DISPATCH_TS=$(date -u +%FT%TZ)

CLAIMED=()
# _uberdev_release_claim ISSUE_NUM REASON [EXTRA_JSON]
#   Releases one issue's claim atomically (single combined gh round-trip:
#   --remove-label + --remove-assignee in one mutation) and emits a
#   canonically-shaped `claim_released` audit event.
#
# Why one helper for all 4 release sites (batch rollback, comment-failure
# rollback, Phase B dispatch-failure rollback, future sites): without it, a
# new rollback path can silently forget one of the three operations
# (label-remove, assignee-remove, audit-emit) — the exact shape of the
# #123 B5 regression that the merge-pipeline cleanup needed an explicit
# fix for. Routing every release through this helper forecloses that
# regression by construction. Folds suggestion S1 (canonical
# claim_released payload) and blocker E3 (combine paired gh calls) into
# one site.
#
# Atomicity note: `gh issue edit --remove-label X --remove-assignee Y`
# fails atomically on partial error (gh aborts on the first failing op
# and propagates its exit). Pre-fold the code paired two separate gh
# calls with a partial-rollback wedge between them — that wedge is no
# longer needed.
#
# Fail-soft on the gh call (||true): every caller invokes release in an
# already-failing path; masking the original error with a secondary
# rollback failure is the wrong tradeoff. Audit-emit is similarly
# fail-soft via `|| true` on the _uberdev_audit_emit return.
_uberdev_release_claim() {
  local issue="$1" reason="$2" extra="${3:-}"
  gh issue edit "$issue" --remove-label "$UBERDEV_ACTIVE_LABEL" --remove-assignee "@me" >/dev/null 2>&1 || true
  local payload="{\"issue\":$issue,\"reason\":\"$reason\""
  [[ -n "$extra" ]] && payload="${payload},${extra}"
  payload="${payload}}"
  _uberdev_audit_emit claim_released "$payload" || true
}
_uberdev_rollback_claims() {
  # Best-effort rollback — delegates to _uberdev_release_claim (above) so
  # the remove-label + remove-assignee + audit triplet is defined once.
  local c
  # B8: explicitly distinguish the no-op case from a successful rollback.
  # If the first issue in a batch fails at the label-add step before any
  # CLAIMED+=("…") runs, the for-loop below iterates zero times and prints
  # nothing — the user sees "error: #N failed to add label" but nothing
  # confirming that the rollback was a no-op (vs. silently succeeded with
  # zero work). The info line makes the no-op auditable so a partial-state
  # bug elsewhere cannot hide behind an empty CLAIMED array.
  if [[ ${#CLAIMED[@]} -eq 0 ]]; then
    echo "info: claim rollback: no prior claims to release (CLAIMED is empty — first-issue failure)" >&2
    return 0
  fi
  for c in "${CLAIMED[@]}"; do
    _uberdev_release_claim "$c" "batch_rollback"
  done
}

for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  TIER="${TIERS[$ISSUE_NUM]}"
  # CLAIM_BODY assembled via heredoc inside $(cat <<EOF…EOF) so $ISSUE_NUM,
  # $TIER, $DISPATCHER_USER etc. expand normally. The marker line MUST be
  # the first line — the collision-check jq filter searches via
  # `.body | contains($marker)` and the field grep regex anchors on
  # `^User: ` / `^Host: ` / `^Branch: ` / `^Started: `.
  CLAIM_BODY="$(cat <<EOF
$CLAIM_COMMENT_MARKER
uberdev:active — claimed for /solve or /turbo dispatch

User: @$DISPATCHER_USER
Host: $DISPATCHER_HOST
Branch: worktree-solve-issue-$ISSUE_NUM
Tier: $TIER
Started: $DISPATCH_TS

Auto-clears on /merge or issue close. If this claim is stale, override with:
  /turbo $ISSUE_NUM --force    (or /solve $ISSUE_NUM --force)
EOF
)"
  # Combined claim write: label + assignee in one gh round-trip. gh fails
  # atomically on partial error (the first failing op's exit propagates),
  # so the inline partial-rollback wedge that used to live between paired
  # add-label and add-assignee calls is no longer needed (E1, #123 Phase 2
  # simplify-lens blocker — halves the gh round-trip count on the claim hot
  # path and tightens atomicity).
  if ! gh issue edit "$ISSUE_NUM" --add-label "$UBERDEV_ACTIVE_LABEL" --add-assignee "@me" >/dev/null 2>&1; then
    echo "error: #$ISSUE_NUM: failed to write claim (label or assignee) — check gh auth / repo permissions" >&2
    _uberdev_audit_emit claim_write_failed "{\"issue\":$ISSUE_NUM,\"step\":\"label_or_assignee\"}" || true
    _uberdev_rollback_claims
    exit 1
  fi
  if ! printf '%s' "$CLAIM_BODY" | gh issue comment "$ISSUE_NUM" --body-file - >/dev/null 2>&1; then
    echo "error: #$ISSUE_NUM: failed to post claim audit comment" >&2
    _uberdev_audit_emit claim_write_failed "{\"issue\":$ISSUE_NUM,\"step\":\"comment\"}" || true
    # Release this issue's partial claim (label+assignee were set above)
    # before the batch rollback runs. Routes through the shared helper
    # (E3+S1) so the remove-label + remove-assignee + audit triplet stays
    # defined in one place.
    _uberdev_release_claim "$ISSUE_NUM" "claim_write_failed"
    _uberdev_rollback_claims
    exit 1
  fi
  # Per-issue claim metadata for the Phase B dispatch-failure rollback
  # (Step 5b' below reads this on $BG_DISPATCH_RC != 0).
  cat > "$UBERDEV_TMPDIR/solve-claim-$ISSUE_NUM.json" <<EOF2
{"issue":$ISSUE_NUM,"user":"$DISPATCHER_USER","host":"$DISPATCHER_HOST","branch":"worktree-solve-issue-$ISSUE_NUM","tier":"$TIER","started":"$DISPATCH_TS","forced":$([[ "$FORCE_CLAIM" == "1" ]] && echo true || echo false)}
EOF2
  CLAIMED+=("$ISSUE_NUM")
  _uberdev_audit_emit claim_acquired \
    "{\"issue\":$ISSUE_NUM,\"user\":\"$DISPATCHER_USER\",\"host\":\"$DISPATCHER_HOST\",\"tier\":\"$TIER\",\"forced\":$([[ "$FORCE_CLAIM" == "1" ]] && echo true || echo false)}" || true
done
```

### 5. Per-issue dispatch (Phase B — spawn one bg agent per issue)

For each validated issue, write its prompt file (Step 5a), then dispatch via `claude --bg` (Step 5b'). Step 5a runs in a serial per-issue for-loop (heredoc writes are cheap). Step 5b' is wrapped in a wave-batching outer loop (mirroring `merge-pipeline/SKILL.md:421`) that respects `MAX_PARALLEL_BG_AGENTS` — `ceil(N / cap)` sequential single-message waves, with one `solve_bg_fanout_wave_started` audit event per wave. Per-issue dispatch outcomes are tracked in `SPAWNED` (success) and `DISPATCH_FAILED` (failure) so the user sees exactly which issues spawned and which didn't — no silent partial-batch failures.

```bash
SPAWNED=()
DISPATCH_FAILED=()
# Step 5a per-issue prompt-write loop: heredoc writes are cheap and serial; this
# loop does NOT need wave-batching (only the bg dispatch does — see Step 5b').
for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
  TIER="${TIERS[$ISSUE_NUM]}"
  TITLE="${TITLES[$ISSUE_NUM]}"
```

#### 5a. Write tier-appropriate prompt

The trivial/small heredocs commit and then hand off to `uberdev:finish-branch` (with `--turbo` forwarded on the auto-mode branch) for push, PR creation, and the chain into `/uberdev:review-pr`. Medium/large dispatches `/uberdev:orchestrator`, which itself routes through `uberdev:finish-branch`. All tiers converge on the same single PR-creation + chain hand-off site, owning `PR_URL_REGEX` validation and the canonical `Skill("uberdev:review-pr")` invocation. The medium prompt branches on `AUTO_MODE=1` to inject `--turbo` into the orchestrator dispatch.

The `if/else/fi` blocks below stay at column 0 (zsh and bash do not require physical indentation inside `for ... done`); `tests/turbo-flow.test.sh` anchors its differential-guard awk on `^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$` and must keep matching unchanged. Do not indent these blocks when the loop wraps them.

**trivial:**

```bash
if [[ "$AUTO_MODE" != "1" ]]; then
# trivial heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your working context. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues whose research was persisted under the previous fanout.
3. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
4. Add/update a test ONLY if the touched code is already tested.
5. Run the relevant test file + lint for that package.
6. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
7. **Hand off to \`uberdev:finish-branch\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
else
# trivial heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
3. Add/update a test ONLY if the touched code is already tested.
4. Run the relevant test file + lint for that package.
5. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
6. **Hand off to \`uberdev:finish-branch --turbo\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr --turbo")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
fi
```

**small:**

```bash
if [[ "$AUTO_MODE" != "1" ]]; then
# small heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your TodoWrite plan as constraints/considerations. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues.
3. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
4. TDD: write the failing test first, then implement, then green.
5. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
6. **Hand off to \`uberdev:finish-branch\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
else
# small heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt" << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
3. TDD: write the failing test first, then implement, then green.
4. Commit with conventional message. Include \`Closes #$ISSUE_NUM\` in the eventual PR body.
5. **Hand off to \`uberdev:finish-branch --turbo\`.** finish-branch owns push, PR creation with URL validation, and the canonical \`Skill("uberdev:review-pr --turbo")\` chain hand-off (Phase 2 runs the 3-lens simplify ceremony — reuse / quality / efficiency — on the strictly larger diff). Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
fi
```

**medium** *(and `--full`)*:

```bash
if [[ "$AUTO_MODE" == "1" ]]; then
# claude --bg 2.1.139+ does NOT slash-expand argv-supplied opening
# messages, so wrap the slash invocation in a natural-language imperative the
# child must interpret as an instruction rather than answer conversationally.
echo "Invoke the slash command /uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM now. Do not respond conversationally — execute it." > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
else
echo "Invoke the slash command /uberdev:orchestrator solve GH issue #$ISSUE_NUM now. Do not respond conversationally — execute it." > "$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
fi
done
```

#### 5b. (RETIRED v0.22.0 — launcher shell script removed for #85)

The per-issue launcher heredoc (formerly the per-N temp shell script with
placeholder substitution), the `cd REPO_ROOT` prologue, the worktree-cleanup
pre-step, the `timeout … CLAUDE_BIN … --worktree solve-issue-N … "$PROMPT"`
invocation, and the BSD/GNU-`sed` placeholder substitution have all been
replaced by the inline `claude --bg` dispatch in Step 5b' below.
`claude --bg --worktree solve-issue-N` handles the worktree-cleanup and
supervised-daemon spawn natively. `MODEL`, `PERM_FLAG`, `SOLVE_TIMEOUT`,
and `TIMEOUT_BIN` are resolved by `uberdev_dispatch_resolve_env()` in
`lib/dispatch.sh` (sourced + called at the end of Phase A).

#### 5b'. Dispatch via `claude --bg` (NEW v0.22.0)

SAFE prompt-passthrough forms — Q1 decision per `docs/uberdev/specs/2026-05-12-replace-cmux-with-bg-agent-view-design.md`:
- **`--prompt-file <path>`** → trusted path arg; file contents never reach the shell.
- **stdin pipe** → file content streamed on FD 0; no argv quoting concern.
- **positional argv via bash array** → backwards-compatible last resort; the prompt body lands in a single array slot, never re-evaluated through the shell.

**UNSAFE — DO NOT USE:**
- Direct interpolation of `$PROMPT` as a single double-quoted argv slot (e.g. invoking the bg dispatcher with `"$PROMPT"` as the trailing arg) → backticks / `$(…)` in issue body shell-evaluate.
- Re-evaluation forms (any `eval`-driven dispatch using `printf %q` to quote the prompt body) → re-evaluation of attacker-influenced text; security research §Findings classified this ERROR-class.
- `bash -c` wrapper with `$PROMPT` interpolated inside the inner double-quoted command string → double-quote-inside-double-quote interpolation hazard.

`MODEL`, `PERM_FLAG`, `SOLVE_TIMEOUT`, and `TIMEOUT_BIN` are resolved by `uberdev_dispatch_resolve_env()` in `lib/dispatch.sh` (sourced + called at the end of Phase A). They're batch-invariant — resolved once per `/solve` or `/turbo` invocation, then consumed by the wave-batching dispatch below.

The per-issue dispatch is wrapped in a wave-batching outer loop. Mirrors `merge-pipeline/SKILL.md:421`'s idiom: `ceil(N / cap)` sequential single-message waves, one `solve_bg_fanout_wave_started` audit event per wave.

```bash
# --- Phase B: wave-batching outer loop (NEW v0.22.0) ---
# The inner loop body stays at column 0 (bash and zsh do not require physical
# indentation inside `for ((…)); do … done`); tests/dispatch-claude-bg.test.sh
# regex-matches the inner-body invariants in lib/dispatch.sh (re-anchored T2).
TOTAL_ISSUES="${#ISSUE_NUMS[@]}"
WAVE_COUNT=$(( (TOTAL_ISSUES + MAX_PARALLEL_BG_AGENTS - 1) / MAX_PARALLEL_BG_AGENTS ))
for (( wave_index = 1; wave_index <= WAVE_COUNT; wave_index++ )); do
wave_start=$(( (wave_index - 1) * MAX_PARALLEL_BG_AGENTS ))
wave_end=$(( wave_start + MAX_PARALLEL_BG_AGENTS - 1 ))
(( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))
wave_size=$(( wave_end - wave_start + 1 ))
_uberdev_audit_emit solve_bg_fanout_wave_started \
  "{\"wave_index\":$wave_index,\"wave_size\":$wave_size}"
# v0.22.3 (#100): subarray slice replaces 0-indexed iteration (zsh portability)
for ISSUE_NUM in "${ISSUE_NUMS[@]:$wave_start:$wave_size}"; do
TIER="${TIERS[$ISSUE_NUM]}"
TITLE="${TITLES[$ISSUE_NUM]}"
# Dispatch one issue via the backend resolved by uberdev_dispatch_preflight
# (Phase A). lib/dispatch.sh owns the per-backend mechanism; this loop just
# routes. PROMPT_FILE is the per-issue prompt written in Step 5a.
# DISPATCH_RC + DISPATCH_ID are reset at the top of uberdev_dispatch_one
# (lib/dispatch.sh, central SSOT reset); no pre-init needed at this call site.
# DISPATCH_RC is documented as always-set after uberdev_dispatch_one returns
# (uberdev_dispatch_one's header contract in lib/dispatch.sh); no defensive
# ${:-1} default needed.
PROMPT_FILE="$UBERDEV_TMPDIR/solve-prompt-$ISSUE_NUM.txt"
uberdev_dispatch_one "$ISSUE_NUM" "$TIER" "$PROMPT_FILE"
BG_DISPATCH_RC="$DISPATCH_RC"
BG_SESSION_ID="${DISPATCH_ID:-}"

if [[ "$BG_DISPATCH_RC" -eq 0 ]]; then
  # lib/dispatch.sh emitted agent_dispatched with the backend-specific id.
  SPAWNED+=("#$ISSUE_NUM ($TIER, ${UBERDEV_RESOLVED_BACKEND} ${BG_SESSION_ID:-?})")
else
  # lib/dispatch.sh exports DISPATCH_LOG on failure; tail it for the report.
  TAIL_OUTPUT="$(tail -3 "${DISPATCH_LOG:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
  DISPATCH_FAILED+=("#$ISSUE_NUM: ${TAIL_OUTPUT:-(no output captured; check ${DISPATCH_LOG:-the dispatch log})}")
  # --- Phase B: claim rollback on dispatch failure (NEW v0.28.0) ---
  # Release the claim acquired in Step 4.5 so a retry (or a teammate) can
  # pick up the issue without a --force override. Fail-soft on every gh
  # call — rollback runs in an already-failing path and we should never
  # mask the dispatch error with a secondary cleanup failure. The release
  # comment uses the same CLAIM_COMMENT_MARKER fingerprint so future
  # claim-collision checks treat the release as the latest claim event
  # (the parser takes `last` of the marker-matching comments and the
  # release body's missing User/Host/Branch/Started lines surface as "?"
  # — semantically correct: the claim is no longer held).
  #
  # B3 ownership check: between our Step 4.5 claim-write and this rollback,
  # a teammate could have raced in and won — most likely via --force after
  # seeing a stuck label from a different bug. Unconditional rollback would
  # strip THEIR claim. Re-fetch the latest marker-matched claim comment, parse
  # its `User: ` line, and only roll back if it still names $DISPATCHER_USER.
  # The check uses the version-stripped prefix matcher (mirrors the Step 4
  # collision-check change for B7). When ownership cannot be confirmed (claim
  # comment fetch failed, body parse returned "?"), conservative-skip with a
  # warning — better to leave a stuck label for the next sweeper pass than to
  # strip a teammate's live claim.
  CLAIM_COMMENT_MARKER_PREFIX="${CLAIM_COMMENT_MARKER% v* -->}"
  CURRENT_CLAIM_USER="?"
  CURRENT_CLAIM_JSON=$(gh issue view "$ISSUE_NUM" --json comments 2>/dev/null) || CURRENT_CLAIM_JSON=""
  if [[ -n "$CURRENT_CLAIM_JSON" ]]; then
    CURRENT_CLAIM_BODY=$(jq -r --arg marker "$CLAIM_COMMENT_MARKER_PREFIX" \
      '[.comments[] | select(.body | contains($marker))] | last | .body // empty' \
      <<<"$CURRENT_CLAIM_JSON" 2>/dev/null)
    if [[ -n "$CURRENT_CLAIM_BODY" ]]; then
      CURRENT_CLAIM_USER=$(printf '%s\n' "$CURRENT_CLAIM_BODY" | grep -m1 '^User: ' | sed 's/^User: @//; s/^User: //' || echo "?")
    fi
  fi
  if [[ "$CURRENT_CLAIM_USER" != "$DISPATCHER_USER" ]]; then
    echo "warning: #$ISSUE_NUM: dispatch-failure rollback skipped — latest claim is owned by '$CURRENT_CLAIM_USER' (we are '$DISPATCHER_USER'); leaving label/assignee in place to avoid stripping a racing dispatcher's claim" >&2
    _uberdev_audit_emit claim_released \
      "{\"issue\":$ISSUE_NUM,\"reason\":\"dispatch_failure_rollback_skipped\",\"rc\":$BG_DISPATCH_RC,\"current_owner\":\"$CURRENT_CLAIM_USER\"}" || true
  else
    # Combined cleanup + canonical claim_released emit via the shared helper
    # (E3+S1 fold; #123 Phase 2 simplify-lens blocker). The helper bundles
    # --remove-label + --remove-assignee into one gh round-trip and emits a
    # claim_released event with the standard {issue, reason, ...extra} shape.
    # The release-comment post still runs separately below — it carries the
    # CLAIM_COMMENT_MARKER fingerprint so future claim-collision parsers see
    # the release as the latest claim event.
    _uberdev_release_claim "$ISSUE_NUM" "dispatch_failure" "\"rc\":$BG_DISPATCH_RC,\"user\":\"$DISPATCHER_USER\",\"host\":\"$DISPATCHER_HOST\""
    RELEASE_BODY="$(cat <<EOF
$CLAIM_COMMENT_MARKER
uberdev:active claim released — dispatch failed (rc=$BG_DISPATCH_RC)

User: @$DISPATCHER_USER
Host: $DISPATCHER_HOST
Branch: worktree-solve-issue-$ISSUE_NUM
Released: $(date -u +%FT%TZ)

The issue is unclaimed again — retry with /solve $ISSUE_NUM or /turbo $ISSUE_NUM.
EOF
)"
    printf '%s' "$RELEASE_BODY" | gh issue comment "$ISSUE_NUM" --body-file - >/dev/null 2>&1 || true
  fi
  rm -f "$UBERDEV_TMPDIR/solve-claim-$ISSUE_NUM.json"
fi
done
done
```

**Why the array form not `eval`:** spec-reviewer finding 1. The array shape makes argv composition explicit and avoids re-evaluation. `"${cmd[@]}"` preserves each slot as one argv element regardless of internal whitespace, backticks, or `$(…)` in `$PROMPT_BODY`.

#### 5c. (RETIRED v0.22.0 — per-terminal dispatch case statement removed for #85)

The five-branch `case "$TERMINAL" in cmux) … ghostty) … iterm) …
terminal) … nohup|*) … esac` block and the 0.6s inter-Ghostty sleep have
been replaced by `claude --bg --worktree solve-issue-N` in Step 5b'
above. Background sessions run in a supervised daemon (see prior-art
docs at `code.claude.com/docs/en/agent-view`) without terminal-emulator
initialisation races.

**Why we DON'T keep an opt-in `--terminal=` path:** three branches
(`iterm`, `terminal`, `nohup`) had **zero test coverage** today (see
`test-coverage.md` §Coverage Map). Retaining untested code paths in
the supported surface is a known silent-failure source; the
deprecation note + audit event in Phase A is sufficient to honour
existing callers without doubling maintenance burden.

**Why we DON'T re-introduce the Ghostty `open --na --args` command-arg
form:** issue #31 (PR #33) documented that the flag form poisons the
Ghostty process's instance default for its entire lifetime. `claude --bg`
runs in a Claude-supervised daemon and does not depend on any terminal
emulator at all.

```bash
# Phase B per-issue dispatch failure summary. Surfaces partial-batch failures
# loudly so the user knows exactly which issues didn't spawn — never silently
# drop a failure into the void.
if [[ ${#DISPATCH_FAILED[@]} -gt 0 ]]; then
  echo "warning: ${#DISPATCH_FAILED[@]} of ${#ISSUE_NUMS[@]} dispatch(es) failed:" >&2
  printf '  - %s\n' "${DISPATCH_FAILED[@]}" >&2
fi
```

### 6. Final summary (replaces notification chain — v0.22.0)

```bash
echo "dispatched ${#SPAWNED[@]} background session(s)" >&2
if [[ ${#SPAWNED[@]} -gt 0 ]]; then
  printf '  %s\n' "${SPAWNED[@]}" >&2
fi
# Step 6: backend-aware monitoring pointer (RFC 0004 §3.10).
case "${UBERDEV_RESOLVED_BACKEND:-claude-bg}" in
  claude-bg)
    echo "Monitor the dispatched agents with:  claude agents" >&2 ;;
  wezterm)
    echo "The dispatched agents are running in WezTerm panes — switch to the WezTerm window to watch them live." >&2 ;;
  background)
    echo "The dispatched agents are detached background processes. Per-issue logs + status files:" >&2
    for ISSUE_NUM in "${ISSUE_NUMS[@]}"; do
      echo "  #$ISSUE_NUM: tail -f $UBERDEV_TMPDIR/solve-bg-stdout-$ISSUE_NUM.log   (exit code in $UBERDEV_TMPDIR/solve-bg-status-$ISSUE_NUM.json)" >&2
    done ;;
esac
```

The single stderr emission replaces the cmux-notify / terminal-notifier /
osascript-display-notification chain. The retirement also closes the
latent `osascript-e-shell-var` ERROR-class finding from
`research_paths.security` §Findings #2 as a side-effect. Agent View
status changes are passive UI state visible via `claude agents` — never
workflow triggers (per `memory/feedback_merge_independent.md`).

### 7. (RETIRED v0.22.0 — tab retitle removed for #85)

Agent View displays each session's name natively from the
`--worktree solve-issue-N` flag passed to `claude --bg`. No OSC escape
sequence, no `cmux workspace-action --action rename` invocation, and no
per-terminal AppleScript retitle is required.

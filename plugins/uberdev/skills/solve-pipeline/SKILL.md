---
name: solve-pipeline
description: "Shared launcher pipeline for /uberdev:solve and /uberdev:turbo. Parses arguments, classifies tier, writes tier-appropriate prompt, dispatches a Claude agent into a fresh terminal session per issue. Invoked inline by both commands. Use when /solve or /turbo invokes this skill — never call directly."
---

# Solve Pipeline (shared body for /solve and /turbo)

This skill is invoked inline by `commands/solve.md` and `commands/turbo.md`. The caller exports `AUTO_MODE` (`0` for /solve interactive; `1` for /turbo unattended) before invocation; this skill reads `$AUTO_MODE` and `$ARGUMENTS` from the caller's shell scope.

`$ARGUMENTS` may contain **one or more issue numbers** (e.g. `42` or `5 6 7`). The skill validates every issue up front (Phase A) and then dispatches one autonomous `claude --bg` background session per issue (Phase B). Per-issue artifacts (`/tmp/solve-prompt-N.txt`, `/tmp/solve-bg-stdout-N.log`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch) are namespaced by `$ISSUE_NUM`, so concurrent spawns are collision-free. Override flags (`--trivial|--small|--full`, `--auto`) apply batch-wide. Monitor via `claude agents`.

## Constants

| Name | Value (verbatim) | Where used |
|---|---|---|
| `TERMINAL_FLAG_DEPRECATED_NOTE` | `warning: --terminal=cmux\|ghostty\|iterm\|terminal\|nohup is deprecated in v0.22.0; /solve and /turbo now dispatch claude --bg background sessions visible in claude agents. The flag is parsed without effect and will be removed in v1.0.0.` | Phase A stderr emission on first encounter; `commands/solve.md` / `commands/turbo.md` `## Deprecated Flags`. |
| `MIN_CLAUDE_VERSION` | `2.1.139` | Phase A `_uberdev_require_claude_version` hard gate. |
| `FANOUT_CONCURRENCY_SOLVE_BG_DEFAULT` | `6` | Phase A `MAX_PARALLEL_BG_AGENTS` resolution default. |
| `EFFORT_LEVEL_DEFAULT` | `max` | Phase A `EFFORT_LEVEL` resolution; rationale: `/turbo` is unattended, quality > cost. |
| `EFFORT_LEVEL_ENUM` | `low \| medium \| high \| xhigh \| max` | Phase A `uberdev_read_enum` validation; matches `claude --effort <level>` accepted values in Claude Code 2.1.139. |
| `EFFORT_SOURCE_ENUM` | `cli \| env \| config \| default` | Audit telemetry source tag set by the Phase A `--effort=<level>` parser; emitted in the `effort_resolved` audit event payload. |
| `SOLVE_AUDIT_EVENT_ENUM` | `agent_dispatched`, `deprecated_flag_used`, `solve_bg_fanout_wave_started`, `effort_resolved`, `error` | Audit-log writers; consumers grep for `deprecated_flag_used` to identify migration laggards. `agent_returned` was removed in v0.22.0 — `claude --bg` does not synchronously report agent completion; use `claude agents` for status. |

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
# --- Phase A: claude version gate (NEW v0.22.0) ---
# Hard-require Claude Code >= 2.1.139 (the `claude --bg` minimum). Older
# versions cannot dispatch background sessions and the entire /solve and /turbo
# contract is voided. Fail loudly with an actionable npm install pointer; do
# not silently degrade.
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
ISSUE_NUMS=($(echo "$ARGUMENTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | awk '!seen[$0]++'))

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
if [[ ${#ISSUE_NUMS[@]} -eq 0 ]]; then
  echo "Usage: /uberdev:solve|/uberdev:turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto]"
  exit 1
fi
# --full is an alias for medium/large (keeps current behavior)
[[ "$OVERRIDE" == "full" ]] && OVERRIDE="medium"

# AUTO_PERMISSIONS precedence (controls --permission-mode auto on the spawned agent):
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
if [[ "$AUTO_PERMISSIONS" == "1" ]]; then
  PERM_DESC="auto (Claude Code AI classifier)"
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
block by the v0.22.0 refactor: the claude-version gate at 2.1.139, the
hardcoded prompt-mode (`argv`), and the `MAX_PARALLEL_BG_AGENTS`
resolution) replace the entire former Step 3 terminal-detection cascade.
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
  ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,state,body,labels 2>"$GH_ERR") || {
    ERRORS+=("#$ISSUE_NUM: gh fetch failed: $(<"$GH_ERR")")
    rm -f "$GH_ERR"
    continue
  }
  rm -f "$GH_ERR"
  STATE=$(jq -r .state <<<"$ISSUE_JSON")
  if [[ "$STATE" != "OPEN" ]]; then
    ERRORS+=("#$ISSUE_NUM: state=$STATE (must be OPEN)")
    continue
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
_uberdev_require_claude_version "2.1.139"
# BG_PROMPT_MODE: hardcoded `argv` because claude --bg 2.1.139 has no documented
# --prompt-file or stdin-passthrough form (prior-art research). T6 implements the
# bash-array argv form (spec-reviewer finding #1). A runtime probe is deferred until
# upstream documents a passthrough flag — `claude --bg --help` is NOT introspective
# in 2.1.139 (it spawns a real session).
# TODO(upstream-claude-code-rfe): switch to file or stdin mode once a documented
# --prompt-file / stdin-passthrough form ships in Claude Code (tracking the RFE
# for safer prompt-passthrough). The file/stdin arms below remain in place as a
# pre-wired migration target; today only the argv arm is exercised at runtime.
BG_PROMPT_MODE=argv
if [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  MAX_PARALLEL_BG_AGENTS="$(uberdev_read_int_in_range fanout_concurrency.solve_bg UBERDEV_FANOUT_SOLVE_BG 1 50 6)"
else
  MAX_PARALLEL_BG_AGENTS=6
fi

# --- Phase A: hoisted from retired launcher heredoc (#85 / v0.22.0) ---
# These four variables formerly lived inside the per-issue launcher shell
# script that Step 5b previously wrote (the per-N temp-file form is now
# retired). The launcher is retired in v0.22.0; the values are
# batch-invariant, so resolve them once at Phase A entry and let the
# inline Step 5b' dispatch (Phase B) consume them.

# MODEL: single-quoted to keep zsh from glob-evaluating [1m] under NOMATCH.
MODEL='claude-opus-4-7[1m]'

# PERM_FLAG: issue bodies are remote-fetched (untrusted). Default mode gates
# every tool use. PERM_FLAG=( --permission-mode auto ) enables Claude Code's
# AI classifier — auto-approves safe ops (read, in-scope edits, tests, push
# to feature branch) and soft-denies dangerous ones (force push, rm -rf on
# pre-existing files, exfil, self-modification). Strictly safer than
# --dangerously-skip-permissions for autonomous /solve runs.
#
# Array form (not scalar): zsh's default SH_WORD_SPLIT=off would treat a
# scalar `PERM_FLAG="--permission-mode auto"` passed as unquoted `$PERM_FLAG`
# at command position as ONE argv slot, and `claude` would reject it with
# `error: unknown option '--permission-mode auto'`. Same trap caught the
# TIMEOUT_BIN block above; same fix here. `"${PERM_FLAG[@]}"` at the call
# site expands an empty array to zero slots and a populated one to its
# elements verbatim — identical behaviour in bash and zsh.
PERM_FLAG=()
[[ "$AUTO_PERMISSIONS" == "1" ]] && PERM_FLAG=( --permission-mode auto )

# EFFORT_FLAG is the threaded form of EFFORT_LEVEL (resolved by the Phase A
# --effort parser block above). Bash+zsh array, expanded as
# `"${EFFORT_FLAG[@]}"` at each dispatch arm — see PERM_FLAG above for the
# zsh-word-split rationale. Regression guard: tests/dispatch-claude-bg.test.sh
# anchors on `^EFFORT_FLAG=\( --effort `; tests/solve-pipeline-zsh.test.sh
# captures the dispatched argv under a real zsh subshell.
EFFORT_FLAG=( --effort "$EFFORT_LEVEL" )
# See `_uberdev_audit_emit` definition near the top of Phase A (anchor:
# `^_uberdev_audit_emit\(\)`); no-op when $SOLVE_AUDIT_LOG is unset.
_uberdev_audit_emit effort_resolved \
  "{\"source\":\"$EFFORT_SOURCE\",\"level\":\"$EFFORT_LEVEL\"}" || true

# Wall-clock timeout: read command_timeouts.solve from .claude/uberdev.local.md
# (env override: UBERDEV_SOLVE_TIMEOUT; default 3600s; range [60, 86400]).
# config-read.sh is already sourced by the MAX_PARALLEL_BG_AGENTS block above
# when readable, so `uberdev_read_int_in_range` is in scope here; guard with
# `command -v` so this block is independently sourceable.
if command -v uberdev_read_int_in_range >/dev/null 2>&1; then
  SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
elif [ -r "${CLAUDE_PLUGIN_ROOT:-}/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
else
  echo "warning: config-read.sh not found at ${CLAUDE_PLUGIN_ROOT:-}/lib/; uberdev.local.md timeout settings ignored" >&2
  SOLVE_TIMEOUT=3600
fi

# Wrap claude in timeout(1)/gtimeout when one is on PATH; fail-open otherwise
# (graceful degradation when required tooling is unavailable). macOS does NOT
# ship GNU timeout; `brew install coreutils` installs it as `gtimeout` (Homebrew
# `g`-prefix), so we probe both. The if/elif/else form is mandatory: zsh's
# default SH_WORD_SPLIT=off would treat a scalar `$PREFIX="timeout 3600"` at
# command position as ONE token and abort with "command not found: timeout 3600"
# under set -e. Quoting "$TIMEOUT_BIN" keeps it as a single argv[0] token.
TIMEOUT_BIN=""
if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
fi

# Runtime guard: if neither timeout(1) nor gtimeout(1) is on PATH, the
# bg dispatch below will pass empty wrap args to claude --bg, failing
# silently. Detect and abort with an actionable install pointer.
# Regression guard: tests/config-override.test.sh I2f anchors on this
# `if [[ -n "$TIMEOUT_BIN" ]]; then` pattern; do not collapse to `[[ … ]] ||`.
if [[ -n "$TIMEOUT_BIN" ]]; then
  : # timeout(1) or gtimeout(1) available; bg dispatch arms wrap correctly
else
  echo "error: neither timeout(1) nor gtimeout(1) found on PATH" >&2
  echo "       install with: brew install coreutils  # provides gtimeout" >&2
  exit 1
fi
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

The trivial/small heredocs no longer run the pre-push reviewer fanout — both AUTO_MODE branches push directly and chain into `/uberdev:review-pr`, whose Phase 1 now hosts the 5-reviewer fanout. The medium prompt branches on `AUTO_MODE=1` to inject `--turbo` into the orchestrator dispatch.

The `if/else/fi` blocks below stay at column 0 (zsh and bash do not require physical indentation inside `for ... done`); `tests/turbo-flow.test.sh` anchors its differential-guard awk on `^if \[\[ "\$AUTO_MODE" == "1" \]\]; then$` and must keep matching unchanged. Do not indent these blocks when the loop wraps them.

**trivial:**

```bash
if [[ "$AUTO_MODE" != "1" ]]; then
# trivial heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your working context. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues whose research was persisted under the previous fanout.
3. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
4. Add/update a test ONLY if the touched code is already tested.
5. Run the relevant test file + lint for that package.
6. Commit with conventional message. Open PR with \`Closes #$ISSUE_NUM\` in the body.
7. **Capture the PR URL from \`gh pr create\` output and invoke the \`uberdev:review-pr\` skill via the Skill tool with that URL.** This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
else
# trivial heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
3. Add/update a test ONLY if the touched code is already tested.
4. Run the relevant test file + lint for that package.
5. Commit with conventional message. Open PR with \`Closes #$ISSUE_NUM\` in the body.
6. **Capture the PR URL from \`gh pr create\` output and invoke the \`uberdev:review-pr --turbo\` skill via the Skill tool with that URL.** This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
fi
```

**small:**

```bash
if [[ "$AUTO_MODE" != "1" ]]; then
# small heredoc — interactive (/solve): pre-collected-research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research (legacy cache)** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your TodoWrite plan as constraints/considerations. After issue #14 the cache is no longer written by \`/issue\`, so this step typically no-ops; left in place for legacy issues.
3. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
4. TDD: write the failing test first, then implement, then green.
5. Commit + PR with \`Closes #$ISSUE_NUM\`.
6. **Capture the PR URL from \`gh pr create\` output and invoke the \`uberdev:review-pr\` skill via the Skill tool with that URL.** This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory — do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
else
# small heredoc — turbo (/turbo): no research read; post-push reviewer fanout runs in /uberdev:review-pr Phase 1
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
3. TDD: write the failing test first, then implement, then green.
4. Commit + PR with \`Closes #$ISSUE_NUM\`.
5. **Capture the PR URL from \`gh pr create\` output and invoke the \`uberdev:review-pr --turbo\` skill via the Skill tool with that URL.** This is the canonical run site for the 3-lens simplify ceremony (Phase 2: reuse / quality / efficiency); it does NOT fire if you skip this step. Findings are advisory.

Do NOT run /uberdev:simplify standalone before push — Phase 2 of /uberdev:review-pr runs it automatically on a strictly larger diff (full PR + review-fix commits).

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
fi
```

**medium** *(and `--full`)*:

```bash
if [[ "$AUTO_MODE" == "1" ]]; then
echo "/uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM" > /tmp/solve-prompt-$ISSUE_NUM.txt
else
echo "/uberdev:orchestrator solve GH issue #$ISSUE_NUM" > /tmp/solve-prompt-$ISSUE_NUM.txt
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
and `TIMEOUT_BIN` have been hoisted from the launcher into Phase A
(immediately after the bg-dispatch probes block) — see the Phase A region.

#### 5b'. Dispatch via `claude --bg` (NEW v0.22.0)

SAFE prompt-passthrough forms — Q1 decision per `docs/uberdev/specs/2026-05-12-replace-cmux-with-bg-agent-view-design.md`:
- **`--prompt-file <path>`** → trusted path arg; file contents never reach the shell.
- **stdin pipe** → file content streamed on FD 0; no argv quoting concern.
- **positional argv via bash array** → backwards-compatible last resort; the prompt body lands in a single array slot, never re-evaluated through the shell.

**UNSAFE — DO NOT USE:**
- Direct interpolation of `$PROMPT` as a single double-quoted argv slot (e.g. invoking the bg dispatcher with `"$PROMPT"` as the trailing arg) → backticks / `$(…)` in issue body shell-evaluate.
- Re-evaluation forms (any `eval`-driven dispatch using `printf %q` to quote the prompt body) → re-evaluation of attacker-influenced text; security research §Findings classified this ERROR-class.
- `bash -c` wrapper with `$PROMPT` interpolated inside the inner double-quoted command string → double-quote-inside-double-quote interpolation hazard.

`MODEL`, `PERM_FLAG`, `SOLVE_TIMEOUT`, and `TIMEOUT_BIN` are resolved in Phase A (immediately after the bg-dispatch probes block). They're batch-invariant — resolved once per `/solve` or `/turbo` invocation, then consumed by the wave-batching dispatch below.

The per-issue dispatch is wrapped in a wave-batching outer loop. Mirrors `merge-pipeline/SKILL.md:421`'s idiom: `ceil(N / cap)` sequential single-message waves, one `solve_bg_fanout_wave_started` audit event per wave.

```bash
# --- Phase B: wave-batching outer loop (NEW v0.22.0) ---
# The inner loop body stays at column 0 (bash and zsh do not require physical
# indentation inside `for ((…)); do … done`); the verifier in tests/turbo-flow.test.sh
# anchors on `^case "\$BG_PROMPT_MODE" in$` and tests/dispatch-claude-bg.test.sh
# regex-matches the inner-body invariants.
TOTAL_ISSUES="${#ISSUE_NUMS[@]}"
WAVE_COUNT=$(( (TOTAL_ISSUES + MAX_PARALLEL_BG_AGENTS - 1) / MAX_PARALLEL_BG_AGENTS ))
for (( wave_index = 1; wave_index <= WAVE_COUNT; wave_index++ )); do
wave_start=$(( (wave_index - 1) * MAX_PARALLEL_BG_AGENTS ))
wave_end=$(( wave_start + MAX_PARALLEL_BG_AGENTS - 1 ))
(( wave_end >= TOTAL_ISSUES )) && wave_end=$(( TOTAL_ISSUES - 1 ))
wave_size=$(( wave_end - wave_start + 1 ))
_uberdev_audit_emit solve_bg_fanout_wave_started \
  "{\"wave_index\":$wave_index,\"wave_size\":$wave_size}"
for (( i = wave_start; i <= wave_end; i++ )); do
ISSUE_NUM="${ISSUE_NUMS[$i]}"
TIER="${TIERS[$ISSUE_NUM]}"
TITLE="${TITLES[$ISSUE_NUM]}"
BG_DISPATCH_RC=0
BG_SESSION_ID=""
BG_STDOUT_LOG="/tmp/solve-bg-stdout-$ISSUE_NUM.log"
case "$BG_PROMPT_MODE" in
  file)
    # Trusted path arg; file contents never reach the shell as argv.
    # PERM_FLAG / EFFORT_FLAG are bash+zsh arrays — see Phase A hoist for the
    # zsh SH_WORD_SPLIT=off rationale; `"${ARRAY[@]}"` expands identically in
    # both shells (empty array → zero slots; populated → one slot per element).
    "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" claude --bg \
      --prompt-file "/tmp/solve-prompt-$ISSUE_NUM.txt" \
      --worktree "solve-issue-$ISSUE_NUM" \
      --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" > "$BG_STDOUT_LOG" 2>&1
    BG_DISPATCH_RC=$?
    ;;
  stdin)
    # File content streamed on FD 0; no argv quoting concern.
    "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" claude --bg \
      --worktree "solve-issue-$ISSUE_NUM" \
      --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" \
      < "/tmp/solve-prompt-$ISSUE_NUM.txt" > "$BG_STDOUT_LOG" 2>&1
    BG_DISPATCH_RC=$?
    ;;
  argv)
    # Bash array form (spec-reviewer finding 1) — single argv slot, no eval.
    PROMPT_BODY="$(cat "/tmp/solve-prompt-$ISSUE_NUM.txt")"
    cmd=( "$TIMEOUT_BIN" "$SOLVE_TIMEOUT" claude --bg
          --worktree "solve-issue-$ISSUE_NUM"
          --model "$MODEL" )
    # PERM_FLAG / EFFORT_FLAG are arrays from Phase A
    # (PERM_FLAG=() or ( --permission-mode auto ); EFFORT_FLAG=( --effort <level> )).
    # `"${ARRAY[@]}"` preserves each element as its own argv slot in both bash
    # AND zsh — no reliance on SH_WORD_SPLIT, which is OFF by default in zsh
    # and would otherwise collapse a scalar `--effort max` into one argv slot
    # that `claude` rejects with `error: unknown option '--effort max'`.
    cmd+=( "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}" -- "$PROMPT_BODY" )
    "${cmd[@]}" > "$BG_STDOUT_LOG" 2>&1
    BG_DISPATCH_RC=$?
    ;;
  *)
    # Defensive default arm: BG_PROMPT_MODE is hardcoded `argv` in Phase A
    # today, so this is unreachable in normal control flow. If a future
    # patch parameterises it (e.g. wires the upstream Claude Code
    # --prompt-file RFE) and a typo or stale config slips through without
    # enum validation, fall through here with rc=127 instead of silently
    # no-op'ing through the case-switch and reporting `BG_DISPATCH_RC=0`
    # for a dispatch that never happened — silent-failure-hunter finding B2.
    echo "error: BG_PROMPT_MODE='$BG_PROMPT_MODE' is not one of {file, stdin, argv}" > "$BG_STDOUT_LOG"
    BG_DISPATCH_RC=127
    ;;
esac

if [[ "$BG_DISPATCH_RC" -eq 0 ]]; then
  BG_SESSION_ID="$(grep -oE 'backgrounded · [0-9a-f]{8}' "$BG_STDOUT_LOG" | awk '{print $NF}' | head -1)"
  SPAWNED+=("#$ISSUE_NUM ($TIER, bg ${BG_SESSION_ID:-?})")
  _uberdev_audit_emit agent_dispatched \
    "{\"issue\":$ISSUE_NUM,\"tier\":\"$TIER\",\"bg_session_id\":\"${BG_SESSION_ID:-}\",\"mode\":\"$BG_PROMPT_MODE\"}" || true
else
  # Capture the last three log lines; if the log is empty (claude --bg
  # crashed before writing anything to its FD 1/2, e.g. exec-failure on
  # macOS where gtimeout exits before flushing), the user gets a pointer
  # to the log path instead of an empty failure entry that reads like a
  # silent success — silent-failure-hunter finding B3.
  TAIL_OUTPUT="$(tail -3 "$BG_STDOUT_LOG" | tr '\n' ' ')"
  DISPATCH_FAILED+=("#$ISSUE_NUM: ${TAIL_OUTPUT:-(no output captured; check /tmp/solve-bg-stdout-$ISSUE_NUM.log)}")
  _uberdev_audit_emit error \
    "{\"issue\":$ISSUE_NUM,\"phase\":\"dispatch\",\"rc\":$BG_DISPATCH_RC}" || true
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
echo "dispatched ${#SPAWNED[@]} background session(s) — run \`claude agents\` to monitor" >&2
if [[ ${#SPAWNED[@]} -gt 0 ]]; then
  printf '  %s\n' "${SPAWNED[@]}" >&2
fi
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

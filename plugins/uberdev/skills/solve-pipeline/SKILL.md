---
name: solve-pipeline
description: "Shared launcher pipeline for /uberdev:solve and /uberdev:turbo. Parses arguments, classifies tier, writes tier-appropriate prompt, dispatches a Claude agent into a fresh terminal session per issue. Invoked inline by both commands. Use when /solve or /turbo invokes this skill — never call directly."
---

# Solve Pipeline (shared body for /solve and /turbo)

This skill is invoked inline by `commands/solve.md` and `commands/turbo.md`. The caller exports `AUTO_MODE` (`0` for /solve interactive; `1` for /turbo unattended) before invocation; this skill reads `$AUTO_MODE` and `$ARGUMENTS` from the caller's shell scope.

`$ARGUMENTS` may contain **one or more issue numbers** (e.g. `42` or `5 6 7`). The skill validates every issue up front (Phase A) and then dispatches one autonomous agent per issue into its own terminal session (Phase B). Per-issue artifacts (`/tmp/solve-prompt-N.txt`, `/tmp/solve-N.sh`, `.claude/worktrees/solve-issue-N/`, `worktree-solve-issue-N` branch, `#N <title>` tab) are namespaced by `$ISSUE_NUM`, so concurrent spawns are collision-free. Override flags (`--trivial|--small|--full`, `--auto`, `--terminal=...`) apply batch-wide.

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
TERMINAL_OVERRIDE=$(echo "$ARGUMENTS" | grep -oE '\-\-terminal=[a-z]+' | head -1 | sed 's/--terminal=//')
AUTO_FLAG=$(echo "$ARGUMENTS" | grep -oE '\-\-auto' | head -1)
if [[ ${#ISSUE_NUMS[@]} -eq 0 ]]; then
  echo "Usage: /uberdev:solve|/uberdev:turbo <issue-number> [<issue-number>...] [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
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
```

`$OVERRIDE`, `$TERMINAL_OVERRIDE`, `$AUTO_FLAG`, and `$AUTO_PERMISSIONS` apply **batch-wide**. There is no per-issue override syntax — run separate `/turbo` invocations if you need different flags per issue.

### 2. Detect repo

```bash
gh repo view --json nameWithOwner --jq .nameWithOwner
```

### 3. Detect terminal app

Pick a dispatcher once, before any spawn. Priority: explicit override > cmux (only when we're inside a live cmux session) > standalone Ghostty > iTerm2 > Terminal.app > nohup-fallback. **Warp falls through to nohup** — its CLI can't dispatch a command into a new window cleanly.

`TERM_PROGRAM=ghostty` is also set when you're inside cmux (cmux bundles Ghostty), so the cmux check MUST come first and MUST require `$CMUX_SOCKET` to be a live socket — otherwise we'd mis-classify a cmux session as plain Ghostty.

```bash
if [[ -n "$TERMINAL_OVERRIDE" ]]; then
  TERMINAL="$TERMINAL_OVERRIDE"
elif [[ -n "$SOLVE_TERMINAL" ]]; then
  TERMINAL="$SOLVE_TERMINAL"
elif [[ -n "$CMUX_SOCKET" && -S "$CMUX_SOCKET" ]] && command -v cmux >/dev/null 2>&1; then
  TERMINAL="cmux"
elif [[ "$TERM_PROGRAM" == "ghostty" ]] && [[ -d /Applications/Ghostty.app ]]; then
  TERMINAL="ghostty"
elif [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
  TERMINAL="iterm"
elif [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then
  TERMINAL="terminal"
else
  TERMINAL="nohup"
fi

# Validate the chosen dispatcher is actually usable. If a user *explicitly* asked
# for cmux/ghostty/iterm via --terminal= or $SOLVE_TERMINAL but the dispatcher
# isn't installed, surface an actionable message and fall back to nohup so the
# agent still spawns instead of failing inside the dispatch case below.
case "$TERMINAL" in
  cmux)
    if ! command -v cmux >/dev/null 2>&1; then
      echo "warning: TERMINAL=cmux requested but 'cmux' binary not on PATH." >&2
      echo "         Install: npm i -g @manaflow-ai/cmux  (see cmux README for canonical install)" >&2
      echo "         Falling back to nohup." >&2
      TERMINAL="nohup"
    elif [[ -z "$CMUX_SOCKET" || ! -S "$CMUX_SOCKET" ]]; then
      echo "warning: TERMINAL=cmux requested but \$CMUX_SOCKET is not a live socket." >&2
      echo "         Run /solve or /turbo from inside an active cmux session, or unset SOLVE_TERMINAL/--terminal." >&2
      echo "         Falling back to nohup." >&2
      TERMINAL="nohup"
    fi
    ;;
  ghostty)
    [[ -d /Applications/Ghostty.app ]] || { echo "warning: ghostty selected but /Applications/Ghostty.app missing; falling back to nohup." >&2; TERMINAL="nohup"; }
    ;;
  iterm)
    [[ -d /Applications/iTerm.app ]] || { echo "warning: iterm selected but /Applications/iTerm.app missing; falling back to nohup." >&2; TERMINAL="nohup"; }
    ;;
  terminal|nohup) ;;  # always available on macOS
  *) echo "warning: unknown TERMINAL='$TERMINAL'; falling back to nohup." >&2; TERMINAL="nohup" ;;
esac

echo "Dispatching via: $TERMINAL"
echo "Permission mode: $([[ "$AUTO_PERMISSIONS" == "1" ]] && echo 'auto (Claude Code AI classifier)' || echo 'default (manual per-tool gating)')"

# Resolve the real Claude binary once (PATH walk skipping wrapper directory).
# Hoisted out of the per-issue loop — same value for every spawn.
REAL_CLAUDE=$(WRAPPER_DIR=$(dirname "$(which claude)"); for d in ${(s/:/)PATH}; do [[ "$d" == "$WRAPPER_DIR" ]] && continue; [[ -x "$d/claude" ]] && echo "$d/claude" && break; done)
REAL_CLAUDE="${REAL_CLAUDE:-$(which claude)}"
```

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
```

### 5. Per-issue dispatch (Phase B — spawn one agent per issue)

For each validated issue, write its prompt heredoc, write its launcher script, and spawn it into the chosen terminal. Each spawn is an independent OS process / cmux workspace; together they run in parallel. The for-loop opens at the top of this code block and closes after the dispatch case in Step 5c (`done`); sub-steps 5a/5b/5c are documentation breakdowns of the loop body — their bash blocks all execute inside the same loop iteration. Per-issue dispatch outcomes are tracked in `SPAWNED` (success) and `DISPATCH_FAILED` (failure) so the user sees exactly which issues spawned and which didn't — no silent partial-batch failures.

```bash
SPAWNED=()
DISPATCH_FAILED=()
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
```

#### 5b. Write launcher script

The launcher `cd`s to repo root, cleans stale worktree, logs errors, keeps terminal open on failure. `REAL_CLAUDE` was resolved once in Step 3 (same value across every spawn).

**Wall-clock timeout.** The launcher reads
`command_timeouts.solve` from `.claude/uberdev.local.md` (env override:
`UBERDEV_SOLVE_TIMEOUT`; default 3600s; range [60, 86400]) and wraps the
`claude` invocation in `timeout(1)` when the binary is on PATH. If
`timeout(1)` is unavailable (rare on bare macOS without coreutils) the
launcher emits one stderr warning and runs unwrapped — fail-open per
the `aliases-sync.sh:14-23` jq-absent precedent. `/merge` and
`/review-pr` parse `command_timeouts.{merge, review_pr}` but only
surface the values in the run audit log; v1 does NOT enforce wall-clock
kill on those commands (the orchestrator turn loop runs inside an
existing Claude session and would need deeper changes to honour a
kill). v2 issue can extend.

```bash
cat > /tmp/solve-$ISSUE_NUM.sh << 'SCRIPT_EOF'
#!/bin/zsh -l
set -e

# Inherit detected terminal so Step 7 retitling can use the right mechanism.
export TERMINAL="DETECTED_TERMINAL"

# cd to repo root (cmux may start in a different directory)
# Path is quoted because repo paths may contain spaces (e.g. /Users/me/My Project/...)
cd "REPO_ROOT"

# Clean up stale worktree AND branch from previous runs
if git worktree list | grep -q "solve-issue-ISSUE_NUM"; then
  git worktree remove .claude/worktrees/solve-issue-ISSUE_NUM --force 2>/dev/null || true
fi
git branch -D worktree-solve-issue-ISSUE_NUM 2>/dev/null || true

# Load prompt
PROMPT=$(cat /tmp/solve-prompt-ISSUE_NUM.txt)

# Run agent
echo "Starting claude agent for issue #ISSUE_NUM (tier: TIER)..."
# Interactive TUI mode: positional arg (no -p) so user sees the Claude CLI
# MODEL: pinned to Opus 4.7 with 1M context. Brackets MUST be single-quoted
# (zsh would otherwise treat [1m] as a character-class glob and abort under set -e).
# PERMISSION MODE: issue bodies are remote-fetched (untrusted). Default mode
# gates every tool use. PERM_FLAG=--permission-mode auto enables Claude Code's
# AI classifier — auto-approves safe ops (read, in-scope edits, tests, push to
# feature branch) and soft-denies dangerous ones (force push, rm -rf on
# pre-existing files, exfil, self-modification). Strictly safer than
# --dangerously-skip-permissions for autonomous /solve runs.
PERM_FLAG="PERM_FLAG_VALUE"
# Wall-clock timeout: helper path is sed-substituted at heredoc-write time below
# because the launcher runs in a fresh terminal session that does not inherit
# $CLAUDE_PLUGIN_ROOT (mirrors the REPO_ROOT / CLAUDE_BIN substitution pattern).
if [ -r "CLAUDE_PLUGIN_ROOT_VAL/lib/config-read.sh" ]; then
  # shellcheck source=/dev/null
  . "CLAUDE_PLUGIN_ROOT_VAL/lib/config-read.sh"
  SOLVE_TIMEOUT="$(uberdev_read_int_in_range command_timeouts.solve UBERDEV_SOLVE_TIMEOUT 60 86400 3600)"
else
  echo "warning: config-read.sh not found at CLAUDE_PLUGIN_ROOT_VAL/lib/; uberdev.local.md timeout settings ignored" >&2
  SOLVE_TIMEOUT=3600
fi

# Wrap claude in timeout(1) when the binary is on PATH; fail-open otherwise
# (graceful degradation when required tooling is unavailable). The if/else form
# is mandatory: zsh's default SH_WORD_SPLIT=off would treat a scalar
# `$PREFIX="timeout 3600"` at command position as ONE token and abort with
# "command not found: timeout 3600" under set -e.
if command -v timeout >/dev/null 2>&1; then
  timeout "${SOLVE_TIMEOUT}" CLAUDE_BIN --model 'claude-opus-4-7[1m]' --effort max --worktree solve-issue-ISSUE_NUM $PERM_FLAG "$PROMPT"
else
  echo "warning: timeout(1) not on PATH; /solve will run unwrapped (no wall-clock kill)" >&2
  CLAUDE_BIN --model 'claude-opus-4-7[1m]' --effort max --worktree solve-issue-ISSUE_NUM $PERM_FLAG "$PROMPT"
fi
SCRIPT_EOF
# BSD/macOS sed needs '-i ""'; GNU sed needs bare '-i'.
SED_INPLACE=(-i '')
[[ "$(uname)" == "Linux" ]] && SED_INPLACE=(-i)
PERM_FLAG_VAL=""
[[ "$AUTO_PERMISSIONS" == "1" ]] && PERM_FLAG_VAL="--permission-mode auto"
# All placeholders are unique tokens with no cross-substitution risk; collapse
# six sed invocations (six forks per spawn × N issues) into one. Per-expression
# delimiter choice (`|` for path-bearing values, `/` for enums) is preserved.
sed "${SED_INPLACE[@]}" \
  -e "s|REPO_ROOT|$(pwd)|g" \
  -e "s|CLAUDE_BIN|$REAL_CLAUDE|g" \
  -e "s/ISSUE_NUM/$ISSUE_NUM/g" \
  -e "s/TIER/$TIER/g" \
  -e "s/DETECTED_TERMINAL/${TERMINAL:-cmux}/g" \
  -e "s|PERM_FLAG_VALUE|$PERM_FLAG_VAL|g" \
  -e "s|CLAUDE_PLUGIN_ROOT_VAL|${CLAUDE_PLUGIN_ROOT:-}|g" \
  /tmp/solve-$ISSUE_NUM.sh
chmod +x /tmp/solve-$ISSUE_NUM.sh
```

#### 5c. Spawn agent in new terminal session

Tab/window shows issue + title; description encodes the tier for audit. Each branch invokes `zsh -l /tmp/solve-$ISSUE_NUM.sh`. Use the literal title from Phase A (already truncated). The for-loop closes here (`done`).

```bash
TAB_NAME="#$ISSUE_NUM $TITLE"
DESCRIPTION="[$TIER] Solve GH issue #$ISSUE_NUM: $TITLE"
SCRIPT="/tmp/solve-$ISSUE_NUM.sh"

case "$TERMINAL" in
  cmux)
    cmux new-workspace --name "$TAB_NAME" --description "$DESCRIPTION" --command "zsh -l $SCRIPT"
    ;;
  ghostty)
    # Drive Ghostty via AppleScript keystrokes (Cmd+T for tab, Cmd+N for window)
    # and type the launcher path into the new tab/window. Keystroke dispatch
    # types into a shell that's already started — it never sets any instance
    # default, so future tabs/windows the user opens manually stay clean.
    #
    # Why we DON'T use `open -na Ghostty --args --command="$SCRIPT"`: Ghostty
    # treats `--command=` passed via `open --args` as the running instance's
    # default command. Once set, every Cmd+T / Cmd+N the user opens manually
    # re-runs the launcher, racing the original agent and "poisoning" the
    # Ghostty process for its lifetime (issue #31). There is no Ghostty CLI
    # form that reliably runs a command once without sticking it as the default.
    #
    # Tab vs window:
    #   - Cmd+T (tab) when /solve was invoked from inside Ghostty
    #     (TERM_PROGRAM=ghostty) and SOLVE_GHOSTTY_NEW_WINDOW != "1": we have
    #     an originating window to tab into.
    #   - Cmd+N (window) when SOLVE_GHOSTTY_NEW_WINDOW=1 (explicit opt-out) or
    #     TERM_PROGRAM != ghostty (e.g. SOLVE_TERMINAL=ghostty from iTerm —
    #     no originating window to tab into).
    if [[ "$SOLVE_GHOSTTY_NEW_WINDOW" == "1" ]] || [[ "$TERM_PROGRAM" != "ghostty" ]]; then
      GHOSTTY_SPAWN_KEY="n"   # Cmd+N → new window
      GHOSTTY_LAUNCH_DELAY="0.5"  # cold-launch may need longer if Ghostty isn't running
    else
      GHOSTTY_SPAWN_KEY="t"   # Cmd+T → new tab in the originating window
      GHOSTTY_LAUNCH_DELAY="0.15"
    fi

    if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Ghostty" to activate
delay $GHOSTTY_LAUNCH_DELAY
tell application "System Events"
  keystroke "$GHOSTTY_SPAWN_KEY" using command down
  delay 0.25
  keystroke "zsh -l $SCRIPT"
  keystroke return
end tell
APPLESCRIPT
    then
      echo "Dispatched into Ghostty (Cmd+$GHOSTTY_SPAWN_KEY)."
    else
      # AppleScript path failed (Accessibility permission denied or non-default
      # Cmd+T/Cmd+N keybind). Fall back to a detached nohup run — nohup runs the
      # launcher in a background shell of the current process, never passing any
      # flag to the Ghostty app itself, so it can't reintroduce the issue #31
      # instance-default poison the way `open -na Ghostty --args --command=...`
      # would.
      GHOSTTY_LOG="/tmp/solve-$ISSUE_NUM.log"
      nohup zsh -l "$SCRIPT" > "$GHOSTTY_LOG" 2>&1 &
      echo "warning: ghostty AppleScript dispatch failed (Accessibility permission or non-default Cmd+T/N keybind?); spawned detached agent (PID $!). Logs: $GHOSTTY_LOG" >&2
    fi
    ;;
  iterm)
    osascript <<APPLESCRIPT
tell application "iTerm"
  activate
  create window with default profile command "zsh -l $SCRIPT"
end tell
APPLESCRIPT
    ;;
  terminal)
    osascript <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "zsh -l $SCRIPT"
end tell
APPLESCRIPT
    ;;
  nohup|*)
    LOG="/tmp/solve-$ISSUE_NUM.log"
    nohup zsh -l "$SCRIPT" > "$LOG" 2>&1 &
    echo "Spawned detached (PID $!). Logs: $LOG"
    ;;
esac

# Track per-issue dispatch outcome. `$?` after the case is the exit status of
# the last command in the matched branch; the Ghostty branch ends in an `echo`
# (success) on either AppleScript-success or AppleScript-fail-then-nohup
# fallback paths, so both record as success — the agent IS spawned either way,
# just via a different mechanism. cmux/iTerm/Terminal record their actual
# dispatch return code so a dead cmux socket or AppleScript permission denial
# surfaces in the failure list instead of silently dropping the issue.
DISPATCH_RC=$?
if [[ $DISPATCH_RC -eq 0 ]]; then
  SPAWNED+=("#$ISSUE_NUM ($TIER)")
else
  DISPATCH_FAILED+=("#$ISSUE_NUM ($TERMINAL exit=$DISPATCH_RC)")
fi

# Ghostty keystroke dispatch is asynchronous; firing Cmd+T three times in
# <100 ms can race all three keystrokes into the first-created tab. Pause
# between Ghostty spawns gives the new tab time to materialize before the
# next keystroke fires. cmux uses an IPC API; iTerm/Terminal use scripted
# `create window`/`do script` (the Apple Event queue serializes
# same-application AppleScript calls in practice); nohup needs nothing.
# Only Ghostty needs the pause, and only when batch size > 1.
if [[ "$TERMINAL" == "ghostty" && ${#ISSUE_NUMS[@]} -gt 1 ]]; then
  sleep 0.6
fi
done

# Phase B per-issue dispatch failure summary. Surfaces partial-batch failures
# loudly so the user knows exactly which issues didn't spawn — never silently
# drop a failure into the void.
if [[ ${#DISPATCH_FAILED[@]} -gt 0 ]]; then
  echo "warning: ${#DISPATCH_FAILED[@]} of ${#ISSUE_NUMS[@]} dispatch(es) failed:" >&2
  printf '  - %s\n' "${DISPATCH_FAILED[@]}" >&2
fi
```

### 6. Brief delay and confirm — single summary notification

cmux's native notifier is preferred (matches existing UX); otherwise fall through to `terminal-notifier` then `osascript display notification`. **One summary notification per `/turbo` invocation** — N back-to-back notifications would be noisy. The body lists every successfully spawned issue and (if any) the count of dispatch failures.

```bash
sleep 1
NOTIFY_BODY="Spawned ${#SPAWNED[@]} agent$([[ ${#SPAWNED[@]} -ne 1 ]] && echo s): $(IFS=', '; echo "${SPAWNED[*]}") (terminal: $TERMINAL$([[ "$AUTO_PERMISSIONS" == "1" ]] && echo ', auto')$([[ "$AUTO_MODE" == "1" ]] && echo ', turbo'))$([[ ${#DISPATCH_FAILED[@]} -gt 0 ]] && echo " — ${#DISPATCH_FAILED[@]} dispatch failure(s), see stderr")"
if [[ "$TERMINAL" == "cmux" ]] && command -v cmux >/dev/null 2>&1; then
  cmux notify --title "Orchestrator" --body "$NOTIFY_BODY"
elif command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "Orchestrator" -message "$NOTIFY_BODY"
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$NOTIFY_BODY\" with title \"Orchestrator\""
fi
```

### 7. Post-action — rename tab to PR number once opened (optional)

After opening its PR, each spawned agent renames its own tab from `#<issue> <title>` to `PR #<pr> <title>`. cmux uses its workspace API; everything else uses OSC escape sequences (Ghostty, iTerm2, Terminal.app all honor `OSC 1` for tab title and `OSC 2` for window title). Apply the same ~40-char truncation rule if `$PR_TITLE` is long.

The spawned agent inherits `$TERMINAL` from its launcher (exported in Step 5b — adjust the launcher heredoc to write `export TERMINAL='$TERMINAL'` near the top if you want this to work cleanly; otherwise the agent re-detects via the same logic above).

```bash
# Inside the spawned agent, after gh pr create returns the PR number:
PR_NUM=$(gh pr view --json number --jq .number)
PR_TITLE=$(gh pr view --json title --jq .title)
NEW_TITLE="PR #$PR_NUM $PR_TITLE"

case "${TERMINAL:-cmux}" in
  cmux)
    cmux workspace-action --action rename --title "$NEW_TITLE"
    ;;
  ghostty|iterm|terminal)
    # OSC 2 = window title; OSC 1 = tab/icon title. Both honored by Ghostty/iTerm2/Terminal.app.
    printf '\e]2;%s\a' "$NEW_TITLE"
    printf '\e]1;PR #%s\a' "$PR_NUM"
    ;;
  *) ;;  # nohup: no controlling terminal to retitle
esac
```

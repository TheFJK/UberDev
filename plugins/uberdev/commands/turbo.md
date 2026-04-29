---
description: "Unattended /solve — auto-accepts brainstorm recommendations for medium/large issues. Same pipeline, no Q&A friction."
argument-hint: "<issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
allowed-tools: ["Bash", "Read", "Task"]
---

<!--
DUPLICATION NOTE — KEEP IN SYNC WITH commands/solve.md.

The bulk of this file (Steps 1-8 — argument parsing, repo detection, issue
fetch/classify, launcher-script template, terminal detection, spawn dispatch,
notify, post-action retitle) is byte-identical to commands/solve.md by design.
Claude Code commands do not support file partials / textual @-include — the
`@${CLAUDE_PLUGIN_ROOT}/...` syntax attaches files as context for Claude to
read, not as in-place text substitution — so we keep two parallel files
instead of an extracted shared partial.

Editing rules:
- Any change to the shared procedural body (Steps 1-8 plumbing) MUST be
  mirrored into the equivalent section of solve.md before the edit lands.
- Diff after editing: `diff -u plugins/uberdev/commands/{solve,turbo}.md`
  should surface only the intentional deltas marked with `DELTA from /solve`
  comments below.
- Intentional deltas are flagged inline with `<!-- DELTA from /solve: ... -->`
  comments. Do NOT remove these markers without first removing the divergence
  itself.
- Inline `<!-- DELTA -->` markers are the source of truth; the list below is
  an index for navigation only — when the index drifts from the inline
  markers, the inline markers win.

Known intentional deltas — index by section anchor (top-of-file → bottom-of-file):
  - DELTA in the page header / opening paragraph (unattended vs interactive framing).
  - DELTA in the Usage example (`/turbo` vs `/solve` invocation).
  - DELTA in the `--auto` flag note (this file's note has the extra "max-autonomy
    combo" sentence).
  - DELTA in the `Behavior vs /solve` callout (turbo-only block; absent from solve.md).
  - DELTA in the Triage table's "Spawned workflow" column (turbo's trivial/small
    are SHORTER than solve.md's — turbo omits the `Read pre-collected research`
    and `uberdev:post-impl-review` steps; see the inline triage-table DELTA
    marker for the historical divergence we have NOT yet harmonized).
  - DELTA in the `Non-blocking Q&A (medium/large under --turbo)` paragraph
    after the triage table (turbo-only block).
  - DELTA in Step 4's trivial bash heredoc (turbo's heredoc omits the
    pre-collected-research + post-impl-review steps solve.md includes —
    see inline marker).
  - DELTA in Step 4's small bash heredoc (same divergence as the trivial
    heredoc — see inline marker).
  - DELTA in Step 4's medium-tier orchestrator prompt (`--turbo solve` here
    vs bare `solve` in solve.md).
  - DELTA in Step 5.5's turbo-mode banner stderr emit (turbo-only block).
  - DELTA in Step 6's ghostty comment (`/turbo` vs `/solve` in the invoker
    reference text).
  - DELTA in Step 7's notify body (turbo appends `, turbo`).

If you find yourself editing the shared body in only one file: STOP and
mirror to the other before committing.
-->

# Solve GitHub Issue (Unattended)

Spawn an autonomous Claude agent in a new cmux workspace to solve GitHub issue **#$ARGUMENTS** with **brainstorm Q&A auto-answered**.

`/turbo` is `/solve` with the brainstorm clarifying-question loop collapsed: after parallel research synthesis, the lead agent presents 2-3 approaches with its recommendation, and **proceeds with the recommendation** — no waiting for user input. Spec and plan are still written to disk before implementation, so you can audit the artifacts and course-correct.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/turbo <issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]`

- No flag → **auto-triage** by reading the issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually
- `--terminal=…` → override terminal detection (else `$SOLVE_TERMINAL` env var, else auto-detect)
- `--auto` → enable `--permission-mode auto` (Claude Code's AI classifier — auto-approves safe ops; blocks force push / `rm -rf` on pre-existing files / exfil / self-modification / `--dangerously-skip-permissions`). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`. Orthogonal to `/turbo`'s brainstorm-interactivity flag — **`/turbo <issue> --auto` is the max-autonomy combo**.
- `SOLVE_GHOSTTY_NEW_WINDOW=1` env var → force the legacy *new window* dispatch instead of tab-spawning into the originating Ghostty window (Ghostty terminal only).

<!-- DELTA from /solve: this `Behavior vs /solve` callout is turbo-only; it
explains the brainstorm-loop collapse and post-impl review wiring for users
arriving from /solve. -->

**Behavior vs `/solve`:**
- **trivial / small tiers:** identical to `/solve` (these tiers don't run brainstorm anyway).
- **medium / large tiers:** brainstorm runs WITHOUT the clarifying-question loop. Parallel research still runs (recommendation grounding preserved). Spec → plan → implementation waves proceed in a single forward pass. After implementation, `subagent-driven-dev` invokes `uberdev:post-impl-review` (5-agent advisory fanout) per wave; large tier additionally fires `pr-test-analyzer` pre-merge. Findings are summarised in the PR body under `## Reviewer findings summary`.

## Triage heuristics (Step 3 applies this table)

<!-- DELTA from /solve (Triage table workflow column): this table's trivial/small
workflow column is SHORTER than solve.md's. solve.md mentions `Read pre-collected
research` and `uberdev:post-impl-review` skill in those tiers; turbo's table
here (and the matching bash heredocs in Step 4 below) does NOT. The
harmonization (either add post-impl-review to turbo's trivial/small, or remove
from solve's) is out of scope for the dedup pass — flagged for a follow-up.
Do NOT silently "sync" the two tables; that would change behavior. -->

| Tier | Signals (any strong match) | Spawned workflow |
|------|----------------------------|------------------|
| **trivial** | Labels: `typo`, `docs`, `documentation`, `chore`, `good-first-issue`. Body <300 chars after stripping markdown. Title matches `typo\|rename\|bump\|version\|readme`. No stack trace. Single file named. | Direct edit → test (if touched code is tested) → `/uberdev:simplify` → PR. **No brainstorm, no multi-step plan.** |
| **small** | Clear reproduction + error message. Localized to one module/package. Estimated ≤50 LOC. Labels: `bug` (scoped) or none. Not cross-cutting. | Lightweight TodoWrite plan (3–6 tasks) → TDD → `/uberdev:simplify` → PR. **No brainstorm.** |
| **medium/large** *(default)* | Labels: `epic`, `needs-discussion`, `architectural`, `infrastructure` (multi-service), `refactor`. ≥3 files/modules mentioned. Missing clear problem statement. Questions in body (`?`, "alternatives:", "options:"). Cross-package scope. | Full `/uberdev:brainstorm` → `/uberdev:write-plan` → `/uberdev:subagent-driven-dev` → `/uberdev:review-pr` pipeline. |

**When in doubt, default to medium/large.** The spawned agent is explicitly told it may escalate to `/uberdev:brainstorm` mid-flight if the scope proves larger than triaged — misclassification is recoverable, not catastrophic.

<!-- DELTA from /solve: this `Non-blocking Q&A` paragraph is turbo-only; it
documents the auto-pick + log-to-PR-body machinery that backs --turbo. -->

**Non-blocking Q&A (medium/large under `--turbo`):** as of #11, the orchestrator's Phase 2 generates clarifying questions in-thread, auto-picks each answer using research-bundle synthesis, and writes them to `.uberdev/research/$RUN_ID/questions.md`. `finish-branch` reads this file when composing the PR body and appends a `## Open questions answered by /turbo` table (Question | Choice | Confidence). This preserves the "best-guess + log" pattern (canonical per the GPT-5 prompting guide): the audit trail is in the PR body, ready for reviewer eyes, without blocking unattended execution. Low-confidence answers are highlighted but do NOT trigger automated blocking — that's a deferred follow-up (#11 Open question 3).

## Steps

<!-- Prereqs (gh, jq) verified at session start by hooks/session-start. The
     previous `command -v gh` block here was theatre — Claude reads command
     files as instructions, not bash, so the check was never actually executed
     at command-invocation time. Real runtime guards live in the session-start
     hook (jq fails the hook fast; gh injects a one-time warning when missing). -->

### 1. Parse arguments

Extract issue number (first numeric token) + optional override flag:

```bash
ISSUE_NUM=$(echo "$ARGUMENTS" | grep -oE '^[0-9]+' | head -1)
OVERRIDE=$(echo "$ARGUMENTS" | grep -oE '\-\-(trivial|small|full)' | head -1 | sed 's/--//')
TERMINAL_OVERRIDE=$(echo "$ARGUMENTS" | grep -oE '\-\-terminal=[a-z]+' | head -1 | sed 's/--terminal=//')
AUTO_FLAG=$(echo "$ARGUMENTS" | grep -oE '\-\-auto' | head -1)
if [[ -z "$ISSUE_NUM" ]]; then
  echo "Usage: /solve <issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
  exit 1
fi
# --full is an alias for medium/large (keeps current behavior)
[[ "$OVERRIDE" == "full" ]] && OVERRIDE="medium"

# AUTO_MODE precedence: CLI flag > env var > per-repo config > default off.
# When set, the spawned agent runs --permission-mode auto (Claude Code's AI
# classifier), NOT --dangerously-skip-permissions (which the classifier itself
# soft-denies as "Create Unsafe Agents").
if [[ -n "$AUTO_FLAG" ]]; then
  AUTO_MODE=1
elif [[ "$SOLVE_AUTO" == "1" ]]; then
  AUTO_MODE=1
elif [[ -f .claude/uberdev.local.md ]] && grep -qE '^solve_auto:[[:space:]]*true[[:space:]]*$' .claude/uberdev.local.md; then
  AUTO_MODE=1
else
  AUTO_MODE=0
fi
```

### 2. Detect repo

```bash
gh repo view --json nameWithOwner --jq .nameWithOwner
```

### 3. Fetch issue, verify state, classify

```bash
gh issue view $ISSUE_NUM --json number,title,state,body,labels
```

Stop if the issue does not exist or is closed. **Save the title** for the workspace tab (truncate at ~40 chars at a word boundary and append `…` if longer).

Determine `TIER`:

- If `$OVERRIDE` is set → `TIER=$OVERRIDE`
- Else apply the triage table above to `{title, body, labels}`. Be honest: if the issue body says "refactor the whole auth module", that's **medium**, not small, even if the labels are quiet. Default to **medium** on ambiguity.

### 4. Write tier-appropriate prompt

<!-- DELTA from /solve: this entire Step 4 diverges between solve.md and
turbo.md. /turbo's trivial+small heredocs OMIT the `Read pre-collected
research` step and the `Invoke uberdev:post-impl-review skill` step that
solve.md includes. /turbo's medium prompt uses `--turbo` flag; solve.md does
not. Do NOT mirror this section blindly across files — the divergence is
intentional (post-impl-review wiring rolled into /solve first; /turbo will
follow in a separate issue). -->

**trivial:**

```bash
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
3. Add/update a test ONLY if the touched code is already tested.
4. Run the relevant test file + lint for that package.
5. /uberdev:simplify before push (mandatory per CLAUDE.md).
6. Commit with conventional message. Open PR with \`Closes #$ISSUE_NUM\` in the body.

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
```

**small:**

```bash
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
3. TDD: write the failing test first, then implement, then green.
4. /uberdev:simplify before push (mandatory).
5. Commit + PR with \`Closes #$ISSUE_NUM\`.

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
```

**medium** *(and `--full`)*:

<!-- DELTA from /solve: `--turbo` flag here vs bare `orchestrator …` in
solve.md. The `--turbo` flag is what tells the orchestrator to auto-pick
brainstorm answers instead of pausing for user input. -->

```bash
echo "/uberdev:orchestrator --turbo solve GH issue #$ISSUE_NUM" > /tmp/solve-prompt-$ISSUE_NUM.txt
```

### 5. Write launcher script

The launcher `cd`s to repo root, cleans stale worktree, logs errors, keeps terminal open on failure.

```bash
cat > /tmp/solve-$ISSUE_NUM.sh << 'SCRIPT_EOF'
#!/bin/zsh -l
set -e

# Inherit detected terminal so Step 8 retitling can use the right mechanism.
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
CLAUDE_BIN --model 'claude-opus-4-7[1m]' --effort max --worktree solve-issue-ISSUE_NUM $PERM_FLAG "$PROMPT"
SCRIPT_EOF
# BSD/macOS sed needs '-i ""'; GNU sed needs bare '-i'.
SED_INPLACE=(-i '')
[[ "$(uname)" == "Linux" ]] && SED_INPLACE=(-i)
sed "${SED_INPLACE[@]}" "s|REPO_ROOT|$(pwd)|g" /tmp/solve-$ISSUE_NUM.sh
REAL_CLAUDE=$(WRAPPER_DIR=$(dirname "$(which claude)"); for d in ${(s/:/)PATH}; do [[ "$d" == "$WRAPPER_DIR" ]] && continue; [[ -x "$d/claude" ]] && echo "$d/claude" && break; done)
sed "${SED_INPLACE[@]}" "s|CLAUDE_BIN|${REAL_CLAUDE:-$(which claude)}|g" /tmp/solve-$ISSUE_NUM.sh
sed "${SED_INPLACE[@]}" "s/ISSUE_NUM/$ISSUE_NUM/g" /tmp/solve-$ISSUE_NUM.sh
sed "${SED_INPLACE[@]}" "s/TIER/$TIER/g" /tmp/solve-$ISSUE_NUM.sh
# DETECTED_TERMINAL is set by Step 5.5 below; if you reorder, move that step before Step 5.
sed "${SED_INPLACE[@]}" "s/DETECTED_TERMINAL/${TERMINAL:-cmux}/g" /tmp/solve-$ISSUE_NUM.sh
PERM_FLAG_VAL=""
[[ "$AUTO_MODE" == "1" ]] && PERM_FLAG_VAL="--permission-mode auto"
sed "${SED_INPLACE[@]}" "s|PERM_FLAG_VALUE|$PERM_FLAG_VAL|g" /tmp/solve-$ISSUE_NUM.sh
chmod +x /tmp/solve-$ISSUE_NUM.sh
```

### 5.5. Detect terminal app

Pick a dispatcher. Priority: explicit override > cmux (only when we're inside a live cmux session) > standalone Ghostty > iTerm2 > Terminal.app > nohup-fallback. **Warp falls through to nohup** — its CLI can't dispatch a command into a new window cleanly.

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
      echo "         Run /solve from inside an active cmux session, or unset SOLVE_TERMINAL/--terminal." >&2
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
echo "Permission mode: $([[ "$AUTO_MODE" == "1" ]] && echo 'auto (Claude Code AI classifier)' || echo 'default (manual per-tool gating)')"
# Banner only fires for medium tier — trivial/small don't run brainstorm, so "questions
# auto-answered" would be misleading there (no questions would have been asked anyway).
if [[ "$TIER" == "medium" ]]; then
  echo "⚠️  TURBO MODE — brainstorm questions auto-answered with lead-agent recommendations." >&2
  echo "    Spec and plan are still written to disk before implementation; review the artifacts to course-correct." >&2
fi
```

### 6. Spawn agent in new terminal session

Tab/window shows issue + title; description encodes the tier for audit. Each branch invokes `zsh -l /tmp/solve-$ISSUE_NUM.sh`. Use the literal title from Step 3 (apply the ~40-char truncation rule).

```bash
TITLE="<issue-title>"  # from Step 3, truncated
TAB_NAME="#$ISSUE_NUM $TITLE"
DESCRIPTION="[$TIER] Solve GH issue #$ISSUE_NUM: $TITLE"
SCRIPT="/tmp/solve-$ISSUE_NUM.sh"

case "$TERMINAL" in
  cmux)
    cmux new-workspace --name "$TAB_NAME" --description "$DESCRIPTION" --command "zsh -l $SCRIPT"
    ;;
  ghostty)
    # Tab-spawn into the originating Ghostty window when /turbo was invoked from
    # inside Ghostty (TERM_PROGRAM=ghostty). Ghostty's macOS CLI rejects
    # `+new-window` ("not supported on this platform") and its AppleScript
    # dictionary doesn't expose `make new tab` cleanly, so we drive the
    # default Cmd+T keybind via System Events and type the launcher path.
    # Fall through to legacy new-window dispatch when:
    #   - SOLVE_GHOSTTY_NEW_WINDOW=1 (explicit opt-out),
    #   - TERM_PROGRAM != ghostty (no originating window — e.g. SOLVE_TERMINAL=ghostty
    #     forced from another terminal),
    #   - or the AppleScript fails (Accessibility permission denied, custom keybind, etc.).
    TAB_SPAWNED=0
    if [[ "$SOLVE_GHOSTTY_NEW_WINDOW" != "1" ]] && [[ "$TERM_PROGRAM" == "ghostty" ]]; then
      if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Ghostty" to activate
delay 0.15
tell application "System Events"
  keystroke "t" using command down
  delay 0.25
  keystroke "zsh -l $SCRIPT"
  keystroke return
end tell
APPLESCRIPT
      then
        TAB_SPAWNED=1
      else
        echo "warning: ghostty tab-spawn failed (Accessibility permission or non-default keybind?); falling back to new window." >&2
      fi
    fi
    if [[ "$TAB_SPAWNED" != "1" ]]; then
      # Legacy new-window dispatch. --command= rather than -e: Ghostty's -e appends to
      # its login shell, which on macOS parses post-username tokens as KEY=VALUE env
      # assignments — `-e "zsh -l $SCRIPT"` would never run the script. The launcher's
      # `#!/bin/zsh -l` shebang preserves login-shell semantics inside `--command=`.
      open -na Ghostty --args --command="$SCRIPT"
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
```

### 7. Brief delay and confirm

cmux's native notifier is preferred (matches existing UX); otherwise fall through to `terminal-notifier` then `osascript display notification`.

<!-- DELTA from /solve: NOTIFY_BODY appends `, turbo` suffix so the desktop
notification distinguishes /turbo runs from /solve runs at a glance. -->

```bash
sleep 1
NOTIFY_BODY="Agent spawned for issue #$ISSUE_NUM (tier: $TIER, terminal: $TERMINAL$([[ "$AUTO_MODE" == "1" ]] && echo ', auto'), turbo)"
if [[ "$TERMINAL" == "cmux" ]] && command -v cmux >/dev/null 2>&1; then
  cmux notify --title "Orchestrator" --body "$NOTIFY_BODY"
elif command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "Orchestrator" -message "$NOTIFY_BODY"
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$NOTIFY_BODY\" with title \"Orchestrator\""
fi
```

### 8. Post-action — rename tab to PR number once opened (optional)

After opening its PR, the spawned agent renames its own tab from `#<issue> <title>` to `PR #<pr> <title>`. cmux uses its workspace API; everything else uses OSC escape sequences (Ghostty, iTerm2, Terminal.app all honor `OSC 1` for tab title and `OSC 2` for window title). Apply the same ~40-char truncation rule if `$PR_TITLE` is long.

The spawned agent inherits `$TERMINAL` from this script (exported into the launcher in Step 5 — adjust the launcher heredoc to write `export TERMINAL='$TERMINAL'` near the top if you want this to work cleanly; otherwise the agent re-detects via the same logic above).

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

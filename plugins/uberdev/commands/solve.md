---
description: "Spawn an autonomous Claude agent in a new terminal/cmux workspace to solve a GitHub issue, with auto-triage and tier-appropriate workflow"
argument-hint: "<issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]"
allowed-tools: ["Bash", "Read", "Task"]
---

# Solve GitHub Issue

Spawn an autonomous Claude agent in a new cmux workspace to solve GitHub issue **#$ARGUMENTS**.

**RULES:** Do NOT use the Task tool or internal subagents. Use bash commands only.

**Usage:** `/solve <issue-number> [--trivial|--small|--full] [--auto] [--terminal=cmux|ghostty|iterm|terminal|nohup]`

- No flag → **auto-triage** by reading the issue (labels + body + title)
- `--trivial` / `--small` / `--full` → override classification manually
- `--terminal=…` → override terminal detection (else `$SOLVE_TERMINAL` env var, else auto-detect)
- `--auto` → enable `--permission-mode auto` (Claude Code's AI classifier — auto-approves safe ops; blocks force push / `rm -rf` on pre-existing files / exfil / self-modification / `--dangerously-skip-permissions`). Else `SOLVE_AUTO=1` env var, else `solve_auto: true` in `.claude/uberdev.local.md`.
- `SOLVE_GHOSTTY_NEW_WINDOW=1` env var → force the legacy *new window* dispatch instead of tab-spawning into the originating Ghostty window (Ghostty terminal only).

## Triage heuristics (Step 3 applies this table)

| Tier | Signals (any strong match) | Spawned workflow |
|------|----------------------------|------------------|
| **trivial** | Labels: `typo`, `docs`, `documentation`, `chore`, `good-first-issue`. Body <300 chars after stripping markdown. Title matches `typo\|rename\|bump\|version\|readme`. No stack trace. Single file named. | Read pre-collected research (constraints, prior-art, security) → minimal edit → test (if touched code is tested) → `/uberdev:simplify` → `uberdev:post-impl-review` → PR. **No brainstorm, no multi-step plan.** |
| **small** | Clear reproduction + error message. Localized to one module/package. Estimated ≤50 LOC. Labels: `bug` (scoped) or none. Not cross-cutting. | Read pre-collected research → lightweight TodoWrite plan (3–6 tasks) → TDD → `/uberdev:simplify` → `uberdev:post-impl-review` → PR. **No brainstorm.** |
| **medium/large** *(default)* | Labels: `epic`, `needs-discussion`, `architectural`, `infrastructure` (multi-service), `refactor`. ≥3 files/modules mentioned. Missing clear problem statement. Questions in body (`?`, "alternatives:", "options:"). Cross-package scope. | Full `/uberdev:brainstorm` → `/uberdev:write-plan` → `/uberdev:subagent-driven-dev` → `/uberdev:review-pr` pipeline. |

**When in doubt, default to medium/large.** The spawned agent is explicitly told it may escalate to `/uberdev:brainstorm` mid-flight if the scope proves larger than triaged — misclassification is recoverable, not catastrophic.

## Steps

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

**trivial:**

```bash
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM directly. Triaged as TRIVIAL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your working context. These were collected at \`/issue\` creation time. If the directory is missing, skip this step (backwards-compat with pre-#11 issues).
3. Make the minimal edit. No redesign, no surrounding refactor, no "while I'm here" cleanup.
4. Add/update a test ONLY if the touched code is already tested.
5. Run the relevant test file + lint for that package.
6. /uberdev:simplify before push (mandatory per CLAUDE.md).
7. **Invoke \`uberdev:post-impl-review\` skill** with \`changed_paths\` = the files you edited and \`commit_range\` = your single commit. Skill returns the 5-agent advisory finding table; surface it to your output but do NOT block on REVISIONS_REQUIRED (the auto-fix loop is deferred).
8. Commit with conventional message. Open PR with \`Closes #$ISSUE_NUM\` in the body. Include the post-impl-review aggregate table under \`## Reviewer findings summary\` in the PR body.

Skip /uberdev:brainstorm. Skip multi-step planning. Escalate to /uberdev:brainstorm ONLY if the scope turns out to be materially larger than triaged.
EOF
```

**small:**

```bash
cat > /tmp/solve-prompt-$ISSUE_NUM.txt << EOF
Solve GH issue #$ISSUE_NUM with a lightweight plan. Triaged as SMALL.

Steps:
1. \`gh issue view $ISSUE_NUM\` — read the ask.
2. **Read pre-collected research** — for each file in \`.uberdev/research/issue-$ISSUE_NUM/{constraints,prior-art,security}.md\` that exists, read the \`summary:\` block and inline its key findings into your TodoWrite plan as constraints/considerations. Backwards-compat: if the directory is missing, proceed without inlined summaries.
3. Write 3–6 TodoWrite tasks. Skip /uberdev:brainstorm — scope is clear.
4. TDD: write the failing test first, then implement, then green.
5. /uberdev:simplify before push (mandatory).
6. **Invoke \`uberdev:post-impl-review\` skill** with \`changed_paths\` = files edited across all TodoWrite tasks and \`commit_range\` = the commits made. Surface the aggregate finding table in your output and the PR body.
7. Commit + PR with \`Closes #$ISSUE_NUM\`. PR body includes the post-impl-review aggregate under \`## Reviewer findings summary\`.

Escalate to /uberdev:brainstorm if the scope proves larger than triaged.
EOF
```

**medium** *(and `--full`)*:

```bash
echo "/uberdev:orchestrator solve GH issue #$ISSUE_NUM" > /tmp/solve-prompt-$ISSUE_NUM.txt
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
    # Tab-spawn into the originating Ghostty window when /solve was invoked from
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

```bash
sleep 1
NOTIFY_BODY="Agent spawned for issue #$ISSUE_NUM (tier: $TIER, terminal: $TERMINAL$([[ "$AUTO_MODE" == "1" ]] && echo ', auto'))"
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

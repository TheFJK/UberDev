#!/usr/bin/env bash
# Shape-locks the always-PR + auto-review-pr chain in finish-branch/SKILL.md:
# mode-selection precedence (--turbo > --interactive > default), captured-and-
# validated PR_URL, Skill-tool chain into uberdev:review-pr, the heredoc + IFS
# read-back title pattern (NOT --title-file, which gh does not support), and
# the layered pre-push secret scan covering both staged diff AND composed PR
# body file.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINISH_BRANCH="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"

if [ ! -r "$FINISH_BRANCH" ]; then
  echo "FATAL: required file missing or unreadable: $FINISH_BRANCH" >&2
  exit 2
fi

PASS=0
FAIL=0

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; echo "        file: $file"; echo "        pattern: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

echo "== Mode selection: --turbo auto-selects Option 2 + chains =="
assert_grep "$FINISH_BRANCH" \
  '[Tt]urbo.*(Option 2|Push and [Cc]reate)|(Option 2|Push and [Cc]reate).*[Tt]urbo' \
  "turbo auto-selects Option 2 (Push and Create PR)"
assert_grep "$FINISH_BRANCH" \
  '[Tt]urbo.*review-pr|review-pr.*[Tt]urbo|forward.*--turbo' \
  "turbo forwards --turbo to review-pr"

echo
echo "== Mode selection: default (no flags) auto-selects Option 2 + chains =="
assert_grep "$FINISH_BRANCH" \
  '[Dd]efault.*[Aa]uto.*Option 2|[Dd]efault mode.*Option 2|always-PR' \
  "default mode auto-selects Option 2 (no menu)"

echo
echo "== Mode selection: --interactive restores 4-option menu =="
assert_grep "$FINISH_BRANCH" \
  '--interactive' \
  "--interactive flag named in mode-selection prose"
assert_grep "$FINISH_BRANCH" \
  'Merge back to|Push and create a Pull Request|Keep the branch as-is|Discard this work' \
  "4-option menu prose still present (gated under --interactive)"

echo
echo "== PR_URL capture from gh pr create stdout =="
assert_grep "$FINISH_BRANCH" \
  'PR_URL=\$\(gh pr create' \
  "PR_URL captured via PR_URL=\$(gh pr create ...) pattern"

echo
echo "== PR_URL regex-validate (parse-fail aborts chain) =="
assert_grep "$FINISH_BRANCH" \
  'https://github\\\.com/\[\^/\]\+/\[\^/\]\+/pull/\[0-9\]\+' \
  "PR_URL regex validation present (^https://github.com/.../.../pull/N)"
assert_grep "$FINISH_BRANCH" \
  'non-parseable URL|abort.*chain into.*review-pr|do NOT chain' \
  "abort-on-parse-fail prose present"

echo
echo "== Chain hand-off uses Skill tool, NOT Task =="
assert_grep "$FINISH_BRANCH" \
  'Skill.*review-pr|Skill\("uberdev:review-pr"\)|uberdev:review-pr.*Skill' \
  "Skill-tool invocation of uberdev:review-pr documented"
assert_not_grep "$FINISH_BRANCH" \
  'Task.*review-pr|Task\("uberdev:review-pr"\)|review-pr.*Task tool' \
  "review-pr is NOT invoked via Task (regression canary)"

echo
echo "== Title injection closed via heredoc + quoted-variable read-back =="
# `gh pr create --title-file` does not exist (verified against gh v2.83.1).
# The injection-close uses: heredoc → IFS= read into a bash variable → pass
# to `gh --title "$VAR"` (double-quoted variable expansion is byte-verbatim,
# no backtick/dollar re-evaluation). Heredoc delimiter is unquoted (#42 bug:
# the single-quoted form trips Claude's permission-pattern evaluator); the
# agent therefore keeps the title free of $/backticks/backslash.
assert_grep "$FINISH_BRANCH" \
  'TITLE_FILE=\$\(mktemp\)|TITLE_FILE=' \
  "TITLE_FILE mktemp pattern present"
assert_grep "$FINISH_BRANCH" \
  '<<PR_TITLE_EOF' \
  "title written via unquoted heredoc (post-#42; agent keeps title free of metachars)"
assert_grep "$FINISH_BRANCH" \
  'IFS= read -r PR_TITLE_VAR' \
  "title read back into a bash variable for safe quoted expansion"
assert_grep "$FINISH_BRANCH" \
  'gh pr create --title "\$PR_TITLE_VAR"' \
  "gh --title receives a double-quoted variable (no shell re-evaluation)"
assert_not_grep "$FINISH_BRANCH" \
  'gh pr create --title "<title>"' \
  "literal <title> placeholder absent (regression canary — would be LLM-substitution-injectable)"
assert_not_grep "$FINISH_BRANCH" \
  'gh pr create.*--title-file|gh pr edit.*--title-file' \
  "--title-file flag NOT used in any gh command (gh v2.83.1+ does not support it — would fail every invocation)"

echo
echo "== Pre-push secret scan: covers staged diff AND PR body file =="
assert_grep "$FINISH_BRANCH" \
  'git diff --staged' \
  "secret scan target 1: staged diff"
assert_grep "$FINISH_BRANCH" \
  'PR_BODY_FILE|composed PR body|composed PR-body' \
  "secret scan target 2: composed PR body file"
assert_grep "$FINISH_BRANCH" \
  'gitleaks' \
  "gitleaks named (primary scan tool)"
assert_grep "$FINISH_BRANCH" \
  'AKIA\[0-9A-Z\]\{16\}|gh\[ps\]_\[A-Za-z0-9\]|BEGIN .*PRIVATE KEY' \
  "regex fallback patterns present (AWS, GH tokens, private keys)"

echo
echo "== gitleaks-missing fail-open warning =="
assert_grep "$FINISH_BRANCH" \
  'brew install gitleaks|gitleaks not installed|regex fallback only' \
  "gitleaks-missing warning + bootstrap hint present"

echo
echo "== Worktree preservation for Options 2/3 unchanged (regression canary) =="
assert_grep "$FINISH_BRANCH" \
  'For Options 2 and 3.*[Kk]eep worktree|Options 2 and 3.*[Pp]reserve|Options 2.*Keep' \
  "worktree-preservation rule for Options 2/3 still present"

echo
echo "== Anti-attribution guard: no Co-Authored-By in any new prose =="
assert_not_grep "$FINISH_BRANCH" \
  'Co-Authored-By' \
  "Co-Authored-By absent (CLAUDE.md attribution rule)"

echo
echo "== Issue #42: heredoc delimiters tokenizer-safe (no <<'X' or <<\"X\" form) =="
# Quoted heredoc delimiters (`<<'EOF'` / `<<"EOF"`) trigger a Claude
# permission-pattern evaluator bug: the tokenizer doesn't honor heredoc
# semantics, so the leading quote of the delimiter opens an unmatched quote
# that pairs with the next `'` in the block (the regex assignment), inverting
# quote-balance and surfacing as `(eval): unmatched '`. Use unquoted `<<EOF`
# form; the agent must compose title/body bytes free of shell metacharacters
# ($, backticks, backslash) — typical PR Summary text has none.
assert_not_grep "$FINISH_BRANCH" \
  "<<-?['\"][A-Za-z_][A-Za-z0-9_]*['\"]" \
  "no quoted heredoc delimiters (Claude permission-evaluator unmatched ' bug, #42)"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]

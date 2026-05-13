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
SECRET_SCAN_LIB="$REPO_ROOT/plugins/uberdev/lib/secret-scan.sh"

if [ ! -r "$FINISH_BRANCH" ]; then
  echo "FATAL: required file missing or unreadable: $FINISH_BRANCH" >&2
  exit 2
fi
if [ ! -r "$SECRET_SCAN_LIB" ]; then
  echo "FATAL: required file missing or unreadable: $SECRET_SCAN_LIB" >&2
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

echo "== Mode selection: UBERDEV_TURBO=1 auto-selects Option 2 + chains (#97) =="
assert_grep "$FINISH_BRANCH" \
  'UBERDEV_TURBO.*(Option 2|Push and [Cc]reate)|(Option 2|Push and [Cc]reate).*UBERDEV_TURBO' \
  "UBERDEV_TURBO=1 auto-selects Option 2 (Push and Create PR)"
assert_grep "$FINISH_BRANCH" \
  'UBERDEV_TURBO.*review-pr|review-pr.*UBERDEV_TURBO|inherits.*UBERDEV_TURBO|UBERDEV_TURBO=1 env' \
  "UBERDEV_TURBO env-var inherited by review-pr (no --turbo arg forwarding, #97)"
assert_not_grep "$FINISH_BRANCH" \
  'Forward `--turbo` if it was in `\$ARGUMENTS`' \
  "finish-branch chain hand-off does NOT forward --turbo arg (#97 — env-var inheritance)"

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
# agent must keep the title free of `$`, backticks, and backslash.
assert_grep "$FINISH_BRANCH" \
  'TITLE_FILE=\$\(mktemp\)|TITLE_FILE=' \
  "TITLE_FILE mktemp pattern present"
assert_grep "$FINISH_BRANCH" \
  '<<PR_TITLE_EOF' \
  "title written via unquoted heredoc <<PR_TITLE_EOF (#42)"
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
  'gitleaks|secret-scan\.sh' \
  "gitleaks reachable from SKILL.md (inline name or sourced lib)"
# Regex patterns and gitleaks-missing warning moved to lib/secret-scan.sh
# (extracted by #111). Assert against the library file, since the content
# location moved but the intent has not.
assert_grep "$SECRET_SCAN_LIB" \
  'AKIA\[0-9A-Z\]\{16\}|gh\[ps\]_\[A-Za-z0-9\]|BEGIN .*PRIVATE KEY' \
  "regex fallback patterns present in lib/secret-scan.sh (AWS, GH tokens, private keys)"
assert_grep "$FINISH_BRANCH" \
  'source.*lib/secret-scan\.sh' \
  "SKILL.md sources the secret-scan library"

echo
echo "== gitleaks-missing fail-open warning =="
assert_grep "$SECRET_SCAN_LIB" \
  'brew install gitleaks|gitleaks not installed|regex fallback only' \
  "gitleaks-missing warning + bootstrap hint present in lib/secret-scan.sh"

echo
echo "== Worktree preservation for Options 2/3 unchanged (regression canary) =="
assert_grep "$FINISH_BRANCH" \
  'For Options 2 and 3.*[Kk]eep worktree|Options 2 and 3.*[Pp]reserve|Options 2.*Keep' \
  "worktree-preservation rule for Options 2/3 still present"

echo
echo "== Issue #67: PR-body composition glob updated for post-push relocation =="
# Glob #1 — widened from `post-impl-review-wave-*.md` to `post-impl-review-*.md`
# so it matches both the new canonical filename (post-impl-review-final.md,
# written by /uberdev:review-pr Phase 1) AND any legacy `-wave-final.md`
# artifacts left over from pre-refactor SDD step 5 runs (zero-migration).
assert_grep "$FINISH_BRANCH" \
  'post-impl-review-\*\.md' \
  "G1 — glob #1 widened to post-impl-review-*.md (no wave- infix)"
# Anti-regression: the old wave-* glob must NOT appear in any executable ls -t line
if grep -E '^\s*REVIEW_FILES=.*post-impl-review-wave-\*\.md' "$FINISH_BRANCH" >/dev/null; then
  echo "  FAIL  G1.regression — old glob 'post-impl-review-wave-*.md' must not appear in any live REVIEW_FILES= ls line"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  G1.regression — old wave-*.md glob removed from live REVIEW_FILES= ls line"
  PASS=$((PASS + 1))
fi
# Glob #2 — RETAINED for legacy artifact matching.
assert_grep "$FINISH_BRANCH" \
  'issue-\*/post-impl-review\.md' \
  "G2 — glob #2 .uberdev/research/issue-*/post-impl-review.md RETAINED for legacy artifact matching"

echo
echo "== Issue #67: Options 1/3/4 bypass caveat documented in interactive-mode docs =="
assert_grep "$FINISH_BRANCH" \
  'Options 1, 3, 4 bypass post-impl review|Options 1.*3.*4.*bypass.*post-impl|bypass.*Options 1.*3.*4' \
  "C1 — Options 1/3/4 caveat prose present (interactive-mode bypass documentation)"
assert_grep "$FINISH_BRANCH" \
  'Only Option 2.*preserves the chain|Option 2.*preserves the chain' \
  "C2 — caveat names Option 2 as the only chain-preserving choice"
assert_grep "$FINISH_BRANCH" \
  '/uberdev:review-pr.*Phase 1.*5-reviewer|5-reviewer.*post-impl-review fanout|post-impl-review.*sole live caller' \
  "C3 — caveat cross-references /uberdev:review-pr Phase 1 as the post-impl-review host"

echo
echo "== Issue #67: Quick Reference table includes Post-impl review column =="
assert_grep "$FINISH_BRANCH" \
  '\| Post-impl review \|' \
  "QR1 — Quick Reference table has Post-impl review column header"
assert_grep "$FINISH_BRANCH" \
  '1\. Merge locally.*\|.*bypassed' \
  "QR2 — Option 1 row marks Post-impl review as bypassed"
assert_grep "$FINISH_BRANCH" \
  '2\. Create PR.*\|.*runs' \
  "QR3 — Option 2 row marks Post-impl review as runs (via /review-pr Phase 1)"
assert_grep "$FINISH_BRANCH" \
  '3\. Keep as-is.*\|.*bypassed' \
  "QR4 — Option 3 row marks Post-impl review as bypassed"
assert_grep "$FINISH_BRANCH" \
  '4\. Discard.*\|.*bypassed' \
  "QR5 — Option 4 row marks Post-impl review as bypassed"

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
# form; the agent must compose title/body bytes free of `$`, backticks,
# and backslash. Note: the assertion does NOT match `<<\EOF` (backslash-
# escaped delimiter, semantically equivalent to the quoted form but
# tokenizer-safe — no quote chars, so it doesn't trip the evaluator).
assert_not_grep "$FINISH_BRANCH" \
  "<<-?['\"][A-Za-z_][A-Za-z0-9_]*['\"]" \
  "no quoted heredoc delimiters (Claude permission-evaluator unmatched ' bug, #42)"

echo
echo "== Issue #55: no English possessives/contractions in bash-block #-comments =="
# Apostrophes inside #-comments in fenced bash blocks trip the Claude
# permission-pattern evaluator (same tokenizer bug as #42 — the evaluator
# does not honor comment context; every ' toggles quote-state, pairing with
# the next unrelated ' downstream and inverting quote-balance until a later
# ' surfaces as `unmatched '`). Rephrase comment prose to drop possessives
# and contractions (e.g. gh's → the gh, caller's → the caller, don't → do
# not). Backtick-quoted documentation forms like `unmatched '` are unaffected —
# the regex below matches only ' adjacent to letters, not ' next to backticks
# or spaces.
assert_not_grep "$FINISH_BRANCH" \
  "#.*[a-zA-Z]'[a-zA-Z]" \
  "no apostrophes inside #-comments in bash blocks (Claude permission-evaluator unmatched ' bug, #55)"

echo
echo "== Same #42/#55 bug class: no shell-keyword backticks in bash-block #-comments =="
# Backtick-quoted bash *reserved words* inside #-comments trip the same
# Claude permission-pattern evaluator that #42 (heredoc delimiters) and
# #55 (apostrophes) hit: the evaluator naively eval()s text from #-comments,
# treating backticks as command substitution. When the body inside the
# backticks is incomplete shell (e.g. `if !`, `then`, `done`, `while x`),
# bash reports `(eval): parse error near `)'` and aborts skill load before
# the option menu / gh pr create path can run. Other backticks in this
# file have *complete* command-sub bodies (`gh pr create`, `git merge-base
# HEAD HEAD~1`, `[[ -n $SCAN_OUT ]]`) and parse cleanly, so they are
# unaffected — this canary fires only on bare reserved words at the start
# of a backtick body, the foot-gun shape. Keep the keyword list aligned
# with bash's reserved words: if/then/else/elif/fi/while/for/until/do/done/
# case/esac/function/select/time. Rephrase such comments to use
# non-backticked prose (e.g. `if !` → "the negated-conditional branch").
assert_not_grep "$FINISH_BRANCH" \
  '#.*`(if|then|else|elif|fi|while|for|until|do|done|case|esac|function|select|time)([[:space:]!]|`)' \
  "no shell-keyword backticks inside #-comments in bash blocks (Claude permission-evaluator parse-error bug, #42/#55 family)"

echo "== Issue #95: review-pr:pending backstop in finish-branch =="

assert_grep "$FINISH_BRANCH" \
  'gh label create --force review-pr:pending' \
  "#95.1 — idempotent gh label create call present (spec C1; gh --add-label cannot auto-create labels)"

assert_grep "$FINISH_BRANCH" \
  'gh pr edit .*--add-label review-pr:pending' \
  "#95.2 — gh pr edit --add-label review-pr:pending present (spec C1)"

assert_grep "$FINISH_BRANCH" \
  'REVIEW_PR_PENDING_LABEL' \
  "#95.3 — prose paragraph references REVIEW_PR_PENDING_LABEL constant by name (spec C4)"

# Line-order: label-add MUST precede the Skill(uberdev:review-pr) dispatch prose
L_ADD=$(grep -n -- '--add-label review-pr:pending' "$FINISH_BRANCH" | head -1 | cut -d: -f1)
L_SKILL=$(grep -n -E 'Invoke `uberdev:review-pr` via the Skill tool' "$FINISH_BRANCH" | head -1 | cut -d: -f1)
if [[ -n "$L_ADD" && -n "$L_SKILL" && "$L_ADD" -lt "$L_SKILL" ]]; then
  echo "  PASS  #95.4 — label-add precedes Skill(uberdev:review-pr) dispatch in source order (L_ADD=$L_ADD < L_SKILL=$L_SKILL)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #95.4 — label-add MUST appear before Skill(uberdev:review-pr) dispatch (L_ADD=$L_ADD L_SKILL=$L_SKILL)"
  FAIL=$((FAIL + 1))
fi

# Fail-soft contract: no `exit` inside the new label-add block (sed-based; bounded range)
LABEL_BLOCK_START=$(grep -n 'Extract PR number from PR_URL using a capture-group variant' "$FINISH_BRANCH" | head -1 | cut -d: -f1)
LABEL_BLOCK_END=$(awk -v s="$LABEL_BLOCK_START" 'NR > s && /^fi$/ { print NR; exit }' "$FINISH_BRANCH")
if [[ -n "$LABEL_BLOCK_START" && -n "$LABEL_BLOCK_END" ]]; then
  EXIT_COUNT=$(sed -n "${LABEL_BLOCK_START},${LABEL_BLOCK_END}p" "$FINISH_BRANCH" | grep -cE '^[[:space:]]*exit')
  if [[ "$EXIT_COUNT" -eq 0 ]]; then
    echo "  PASS  #95.5 — label-add bash block is fail-soft (no exit inside; fire-and-surface contract)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  #95.5 — label-add bash block MUST be fail-soft; found $EXIT_COUNT exit statement(s)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  #95.5 — could not locate label-add block (LABEL_BLOCK_START=$LABEL_BLOCK_START LABEL_BLOCK_END=$LABEL_BLOCK_END)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"

[[ $FAIL -eq 0 ]]

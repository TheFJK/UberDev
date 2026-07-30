#!/usr/bin/env bash
# tests/finish-branch-zsh.test.sh — RUNTIME coverage for the finish-branch
# "## Reviewer findings summary" PR-body composer under the REAL shell the
# Claude-Code Bash tool runs SKILL.md fences with: /bin/zsh on macOS.
#
# Why this fixture exists (#308 / RFC 0012 §3.6 finish-branch hardening):
# the section reads the post-impl-review aggregate(s) via `ls`, then loops the
# file list and (post-#302) strips the `<external-untrusted-input>` envelope tag
# lines before pasting findings into the PR body. The list was space-joined
# (`ls … | tr '\n' ' '`) and consumed by `for f in $REVIEW_FILES`. Under zsh
# SH_WORD_SPLIT is OFF, so an unquoted scalar does NOT word-split — $f bound to
# the ENTIRE joined list as one token, the `[ -f "$f" ]` guard failed, `continue`
# fired, and the whole section (heading + envelope strip) was SILENTLY SKIPPED.
# CI runs the *.test.sh suite under bash (where the old for-loop DID word-split),
# which is exactly why the zsh-only inertness escaped every existing grep/bash
# test. The companion bash coverage is turbo-flow.test.sh:459 (heading grep) and
# finish-branch-auto-chain.test.sh G1/G2 (glob shape) — both grep-only.
#
# This fixture EXTRACTS the live composer block from SKILL.md and RUNS it under a
# dedicated `zsh -f` (the real fence runtime) with seeded fixture files, then
# asserts: the section renders, BOTH files are processed, the finding text
# survives, and the envelope tag lines are stripped. A negative control runs the
# OLD `for f in $REVIEW_FILES` form under zsh and proves it skips the body — so
# the assertion is non-vacuous (it goes RED if the fix regresses to a for-loop).
#
# Launcher (matches test.yml — runs alongside goal-state-zsh.test.sh et al.):
#
#   zsh  tests/finish-branch-zsh.test.sh   # CI launcher: the real fence runtime
#   bash tests/finish-branch-zsh.test.sh   # also works — the HARNESS is dual-
#                                          # launchable; the extracted composer is
#                                          # ALWAYS run under `zsh -f` regardless.
#
# Mutation guard (revert the named production fix in your worktree, re-run):
#   - the loop `while IFS= read -r f … done <<< "$REVIEW_FILES"` -> the old
#     `for f in $REVIEW_FILES; do … done`                 => F1 RED (section empty
#     under zsh: the joined scalar fails to word-split, the guard skips the body).
#   - the `REVIEW_FILES=… | tr '\n' ' '` join reintroduced  => F1 RED (same path:
#     a space-joined scalar read by the read-loop is a single line -> one bogus
#     non-file token -> guard skip).
#   - the `sed … /external-untrusted-input/d` strip removed  => F3 RED (tag lines
#     leak into the rendered section).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINISH_BRANCH="$REPO_ROOT/plugins/uberdev/skills/finish-branch/SKILL.md"

if [ ! -r "$FINISH_BRANCH" ]; then
  echo "FATAL: required file missing/unreadable: $FINISH_BRANCH" >&2
  exit 2
fi

# Locate a real zsh — this fixture's whole point is the zsh runtime. CI installs
# zsh on ubuntu-latest (see test.yml). If the harness itself was launched under
# zsh we reuse that interpreter; otherwise we find zsh on PATH.
if [ -n "${ZSH_VERSION:-}" ]; then
  LAUNCH_SHELL="zsh"
  ZSH_BIN="$(command -v zsh 2>/dev/null || echo zsh)"
else
  LAUNCH_SHELL="bash"
  ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
fi
if [ -z "$ZSH_BIN" ] || ! "$ZSH_BIN" -c 'exit 0' 2>/dev/null; then
  echo "FATAL: zsh not found on PATH — this fixture must run the SKILL.md composer under zsh" >&2
  echo "       (CI installs zsh on ubuntu-latest; locally: brew install zsh / apt-get install zsh)" >&2
  exit 2
fi

echo "== finish-branch-zsh.test.sh — harness launched under: $LAUNCH_SHELL; composer run under: $ZSH_BIN =="

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# --------------------------------------------------------------------------
# Fence slicer (ported from goal-pipeline-zsh.test.sh): pull the in-fence lines
# from the (in-fence) line containing SANCHOR through the line containing
# EANCHOR (inclusive) out of the ```bash fence. Anchored by CONTENT, robust to
# line-number drift. Exits 3 (-> caller fails LOUD) when an anchor is not found,
# so a SKILL.md edit that removes/renames the composer fails here rather than
# silently producing an empty slice.
# --------------------------------------------------------------------------
SLICE_AWK="$WORK/slice.awk"
cat > "$SLICE_AWK" <<'AWK'
BEGIN { infence=0; curbash=0; emitting=0; found=0 }
{
  line=$0
  if (line ~ /^[[:space:]]*```/) {
    if (infence==0) {
      stripped=line; sub(/^[[:space:]]*```/, "", stripped)
      curbash = (stripped ~ /^bash[[:space:]]*$/) ? 1 : 0
      infence=1; next
    } else { infence=0; curbash=0; next }
  }
  if (infence==1 && curbash==1) {
    if (emitting==0 && index(line, SANCHOR) > 0) emitting=1
    if (emitting==1) { print line; if (index(line, EANCHOR) > 0) { found=1; exit } }
  }
}
END { if (found==0) exit 3 }
AWK

slice_fence() { awk -v SANCHOR="$1" -v EANCHOR="$2" -f "$SLICE_AWK" "$FINISH_BRANCH"; }

# Slice the composer: from the heading echo through the loop terminator (`done`).
# The end-anchor is the GENERIC `done` (the loop's only `done` between the heading
# and its terminator — verified: no stray `done` in between) rather than the
# fix-specific `done <<< "$REVIEW_FILES"`, so a regression to the old
# `for f in $REVIEW_FILES; do … done` shape still SLICES cleanly and is caught
# BEHAVIORALLY by F1 (a clear "section empty under zsh" failure) instead of a
# confusing slice-anchor miss.
COMPOSER="$WORK/composer.zsh"
if ! slice_fence 'echo "## Reviewer findings summary"' 'done' > "$COMPOSER"; then
  echo "  FAIL  could not slice the '## Reviewer findings summary' composer block from finish-branch/SKILL.md"
  echo "        (anchors: 'echo \"## Reviewer findings summary\"' .. 'done')"
  echo "  Summary: passed=$PASS failed=$((FAIL + 1))"
  exit 1
fi

# Seed the run dir with the canonical compact JSON v2 aggregate plus one legacy
# analyzer report. The composer must render the v2 document for humans instead
# of pasting its raw JSON bytes into the PR body.
SEED_DIR="$WORK/seed"
mkdir -p "$SEED_DIR"
{
  printf '%s\n' '<external-untrusted-input source="post-impl-review-aggregate">'
  printf '%s\n' '{"contributors":[{"confidence":"high","id":"review_pr.review.correctness","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.silent_failures","verdict":"REVISIONS_REQUIRED"},{"confidence":"high","id":"review_pr.review.types","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.comments","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.tests","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.general","verdict":"APPROVE"}],"findings":[{"detail":"The failure path loses its error.","scope":{"line":7,"operation":"modify_existing","path":"src/handler.ts"},"severity":"blocker","source_edges":["review_pr.review.silent_failures"],"summary":"Silent failure in handler"}],"phase":"phase1","schema_version":2}'
  printf '%s\n' '</external-untrusted-input>'
} > "$SEED_DIR/post-impl-review-final.md"
{
  printf '%s\n' '<external-untrusted-input source="test-analysis">'
  printf '%s\n' 'FINDING-PTA: missing coverage on the new branch'
  printf '%s\n' '</external-untrusted-input>'
} > "$SEED_DIR/pr-test-analyzer.md"

# Build the NEWLINE-delimited list exactly as the live SKILL.md does (raw `ls -t`,
# no `tr` join). Pass it to the sliced composer via env and run that composer
# under a real `zsh -f`. The slice references $REVIEW_FILES + standard utils only.
REVIEW_FILES_VAL="$(ls -t "$SEED_DIR"/post-impl-review-*.md "$SEED_DIR"/pr-test-analyzer.md 2>/dev/null)"

echo
echo "== F1/F2/F3: the live composer renders the section under zsh and strips envelopes =="
RENDERED="$("$ZSH_BIN" -f -c '
  set -u
  REVIEW_FILES="'"$REVIEW_FILES_VAL"'"
  '"$(cat "$COMPOSER")"'
' 2>"$WORK/composer.err")"
COMPOSER_RC=$?

if [ "$COMPOSER_RC" -ne 0 ]; then
  fail "F0: composer slice exited non-zero ($COMPOSER_RC) under zsh; stderr=[$(tr -d '\n' < "$WORK/composer.err")]"
fi

# F1 — the section is NOT silently skipped: the heading + BOTH per-file
# `### <basename>` sub-headers render. This is the assertion the zsh word-split
# bug defeated (the body never ran, so nothing past the heading appeared).
if grep -qF '## Reviewer findings summary' <<<"$RENDERED" \
   && grep -qF '### post-impl-review-final.md' <<<"$RENDERED" \
   && grep -qF '### pr-test-analyzer.md' <<<"$RENDERED"; then
  pass "F1: composer renders the section + both ### file headers under zsh (the read-loop word-splits the list)"
else
  fail "F1: composer section/file-headers MISSING under zsh — the loop skipped the body (for-loop word-split regression?)"
  printf '        rendered=[%s]\n' "$(printf '%s' "$RENDERED" | tr '\n' '|')"
fi

# F2 — the finding text from BOTH files survives into the rendered body.
if grep -qF '**blocker** `src/handler.ts:7` — Silent failure in handler' <<<"$RENDERED" \
   && grep -qF 'FINDING-PTA: missing coverage on the new branch' <<<"$RENDERED"; then
  pass "F2: schema-v2 findings are human-rendered and legacy analyzer text survives under zsh"
else
  fail "F2: v2 human summary or legacy analyzer text is missing under zsh"
  printf '        rendered=[%s]\n' "$(printf '%s' "$RENDERED" | tr '\n' '|')"
fi

if grep -qF '"schema_version":2' <<<"$RENDERED"; then
  fail "F2b: raw compact schema-v2 JSON leaked into the PR body"
else
  pass "F2b: raw compact schema-v2 JSON is not pasted into the PR body"
fi

# F3 — the envelope tag lines are STRIPPED (the headline behavior of the #302
# pairing). Pure `<external-untrusted-input …>` / `</external-untrusted-input>`
# lines must NOT survive into the PR body.
if grep -qE '<external-untrusted-input' <<<"$RENDERED"; then
  fail "F3: envelope OPEN/CLOSE tag lines leaked into the rendered section (the sed strip did not run)"
  printf '        rendered=[%s]\n' "$(printf '%s' "$RENDERED" | tr '\n' '|')"
else
  pass "F3: envelope tag lines stripped from the rendered section under zsh (#302 envelope-strip is LIVE)"
fi

# --------------------------------------------------------------------------
# F4 — NEGATIVE CONTROL: prove the assertions above are non-vacuous. Run the
# OLD `for f in $REVIEW_FILES` shape under the SAME zsh against the SAME files
# and confirm it skips the body (so nothing past the heading renders). If this
# control ever STARTS rendering the files, F1/F2 would be passing for the wrong
# reason (zsh word-split changed) and the guard tells us so.
# --------------------------------------------------------------------------
echo
echo "== F4: negative control — the OLD for-loop shape skips the body under zsh =="
OLD_RENDERED="$("$ZSH_BIN" -f -c '
  set -u
  REVIEW_FILES="'"$REVIEW_FILES_VAL"'"
  echo "## Reviewer findings summary"
  echo
  for f in $REVIEW_FILES; do
    [ -f "$f" ] || continue
    echo "### $(basename "$f")"
    cat "$f"
    echo
  done
' 2>/dev/null)"
if grep -qF '### post-impl-review-final.md' <<<"$OLD_RENDERED"; then
  fail "F4: the OLD for-loop shape rendered a file header under zsh — zsh word-split behavior changed; F1/F2 may be vacuous"
else
  pass "F4: OLD for-loop shape skips the body under zsh (confirms F1/F2 assert the real fix, not shell luck)"
fi

# --------------------------------------------------------------------------
# F5 — STRUCTURAL guard: no EXECUTABLE `for f in $REVIEW_FILES` remains in the
# SKILL.md (only the explanatory comments that name it). Comment lines begin
# with optional whitespace + `#`; strip them before the scan.
# --------------------------------------------------------------------------
echo
echo "== F5: no executable for-loop over \$REVIEW_FILES remains =="
if grep -vE '^[[:space:]]*#' "$FINISH_BRANCH" | grep -qE 'for[[:space:]]+f[[:space:]]+in[[:space:]]+\$REVIEW_FILES'; then
  fail "F5: an EXECUTABLE 'for f in \$REVIEW_FILES' still exists in finish-branch/SKILL.md (zsh-skip regression)"
else
  pass "F5: no executable 'for f in \$REVIEW_FILES' remains (the read-loop is the only consumer)"
fi
if grep -qE 'done[[:space:]]*<<<[[:space:]]*"\$REVIEW_FILES"' "$FINISH_BRANCH"; then
  pass "F5b: the composer consumes REVIEW_FILES via a read-loop here-string (word-split-independent)"
else
  fail "F5b: expected the composer to feed \$REVIEW_FILES into a 'while read' loop via '<<< \"\$REVIEW_FILES\"'"
fi

echo
echo "== Summary =="
echo "  launcher: $LAUNCH_SHELL  (composer ran under: $ZSH_BIN)"
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]

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
  printf '%s\n' '{"contributors":[{"confidence":"high","id":"review_pr.review.correctness","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.silent_failures","verdict":"REVISIONS_REQUIRED"},{"confidence":"high","id":"review_pr.review.types","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.comments","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.tests","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.general","verdict":"APPROVE"},{"confidence":"high","id":"review_pr.review.convention","verdict":"APPROVE"}],"findings":[{"detail":"The failure path loses its error.","scope":{"line":7,"operation":"modify_existing","path":"src/handler.ts"},"severity":"blocker","source_edges":["review_pr.review.silent_failures"],"summary":"Silent failure in handler"}],"phase":"phase1","schema_version":2}'
  printf '%s\n' '</external-untrusted-input>'
} > "$SEED_DIR/post-impl-review-final.md"
{
  printf '%s\n' '<external-untrusted-input source="test-analysis">'
  printf '%s\n' 'FINDING-PTA: missing coverage on the new branch'
  printf '%s\n' '</external-untrusted-input>'
} > "$SEED_DIR/pr-test-analyzer-0123456789ab.md"

# Build the NEWLINE-delimited list exactly as the live SKILL.md does (raw `ls -t`,
# no `tr` join). Pass it to the sliced composer via env and run that composer
# under a real `zsh -f`. The slice references $REVIEW_FILES + standard utils only.
# The analyzer seed carries a literal 12-hex plan scope (#458): SDD Step 4.5
# writes pr-test-analyzer-<plan-scope>.md, and this file HAND-COPIES the SKILL.md
# glob rather than reading it, so widening the production glob does not red it —
# left stale it would stay green while exercising a filename production no longer
# writes. A literal scope is correct here: this file is a fixture, it never mints.
REVIEW_FILES_VAL="$(ls -t "$SEED_DIR"/post-impl-review-*.md "$SEED_DIR"/pr-test-analyzer*.md 2>/dev/null)"

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
   && grep -qF '### pr-test-analyzer-0123456789ab.md' <<<"$RENDERED"; then
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

# --------------------------------------------------------------------------
# F6 — the pre-push secret-scan LIBRARY must behave identically under the real
# fence shell. zsh ties the parameter `path` to `PATH`, so a `local path` inside
# any library function empties the command search path for that entire function
# body and every external it calls silently stops resolving — turning a clean
# scan into a fail-CLOSED scanner error. bash has no such tie, so the bash
# suites cannot see it; and the affected code is on the gitleaks branch, which
# never executes on a runner without gitleaks. This probe therefore puts a
# gitleaks STUB on PATH so the primary layer runs on every platform.
#
# Mutation guard: rename any library local back to `path` (e.g. in
# _uberdev_secret_scan_default_config) => F6 RED on all three assertions.
# --------------------------------------------------------------------------
echo
echo "== F6: lib/secret-scan.sh behaves identically under zsh =="
F6_BIN="$WORK/f6bin"
mkdir -p "$F6_BIN"
cat > "$F6_BIN/gitleaks" <<'STUB'
#!/bin/sh
# Reports CLEAN, so the verdict is decided by the regex fallback: the point of
# this probe is that the surrounding library machinery still RUNS under zsh.
cat >/dev/null
exit 0
STUB
chmod +x "$F6_BIN/gitleaks"
F6_OUT="$(PATH="$F6_BIN:$PATH" CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" "$ZSH_BIN" -c '
  set -u
  source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || { echo "source=failed"; exit 0; }
  # Assembled at runtime so these source bytes never carry the token
  # contiguously (finish-branch scans its own diff).
  key="AKIA""IOSFODNN7EXAMPLE"
  printf "%s\n" "a clean line of code" | uberdev_run_secret_scan_stdin >/dev/null 2>&1; echo "clean=$?"
  printf "%s\n" "$key" | uberdev_run_secret_scan_stdin >/dev/null 2>&1; echo "leak=$?"
  printf "%s # %s\n" "$key" "$UBERDEV_SECRET_SCAN_ALLOW_MARKER" \
    | uberdev_run_secret_scan_stdin >/dev/null 2>&1; echo "marked=$?"
' 2>&1)"
F6_FAILURES=''
grep -q '^clean=0$'  <<<"$F6_OUT" || F6_FAILURES="$F6_FAILURES clean-input-not-clean"
grep -q '^leak=1$'   <<<"$F6_OUT" || F6_FAILURES="$F6_FAILURES leak-not-detected-as-match"
grep -q '^marked=0$' <<<"$F6_OUT" || F6_FAILURES="$F6_FAILURES allow-marker-not-honoured"
if [ -z "$F6_FAILURES" ]; then
  pass "F6: secret-scan clean/leak/allowlisted verdicts are identical under zsh"
else
  fail "F6: secret-scan misbehaves under zsh:$F6_FAILURES (got: $(tr '\n' ' ' <<<"$F6_OUT"))"
fi

# --------------------------------------------------------------------------
# FBZ-1 / FBZ-2 (#402) — the composer must distinguish "no findings yet" from
# "corrupt findings".
#
# command-workspace.py CALLERS["review-pr"] pre-allocates every declared
# artifact with its initial bytes at prepare time, and the Phase 1 aggregate's
# initial bytes are EMPTY. So a run that prepares its workspace and then stops
# before Phase 1 writes (or whose Phase 1 suppressed the aggregate and left the
# pre-allocated file behind) leaves a ZERO-BYTE post-impl-review-final.md on the
# glob path this composer walks. Zero bytes can never be a canonical v2
# aggregate, so the strict validator below exits 2 and the composer hard-aborts
# the whole PR-body composition — a workspace pre-allocation detail killing an
# otherwise-fine `gh pr create`.
#
# Contract: a zero-byte report is SKIPPED (it carries no findings, so omitting
# it loses nothing); NON-EMPTY bytes that fail validation still hard-fail, so
# the relaxation cannot be widened into "swallow corrupt aggregates".
#
# Mutation guard: delete the `[ -s "$f" ] || continue` guard from SKILL.md
# => FBZ-1 RED (rc 1 + "invalid canonical Phase 1 review aggregate"). Relax it
# to skip on validator failure instead => FBZ-2 RED (rc 0, no error).
# --------------------------------------------------------------------------
echo
echo "== FBZ-1: a zero-byte Phase 1 aggregate is skipped, not fatal =="
SEED_DIR_EMPTY="$WORK/seed-empty"
mkdir -p "$SEED_DIR_EMPTY"
: > "$SEED_DIR_EMPTY/post-impl-review-final.md"
cp "$SEED_DIR/pr-test-analyzer-0123456789ab.md" "$SEED_DIR_EMPTY/pr-test-analyzer-0123456789ab.md"
REVIEW_FILES_EMPTY="$(ls -t "$SEED_DIR_EMPTY"/post-impl-review-*.md "$SEED_DIR_EMPTY"/pr-test-analyzer*.md 2>/dev/null)"
EMPTY_RENDERED="$("$ZSH_BIN" -f -c '
  set -u
  REVIEW_FILES="'"$REVIEW_FILES_EMPTY"'"
  '"$(cat "$COMPOSER")"'
' 2>"$WORK/composer-empty.err")"
EMPTY_RC=$?
FBZ1_FAILURES=''
[ "$EMPTY_RC" -eq 0 ] || FBZ1_FAILURES="$FBZ1_FAILURES rc=$EMPTY_RC(want-0)"
grep -qF '### pr-test-analyzer-0123456789ab.md' <<<"$EMPTY_RENDERED" \
  || FBZ1_FAILURES="$FBZ1_FAILURES legacy-report-not-rendered"
grep -qF '### post-impl-review-final.md' <<<"$EMPTY_RENDERED" \
  && FBZ1_FAILURES="$FBZ1_FAILURES zero-byte-aggregate-rendered-a-header"
grep -qF 'ERROR: invalid canonical Phase 1 review aggregate' <"$WORK/composer-empty.err" \
  && FBZ1_FAILURES="$FBZ1_FAILURES zero-byte-aggregate-hard-failed"
if [ -z "$FBZ1_FAILURES" ]; then
  pass "FBZ-1: zero-byte post-impl-review-*.md is skipped; the rest of the body still composes"
else
  fail "FBZ-1: zero-byte aggregate mishandled:$FBZ1_FAILURES"
  printf '        rendered=[%s]\n' "$(printf '%s' "$EMPTY_RENDERED" | tr '\n' '|')"
  printf '        stderr=[%s]\n' "$(tr '\n' '|' < "$WORK/composer-empty.err")"
fi

echo
echo "== FBZ-2: a NON-EMPTY invalid Phase 1 aggregate still hard-fails =="
SEED_DIR_BAD="$WORK/seed-bad"
mkdir -p "$SEED_DIR_BAD"
printf '%s\n' 'not-an-aggregate' > "$SEED_DIR_BAD/post-impl-review-final.md"
REVIEW_FILES_BAD="$(ls -t "$SEED_DIR_BAD"/post-impl-review-*.md 2>/dev/null)"
BAD_RENDERED="$("$ZSH_BIN" -f -c '
  set -u
  REVIEW_FILES="'"$REVIEW_FILES_BAD"'"
  '"$(cat "$COMPOSER")"'
' 2>"$WORK/composer-bad.err")"
BAD_RC=$?
FBZ2_FAILURES=''
[ "$BAD_RC" -eq 1 ] || FBZ2_FAILURES="$FBZ2_FAILURES rc=$BAD_RC(want-1)"
grep -qF 'ERROR: invalid canonical Phase 1 review aggregate' <"$WORK/composer-bad.err" \
  || FBZ2_FAILURES="$FBZ2_FAILURES no-invalid-aggregate-error"
if [ -z "$FBZ2_FAILURES" ]; then
  pass "FBZ-2: non-empty invalid aggregate bytes still abort composition (the skip is zero-byte-only)"
else
  fail "FBZ-2: corrupt aggregate was not rejected:$FBZ2_FAILURES"
  printf '        rendered=[%s]\n' "$(printf '%s' "$BAD_RENDERED" | tr '\n' '|')"
  printf '        stderr=[%s]\n' "$(tr '\n' '|' < "$WORK/composer-bad.err")"
fi

echo
echo "== FBZ-3: the --base arg reaches gh as TWO argv words under zsh (#439) =="
# zsh does NOT word-split an unquoted scalar (SH_WORD_SPLIT is off), so the
# obvious `PR_BASE_ARG="--base $PR_BASE"; gh … $PR_BASE_ARG` shape hands gh a
# SINGLE argument `--base feat/parent` and every stacked PR silently retargets
# the default branch. Only an ARRAY expansion splits correctly in both shells.
#
# Mutation guard: rebuild PR_BASE_ARGS as a scalar in SKILL.md => FBZ-3 RED
# (argc collapses from 3 to 2 and the flag word is never seen alone).
FBZ3_BLOCK="$(sed -n '/^# --- BEGIN pr-base resolution (#439) ---$/,/^# --- END pr-base resolution (#439) ---$/p' "$FINISH_BRANCH")"
FBZ3_FAILURES=''
if [ -z "$FBZ3_BLOCK" ]; then
  FBZ3_FAILURES="$FBZ3_FAILURES base-block-not-extractable"
else
  FBZ3_REPO="$WORK/fbz3-repo"
  mkdir -p "$FBZ3_REPO"
  (
    cd "$FBZ3_REPO" || exit 2
    git init -q . >/dev/null 2>&1 || exit 2
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git config commit.gpgsign false
    printf 'one\n' > a.txt && git add a.txt && git commit -qm one >/dev/null 2>&1 || exit 2
    git update-ref refs/remotes/origin/feat/parent HEAD || exit 2
  ) || FBZ3_FAILURES="$FBZ3_FAILURES fixture-setup-failed"

  FBZ3_DRIVER="$WORK/fbz3-driver.zsh"
  {
    printf '%s\n' "$FBZ3_BLOCK"
    printf '%s\n' 'gh_probe() { print -r -- "argc=$#"; for a in "$@"; do print -r -- "arg=[$a]"; done }'
    # Byte-identical argv shape to the shipped `gh pr create` invocation tail.
    printf '%s\n' 'gh_probe --body-file "/tmp/body" ${PR_BASE_ARGS[@]+"${PR_BASE_ARGS[@]}"}'
  } > "$FBZ3_DRIVER"

  FBZ3_OUT="$(cd "$FBZ3_REPO" && env -u UBERDEV_CONFIG_FILE \
    UBERDEV_PR_BASE_BRANCH=feat/parent CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
    "$ZSH_BIN" "$FBZ3_DRIVER" 2>/dev/null)"
  grep -qF 'argc=4' <<<"$FBZ3_OUT"        || FBZ3_FAILURES="$FBZ3_FAILURES argc-not-4"
  grep -qF 'arg=[--base]' <<<"$FBZ3_OUT"  || FBZ3_FAILURES="$FBZ3_FAILURES flag-not-its-own-word"
  grep -qF 'arg=[feat/parent]' <<<"$FBZ3_OUT" || FBZ3_FAILURES="$FBZ3_FAILURES value-not-its-own-word"
fi
if [ -z "$FBZ3_FAILURES" ]; then
  pass "FBZ-3: PR_BASE_ARGS expands to two separate argv words under zsh"
else
  fail "FBZ-3: base arg does not survive zsh expansion:$FBZ3_FAILURES"
  printf '        out=[%s]\n' "$(printf '%s' "${FBZ3_OUT:-}" | tr '\n' '|')"
fi

# --------------------------------------------------------------------------
# FBT-* (#460) — the Step 5 worktree-teardown block against REAL git
# repositories, under the real fence shell.
#
# The companion tier in tests/finish-branch.test.sh (F13) drives the same block
# through a recording `git` shim and asserts CONTROL FLOW: which verbs ran, in
# which order, which ones did not. It runs on ubuntu AND windows. This tier
# asserts GIT STATE — did the merge actually land, is the worktree really gone
# from the registry and the disk, does the branch still exist — which is the
# only way to catch a block that issues all the right commands against the wrong
# repository. Ubuntu-only, same boundary as
# tests/dispatch-child-worktree-teardown.test.sh.
#
# The four defects this block replaces (each reproduced by an executed probe,
# not inferred): an unchecked `git checkout <base>` that left HEAD on the
# feature branch so the next merge merged the branch into itself and reported
# "Already up to date"; a `git worktree list | grep <current-branch>` probe that
# matched the main checkout's own row in an ordinary clone; the same probe going
# vacuous on a detached HEAD, where `git branch --show-current` prints nothing
# and the pattern becomes the empty string; and a branch delete ordered before
# the worktree removal, which git refuses.
#
# FBT-N1 and FBT-N2 are the negative controls that keep the positives honest.
# --------------------------------------------------------------------------
echo
echo "== FBT: the Step 5 worktree-teardown block against real git repositories (#460) =="

FBT_FAILURES=''
fbt_bad() { FBT_FAILURES="$FBT_FAILURES $1"; }

# Physical work root. git answers --absolute-git-dir, --show-toplevel and the
# worktree listing with symlink-resolved paths, so a fixture rooted at an
# unresolved /var/... would compare unequal to git's /private/var/... on macOS
# and every path assertion below would be testing the symlink, not the block.
FBT_WORK="$(cd "$WORK" && pwd -P)"
FBT_HOME="$FBT_WORK/home"
mkdir -p "$FBT_HOME"

TEARDOWN="$WORK/teardown.zsh"
if ! slice_fence '# --- BEGIN worktree teardown (#460) ---' '# --- END worktree teardown (#460) ---' > "$TEARDOWN"; then
  fail "FBT-0: could not slice the worktree-teardown block from finish-branch/SKILL.md"
  echo "        (anchors: '# --- BEGIN worktree teardown (#460) ---' .. '# --- END worktree teardown (#460) ---')"
  FBT_FAILURES="$FBT_FAILURES block-not-sliceable"
else
  pass "FBT-0: the worktree-teardown block slices cleanly out of a bash fence"
fi

fbt_repo() {  # fbt_repo <name> -> prints the physical repo root
  local nm="$1"
  local rt="$FBT_WORK/$nm"
  mkdir -p "$rt" || return 1
  (
    cd "$rt" || exit 2
    git init -q . || exit 2
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git config commit.gpgsign false
    printf 'base\n' > base.txt
    git add base.txt
    git commit -qm base || exit 2
    git branch -M main || exit 2
  ) >/dev/null 2>&1 || return 1
  printf '%s\n' "$rt"
}

fbt_feature_worktree() {  # fbt_feature_worktree <root> <worktree-path> <branch>
  (
    cd "$1" || exit 2
    git worktree add -q "$2" -b "$3" main || exit 2
    cd "$2" || exit 2
    printf 'feature\n' > feature.txt
    git add feature.txt
    git commit -qm feature || exit 2
  ) >/dev/null 2>&1
}

FBT_OUT=''; FBT_RC=0; FBT_ERR=''
fbt_run() {  # fbt_run <cwd> <env assignments...>
  local rundir="$1"
  shift
  : > "$WORK/fbt.err"
  FBT_OUT="$( cd "$rundir" && env "FB_TEST_COMMAND=" "HOME=$FBT_HOME" "$@" "$ZSH_BIN" -f "$TEARDOWN" 2>"$WORK/fbt.err" )"
  FBT_RC=$?
  FBT_ERR="$(cat "$WORK/fbt.err")"
}

fbt_registered() {  # fbt_registered <root> <worktree-path>  -> rc 0 when listed
  local listing
  listing="$( cd "$1" && git worktree list --porcelain 2>/dev/null )"
  grep -qF "worktree $2" <<<"$listing"
}

fbt_has_branch() {  # fbt_has_branch <root> <branch>
  ( cd "$1" && git rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 )
}

fbt_file_on_main() {  # fbt_file_on_main <root> <path-in-tree>
  local listing
  listing="$( cd "$1" && git ls-tree --name-only main 2>/dev/null )"
  grep -qxF "$2" <<<"$listing"
}

if [ -z "$FBT_FAILURES" ]; then
  # ------------------------------------------------------------------
  # FBT-1 — THE HEADLINE REGRESSION. Main checkout sitting on the base
  # branch, feature work in a linked worktree, teardown launched from that
  # worktree. The shipped prose did `git checkout main` from the worktree
  # (rc 128, HEAD unchanged), then `git merge feat/x` from the feature
  # branch itself: rc 0, "Already up to date." — a merge reported and never
  # performed. The fixed block resolves the main root first and does the
  # work there, so the merge must actually land.
  # ------------------------------------------------------------------
  FBT1_ROOT="$(fbt_repo fbt1)" || fbt_bad 1-fixture
  fbt_feature_worktree "$FBT1_ROOT" "$FBT1_ROOT/.worktrees/feat-x" feat/x || fbt_bad 1-worktree
  fbt_run "$FBT1_ROOT/.worktrees/feat-x" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT1_ROOT/tests-ran"
  [ "$FBT_RC" -eq 0 ] || fbt_bad "1-rc=$FBT_RC"
  fbt_file_on_main "$FBT1_ROOT" feature.txt || fbt_bad 1-merge-never-landed
  [ -f "$FBT1_ROOT/tests-ran" ] || fbt_bad 1-tests-never-ran
  fbt_registered "$FBT1_ROOT" "$FBT1_ROOT/.worktrees/feat-x" && fbt_bad 1-worktree-still-registered
  [ -d "$FBT1_ROOT/.worktrees/feat-x" ] && fbt_bad 1-worktree-dir-survived
  fbt_has_branch "$FBT1_ROOT" feat/x && fbt_bad 1-branch-not-deleted
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-1: from a linked worktree the merge actually LANDS on the base, the worktree is removed and the branch deleted (the old prose reported this merge without performing it)"
  else
    fail "FBT-1: linked-worktree merge path broken:$FBT_FAILURES"
    printf '        stdout=[%s]\n' "$(printf '%s' "$FBT_OUT" | tr '\n' '|')"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT1_FAILURES="$FBT_FAILURES"; FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-2 (P2) — an ORDINARY clone with no linked worktrees must not try to
  # remove anything. The shipped probe matched the main checkout's own row
  # here and the flow went on to `git worktree remove`, which answers
  # "fatal: ... is a main working tree".
  # ------------------------------------------------------------------
  FBT2_ROOT="$(fbt_repo fbt2)" || fbt_bad 2-fixture
  (
    cd "$FBT2_ROOT" || exit 2
    git checkout -q -b feat/plain
    printf 'plain\n' > plain.txt
    git add plain.txt
    git commit -qm plain
  ) >/dev/null 2>&1 || fbt_bad 2-branch
  fbt_run "$FBT2_ROOT" FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT2_ROOT/tests-ran"
  [ "$FBT_RC" -eq 0 ] || fbt_bad "2-rc=$FBT_RC"
  grep -qF 'this is the main checkout' <<<"$FBT_OUT" || fbt_bad 2-main-checkout-not-recognised
  grep -qF 'is a main working tree' <<<"$FBT_ERR" && fbt_bad 2-attempted-to-remove-the-main-worktree
  grep -qF 'Left worktree in place' <<<"$FBT_OUT" && fbt_bad 2-main-checkout-classified-as-a-worktree
  fbt_file_on_main "$FBT2_ROOT" plain.txt || fbt_bad 2-merge-never-landed
  fbt_has_branch "$FBT2_ROOT" feat/plain && fbt_bad 2-branch-not-deleted
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-2: an ordinary clone is recognised as the main checkout — no worktree removal is attempted and the merge still completes"
  else
    fail "FBT-2: plain-clone path broken:$FBT_FAILURES"
    printf '        stdout=[%s]\n' "$(printf '%s' "$FBT_OUT" | tr '\n' '|')"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-3 (P3) — a detached HEAD must refuse. `git branch --show-current`
  # prints nothing there, which turned the shipped probe into a grep for the
  # empty string that matched every row at rc 0.
  # ------------------------------------------------------------------
  FBT3_ROOT="$(fbt_repo fbt3)" || fbt_bad 3-fixture
  fbt_feature_worktree "$FBT3_ROOT" "$FBT3_ROOT/.worktrees/feat-d" feat/d || fbt_bad 3-worktree
  ( cd "$FBT3_ROOT/.worktrees/feat-d" && git checkout -q --detach HEAD ) >/dev/null 2>&1 || fbt_bad 3-detach
  FBT3_MAIN_SHA="$( cd "$FBT3_ROOT" && git rev-parse main )"
  fbt_run "$FBT3_ROOT/.worktrees/feat-d" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT3_ROOT/tests-ran"
  [ "$FBT_RC" -ne 0 ] || fbt_bad 3-detached-head-not-refused
  grep -qF 'detached' <<<"$FBT_ERR" || fbt_bad 3-refusal-does-not-name-the-reason
  [ "$( cd "$FBT3_ROOT" && git rev-parse main )" = "$FBT3_MAIN_SHA" ] || fbt_bad 3-base-was-mutated
  [ -f "$FBT3_ROOT/tests-ran" ] && fbt_bad 3-tests-ran-anyway
  fbt_has_branch "$FBT3_ROOT" feat/d || fbt_bad 3-branch-deleted
  fbt_registered "$FBT3_ROOT" "$FBT3_ROOT/.worktrees/feat-d" || fbt_bad 3-worktree-removed
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-3: a detached HEAD refuses outright — nothing merged, nothing deleted, nothing removed"
  else
    fail "FBT-3: detached-HEAD path broken:$FBT_FAILURES"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-4 — the base branch is checked out by ANOTHER worktree. Refuse before
  # any mutation, and name the holder: this is the state in which the shipped
  # `git checkout main` exited 128 and the next merge silently self-merged.
  # ------------------------------------------------------------------
  FBT4_ROOT="$(fbt_repo fbt4)" || fbt_bad 4-fixture
  ( cd "$FBT4_ROOT" && git checkout -q -b idle ) >/dev/null 2>&1 || fbt_bad 4-idle
  ( cd "$FBT4_ROOT" && git worktree add -q "$FBT4_ROOT/.worktrees/base-holder" main ) >/dev/null 2>&1 || fbt_bad 4-holder
  fbt_feature_worktree "$FBT4_ROOT" "$FBT4_ROOT/.worktrees/feat-b" feat/b || fbt_bad 4-worktree
  FBT4_MAIN_SHA="$( cd "$FBT4_ROOT" && git rev-parse main )"
  fbt_run "$FBT4_ROOT/.worktrees/feat-b" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT4_ROOT/tests-ran"
  [ "$FBT_RC" -ne 0 ] || fbt_bad 4-busy-base-not-refused
  grep -qF "$FBT4_ROOT/.worktrees/base-holder" <<<"$FBT_ERR" || fbt_bad 4-holder-not-named
  [ "$( cd "$FBT4_ROOT" && git rev-parse main )" = "$FBT4_MAIN_SHA" ] || fbt_bad 4-base-was-mutated
  [ -f "$FBT4_ROOT/tests-ran" ] && fbt_bad 4-tests-ran-anyway
  fbt_has_branch "$FBT4_ROOT" feat/b || fbt_bad 4-branch-deleted
  fbt_registered "$FBT4_ROOT" "$FBT4_ROOT/.worktrees/feat-b" || fbt_bad 4-worktree-removed
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-4: a base branch held by another worktree refuses BEFORE any mutation and names the holding path"
  else
    fail "FBT-4: busy-base refusal broken:$FBT_FAILURES"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-5 — a worktree outside every location this project creates is left
  # alone, and the skip says so out loud. Silence here is what the whole
  # issue is about.
  # ------------------------------------------------------------------
  FBT5_ROOT="$(fbt_repo fbt5)" || fbt_bad 5-fixture
  mkdir -p "$FBT_WORK/outside"
  fbt_feature_worktree "$FBT5_ROOT" "$FBT_WORK/outside/feat-y" feat/y || fbt_bad 5-worktree
  fbt_run "$FBT_WORK/outside/feat-y" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT5_ROOT/tests-ran"
  [ "$FBT_RC" -eq 0 ] || fbt_bad "5-rc=$FBT_RC"
  fbt_file_on_main "$FBT5_ROOT" feature.txt || fbt_bad 5-merge-never-landed
  fbt_registered "$FBT5_ROOT" "$FBT_WORK/outside/feat-y" || fbt_bad 5-foreign-worktree-was-removed
  [ -d "$FBT_WORK/outside/feat-y" ] || fbt_bad 5-foreign-worktree-dir-deleted
  grep -qF "$FBT_WORK/outside/feat-y" <<<"$FBT_OUT" || fbt_bad 5-skip-does-not-name-the-path
  grep -qF 'foreign' <<<"$FBT_OUT" || fbt_bad 5-skip-does-not-name-the-reason
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-5: a foreign worktree survives, the merge still lands, and the skip names both the path and the reason"
  else
    fail "FBT-5: foreign-worktree path broken:$FBT_FAILURES"
    printf '        stdout=[%s]\n' "$(printf '%s' "$FBT_OUT" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-6 — .claude/worktrees is the dispatcher lane (lib/dispatch.sh creates
  # it and tears it down). Removing it here would race the dispatcher, so the
  # block must skip it and say why.
  # ------------------------------------------------------------------
  FBT6_ROOT="$(fbt_repo fbt6)" || fbt_bad 6-fixture
  fbt_feature_worktree "$FBT6_ROOT" "$FBT6_ROOT/.claude/worktrees/solve-issue-9" feat/i9 || fbt_bad 6-worktree
  fbt_run "$FBT6_ROOT/.claude/worktrees/solve-issue-9" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT6_ROOT/tests-ran"
  [ "$FBT_RC" -eq 0 ] || fbt_bad "6-rc=$FBT_RC"
  fbt_registered "$FBT6_ROOT" "$FBT6_ROOT/.claude/worktrees/solve-issue-9" || fbt_bad 6-dispatcher-worktree-was-removed
  [ -d "$FBT6_ROOT/.claude/worktrees/solve-issue-9" ] || fbt_bad 6-dispatcher-worktree-dir-deleted
  grep -qF 'dispatcher-owned' <<<"$FBT_OUT" || fbt_bad 6-skip-does-not-name-dispatcher-ownership
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-6: a dispatcher-owned worktree is left for lib/dispatch.sh and the skip names the ownership"
  else
    fail "FBT-6: dispatcher-lane path broken:$FBT_FAILURES"
    printf '        stdout=[%s]\n' "$(printf '%s' "$FBT_OUT" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-7 — merge mode must never destroy uncommitted work. A commit-based
  # merge never carried an untracked file across, so `git worktree remove`
  # runs WITHOUT --force here: the removal fails, the retry behind
  # `git worktree prune` fails too, and the block warns and leaves the tree
  # standing instead of forcing it away. Only Option 4, behind its typed
  # confirmation, gets --force (FBT-8).
  # ------------------------------------------------------------------
  FBT7_ROOT="$(fbt_repo fbt7)" || fbt_bad 7-fixture
  fbt_feature_worktree "$FBT7_ROOT" "$FBT7_ROOT/.worktrees/feat-dirty" feat/dirty || fbt_bad 7-worktree
  printf 'uncommitted\n' > "$FBT7_ROOT/.worktrees/feat-dirty/scratch.txt"
  fbt_run "$FBT7_ROOT/.worktrees/feat-dirty" \
    FB_MODE=merge FB_BASE_BRANCH=main "FB_TEST_COMMAND=touch $FBT7_ROOT/tests-ran"
  [ "$FBT_RC" -eq 0 ] || fbt_bad "7-rc=$FBT_RC"
  fbt_file_on_main "$FBT7_ROOT" feature.txt || fbt_bad 7-merge-never-landed
  [ -f "$FBT7_ROOT/.worktrees/feat-dirty/scratch.txt" ] || fbt_bad 7-uncommitted-work-destroyed
  fbt_registered "$FBT7_ROOT" "$FBT7_ROOT/.worktrees/feat-dirty" || fbt_bad 7-dirty-worktree-removed
  grep -qF 'WARNING' <<<"$FBT_ERR" || fbt_bad 7-failure-not-reported
  grep -qF "$FBT7_ROOT/.worktrees/feat-dirty" <<<"$FBT_ERR" || fbt_bad 7-warning-does-not-name-the-path
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-7: merge mode leaves a dirty worktree standing, keeps the uncommitted file, and warns with the path"
  else
    fail "FBT-7: dirty-worktree handling broken:$FBT_FAILURES"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-8 — discard mode: no pull, no merge, no test run; the worktree goes
  # first (with --force, authorised by the typed confirmation in Option 4)
  # and only then the branch, because git refuses to delete a branch a live
  # worktree still holds.
  # ------------------------------------------------------------------
  FBT8_ROOT="$(fbt_repo fbt8)" || fbt_bad 8-fixture
  fbt_feature_worktree "$FBT8_ROOT" "$FBT8_ROOT/.worktrees/feat-z" feat/z || fbt_bad 8-worktree
  FBT8_MAIN_SHA="$( cd "$FBT8_ROOT" && git rev-parse main )"
  fbt_run "$FBT8_ROOT/.worktrees/feat-z" FB_MODE=discard FB_BASE_BRANCH=main
  [ "$FBT_RC" -eq 0 ] || fbt_bad "8-rc=$FBT_RC"
  [ "$( cd "$FBT8_ROOT" && git rev-parse main )" = "$FBT8_MAIN_SHA" ] || fbt_bad 8-discard-merged-anyway
  fbt_registered "$FBT8_ROOT" "$FBT8_ROOT/.worktrees/feat-z" && fbt_bad 8-worktree-still-registered
  [ -d "$FBT8_ROOT/.worktrees/feat-z" ] && fbt_bad 8-worktree-dir-survived
  fbt_has_branch "$FBT8_ROOT" feat/z && fbt_bad 8-branch-not-force-deleted
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-8: discard mode force-removes the worktree and force-deletes an unmerged branch without touching the base"
  else
    fail "FBT-8: discard path broken:$FBT_FAILURES"
    printf '        stderr=[%s]\n' "$(printf '%s' "$FBT_ERR" | tr '\n' '|')"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-N1 — NEGATIVE CONTROL for FBT-2 and FBT-3. Run the RETIRED probe
  # (`git worktree list | grep <current-branch>`) against the very same two
  # fixtures and prove it answers "yes, you are in a removable worktree" in
  # both. Without this, FBT-2 and FBT-3 could be passing because git changed,
  # not because the block did.
  # ------------------------------------------------------------------
  FBTN1_PLAIN="$( cd "$FBT2_ROOT" && git worktree list 2>/dev/null | grep -c "$( git branch --show-current 2>/dev/null )" )"
  FBTN1_DETACHED="$( cd "$FBT3_ROOT/.worktrees/feat-d" && git worktree list 2>/dev/null | grep -c "$( git branch --show-current 2>/dev/null )" )"
  [ "${FBTN1_PLAIN:-0}" -ge 1 ] || fbt_bad n1-plain-clone-no-longer-false-positives
  [ "${FBTN1_DETACHED:-0}" -ge 2 ] || fbt_bad n1-detached-head-no-longer-matches-every-row
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-N1: the retired grep probe still false-positives in the FBT-2 and FBT-3 fixtures (so FBT-2/FBT-3 assert the fix, not shell luck)"
  else
    fail "FBT-N1: negative control did not reproduce the old defect:$FBT_FAILURES (plain=$FBTN1_PLAIN detached=$FBTN1_DETACHED)"
  fi
  FBT_FAILURES=''

  # ------------------------------------------------------------------
  # FBT-N2 — NEGATIVE CONTROL for the `cd … && pwd -P` normalization of
  # --git-common-dir. The reason that normalization exists is NOT symlinks:
  # git already answers --absolute-git-dir, --show-toplevel and the worktree
  # listing with physical paths (verified). It is that in an ORDINARY clone
  # --git-common-dir answers the RELATIVE string `.git`, so comparing it
  # unnormalized against the absolute --absolute-git-dir makes every ordinary
  # clone report itself a linked worktree.
  #
  # This control runs a copy of the block with the normalization dropped
  # against the FBT-2 plain-clone fixture and proves the verdict flips: the
  # main checkout is reported as a foreign worktree that was deliberately left
  # in place. A wrong provenance verdict printed at the operator is precisely
  # the defect class this issue is about.
  #
  # The shim tier in finish-branch.test.sh CANNOT catch this — it always hands
  # the block an absolute common dir — which is why the control lives here.
  # ------------------------------------------------------------------
  # Line-wise rewrite rather than a sed s|||, whose delimiter would collide with
  # the `||` in the production line. The mutation is verified to have applied
  # before the control runs, so this can never silently degrade into a rerun of
  # the correct block. awk field refs are parameterised (-v c0=0) to match the
  # repo-wide renderer-collision convention.
  FBTN2_BLOCK="$WORK/teardown-unnormalized.zsh"
  awk -v c0=0 'index($c0, "fb_common=\"$(cd \"$fb_common_raw\"") > 0 { print "  fb_common=\"$fb_common_raw\""; next } { print }' \
    "$TEARDOWN" > "$FBTN2_BLOCK"
  grep -qF 'fb_common="$fb_common_raw"' "$FBTN2_BLOCK" || fbt_bad n2-mutation-not-applied
  grep -qF 'pwd -P)" || fb_common=""' "$FBTN2_BLOCK" && fbt_bad n2-original-line-survived-the-mutation
  FBTN2_ROOT="$(fbt_repo fbtn2)" || fbt_bad n2-fixture
  (
    cd "$FBTN2_ROOT" || exit 2
    git checkout -q -b feat/n2
    printf 'n2\n' > n2.txt
    git add n2.txt
    git commit -qm n2
  ) >/dev/null 2>&1 || fbt_bad n2-branch
  FBTN2_OUT="$( cd "$FBTN2_ROOT" && env "HOME=$FBT_HOME" FB_MODE=merge FB_BASE_BRANCH=main \
      "FB_TEST_COMMAND=touch $FBTN2_ROOT/tests-ran" "$ZSH_BIN" -f "$FBTN2_BLOCK" 2>/dev/null )"
  grep -qF 'Left worktree in place' <<<"$FBTN2_OUT" || fbt_bad n2-unnormalized-copy-did-not-misclassify
  grep -qF 'this is the main checkout' <<<"$FBTN2_OUT" && fbt_bad n2-unnormalized-copy-behaved-correctly
  if [ -z "$FBT_FAILURES" ]; then
    pass "FBT-N2: dropping the common-dir normalization makes an ordinary clone report itself a linked worktree (so the normalization is load-bearing, not decoration)"
  else
    fail "FBT-N2: normalization control broken:$FBT_FAILURES"
    printf '        out=[%s]\n' "$(printf '%s' "$FBTN2_OUT" | tr '\n' '|')"
  fi
fi

echo
echo "== Summary =="
echo "  launcher: $LAUNCH_SHELL  (composer ran under: $ZSH_BIN)"
echo "  passed: $PASS"
echo "  failed: $FAIL"

[ "$FAIL" -eq 0 ]

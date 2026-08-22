#!/usr/bin/env bash
# tests/premerge-phase5.test.sh — BEHAVIOUR gates for /premerge's repo-agnostic
# seams (RFC 0021). Unix-only: it builds throwaway git repos under mktemp -d and
# executes fence bodies extracted from the shipped SKILL.md.
#
# This file exists because tests/premerge.test.sh can only prove the fences are
# SPELLED right, and the first draft of those gates proved exactly how little
# that is worth: every row was satisfiable by prose, so a Phase 5 that had
# stopped bumping altogether passed 6/6. The properties that matter here are
# observable only by running the code:
#
#   B1  a repo without the version ratchet SKIPS the bump and exits 0
#   B2  the UberDev-shaped repo does NOT skip, and the bump moves every surface
#   B3  the apply fence's probe is reachable with PREMERGE_NEXT unset — the one
#       state it was added to cover
#   B4  the ignore policy makes a foreign repo pass Phase 0b's cleanliness gate
#   B5  a pre-existing NON-COVERING policy is refused here, loudly, instead of
#       wedging five fences later as "the working tree is not clean"
#   B6  the policy does not blanket the repo's own .uberdev config root
#
# Every case runs bytes EXTRACTED from SKILL.md. Nothing here is a transcription
# of the shipped logic: a test that executes its own copy of the code is green
# forever, whatever the shipped copy grows into.

# ci-wiring: declared Unix-only in the test.yml windows-skip-list.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/SKILL.md"
CONSOLIDATE="$REPO_ROOT/plugins/uberdev/lib/review-consolidate.sh"
BUMP="$REPO_ROOT/plugins/uberdev/lib/bump-version.sh"
MANIFEST='plugins/uberdev/.claude-plugin/plugin.json'

for f in "$SKILL" "$CONSOLIDATE" "$BUMP"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required by ${0##*/}" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

# --- extraction --------------------------------------------------------------
# fence_body TAG -> the body of the ```bash uberdev-executable origin=TAG fence.
fence_body() {
  awk -v tag="$1" '
    index($0, "```bash uberdev-executable origin=" tag) == 1 { inf = 1; next }
    inf && index($0, "```") == 1 { exit }
    inf { print }
  ' "$SKILL"
}

# block_of TAG START MARK -> the slice of that fence from the first line
# containing START through the first bare `fi` at or after the line containing
# MARK. The MARK is what makes the region's own inner if/fi stop truncating it —
# extracting to the FIRST `fi` silently dropped the verification and made the
# case that depends on it vacuous. Used where a fence also does work this test
# cannot stand up (gh, a real combine).
block_of() {
  fence_body "$1" | awk -v s="$2" -v m="$3" '
    !inb && index($0, s) { inb = 1 }
    inb { print }
    inb && index($0, m) { seen = 1 }
    inb && seen && $0 == "fi" { exit }
  '
}

POLICY_BLOCK="$(block_of premerge-scan 'PREMERGE_RUN_DIR="$UBERDEV_PREMERGE_ROOT/.uberdev/premerge/$RUN_ID"' 'check-ignore')"
BUMP_FENCE="$(fence_body premerge-bump)"
APPLY_FENCE="$(fence_body premerge-bump-apply)"

echo "== extraction pre-flight =="
# An empty extraction would make every case below vacuously green.
for pair in "policy-block:$POLICY_BLOCK" "bump-fence:$BUMP_FENCE" "apply-fence:$APPLY_FENCE"; do
  if [ -n "${pair#*:}" ]; then ok "extracted ${pair%%:*} non-empty"
  else bad "extracted ${pair%%:*} EMPTY — an anchor moved; every case below would be meaningless"; fi
done
# The policy block must actually reach the verification, or B5 proves nothing.
case "$POLICY_BLOCK" in
  *check-ignore*) ok "the policy block includes the check-ignore verification" ;;
  *)              bad "the policy block stops before check-ignore — B5 would be vacuous" ;;
esac

# --- fixtures ----------------------------------------------------------------
new_repo() {  # new_repo NAME -> path of a fresh committed git repo
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q .
  git -C "$d" config user.email premerge-test@example.invalid
  git -C "$d" config user.name "premerge test"
  printf 'x\n' >"$d/README.md"
  git -C "$d" add README.md >/dev/null
  git -C "$d" commit -qm init
  printf '%s' "$d"
}

uberdev_repo() {  # a repo carrying all six version surfaces at the real version
  local d; d="$(new_repo "$1")"
  local f
  for f in "$MANIFEST" .claude-plugin/marketplace.json README.md CHANGELOG.md \
           tests/goal.test.sh tests/solve-claim.test.sh; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$d/$f"
  done
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm surfaces
  printf '%s' "$d"
}

run_policy_block() {  # run_policy_block REPO -> exit code; stderr on fd 2
  ( cd "$1" && UBERDEV_PREMERGE_ROOT="$1" RUN_ID=20260822-010203-abc123 \
      bash -c "set -u; $POLICY_BLOCK
               printf '{}\\n' >\"\$PREMERGE_RUN_DIR/manifest.json\"" )
}

echo "== B1: a repo without the version ratchet skips the bump =="
FOREIGN="$(new_repo foreign)"
OUT="$( cd "$FOREIGN" && RUN_ID=20260822-010203-abc123 \
        PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
        bash -c "set -u; $BUMP_FENCE" 2>&1 )"; RC=$?
check "$RC" 0 "B1: the bump fence exits 0 in a foreign repo"
case "$OUT" in
  *"BUMP=skipped REASON=no-version-ratchet"*) ok "B1: it reports the typed skip reason" ;;
  *) bad "B1: expected the typed skip, got: $OUT" ;;
esac

echo "== B2: an UberDev-shaped repo does not skip, and --repo-root bumps it =="
UD="$(uberdev_repo uberdevlike)"
UD_RUN="$UD/.uberdev/premerge/20260822-010203-abc123"
mkdir -p "$UD_RUN"
printf 'main\n' >"$UD_RUN/combine-base.txt"
git -C "$UD" update-ref refs/remotes/origin/main "$(git -C "$UD" rev-parse HEAD)"
git -C "$UD" checkout -q -b chore/stack-20260822-010203-abc123
printf 'y\n' >"$UD/feature.txt"
git -C "$UD" add feature.txt >/dev/null
git -C "$UD" commit -qm "feat(x): add a feature so the class is minor, not patch"
printf 'chore/stack-20260822-010203-abc123\n' >"$UD_RUN/combine-branch.txt"
OUT="$( cd "$UD" && RUN_ID=20260822-010203-abc123 \
        PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
        bash -c "set -u; $BUMP_FENCE" 2>&1 )"
case "$OUT" in
  *no-version-ratchet*) bad "B2: the ratchet repo was wrongly skipped" ;;
  *BUMP_CLASS=minor*)   ok  "B2: the ratchet repo proceeds and derives the class from the commits" ;;
  *)                    bad "B2: expected a BUMP_CLASS, got: $OUT" ;;
esac
# The apply fence, for real, against that repo. This is the case that was broken
# in the shipped v0.53.0: without --repo-root, bump-version.sh resolves into the
# plugin cache and exits 3, aborting Phase 5 in EVERY repo including this one.
CUR="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$UD/$MANIFEST" | sed -n 1p)"
NEXT="${CUR%.*}.$(( ${CUR##*.} + 1 ))"
OUT="$( cd "$UD" && RUN_ID=20260822-010203-abc123 PREMERGE_NEXT="$NEXT" \
        PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
        bash -c "set -u; $APPLY_FENCE" 2>&1 )"; RC=$?
check "$RC" 0 "B2: the apply fence succeeds against a real checkout"
MISSED=""
grep -qF "\"version\": \"$NEXT\"" "$UD/$MANIFEST"                        || MISSED="$MISSED plugin.json"
grep -qF "$NEXT" "$UD/.claude-plugin/marketplace.json"                   || MISSED="$MISSED marketplace.json"
grep -qF "version-$NEXT-blue" "$UD/README.md"                            || MISSED="$MISSED README"
grep -qF "## [$NEXT]" "$UD/CHANGELOG.md"                                 || MISSED="$MISSED CHANGELOG"
grep -qF "version bump locked ($NEXT)" "$UD/tests/goal.test.sh"          || MISSED="$MISSED goal-lock"
grep -qF "$CUR -> $NEXT" "$UD/tests/solve-claim.test.sh"                 || MISSED="$MISSED solve-claim-lock"
if [ -z "$MISSED" ]; then ok "B2: all six version surfaces moved $CUR -> $NEXT"
else bad "B2: surfaces not bumped:$MISSED (out: $OUT)"; fi

echo "== B3: the apply-fence probe is reachable with PREMERGE_NEXT unset =="
# A run that skipped 5a never produced a BUMP_CLASS, so the orchestrator has no
# PREMERGE_NEXT to prefix. If the probe sits below `${PREMERGE_NEXT:?}` the fence
# dies there instead of skipping — in the one state the probe exists to cover.
OUT="$( cd "$FOREIGN" && env -u PREMERGE_NEXT RUN_ID=20260822-010203-abc123 \
        PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
        bash -c "set -u; $APPLY_FENCE" 2>&1 )"; RC=$?
check "$RC" 0 "B3: the apply fence exits 0 rather than dying on the unset variable"
case "$OUT" in
  *"BUMP=skipped REASON=no-version-ratchet"*) ok "B3: it reports the typed skip" ;;
  *PREMERGE_NEXT*) bad "B3: the fence died on PREMERGE_NEXT before reaching the probe" ;;
  *) bad "B3: expected the typed skip, got: $OUT" ;;
esac

echo "== B4: the ignore policy carries a foreign repo through Phase 0b =="
CLEAN="$(new_repo cleanfixture)"
run_policy_block "$CLEAN" >/dev/null 2>&1; RC=$?
check "$RC" 0 "B4: the policy block succeeds in a repo that does not ignore .uberdev/"
# Phase 0b's real gate, from the shipped library.
( . "$CONSOLIDATE" >/dev/null 2>&1
  review_consolidate_preflight "$CLEAN" "$CLEAN/.uberdev/premerge/20260822-010203-abc123" >/dev/null 2>&1 )
check "$?" 0 "B4: review_consolidate_preflight then passes"
# Anti-vacuity: the same gate must REFUSE without the policy, or B4 proves only
# that this repo happened to be clean already.
BARE="$(new_repo barefixture)"
mkdir -p "$BARE/.uberdev/premerge/20260822-010203-abc123"
# git never reports an EMPTY untracked directory, so the control needs content.
printf '{}\n' >"$BARE/.uberdev/premerge/20260822-010203-abc123/manifest.json"
( . "$CONSOLIDATE" >/dev/null 2>&1
  review_consolidate_preflight "$BARE" "$BARE/.uberdev/premerge/20260822-010203-abc123" >/dev/null 2>&1 )
if [ "$?" -eq 0 ]; then bad "B4: the gate passed WITHOUT the policy — B4 is vacuous"
else ok "B4: the gate refuses without the policy (the policy is load-bearing)"; fi

echo "== B5: a pre-existing non-covering policy is refused here, not five fences later =="
for residue in empty selective; do
  R="$(new_repo "residue-$residue")"
  mkdir -p "$R/.uberdev/premerge"
  case "$residue" in
    empty)     : >"$R/.uberdev/premerge/.gitignore" ;;
    selective) printf 'audit.jsonl\n' >"$R/.uberdev/premerge/.gitignore" ;;
  esac
  OUT="$(run_policy_block "$R" 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ]; then
    bad "B5/$residue: the block accepted a policy that does not cover the run dir"
  else
    ok "B5/$residue: refused (exit $RC)"
    case "$OUT" in
      *".uberdev/premerge/.gitignore"*) ok "B5/$residue: the refusal names the policy file" ;;
      *) bad "B5/$residue: the refusal does not name the policy file: $OUT" ;;
    esac
  fi
done

echo "== B6: the policy does not blanket the repo's own .uberdev config root =="
# .uberdev/ is the documented per-repo config root (.uberdev/config.yaml, RFC
# 0006; .uberdev/config.json, RFC 0007). A `*` published one level up would
# permanently un-add a repository's own committed config.
CFG="$(new_repo configfixture)"
mkdir -p "$CFG/.uberdev"
printf 'prod_url_patterns: []\n' >"$CFG/.uberdev/config.yaml"
git -C "$CFG" add .uberdev/config.yaml >/dev/null 2>&1
git -C "$CFG" commit -qm config
run_policy_block "$CFG" >/dev/null 2>&1
printf 'prod_url_patterns: [x]\n' >"$CFG/.uberdev/config2.yaml"
if git -C "$CFG" add .uberdev/config2.yaml >/dev/null 2>&1; then
  ok "B6: a new .uberdev config file is still addable after the policy"
else
  bad "B6: the policy has made the repo's own .uberdev config root unaddable"
fi
if git -C "$CFG" check-ignore -q .uberdev/config.yaml; then
  bad "B6: the policy now ignores the repo's committed .uberdev/config.yaml"
else
  ok "B6: the committed config file is untouched by the policy"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

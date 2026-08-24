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
#   B7  the `--converge` upper bound is EXECUTED — the shipped argument parser
#       accepts the library's CONVERGE_REPAIR_CEILING and refuses one past it,
#       so raising the library value reds until the fence follows (#724)
#   B8  the Phase 5-trail decision fence emits NOTHING when the loop did not stop
#       green, when the attempt's gate file is missing, when its verdict/rc is
#       not green, when the JSON is unreadable, and when HEAD moved after the
#       gate — five refusals, each with its own typed reason, each exiting 0
#   B9  and it prints TRAIL=emit for the one state that earns it, so B8 is not
#       vacuously green over a fence that refuses everything (#716)
#   B10 the PUBLICATION fence publishes nothing on TRAIL=skipped — no commit, no
#       push, no gh call — proved by a recording git/gh shim rather than by the
#       absence of an error, with a real emit run as the control that shows the
#       shim can see a call at all (#716)
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
LIB="$REPO_ROOT/plugins/uberdev/lib/premerge-findings.py"
MANIFEST='plugins/uberdev/.claude-plugin/plugin.json'

for f in "$SKILL" "$CONSOLIDATE" "$BUMP" "$LIB"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required by ${0##*/}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required by ${0##*/}" >&2; exit 2; }

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

echo "== B7: the --converge ceiling is EXECUTED against the library's constant =="
# #724. Four copies of this number exist: lib/premerge-findings.py's
# CONVERGE_REPAIR_CEILING (the enforcer), the SKILL's Constants row, the argument
# fence's `-gt` condition, and the refusal message. tests/premerge-findings.test.sh
# B15b compares the Constants row and the refusal message against the evaluated
# constant by reading bytes (and commands/premerge.md's prose besides), but
# NOTHING read the condition -- so raising the library value left the suite green
# while the fence still refused the new top of the range with a message promising
# it.
#
# So this case RUNS the shipped condition. ARG_BLOCK is the premerge-scan fence
# sliced to its argument parser -- from the first default assignment through the
# heredoc that feeds the loop -- which is exactly the part that can execute
# without a repo, a run dir or gh: every refusal in the parser exits before the
# fence reaches `git rev-parse --show-toplevel`. Nothing here transcribes the
# condition; a test that executes its own copy of the code is green forever.
#
# THE SLICE IS BOUNDED AT BOTH ENDS, and that is the safety property, not tidiness
# -- the premise above holds for the PARSER and for nothing past it. Two anchors
# choose what runs, and when the closing one stops matching the slice keeps
# growing into fences that make branches, write run dirs and call gh.
#
# The first draft bounded it below only. Renaming the terminator to `EOF_ARGS` in
# a scratch copy grew the slice from 67 lines to 167 with BOTH guards still
# passing (a floor cannot see growth, and the `-gt` bound is still inside the
# wider slice), and `run_converge` then ran that widened slice against the
# LAUNCHING CWD. Every call the parser does not refuse -- two of the three tokens
# this case tries, since `--converge=7` exits at the range check having written
# nothing -- ran on past the parser into the fence's setup: it created
# `.uberdev/premerge/`, wrote a `.gitignore` of `*` and a run dir holding a
# `discovery-audit.jsonl`, and only then died on
# `UBERDEV_PREMERGE_PLUGIN_ROOT: unbound variable`. Which is the shape of the
# hazard rather than a detail of it: the further a call gets, the more it leaves
# behind. Measured in a throwaway repo, not imagined (#724).
#
# So: the extractor PROVES it reached the terminator (awk exits 3 when it never
# does, which also covers the opening anchor moving -- no anchor, no terminator),
# the line count is a BAND and not a floor, and nothing is EXECUTED unless both
# hold. A renamed terminator now reds here, saying that, before anything runs.
arg_block() {  # arg_block -> the slice on stdout; rc 3 if the terminator was never reached
  fence_body premerge-scan | awk '
    !inb && index($0, "PREMERGE_LEVEL=xhigh") == 1 { inb = 1 }
    inb { print }
    inb && $0 == "EOF_PREMERGE_ARGS" { hit = 1; exit }
    END { if (!hit) exit 3 }
  '
}
ARG_BLOCK="$(arg_block)"; ARG_BLOCK_RC=$?
ARG_BLOCK_LINES="$(grep -c . <<<"$ARG_BLOCK")"
ARG_BLOCK_OK=1
if [ "$ARG_BLOCK_RC" -eq 0 ]; then
  ok "B7: the slice ends where the parser does, at EOF_PREMERGE_ARGS"
else
  ARG_BLOCK_OK=0
  bad "B7: the slice never reached EOF_PREMERGE_ARGS (awk rc=$ARG_BLOCK_RC) -- the terminator moved or was renamed, so the slice is unbounded and will NOT be run"
fi
# The upper end is loose on purpose: the parser legitimately grew 61 -> 67 lines
# while #724 was being written. This is a guard against a slice that ran away,
# never a line-count lock on a file people are expected to edit.
if [ "$ARG_BLOCK_LINES" -ge 40 ] && [ "$ARG_BLOCK_LINES" -le 110 ]; then
  ok "B7: extracted $ARG_BLOCK_LINES lines of argument parser"
else
  ARG_BLOCK_OK=0
  bad "B7: the argument-parser slice yielded $ARG_BLOCK_LINES lines, outside the 40..110 band -- an anchor moved; every row below would be meaningless"
fi
case "$ARG_BLOCK" in
  *"PREMERGE_CONVERGE_ARG\" -gt "*) ok "B7: the slice contains the bound it is here to execute" ;;
  *) bad "B7: the slice does not contain the --converge bound -- the parser moved" ;;
esac

# EVALUATE the library's ceiling, never parse it: the constant may be built by any
# expression, and tests/premerge.test.sh P3b states that rule for this repo.
CEILING="$(python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pmf", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.CONVERGE_REPAIR_CEILING)
' "$LIB")"
case "$CEILING" in
  ''|*[!0-9]*) bad "B7: could not evaluate CONVERGE_REPAIR_CEILING from $LIB (got '$CEILING')"; CEILING="" ;;
  *)           ok "B7: the library's enforced ceiling evaluates to $CEILING" ;;
esac

# The block is interpolated as a VALUE into the bash -c program text; a variable
# expansion is not re-scanned for command substitution, so the parser's own
# `$( ... | tr ... )` heredoc runs in the CHILD, which is the point.
run_converge() {  # run_converge <token> -> child's rc; output on stdout
  ARGUMENTS="$1" bash -c "set -u
$ARG_BLOCK
printf 'PARSED CONVERGE=%s\n' \"\$PREMERGE_CONVERGE\"" 2>&1
}

if [ "$ARG_BLOCK_OK" != 1 ]; then
  # Not a stand-down that hides anything: the FAIL above has already reddened the
  # file, and refusing to run an unbounded slice is the point of measuring it.
  echo "  ----  B7: the slice is not bounded (see the FAIL above) -- NOT executing it"
elif [ -n "$CEILING" ]; then
  OUT="$(run_converge "--converge=$CEILING")"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "PARSED CONVERGE=$CEILING" ]; then
    ok "B7: --converge=$CEILING (the library's ceiling) is ACCEPTED by the fence"
  else
    bad "B7: the fence refuses the ceiling the library enforces (rc=$RC): $OUT"
  fi

  OUT="$(run_converge "--converge=$((CEILING + 1))")"; RC=$?
  if [ "$RC" -eq 0 ]; then
    bad "B7: the fence ACCEPTED --converge=$((CEILING + 1)), one past the library's ceiling: $OUT"
  else
    ok "B7: --converge=$((CEILING + 1)) is refused (exit $RC)"
    case "$OUT" in
      *"1..$CEILING"*) ok "B7: and the refusal names the range the library enforces" ;;
      *)               bad "B7: the refusal does not say 1..$CEILING: $OUT" ;;
    esac
  fi

  # Anti-vacuity on the low end: a parser that refused everything would satisfy
  # the refusal row above for entirely the wrong reason.
  OUT="$(run_converge "--converge=1")"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "PARSED CONVERGE=1" ]; then
    ok "B7: --converge=1 still parses -- the refusal is bounded, not blanket"
  else
    bad "B7: --converge=1 was refused (rc=$RC): $OUT"
  fi
fi

# --- Phase 5-trail: the emission gate, EXECUTED (#716) -----------------------
# AC1 is "a trail is emitted ONLY on a green gate", which is a claim about the
# five states that must emit NOTHING. Every one of them is satisfiable by prose,
# so the whole point of putting the decision in its own fence — no git write, no
# network — was to make it runnable here against a throwaway repo. These cases
# run the SHIPPED bytes: nothing below transcribes the fence.
#
# Run under bash AND zsh. The fences reach the runtime through the Bash tool,
# which is /bin/zsh on the maintainer's machine, and this repo has a standing
# class of bugs visible only there (`for x in $SCALAR` iterating once over the
# whole string; a `local path=` colliding with the tied PATH array).
TRAIL_GATE_FENCE="$(fence_body premerge-trail-gate)"
TRAIL_EMIT_FENCE="$(fence_body premerge-trail-emit)"
TRAIL_GATE_LINES="$(grep -c . <<<"$TRAIL_GATE_FENCE")"
TRAIL_EMIT_LINES="$(grep -c . <<<"$TRAIL_EMIT_FENCE")"
TRAIL_RUN_ID=20260824-111213-deadbe
TRAIL_BRANCH="chore/stack-$TRAIL_RUN_ID"
TRAIL_PR=4242
TRAIL_REAL_GIT="$(command -v git)"

echo
echo "== B8/B9/B10 pre-flight: both trail fences extracted, and split as designed =="
# A floor, not a band: unlike B7's slice these bodies are bounded at BOTH ends by
# the fence markers themselves, so they cannot run away into a neighbouring
# fence. What a floor is here to catch is the extraction yielding nothing at all
# — which would pass every `case` below for the wrong reason.
if [ "$TRAIL_GATE_LINES" -ge 20 ]; then
  ok "pre-flight: the gate fence extracted $TRAIL_GATE_LINES non-blank lines"
else
  bad "pre-flight: the gate fence extracted $TRAIL_GATE_LINES non-blank lines (want >= 20) — the origin= tag moved; every B8/B9 row would be meaningless"
fi
if [ "$TRAIL_EMIT_LINES" -ge 20 ]; then
  ok "pre-flight: the emit fence extracted $TRAIL_EMIT_LINES non-blank lines"
else
  bad "pre-flight: the emit fence extracted $TRAIL_EMIT_LINES non-blank lines (want >= 20) — the origin= tag moved; every B10 row would be meaningless"
fi
# The split is what makes B8 runnable at all: a single fence that pushed and
# called gh could only ever be grep-proved. So assert the DECISION half stays a
# decision. This is a structural row about a different property; the emission
# behaviour itself is executed below, never asserted as text.
case "$TRAIL_GATE_FENCE" in
  *"git push"*|*"gh "*) bad "pre-flight: the decision fence has grown a git push or a gh call — it can no longer be executed here, and AC1 falls back to being grep-only" ;;
  *)                    ok "pre-flight: the decision fence still writes nothing and calls nothing remote" ;;
esac

# trail_repo NAME -> a fresh committed repo carrying an empty premerge run dir
trail_repo() {
  local d; d="$(new_repo "$1")"
  mkdir -p "$d/.uberdev/premerge/$TRAIL_RUN_ID"
  printf '%s' "$d"
}

# trail_gate_file REPO ATTEMPT_PAD VERDICT RC HEAD_SHA -> writes gate-NN.json
trail_gate_file() {
  printf '{"verdict":"%s","rc":%s,"head_sha":"%s"}\n' "$3" "$4" "$5" \
    >"$1/.uberdev/premerge/$TRAIL_RUN_ID/gate-$2.json"
}

# run_trail_gate SHELL REPO STOP ATTEMPT -> merged output on stdout, rc in $?.
# Merged, because every line this fence prints goes to stderr on purpose.
run_trail_gate() {
  local sh="$1" repo="$2" stop="$3" attempt="$4"
  case "$sh" in
    # -f so a developer's ~/.zshenv cannot change the answer. No array: bash 3.2
    # is still the /bin/bash on macOS and this stays inside the POSIX subset.
    zsh) set -- zsh -f -c ;;
    *)   set -- bash -c ;;
  esac
  ( cd "$repo" \
    && RUN_ID="$TRAIL_RUN_ID" PREMERGE_ATTEMPT="$attempt" PREMERGE_STOP="$stop" \
       "$@" "$TRAIL_GATE_FENCE" ) 2>&1
}

# trail_refusal SHELL LABEL EXPECT REPO STOP ATTEMPT
trail_refusal() {
  local sh="$1" label="$2" expect="$3" repo="$4" stop="$5" attempt="$6"
  local out rc
  out="$(run_trail_gate "$sh" "$repo" "$stop" "$attempt")"; rc=$?
  case "$out" in
    *"$expect"*) ok "$label [$sh]: $expect" ;;
    *)           bad "$label [$sh]: expected '$expect', got: $out" ;;
  esac
  # A refusal to emit is an ordinary outcome the run parks past, not a fence
  # failure — a non-zero here would abort Phase 5 on every not-green stack.
  check "$rc" 0 "$label [$sh]: exits 0"
}

# trail_stack_repo NAME -> a repo with a real (bare, local) origin, the stack
# branch checked out over one commit of work, and the three run-dir files the
# publication fence reads. Local bare remote so the push is real and offline.
trail_stack_repo() {
  local d="$WORK/$1"
  rm -rf "$d" "$d.git"
  git init -q --bare "$d.git"
  mkdir -p "$d"
  git -C "$d" init -q .
  git -C "$d" config user.email premerge-test@example.invalid
  git -C "$d" config user.name "premerge test"
  git -C "$d" remote add origin "$d.git"
  printf 'x\n' >"$d/README.md"
  git -C "$d" add README.md >/dev/null
  git -C "$d" commit -qm init
  git -C "$d" branch -M main
  git -C "$d" push -q -u origin main
  git -C "$d" checkout -q -b "$TRAIL_BRANCH"
  printf 'y\n' >"$d/stacked.txt"
  git -C "$d" add stacked.txt >/dev/null
  git -C "$d" commit -qm "feat(x): the stacked work a trail would describe"
  mkdir -p "$d/.uberdev/premerge/$TRAIL_RUN_ID"
  printf '{"combined_pr":%s}\n' "$TRAIL_PR" >"$d/.uberdev/premerge/$TRAIL_RUN_ID/manifest.json"
  printf '%s\n' "$TRAIL_BRANCH" >"$d/.uberdev/premerge/$TRAIL_RUN_ID/combine-branch.txt"
  printf 'main\n' >"$d/.uberdev/premerge/$TRAIL_RUN_ID/combine-base.txt"
  printf '%s' "$d"
}

# trail_shims DIR -> a PATH prefix whose `git` records every call before running
# the real one, and whose `gh` records and returns without a network.
# "Published nothing" is a claim about calls that were NEVER MADE, and the only
# honest way to prove one is to record every call and find the log empty. An
# unchanged HEAD would not do it: a fence that pushed a stale ref or edited a
# label leaves HEAD exactly where it was.
trail_shims() {
  local s="$1"
  rm -rf "$s"; mkdir -p "$s"
  cat >"$s/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$s/git.log'
exec '$TRAIL_REAL_GIT' "\$@"
EOF
  cat >"$s/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$s/gh.log'
exit 0
EOF
  chmod +x "$s/git" "$s/gh"
  : >"$s/git.log"; : >"$s/gh.log"
}

# run_trail_emit SHELL REPO SHIMDIR TRAIL ATTEMPT -> merged output, rc in $?
run_trail_emit() {
  local sh="$1" repo="$2" shim="$3" trail="$4" attempt="$5"
  case "$sh" in
    zsh) set -- zsh -f -c ;;
    *)   set -- bash -c ;;
  esac
  ( cd "$repo" \
    && PATH="$shim:$PATH" RUN_ID="$TRAIL_RUN_ID" PREMERGE_TRAIL="$trail" \
       PREMERGE_TRAIL_ATTEMPT="$attempt" "$@" "$TRAIL_EMIT_FENCE" ) 2>&1
}

for TSH in bash zsh; do
  if [ "$TSH" = zsh ] && ! command -v zsh >/dev/null 2>&1; then
    echo "  ----  B8/B9/B10: zsh is not on PATH — the zsh half is not run"
    continue
  fi

  echo
  echo "== B8 [$TSH]: the trail gate emits NOTHING unless every condition holds =="
  # 1. The loop did not stop green. The gate file below is otherwise PERFECT —
  #    green, rc 0, bound to this very HEAD — so the only thing refusing is the
  #    stop token, which is the whole claim.
  R="$(trail_repo "trail-$TSH-stop")"
  trail_gate_file "$R" 02 green 0 "$(git -C "$R" rev-parse HEAD)"
  trail_refusal "$TSH" B8.stop "TRAIL=skipped REASON=stop_not_green" "$R" STOP_NO_PROGRESS 2

  # 2. Stopped green, but this attempt left no gate file. `.uberdev/` is
  #    gitignored and a fresh clone has none, so absence is a live state.
  R="$(trail_repo "trail-$TSH-nogate")"
  trail_refusal "$TSH" B8.nogate "TRAIL=skipped REASON=gate_unreadable" "$R" STOP_GREEN 2

  # 3. Stopped green, gate says otherwise. The loop's own stop token and the
  #    attempt's recorded verdict are two separate facts; the fence needs both.
  R="$(trail_repo "trail-$TSH-notgreen")"
  trail_gate_file "$R" 02 not_green 1 "$(git -C "$R" rev-parse HEAD)"
  trail_refusal "$TSH" B8.notgreen "TRAIL=skipped REASON=not_green VERDICT=not_green RC=1" "$R" STOP_GREEN 2

  # 4. Unreadable JSON reaches the classifier AS A VALUE. jq fails, both reads
  #    come back empty, and the fence must say `unreadable` rather than default
  #    an empty verdict into anything — a silent default here would emit a trail
  #    over a gate file nobody could parse.
  R="$(trail_repo "trail-$TSH-malformed")"
  printf '{ this is not json\n' >"$R/.uberdev/premerge/$TRAIL_RUN_ID/gate-02.json"
  trail_refusal "$TSH" B8.malformed "REASON=not_green VERDICT=unreadable RC=unreadable" "$R" STOP_GREEN 2

  # 5. Green, but about a different commit. This is the binding that stops a
  #    late fixup or a rebase from inheriting a gate it was never read against.
  R="$(trail_repo "trail-$TSH-headmoved")"
  trail_gate_file "$R" 02 green 0 0000000000000000000000000000000000000000
  trail_refusal "$TSH" B8.headmoved "TRAIL=skipped REASON=head_moved" "$R" STOP_GREEN 2
  # ...and it names the LIVE head, so the comparison is a comparison and not a
  # constant that happens to read as one.
  TRAIL_OUT="$(run_trail_gate "$TSH" "$R" STOP_GREEN 2)"
  case "$TRAIL_OUT" in
    *"HEAD=$(git -C "$R" rev-parse HEAD)"*) ok "B8.headmoved [$TSH]: the refusal names the live HEAD" ;;
    *) bad "B8.headmoved [$TSH]: the refusal does not name the live HEAD: $TRAIL_OUT" ;;
  esac

  echo
  echo "== B9 [$TSH]: and it emits for the one state that earns it =="
  # Without this row B8 is satisfied by a fence that refuses everything, which
  # is exactly what a broken emitter looks like from the outside.
  R="$(trail_repo "trail-$TSH-emit")"
  TRAIL_HEAD="$(git -C "$R" rev-parse HEAD)"
  # Attempt 2, not 1: the padding is part of the token /merge reads back out of
  # the commit body as `attempt=NN`, so an unpadded 2 must not satisfy this.
  trail_gate_file "$R" 02 green 0 "$TRAIL_HEAD"
  TRAIL_OUT="$(run_trail_gate "$TSH" "$R" STOP_GREEN 2)"; RC=$?
  case "$TRAIL_OUT" in
    *"TRAIL=emit ATTEMPT=02 HEAD=$TRAIL_HEAD"*)
      ok "B9 [$TSH]: TRAIL=emit ATTEMPT=02 bound to the gated HEAD" ;;
    *) bad "B9 [$TSH]: expected TRAIL=emit ATTEMPT=02 HEAD=$TRAIL_HEAD, got: $TRAIL_OUT" ;;
  esac
  check "$RC" 0 "B9 [$TSH]: exits 0"

  echo
  echo "== B10 [$TSH]: the publication fence publishes nothing on TRAIL=skipped =="
  R="$(trail_stack_repo "trailstack-$TSH-skip")"; S="$WORK/trailshim-$TSH-skip"
  trail_shims "$S"
  TRAIL_HEAD="$(git -C "$R" rev-parse HEAD)"
  TRAIL_OUT="$(run_trail_emit "$TSH" "$R" "$S" skipped 02)"; RC=$?
  check "$RC" 0 "B10.skip [$TSH]: exits 0"
  if [ -s "$S/git.log" ]; then
    bad "B10.skip [$TSH]: the fence ran git despite TRAIL=skipped: $(tr '\n' ';' <"$S/git.log")"
  else
    ok "B10.skip [$TSH]: no git call at all — no commit, no push"
  fi
  if [ -s "$S/gh.log" ]; then
    bad "B10.skip [$TSH]: the fence called gh despite TRAIL=skipped: $(tr '\n' ';' <"$S/gh.log")"
  else
    ok "B10.skip [$TSH]: no gh call — no label, no PR edit"
  fi
  check "$(git -C "$R" rev-parse HEAD)" "$TRAIL_HEAD" "B10.skip [$TSH]: HEAD did not move"
  if git -C "$R.git" rev-parse --verify -q "refs/heads/$TRAIL_BRANCH" >/dev/null; then
    bad "B10.skip [$TSH]: the stack branch reached the remote"
  else
    ok "B10.skip [$TSH]: the remote never heard of the stack branch"
  fi

  # The control. Without it B10.skip is equally satisfied by a shim that cannot
  # see anything and by a fence that is dead on every input — and by a run that
  # died on a missing manifest before it reached the decision.
  echo "== B10 [$TSH]: ...and the same fence DOES publish on TRAIL=emit (the control) =="
  R="$(trail_stack_repo "trailstack-$TSH-emit")"; S="$WORK/trailshim-$TSH-emit"
  trail_shims "$S"
  TRAIL_PARENT="$(git -C "$R" rev-parse HEAD)"
  TRAIL_BASE_OID="$(git -C "$R" rev-parse origin/main)"
  TRAIL_OUT="$(run_trail_emit "$TSH" "$R" "$S" emit 02)"; RC=$?
  check "$RC" 0 "B10.emit [$TSH]: exits 0"
  case "$TRAIL_OUT" in
    *"TRAIL=emitted"*"PR=$TRAIL_PR"*) ok "B10.emit [$TSH]: reports the emission" ;;
    *) bad "B10.emit [$TSH]: expected TRAIL=emitted for PR=$TRAIL_PR, got: $TRAIL_OUT" ;;
  esac
  TRAIL_GIT_LOG="$(cat "$S/git.log")"
  TRAIL_GH_LOG="$(cat "$S/gh.log")"
  case "$TRAIL_GIT_LOG" in
    *"commit --allow-empty"*) ok "B10.emit [$TSH]: the shim SAW the anchor commit (so B10.skip's empty log means something)" ;;
    *) bad "B10.emit [$TSH]: no commit reached the shim: $TRAIL_GIT_LOG" ;;
  esac
  case "$TRAIL_GIT_LOG" in
    *"push origin $TRAIL_BRANCH"*) ok "B10.emit [$TSH]: the shim SAW the push" ;;
    *) bad "B10.emit [$TSH]: no push reached the shim: $TRAIL_GIT_LOG" ;;
  esac
  case "$TRAIL_GH_LOG" in
    *"label create --force premerge-approved"*"pr edit $TRAIL_PR --add-label premerge-approved"*)
      ok "B10.emit [$TSH]: the shim SAW both gh calls, label provisioned before it is applied" ;;
    *) bad "B10.emit [$TSH]: the gh calls are missing or out of order: $TRAIL_GH_LOG" ;;
  esac
  # The payload /merge reads back out of the immutable commit body: both
  # endpoints of the delta, the instrument as data, and the gate token.
  TRAIL_BODY="$(git -C "$R" log -1 --format=%B)"
  case "$TRAIL_BODY" in
    *"Reviewed-by: uberdev/premerge@$TRAIL_PARENT gate=green attempt=02"*)
      ok "B10.emit [$TSH]: the anchor carries the head trailer with the gate token" ;;
    *) bad "B10.emit [$TSH]: head trailer missing or unbound: $TRAIL_BODY" ;;
  esac
  case "$TRAIL_BODY" in
    *"Reviewed-base: uberdev/premerge@$TRAIL_BASE_OID ref=main"*)
      ok "B10.emit [$TSH]: the anchor carries the base endpoint too" ;;
    *) bad "B10.emit [$TSH]: base trailer missing or unbound: $TRAIL_BODY" ;;
  esac
  if git -C "$R" diff --quiet HEAD~1 HEAD; then
    ok "B10.emit [$TSH]: the anchor is empty — a trail over changed bytes is refused"
  else
    bad "B10.emit [$TSH]: the anchor commit carries a diff"
  fi
  check "$(git -C "$R.git" rev-parse "refs/heads/$TRAIL_BRANCH")" "$(git -C "$R" rev-parse HEAD)" \
    "B10.emit [$TSH]: the remote branch now points at the anchor"
done

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

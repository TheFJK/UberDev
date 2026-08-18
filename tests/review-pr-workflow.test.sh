#!/usr/bin/env bash
# tests/review-pr-workflow.test.sh — #381: the /review-pr + /simplify wiring
# into skills/review-fleet/workflow.js.
#
# The engine shipped before anything could select it, and the whole point of
# this suite is that the two halves cannot drift apart again. Three surfaces:
#
#   S — the shell seam: lib/dispatch.sh must ADMIT the workflow backend for
#       review-pr/simplify (or the wiring is unreachable) while still refusing
#       every backend it refused before, and the no-provider-arm refusal must
#       survive.
#   G — per-stage shape greps over commands/review-pr.md and commands/simplify.md:
#       every stage owes the RFC 0012 §4.1 existence guard, the per-child mkdir,
#       the CSPRNG nonce mint, a binding minted BEFORE dispatch, the args
#       envelope, the mandated Workflow call, and the post-return capture verbs.
#       Plus the roster order, which is a wire format shared with the script.
#   B — BEHAVIORAL: the review-stage and lens-stage mint fences are EXTRACTED
#       FROM THE COMMAND FILES AND RUN, against the real
#       lib/code_fixer_contract.py. The envelope they print and the launched
#       ledger they write are then cross-checked against each other, so a
#       dropped nonce or a dropped emission is a hard failure rather than a
#       missing grep.
#
# Unix-only (python3 + realpath + the contract round-trip over mktemp -d paths);
# declared in the test.yml windows-skip-list. Runs on ubuntu and macOS.
#
# FIXTURE DISCIPLINE (RFC 0012 §4.4): no secret-shaped literals.

set -u
set -o pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REVIEW_CMD="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY_CMD="$REPO_ROOT/plugins/uberdev/commands/simplify.md"
ARGS_LIB="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
DISPATCH="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/review-fleet/workflow.js"
SKILL="$REPO_ROOT/plugins/uberdev/skills/review-fleet/SKILL.md"
CONTRACT="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"
# The fence library the command files' helpers actually live in (#427). Section
# W-UNAP carves a helper out of these bytes and RUNS it, so it is a required
# input of this suite, not merely a grep target.
FENCES="$REPO_ROOT/plugins/uberdev/lib/review-fences.sh"

for f in "$REVIEW_CMD" "$SIMPLIFY_CMD" "$ARGS_LIB" "$DISPATCH" "$WORKFLOW" "$SKILL" "$CONTRACT" "$FENCES"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
# `node` joined this list with section W, which EXECUTES workflow.js rather
# than grepping it. A missing interpreter must be one FATAL line, never
# fifteen mysterious W-row failures that read as engine bugs. Both CI images
# ship node (tests/workflow-scripts.test.sh relies on the same fact).
#
# `zsh` joined it with W-UNAP, which re-drives a carved fence helper -- and, in
# W-UNAP-E2E, a whole lifted command fence -- under the interpreter the
# Skill-tool `bash` fence actually gets. A bashism there is a runtime-only
# defect no shape test can see, so the second interpreter is the whole point of
# the row — silently skipping it would be a vacuous green.
# ubuntu-latest installs zsh in the shape-checks job; macos-latest ships it.
for tool in jq python3 node zsh; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is required" >&2; exit 2; }
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

. "$REPO_ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() { rm -rf "$TMP"; }
trap '_floor_rc=$?; cleanup; uberdev_test_exit_floor review-pr-workflow "$_floor_rc"' EXIT

echo "## review-pr-workflow (#381) — the review-fleet wiring in both command files"

# extract_fence FILE TOKEN — body of the first ```bash fence containing TOKEN.
extract_fence() {
  awk -v token="$2" '
    /^[ \t]*```bash/ { inf = 1; buf = ""; next }
    inf && /^[ \t]*```[ \t]*$/ {
      if (index(buf, token) > 0) { printf "%s", buf; found = 1; exit }
      inf = 0; buf = ""; next
    }
    inf { buf = buf $0 "\n" }
    END { if (!found) exit 1 }
  ' "$1"
}

# ---------------------------------------------------------------------------
# S — the shell seam
# ---------------------------------------------------------------------------
echo "== S: lib/dispatch.sh admits workflow for review-pr/simplify =="

backend_probe() {  # BACKEND WORKFLOW -> prints the rc
  bash -c '. "$1" >/dev/null 2>&1; uberdev_dispatch_preflight_backend "$2" "$3" >/dev/null 2>&1; echo $?' \
    _ "$DISPATCH" "$1" "$2"
}

for wf in review-pr simplify; do
  rc="$(backend_probe workflow "$wf")"
  [ "$rc" = 0 ] \
    && pass "S1 uberdev_dispatch_preflight_backend workflow $wf returns 0 (the wiring is reachable)" \
    || fail "S1 uberdev_dispatch_preflight_backend workflow $wf returned $rc — the wiring is unreachable"
  # INVERTED (#381): this asserted codex was STILL accepted here. `codex` is out
  # of _UBERDEV_DISPATCH_BACKEND_ENUM, so uberdev_dispatch_preflight_backend must
  # now refuse it through its unknown-backend `*)` arm for both governed
  # workflows -- the same shape S3 locks for wezterm/background.
  rc="$(backend_probe codex "$wf")"
  [ "$rc" != 0 ] \
    && pass "S2 codex is refused for $wf (the transport is gone, not merely unselected)" \
    || fail "S2 codex is still accepted for $wf — a deleted backend must not preflight clean"
done

# S3 — nothing was weakened for the backends that never met the bar.
for be in wezterm background; do
  rc="$(backend_probe "$be" review-pr)"
  [ "$rc" != 0 ] \
    && pass "S3 $be is still refused for review-pr" \
    || fail "S3 $be is now accepted for review-pr — that is a weakened check, not a wiring"
done

# S4 — the loud no-provider-arm refusal is what makes a mis-wired routed child
# fail closed. Admitting the backend at preflight must not remove it.
if grep -q "backend 'workflow' is dispatched by the session's Workflow tool" "$DISPATCH"; then
  pass "S4 _uberdev_agent_dispatch_backend keeps its loud workflow refusal"
else
  fail "S4 the loud workflow refusal is gone — a routed child would silently fall through"
fi

# ---------------------------------------------------------------------------
# S5..S9 — the DEFAULT flip (#381 step 3). S1 proved the opt-in half; these
# prove `auto` itself now lands on the wired transport, that codex stays
# explicitly selectable, and that the two hosts which genuinely cannot run a
# Workflow (a Codex session; a plugin tree with no engine on disk) still get a
# concrete backend or a loud refusal — never a silent resolution to something
# unexecutable.
# ---------------------------------------------------------------------------
echo "== S5-S9: auto resolves workflow, and never resolves an unexecutable one =="

# auto_probe DISPATCH_FILE WORKFLOW -> "<rc>|<resolved>|<stderr>"
#
# #381: this used to take a CODEX_AVAILABLE argument and stub
# `_uberdev_dispatch_codex_available` after the source. That function no longer
# exists, so the stub was an inert no-op — the probe read as though it isolated
# resolution from the host's codex binary while isolating nothing. Resolution is
# now genuinely codex-independent, which is the property S5/S7 assert.
auto_probe() {
  local dispatch_file="$1" wf="$2" errfile="$TMP/auto-probe.err"
  # preflight EXPORTS its answer, so it must not run inside a command
  # substitution — that subshell would discard UBERDEV_RESOLVED_BACKEND and
  # every probe would read back empty. stderr goes to a file instead.
  local out
  out="$(
    bash -c '
      set +e
      . "$1" >/dev/null 2>&1
      unset UBERDEV_RESOLVED_BACKEND
      uberdev_dispatch_preflight "$2" >/dev/null 2>"$3"
      printf "%s|%s" "$?" "${UBERDEV_RESOLVED_BACKEND-}"
    ' _ "$dispatch_file" "$wf" "$errfile"
  )"
  printf '%s|%s' "$out" "$(tr '\n' ' ' <"$errfile" 2>/dev/null)"
}

# S5 — THE MISSION TEST. codex unavailable, and auto must still resolve a
# concrete, wired backend for both governed workflows.
for wf in review-pr simplify; do
  probe="$(CODEX_HOME='' auto_probe "$DISPATCH" "$wf")"
  rc="${probe%%|*}"; rest="${probe#*|}"; resolved="${rest%%|*}"; err="${rest#*|}"
  if [ "$rc" = 0 ] && [ "$resolved" = workflow ]; then
    pass "S5 uberdev_dispatch_preflight $wf resolves workflow with codex unavailable"
  else
    fail "S5 uberdev_dispatch_preflight $wf -> rc=$rc resolved='$resolved' ${err:+($err)}"
  fi
done

# S6 — INVERTED (#381). This asserted codex was NOT deleted by the default flip
# and stayed explicitly selectable as /review-pr Phase 3's escape hatch. Step 4
# deleted it: there is no escape hatch any more (--no-ci-fix is the supported
# mode, see commands/review-pr.md 6c). An explicit --backend=codex must fail the
# enum check and leave UBERDEV_RESOLVED_BACKEND UNSET — a nonzero rc that still
# exported a backend would be worse than the old behaviour.
for wf in review-pr simplify; do
  probe="$(
    bash -c '
      set +e
      . "$1" >/dev/null 2>&1
      unset UBERDEV_RESOLVED_BACKEND
      UBERDEV_DISPATCH_BACKEND_REQUESTED=codex uberdev_dispatch_preflight "$2" >/dev/null 2>&1
      printf "%s|%s" "$?" "${UBERDEV_RESOLVED_BACKEND-}"
    ' _ "$DISPATCH" "$wf"
  )"
  [ "$probe" = "1|" ] \
    && pass "S6 --backend=codex is refused for $wf and resolves nothing" \
    || fail "S6 --backend=codex for $wf gave '$probe' (want '1|')"
done

# S7 — INVERTED (#381). This asserted that an ambient CODEX_HOME made `auto`
# keep choosing codex, because a Codex session has no Claude Workflow tool to
# mandate. That CODEX_HOME escape ran BEFORE the per-OS matrix and was deleted
# with the transport (lib/dispatch.sh:682-685): `auto` has exactly one answer
# now, and an ambient environment variable must not steer it.
for wf in review-pr simplify; do
  probe="$(CODEX_HOME="$TMP/fake-codex-home" auto_probe "$DISPATCH" "$wf")"
  [ "${probe%%|*}" = 0 ] && [ "$(echo "$probe" | cut -d'|' -f2)" = workflow ] \
    && pass "S7 auto resolves workflow for $wf even with CODEX_HOME set (the escape is gone)" \
    || fail "S7 auto with CODEX_HOME set gave '$probe' for $wf (want rc 0, resolved workflow)"
done

# S8/S9 — the fail-loud arm for a host that cannot execute the Workflow, built
# from a REAL plugin tree with the engine removed. Sourcing a copy of
# dispatch.sh out of that tree is what makes the arm reachable: the library
# locates its own plugin root, so this is the same probe a broken install runs.
ENGINELESS_ROOT="$TMP/engineless-plugin"
mkdir -p "$ENGINELESS_ROOT/lib" "$ENGINELESS_ROOT/skills/solve-fleet"
cp "$REPO_ROOT/plugins/uberdev/lib/"*.sh "$ENGINELESS_ROOT/lib/"
cp "$WORKFLOW" "$ENGINELESS_ROOT/skills/solve-fleet/workflow.js"
ENGINELESS_DISPATCH="$ENGINELESS_ROOT/lib/dispatch.sh"

# Control: the same copied tree WITH the engine present must resolve workflow,
# so S8 is proved by the missing file and not by the copy itself.
ENGINEFUL_ROOT="$TMP/engineful-plugin"
mkdir -p "$ENGINEFUL_ROOT/lib" "$ENGINEFUL_ROOT/skills/review-fleet"
cp "$REPO_ROOT/plugins/uberdev/lib/"*.sh "$ENGINEFUL_ROOT/lib/"
cp "$WORKFLOW" "$ENGINEFUL_ROOT/skills/review-fleet/workflow.js"
probe="$(CODEX_HOME='' auto_probe "$ENGINEFUL_ROOT/lib/dispatch.sh" review-pr 1)"
[ "${probe%%|*}" = 0 ] && [ "$(echo "$probe" | cut -d'|' -f2)" = workflow ] \
  && pass "S8a control: a copied plugin tree WITH the engine resolves workflow" \
  || fail "S8a control tree did not resolve workflow: '$probe'"

for wf in review-pr simplify; do
  probe="$(CODEX_HOME='' auto_probe "$ENGINELESS_DISPATCH" "$wf" 1)"
  rc="${probe%%|*}"; rest="${probe#*|}"; resolved="${rest%%|*}"; err="${rest#*|}"
  if [ "$rc" != 0 ] && [ -z "$resolved" ] \
     && grep -Fq 'skills/review-fleet/workflow.js' <<<"$err"; then
    pass "S8 auto refuses loudly for $wf when the engine is absent, and exports no backend"
  else
    fail "S8 engineless auto for $wf -> rc=$rc resolved='$resolved' err='$err'"
  fi
done

# S9 — the same gate on the two EXPLICIT entry points, so `--backend=workflow`
# on a broken install refuses at preflight instead of at stage time, when a
# RUN_ID has already been reserved.
probe="$(
  bash -c '
    set +e
    . "$1" >/dev/null 2>&1
    unset UBERDEV_RESOLVED_BACKEND
    err="$(UBERDEV_DISPATCH_BACKEND_REQUESTED=workflow uberdev_dispatch_preflight review-pr 2>&1 >/dev/null)"
    printf "%s|%s|%s" "$?" "${UBERDEV_RESOLVED_BACKEND-}" "$err"
  ' _ "$ENGINELESS_DISPATCH"
)"
[ "${probe%%|*}" != 0 ] && grep -Fq 'skills/review-fleet/workflow.js' <<<"$probe" \
  && pass "S9a --backend=workflow refuses when the engine is absent" \
  || fail "S9a --backend=workflow on an engineless tree gave '$probe'"

rc="$(bash -c '. "$1" >/dev/null 2>&1; uberdev_dispatch_preflight_backend workflow "$2" >/dev/null 2>&1; echo $?' \
        _ "$ENGINELESS_DISPATCH" review-pr)"
[ "$rc" != 0 ] \
  && pass "S9b uberdev_dispatch_preflight_backend workflow review-pr refuses when the engine is absent" \
  || fail "S9b preflight_backend accepted workflow with no engine on disk"

# ---------------------------------------------------------------------------
# G — per-stage shape greps
# ---------------------------------------------------------------------------
echo "== G: every stage owes the same six things =="

GUARD='missing (RFC 0012 §4.1)'
MANDATE='Workflow({scriptPath: "$CLAUDE_PLUGIN_ROOT/skills/review-fleet/workflow.js"}'

fence_has() {  # FILE TOKEN NEEDLE LABEL
  local body
  body="$(extract_fence "$1" "$2")" || { fail "$4 (no fence carrying '$2')"; return; }
  # Herestring, not a pipe: `grep -Fq` exits at the first match, so a pipe
  # writer can take EPIPE and — under `set -o pipefail` — turn a MATCH into a
  # 141 pipeline status, i.e. a spurious fail. tests/epipe-guard.test.sh E2.O1
  # declares the herestring the safe form.
  if grep -Fq "$3" <<<"$body"; then pass "$4"; else fail "$4"; fi
}

# review-pr.md: four stages (fix runs twice, on two different edges) plus the
# four Phase 3 CI stages (#383).
for stage_token in 'stage=review' 'stage=verify' 'fixerEdgeId=review_pr.fix.phase1' 'stage=simplify' 'fixerEdgeId=review_pr.fix.phase2' 'stage=defer' 'stage=ci-classify' 'stage=ci-fix' 'stage=ci-conflicts' 'stage=ci-defer'; do
  label="review-pr.md [$stage_token]"
  fence_has "$REVIEW_CMD" "$stage_token" "$GUARD" "G1 $label carries the RFC 0012 §4.1 existence guard"
  fence_has "$REVIEW_CMD" "$stage_token" 'mkdir -p "$REVIEW_FLEET_RUN_DIR/children"' "G2 $label makes the per-child layout root"
  fence_has "$REVIEW_CMD" "$stage_token" 'uberdev_emit_workflow_args review-fleet' "G3 $label emits a review-fleet envelope"
  fence_has "$REVIEW_CMD" "$stage_token" 'runNonces=' "G4 $label passes the nonce pool as one comma-joined scalar"
  fence_has "$REVIEW_CMD" "$stage_token" 'branchName=' "G5 $label declares branchName (empty, matching the binding)"
done

# simplify.md: three stages.
for stage_token in 'stage=simplify' 'fixerEdgeId=simplify.fix.phase2' 'stage=defer'; do
  label="simplify.md [$stage_token]"
  fence_has "$SIMPLIFY_CMD" "$stage_token" "$GUARD" "G1 $label carries the RFC 0012 §4.1 existence guard"
  fence_has "$SIMPLIFY_CMD" "$stage_token" 'mkdir -p "$REVIEW_FLEET_RUN_DIR/children"' "G2 $label makes the per-child layout root"
  fence_has "$SIMPLIFY_CMD" "$stage_token" 'uberdev_emit_workflow_args review-fleet' "G3 $label emits a review-fleet envelope"
  fence_has "$SIMPLIFY_CMD" "$stage_token" 'runNonces=' "G4 $label passes the nonce pool as one comma-joined scalar"
  fence_has "$SIMPLIFY_CMD" "$stage_token" 'branchName=' "G5 $label declares branchName (empty, matching the binding)"
done

# G6 — the binding is minted BEFORE the call, by the producer that matches the
# child's obligations. A reviewer-shaped producer for a fixer child would skip
# the authority pin; a fixer-shaped one for the defer child cannot exist.
grep -Fq 'review_fleet_bind_roster review ' "$REVIEW_CMD" \
  && pass "G6a review-pr binds the six reviewers with bind-workflow-launch (via review_fleet_bind_roster)" \
  || fail "G6a review-pr does not bind the reviewer roster"
grep -Fq 'review_fleet_bind_fixer review_pr.fix.phase1 ' "$REVIEW_CMD" \
  && grep -Fq 'review_fleet_bind_fixer review_pr.fix.phase2 ' "$REVIEW_CMD" \
  && pass "G6b review-pr binds both fixers with the FIXER producer" \
  || fail "G6b review-pr does not bind both fixers with the fixer producer"
grep -Fq 'review_fleet_bind_persistence ' "$REVIEW_CMD" \
  && pass "G6c review-pr binds the defer child with the PERSISTENCE producer" \
  || fail "G6c review-pr does not bind the defer child"
# G6e — the recount the defer binding is gated on names the phase it counts.
# Nothing grepped review-pr.md for this verb before #452, so a missed fence
# passed the whole suite and failed only at runtime behind `|| return 74`.
grep -Fq 'count-phase2-deferred-blockers' "$REVIEW_CMD" \
  && pass "G6e review-pr recounts the PHASE 2 deferred blockers before binding the defer child" \
  || fail "G6e review-pr does not name the phase2 deferred-blocker verb"
grep -Fq 'review_fleet_bind_roster simplify ' "$SIMPLIFY_CMD" \
  && grep -Fq 'review_fleet_bind_fixer simplify.fix.phase2 ' "$SIMPLIFY_CMD" \
  && grep -Fq 'review_fleet_bind_persistence ' "$SIMPLIFY_CMD" \
  && pass "G6d simplify binds all three of its stages with the matching producers" \
  || fail "G6d simplify is missing one of its three producers"

# G7 — the mandated Workflow call, relayed verbatim between the markers.
for f in "$REVIEW_CMD" "$SIMPLIFY_CMD"; do
  base="$(basename "$f")"
  grep -Fq "$MANDATE" "$f" \
    && pass "G7 $base mandates the review-fleet Workflow call" \
    || fail "G7 $base has no Workflow mandate"
  grep -Fq 'WORKFLOW_ARGS_BEGIN' "$f" \
    && pass "G8 $base names the args markers (verbatim relay, DR-2)" \
    || fail "G8 $base does not reference the args markers"
  grep -Fq '"Workflow"' "$f" \
    && pass "G9 $base lists Workflow in allowed-tools" \
    || fail "G9 $base does not allow the Workflow tool"
done

# G10 — the post-return capture verbs, per stage. Without these the run
# dispatches a real fanout and then proves nothing, which is the one outcome
# this whole seam exists to prevent.
#
# RE-POINTED (#556). The fix stage's two verbs moved out of the command file and
# into `review_fixer_terminal_outcome`, which owns the three-way branch all four
# fixer fences now call. Grepping $REVIEW_CMD for them would go red on a change
# that improved the wiring, so each verb is asserted where it now LIVES and the
# command file is asserted to name the owner — this is the known "SSOT
# extraction breaks structural-grep anchors" class, and re-pointing is the fix.
grep -Fq 'capture-bound-child' "$REVIEW_CMD" \
  && grep -Fq 'review_fixer_terminal_outcome' "$REVIEW_CMD" \
  && grep -Fq 'capture-review-terminal' "$FENCES" \
  && grep -Fq 'capture-persistence-terminal' "$REVIEW_CMD" \
  && grep -Fq 'post_review_validated_evidence_complete' "$REVIEW_CMD" \
  && grep -Fq 'post_review_write_aggregate_v2' "$REVIEW_CMD" \
  && grep -Fq 'post_review_write_simplify_aggregate_v2' "$REVIEW_CMD" \
  && pass "G10a review-pr runs the capture verbs for all four stages after the call" \
  || fail "G10a review-pr is missing a post-return capture verb"
grep -Fq 'capture-bound-child' "$SIMPLIFY_CMD" \
  && grep -Fq 'capture-standalone-terminal' "$SIMPLIFY_CMD" \
  && grep -Fq 'capture-persistence-terminal' "$SIMPLIFY_CMD" \
  && pass "G10b simplify runs the capture verbs for all three stages after the call" \
  || fail "G10b simplify is missing a post-return capture verb"
# G10d (#481) — capturing the three lens children proved they ran; nothing then
# turned them into `simplify-final.md`, and Phase 2 stopped there. Both producer
# sites must name the writer.
grep -Fq 'post_review_write_simplify_aggregate_v2' "$SIMPLIFY_CMD" \
  && pass "G10d simplify aggregates the captured lens wave into the phase2 document" \
  || fail "G10d simplify captures three lenses and never builds the phase2 aggregate"
# G10c — same re-point (#556): the review terminal is validated inside the
# branch owner, so the fix stage's validator is asserted against $FENCES.
grep -Fq 'validate-review-outcome' "$FENCES" \
  && grep -Fq 'validate-persistence-result' "$REVIEW_CMD" \
  && grep -Fq 'validate-standalone-outcome' "$SIMPLIFY_CMD" \
  && grep -Fq 'validate-persistence-result' "$SIMPLIFY_CMD" \
  && pass "G10c both commands validate the captured terminals" \
  || fail "G10c a captured terminal is never validated"

# G11 — ROSTER ORDER IS A WIRE FORMAT. The shell side and the script side must
# agree exactly; reordering either silently binds every child to another
# child's nonce.
JS_REVIEW_ORDER="$(grep -o 'edge: "review_pr\.review\.[a-z_]*"' "$WORKFLOW" | sed 's/.*"\(.*\)"/\1/' | tr '\n' ',')"
SH_REVIEW_ORDER="$(bash -c '. "$1"; review_fleet_roster review | cut -f2 | tr "\n" ","' _ "$ARGS_LIB")"
[ -n "$JS_REVIEW_ORDER" ] && [ "$JS_REVIEW_ORDER" = "$SH_REVIEW_ORDER" ] \
  && pass "G11a the six reviewer edges are in the same order in workflow.js and review-fleet-args.sh" \
  || fail "G11a reviewer roster order drifted: js=[$JS_REVIEW_ORDER] sh=[$SH_REVIEW_ORDER]"
JS_LENS_ORDER="$(grep -o 'edge: "review_pr\.simplify\.[a-z_]*"' "$WORKFLOW" | sed 's/.*"\(.*\)"/\1/' | tr '\n' ',')"
SH_LENS_ORDER="$(bash -c '. "$1"; review_fleet_roster simplify | cut -f2 | tr "\n" ","' _ "$ARGS_LIB")"
[ -n "$JS_LENS_ORDER" ] && [ "$JS_LENS_ORDER" = "$SH_LENS_ORDER" ] \
  && pass "G11b the three lens edges are in the same order in workflow.js and review-fleet-args.sh" \
  || fail "G11b lens roster order drifted: js=[$JS_LENS_ORDER] sh=[$SH_LENS_ORDER]"

# G12 — the child-directory formula is computed on both sides with no envelope
# scalar and no round-trip, so the two spellings must agree.
SH_CHILD_DIR="$(bash -c '. "$1"; review_fleet_child_dir /run 7 correctness' _ "$ARGS_LIB")"
[ "$SH_CHILD_DIR" = "/run/children/correctness-iter07" ] \
  && pass "G12 the shell child-dir formula matches the script's runDirAbs/children/<slug>-iter<NN>" \
  || fail "G12 child-dir formula mismatch: $SH_CHILD_DIR"

# G13 — the nonce must come from a real CSPRNG. $RANDOM and timestamps are
# banned: a predictable nonce is not a binding token at all.
if grep -Eq 'openssl rand -hex 32|secrets\.token_hex\(32\)' "$ARGS_LIB"; then
  pass "G13a the nonce mint uses a CSPRNG (openssl rand / secrets.token_hex)"
else
  fail "G13a no CSPRNG in the nonce mint"
fi
# Comment-strip first: the mint's own docstring NAMES the banned sources in
# order to ban them, and a guard that punished the prose would be unfixable.
ARGS_LIB_NONCOMMENT="$(grep -v '^[[:space:]]*#' "$ARGS_LIB")"
if grep -Eq '\$RANDOM|date \+%s' <<<"$ARGS_LIB_NONCOMMENT"; then
  fail "G13b the nonce mint reaches for \$RANDOM or a timestamp"
else
  pass "G13b the nonce mint never reaches for \$RANDOM or a timestamp"
fi

# G14 — INVERTED (#383). This used to LOCK the refusal that made a red PR halt:
# it asserted the inline `ci_transport_unsupported` gate lived inside the
# CLASSIFY fence. Leaving it asserting the gate it retires is exactly the trap
# that keeps a retired surface alive, so it now asserts the opposite in three
# independent ways.
for target in "$REVIEW_CMD" "$SKILL" "$DISPATCH"; do
  base="$(basename "$target")"
  if grep -Fq 'ci_transport_unsupported' "$target"; then
    # SKILL.md's gate log keeps the reason as HISTORY inside its "Was (#381)"
    # block; that is the one place it may still be named.
    if [ "$target" = "$SKILL" ] && grep -Fq 'Was (#381)' "$target"; then
      pass "G14a $base names ci_transport_unsupported only in the historical gate-log entry"
    else
      fail "G14a $base still carries the retired ci_transport_unsupported refusal"
    fi
  else
    pass "G14a $base no longer carries the retired ci_transport_unsupported refusal"
  fi
done

# G14b — the CLASSIFY step now EMITS a stage instead of refusing one, and the
# routed single-child dispatch is gone from every Phase 3 edge.
CLASSIFY_FENCE="$(extract_fence "$REVIEW_CMD" 'stage=ci-classify' || true)"
if grep -Fq 'uberdev_emit_workflow_args review-fleet' <<<"$CLASSIFY_FENCE" \
   && grep -Fq 'review_fleet_bind_ci review_pr.ci.classify ' <<<"$CLASSIFY_FENCE" \
   && ! grep -Fq 'review_child_single' <<<"$CLASSIFY_FENCE"; then
  pass "G14b the CLASSIFY step binds a CI child and emits a review-fleet envelope"
else
  fail "G14b the CLASSIFY step does not dispatch through the review-fleet engine"
fi
if grep -Eq 'review_child_single review_pr\.ci\.' "$REVIEW_CMD"; then
  fail "G14b2 a Phase 3 edge still takes the routed adapter, which has no workflow provider arm"
else
  pass "G14b2 no Phase 3 edge takes the routed adapter any more"
fi

# G14c — PHANTOM-NAME LOCK. #382's review caught a doc naming a
# `review_require_ci_capable_*` transport primitive that exists nowhere. This
# design does not create it either; the lock makes the name unresurrectable.
# The literal is assembled at runtime so this fixture cannot match itself.
# Assembled at runtime so THIS file's own grep is not what the grep finds.
PHANTOM_PRIMITIVE="review_require_ci""_capable_transport"
if grep -rqn -- "$PHANTOM_PRIMITIVE" "$REPO_ROOT/plugins" "$REPO_ROOT/docs" 2>/dev/null; then
  fail "G14c the phantom $PHANTOM_PRIMITIVE primitive was resurrected"
else
  pass "G14c the phantom $PHANTOM_PRIMITIVE primitive still exists nowhere"
fi

# G15 — the engine's own gate log must not still advertise itself as unreachable.
grep -Fq 'nothing dispatches this engine' "$SKILL" \
  && fail "G15 review-fleet/SKILL.md still records blocker B as OPEN while both commands dispatch it" \
  || pass "G15 review-fleet/SKILL.md no longer records the engine as undispatched"

# ---------------------------------------------------------------------------
# G16-G18 — Phase 3 (#383). The CI edge set had FOUR uncompared copies, which
# is exactly the "one contract, N uncompared copies" class #370/#371 named.
# ---------------------------------------------------------------------------
CONTRACT_PY="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"
MANIFEST="$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"

G16="$(python3 - "$WORKFLOW" "$CONTRACT_PY" "$REVIEW_CMD" "$MANIFEST" <<'PY'
import importlib.util, json, re, sys
workflow_js, contract_py, review_md, manifest_json = sys.argv[1:5]

js = open(workflow_js, encoding="utf-8").read()
js_edges = set(re.findall(r'"(review_pr\.ci\.[a-z_]+)"', js))

spec = importlib.util.spec_from_file_location("cfc", contract_py)
module = importlib.util.module_from_spec(spec)
sys.modules["cfc"] = module
spec.loader.exec_module(module)
contract_edges = set(module.WORKFLOW_CI_EDGE_IDS)

md = open(review_md, encoding="utf-8").read()
block = re.search(
    r"<!-- BEGIN child-callsite-contracts-v1 -->\s*```json\n(.*?)\n```",
    md, re.DOTALL)
registry = json.loads(block.group(1)) if block else {}
registry_edges = {k for k in registry if k.startswith("review_pr.ci.")}

policy = json.load(open(manifest_json, encoding="utf-8"))
policy_edges = {k for k in policy.get("edges", {}) if k.startswith("review_pr.ci.")}

problems = []
for label, observed in (("workflow.js", js_edges), ("registry", registry_edges),
                        ("manifest", policy_edges)):
    if observed != contract_edges:
        problems.append("%s=%s" % (label, sorted(observed ^ contract_edges)))
print("ok" if not problems else "; ".join(problems))
print(len(contract_edges))
PY
)"
G16_STATE="$(printf '%s' "$G16" | sed -n 1p)"
G16_COUNT="$(printf '%s' "$G16" | sed -n 2p)"
[ "$G16_STATE" = ok ] && [ "$G16_COUNT" = 5 ] \
  && pass "G16 the five review_pr.ci.* edges agree across workflow.js, code_fixer_contract.py, the review-pr registry and the run-tree manifest" \
  || fail "G16 the CI edge set drifted between its four copies: $G16_STATE (contract count=$G16_COUNT)"

# G17 — every Phase 3 phase() literal is declared in meta.phases. T2 checks this
# globally; G17 exists so the failure message names Phase 3 rather than a
# generic drift.
G17_MISSING=""
# Extracted ONCE into a variable, then read with a herestring: a piped
# `grep -Fq` exits early, EPIPEs the writer, and pipefail promotes that to a
# false non-zero on the CI runner (tests/epipe-guard.test.sh, #313).
WORKFLOW_META_BLOCK="$(sed -n '/META-BEGIN/,/META-END/p' "$WORKFLOW")"
for literal in 'Phase 3 — CI classify' 'Phase 3 — CI fix' 'Phase 3 — CI conflicts' 'Phase 3 — CI defer'; do
  grep -Fq "phase(\"$literal\")" "$WORKFLOW" || G17_MISSING="$G17_MISSING no-phase-call[$literal]"
  # META-BEGIN/META-END block must declare it.
  grep -Fq "\"$literal\"" <<<"$WORKFLOW_META_BLOCK" \
    || G17_MISSING="$G17_MISSING undeclared[$literal]"
done
[ -z "$G17_MISSING" ] \
  && pass "G17 all four Phase 3 phase() literals exist and are declared in meta.phases" \
  || fail "G17 Phase 3 phase literals:$G17_MISSING"

# G18 — the CI slug rule is computed on BOTH sides with no envelope scalar, and
# it must NOT have introduced a second child-directory formula: the CI loop
# counter lives in the slug, and iterSuffix() still owns the directory suffix.
grep -Fq 'function ciSlug(base) { return base + "-ci" + pad2(ciLoopIter); }' "$WORKFLOW" \
  && pass "G18a workflow.js keys the CI loop counter into the SLUG" \
  || fail "G18a workflow.js ciSlug rule is missing or changed shape"
SH_CI_SLUG="$(bash -c '. "$1"; review_fleet_ci_slug ci-rebase 2' _ "$ARGS_LIB")"
[ "$SH_CI_SLUG" = "ci-rebase-ci02" ] \
  && pass "G18b the shell ciSlug mirror agrees (ci-rebase-ci02)" \
  || fail "G18b shell ciSlug produced '$SH_CI_SLUG', expected ci-rebase-ci02"
SH_CI_DIR="$(bash -c '. "$1"; review_fleet_child_dir /run 1 "$(review_fleet_ci_slug ci-rebase 2)"' _ "$ARGS_LIB")"
[ "$SH_CI_DIR" = "/run/children/ci-rebase-ci02-iter01" ] \
  && pass "G18c a CI child directory is unique in BOTH counters via the one formula" \
  || fail "G18c CI child dir was '$SH_CI_DIR'"
# The trap this replaces: a second childDirAbs-style formula keyed on the CI
# counter would silently clobber iteration 1's artifacts.
[ "$(grep -c 'runDirAbs + "/children/"' "$WORKFLOW")" = 1 ] \
  && pass "G18d there is still exactly ONE child-directory formula in workflow.js" \
  || fail "G18d a second child-directory formula appeared — CI iterations would clobber each other"

# G19 — the CI stages must use the CI producer. A reviewer- or fixer-shaped
# producer would mint a binding with no slot for the pinned log artifact, and
# every downstream equality would still pass while proving strictly less.
grep -Fq 'bind-workflow-ci-launch' "$ARGS_LIB" \
  && grep -Fq 'review_fleet_bind_ci()' "$ARGS_LIB" \
  && grep -Fq 'review_fleet_bind_ci_conflicts()' "$ARGS_LIB" \
  && pass "G19a review-fleet-args.sh binds CI children with bind-workflow-ci-launch" \
  || fail "G19a review-fleet-args.sh has no CI producer"
CI_BIND_BODY="$(sed -n '/^review_fleet_bind_ci()/,/^}/p;/^review_fleet_bind_ci_conflicts()/,/^}/p' "$ARGS_LIB")"
if grep -Eq 'bind-workflow-launch|bind-workflow-fixer-launch|bind-workflow-persistence-launch' <<<"$CI_BIND_BODY"; then
  fail "G19b a CI binder reaches for a non-CI producer — the input pin would be dropped"
else
  pass "G19b no CI binder reaches for a non-CI producer"
fi
# G19c — the loop counters are persisted, because every fence is a fresh shell.
grep -Fq 'review_fleet_write_ci_state()' "$ARGS_LIB" \
  && grep -Fq 'review_fleet_read_ci_state()' "$ARGS_LIB" \
  && pass "G19c the Phase 3 loop counters have an on-disk home" \
  || fail "G19c the Phase 3 loop counters would die with their fence"

# G20 — the Phase 1 reviewer OUTPUT contract crosses the envelope (#403). The
# script has no filesystem, so a contract nobody hands it is a contract the six
# children never see; they then improvise a serialization
# uberdev_child_validate_phase1_review_result's re.fullmatch always rejects.
fence_has "$REVIEW_CMD" 'stage=review' 'review_fleet_contract_path' \
  "G20a review-pr.md [stage=review] resolves the reviewer output contract from the policy manifest"
fence_has "$REVIEW_CMD" 'stage=review' 'phase1ContractPathAbs=' \
  "G20b review-pr.md [stage=review] emits the resolved contract path in the args envelope"
grep -Fq 'phase1ContractPathAbs' "$SKILL" \
  && pass "G20c the review-fleet SKILL.md documents the phase1ContractPathAbs key" \
  || fail "G20c phase1ContractPathAbs is undocumented — the envelope contract is the SKILL.md table"
# G20d — the no-copy guard. policy/solve-run-tree-v1.json is the ONE place the
# relative path is declared; a copy in the command file or the script is a
# second declaration that drifts silently. This row passes today and must never
# start failing.
if grep -Fq 'shared/phase1-reviewer-output-v1' "$REVIEW_CMD" \
   || grep -Fq 'shared/phase1-reviewer-output-v1' "$WORKFLOW"; then
  fail "G20d the contract path is re-declared in review-pr.md or workflow.js instead of resolved"
else
  pass "G20d neither review-pr.md nor workflow.js re-declares the contract's relative path"
fi
# G20e — the SAME documentation duty for the fixer's contract key (#474). The
# `fix` arm is a REQUIRED-key arm now: an envelope missing `fixerContractPathAbs`
# aborts `bad_contract_path` with zero dispatches, exactly like the review arm's
# `phase1ContractPathAbs`. The SKILL.md table is the envelope contract every
# caller is written against, so a required key absent from it is a key the third
# emitter can be written without — which is precisely how simplify.fix.phase2
# shipped the guard without the key.
grep -Fq 'fixerContractPathAbs' "$SKILL" \
  && pass "G20e the review-fleet SKILL.md documents the fixerContractPathAbs key" \
  || fail "G20e fixerContractPathAbs is undocumented — the envelope contract is the SKILL.md table"

# ---------------------------------------------------------------------------
# B — behavioral: run the mint fences the command files actually carry
# ---------------------------------------------------------------------------
echo "== B: the extracted mint fences really mint, bind and emit =="

run_stage_fence() {  # FILE TOKEN OUTDIR -> envelope on stdout
  local file="$1" token="$2" out="$3" body fixture repo research
  body="$(extract_fence "$file" "$token")" || return 1
  # #427 — the review-pr fences no longer read their run paths out of seeded
  # scalars: each one opens with the rehydration prologue and resolves them from
  # a run on disk. So the fixture is now a REAL run (real git repository, real
  # uberdev_command_workspace_prepare, real command-workspace.json descriptor
  # and active-run pointer) and the fence executes from inside it. The seeded
  # scalars below stay for the /simplify fences this same helper drives, which
  # have no prologue; where both are present the values agree by construction.
  fixture="$(bash "$REPO_ROOT/tests/_lib_review_run_fixture.sh" --make-run \
    "$out" "$REPO_ROOT/plugins/uberdev" 41 20260101-000000-abc123 2>/dev/null)" || return 1
  repo="$(printf '%s\n' "$fixture" | sed -n 1p)"
  research="$(printf '%s\n' "$fixture" | sed -n 3p)"
  [ -n "$repo" ] && [ -n "$research" ] || return 1
  ( . "$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh" \
    && review_fleet_write_review_base \
         "$research/review-base-identity.tsv" \
         0000000000000000000000000000000000000000 main ) || return 1
  {
    echo 'set -u'
    echo "UBERDEV_REVIEW_PLUGIN_ROOT='$REPO_ROOT/plugins/uberdev'"
    echo "CODE_FIXER_CONTRACT='$CONTRACT'"
    echo "WORKTREE_ROOT='$repo'"
    echo "RESEARCH_DIR_ABS='$research'"
    echo "DIFF_ARTIFACT_PATH='$research/pr-diff.md'"
    echo "RUN_ID=20260101-000000-abc123"
    echo "REVIEW_ITERATION=1"
    echo "PR_NUMBER=41"
    echo "REVIEW_REPO_SLUG=acme/widget"
    echo "FOCUS=''"
    echo "SEQUENTIAL=0"
    echo "ASPECT_LIST=(tests)"
    # #440 — BASE_SHA is NOT env-passed any more. The lens fence takes the
    # reviewed-base identity off the run-dir carrier Phase 1 wrote, so seeding
    # the env here would prove nothing about what the fence can actually see
    # (that env-passing shortcut is precisely what masked #418/#419). Seed the
    # carrier instead, exactly as Phase 1 does.
    echo "audit() { :; }"
    # The lens fence refreshes the Phase-1 scope first; that is /review-pr's own
    # git-facing helper and is not what this fixture is proving. Stub it so the
    # mint/bind/emit half runs on its own.
    echo "review_refresh_phase1_scope() { return 0; }"
    echo "uberdev_review_fleet_stage_fence() {"
    # printf with the newline: $(...) strips the body's trailing one, and
    # without it the closing brace lands on the last command's line.
    printf '%s\n' "$body"
    echo "}"
    echo "uberdev_review_fleet_stage_fence"
  } >"$out/fence.sh"
  # From INSIDE the fixture repository: the prologue resolves the run root with
  # `git rev-parse --show-toplevel`, so the fence's cwd is load-bearing.
  ( cd "$repo" && bash "$out/fence.sh" 2>"$out/fence.err" )
}

envelope_of() {  # captured fence output -> the JSON between the markers
  sed -n '/^WORKFLOW_ARGS_BEGIN$/,/^WORKFLOW_ARGS_END$/p' | sed '1d;$d'
}

assert_stage() {  # LABEL FILE TOKEN EXPECTED_MODE EXPECTED_STAGE EXPECTED_COUNT LEDGER
  local label="$1" file="$2" token="$3" mode="$4" stage="$5" count="$6" ledger="$7"
  local out="$TMP/$label" raw env_json pool_count ledger_count matched
  mkdir -p "$out"
  if ! raw="$(run_stage_fence "$file" "$token" "$out")"; then
    fail "B[$label] the extracted fence did not run: $(head -3 "$out/fence.err" 2>/dev/null)"
    return
  fi
  env_json="$(printf '%s\n' "$raw" | envelope_of)"
  if [ -z "$env_json" ] || ! printf '%s' "$env_json" | jq -e . >/dev/null 2>&1; then
    fail "B[$label] the fence emitted no parseable envelope between the markers"
    return
  fi
  pass "B[$label] the fence emitted a parseable args envelope between the markers"

  [ "$(printf '%s' "$env_json" | jq -r .pipeline)" = review-fleet ] \
    && pass "B[$label] pipeline=review-fleet" || fail "B[$label] wrong pipeline"
  [ "$(printf '%s' "$env_json" | jq -r .config.mode)" = "$mode" ] \
    && pass "B[$label] config.mode=$mode" || fail "B[$label] wrong config.mode"
  [ "$(printf '%s' "$env_json" | jq -r .config.stage)" = "$stage" ] \
    && pass "B[$label] config.stage=$stage" || fail "B[$label] wrong config.stage"
  # branchName must be EMPTY: the binding records branch "" and the child status
  # is required to equal it.
  [ "$(printf '%s' "$env_json" | jq -r .config.branchName)" = "" ] \
    && pass "B[$label] branchName is emitted empty (matches the binding)" \
    || fail "B[$label] branchName is non-empty — every child status would refuse"

  # The pool must cover the roster exactly, be 64-hex, and be all-distinct.
  pool_count="$(printf '%s' "$env_json" | jq -r '.config.runNonces' | tr ',' '\n' | grep -c '^[0-9a-f]\{64\}$')"
  [ "$pool_count" = "$count" ] \
    && pass "B[$label] the pool carries exactly $count 64-hex nonces" \
    || fail "B[$label] the pool carries $pool_count valid nonces, expected $count"
  [ "$(printf '%s' "$env_json" | jq -r '.config.runNonces' | tr ',' '\n' | sort -u | grep -c .)" = "$count" ] \
    && pass "B[$label] every nonce in the pool is distinct (single-use)" \
    || fail "B[$label] the pool repeats a nonce"

  # The ledger was written BEFORE the emission, one binding row per child.
  ledger_count="$(grep -c . "$out/repo/.uberdev/research/20260101-000000-abc123/$ledger" 2>/dev/null || echo 0)"
  [ "$ledger_count" = "$count" ] \
    && pass "B[$label] the launched ledger carries $count binding rows" \
    || fail "B[$label] the launched ledger carries $ledger_count rows, expected $count"

  # THE CROSS-CHECK: pool[i] must be the run_nonce of ledger row i+1, in roster
  # order. This is what a dropped or reordered nonce actually breaks.
  matched="$(python3 - "$out/repo/.uberdev/research/20260101-000000-abc123/$ledger" "$(printf '%s' "$env_json" | jq -r '.config.runNonces')" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1],encoding="utf-8") if line.strip()]
pool=[item for item in sys.argv[2].split(",") if item]
if len(rows)!=len(pool): print("count"); raise SystemExit(0)
for index,(row,nonce) in enumerate(zip(rows,pool),start=1):
    binding=json.loads(row["binding"])
    if row["index"]!=index or binding["run_nonce"]!=nonce or binding["edge_id"]!=row["edge"]:
        print("mismatch-at-%d" % index); raise SystemExit(0)
    if binding["backend"]!="workflow" or binding["branch"]!="":
        print("shape-at-%d" % index); raise SystemExit(0)
    if binding["result_path"]!=row["result"] or binding["status_path"]!=row["status"]:
        print("paths-at-%d" % index); raise SystemExit(0)
print("ok")
PY
)"
  [ "$matched" = ok ] \
    && pass "B[$label] pool position i binds ledger row i, in roster order ($matched)" \
    || fail "B[$label] pool/ledger cross-check failed: $matched"

  # Every child directory the script will derive exists, and it was made before
  # the binding (realpath stability).
  for slug_dir in "$out/repo/.uberdev/research/20260101-000000-abc123/children/"*-iter01; do
    [ -d "$slug_dir" ] || { fail "B[$label] a derived child directory is missing"; return; }
  done
  [ "$(find "$out/repo/.uberdev/research/20260101-000000-abc123/children" -maxdepth 1 -type d -name '*-iter01' | wc -l | tr -d ' ')" = "$count" ] \
    && pass "B[$label] all $count per-child directories exist under children/" \
    || fail "B[$label] the per-child directory count does not match the roster"
}

assert_stage review-stage "$REVIEW_CMD" 'stage=review' review-pr review 7 review-fleet-review.launched

# B[review-contract] — the review and fix stages own output contracts (the
# simplify and defer stages do not), so these are standalone blocks rather than a
# parameter on the shared assert_stage helper. Each runs the REAL fence against
# the REAL plugin root, so it proves the value the envelope carries is the file
# the plugin ships — not merely that a key exists.
B_CONTRACT_OUT="$TMP/b-review-contract"
mkdir -p "$B_CONTRACT_OUT"
if B_CONTRACT_RAW="$(run_stage_fence "$REVIEW_CMD" 'stage=review' "$B_CONTRACT_OUT")"; then
  B_CONTRACT_ENV="$(printf '%s\n' "$B_CONTRACT_RAW" | envelope_of)"
  B_CONTRACT_VAL="$(printf '%s' "$B_CONTRACT_ENV" | jq -r '.config.phase1ContractPathAbs // ""')"
  B_CONTRACT_WANT="$REPO_ROOT/plugins/uberdev/$(jq -r '.output_contracts["phase1-reviewer-v1"] // empty' \
    "$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json")"
  [ "$B_CONTRACT_VAL" = "$B_CONTRACT_WANT" ] \
    && pass "B[review-contract] the envelope carries the manifest-resolved contract path" \
    || fail "B[review-contract] envelope carried '$B_CONTRACT_VAL', manifest resolves to '$B_CONTRACT_WANT'"
  [ -n "$B_CONTRACT_VAL" ] && [ -f "$B_CONTRACT_VAL" ] \
    && pass "B[review-contract] the emitted contract path names a file that exists on disk" \
    || fail "B[review-contract] the emitted contract path is not a readable file: '$B_CONTRACT_VAL'"
else
  fail "B[review-contract] the extracted fence did not run: $(head -3 "$B_CONTRACT_OUT/fence.err" 2>/dev/null)"
fi
# B[fixer-contract] — #474. The fixer edges carry a format contract for a
# STRICTER reason than the reviewers: a reviewer whose result is refused has
# produced nothing and the run fails closed with the tree untouched, but a fixer
# has ALREADY COMMITTED by the time its result is parsed, so an unbound format
# strands unattributed history and halts the run MUTATED_BLOCKED.
#
# ALL THREE COMMITTING FENCES, ACROSS BOTH COMMAND FILES. The `stage=fix` arm in
# workflow.js is shared and is NOT mode-scoped the way the review arm is, so its
# `bad_contract_path` guard governs `mode=simplify` too. Checking only the two
# `review_pr.fix.*` fences in $REVIEW_CMD is what let `simplify.fix.phase2` ship
# the guard without the key: measured, that envelope aborted `bad_contract_path`
# with zero dispatches, i.e. /simplify lost its Phase 2 fixer outright on the
# RFC 0015 default transport. The loop therefore iterates FILE + EDGE pairs.
#
# WHAT THIS BLOCK PROVES, precisely. Unlike B[review-contract] above it does NOT
# execute the fence: a fixer fence reaches its emit only after prepare-authority
# validates a REAL commit range against a REAL repository, so executing it would
# mean seeding a fixture with live SHAs and a clean-worktree gate — machinery
# that belongs to the authority path, not to this wiring. So the assertions are
# made against the EXTRACTED FENCE BODY, not the whole file: a `code-fixer-v1`
# mention anywhere else in this 7000-line command cannot satisfy them. The
# runtime half is covered where it can be executed — the manifest resolution by
# tests/solve-run-tree.test.sh, and the script's consumption of the key by the
# W section below, which runs workflow.js for real.
B_FIXER_CONTRACT_FILE="$(jq -r '.output_contracts["code-fixer-v1"] // empty' \
  "$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json")"
[ -n "$B_FIXER_CONTRACT_FILE" ] && [ -f "$REPO_ROOT/plugins/uberdev/$B_FIXER_CONTRACT_FILE" ] \
  && pass "B[fixer-contract] the manifest resolves code-fixer-v1 to a file the plugin ships" \
  || fail "B[fixer-contract] code-fixer-v1 resolves to '$B_FIXER_CONTRACT_FILE', which is not a shipped file"
for B_FIXER_PAIR in "$REVIEW_CMD|review_pr.fix.phase1" \
                    "$REVIEW_CMD|review_pr.fix.phase2" \
                    "$SIMPLIFY_CMD|simplify.fix.phase2"; do
  B_FIXER_FILE="${B_FIXER_PAIR%%|*}"
  B_FIXER_EDGE="${B_FIXER_PAIR##*|}"
  if B_FIXER_BODY="$(extract_fence "$B_FIXER_FILE" "fixerEdgeId=$B_FIXER_EDGE")"; then
    # Herestrings, not `printf | grep -q`: this file sets pipefail, and an
    # early-exiting reader closes the pipe under the writer, which tests/
    # epipe-guard.test.sh flags (and which would make these rows fail for a
    # reason that has nothing to do with the fence).
    grep -q 'review_fleet_contract_path "\$UBERDEV_REVIEW_PLUGIN_ROOT" code-fixer-v1' <<<"$B_FIXER_BODY" \
      && pass "B[fixer-contract] $B_FIXER_EDGE resolves the contract through the manifest helper" \
      || fail "B[fixer-contract] $B_FIXER_EDGE does not resolve code-fixer-v1 via review_fleet_contract_path"
    grep -q 'fixerContractPathAbs="\$REVIEW_FLEET_FIXER_CONTRACT_PATH"' <<<"$B_FIXER_BODY" \
      && pass "B[fixer-contract] $B_FIXER_EDGE emits the resolved path into the envelope" \
      || fail "B[fixer-contract] $B_FIXER_EDGE does not emit fixerContractPathAbs (in $(basename "$B_FIXER_FILE"))"
  else
    fail "B[fixer-contract] no fence found for $B_FIXER_EDGE in $(basename "$B_FIXER_FILE")"
  fi
done
# The script half: the contract path must reach the child's prompt, and the
# stage must refuse a mis-wired envelope BEFORE it dispatches a child that would
# commit against no format binding.
grep -q 'function fixerOutputContract()' "$WORKFLOW" \
  && grep -q 'lines.push(fixerOutputContract());' "$WORKFLOW" \
  && pass "B[fixer-contract] workflow.js binds the fixer prompt to the contract" \
  || fail "B[fixer-contract] workflow.js does not push a fixer output contract into the prompt"
grep -q 'isSafeAbsPath(fixerContractPathAbs)' "$WORKFLOW" \
  && pass "B[fixer-contract] the fix stage refuses an unusable contract path before dispatch" \
  || fail "B[fixer-contract] the fix stage does not guard fixerContractPathAbs"
# B[lens-contract] (#481) — lensPrompt used to say only "follow the agent
# instructions", while boundChildProtocol goes on to say "write your full
# report". A whole-file grammar pinned ONLY in the agent file is contradicted by
# the prompt the lens actually reads, which is how the three lenses drifted into
# three document shapes. Phase 1 resolves that contradiction with an explicit
# FORMAT-scoped override; Phase 2 must too.
B_LENS_BODY="$(awk '/^function lensPrompt\(/{a=1} a{print} a&&/^}$/{exit}' "$WORKFLOW")"
grep -q 'lines.push(phase2OutputContract(' <<<"$B_LENS_BODY" \
  && pass "B[lens-contract] lensPrompt pushes an explicit output contract" \
  || fail "B[lens-contract] lensPrompt does not push a Phase 2 output contract"
B_LENS_CONTRACT="$(awk '/^function phase2OutputContract\(lens\) \{/{a=1} a{print} a&&/^}$/{exit}' "$WORKFLOW")"
for B_LENS_RULE in 'entire contents of the result file' 'findings:' 'blocker' 'suggestion' 'findings: \[\]'; do
  grep -q "$B_LENS_RULE" <<<"$B_LENS_CONTRACT" \
    && pass "B[lens-contract] the Phase 2 contract states '$B_LENS_RULE'" \
    || fail "B[lens-contract] the Phase 2 contract omits '$B_LENS_RULE'"
done
grep -q 'output FORMAT' <<<"$B_LENS_CONTRACT" \
  && pass "B[lens-contract] the Phase 2 override is scoped to FORMAT, not to the secret-leak rule" \
  || fail "B[lens-contract] the Phase 2 override must scope itself to FORMAT explicitly"

assert_stage lens-stage-simplify-cmd "$SIMPLIFY_CMD" 'stage=simplify' simplify simplify 3 review-fleet-simplify.launched
assert_stage lens-stage-review-cmd "$REVIEW_CMD" 'stage=simplify' review-pr simplify 3 review-fleet-simplify.launched

# B-neg — the pool guard is what turns a short roster into a refusal instead of
# an unbound child. Prove it fires rather than trusting the happy path.
GUARD_RC="$(bash -c '. "$1"; review_fleet_pool_guard review "$(printf a%.0s $(seq 64)),$(printf b%.0s $(seq 64))" >/dev/null 2>&1; echo $?' _ "$ARGS_LIB")"
[ "$GUARD_RC" != 0 ] \
  && pass "B-neg a pool shorter than the roster is refused before dispatch" \
  || fail "B-neg a two-entry pool was accepted for a six-child roster"
GUARD_RC="$(bash -c '. "$1"; review_fleet_pool_guard simplify "$(printf a%.0s $(seq 64)),$(printf b%.0s $(seq 64)),$(printf c%.0s $(seq 64)),$(printf d%.0s $(seq 64))" >/dev/null 2>&1; echo $?' _ "$ARGS_LIB")"
[ "$GUARD_RC" != 0 ] \
  && pass "B-neg a pool longer than the roster is refused too (controller/script disagree)" \
  || fail "B-neg an over-long pool was accepted"
GUARD_RC="$(bash -c '. "$1"; review_fleet_pool_guard review "not-hex,not-hex,not-hex,not-hex,not-hex,not-hex" >/dev/null 2>&1; echo $?' _ "$ARGS_LIB")"
[ "$GUARD_RC" != 0 ] \
  && pass "B-neg a right-sized pool of malformed nonces is still refused" \
  || fail "B-neg malformed nonces passed the pool guard"

# ---------------------------------------------------------------------------
# W — EVERY stage is EXECUTED, not grepped
# ---------------------------------------------------------------------------
# The gap this closes: a ReferenceError inside one stage's prompt builder is
# invisible to every other check in this repo. The G-section greps read the
# command files, not the script; tests/workflow-scripts.test.sh T3 runs the
# script once with `config: {}`, so `stage` is "" and it guard-aborts before
# any prompt builder is entered; and main()'s DR-8 catch SWALLOWS the throw
# into a `run_threw` audit event and still returns a structured result with
# `dispatched` already incremented. The observable failure is therefore a
# successful-looking return with no child — the exact shape the controller
# then normalises to MALFORMED.
#
# So: run the real script, once per stage, under the same preprocess the
# workflow harness uses (strip the meta block, wrap in an async IIFE, execute
# under stubs), and require of every stage that it dispatched the children it
# claims to and recorded NO run_threw. `abortReason` must be empty too — a
# stage that guard-aborts on a valid envelope is a wiring bug, not a refusal.
echo
echo "== W: every review-fleet stage EXECUTES (prompt builders included) =="

W_HARNESS="$TMP/stage_harness.mjs"
cat >"$W_HARNESS" <<'WHARNESS'
// Executes skills/review-fleet/workflow.js for ONE stage under runtime stubs.
// argv: <workflow.js> <args-json-file> [<agent-return-json-file>]. Prints one
// JSON line:
//   {"threw":<string|null>,"abortReason":...,"dispatched":N,"labels":[...],
//    "prompts":[...],"result":<the parsed WORKFLOW_RESULT|null>,"logs":[...]}
//
// The optional THIRD argv REPLACES the canned agent() return with the parsed
// contents of that file. It is opt-in on purpose: editing the canned return in
// place would feed extra keys into all ten existing assert_stage_runs rows and
// change recordChild's behaviour for every stage at once. Rows that assert on
// what the script does with a child's RETURN pass an override; rows that assert
// on prompts or roster size pass nothing and see byte-identical behaviour.
import fs from 'node:fs';
import vm from 'node:vm';

const scriptPath = process.argv[2];
const source = fs.readFileSync(scriptPath, 'utf8');
// Same preprocess as tests/_workflow_harness.js: the meta block is an ESM
// `export`, which vm cannot evaluate, and the file's top level is `await`ed.
const body = source.replace(/\/\* META-BEGIN \*\/[\s\S]*?\/\* META-END \*\//, '');
const wrapped = '(async () => {\n' + body + '\n})()';

const RETURN_DEFAULT = { status: 'COMPLETE', issuesCreated: [], commentedUrls: [],
                         skipped: 0, halted: false, resultPath: '', statusPath: '' };
const agentReturn = process.argv[4]
  ? JSON.parse(fs.readFileSync(process.argv[4], 'utf8'))
  : RETURN_DEFAULT;

const logs = [];
const labels = [];
const prompts = [];
const sandbox = {
  args: fs.readFileSync(process.argv[3], 'utf8'),   // the runtime hands a STRING
  log: (m) => { logs.push(String(m)); },
  phase: () => {},
  // A canned return that satisfies every stage's schema loosely; the point of
  // this harness is reaching and evaluating the prompt builders, not asserting
  // on the returns (recordChild's path check is covered by the B section).
  agent: async (prompt, opts) => {
    if (typeof prompt !== 'string' || prompt.length === 0) {
      throw new Error('prompt builder produced a non-string prompt');
    }
    labels.push(opts && opts.label);
    prompts.push(prompt);
    return agentReturn;
  },
  parallel: async (thunks) => Promise.all(thunks.map(async (t) => {
    try { return await t(); } catch { return null; }
  })),
  pipeline: async () => [],
  workflow: async () => ({}),
  // Opt-in via env so no existing row's argv changes. Unset (or 0) keeps the
  // historical `null`, which is what every other row in this file runs under —
  // budgetExhausted() short-circuits on a falsy budget, so those rows see
  // byte-identical behaviour. Set, it models the runtime's own token budget:
  // one unit per dispatched agent, so a total of N exhausts the moment the Nth
  // child returns. That is the ONLY way to reach the mid-fanout guard, which is
  // why it had no row at all until now.
  budget: null,
};
const W_BUDGET_TOTAL = Number(process.env.W_BUDGET_TOTAL || 0);
if (W_BUDGET_TOTAL > 0) {
  sandbox.budget = {
    total: W_BUDGET_TOTAL,
    remaining: () => Math.max(0, W_BUDGET_TOTAL - labels.length),
  };
}
sandbox.globalThis = sandbox;

let threw = null;
try {
  await vm.runInNewContext(wrapped, vm.createContext(sandbox),
    { filename: scriptPath, timeout: 20000 });
} catch (e) {
  threw = (e && e.message) ? e.message : String(e);
}
const resultLine = logs.filter((l) => l.indexOf('WORKFLOW_RESULT ') === 0).pop();
const result = resultLine ? JSON.parse(resultLine.slice('WORKFLOW_RESULT '.length)) : null;
// main()'s catch turns an in-stage throw into a `run_threw` audit event rather
// than a rejection, so surface BOTH channels or the swallowed one stays hidden.
const swallowed = result && Array.isArray(result.auditEvents)
  ? result.auditEvents.filter((e) => e && e.event === 'run_threw').map((e) => e.reason)
  : [];
process.stdout.write(JSON.stringify({
  threw: threw || (swallowed.length ? swallowed.join('; ') : null),
  abortReason: result ? result.abortReason : 'NO_RESULT_EMITTED',
  dispatched: result ? result.dispatched : -1,
  labels: labels,
  prompts: prompts,
  // The WHOLE structured return and the WHOLE log tape, so a row can assert on
  // what the script REPORTED about a child rather than only on what it asked
  // one for. Without these two channels a return-carried field can be requested
  // by every prompt, validated by the schema, and dropped on the floor with
  // every fixture still green — the defect class #514 names.
  result: result,
  logs: logs,
}) + '\n');
WHARNESS

W_HEX64_A="$(printf 'ab%.0s' $(seq 32))"
W_NONCE1="$(printf '0%.0s' $(seq 63))1"
W_NONCE2="$(printf '0%.0s' $(seq 63))2"
W_NONCE3="$(printf '0%.0s' $(seq 63))3"
W_NONCE4="$(printf '0%.0s' $(seq 63))4"
W_NONCE5="$(printf '0%.0s' $(seq 63))5"
W_NONCE6="$(printf '0%.0s' $(seq 63))6"
# #433: the review roster is seven. nonceGate(REVIEW_ROSTER.length) refuses a
# pool whose length is not exactly the roster's, so a six-nonce pool aborts the
# whole review stage before a single prompt is built.
W_NONCE7="$(printf '0%.0s' $(seq 63))7"

# stage_args STAGE NONCES EXTRA_JSON -> writes $TMP/w-args.json
stage_args() {
  jq -n --arg stage "$1" --arg nonces "$2" --arg sha "$W_HEX64_A" \
        --argjson extra "$3" '
    {v:1, run_id:"W-RUN", now_epoch:0, now_iso:"1970-01-01T00:00:00Z",
     plugin_root:"/p", repo_root:"/r", cwd:"/r",
     config: ({
       mode:"review-pr", stage:$stage,
       pluginRootAbs:"/p", repoRootAbs:"/r", workingDirAbs:"/r",
       runDirAbs:"/r/run", startedAtIso:"1970-01-01T00:00:00Z",
       prNumber:1, reviewIteration:1, repoSlug:"o/r",
       diffPathAbs:"/r/run/diff.txt",
       # The Phase 1 reviewer output contract, resolved by the controller and
       # carried BY PATH (#403). The root is fake and the script never opens it
       # — this key exists in the base object rather than per-call `extra` so
       # every existing assert_stage_runs row stays green once the review arm
       # fails closed on a missing one.
       phase1ContractPathAbs:"/p/shared/phase1-reviewer-output-v1.md",
       # The code-fixer output contract (#474), same placement and same reason:
       # the fix arm now fails closed on a missing one, so it belongs in the base
       # object where every existing fix-stage row picks it up.
       fixerContractPathAbs:"/p/shared/code-fixer-output-v1.md",
       # The rule-source allowlist for the convention lens, also BY PATH
       # (#433). Same placement reasoning: base object, so every existing row
       # keeps its envelope shape while the convention-only rows below can
       # assert on it.
       ruleSourcesPathAbs:"/r/run/post-review/rule-sources.txt",
       phase1PathAbs:"/r/run/p1.md", phase2PathAbs:"/r/run/p2.md",
       phase1DispositionPathAbs:"/r/run/d1.json",
       phase2DispositionPathAbs:"/r/run/d2.json",
       workspaceMode:"caller", worktreeAbs:"/r", branchName:"feat/x",
       runNonces:$nonces
     } + $extra)}' >"$TMP/w-args.json"
}

# assert_stage_runs LABEL STAGE NONCES EXTRA_JSON EXPECTED_CHILDREN
assert_stage_runs() {
  local label="$1" stage="$2" nonces="$3" extra="$4" expected="$5" out
  stage_args "$stage" "$nonces" "$extra"
  out="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)" || {
    fail "W[$label] harness itself failed: $out"; return
  }
  local threw abort dispatched
  threw="$(printf '%s' "$out" | jq -r '.threw // "null"')"
  abort="$(printf '%s' "$out" | jq -r '.abortReason')"
  dispatched="$(printf '%s' "$out" | jq -r '.dispatched')"
  if [ "$threw" != null ]; then
    fail "W[$label] stage=$stage THREW: $threw"
    return
  fi
  if [ -n "$abort" ]; then
    fail "W[$label] stage=$stage guard-aborted on a valid envelope: $abort"
    return
  fi
  local agents
  agents="$(printf '%s' "$out" | jq -r '.labels | length')"
  if [ "$agents" != "$expected" ]; then
    fail "W[$label] stage=$stage dispatched $agents agent(s), expected $expected (dispatched=$dispatched)"
    return
  fi
  pass "W[$label] stage=$stage executes end-to-end and dispatches $expected child(ren)"
}

# stage_run_with_return STAGE NONCES EXTRA_JSON RETURN_JSON -> echoes the
# harness JSON line for the caller to `jq`.
#
# The sibling of assert_stage_runs for rows that assert on `.result` / `.logs`
# rather than on the roster: it deliberately asserts NOTHING itself, because a
# row driving a hostile child return (a 5000-character note, an unrecognised
# failure class) is asking what the script REPORTS, not how many children it
# dispatched — that half is already locked by the assert_stage_runs row above.
stage_run_with_return() {
  local stage="$1" nonces="$2" extra="$3" ret="$4"
  printf '%s' "$ret" >"$TMP/w-ret.json"
  stage_args "$stage" "$nonces" "$extra"
  node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" "$TMP/w-ret.json" 2>&1
}

# The same runner under a FINITE token budget. Separate from the two above so no
# existing row's environment changes: the budget stub is inert unless this
# variable is set, and only the rows below set it.
stage_run_with_budget() {  # STAGE NONCES EXTRA_JSON BUDGET_TOTAL -> harness JSON
  local stage="$1" nonces="$2" extra="$3" total="$4"
  stage_args "$stage" "$nonces" "$extra"
  W_BUDGET_TOTAL="$total" node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1
}

# --- W-H: the harness extension itself, proved before anything depends on it -
# A test-infrastructure change that silently no-ops turns every row built on it
# into a vacuous pass, so the two channels the X5/X6 sections read (`.result`,
# `.logs`) and the return-override seam are asserted here, first.
W_REVIEW_NONCES="$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6,$W_NONCE7"
W_H1_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n '{status:"COMPLETE",
  issuesCreated:[], commentedUrls:[], skipped:0, halted:false, resultPath:"", statusPath:""}')")"
if [ "$(jq -r '.result.children[0].note // ""' <<<"$W_H1_OUT")" = "" ] \
   && [ "$(jq -r '.logs | length' <<<"$W_H1_OUT")" -gt 0 ] 2>/dev/null \
   && [ "$(jq -r '.result.children | length' <<<"$W_H1_OUT")" = 7 ]; then
  pass "W-H1 the harness surfaces .result and .logs, and the DEFAULT agent return is unchanged"
else
  fail "W-H1 the harness's new .result/.logs channels are missing or the default return moved: $(jq -c '{n:(.result.children|length),logs:(.logs|length)}' <<<"$W_H1_OUT")"
fi
W_H2_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n '{status:"COMPLETE",
  resultPath:"", statusPath:"", verdict:"HARNESS-OVERRIDE-PROBE"}')")"
if [ "$(jq -r '.result.children[0].verdict' <<<"$W_H2_OUT")" = "HARNESS-OVERRIDE-PROBE" ]; then
  pass "W-H2 the optional agent-return override really reaches recordChild"
else
  fail "W-H2 the agent-return override never reached the script: $(jq -c '.result.children[0]' <<<"$W_H2_OUT")"
fi

W_CI_COMMON="$(jq -n --arg sha "$W_HEX64_A" '{
  ciLoopIter:1, ciAuthorityPathAbs:"/r/run/ci-auth.json",
  ciAuthoritySha256:$sha, ciInputSha256:$sha,
  ciRunId:"12345", ciHeadSha:"0000000000000000000000000000000000000000",
  ciBaseSha:"0000000000000000000000000000000000000000",
  ciPrBranch:"feat/x", ciBaseBranch:"main"}')"

assert_stage_runs review review \
  "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6,$W_NONCE7" '{}' 7
assert_stage_runs simplify simplify "$W_NONCE1,$W_NONCE2,$W_NONCE3" '{}' 3
# The two fix envelopes, hoisted to variables because the W-CONTRACT block below
# drives the SAME two through the `bad_contract_path` mutations (#474). One
# spelling per envelope: a fix arm proved reachable on one shape and gated on a
# differently-spelled twin would be proving nothing about the shape it gates.
W_FIX_COMMON="$(jq -n --arg sha "$W_HEX64_A" '{fixerEdgeId:"review_pr.fix.phase1", commitType:"fix",
   findingsPathAbs:"/r/run/f.md", findingsSha256:$sha,
   commitRangePathAbs:"/r/run/cr.json", commitRangeSha256:$sha,
   authorityPathAbs:"/r/run/a.json", authoritySha256:$sha,
   dispositionPathAbs:"/r/run/disp.json", appliedContentPathAbs:"/r/run/ac.json"}')"
# THE THIRD COMMITTING EDGE, and the only one reached under mode=simplify
# (commands/simplify.md's Workflow-native Phase 2 fence). It carries the
# standalone-snapshot family instead of the commit-range family, and it is the
# envelope the shared `stage=fix` arm refused outright when its emitter omitted
# `fixerContractPathAbs`: measured on the pre-fix tree, abort=bad_contract_path
# with dispatched=0 where the base script dispatched 1.
W_FIX_SIMPLIFY="$(jq -n --arg sha "$W_HEX64_A" '{mode:"simplify",
   fixerEdgeId:"simplify.fix.phase2", commitType:"refactor",
   findingsPathAbs:"/r/run/agg.md", findingsSha256:$sha,
   standaloneSnapshotPathAbs:"/r/run/snap.json", standaloneSnapshotSha256:$sha,
   authorityPathAbs:"/r/run/a.json", authoritySha256:$sha,
   dispositionPathAbs:"/r/run/d2.json",
   appliedContentPathAbs:"/r/run/standalone-applied-content.json"}')"

assert_stage_runs fix fix "$W_NONCE1" "$W_FIX_COMMON" 1
assert_stage_runs fix-simplify fix "$W_NONCE1" "$W_FIX_SIMPLIFY" 1
# THE #383 REGRESSION: the shipped Phase 2.5 stage. It is reached by BOTH
# /review-pr and /simplify and it is the one stage no other test executes.
assert_stage_runs defer defer "$W_NONCE1" '{}' 1

# --- W-DISP: the defer stage's disposition-path gate, in BOTH directions ----
# The gate had no row at all, and it refused EVERY empty value. That made the
# ordinary clean review undispatchable: a Phase 1 returning APPROVE with no
# blocker never runs a fixer, so no disposition is ever published, and the only
# other value the controller can pass is the zero-byte file it created itself —
# which agents/findings-to-issues.md refuses as `input-malformed` (#556). Both
# input forms rejected, so Phase 2.5 could not run on the path it exists for.
# `optional_path` is the type policy/solve-run-tree-v1.json and the callsite
# fixture both give these keys, commands/simplify.md already passes them empty
# on the routed transport, and ciDeferPrompt() in this same script hands the
# same agent both empty. What must still bite is a NON-EMPTY unsafe value.
w_disp_out() {  # w_disp_out PHASE1_VALUE PHASE2_VALUE -> the harness JSON line
  stage_args defer "$W_NONCE1" \
    "$(jq -n --arg p1 "$1" --arg p2 "$2" \
       '{phase1DispositionPathAbs:$p1, phase2DispositionPathAbs:$p2}')"
  node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1
}

W_DISP_BOTH="$(w_disp_out '' '')"
if [ -z "$(jq -r '.abortReason' <<<"$W_DISP_BOTH")" ] \
   && [ "$(jq -r '.dispatched' <<<"$W_DISP_BOTH")" = 1 ]; then
  pass "W-DISP1 both disposition paths declared empty (the clean review) dispatches Phase 2.5"
else
  fail "W-DISP1 the clean-review shape was refused: $(jq -c '{abortReason,dispatched}' <<<"$W_DISP_BOTH")"
fi

W_DISP_P1="$(w_disp_out '' '/r/run/d2.json')"
if [ -z "$(jq -r '.abortReason' <<<"$W_DISP_P1")" ] \
   && [ "$(jq -r '.dispatched' <<<"$W_DISP_P1")" = 1 ]; then
  pass "W-DISP2 an empty Phase 1 disposition alone (no Phase 1 fixer) dispatches"
else
  fail "W-DISP2 empty Phase 1 disposition refused: $(jq -c '{abortReason,dispatched}' <<<"$W_DISP_P1")"
fi

W_DISP_P2="$(w_disp_out '/r/run/d1.json' '')"
if [ -z "$(jq -r '.abortReason' <<<"$W_DISP_P2")" ] \
   && [ "$(jq -r '.dispatched' <<<"$W_DISP_P2")" = 1 ]; then
  pass "W-DISP3 an empty Phase 2 disposition alone (no Phase 2 fixer) dispatches"
else
  fail "W-DISP3 empty Phase 2 disposition refused: $(jq -c '{abortReason,dispatched}' <<<"$W_DISP_P2")"
fi

# ANTI-VACUITY for the three rows above: relaxing the gate to accept the empty
# string must not relax it to accept a RELATIVE one, which is the value that
# would render into the prompt and leave the agent to improvise a location.
W_DISP_REL1="$(w_disp_out 'run/d1.json' '/r/run/d2.json')"
if [ "$(jq -r '.abortReason' <<<"$W_DISP_REL1")" = bad_disposition_path ] \
   && [ "$(jq -r '.dispatched' <<<"$W_DISP_REL1")" = 0 ]; then
  pass "W-DISP4 a relative Phase 1 disposition path still aborts bad_disposition_path"
else
  fail "W-DISP4 relative Phase 1 disposition path was accepted: $(jq -c '{abortReason,dispatched}' <<<"$W_DISP_REL1")"
fi

W_DISP_REL2="$(w_disp_out '/r/run/d1.json' 'run/d2.json')"
if [ "$(jq -r '.abortReason' <<<"$W_DISP_REL2")" = bad_disposition_path ] \
   && [ "$(jq -r '.dispatched' <<<"$W_DISP_REL2")" = 0 ]; then
  pass "W-DISP5 a relative Phase 2 disposition path still aborts bad_disposition_path"
else
  fail "W-DISP5 relative Phase 2 disposition path was accepted: $(jq -c '{abortReason,dispatched}' <<<"$W_DISP_REL2")"
fi

# The child must be able to tell "declared empty" from "the controller lost it",
# because those two demand opposite behaviour: default the phase's rows to
# DEFERRED, or refuse. A bare `=` says neither.
W_DISP_PROMPT="$(jq -r '.prompts[0] // ""' <<<"$W_DISP_BOTH")"
if grep -qF 'no Phase 1 fixer ran, so no disposition exists' <<<"$W_DISP_PROMPT" \
   && grep -qF 'no Phase 2 fixer ran, so no disposition exists' <<<"$W_DISP_PROMPT"; then
  pass "W-DISP6 an empty disposition path reaches the child DECLARED empty, not as a bare ="
else
  fail "W-DISP6 the empty disposition path rendered with no stated meaning"
fi

W_DISP_PROMPT_FULL="$(jq -r '.prompts[0] // ""' <<<"$W_DISP_P2")"
if grep -qF 'no Phase 1 fixer ran, so no disposition exists' <<<"$W_DISP_PROMPT_FULL"; then
  fail "W-DISP7 the declared-empty marker is emitted for a NON-empty path, so W-DISP6 proves nothing"
else
  pass "W-DISP7 a supplied disposition path carries no declared-empty marker"
fi

# --- W-DISPC: the CONTROLLER half of the same fix, on BOTH defer fences -----
# W-DISP1–7 above hold the script-side gate. The other half — the guard in each
# defer fence that turns an absent or zero-byte disposition file into the empty
# value BEFORE it is passed — was held by nothing: no test names the DEFER_
# variables, the Workflow-native fence is executed by no test at all (this
# file's harness synthesises the envelope directly), and the routed fence is
# driven only by the review-child-inputs defer fixture, whose two disposition
# files are both NON-EMPTY, so the guard's branch never ran there and that
# fixture's exact-payload assertion passes identically with the guard deleted.
# Reverting the controller half therefore left every suite green while Phase 2.5
# broke again on the next clean review.
#
# The guard is EXECUTED here, not grepped: the region is lifted verbatim out of
# commands/review-pr.md and run against the three states the file can be in.
# FIXED STRINGS, never regexes: both markers are shell, so they are made almost
# entirely of regex metacharacters ([ ] $ { } | *), and awk rejects `\|` outright.
W_DISPC_BEGIN='if [ -z "${PHASE1_DISPOSITION_PATH:-}" ]'
W_DISPC_END='[ -s "$PHASE2_DISPOSITION_PATH" ] || DEFER_PHASE2_DISPOSITION_PATH='"''"
W_DISPC_COUNT="$(grep -cF "$W_DISPC_END" "$REVIEW_CMD")"
if [ "$W_DISPC_COUNT" = 2 ]; then
  pass "W-DISPC0 both defer fences (routed and Workflow-native) carry the disposition guard"
else
  fail "W-DISPC0 expected the disposition guard in 2 defer fences, found $W_DISPC_COUNT"
fi

# Lift each occurrence into its own file, so a guard present in one fence and
# missing from the other cannot pass on its sibling's behalf.
awk -v b="$W_DISPC_BEGIN" -v e="$W_DISPC_END" -v out="$TMP/w-dispc-" '
  index($0, b) { n += 1; grab = 1 }
  grab { sub(/^[[:space:]]+/, ""); print > (out n ".sh") }
  grab && index($0, e) { grab = 0 }
' "$REVIEW_CMD"

w_dispc_drive() {  # w_dispc_drive FENCE_FILE P1_VALUE P2_VALUE -> "<p1>|<p2>|<warned>"
  local fence="$1" p1="$2" p2="$3" warned out
  out="$(PHASE1_DISPOSITION_PATH="$p1" PHASE2_DISPOSITION_PATH="$p2" bash -c '
    set -u
    . "$1" 2>"$2"
    printf "%s|%s" "$DEFER_PHASE1_DISPOSITION_PATH" "$DEFER_PHASE2_DISPOSITION_PATH"
  ' _ "$fence" "$TMP/w-dispc-warn.txt")" || { printf 'DRIVE-FAILED||'; return; }
  warned=no
  grep -qF 'is LOST' "$TMP/w-dispc-warn.txt" && warned=yes
  printf '%s|%s' "$out" "$warned"
}

W_DISPC_REAL="$TMP/w-dispc-real.json"
printf '{"findings_disposition":[]}' >"$W_DISPC_REAL"
W_DISPC_ZERO="$TMP/w-dispc-zero.json"
: >"$W_DISPC_ZERO"
W_DISPC_GONE="$TMP/w-dispc-absent.json"
rm -f "$W_DISPC_GONE"

for w_dispc_n in 1 2; do
  w_dispc_fence="$TMP/w-dispc-$w_dispc_n.sh"
  # A real disposition is passed THROUGH untouched — the anti-vacuity half: a
  # guard that blanked everything would satisfy the two rows below.
  if [ "$(w_dispc_drive "$w_dispc_fence" "$W_DISPC_REAL" "$W_DISPC_REAL")" \
       = "$W_DISPC_REAL|$W_DISPC_REAL|no" ]; then
    pass "W-DISPC${w_dispc_n}a fence $w_dispc_n passes a real disposition through unchanged"
  else
    fail "W-DISPC${w_dispc_n}a fence $w_dispc_n mangled a real disposition: $(w_dispc_drive "$w_dispc_fence" "$W_DISPC_REAL" "$W_DISPC_REAL")"
  fi
  # The zero-byte file the workspace pre-creates: emptiness travels as the empty
  # string, and it is NOT a lost record, so it is not warned about.
  if [ "$(w_dispc_drive "$w_dispc_fence" "$W_DISPC_ZERO" "$W_DISPC_ZERO")" = "||no" ]; then
    pass "W-DISPC${w_dispc_n}b fence $w_dispc_n turns a zero-byte disposition into the declared-empty value"
  else
    fail "W-DISPC${w_dispc_n}b fence $w_dispc_n did not empty a zero-byte disposition: $(w_dispc_drive "$w_dispc_fence" "$W_DISPC_ZERO" "$W_DISPC_ZERO")"
  fi
  # A path naming no file is a LOST record wearing the same clothes: it still
  # travels empty (the child's contract has no third form) but it is named.
  if [ "$(w_dispc_drive "$w_dispc_fence" "$W_DISPC_GONE" "$W_DISPC_GONE")" = "||yes" ]; then
    pass "W-DISPC${w_dispc_n}c fence $w_dispc_n empties an absent disposition AND reports the loss"
  else
    fail "W-DISPC${w_dispc_n}c fence $w_dispc_n mishandled an absent disposition: $(w_dispc_drive "$w_dispc_fence" "$W_DISPC_GONE" "$W_DISPC_GONE")"
  fi
done

# --- W-UNAP: review_fixer_terminal_outcome, the three-way terminal branch ---
# #556. A Phase 1 fixer that returns REFUSED writes NEITHER artifact the
# controller binds by path: the applied-content document is never created and
# the disposition is left at the zero bytes the workspace pre-created. Every
# fixer fence went straight to `capture-review-terminal`, whose
# `--applied-content-path` is required and whose disposition capture has
# minimum=1 — so a clean refusal could not be captured at all, and the six
# BLOCKER rows it refused were dropped instead of deferred.
#
# The branch that tells those states apart is ONE function, in the fence
# library, because the four fixer fences (Phase 1 and 2 × routed and
# Workflow-native) each held their own copy of the terminal chain — the #370
# "one contract, N uncompared copies" shape this file already polices elsewhere.
#
# EXECUTED, not grepped, and for the same reason W-DISPC is: a three-way branch
# proved by greps passes identically when two of its arms are wired to the same
# verb. The helper is carved out of lib/review-fences.sh by the loader's own
# rule and run against the three states the disposition file can be in, with a
# recording stand-in on CODE_FIXER_CONTRACT so the row observes WHICH verb ran
# and with WHICH flags, never merely that something exited 0.
W_UNAP_FN="$TMP/w-unap-fn.sh"
awk -v b='review_fixer_terminal_outcome() {' '
  index($0, b) == 1 { grab = 1 }
  grab { print }
  grab && $0 == "}" { exit }
' "$FENCES" >"$W_UNAP_FN"

W_UNAP_DEFS="$(grep -cF 'review_fixer_terminal_outcome() {' "$FENCES")"
W_UNAP_BEGINS="$(grep -cF '# BEGIN review-fixer-terminal-outcome-v1' "$FENCES")"
W_UNAP_ENDS="$(grep -cF '# END review-fixer-terminal-outcome-v1' "$FENCES")"
if [ "$W_UNAP_DEFS" = 1 ] && [ "$W_UNAP_BEGINS" = 1 ] && [ "$W_UNAP_ENDS" = 1 ]; then
  pass "W-UNAP0a review_fixer_terminal_outcome is defined exactly once, inside exactly one marker pair"
else
  fail "W-UNAP0a expected one definition in one marker pair, found def=$W_UNAP_DEFS begin=$W_UNAP_BEGINS end=$W_UNAP_ENDS"
fi

# W-UNAP0b — ONE DEFINITION IS ONLY HALF OF ONE OWNER. The other half is that
# nothing else still does the job itself, and that is the half #370 keeps
# catching: the branch owner shipped, three of the four fences kept their
# private copy, and the copies drifted.
#
# So: all four fixer fences (Phase 1 and 2 x routed and Workflow-native) call
# the owner with the binding they bound, and NEITHER underlying verb is spelled
# in the command file at all any more. A fence that quietly kept its own
# `capture-review-terminal` would still pass every behavioural row in this
# section -- the helper it does not call cannot misbehave -- so the count is the
# assertion, not the presence.
#
# This is also the machine-checkable half of "one owner". An RFC 0016
# `CONTRACT:` marker cannot express it: tests/contract_markers.py maps a closed
# VOCABULARY name to the sites that declare it and compares the members those
# sites harvest; it has no notion of a function or a call site.
#
# OCCURRENCES, not matching lines. `grep -c` counts lines, so two call sites
# folded onto one line would total 3 where 4 are owed and the row would go red
# for the right reason by accident -- or, on the stray-verb side, a verb spelled
# twice on one line would count as one. `index()` in a loop is the only cheap
# counter that answers the question actually being asked. No regex and no
# backslash reaches awk here: both needles are shell text, made almost entirely
# of metacharacters, and are matched as FIXED STRINGS.
w_count_occurrences() {  # FILE NEEDLE -> occurrences of NEEDLE in FILE
  awk -v needle="$2" '
    {
      line = $0
      while ((at = index(line, needle)) > 0) {
        n += 1
        line = substr(line, at + length(needle))
      }
    }
    END { print n + 0 }
  ' "$1"
}
W_UNAP_CALLS="$(w_count_occurrences "$REVIEW_CMD" 'review_fixer_terminal_outcome "$REVIEW_FIXER_LAUNCH_BINDING"')"
W_UNAP_STRAY_CAPTURE="$(w_count_occurrences "$REVIEW_CMD" 'capture-review-terminal')"
W_UNAP_STRAY_VALIDATE="$(w_count_occurrences "$REVIEW_CMD" 'validate-review-outcome')"
if [ "$W_UNAP_CALLS" = 4 ] \
   && [ "$W_UNAP_STRAY_CAPTURE" = 0 ] && [ "$W_UNAP_STRAY_VALIDATE" = 0 ]; then
  pass "W-UNAP0b all four fixer fences route through the owner, and neither verb is spelled in the command file"
else
  fail "W-UNAP0b expected 4 owner calls and 0 stray verbs, found calls=$W_UNAP_CALLS capture=$W_UNAP_STRAY_CAPTURE validate=$W_UNAP_STRAY_VALIDATE"
fi

# The stand-in is a PYTHON file, because every call site spells
# `python3 -I -B "$CODE_FIXER_CONTRACT" <verb>`; a shell script on that carrier
# would not be exercising the invocation the fences actually make. It resolves
# its own log paths from __file__ rather than the environment: `-I` is isolated
# mode, and a row that depended on an inherited variable would be one export
# away from silently logging nothing. Four DISTINCT digests, so an extraction
# that reads the right JSON key into the wrong flag is caught.
W_UNAP_SHIM="$TMP/w-unap-contract.py"
cat >"$W_UNAP_SHIM" <<'PY'
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
verb = sys.argv[1] if len(sys.argv) > 1 else ""
flags = {}
rest = sys.argv[2:]
for index in range(0, len(rest) - 1, 2):
    flags[rest[index]] = rest[index + 1]
with open(os.path.join(here, "w-unap-verbs.log"), "a", encoding="utf-8") as stream:
    stream.write(verb + "\n")
with open(os.path.join(here, "w-unap-argv.log"), "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"verb": verb, "flags": flags}, sort_keys=True) + "\n")
# The sentinel makes the NEXT verb refuse the way a real contract refusal does:
# rc 74, nothing on stdout. Logged first, so the row can see how far the chain
# got before it stopped.
if os.path.exists(os.path.join(here, "w-unap-refuse")):
    sys.stderr.write("w-unap stand-in: refusing %s\n" % verb)
    raise SystemExit(74)
if verb == "capture-review-terminal":
    payload = {
        "status_sha256": "a" * 64,
        "result_sha256": "b" * 64,
        "disposition_sha256": "c" * 64,
        "applied_content_sha256": "d" * 64,
    }
elif verb == "validate-review-outcome":
    payload = {"terminal": "validated-non-empty"}
elif verb == "publish-unapplied-terminal":
    payload = {"terminal": "published-unapplied"}
else:
    sys.stderr.write("w-unap stand-in: unexpected verb %r\n" % verb)
    raise SystemExit(64)
sys.stdout.write(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY

W_UNAP_WORKTREE="$TMP/w-unap-worktree"
mkdir -p "$W_UNAP_WORKTREE"
W_UNAP_BINDING='{"run_nonce":"w-unap-nonce"}'
W_UNAP_AUTHORITY="$TMP/w-unap-authority.json"
W_UNAP_AUTHORITY_SHA256="$W_HEX64_A"
W_UNAP_CONTENT="$TMP/w-unap-applied-content.json"
# DISTINCT heads: identical ones would let a helper that passed head_before
# twice satisfy the flag-map rows below.
W_UNAP_HEAD_BEFORE="$(printf '1a%.0s' $(seq 20))"
W_UNAP_HEAD_AFTER="$(printf '2b%.0s' $(seq 20))"
W_UNAP_REAL="$TMP/w-unap-real.json"
printf '{"findings_disposition":[]}' >"$W_UNAP_REAL"
W_UNAP_ZERO="$TMP/w-unap-zero.json"
: >"$W_UNAP_ZERO"
W_UNAP_GONE="$TMP/w-unap-absent.json"
rm -f "$W_UNAP_GONE"

w_unap_drive() {  # w_unap_drive SHELL DISPOSITION_PATH [refuse] -> "<rc>|<stdout>"
  local shell="$1" disposition="$2" refuse="${3:-}" out rc
  : >"$TMP/w-unap-verbs.log"
  : >"$TMP/w-unap-argv.log"
  : >"$TMP/w-unap-stderr.txt"
  rm -f "$TMP/w-unap-refuse"
  [ -z "$refuse" ] || : >"$TMP/w-unap-refuse"
  out="$("$shell" -c '
    set -u
    CODE_FIXER_CONTRACT="$2"
    WORKTREE_ROOT="$3"
    . "$1" || exit 9
    review_fixer_terminal_outcome "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
  ' _ "$W_UNAP_FN" "$W_UNAP_SHIM" "$W_UNAP_WORKTREE" \
      "$W_UNAP_BINDING" "$W_UNAP_AUTHORITY" "$W_UNAP_AUTHORITY_SHA256" \
      "$disposition" "$W_UNAP_CONTENT" "$W_UNAP_HEAD_BEFORE" "$W_UNAP_HEAD_AFTER" \
      2>"$TMP/w-unap-stderr.txt")"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

w_unap_verbs() {  # the verbs the stand-in saw, in order, comma-terminated
  tr '\n' ',' <"$TMP/w-unap-verbs.log"
}

w_unap_flags() {  # w_unap_flags VERB -> that call's flag map, key-sorted
  jq -cS --arg verb "$1" 'select(.verb == $verb) | .flags' <"$TMP/w-unap-argv.log"
}

# bash first, then zsh: the Skill tool runs `bash` fences through /bin/zsh, so a
# bashism in the helper is a live defect that only the second pass can see.
for w_unap_shell in bash zsh; do
  case "$w_unap_shell" in
    bash) w_unap_row="W-UNAP" ;;
    *)    w_unap_row="W-UNAPd" ;;
  esac

  # A NON-EMPTY disposition is today's path, unchanged: capture, then validate.
  # The anti-vacuity half of the whole section — a branch rewired to reach the
  # new publisher unconditionally fails right here.
  w_unap_out="$(w_unap_drive "$w_unap_shell" "$W_UNAP_REAL")"
  w_unap_seen="$(w_unap_verbs)"
  w_unap_validate_flags="$(w_unap_flags validate-review-outcome)"
  w_unap_validate_expected="$(jq -cS -n \
    --arg binding "$W_UNAP_BINDING" --arg authority "$W_UNAP_AUTHORITY" \
    --arg authority_sha "$W_UNAP_AUTHORITY_SHA256" --arg disposition "$W_UNAP_REAL" \
    --arg content "$W_UNAP_CONTENT" --arg worktree "$W_UNAP_WORKTREE" \
    --arg head_before "$W_UNAP_HEAD_BEFORE" --arg head_after "$W_UNAP_HEAD_AFTER" \
    '{"--launch-binding-json":$binding,
      "--authority-path":$authority, "--authority-sha256":$authority_sha,
      "--disposition-path":$disposition, "--disposition-sha256":("c"*64),
      "--applied-content-path":$content, "--applied-content-sha256":("d"*64),
      "--status-sha256":("a"*64), "--result-sha256":("b"*64),
      "--working-dir":$worktree,
      "--head-before":$head_before, "--head-after":$head_after}')"
  if [ "$w_unap_out" = '0|{"terminal":"validated-non-empty"}' ] \
     && [ "$w_unap_seen" = "capture-review-terminal,validate-review-outcome," ]; then
    pass "${w_unap_row}a a non-empty disposition still captures then validates, and never publishes ($w_unap_shell)"
  else
    fail "${w_unap_row}a non-empty disposition took the wrong arm ($w_unap_shell): out=$w_unap_out verbs=$w_unap_seen"
  fi
  if [ "$w_unap_validate_flags" = "$w_unap_validate_expected" ]; then
    pass "${w_unap_row}a2 every captured digest reaches validate-review-outcome on its own flag ($w_unap_shell)"
  else
    fail "${w_unap_row}a2 validate-review-outcome flags drifted ($w_unap_shell): $w_unap_validate_flags"
  fi

  # EXACTLY ZERO BYTES is the refusal the controller must publish for the child.
  w_unap_out="$(w_unap_drive "$w_unap_shell" "$W_UNAP_ZERO")"
  w_unap_seen="$(w_unap_verbs)"
  w_unap_publish_flags="$(w_unap_flags publish-unapplied-terminal)"
  w_unap_publish_expected="$(jq -cS -n \
    --arg binding "$W_UNAP_BINDING" --arg authority "$W_UNAP_AUTHORITY" \
    --arg authority_sha "$W_UNAP_AUTHORITY_SHA256" --arg disposition "$W_UNAP_ZERO" \
    --arg content "$W_UNAP_CONTENT" --arg worktree "$W_UNAP_WORKTREE" \
    --arg head_before "$W_UNAP_HEAD_BEFORE" --arg head_after "$W_UNAP_HEAD_AFTER" \
    '{"--launch-binding-json":$binding,
      "--authority-path":$authority, "--authority-sha256":$authority_sha,
      "--disposition-path":$disposition, "--applied-content-path":$content,
      "--working-dir":$worktree,
      "--head-before":$head_before, "--head-after":$head_after}')"
  if [ "$w_unap_out" = '0|{"terminal":"published-unapplied"}' ] \
     && [ "$w_unap_seen" = "publish-unapplied-terminal," ]; then
    pass "${w_unap_row}b a zero-byte disposition publishes the unapplied terminal instead ($w_unap_shell)"
  else
    fail "${w_unap_row}b zero-byte disposition took the wrong arm ($w_unap_shell): out=$w_unap_out verbs=$w_unap_seen"
  fi
  if [ "$w_unap_publish_flags" = "$w_unap_publish_expected" ]; then
    pass "${w_unap_row}b2 all eight publish-unapplied-terminal flags carry the caller's own values ($w_unap_shell)"
  else
    fail "${w_unap_row}b2 publish-unapplied-terminal flags drifted ($w_unap_shell): $w_unap_publish_flags"
  fi

  # ABSENT is neither. The controller allocates this file, so a path naming no
  # file is workspace loss or tampering — and answering it with a published
  # "nothing was applied" record would fabricate evidence about a run whose
  # artifacts are gone. No verb may run at all.
  w_unap_out="$(w_unap_drive "$w_unap_shell" "$W_UNAP_GONE")"
  w_unap_seen="$(w_unap_verbs)"
  if [ "$w_unap_out" != "0|" ] && [ "${w_unap_out%%|*}" != 0 ] \
     && [ -z "$w_unap_seen" ] \
     && grep -qF 'is LOST' "$TMP/w-unap-stderr.txt"; then
    pass "${w_unap_row}c an absent disposition refuses, names the loss, and invokes no contract verb ($w_unap_shell)"
  else
    fail "${w_unap_row}c absent disposition mishandled ($w_unap_shell): out=$w_unap_out verbs=$w_unap_seen stderr=$(tr '\n' ' ' <"$TMP/w-unap-stderr.txt")"
  fi

  # THE RC BELONGS TO THE SUB-CALL. A helper that swallowed a contract refusal
  # into rc 0 would hand review_promote_validated_fixer_outcome an empty
  # document, and the fence's review_guard_failed_fixer_return arm — the only
  # thing that turns a residue-bearing failure into MUTATED_BLOCKED — would
  # never run. Both arms are driven, because they propagate through different
  # shell shapes (a bare tail call vs `|| return $?` off an assignment).
  w_unap_out="$(w_unap_drive "$w_unap_shell" "$W_UNAP_ZERO" refuse)"
  w_unap_seen="$(w_unap_verbs)"
  if [ "$w_unap_out" = "74|" ] && [ "$w_unap_seen" = "publish-unapplied-terminal," ]; then
    pass "${w_unap_row}e a refusing publish-unapplied-terminal returns its own rc, printing nothing ($w_unap_shell)"
  else
    fail "${w_unap_row}e the unapplied arm did not propagate the refusal ($w_unap_shell): out=$w_unap_out verbs=$w_unap_seen"
  fi

  # And the chain STOPS at the first refusal: a capture that failed must not be
  # followed by a validate over an unset digest.
  w_unap_out="$(w_unap_drive "$w_unap_shell" "$W_UNAP_REAL" refuse)"
  w_unap_seen="$(w_unap_verbs)"
  if [ "$w_unap_out" = "74|" ] && [ "$w_unap_seen" = "capture-review-terminal," ]; then
    pass "${w_unap_row}f a refusing capture stops the chain there and returns its own rc ($w_unap_shell)"
  else
    fail "${w_unap_row}f the capture arm did not fail closed ($w_unap_shell): out=$w_unap_out verbs=$w_unap_seen"
  fi
done

# --- W-UNAP-E2E: the reported incident, start to finish, through THE FENCES -
# The rows above prove the OWNER picks the right verb. These prove the two
# claims the owner cannot make for itself:
#
#   ROUTING -- that the fixer fences actually reach it, with the arguments the
#   run's own state says they owe it. A helper driven directly proves the
#   helper; every fence could still be spelling its own terminal chain, or
#   passing argument 7 empty, and a suite that only drives the helper stays
#   green. That is what the first cut of this section did.
#
#   CONSEQUENCE -- that after a clean refusal the six Phase 1 BLOCKER rows reach
#   findings-to-issues instead of being dropped, which is the issue itself.
#
# So the thing driven here is the FENCE, lifted verbatim out of
# commands/review-pr.md, for BOTH Workflow-native fixer fences (Phase 1 and
# Phase 2). Those two are the pair nothing else executes: the routed pair is
# lifted and run by tests/review-child-inputs.test.sh, and on the default
# transport (RFC 0015) these two are the ones a real run enters.
#
# Everything the fence touches is real, and only the fixer child is stood in for:
#
#   * a REAL run, from tests/_lib_review_run_fixture.sh --make-run -- never a
#     hand-seeded directory (#427). `phase{1,2}-disposition.json` is the
#     zero-byte file lib/command-workspace.py allocates, which is precisely the
#     state a refusing child leaves behind. The fence is entered from a fresh
#     shell inside that repository carrying nothing but the plugin root, RUN_ID
#     and PR_NUMBER, so every path it uses it rehydrated for itself.
#   * the REAL fence library (lib/review-fences.sh), loaded by the fence's own
#     rehydration prologue, so `review_fixer_terminal_outcome` is the shipped
#     one rather than a copy.
#   * the REAL step 6b.0 gate (`digest --path ... --minimum 1`) off the shipped
#     lib/code_fixer_contract.py, which is the fence that decides whether the
#     disposition counts as published.
#   * the REAL Phase 2.5 defer fences, lifted out of the command file by W-DISPC
#     above and re-driven here through w_dispc_drive.
#
# The stand-in on CODE_FIXER_CONTRACT publishes what publish-unapplied-terminal
# publishes AND refuses -- rc 64, nothing on stdout -- unless the eight flags it
# is handed are byte-for-byte the ones this run's own state implies. That is the
# per-argument identity assertion: a swapped disposition/applied-content pair, a
# swapped head pair, an authority read off the wrong phase's sidecar, or the
# `FIXER_HEAD_AFTER` read moved back below the call (which leaves argument 7
# expanding to the empty string) all fail the fence here rather than shipping.
# The verb's own proof that it may only publish on a genuinely unapplied tree
# belongs to tests/code-fixer-contract.test.sh; duplicating it here would test
# the contract twice and the wiring never.
#
# `review_promote_validated_fixer_outcome` is stubbed, and RECORDING. It is the
# next fence's subject (tests/review-pr.test.sh executes the real one against a
# receipt publish-unapplied-terminal really produced); what this section owes is
# that the fence hands it the terminal document it just obtained together with
# the two heads, which the recorder captures.
W_UNAP_E2E_ROOT="$TMP/w-unap-e2e"
mkdir -p "$W_UNAP_E2E_ROOT"
W_UNAP_E2E_RUN_ID=20260814-074622-b2421484c09
# stderr to a FILE, never /dev/null: a fixture that cannot build is the one
# failure mode of this section that carries no other evidence, and "could not
# build a run fixture" with no reason is not debuggable from a CI log.
W_UNAP_E2E_FIXTURE="$(bash "$REPO_ROOT/tests/_lib_review_run_fixture.sh" --make-run \
  "$W_UNAP_E2E_ROOT" "$REPO_ROOT/plugins/uberdev" 41 "$W_UNAP_E2E_RUN_ID" \
  2>"$W_UNAP_E2E_ROOT/fixture.err")" || W_UNAP_E2E_FIXTURE=''
W_UNAP_E2E_REPO="$(printf '%s\n' "$W_UNAP_E2E_FIXTURE" | sed -n 1p)"
W_UNAP_E2E_RESEARCH="$(printf '%s\n' "$W_UNAP_E2E_FIXTURE" | sed -n 3p)"

# The two Workflow-native fixer fences, by the ONE line that is unique to each:
# the sidecar read. `REVIEW_FLEET_FIX_SIDECAR` alone also appears in the dispatch
# fence that WRITES the sidecar, which is a different fence in a different shell.
W_UNAP_E2E_FENCE1="$(extract_fence "$REVIEW_CMD" \
  'review_fleet_read_sidecar "$REVIEW_FLEET_FIX_SIDECAR" binding')" || W_UNAP_E2E_FENCE1=''
W_UNAP_E2E_FENCE2="$(extract_fence "$REVIEW_CMD" \
  'review_fleet_read_sidecar "$REVIEW_FLEET_FIX2_SIDECAR" binding')" || W_UNAP_E2E_FENCE2=''
if [ -n "$W_UNAP_E2E_FENCE1" ] && [ -n "$W_UNAP_E2E_FENCE2" ] \
   && [ "$W_UNAP_E2E_FENCE1" != "$W_UNAP_E2E_FENCE2" ]; then
  pass "W-UNAP-E2EL both Workflow-native fixer fences lift out of the command file, as distinct bodies"
else
  fail "W-UNAP-E2EL a Workflow-native fixer fence did not lift; the drives below cannot run"
fi

# w_unap_e2e_stage PHASE SHELL -- everything one drive needs, on disk.
#
# Per-phase DISTINCT values throughout (authority bytes, and therefore digest),
# so a fence that read the other phase's sidecar fails the flag-identity check
# rather than passing on its sibling's state. Per-SHELL scratch too, so the two
# interpreters never read each other's verb log or expectation.
#
# It also puts the workspace back into the state a refusing child leaves: the
# zero-byte disposition lib/command-workspace.py allocated and no applied-content
# plan at all. That is a RESET to the fixture's own initial state, not a seed --
# the second drive of a phase must start where the first one did or it would be
# asserting over its predecessor's published record.
w_unap_e2e_stage() {  # PHASE SHELL -> 0, with $TMP/w-unap-e2e-<phase>-<shell>/ ready
  # Two statements, never `local phase="$1" out="...$phase"`: a builtin's words
  # are all expanded BEFORE it runs, so the second would read the outer scope's
  # `phase` -- which under `set -u` is an unbound-variable abort.
  local phase="$1" shell="$2"
  local out="$TMP/w-unap-e2e-phase$phase-$shell" authority authority_sha binding
  local head_before head_after
  mkdir -p "$out" || return 1
  : >"$W_UNAP_E2E_RESEARCH/phase$phase-disposition.json" || return 1
  rm -f "$W_UNAP_E2E_RESEARCH/review-applied-content-phase$phase-iter1.json" || return 1
  head_before="$(git -C "$W_UNAP_E2E_REPO" rev-parse HEAD)" || return 1
  authority="$W_UNAP_E2E_RESEARCH/code-fixer-authority-phase$phase-iter1.json"
  printf '{"phase":"phase%s","authority":"fixture"}\n' "$phase" >"$authority" || return 1
  authority_sha="$(python3 -I -B -c 'import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$authority")" || return 1
  # A 64-hex run_nonce because that is what the controller mints and what
  # review_promote_validated_fixer_outcome requires of the receipt the stand-in
  # echoes it back in.
  binding="$(jq -cn --arg nonce "$(python3 -I -B -c 'import sys
print(sys.argv[1] * 64, end="")' "$phase")" \
    --arg authority "$authority" --arg authority_sha "$authority_sha" \
    --arg edge "review_pr.fix.phase$phase" \
    '{run_nonce:$nonce,edge_id:$edge,backend:"workflow",branch:"",
      authority_path:$authority,authority_sha256:$authority_sha}')" || return 1
  ( . "$ARGS_LIB" && review_fleet_write_sidecar \
      "$W_UNAP_E2E_RESEARCH/review-fleet-fix-phase$phase-iter1.launch.json" \
      "$binding" "$W_UNAP_E2E_RESEARCH/children/fix-phase$phase-iter01" \
      "review-pr-$W_UNAP_E2E_RUN_ID-fix-phase$phase" "$head_before" ) || return 1
  # THE TREE MOVES between dispatch and return, so the two heads this fence
  # forwards are DISTINCT. That is not decoration: with head_before == head_after
  # a fence that passed argument 6 twice, or swapped 6 and 7, satisfies any
  # assertion made about them. head_before is the sidecar's (what was recorded at
  # dispatch) and head_after is the repository's (what the fence reads for
  # itself), and only a fence that keeps them apart can hand over both.
  #
  # Whether the terminal verb may publish an unapplied record for a tree that
  # moved is the CONTRACT's question, and it is answered in
  # tests/code-fixer-contract.test.sh against the real verb. What this section
  # owns is that both heads leave the fence intact.
  #
  # Distinct BYTES per drive, not merely a distinct filename: re-committing an
  # unchanged tree exits 1 ("nothing to commit"), which would leave the second
  # interpreter's stage failing for a reason that has nothing to do with it.
  printf 'phase %s fixer commit (%s)\n' "$phase" "$shell" \
    >"$W_UNAP_E2E_REPO/fixer-phase$phase-$shell.txt" || return 1
  git -C "$W_UNAP_E2E_REPO" add "fixer-phase$phase-$shell.txt" >/dev/null 2>&1 || return 1
  git -C "$W_UNAP_E2E_REPO" commit -qm "fix: phase $phase fixer commit ($shell)" >/dev/null 2>&1 || return 1
  head_after="$(git -C "$W_UNAP_E2E_REPO" rev-parse HEAD)" || return 1
  [ "$head_before" != "$head_after" ] || return 1
  printf '%s\n%s\n' "$head_before" "$head_after" >"$out/heads.txt" || return 1
  # THE EXPECTATION, built from the run rather than from the fence: the two
  # artifact paths are the workspace's own (phase<N>-disposition.json comes off
  # the descriptor, the applied-content name is the one iteration 1 implies),
  # the heads are the sidecar's and the repository's, and the authority pins are
  # the binding's. REVIEW_ITERATION is 1 here because the run has no
  # ci-loop-state.json yet, which is the first-pass state.
  jq -n --arg binding "$binding" --arg authority "$authority" \
    --arg authority_sha "$authority_sha" \
    --arg disposition "$W_UNAP_E2E_RESEARCH/phase$phase-disposition.json" \
    --arg content "$W_UNAP_E2E_RESEARCH/review-applied-content-phase$phase-iter1.json" \
    --arg worktree "$W_UNAP_E2E_REPO" --arg before "$head_before" --arg after "$head_after" \
    --arg phase "phase$phase" \
    '{phase:$phase,
      flags:{"--launch-binding-json":$binding,
             "--authority-path":$authority,"--authority-sha256":$authority_sha,
             "--disposition-path":$disposition,"--applied-content-path":$content,
             "--working-dir":$worktree,
             "--head-before":$before,"--head-after":$after}}' >"$out/expected.json" || return 1
  # The stand-in resolves BOTH its expectation and its log from __file__, never
  # from the environment: `-I` is isolated mode, and a row that depended on an
  # inherited variable would be one export away from asserting nothing.
  cat >"$out/contract.py" <<'PY'
import hashlib
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
verb = sys.argv[1] if len(sys.argv) > 1 else ""
with open(os.path.join(here, "verbs.log"), "a", encoding="utf-8") as stream:
    stream.write(verb + "\n")


def refuse(message):
    sys.stderr.write("w-unap-e2e stand-in: " + message + "\n")
    raise SystemExit(64)


if verb != "publish-unapplied-terminal":
    refuse("unexpected verb %r" % verb)
rest = sys.argv[2:]
if len(rest) % 2:
    refuse("odd flag list: %r" % (rest,))
flags = {rest[index]: rest[index + 1] for index in range(0, len(rest) - 1, 2)}
with open(os.path.join(here, "expected.json"), encoding="utf-8") as stream:
    plan = json.load(stream)
if flags != plan["flags"]:
    # ONLY the flags that differ. The eight values are absolute paths and a
    # serialised binding, so dumping both maps buries the one wrong argument in
    # two kilobytes of identical text -- in a CI log, on one line.
    differing = sorted(set(flags) | set(plan["flags"]))
    refuse("flag map is not this run's: " + "; ".join(
        "%s got=%r want=%r" % (name, flags.get(name), plan["flags"].get(name))
        for name in differing if flags.get(name) != plan["flags"].get(name)))


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode() + b"\n"


rows = [
    {"finding_index": index, "location": "plugins/uberdev/lib/example.sh:%d" % index,
     "summary_sha256": hashlib.sha256(b"finding-%d" % index).hexdigest(),
     "disposition": "REFUSED", "behavior_tag": "n/a",
     "reason": "prepared and verified; publication gate refused"}
    for index in range(1, 7)
]
disposition = canonical({
    "schema_version": 1, "phase": plan["phase"],
    "aggregate_sha256": "0" * 64,
    "findings_disposition": rows,
})
with open(flags["--disposition-path"], "wb") as stream:
    stream.write(disposition)
content = canonical({
    "schema_version": 1, "applied": [],
    "authority_sha256": "1" * 64,
    "disposition_sha256": hashlib.sha256(disposition).hexdigest(),
})
with open(flags["--applied-content-path"], "wb") as stream:
    stream.write(content)
sys.stdout.write(json.dumps({
    "status": "REFUSED", "declared_tip": "", "commit": None,
    "run_nonce": json.loads(plan["flags"]["--launch-binding-json"])["run_nonce"],
    "status_sha256": "2" * 64, "result_sha256": "3" * 64,
    "disposition_sha256": hashlib.sha256(disposition).hexdigest(),
    "applied_content_sha256": hashlib.sha256(content).hexdigest(),
}, sort_keys=True, separators=(",", ":")))
PY
  return 0
}

# w_unap_e2e_drive PHASE SHELL BODY -> the LIFTED fence's rc, from a fresh shell
# inside the fixture repository. Nothing is seeded that a real fence would not
# have: the prologue resolves the run root with `git rev-parse --show-toplevel`,
# so the cwd is load-bearing, and `set -u` makes a carrier the fence forgot to
# establish a hard failure rather than an empty argument.
#
# SHELL is bash then zsh, for the reason W-UNAP already runs twice: the Skill
# tool hands a ```bash fence to /bin/zsh, so these fence bytes really do execute
# on both, and a bashism in one of them is a runtime-only defect a shape test
# cannot see. This is the only place any commands/review-pr.md fence is executed
# under the second interpreter.
w_unap_e2e_drive() {  # PHASE SHELL BODY -> rc
  local phase="$1" shell="$2" body="$3"
  local out="$TMP/w-unap-e2e-phase$phase-$shell" rc
  {
    echo 'set -u'
    printf "UBERDEV_REVIEW_PLUGIN_ROOT='%s'\n" "$REPO_ROOT/plugins/uberdev"
    printf "CODE_FIXER_CONTRACT='%s'\n" "$out/contract.py"
    printf "RUN_ID='%s'\n" "$W_UNAP_E2E_RUN_ID"
    echo 'PR_NUMBER=41'
    printf "W_UNAP_E2E_PROMOTE_ARGV='%s'\n" "$out/promote.argv"
    # Defined BEFORE the prologue runs, so the fence library's gap-filling
    # loader keeps it (a name the calling shell already holds is never carved).
    cat <<'PROMOTE'
review_promote_validated_fixer_outcome() {
  printf '%s\n' "$#" "$@" >"$W_UNAP_E2E_PROMOTE_ARGV"
  return 0
}
PROMOTE
    echo 'uberdev_review_fixer_terminal_fence() {'
    # printf with the newline: $( ) strips the body's trailing one, and without
    # it the closing brace lands on the last command's line.
    printf '%s\n' "$body"
    echo '}'
    echo 'uberdev_review_fixer_terminal_fence'
  } >"$out/fence.sh"
  ( cd "$W_UNAP_E2E_REPO" && "$shell" "$out/fence.sh" >"$out/fence.out" 2>"$out/fence.err" )
  rc=$?
  printf '%s' "$rc"
}

if [ -n "$W_UNAP_E2E_REPO" ] && [ -d "$W_UNAP_E2E_RESEARCH" ] \
   && [ -n "$W_UNAP_E2E_FENCE1" ] && [ -n "$W_UNAP_E2E_FENCE2" ]; then
  W_UNAP_E2E_DISPOSITION="$W_UNAP_E2E_RESEARCH/phase1-disposition.json"
  W_UNAP_E2E_DISPOSITION2="$W_UNAP_E2E_RESEARCH/phase2-disposition.json"
  if [ -f "$W_UNAP_E2E_DISPOSITION" ] && [ ! -s "$W_UNAP_E2E_DISPOSITION" ] \
     && [ -f "$W_UNAP_E2E_DISPOSITION2" ] && [ ! -s "$W_UNAP_E2E_DISPOSITION2" ]; then
    pass "W-UNAP-E2E0 the run allocates both phase dispositions at exactly zero bytes"
  else
    fail "W-UNAP-E2E0 the run fixture did not allocate zero-byte phase dispositions"
  fi

  # THE INCIDENT, before the fix reaches it: the zero-byte record fails step
  # 6b.0's gate, and the defer fence forwards the EMPTY path -- which is how six
  # BLOCKER rows became zero filed issues. Asserted first, so the rows below
  # cannot pass on a file that was already publishable.
  if ! python3 -I -B "$CONTRACT" digest --path "$W_UNAP_E2E_DISPOSITION" \
       --minimum 1 --maximum 16777216 >/dev/null 2>&1 \
     && [ "$(w_dispc_drive "$TMP/w-dispc-1.sh" "$W_UNAP_E2E_DISPOSITION" "$W_UNAP_E2E_DISPOSITION2")" = "||no" ]; then
    pass "W-UNAP-E2E1 an unpublished refusal fails step 6b.0 and reaches Phase 2.5 as the empty path (the incident)"
  else
    fail "W-UNAP-E2E1 the zero-byte disposition was already accepted; the control half of this row is vacuous"
  fi

  # bash first, then zsh, and both phases under each. FOUR drives, because the
  # two fences are two separate copies of one shape and the two interpreters are
  # two separate runtimes -- and every pairing of those is a real production path.
  for w_unap_e2e_shell in bash zsh; do
   case "$w_unap_e2e_shell" in
     bash) w_unap_e2e_row=W-UNAP-E2E2 ;;
     *)    w_unap_e2e_row=W-UNAP-E2E2d ;;
   esac
   for w_unap_e2e_phase in 1 2; do
    case "$w_unap_e2e_phase" in
      1) w_unap_e2e_body="$W_UNAP_E2E_FENCE1" ;;
      *) w_unap_e2e_body="$W_UNAP_E2E_FENCE2" ;;
    esac
    w_unap_e2e_dir="$TMP/w-unap-e2e-phase$w_unap_e2e_phase-$w_unap_e2e_shell"
    w_unap_e2e_record="$W_UNAP_E2E_RESEARCH/phase$w_unap_e2e_phase-disposition.json"
    w_unap_e2e_content="$W_UNAP_E2E_RESEARCH/review-applied-content-phase$w_unap_e2e_phase-iter1.json"
    if ! w_unap_e2e_stage "$w_unap_e2e_phase" "$w_unap_e2e_shell"; then
      fail "${w_unap_e2e_row}p$w_unap_e2e_phase could not stage the phase $w_unap_e2e_phase launch sidecar ($w_unap_e2e_shell)"
      continue
    fi
    w_unap_e2e_rc="$(w_unap_e2e_drive "$w_unap_e2e_phase" "$w_unap_e2e_shell" "$w_unap_e2e_body")"
    w_unap_e2e_verbs="$(tr '\n' ',' <"$w_unap_e2e_dir/verbs.log" 2>/dev/null)"

    # THE ROUTING ROW. rc 0 is only half of it: the stand-in refuses unless every
    # one of the eight flags carries this run's own value, so reaching it at all
    # is the argument-identity assertion.
    if [ "$w_unap_e2e_rc" = 0 ] \
       && [ "$w_unap_e2e_verbs" = 'publish-unapplied-terminal,' ] \
       && [ -s "$w_unap_e2e_record" ] && [ -s "$w_unap_e2e_content" ] \
       && python3 -I -B "$CONTRACT" digest --path "$w_unap_e2e_record" \
            --minimum 1 --maximum 16777216 >/dev/null 2>&1; then
      pass "${w_unap_e2e_row}p$w_unap_e2e_phase the Workflow-native phase $w_unap_e2e_phase fence routes the refusal to the owner with this run's own arguments, publishes it, and step 6b.0's real gate accepts it ($w_unap_e2e_shell)"
    else
      fail "${w_unap_e2e_row}p$w_unap_e2e_phase the phase $w_unap_e2e_phase fence did not publish ($w_unap_e2e_shell): rc=$w_unap_e2e_rc verbs=$w_unap_e2e_verbs stderr=$(tr '\n' ' ' <"$w_unap_e2e_dir/fence.err" 2>/dev/null)"
    fi

    # And what it promotes is what it obtained: the terminal document plus the
    # two heads, in that order, and nothing else. The heads are DISTINCT (the
    # stage commits between recording head_before and the drive), so promoting
    # one of them twice cannot satisfy this row.
    w_unap_e2e_promoted="$(sed -n 1p "$w_unap_e2e_dir/promote.argv" 2>/dev/null)"
    w_unap_e2e_promoted_doc="$(sed -n 2p "$w_unap_e2e_dir/promote.argv" 2>/dev/null)"
    if [ "$w_unap_e2e_promoted" = 3 ] \
       && [ "$(printf '%s' "$w_unap_e2e_promoted_doc" | jq -r '.status')" = REFUSED ] \
       && [ "$(printf '%s' "$w_unap_e2e_promoted_doc" | jq -r '.disposition_sha256')" \
            = "$(python3 -I -B -c 'import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$w_unap_e2e_record")" ] \
       && [ "$(sed -n 3p "$w_unap_e2e_dir/promote.argv" 2>/dev/null)" \
            = "$(sed -n 1p "$w_unap_e2e_dir/heads.txt" 2>/dev/null)" ] \
       && [ "$(sed -n 4p "$w_unap_e2e_dir/promote.argv" 2>/dev/null)" \
            = "$(sed -n 2p "$w_unap_e2e_dir/heads.txt" 2>/dev/null)" ]; then
      pass "${w_unap_e2e_row}q$w_unap_e2e_phase the phase $w_unap_e2e_phase fence promotes the terminal it just obtained, with both heads ($w_unap_e2e_shell)"
    else
      fail "${w_unap_e2e_row}q$w_unap_e2e_phase the phase $w_unap_e2e_phase promotion argv is wrong ($w_unap_e2e_shell): $(tr '\n' ' ' <"$w_unap_e2e_dir/promote.argv" 2>/dev/null)"
    fi
   done
  done

  # And the record travels. BOTH defer fences are driven: the routed one and the
  # Workflow-native one carry separate copies of the guard, and the incident is
  # only fixed when both forward the real paths.
  W_UNAP_E2E_DEFER_OK=1
  for w_unap_e2e_n in 1 2; do
    [ "$(w_dispc_drive "$TMP/w-dispc-$w_unap_e2e_n.sh" \
         "$W_UNAP_E2E_DISPOSITION" "$W_UNAP_E2E_DISPOSITION2")" \
       = "$W_UNAP_E2E_DISPOSITION|$W_UNAP_E2E_DISPOSITION2|no" ] || W_UNAP_E2E_DEFER_OK=0
  done
  if [ "$W_UNAP_E2E_DEFER_OK" = 1 ]; then
    pass "W-UNAP-E2E3 both Phase 2.5 defer fences forward the published refusals instead of the empty path"
  else
    fail "W-UNAP-E2E3 a defer fence still empties a published refusal"
  fi

  # The rows themselves survived the round trip as REFUSED -- the whole point.
  # A publisher that wrote a well-formed but EMPTY findings_disposition would
  # satisfy every size and path assertion above.
  if [ "$(python3 -I -B -c '
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
rows = value["findings_disposition"]
print(len(rows) if all(row["disposition"] == "REFUSED" for row in rows) else 0, end="")
' "$W_UNAP_E2E_DISPOSITION" 2>/dev/null)" = 6 ]; then
    pass "W-UNAP-E2E4 all six refused BLOCKER rows are in the record Phase 2.5 receives"
  else
    fail "W-UNAP-E2E4 the published record does not carry the six REFUSED rows"
  fi
else
  fail "W-UNAP-E2E could not build a run fixture or lift the fences; the end-to-end rows did not run: $(tr '\n' ' ' <"$W_UNAP_E2E_ROOT/fixture.err" 2>/dev/null)"
fi

assert_stage_runs ci-classify ci-classify "$W_NONCE1" "$W_CI_COMMON" 1
assert_stage_runs ci-fix-code ci-fix "$W_NONCE1" \
  "$(printf '%s' "$W_CI_COMMON" | jq '. + {ciFixerEdgeId:"review_pr.ci.fix_code",
     ciFailureClass:"code_bug", ciSignalAnchor:"src/app.py:1"}')" 1
assert_stage_runs ci-fix-rebase ci-fix "$W_NONCE1" \
  "$(printf '%s' "$W_CI_COMMON" | jq '. + {ciFixerEdgeId:"review_pr.ci.rebase",
     ciFailureClass:"stale_base", ciSignalAnchor:"gh-run-12345:1"}')" 1
assert_stage_runs ci-conflicts ci-conflicts "$W_NONCE1,$W_NONCE2" \
  "$(printf '%s' "$W_CI_COMMON" | jq '. + {ciConflictCount:2, ciConflictCap:50,
     ciConflictWave:10,
     ciConflictAuthorityPrefixAbs:"/r/run/ci-authority-resolve-conflict-iter1-ci1-"}')" 2
assert_stage_runs ci-defer ci-defer "$W_NONCE1" \
  "$(printf '%s' "$W_CI_COMMON" | jq --arg sha "$W_HEX64_A" \
     '. + {ciAggregatePathAbs:"/r/run/agg.md", ciAggregateSha256:$sha}')" 1

# --- V: the ninth stage — the Phase 1 verification gate (#431) -------------
W_VERIFY_COMMON="$(jq -n '{
  verifyClaimPrefixAbs:"/r/run/verification-claims-iter1/verify-",
  verifyContractPathAbs:"/p/shared/finding-verifier-output-v1.md",
  verifyRubricPathAbs:"/p/shared/finding-confidence-rubric-v1.md",
  verifyPrContextPathAbs:"/r/run/pr-context.md"}')"
assert_stage_runs verify verify "$W_NONCE1,$W_NONCE2" \
  "$(printf '%s' "$W_VERIFY_COMMON" | jq '. + {verifyCount:2, verifyCap:50}')" 2

# V1 — THE withholding invariant, asserted on the SHIPPED script rather than on
# a prompt sample: no verifier prompt builder can interpolate a threshold it
# never receives. A `confidenceThreshold` scalar appearing here at all would
# mean the cutoff crossed the boundary.
V_THRESHOLD_HITS="$(grep -c -E 'confidenceThreshold|CONFIDENCE_THRESHOLD|REVIEW_THRESHOLD' "$WORKFLOW" || true)"
[ "$V_THRESHOLD_HITS" = "0" ] \
  && pass "V1 workflow.js interpolates no confidence threshold anywhere (the child is never told the cutoff)" \
  || fail "V1 workflow.js carries $V_THRESHOLD_HITS threshold reference(s); the cutoff must stay controller-side"
# Anti-vacuity: the grep must be looking at a file that DOES mention the gate,
# or V1 would pass against an empty or misrooted path.
grep -Fq 'verifyCount' "$WORKFLOW" \
  && pass "V1b the scanned script really is the one carrying the verify stage" \
  || fail "V1b $WORKFLOW has no verify stage at all — V1 is vacuous"

# V2 — the roster length is DERIVED from verifyCount on both sides. G11a proves
# JS/shell equality for the FIXED reviewer roster; this is the variable twin.
V_JS_ROSTER="$(grep -c 'for (let i = 1; i <= verifyCount; i++)' "$WORKFLOW")"
[ "$V_JS_ROSTER" = "1" ] \
  && pass "V2a the JS verify roster length derives from verifyCount" \
  || fail "V2a the JS verify roster is not derived from verifyCount"
V_SH_NONCES="$(bash -c '
  . "$1"
  d="$(mktemp -d)"; : >"$d/claims.txt"
  for i in 1 2 3; do printf "%s/verify-0%s.json\n" "$d" "$i" >>"$d/claims.txt"; done
  review_fleet_bind_verify "$d" 1 "$d" "$2" "$d/claims.txt" "$d/ledger.jsonl" >/dev/null 2>&1
  printf "%s|%s" "$REVIEW_FLEET_VERIFY_COUNT" "$(printf "%s" "$REVIEW_FLEET_NONCE_POOL" | tr -cd , | wc -c | tr -d " ")"
  rm -rf "$d"
' _ "$ARGS_LIB" "$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py")"
[ "$V_SH_NONCES" = "3|2" ] \
  && pass "V2b review_fleet_bind_verify mints exactly one nonce per claim (3 claims -> 3 nonces)" \
  || fail "V2b bind_verify minted '$V_SH_NONCES', want '3|2' (count|comma-count)"

# ---------------------------------------------------------------------------
# X1 — the verify child is a BOUND child (#514 item 2)
# ---------------------------------------------------------------------------
# THE DEFECT: verifyPrompt was the only one of the ten prompt builders that never
# called boundChildProtocol. Its ad-hoc substitute named the two files and the
# nonce but omitted the partial-then-rename atomic-publish rule every sibling
# supplies, so a verifier could be captured mid-write; the strict validator then
# refuses the torn bytes and the finding degrades to `verifier-unavailable`,
# which reads as "the child failed" rather than "the child mis-published". It
# also carried no "Return via StructuredOutput" line at all while `S.verify`
# REQUIRES four fields, so the child had to invent them or trip the retry.
#
# The review-fleet SKILL.md section "Bound children — the nonce protocol"
# asserts "Every child that produces a result file is a bound child" and lists
# `verify` in the nonce table — these rows are what makes that sentence true
# rather than aspirational. Anchored on the section heading, not on a line
# number: this PR edits that document, so the number would drift (and did).
#
# Herestrings, never `printf | grep -q`: tests/epipe-guard.test.sh reds on a new
# pipe probe (the guard fires on the WRITER side of a short-reading pipeline).
echo
echo "== X1: the verify stage's children are bound like every other child =="

X1_ARGS="$(printf '%s' "$W_VERIFY_COMMON" | jq '. + {verifyCount:2, verifyCap:50}')"
stage_args verify "$W_NONCE1,$W_NONCE2" "$X1_ARGS"
X1_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
stage_args review "$W_REVIEW_NONCES" '{}'
X1_REVIEW_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"

# x1_count OUT JQ_TEST -> how many prompts satisfy the jq test
x1_count() { jq -r --arg n "$2" '[.prompts[] | select(contains($n))] | length' <<<"$1"; }

[ "$(x1_count "$X1_OUT" 'Bound-child protocol')" = 2 ] \
  && pass "X1a both verify prompts carry the bound-child protocol block" \
  || fail "X1a $(x1_count "$X1_OUT" 'Bound-child protocol') of 2 verify prompts carry the bound-child protocol"
[ "$(x1_count "$X1_REVIEW_OUT" 'Bound-child protocol')" = 7 ] \
  && pass "X1b anti-vacuity: the same needle finds all seven reviewer prompts" \
  || fail "X1b the 'Bound-child protocol' needle is wrong — it matches $(x1_count "$X1_REVIEW_OUT" 'Bound-child protocol') of 7 reviewer prompts"
X1C="$(jq -r '[.prompts[] | select(contains(".partial") and contains("mv -f"))] | length' <<<"$X1_OUT")"
[ "$X1C" = 2 ] \
  && pass "X1c both verify prompts state the partial-then-rename publish rule" \
  || fail "X1c $X1C of 2 verify prompts state partial-then-rename; a torn read stays possible"
X1D="$(jq -r '[.prompts[] | select(contains("Also return") and contains("SCORED"))] | length' <<<"$X1_OUT")"
[ "$X1D" = 2 ] \
  && pass "X1d both verify prompts request the S.verify fields the schema requires" \
  || fail "X1d $X1D of 2 verify prompts request edgeId/status; the child must invent them or trip the retry"
[ "$(x1_count "$X1_OUT" 'and your status.json at')" = 0 ] \
  && pass "X1e the ad-hoc publication block was REPLACED, not duplicated" \
  || fail "X1e $(x1_count "$X1_OUT" 'and your status.json at') verify prompt(s) still carry the ad-hoc publication block beside the protocol"
[ "$(x1_count "$X1_OUT" 'means this document and only this document')" = 2 ] \
  && pass "X1f both verify prompts override the protocol's 'write your full report' wording" \
  || fail "X1f the verify output contract does not override 'write your full report'; a titled report around the YAML refuses the whole result"
# The withholding invariant, on the NEW line specifically: the score belongs in
# the result file the controller re-reads, so the structured return must not
# name one — and the child must never be handed the cutoff. Word-bounded, so the
# `SCORED` status enum member X1d requires is not mistaken for a score field;
# and un-anchored to a single line only because jq's `.` does not cross a
# newline without the "m" flag, which is exactly the scoping wanted here.
X1G="$(jq -r '[.prompts[] | select(test("Also return.*\\b(score|confidence|verdict|threshold)\\b"; "i"))] | length' <<<"$X1_OUT")"
[ "$X1G" = 0 ] \
  && pass "X1g no verify prompt asks for a score, a verdict or a threshold in its structured return" \
  || fail "X1g $X1G verify prompt(s) ask for a score/verdict/threshold in the return; the score must stay in the result file"

# ---------------------------------------------------------------------------
# X2 — the status-document TEMPLATE and the minted BINDING agree (#514 item 2)
# ---------------------------------------------------------------------------
# CHARACTERIZATION, not red-first: these two rows pass on the pre-fix tree by
# design and are the only defence against the sequencing trap that binding the
# verify child (X1) and consuming its binding (X3) create together. The prompt
# tells the child to write `workspace_mode`/`worktree`/`branch` from the
# ENVELOPE; `bind-workflow-launch` mints `workspace_mode:"caller"`,
# `worktree:<canonical working dir>` and `branch:""` from its own arguments. If
# those two ever disagree, EVERY verifier's status document refuses, every
# eligible blocker degrades to `verifier-unavailable`, and the precision gate
# silently stops filtering with CI still green — no test executes a real
# verifier, so nothing else would notice.
echo
echo "== X2: the bound-child status template round-trips through the real binder =="

X2_DIR="$TMP/x2"
mkdir -p "$X2_DIR"
bash -c '
  . "$1"
  d="$2"
  : >"$d/claims.txt"
  for i in 1 2; do printf "%s/claim-0%s.json\n" "$d" "$i" >>"$d/claims.txt"; done
  review_fleet_bind_verify "$d" 1 "$d" "$3" "$d/claims.txt" "$d/ledger.jsonl"
' _ "$ARGS_LIB" "$X2_DIR" "$CONTRACT" >/dev/null 2>&1
X2_BAD=""
[ -s "$X2_DIR/ledger.jsonl" ] || X2_BAD="$X2_BAD no-ledger"
X2_ROWS=0
while IFS= read -r X2_ROW; do
  [ -n "$X2_ROW" ] || continue
  X2_ROWS=$((X2_ROWS + 1))
  X2_RESULT="$(jq -er .result <<<"$X2_ROW")" || { X2_BAD="$X2_BAD row$X2_ROWS-no-result"; continue; }
  X2_STATUS="$(jq -er .status <<<"$X2_ROW")" || { X2_BAD="$X2_BAD row$X2_ROWS-no-status"; continue; }
  X2_BINDING="$(jq -er .binding <<<"$X2_ROW")" || { X2_BAD="$X2_BAD row$X2_ROWS-no-binding"; continue; }
  X2_NONCE="$(jq -er .run_nonce <<<"$X2_BINDING")" || { X2_BAD="$X2_BAD row$X2_ROWS-no-nonce"; continue; }
  printf 'a verifier opinion\n' >"$X2_RESULT"
  # BYTE-SHAPED exactly as boundChildProtocol templates it — including the
  # ABSENCE of pid / process_identity / lease_generation, which the contract
  # refuses outright rather than ignoring.
  printf '{"backend":"workflow","state":"completed","exit_code":0,\n "run_nonce":"%s",\n "workspace_mode":"%s",\n "worktree":"%s",\n "branch":"%s",\n "result":"%s"}\n' \
    "$X2_NONCE" caller "$X2_DIR" "" "$X2_RESULT" >"$X2_STATUS"
  python3 -I -B "$CONTRACT" capture-bound-child \
    --edge-id "$(jq -er .edge <<<"$X2_ROW")" \
    --launch-binding-json "$X2_BINDING" >/dev/null 2>&1 \
    || X2_BAD="$X2_BAD row$X2_ROWS-capture-refused"
done <"$X2_DIR/ledger.jsonl"
[ "$X2_ROWS" = 2 ] || X2_BAD="$X2_BAD rows=$X2_ROWS"
if [ -z "$X2_BAD" ]; then
  pass "X2a a status document written from the prompt's template captures cleanly against the minted binding"
else
  fail "X2a the prompt template and bind-workflow-launch disagree:$X2_BAD"
fi

# Negative twin. Without it the pair proves only that SOMETHING captured, not
# that the nonce is what bound it — a validator that ignored the nonce would
# pass X2a exactly as loudly.
X2_ROW1="$(sed -n 1p "$X2_DIR/ledger.jsonl")"
X2_B1="$(jq -er .binding <<<"$X2_ROW1")"
X2_N1="$(jq -er .run_nonce <<<"$X2_B1")"
# Flip ONE character; the grammar (64 lowercase hex) stays valid, so only the
# equality can refuse it.
case "$X2_N1" in
  a*) X2_N_BAD="b${X2_N1#?}" ;;
  *)  X2_N_BAD="a${X2_N1#?}" ;;
esac
printf '{"backend":"workflow","state":"completed","exit_code":0,\n "run_nonce":"%s",\n "workspace_mode":"%s",\n "worktree":"%s",\n "branch":"%s",\n "result":"%s"}\n' \
  "$X2_N_BAD" caller "$X2_DIR" "" "$(jq -er .result <<<"$X2_ROW1")" >"$(jq -er .status <<<"$X2_ROW1")"
if python3 -I -B "$CONTRACT" capture-bound-child \
     --edge-id "$(jq -er .edge <<<"$X2_ROW1")" \
     --launch-binding-json "$X2_B1" >/dev/null 2>&1; then
  fail "X2b a status document echoing a nonce this run never minted was captured as bound evidence"
else
  pass "X2b a one-character nonce mismatch refuses the capture (X2a is not vacuous)"
fi

# --- W-CONTRACT: the Phase 1 reviewers must be TOLD the output contract (#403)
#
# lib/child-dispatch.sh validates a reviewer result with re.fullmatch over the
# WHOLE file, and lib/review-aggregate.sh re-parses with the byte-identical
# regex. A prompt that delegates the serialization to "your agent file's
# declared output contract" delegates it to five prose sections that regex can
# never accept, so every Phase 1 wave comes back BLOCKED and the aggregate is
# suppressed. These rows read the PROMPTS the script actually builds.
stage_args review "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6,$W_NONCE7" '{}'
W_CONTRACT_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("phase1-reviewer-output-v1"))] | length')" = 7 ]; then
  pass "W[review-contract-path] all seven reviewer prompts carry the contract path"
else
  fail "W[review-contract-path] the contract path reaches $(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("phase1-reviewer-output-v1"))] | length') of 7 reviewer prompts"
fi
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("entire contents of the result file"))] | length')" = 7 ] \
   && [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("agent file.s declared output contract"))] | length')" = 0 ]; then
  pass "W[review-contract-wholefile] every reviewer prompt binds the WHOLE result file and delegates to no agent file"
else
  fail "W[review-contract-wholefile] a reviewer prompt still delegates the serialization to its agent file"
fi
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("blocker") and test("suggestion"))] | length')" = 7 ]; then
  pass "W[review-contract-vocab] every reviewer prompt states the blocker/suggestion severity vocabulary"
else
  fail "W[review-contract-vocab] the severity vocabulary the validator accepts is not in every prompt"
fi

# #433: the rule-source allowlist path, the citation grammar and the
# empty-allowlist instruction reach the convention child and NOTHING else. A
# second lens told where the rule documents are is a second lens able to make a
# convention claim with no citation gate behind it -- the exact route this edge
# exists to close.
W_RULES_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
w_prompt_count() {  # NEEDLE -> how many reviewer prompts contain it
  printf '%s' "$W_RULES_OUT" | jq -r --arg needle "$1" \
    '[.prompts[] | select(contains($needle))] | length'
}
if [ "$(w_prompt_count '/r/run/post-review/rule-sources.txt')" = 1 ]; then
  pass "W[review-rule-sources] the allowlist path reaches exactly one reviewer prompt"
else
  fail "W[review-rule-sources] the allowlist path reaches $(w_prompt_count '/r/run/post-review/rule-sources.txt') prompts (want exactly 1)"
fi
if [ "$(w_prompt_count 'quote: <the rule text, verbatim>')" = 1 ]; then
  pass "W[review-citation-grammar] the citation grammar reaches exactly one reviewer prompt"
else
  fail "W[review-citation-grammar] the citation grammar reaches $(w_prompt_count 'quote: <the rule text, verbatim>') prompts (want exactly 1)"
fi
if [ "$(w_prompt_count 'this repository has written no conventions down')" = 1 ]; then
  pass "W[review-empty-allowlist] the empty-allowlist instruction is a prompt string, not prose in a doc"
else
  fail "W[review-empty-allowlist] the empty-allowlist instruction reaches $(w_prompt_count 'this repository has written no conventions down') prompts (want exactly 1)"
fi

# The gate. A wiring regression must abort BEFORE the nonce gate, so no nonce is
# burned and no child is dispatched into an unstated contract.
#
# w_expect_contract_abort is shared by the review arm and the fix arm below
# because the two arms owe the SAME three-part verdict — reason, zero prompts,
# zero dispatches — and a second copy of it is a second place for one of the
# three to be quietly dropped.
w_expect_contract_abort() {  # LABEL ARGS_FILE
  local label="$1" args_file="$2" out abort prompts labels
  out="$(node "$W_HARNESS" "$WORKFLOW" "$args_file" 2>&1)"
  abort="$(printf '%s' "$out" | jq -r '.abortReason')"
  prompts="$(printf '%s' "$out" | jq -r '.prompts | length')"
  labels="$(printf '%s' "$out" | jq -r '.labels | length')"
  if [ "$abort" = bad_contract_path ] && [ "$prompts" = 0 ] && [ "$labels" = 0 ]; then
    pass "W[$label] aborts bad_contract_path with zero prompts and zero dispatches"
  else
    fail "W[$label] abort='$abort' prompts=$prompts labels=$labels (want bad_contract_path/0/0)"
  fi
}
w_contract_abort() {  # LABEL JQ_MUTATION
  stage_args review "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6,$W_NONCE7" '{}'
  jq "$2" "$TMP/w-args.json" >"$TMP/w-args-contract.json"
  w_expect_contract_abort "$1" "$TMP/w-args-contract.json"
}
w_contract_abort review-contract-missing 'del(.config.phase1ContractPathAbs)'
w_contract_abort review-contract-empty '.config.phase1ContractPathAbs = ""'
w_contract_abort review-contract-relative '.config.phase1ContractPathAbs = "shared/x.md"'
w_contract_abort review-contract-traversal '.config.phase1ContractPathAbs = "/p/../etc/x"'

# The FIX arm's runtime twin (#474). Until these rows existed, deleting the
# guard body from workflow.js redded exactly ONE row — a grep for the source
# line — while the four rows above kept the review arm honest. A guard whose
# only proof is that its text is present is a guard that can be rewritten into a
# no-op with the string intact.
#
# Driven under BOTH modes, because `stage=fix` is shared and deliberately not
# mode-scoped: the mode=simplify half is what says the third emitter owes the
# key, and it is the half that reds if someone "fixes" this by mode-scoping the
# guard instead of wiring the emitter.
w_fix_contract_abort() {  # LABEL EXTRA_JSON JQ_MUTATION
  stage_args fix "$W_NONCE1" "$2"
  jq "$3" "$TMP/w-args.json" >"$TMP/w-args-fix-contract.json"
  w_expect_contract_abort "$1" "$TMP/w-args-fix-contract.json"
}
for W_FIX_ARM in "review:$W_FIX_COMMON" "simplify:$W_FIX_SIMPLIFY"; do
  W_FIX_ARM_NAME="${W_FIX_ARM%%:*}"
  W_FIX_ARM_EXTRA="${W_FIX_ARM#*:}"
  w_fix_contract_abort "fix-$W_FIX_ARM_NAME-contract-missing" "$W_FIX_ARM_EXTRA" \
    'del(.config.fixerContractPathAbs)'
  w_fix_contract_abort "fix-$W_FIX_ARM_NAME-contract-empty" "$W_FIX_ARM_EXTRA" \
    '.config.fixerContractPathAbs = ""'
  w_fix_contract_abort "fix-$W_FIX_ARM_NAME-contract-relative" "$W_FIX_ARM_EXTRA" \
    '.config.fixerContractPathAbs = "shared/x.md"'
  w_fix_contract_abort "fix-$W_FIX_ARM_NAME-contract-traversal" "$W_FIX_ARM_EXTRA" \
    '.config.fixerContractPathAbs = "/p/../etc/x"'
done
# ...and the contract path must actually REACH the committing child, not merely
# survive the gate. The prompt half of the same key.
stage_args fix "$W_NONCE1" "$W_FIX_SIMPLIFY"
W_FIX_PROMPT_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
if [ "$(printf '%s' "$W_FIX_PROMPT_OUT" | jq -r '[.prompts[] | select(test("code-fixer-output-v1"))] | length')" = 1 ] \
   && [ "$(printf '%s' "$W_FIX_PROMPT_OUT" | jq -r '[.prompts[] | select(test("entire contents of the result file"))] | length')" = 1 ]; then
  pass "W[fix-simplify-contract-path] the simplify fixer prompt carries the contract path and the whole-file rule"
else
  fail "W[fix-simplify-contract-path] the simplify fixer prompt is unbound: $W_FIX_PROMPT_OUT"
fi

# The gate is REVIEW-SCOPED. Hoisting it into commonPreflight() would break
# /simplify entirely and no other row in this file would notice.
stage_args simplify "$W_NONCE1,$W_NONCE2,$W_NONCE3" '{}'
jq 'del(.config.phase1ContractPathAbs)' "$TMP/w-args.json" >"$TMP/w-args-simplify-contract.json"
W_SIMPLIFY_NC="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args-simplify-contract.json" 2>&1)"
if [ -z "$(printf '%s' "$W_SIMPLIFY_NC" | jq -r '.abortReason')" ] \
   && [ "$(printf '%s' "$W_SIMPLIFY_NC" | jq -r '.labels | length')" = 3 ]; then
  pass "W[simplify-contract-not-required] the lens stage still dispatches 3 without a Phase 1 contract"
else
  fail "W[simplify-contract-not-required] the contract gate leaked out of the review arm: $W_SIMPLIFY_NC"
fi

# --- W-CONFLICT: the two defects the ci-conflicts stage shipped with ---------
#
# 1. ONE authority scalar was forwarded for the WHOLE stage — the last iteration
#    of the controller's mint loop — and ciAuthorityContract() rendered it into
#    EVERY resolver's prompt under "Treat every value as exact". With N files,
#    N-1 resolvers were told their scope was the authority pinning someone
#    else's file. Nothing asserted per-resolver distinctness, so the bug was
#    invisible to the suite.
# 2. `ciConflictCap` was fed from `fanout_concurrency.conflict_resolver` — a
#    CONCURRENCY knob, default 10 — and used as a hard TOTAL, so an 11-conflict
#    PR aborted `bad_ci_conflict_count` with zero resolvers dispatched, while
#    dispatchRoster's wave loop two lines later existed to batch exactly that.
W_CONFLICT_PREFIX="/r/run/ci-authority-resolve-conflict-iter1-ci1-"
stage_args ci-conflicts "$W_NONCE1,$W_NONCE2,$W_NONCE3" \
  "$(printf '%s' "$W_CI_COMMON" | jq --arg p "$W_CONFLICT_PREFIX" \
     '. + {ciConflictCount:3, ciConflictCap:50, ciConflictWave:10,
           ciConflictAuthorityPrefixAbs:$p}')"
W_CONFLICT_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
W_CONFLICT_AUTHORITIES="$(printf '%s' "$W_CONFLICT_OUT" \
  | jq -r '[.prompts[] | capture("ci_authority_path   = (?<p>[^\n]+)").p] | @csv' 2>/dev/null)"
W_CONFLICT_DISTINCT="$(printf '%s' "$W_CONFLICT_OUT" \
  | jq -r '[.prompts[] | capture("ci_authority_path   = (?<p>[^\n]+)").p] | unique | length' 2>/dev/null)"
if [ "$W_CONFLICT_DISTINCT" = 3 ] \
   && [ "$W_CONFLICT_AUTHORITIES" = "\"${W_CONFLICT_PREFIX}1.json\",\"${W_CONFLICT_PREFIX}2.json\",\"${W_CONFLICT_PREFIX}3.json\"" ]; then
  pass "W[ci-conflicts-authority] each resolver's prompt pins its OWN authority (1,2,3 — never one shared scalar)"
else
  fail "W[ci-conflicts-authority] resolvers share an authority pin: distinct=$W_CONFLICT_DISTINCT paths=$W_CONFLICT_AUTHORITIES"
fi
# ...and no digest is quoted to a child, because a per-resolver digest cannot be
# forwarded as one scalar and the wrong one is worse than none.
if ! printf '%s' "$W_CONFLICT_OUT" | jq -e '[.prompts[] | select(test("ci_authority_sha256"))] | length > 0' >/dev/null 2>&1; then
  pass "W[ci-conflicts-authority] no resolver prompt quotes a stage-wide authority digest"
else
  fail "W[ci-conflicts-authority] a resolver prompt still quotes ci_authority_sha256 — one scalar, N children"
fi
# The wave/total split: 11 conflicts, wave 10 -> ALL 11 dispatch, in 2 waves.
stage_args ci-conflicts "$(for i in $(seq 11); do printf '%s,' "$(printf '0%.0s' $(seq 62))$(printf '%02d' "$i")"; done | sed 's/,$//')" \
  "$(printf '%s' "$W_CI_COMMON" | jq --arg p "$W_CONFLICT_PREFIX" \
     '. + {ciConflictCount:11, ciConflictCap:50, ciConflictWave:10,
           ciConflictAuthorityPrefixAbs:$p}')"
W_WAVE_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
W_WAVE_ABORT="$(printf '%s' "$W_WAVE_OUT" | jq -r '.abortReason')"
W_WAVE_AGENTS="$(printf '%s' "$W_WAVE_OUT" | jq -r '.labels | length')"
if [ -z "$W_WAVE_ABORT" ] && [ "$W_WAVE_AGENTS" = 11 ]; then
  pass "W[ci-conflicts-wave] 11 conflicts with a wave size of 10 dispatch ALL 11 (the knob is the wave, not the cap)"
else
  fail "W[ci-conflicts-wave] abort='$W_WAVE_ABORT' dispatched=$W_WAVE_AGENTS (want no abort, 11)"
fi
# ...and the DEFAULT total ceiling is NOT the wave knob's 10: omit
# ciConflictCap entirely and 11 must still dispatch. (What the default resolves
# to exactly — `min(50, maxAgents)` — is E6a/E6b's job, driven against the
# maxAgents the call sites emit rather than against a literal.)
stage_args ci-conflicts "$(for i in $(seq 11); do printf '%s,' "$(printf '0%.0s' $(seq 62))$(printf '%02d' "$i")"; done | sed 's/,$//')" \
  "$(printf '%s' "$W_CI_COMMON" | jq --arg p "$W_CONFLICT_PREFIX" \
     '. + {ciConflictCount:11, ciConflictWave:10, ciConflictAuthorityPrefixAbs:$p}')"
W_DEFAULT_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
if [ -z "$(printf '%s' "$W_DEFAULT_OUT" | jq -r '.abortReason')" ] \
   && [ "$(printf '%s' "$W_DEFAULT_OUT" | jq -r '.labels | length')" = 11 ]; then
  pass "W[ci-conflicts-wave] the DEFAULT total ceiling is not the wave knob's 10"
else
  fail "W[ci-conflicts-wave] ciConflictCap still defaults to the concurrency knob: $W_DEFAULT_OUT"
fi
# ...and the TOTAL ceiling still fails closed above itself, so the guard is live
# rather than merely widened away.
stage_args ci-conflicts "$W_NONCE1,$W_NONCE2" \
  "$(printf '%s' "$W_CI_COMMON" | jq --arg p "$W_CONFLICT_PREFIX" \
     '. + {ciConflictCount:6, ciConflictCap:5, ciConflictWave:10,
           ciConflictAuthorityPrefixAbs:$p}')"
if [ "$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1 | jq -r '.abortReason')" \
     = bad_ci_conflict_count ]; then
  pass "W[ci-conflicts-wave] a set above the TOTAL ceiling still refuses (bad_ci_conflict_count)"
else
  fail "W[ci-conflicts-wave] the total ceiling no longer fails closed"
fi

# /simplify reaches `defer` too, on the mode branch that has no Phase 1
# aggregate — the arm f2iPrompt's own phase1Path prose is written for.
stage_args defer "$W_NONCE1" '{}'
jq '.config.mode = "simplify" | .config.phase1PathAbs = ""' \
  "$TMP/w-args.json" >"$TMP/w-args-simplify.json"
W_SIMPLIFY_DEFER="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args-simplify.json" 2>&1)"
if [ "$(printf '%s' "$W_SIMPLIFY_DEFER" | jq -r '.threw // "null"')" = null ] \
   && [ -z "$(printf '%s' "$W_SIMPLIFY_DEFER" | jq -r '.abortReason')" ] \
   && [ "$(printf '%s' "$W_SIMPLIFY_DEFER" | jq -r '.labels | length')" = 1 ]; then
  pass "W[defer-simplify] /simplify's Phase 2.5 executes with an empty phase1_path"
else
  fail "W[defer-simplify] /simplify's Phase 2.5 broke: $W_SIMPLIFY_DEFER"
fi

# W-neg — the harness must be able to SEE a swallowed throw, or every row above
# is vacuous. Inject one into a copy of the script and require a red.
W_SABOTAGE="$TMP/sabotaged-workflow.js"
sed 's|^function f2iPrompt(nonce) {|function f2iPrompt(nonce) {\n  lines_that_do_not_exist.push(childInputPath(undeclared_slug));|' \
  "$WORKFLOW" >"$W_SABOTAGE"
stage_args defer "$W_NONCE1" '{}'
W_SAB_OUT="$(node "$W_HARNESS" "$W_SABOTAGE" "$TMP/w-args.json" 2>&1)"
if [ "$(printf '%s' "$W_SAB_OUT" | jq -r '.threw // "null"')" != null ]; then
  pass "W-neg an undeclared identifier inside a prompt builder is caught (the #383 shape)"
else
  fail "W-neg the harness MISSED an injected ReferenceError — every W row above is vacuous"
fi

# ---------------------------------------------------------------------------
# E — the Phase 3 CROSS-FENCE primitives, exercised in shells that inherited
#     NOTHING (#383)
# ---------------------------------------------------------------------------
# These live in lib/review-fleet-args.sh, which is engine, not caller: the
# `ci-*` stages are dispatched with bindings these functions mint, and the
# counters/pointers/path lists they publish are the ONLY way a value crosses a
# Workflow call. Every probe below uses `env -i`, because an env-passing probe
# MASKS the whole fence-scoped-shell-state class it exists to catch.
echo
echo "== E: the Phase 3 cross-fence primitives survive a cleared environment =="

E_TMP="$TMP/engine-crossfence"
mkdir -p "$E_TMP"

# E1 — the loop counters. Recomputing them instead of reading them back is what
# made CI iteration 2 refuse `authority_preexists` with no audit event.
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 3 2 "[]" "[\"code_bug\"]"' \
  _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1
E_STATE_READBACK="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_read_ci_state "$2/ci-loop-state.json" ci_loop_iter' \
  _ "$ARGS_LIB" "$E_TMP" 2>/dev/null)"
[ "$E_STATE_READBACK" = 3 ] \
  && pass "E1a the CI loop counter reads 3 in a shell that inherited nothing" \
  || fail "E1a the loop counter did not survive a fresh shell: '$E_STATE_READBACK'"
E_LOADED="$(env -i PATH="$PATH" bash -c '. "$1"
  review_fleet_load_ci_counters "$2" || exit 9
  printf "%s|%s" "$CI_FIX_LOOP_ITER" "$REVIEW_ITERATION"' _ "$ARGS_LIB" "$E_TMP" 2>/dev/null)"
[ "$E_LOADED" = '3|2' ] \
  && pass "E1b review_fleet_load_ci_counters rebinds BOTH counters off disk (3|2)" \
  || fail "E1b counter load drifted: '$E_LOADED'"
# Absent state file is the only time the fresh-shell default is the right answer.
E_DEFAULT="$(env -i PATH="$PATH" bash -c '. "$1"
  review_fleet_load_ci_counters "$2" || exit 9
  printf "%s|%s" "$CI_FIX_LOOP_ITER" "$REVIEW_ITERATION"' _ "$ARGS_LIB" "$E_TMP/absent" 2>/dev/null)"
[ "$E_DEFAULT" = '1|1' ] \
  && pass "E1c an absent state file defaults to iteration 1 of both counters" \
  || fail "E1c absent-state default drifted: '$E_DEFAULT'"

# E8 — WHICH green. `green` and `green_after_fix` are two CI_OUTCOME_ENUM
# members separated by ONE fact — whether an autopilot rewrote the head the CI
# just passed on — and that fact lives in ci-loop-state.json's `fix_pushes`,
# never in the fence that observes the green. #400: the member had seven readers
# and zero producers, so a rewritten head and a human-pushed one serialised
# IDENTICALLY into phases.phase3.outcome. These rows pin the single derivation
# both green terminals now call. `env -i` for the same reason as every other E
# row: the ledger is the only channel, so a probe that inherits state proves
# nothing.
E8_DIR="$E_TMP/green-outcome"
mkdir -p "$E8_DIR/absent"
E8_SHA="$(printf 'a%.0s' $(seq 40))"

E8_ABSENT="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/absent" 2>/dev/null)"
[ "$E8_ABSENT" = green ] \
  && pass "E8a an absent ledger is the first probe of the run, not an error: green" \
  || fail "E8a absent-ledger outcome drifted: '$E8_ABSENT'"
# ...and it must be SILENT. `green` is the answer on this path, so a diagnostic
# on stderr here is noise that trains the operator to ignore the real ones.
E8_ABSENT_ERR="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1 >/dev/null' \
  _ "$ARGS_LIB" "$E8_DIR/absent" 2>&1)"
[ -z "$E8_ABSENT_ERR" ] \
  && pass "E8a2 the absent-ledger path writes nothing to stderr" \
  || fail "E8a2 absent ledger wrote to stderr: '$E8_ABSENT_ERR'"

mkdir -p "$E8_DIR/empty"
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 1 1 "[]" "[]"' \
  _ "$ARGS_LIB" "$E8_DIR/empty" >/dev/null 2>&1
E8_EMPTY="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/empty" 2>/dev/null)"
[ "$E8_EMPTY" = green ] \
  && pass "E8b a ledger recording zero fix pushes is a plain green" \
  || fail "E8b empty-fix_pushes outcome drifted: '$E8_EMPTY'"

mkdir -p "$E8_DIR/pushed"
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 2 2 \
  "[{\"sha\":\"$3\",\"by_agent\":\"ci-code-fixer\"}]" "[\"code_bug\"]"' \
  _ "$ARGS_LIB" "$E8_DIR/pushed" "$E8_SHA" >/dev/null 2>&1
E8_PUSHED="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/pushed" 2>/dev/null)"
[ "$E8_PUSHED" = green_after_fix ] \
  && pass "E8c a recorded fix push upgrades the same green to green_after_fix" \
  || fail "E8c a rewritten head still serialised as a plain green: '$E8_PUSHED'"

# E8d/E8e/E8f — present-but-broken is NOT "no fixes". Folding a truncated,
# crashed or wrong-typed producer to 0 is the `jq length … || echo 0` masking
# class (#263/#265), and HERE it would launder a rewritten head into a clean
# one: the exact inverse of the signal this function carries.
#
# These three assert rc is EXACTLY 2, not merely non-zero. An absent function
# exits 127 with empty output, which satisfies "non-zero and silent" perfectly —
# so the loose form would go green against a tree with no implementation at all
# and prove nothing. 2 is the refusal code every other refusal in this library
# uses, and 127 is distinguishable from it.
mkdir -p "$E8_DIR/zero"
: >"$E8_DIR/zero/ci-loop-state.json"
E8_ZERO="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/zero" 2>/dev/null)"
E8_ZERO_RC=$?
{ [ "$E8_ZERO_RC" -eq 2 ] && [ -z "$E8_ZERO" ]; } \
  && pass "E8d a 0-byte ledger is refused (rc 2), not folded to 'no fixes'" \
  || fail "E8d 0-byte ledger returned rc=$E8_ZERO_RC out='$E8_ZERO' (want rc 2, empty)"

mkdir -p "$E8_DIR/garbage"
printf 'not json' >"$E8_DIR/garbage/ci-loop-state.json"
E8_GARBAGE="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/garbage" 2>/dev/null)"
E8_GARBAGE_RC=$?
{ [ "$E8_GARBAGE_RC" -eq 2 ] && [ -z "$E8_GARBAGE" ]; } \
  && pass "E8e a non-JSON ledger is refused (rc 2), not folded to 'no fixes'" \
  || fail "E8e non-JSON ledger returned rc=$E8_GARBAGE_RC out='$E8_GARBAGE' (want rc 2, empty)"

# E8f is the row that justifies the `type == "array"` guard specifically: for
# this fixture review_fleet_read_ci_state returns rc 0 PRINTING `3`, so an rc
# check alone waves it straight through to `[ 3 -gt 0 ]` → green_after_fix on a
# ledger that recorded no push at all.
mkdir -p "$E8_DIR/nonarray"
printf '{"ci_loop_iter":1,"review_iteration":1,"fix_pushes":3,"failure_classes_seen":[]}\n' \
  >"$E8_DIR/nonarray/ci-loop-state.json"
E8_NONARRAY="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1' \
  _ "$ARGS_LIB" "$E8_DIR/nonarray" 2>/dev/null)"
E8_NONARRAY_RC=$?
{ [ "$E8_NONARRAY_RC" -eq 2 ] && [ -z "$E8_NONARRAY" ]; } \
  && pass "E8f a non-array fix_pushes is refused (rc 0 from the reader is NOT the detector)" \
  || fail "E8f non-array fix_pushes returned rc=$E8_NONARRAY_RC out='$E8_NONARRAY' (want rc 2, empty)"

# E8g — probe-only (`--no-ci-fix`, CI_FIX_PHASE=0) never upgrades. 6c.4 skips
# the fixer arms entirely, so by construction no fixer ran; a ledger some prior
# non-probe-only run left behind is not evidence about THIS head.
E8_PROBE_ONLY="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 0' \
  _ "$ARGS_LIB" "$E8_DIR/pushed" 2>/dev/null)"
[ "$E8_PROBE_ONLY" = green ] \
  && pass "E8g probe-only mode answers green even with a non-empty ledger on disk" \
  || fail "E8g probe-only outcome drifted: '$E8_PROBE_ONLY'"

# E8h — arity and the fix-phase domain. A silently-accepted third argument or an
# unrecognised phase is how a caller's typo becomes a wrong outcome.
E8_ARITY_OK=1
for e8_args in 1 3 badphase; do
  case "$e8_args" in
    1) env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2"' \
         _ "$ARGS_LIB" "$E8_DIR/empty" >/dev/null 2>&1 ;;
    3) env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 1 extra' \
         _ "$ARGS_LIB" "$E8_DIR/empty" >/dev/null 2>&1 ;;
    badphase) env -i PATH="$PATH" bash -c '. "$1"; review_fleet_ci_green_outcome "$2" 2' \
         _ "$ARGS_LIB" "$E8_DIR/empty" >/dev/null 2>&1 ;;
  esac
  [ "$?" -eq 2 ] || E8_ARITY_OK=0
done
[ "$E8_ARITY_OK" = 1 ] \
  && pass "E8h wrong arity and an unrecognised CI_FIX_PHASE are refused with rc 2" \
  || fail "E8h a malformed call was accepted instead of returning rc 2"

# E2 — the conflicted-path list. Held in a shell array it was gone by the time
# `git add -- "${conflicted_files[@]}"` ran, and `git add --` with zero
# pathspecs exits 0, so the `|| abort` guard never fired.
bash -c '. "$1"; review_fleet_write_conflict_paths "$2/paths.zlist" "src/a b.py" "src/plain.py"' \
  _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1
E_PATHS="$(env -i PATH="$PATH" bash -c '
  count=0; last=
  while IFS= read -r -d "" p; do count=$((count + 1)); last="$p"; done <"$1/paths.zlist"
  printf "%s|%s" "$count" "$last"' _ "$E_TMP" 2>/dev/null)"
[ "$E_PATHS" = '2|src/plain.py' ] \
  && pass "E2a the conflicted-path list round-trips NUL-delimited (space-bearing path intact)" \
  || fail "E2a conflicted-path handoff drifted: '$E_PATHS'"
if bash -c '. "$1"; review_fleet_write_conflict_paths "$2/empty.zlist"' _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1; then
  fail "E2b an empty conflicted-file set was accepted — staging would silently no-op"
else
  pass "E2b an empty conflicted-file set is refused, not published"
fi
# E2c — the DOCUMENTED spelling. The signature comment is `PATH -- PATH...`,
# and it is the only `--` among ~25 signature comments in that file, so the
# callers half two of #383 writes are the ones that will follow it. A body that
# does not consume the separator writes a literal `--` as the FIRST NUL entry,
# the reader feeds it into `git add -- "${conflicted_files[@]}"` as a pathspec,
# git answers "pathspec '--' did not match any files", the stage guard fires,
# and the CONFLICT arm aborts a rebase it could have finished. Assert on the
# FIRST entry, not just the count: a trailing check would pass on the literal.
bash -c '. "$1"; review_fleet_write_conflict_paths "$2/sep.zlist" -- "src/a b.py" "src/plain.py"' \
  _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1
E_SEP_PATHS="$(env -i PATH="$PATH" bash -c '
  count=0; first=; last=
  while IFS= read -r -d "" p; do
    count=$((count + 1)); last="$p"
    [ "$count" -eq 1 ] && first="$p"
  done <"$1/sep.zlist"
  printf "%s|%s|%s" "$count" "$first" "$last"' _ "$E_TMP" 2>/dev/null)"
[ "$E_SEP_PATHS" = '2|src/a b.py|src/plain.py' ] \
  && pass "E2c the documented \`PATH -- PATH...\` spelling publishes ONLY the real paths" \
  || fail "E2c the \`--\` separator leaked into the pathspec list: '$E_SEP_PATHS'"
# E2d — and consuming the separator must not open a hole in the arity guard:
# `PATH --` names zero conflicted files, which is E2b's defect wearing the
# documented spelling.
if bash -c '. "$1"; review_fleet_write_conflict_paths "$2/sep-empty.zlist" --' _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1; then
  fail "E2d \`PATH --\` with no paths was accepted — an empty list under the documented spelling"
else
  pass "E2d \`PATH --\` with no paths is refused, same as the bare empty set"
fi

# E3 — the push record. Passing $NEW_HEAD_SHA between fences in a variable
# recorded an EMPTY sha into phases.phase3.fix_pushes: an audit row naming no
# commit, which reads as a push that happened.
E_SHA="$(printf 'a%.0s' $(seq 40))"
bash -c '. "$1"; review_fleet_write_ci_push "$2/push.json" "$3" ci-rebase-handler' \
  _ "$ARGS_LIB" "$E_TMP" "$E_SHA" >/dev/null 2>&1
E_PUSH_SHA="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_read_ci_push "$2/push.json" sha' \
  _ "$ARGS_LIB" "$E_TMP" 2>/dev/null)"
[ "$E_PUSH_SHA" = "$E_SHA" ] \
  && pass "E3a the pushed sha reaches the re-entry fence through a cleared environment" \
  || fail "E3a the push record did not survive a fresh shell: '$E_PUSH_SHA'"
if bash -c '. "$1"; review_fleet_write_ci_push "$2/bad.json" "" ci-rebase-handler' _ "$ARGS_LIB" "$E_TMP" >/dev/null 2>&1; then
  fail "E3b an empty sha was recorded as a push"
else
  pass "E3b an empty sha is refused, so fix_pushes can never name no commit"
fi

# E4 — the launch-sidecar POINTER. The CONFLICT arm's restage advances the CI
# loop counter and persists it, so a push fence that RECOMPUTES the sidecar
# name looks for a file nothing ever wrote.
E_PTR="$E_TMP/pointer"
mkdir -p "$E_PTR"
bash -c '. "$1"
  review_fleet_write_sidecar "$2/review-fleet-ci-fix-iter1-ci1.launch.json" '"'"'{"edge_id":"review_pr.ci.rebase"}'"'"' "$2/child" inst 0000000000000000000000000000000000000000
  review_fleet_write_ci_pointer "$2/ci-fix-launch-pointer.txt" "$2/review-fleet-ci-fix-iter1-ci1.launch.json"' \
  _ "$ARGS_LIB" "$E_PTR" >/dev/null 2>&1
bash -c '. "$1"; review_fleet_write_ci_state "$2/ci-loop-state.json" 2 1 "[]" "[]"' \
  _ "$ARGS_LIB" "$E_PTR" >/dev/null 2>&1
E_OLD="$(env -i PATH="$PATH" bash -c '. "$1"
  review_fleet_load_ci_counters "$2" || exit 9
  test -r "$2/review-fleet-ci-fix-iter${REVIEW_ITERATION}-ci${CI_FIX_LOOP_ITER}.launch.json" && echo found || echo missing' \
  _ "$ARGS_LIB" "$E_PTR" 2>&1)"
E_NEW="$(env -i PATH="$PATH" bash -c '. "$1"
  sidecar="$(review_fleet_read_ci_pointer "$2/ci-fix-launch-pointer.txt")" || exit 9
  review_fleet_read_sidecar "$sidecar" binding' _ "$ARGS_LIB" "$E_PTR" 2>&1)"
if [ "$E_OLD" = missing ] && [ "$E_NEW" = '{"edge_id":"review_pr.ci.rebase"}' ]; then
  pass "E4a after a restage the recomputed sidecar name is gone and the pointer still resolves"
else
  fail "E4a recomputed='$E_OLD' pointer='$E_NEW'"
fi
if bash -c '. "$1"
    review_fleet_write_ci_pointer "$2/dangling.txt" "$2/nothing-here.json"
    review_fleet_read_ci_pointer "$2/dangling.txt"' _ "$ARGS_LIB" "$E_PTR" >/dev/null 2>&1; then
  fail "E4b a dangling pointer read as success"
else
  pass "E4b a pointer to a missing sidecar refuses instead of yielding an empty path"
fi

# E5 — the rebase-state probe. `git -C <dir> rev-parse --git-path rebase-merge`
# prints a path RELATIVE TO <dir>, so the cwd-relative spelling answered for
# whatever directory the harness shell happened to be in.
E_REBASE_TMP="$TMP/engine-rebase"
mkdir -p "$E_REBASE_TMP"
(
  set -e
  cd "$E_REBASE_TMP"
  git init -q -b main repo
  cd repo
  git config user.email fixture@example.invalid
  git config user.name Fixture
  mkdir sub
  printf 'base\n' >f.txt
  git add -- f.txt
  git commit -qm 'test: base'
  git checkout -qb feat
  printf 'feat\n' >f.txt
  git commit -qam 'test: feat'
  git checkout -q main
  printf 'main\n' >f.txt
  git commit -qam 'test: main'
  git checkout -q feat
  git rebase main
) >/dev/null 2>&1 || true    # the fixture rebase MUST conflict
E_REPO="$E_REBASE_TMP/repo"
if [ -n "$(git -C "$E_REPO" status --porcelain | grep '^UU ' || true)" ]; then
  E_PROBE_OLD="$(cd "$E_REPO/sub" && [ -d "$(git -C "$E_REPO" rev-parse --git-path rebase-merge)" ] && echo detected || echo missed)"
  E_PROBE_SUB="$(cd "$E_REPO/sub" && bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null && echo detected || echo missed' _ "$ARGS_LIB" "$E_REPO")"
  E_PROBE_ROOT="$(cd / && bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null && echo detected || echo missed' _ "$ARGS_LIB" "$E_REPO")"
  if [ "$E_PROBE_OLD" = missed ] && [ "$E_PROBE_SUB" = detected ] && [ "$E_PROBE_ROOT" = detected ]; then
    pass "E5a the old cwd-relative test MISSES a live rebase; the shared probe finds it from anywhere"
  else
    fail "E5a old=$E_PROBE_OLD new(subdir)=$E_PROBE_SUB new(/)=$E_PROBE_ROOT"
  fi
  E_CLEAN_RC=0
  bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null' _ "$ARGS_LIB" "$REPO_ROOT" || E_CLEAN_RC=$?
  E_BROKEN_RC=0
  bash -c '. "$1"; review_fleet_rebase_dir "$2" >/dev/null' _ "$ARGS_LIB" "$E_REBASE_TMP/not-a-repo" || E_BROKEN_RC=$?
  if [ "$E_CLEAN_RC" = 1 ] && [ "$E_BROKEN_RC" = 2 ]; then
    pass "E5b no-rebase (rc 1) and probe-failed (rc 2) are distinguishable"
  else
    fail "E5b clean rc=$E_CLEAN_RC broken rc=$E_BROKEN_RC (want 1 and 2)"
  fi
else
  fail "E5 the mid-rebase fixture did not conflict; the rows above would be vacuous"
fi

# E6 — the conflict ceiling is ONE number on both sides of the boundary, and
# that number is NOT the one either side spells.
#
# The row this replaces compared the shell constant against the script's
# `ciConflictCap` clamp default (50 == 50) and passed — while the ci-conflicts
# roster is dispatched as ONE roster whose length goes into ceilingGate(), so
# `maxAgents` (40 at every review-fleet call site) was a second, LOWER ceiling
# that neither literal named. 45 conflicted files were accepted here and then
# aborted `agent_ceiling` with zero resolvers dispatched — the exact failure the
# cap/wave split was introduced to eliminate. A cap-to-cap comparison is
# structurally incapable of seeing that, so this row does not compare literals:
# it DRIVES the shipped script at the cap and at cap+1 under the maxAgents the
# call sites really emit, and separately pins the shell constant to the lowest
# maxAgents any call site emits.
E_CAP_SHELL="$(bash -c '. "$1"; printf "%s" "$REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP"' _ "$ARGS_LIB" 2>/dev/null)"
# The minimum maxAgents literal across EVERY review-fleet emit site. Reading it
# from the command files rather than hardcoding 40 is what keeps this row alive
# if a future PR retunes the ceiling. The min is taken by awk, not `sort -n |
# head -1`: this file sets `set -o pipefail`, and tests/epipe-guard.test.sh
# refuses a pipe into an early-exiting reader repo-wide.
E_MAX_AGENTS_MIN="$(grep -hoE 'maxAgents=[0-9]+' "$REVIEW_CMD" "$SIMPLIFY_CMD" \
  | awk -F= 'NR == 1 || $2 < lowest { lowest = $2 } END { if (NR) print lowest }')"
if [ -n "$E_CAP_SHELL" ] && [ -n "$E_MAX_AGENTS_MIN" ] \
   && [ "$E_CAP_SHELL" -le "$E_MAX_AGENTS_MIN" ]; then
  pass "E6 the controller ceiling ($E_CAP_SHELL) is at or under the lowest emitted maxAgents ($E_MAX_AGENTS_MIN)"
else
  fail "E6 ceiling drift: shell cap='$E_CAP_SHELL' lowest emitted maxAgents='$E_MAX_AGENTS_MIN'"
fi

# E6a/E6b — BEHAVIOURAL. Drive the real ci-conflicts stage with the emitted
# maxAgents. At the cap every resolver must dispatch; at cap+1 the refusal must
# be the NAMED up-front one, never `agent_ceiling` (accept-then-kill is the bug).
e6_nonces() {  # e6_nonces N -> N distinct 64-hex nonces, comma-joined
  local n="$1" i out=''
  for i in $(seq "$n"); do
    out="$out,$(printf '0%.0s' $(seq 58))$(printf '%06d' "$i")"
  done
  printf '%s' "${out#,}"
}
e6_drive() {  # e6_drive N -> "<abortReason>|<dispatched>"
  local n="$1" out
  stage_args ci-conflicts "$(e6_nonces "$n")" \
    "$(printf '%s' "$W_CI_COMMON" | jq --argjson n "$n" --argjson m "$E_MAX_AGENTS_MIN" \
       --arg p "/r/run/ci-authority-resolve-conflict-iter1-ci1-" \
       '. + {maxAgents:$m, ciConflictCount:$n, ciConflictWave:10,
             ciConflictAuthorityPrefixAbs:$p}')"
  out="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
  printf '%s|%s' "$(printf '%s' "$out" | jq -r '.abortReason')" \
                 "$(printf '%s' "$out" | jq -r '.labels | length')"
}
E_AT_CAP="$(e6_drive "$E_CAP_SHELL")"
if [ "$E_AT_CAP" = "|$E_CAP_SHELL" ]; then
  pass "E6a a set AT the controller ceiling ($E_CAP_SHELL) dispatches every resolver"
else
  fail "E6a at the cap the engine returned '$E_AT_CAP' (want '|$E_CAP_SHELL')"
fi
E_OVER_CAP="$(e6_drive "$((E_CAP_SHELL + 1))")"
if [ "$E_OVER_CAP" = "bad_ci_conflict_count|0" ]; then
  pass "E6b a set ABOVE it refuses by name up-front, not agent_ceiling after acceptance"
else
  fail "E6b at cap+1 the engine returned '$E_OVER_CAP' (want 'bad_ci_conflict_count|0')"
fi

# V3 — the cap is ONE number on both sides, and above it the refusal is the
# NAMED up-front one, never `agent_ceiling` after acceptance. Same shape and
# same reason as E6a/E6b for the conflict fanout.
V_CAP_SHELL="$(bash -c '. "$1"; printf "%s" "$REVIEW_FLEET_VERIFY_TOTAL_CAP"' _ "$ARGS_LIB" 2>/dev/null)"
if [ -n "$V_CAP_SHELL" ] && [ -n "$E_MAX_AGENTS_MIN" ] && [ "$V_CAP_SHELL" -le "$E_MAX_AGENTS_MIN" ]; then
  pass "V3 the verify ceiling ($V_CAP_SHELL) is at or under the lowest emitted maxAgents ($E_MAX_AGENTS_MIN)"
else
  fail "V3 verify ceiling drift: shell cap='$V_CAP_SHELL' lowest emitted maxAgents='$E_MAX_AGENTS_MIN'"
fi
v_drive() {  # v_drive N -> "<abortReason>|<dispatched>"
  local n="$1" out
  stage_args verify "$(e6_nonces "$n")" \
    "$(printf '%s' "$W_VERIFY_COMMON" | jq --argjson n "$n" --argjson m "$E_MAX_AGENTS_MIN" \
       '. + {maxAgents:$m, verifyCount:$n, verifyCap:50}')"
  out="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
  printf '%s|%s' "$(printf '%s' "$out" | jq -r '.abortReason')" \
                 "$(printf '%s' "$out" | jq -r '.labels | length')"
}
V_AT_CAP="$(v_drive "$V_CAP_SHELL")"
[ "$V_AT_CAP" = "|$V_CAP_SHELL" ] \
  && pass "V3a a roster AT the verify ceiling ($V_CAP_SHELL) dispatches every verifier" \
  || fail "V3a at the cap the engine returned '$V_AT_CAP' (want '|$V_CAP_SHELL')"
V_OVER_CAP="$(v_drive "$((V_CAP_SHELL + 1))")"
[ "$V_OVER_CAP" = "bad_verify_count|0" ] \
  && pass "V3b a roster ABOVE it refuses by name up-front, not agent_ceiling after acceptance" \
  || fail "V3b at cap+1 the engine returned '$V_OVER_CAP' (want 'bad_verify_count|0')"
V_ZERO="$(v_drive 0 2>/dev/null || true)"
stage_args verify "$W_NONCE1" \
  "$(printf '%s' "$W_VERIFY_COMMON" | jq '. + {verifyCount:0, verifyCap:50}')"
V_ZERO_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
[ "$(printf '%s' "$V_ZERO_OUT" | jq -r '.abortReason')" = "bad_verify_count" ] \
  && pass "V3c verifyCount=0 refuses by name (the controller short-circuits a zero roster without calling the script)" \
  || fail "V3c verifyCount=0 did not refuse: $(printf '%s' "$V_ZERO_OUT" | jq -r '.abortReason')"

# V4 — the controller's two no-dispatch short-circuits exist in the command.
grep -Fq 'REVIEW_CONFIDENCE_THRESHOLD" -eq 0' "$REVIEW_CMD" \
  && grep -Fq 'gate-disabled' "$REVIEW_CMD" \
  && pass "V4a review-pr short-circuits threshold=0 to a gate-disabled sidecar with no Workflow call" \
  || fail "V4a the threshold=0 kill switch is missing from review-pr.md"
grep -Fq 'over-cap-unverified' "$REVIEW_CMD" \
  && pass "V4b review-pr records rows past the dispatch cap instead of dropping them" \
  || fail "V4b review-pr does not record over-cap rows"
grep -Fq 'verifier-unavailable' "$REVIEW_CMD" \
  && pass "V4c review-pr records an unusable child result as verifier-unavailable (fail toward keeping)" \
  || fail "V4c review-pr has no fail-toward-keeping arm for an unusable verifier result"

# ---------------------------------------------------------------------------
# E7 — the CI BINDERS are EXECUTED, against the real contract
# ---------------------------------------------------------------------------
# review_fleet_bind_ci and review_fleet_bind_ci_conflicts mint every Phase 3
# child's launch binding and are the only callers of `bind-workflow-ci-launch`.
# Until this section they had structural coverage ONLY: G19a greps for the
# function names, G19b seds the bodies out and checks they do not name a non-CI
# producer. Nothing executed either one. Section B cannot reach them (it runs
# mint fences extracted from the command files, and PR 1 correctly ships no CI
# command fence) and the crossplatform zsh probe drives the writers, not the
# binders — so the 10-arg arity check, the closed edge-slug case, the 40-hex
# head_before check and, above all, the authority digest that ties a CI child to
# its authority document were all unproven. Blanking
# `--ci-authority-sha256` inside review_fleet_bind_ci left this suite,
# review-pr-phase3-ci, crossplatform-shell-wrappers and review-child-inputs ALL
# green; the first signal would have been a runtime ci_binding_invalid.
E7_ROOT="$TMP/e7"
mkdir -p "$E7_ROOT"
(
  set -e
  cd "$E7_ROOT"
  git init -q -b main repo
  cd repo
  git config user.email fixture@example.invalid
  git config user.name Fixture
  printf 'print("hi")\n' >app.py
  git add -- app.py
  git commit -qm 'test: base'
) >/dev/null 2>&1
E7_REPO="$(cd "$E7_ROOT/repo" && pwd -P)"
E7_RUN="$E7_REPO/.uberdev/research/E7RUN"
mkdir -p "$E7_RUN"
printf 'FAIL test_alpha\n' >"$E7_RUN/ci-log.txt"
E7_LOG_SHA="$(python3 -I -B -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(),end="")' "$E7_RUN/ci-log.txt")"
E7_HEAD="$(git -C "$E7_REPO" rev-parse HEAD)"

# e7_mint EDGE OUTPUT_BASENAME [EXTRA ARGS...] -> "<authority_path>|<sha256>"
e7_mint() {
  local edge="$1" basename="$2"; shift 2
  python3 -I -B "$CONTRACT" prepare-ci-authority \
    --edge-id "$edge" --pr-number 41 --run-id 77 --head-sha "$E7_HEAD" \
    --working-dir "$E7_REPO" --input-path "$E7_RUN/ci-log.txt" \
    --input-sha256 "$E7_LOG_SHA" \
    --authority-output-path "$E7_RUN/$basename" "$@" \
    | jq -r '"\(.authority_path)|\(.authority_sha256)"'
}
E7_CLASSIFY="$(e7_mint review_pr.ci.classify ci-authority-classify-iter01-ci01.json 2>/dev/null || true)"
if [ -z "$E7_CLASSIFY" ]; then
  fail "E7 setup: prepare-ci-authority produced no classify authority — every row below would be vacuous"
else
  E7_AUTH_PATH="${E7_CLASSIFY%%|*}"
  E7_AUTH_SHA="${E7_CLASSIFY##*|}"
  # e7_bind_ci ARGS... -> "<rc>|<child_dir>|<sidecar ci_authority_sha256>"
  e7_bind_ci() {
    env -i PATH="$PATH" HOME="$HOME" bash -c '
      . "$1"; shift
      sidecar="$1"; shift
      rc=0
      review_fleet_bind_ci "$@" >/dev/null 2>&1 || rc=$?
      pinned=""
      if [ -r "$sidecar" ]; then
        pinned="$(jq -r ".binding" <"$sidecar" | jq -r ".ci_authority_sha256 // \"\"")"
      fi
      printf "%s|%s|%s" "$rc" "${REVIEW_FLEET_CHILD_DIR:-}" "$pinned"' \
      _ "$ARGS_LIB" "$@"
  }
  E7_SIDECAR="$E7_RUN/classify.launch.json"
  E7_OK="$(e7_bind_ci "$E7_SIDECAR" review_pr.ci.classify "$E7_RUN" 1 1 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" '' "$E7_SIDECAR")"
  if [ "$E7_OK" = "0|$E7_RUN/children/ci-classify-ci01-iter01|$E7_AUTH_SHA" ]; then
    pass "E7a review_fleet_bind_ci mints a real binding at the script-derived dir, pinned to the authority digest"
  else
    fail "E7a bind_ci returned '$E7_OK' (want '0|$E7_RUN/children/ci-classify-ci01-iter01|$E7_AUTH_SHA')"
  fi
  # The digest pin is the point of using the CI producer at all. Blank it and
  # the binder must refuse rather than mint an unpinned CI binding.
  E7_BLANK="$(e7_bind_ci "$E7_RUN/blank.launch.json" review_pr.ci.classify "$E7_RUN" 1 2 \
    "$E7_REPO" "$CONTRACT" "$E7_AUTH_PATH" '' '' "$E7_RUN/blank.launch.json")"
  case "$E7_BLANK" in
    0\|*) fail "E7b an EMPTY --ci-authority-sha256 minted a binding: '$E7_BLANK'" ;;
    *)    pass "E7b an empty authority digest is refused, not minted as an unpinned CI binding" ;;
  esac
  # Arity, the closed edge set and the 40-hex head_before are all rc-2 refusals.
  # Matched with `case`, never `| grep -q`: this file sets `set -o pipefail` and
  # tests/epipe-guard.test.sh refuses a pipe into an early-exiting reader.
  E7_NEG=0
  e7_expect_rc2() {
    local observed
    observed="$(e7_bind_ci "$@")"
    case "$observed" in
      2\|*) ;;
      *) E7_NEG=$((E7_NEG + 1)) ;;
    esac
  }
  # 9 args (the sidecar dropped) — the one slip that silently writes nowhere.
  e7_expect_rc2 "$E7_RUN/n1.json" review_pr.ci.classify "$E7_RUN" 1 3 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" ''
  # 11 args. This is the case the arity check ALONE catches: with an extra
  # trailing argument every positional the body reads is still bound, so
  # without `[ "$#" -eq 10 ]` the binder happily mints a child for a call whose
  # shape the caller and the callee disagree about.
  e7_expect_rc2 "$E7_RUN/n1b.json" review_pr.ci.classify "$E7_RUN" 1 3 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" '' "$E7_RUN/n1b.json" extra
  # An edge outside the closed single-child set.
  e7_expect_rc2 "$E7_RUN/n2.json" review_pr.ci.resolve_conflict "$E7_RUN" 1 3 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" '' "$E7_RUN/n2.json"
  # head_before that is neither empty nor 40 hex.
  e7_expect_rc2 "$E7_RUN/n3.json" review_pr.ci.classify "$E7_RUN" 1 3 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" "${E7_HEAD}0" "$E7_RUN/n3.json"
  e7_expect_rc2 "$E7_RUN/n4.json" review_pr.ci.classify "$E7_RUN" 1 3 "$E7_REPO" \
    "$CONTRACT" "$E7_AUTH_PATH" "$E7_AUTH_SHA" "$(printf 'z%.0s' $(seq 40))" "$E7_RUN/n4.json"
  if [ "$E7_NEG" -eq 0 ]; then
    pass "E7c bad arity, an out-of-set edge and a non-40-hex head_before are all rc-2 refusals"
  else
    fail "E7c $E7_NEG of the 5 bind_ci argument refusals did not return rc 2"
  fi

  # The N-child fanout. One authority per resolver, so the ledger must carry N
  # DISTINCT instances and each row's own authority — never one shared pin.
  E7_LEDGER_IN="$E7_RUN/authority.ledger"
  : >"$E7_LEDGER_IN"
  E7_LEDGER_OK=1
  for i in 1 2 3; do
    E7_ROW="$(e7_mint review_pr.ci.resolve_conflict \
      "ci-authority-resolve-conflict-iter01-ci01-$i.json" \
      --base-sha "$E7_HEAD" --pr-branch feat/x --base-branch main \
      --target-path app.py 2>/dev/null || true)"
    [ -n "$E7_ROW" ] || { E7_LEDGER_OK=0; break; }
    printf '%s\t%s\n' "${E7_ROW%%|*}" "${E7_ROW##*|}" >>"$E7_LEDGER_IN"
  done
  if [ "$E7_LEDGER_OK" != 1 ]; then
    fail "E7 setup: no resolve_conflict authority could be minted — E7d/E7e would be vacuous"
  else
    E7_FANOUT="$(env -i PATH="$PATH" HOME="$HOME" bash -c '
      . "$1"
      rc=0
      review_fleet_bind_ci_conflicts "$2" 1 1 "$3" "$4" "$5" "$6" >/dev/null 2>&1 || rc=$?
      printf "%s|%s|%s" "$rc" "${REVIEW_FLEET_CONFLICT_COUNT:-}" \
        "$(printf "%s" "${REVIEW_FLEET_NONCE_POOL:-}" | tr "," "\n" | grep -c "^[0-9a-f]\{64\}$")"' \
      _ "$ARGS_LIB" "$E7_RUN" "$E7_REPO" "$CONTRACT" "$E7_LEDGER_IN" "$E7_RUN/conflicts.ledger")"
    E7_INSTANCES="$(jq -r '.instance' <"$E7_RUN/conflicts.ledger" 2>/dev/null | sort -u | grep -c . || echo 0)"
    E7_PINS="$(jq -r '.binding | fromjson | .ci_authority_path' <"$E7_RUN/conflicts.ledger" 2>/dev/null | sort -u | grep -c . || echo 0)"
    if [ "$E7_FANOUT" = '0|3|3' ] && [ "$E7_INSTANCES" = 3 ] && [ "$E7_PINS" = 3 ]; then
      pass "E7d review_fleet_bind_ci_conflicts mints 3 distinct children, 3 nonces and 3 DISTINCT authority pins"
    else
      fail "E7d conflict fanout returned '$E7_FANOUT' instances=$E7_INSTANCES distinct-pins=$E7_PINS (want '0|3|3', 3, 3)"
    fi
    : >"$E7_RUN/empty.ledger"
    E7_EMPTY_RC=0
    env -i PATH="$PATH" HOME="$HOME" bash -c '. "$1"
      review_fleet_bind_ci_conflicts "$2" 1 1 "$3" "$4" "$5" "$6"' \
      _ "$ARGS_LIB" "$E7_RUN" "$E7_REPO" "$CONTRACT" "$E7_RUN/empty.ledger" \
      "$E7_RUN/empty-out.ledger" >/dev/null 2>&1 || E7_EMPTY_RC=$?
    if [ "$E7_EMPTY_RC" != 0 ]; then
      pass "E7e an empty authority ledger is refused, so a zero-child conflict wave cannot be published"
    else
      fail "E7e an empty authority ledger minted a zero-child conflict wave"
    fi
  fi
fi

# E8 — the conflict ENUMERATOR (#398). E7 binds the fanout and E2c/E2d lock the
# writer, but nothing PRODUCED the set: the Step-4 re-bind in
# commands/review-pr.md inlined `git status --porcelain | awk '/^UU /'` in a
# markdown fence. Two exact bytes against code_fixer_contract.py's seven-pair
# membership test, so an add/add rebase conflict was CONFLICT to the judge and
# the empty set to the enumerator — zero resolvers dispatched, "all RESOLVED"
# vacuously true, and the arm aborted a mid-rebase it could have finished.
#
# Mutation guard (revert the named production fix in your worktree, re-run):
#   revert the CLI verb to `^UU` only  -> P1, P2 (contract suite), E8a red
#   revert `read -r -d ''` to bash's array-slurp builtin
#                                      -> crossplatform-shell-wrappers Z1 red
#   collapse the rc to two values      -> E8d red
#   drop the `--` from `git add`       -> review-pr-phase3-ci S13.21 red
#   leave the prose saying "UU"        -> review-pr-phase3-ci S13.23 red
# ubuntu's apt zsh is CI's ONLY proxy for the macOS Bash-tool runtime these
# fences actually execute in — there is no macOS shape-check job.
E8_TMP="$TMP/engine-unmerged"
mkdir -p "$E8_TMP"
# Same recipe as E5's, but an ADD/ADD: BOTH sides create the colliding path, so
# there is no common ancestor blob and git records `AA`, never `UU`. That is the
# whole point — a `UU` fixture passes under the retired shape too.
e8_conflict_repo() {
  (
    set -e
    cd "$1"
    git init -q -b main repo
    cd repo
    git config user.email fixture@example.invalid
    git config user.name Fixture
    mkdir src
    printf 'KEEP = 1\n' >src/keep.py
    git add -- src/keep.py
    git commit -qm 'test: base'
    printf "COLLIDE = 'main'\n" >"$2"
    git add -- "$2"
    git commit -qm 'test: main adds the colliding path'
    git checkout -qb fix/398-collide HEAD~1
    printf "COLLIDE = 'branch'\n" >"$2"
    git add -- "$2"
    git commit -qm 'test: the branch adds it too'
    git rebase main
  ) >/dev/null 2>&1 || true    # the fixture rebase MUST conflict
}
mkdir -p "$E8_TMP/plain"
e8_conflict_repo "$E8_TMP/plain" src/collide.py
E8_REPO="$E8_TMP/plain/repo"
E8_PORCELAIN="$(git -C "$E8_REPO" status --porcelain 2>/dev/null)"
case "$E8_PORCELAIN" in
  *'AA '*) E8_GATE=ok ;;
  *) E8_GATE=no-aa ;;
esac
case "$E8_PORCELAIN" in
  *'UU '*) E8_GATE=stray-uu ;;
esac
if [ "$E8_GATE" != ok ]; then
  fail "E8 the add/add fixture did not conflict as AA ($E8_GATE); the rows below would be vacuous"
else
  E8_OUT="$E8_TMP/paths.zlist"
  E8_WANT="$E8_TMP/want.zlist"
  printf 'src/collide.py\0' >"$E8_WANT"
  E8_RC=0
  bash -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
    _ "$ARGS_LIB" "$E8_REPO" "$CONTRACT" "$E8_OUT" >/dev/null 2>&1 || E8_RC=$?
  if [ "$E8_RC" = 0 ] && cmp -s "$E8_OUT" "$E8_WANT"; then
    pass "E8a the enumerator reaches the AA conflict the judge already calls CONFLICT"
  else
    fail "E8a rc=$E8_RC payload='$(od -c <"$E8_OUT" 2>/dev/null | tr '\n' ' ')' (want rc 0 and src/collide.py NUL)"
  fi

  # E8e — NEGATIVE CONTROL, placed before the rows that depend on it: without
  # this, E8a passes for the wrong reason the day someone reverts the widening.
  E8_RETIRED="$(git -C "$E8_REPO" status --porcelain | awk -v c2=2 '/^UU / {print $c2}' | wc -l | tr -d ' ')"
  if [ "$E8_RETIRED" = 0 ]; then
    pass "E8e the retired \`^UU\` shape enumerates ZERO files on the same fixture"
  else
    fail "E8e the retired shape found $E8_RETIRED file(s) — the fixture is not add/add and E8a is vacuous"
  fi

  # E8b — a conflicted path with a SPACE is ONE record. `-z` porcelain is
  # unquoted; the non-`-z` form C-quotes it, which is the second half of why the
  # retired whitespace-split shape truncated it.
  mkdir -p "$E8_TMP/spaced"
  e8_conflict_repo "$E8_TMP/spaced" 'src/a b.py'
  E8_SPACED_REPO="$E8_TMP/spaced/repo"
  E8_SPACED_OUT="$E8_TMP/spaced.zlist"
  E8_SPACED_RC=0
  bash -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
    _ "$ARGS_LIB" "$E8_SPACED_REPO" "$CONTRACT" "$E8_SPACED_OUT" >/dev/null 2>&1 || E8_SPACED_RC=$?
  E8_SPACED_FILES=()
  while IFS= read -r -d '' e8_entry; do
    E8_SPACED_FILES+=("$e8_entry")
  done <"$E8_SPACED_OUT"
  if [ "$E8_SPACED_RC" = 0 ] && [ "${#E8_SPACED_FILES[@]}" -eq 1 ] \
     && [ "${E8_SPACED_FILES[0]}" = 'src/a b.py' ]; then
    pass "E8b a conflicted path containing a space reads back as ONE entry"
  else
    fail "E8b rc=$E8_SPACED_RC count=${#E8_SPACED_FILES[@]} first='${E8_SPACED_FILES[0]:-}'"
  fi

  # E8c/E8d — three-valued, for the same reason review_fleet_rebase_dir is
  # (E5b). A two-valued probe maps "python3 missing / git unreadable" onto "no
  # conflicts to resolve", which is the silent-empty collapse this issue is
  # about. Compared separately so a run where BOTH are wrong cannot pass.
  E8_CLEAN_OUT="$E8_TMP/clean.zlist"
  E8_CLEAN_RC=0
  bash -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
    _ "$ARGS_LIB" "$REPO_ROOT" "$CONTRACT" "$E8_CLEAN_OUT" >/dev/null 2>&1 || E8_CLEAN_RC=$?
  if [ "$E8_CLEAN_RC" = 1 ] && [ -f "$E8_CLEAN_OUT" ] && [ ! -s "$E8_CLEAN_OUT" ]; then
    pass "E8c a repository with no unmerged paths answers rc 1 and an empty payload"
  else
    fail "E8c rc=$E8_CLEAN_RC (want 1) exists=$([ -f "$E8_CLEAN_OUT" ] && echo y || echo n) size=$(wc -c <"$E8_CLEAN_OUT" 2>/dev/null | tr -d ' ')"
  fi
  E8_BROKEN_RC=0
  bash -c '. "$1"; review_fleet_unmerged_paths "$2" "$3" "$4"' \
    _ "$ARGS_LIB" "$E8_TMP/not-a-repo" "$CONTRACT" "$E8_TMP/broken.zlist" >/dev/null 2>&1 || E8_BROKEN_RC=$?
  if [ "$E8_BROKEN_RC" = 2 ] && [ "$E8_CLEAN_RC" = 1 ]; then
    pass "E8d no-conflicts (rc 1) and probe-failed (rc 2) are distinguishable"
  else
    fail "E8d clean rc=$E8_CLEAN_RC broken rc=$E8_BROKEN_RC (want 1 and 2)"
  fi

  # E8f — CHAIN PROOF. The set the enumerator produces, read back the way the
  # fence reads it, is a set the locked writer reproduces byte-for-byte. This is
  # what joins the new producer to review_fleet_write_conflict_paths (E2c/E2d)
  # and to review_fleet_bind_ci_conflicts (E7d) as one wire format.
  E8_CHAIN=()
  while IFS= read -r -d '' e8_entry; do
    E8_CHAIN+=("$e8_entry")
  done <"$E8_OUT"
  E8_CHAIN_OUT="$E8_TMP/chain.zlist"
  E8_CHAIN_RC=0
  # Guarded, not because the empty set is interesting here but because bash 3.2
  # (the macOS system bash) treats `"${arr[@]}"` on an EMPTY array as unbound
  # under `set -u` — an E8a failure would otherwise abort the run instead of
  # reporting E8f.
  if [ "${#E8_CHAIN[@]}" -eq 0 ]; then
    E8_CHAIN_RC=90
  else
    bash -c '. "$1"; shift; target="$1"; shift; review_fleet_write_conflict_paths "$target" -- "$@"' \
      _ "$ARGS_LIB" "$E8_CHAIN_OUT" "${E8_CHAIN[@]}" >/dev/null 2>&1 || E8_CHAIN_RC=$?
  fi
  if [ "$E8_CHAIN_RC" = 0 ] && cmp -s "$E8_OUT" "$E8_CHAIN_OUT"; then
    pass "E8f the enumerated set round-trips through review_fleet_write_conflict_paths byte-identically"
  else
    fail "E8f rc=$E8_CHAIN_RC payloads differ between the enumerator and the writer"
  fi
fi

# ---------------------------------------------------------------------------
# E9 — the Phase 1 reviewer output contract is RESOLVED, never re-declared (#403)
# ---------------------------------------------------------------------------
# policy/solve-run-tree-v1.json is the single declaration of which file the
# Phase 1 reviewers must obey; lib/child-dispatch.sh already resolves it for the
# ROUTED path. The Workflow composer has no filesystem, so the controller must
# resolve the same declaration and hand the absolute path across the envelope.
# A hardcoded literal in the lib would satisfy E9a and fail E9b, which is the
# whole reason E9b computes the expected value from the manifest independently.
echo
echo "== E9: the Phase 1 reviewer output contract resolves from the policy manifest =="

E9_ROOT="$REPO_ROOT/plugins/uberdev"
E9_MANIFEST="$E9_ROOT/policy/solve-run-tree-v1.json"
E9_TMP="$TMP/e9"
mkdir -p "$E9_TMP"

# e9_call ROOT ARGS... -> stdout on fd 1, stderr into $E9_TMP/err, rc in $E9_RC
e9_call() {
  E9_OUT="$(env -i PATH="$PATH" bash -c '. "$1"; shift; review_fleet_contract_path "$@"' \
    _ "$ARGS_LIB" "$@" 2>"$E9_TMP/err")"
  E9_RC=$?
}

# E9a — it resolves, and it prints the file the plugin actually ships.
e9_call "$E9_ROOT" phase1-reviewer-v1
E9_EXPECT="$E9_ROOT/$(jq -r '.output_contracts["phase1-reviewer-v1"] // empty' "$E9_MANIFEST")"
if [ "$E9_RC" = 0 ] && [ "$E9_OUT" = "$E9_EXPECT" ] && [ -f "$E9_OUT" ]; then
  pass "E9a review_fleet_contract_path resolves phase1-reviewer-v1 to an existing file"
else
  fail "E9a resolver returned rc=$E9_RC '$E9_OUT' (expected rc 0 and '$E9_EXPECT')"
fi

# E9b — THE COMPARATOR. The printed value must be the manifest's declaration
# joined onto the plugin root, not a literal spelled a second time in the lib.
# A hardcoded path passes E9a (it equals today's declaration) and fails here.
mkdir -p "$E9_TMP/alt/policy" "$E9_TMP/alt/shared"
printf 'alternate\n' >"$E9_TMP/alt/shared/alternate-contract.md"
jq -n '{output_contracts:{"phase1-reviewer-v1":"shared/alternate-contract.md"}}' \
  >"$E9_TMP/alt/policy/solve-run-tree-v1.json"
e9_call "$E9_TMP/alt" phase1-reviewer-v1
if [ "$E9_RC" = 0 ] && [ "$E9_OUT" = "$E9_TMP/alt/shared/alternate-contract.md" ] \
   && ! grep -Fq 'shared/phase1-reviewer-output-v1' "$ARGS_LIB"; then
  pass "E9b the resolver FOLLOWS the manifest declaration and spells no second copy of the path"
else
  fail "E9b resolver ignored the manifest declaration (rc=$E9_RC, '$E9_OUT') or re-declares the path"
fi

# E9c — an unknown id is a NAMED refusal, never a silent empty string.
e9_call "$E9_ROOT" bogus-contract-id
E9_ERR_LINES="$(grep -c . "$E9_TMP/err" 2>/dev/null || echo 0)"
if [ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ] && [ "$E9_ERR_LINES" = 1 ] \
   && grep -Fq 'bogus-contract-id' "$E9_TMP/err"; then
  pass "E9c an unknown contract id is rc 2, empty stdout and exactly one diagnostic naming the id"
else
  fail "E9c unknown id returned rc=$E9_RC stdout='$E9_OUT' stderr-lines=$E9_ERR_LINES"
fi

# E9d — unsafe manifest values. Each fixture CREATES the file the unsafe value
# would reach, so the refusal is attributable to the predicate and not merely to
# a missing file.
e9_fixture() {  # DECLARED_VALUE -> builds $E9_TMP/fx and echoes its root
  rm -rf "$E9_TMP/fx"
  mkdir -p "$E9_TMP/fx/policy" "$E9_TMP/fx/shared" "$E9_TMP/fx/a"
  jq -n --arg v "$1" '{output_contracts:{"phase1-reviewer-v1":$v}}' \
    >"$E9_TMP/fx/policy/solve-run-tree-v1.json"
  printf 'contract\n' >"$E9_TMP/fx/shared/phase1-reviewer-output-v1.md"
  printf 'contract\n' >"$E9_TMP/fx/abs.md"
  printf 'contract\n' >"$E9_TMP/fx/a.md"
  printf 'contract\n' >"$E9_TMP/fx/b.md"
  printf 'contract\n' >"$E9_TMP/fx/a/b.md"
  printf 'contract\n' >"$E9_TMP/escape.md"
  printf 'contract\n' >"$E9_TMP/fx/sh\\ared.md"
  printf '%s' "$E9_TMP/fx"
}
E9_UNSAFE_BAD=0
E9_UNSAFE_WHICH=""
for e9_value in '../escape.md' '/abs.md' 'a//b.md' './a.md' 'a/../b.md' 'sh\ared.md' ''; do
  e9_call "$(e9_fixture "$e9_value")" phase1-reviewer-v1
  if [ "$E9_RC" != 2 ] || [ -n "$E9_OUT" ]; then
    E9_UNSAFE_BAD=$((E9_UNSAFE_BAD + 1))
    E9_UNSAFE_WHICH="$E9_UNSAFE_WHICH '$e9_value'(rc=$E9_RC)"
  fi
done
if [ "$E9_UNSAFE_BAD" = 0 ]; then
  pass "E9d every traversal, absolute, dot-component, double-slash, backslash and empty declaration is rc 2 with empty stdout"
else
  fail "E9d $E9_UNSAFE_BAD unsafe declaration(s) were accepted:$E9_UNSAFE_WHICH"
fi

# E9e — a declared-but-absent file is a refusal, not a path to a file the child
# would then fail to read halfway through a wave.
e9_call "$(e9_fixture 'shared/does-not-exist.md')" phase1-reviewer-v1
[ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ] \
  && pass "E9e a declared contract file that does not exist is refused (rc 2)" \
  || fail "E9e a missing contract file returned rc=$E9_RC '$E9_OUT'"

# E9f — the contract FILE is itself a symlink. This pins the `[ ! -L ]` guard,
# and ONLY that guard: `-L` is tested one line before the containment check, so
# this fixture is refused before realpath is ever consulted. It used to claim
# the containment check was the only predicate that could see it, which was
# false and left that check with zero coverage — E9i is the row that reaches it.
E9_FX="$(e9_fixture 'shared/link.md')"
ln -sf "$E9_TMP/escape.md" "$E9_FX/shared/link.md"
e9_call "$E9_FX" phase1-reviewer-v1
[ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ] \
  && pass "E9f a contract symlinked out of the plugin root is refused" \
  || fail "E9f a symlinked contract escaped the root check: rc=$E9_RC '$E9_OUT'"

# E9g — a relative plugin root. The resolved value is emitted into an envelope
# key skills/review-fleet/workflow.js gates with isSafeAbsPath(), which requires
# a leading '/'; a relative answer would abort the whole wave downstream.
E9_OUT="$(env -i PATH="$PATH" bash -c 'cd "$2" || exit 9; . "$1"; review_fleet_contract_path plugins/uberdev phase1-reviewer-v1' \
  _ "$ARGS_LIB" "$REPO_ROOT" 2>/dev/null)"
E9_RC=$?
[ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ] \
  && pass "E9g a relative PLUGIN_ROOT is refused (the envelope key must be absolute)" \
  || fail "E9g a relative PLUGIN_ROOT resolved to '$E9_OUT' (rc=$E9_RC)"

# E9h — arity. Both a missing id and a stray third word are wiring bugs.
E9_ARITY_BAD=0
e9_call; [ "$E9_RC" = 2 ] || E9_ARITY_BAD=$((E9_ARITY_BAD + 1))
e9_call "$E9_ROOT"; [ "$E9_RC" = 2 ] || E9_ARITY_BAD=$((E9_ARITY_BAD + 1))
e9_call "$E9_ROOT" phase1-reviewer-v1 extra; [ "$E9_RC" = 2 ] || E9_ARITY_BAD=$((E9_ARITY_BAD + 1))
[ "$E9_ARITY_BAD" = 0 ] \
  && pass "E9h 0, 1 and 3 arguments are each rc 2" \
  || fail "E9h $E9_ARITY_BAD of the 3 arity refusals did not return rc 2"

# E9i — THE CONTAINMENT PREDICATE, and the only row that can reach it.
#
# E9f symlinks the contract FILE, so `[ ! -L "$contract_abs" ]` refuses it one
# line before `beneath(realpath(root), realpath(target))` runs — proven by
# mutation: blanking the two realpath assignments and the case that consumes
# them left the whole suite green. Here the DIRECTORY COMPONENT is the symlink
# and a plain regular file sits at the far end, so `-f`, `-r` and `! -L` all
# pass on the contract itself (asserted below, so this row cannot silently
# decay into a second copy of E9f) and only the realpath containment can refuse.
E9_FX="$(e9_fixture 'shared/phase1-reviewer-output-v1.md')"
mkdir -p "$E9_TMP/outside"
printf 'contract\n' >"$E9_TMP/outside/phase1-reviewer-output-v1.md"
rm -rf "$E9_FX/shared"
ln -s "$E9_TMP/outside" "$E9_FX/shared"
E9_ESCAPED="$E9_FX/shared/phase1-reviewer-output-v1.md"
e9_call "$E9_FX" phase1-reviewer-v1
if [ -f "$E9_ESCAPED" ] && [ -r "$E9_ESCAPED" ] && [ ! -L "$E9_ESCAPED" ] \
   && [ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ]; then
  pass "E9i a contract behind a symlinked DIRECTORY component is refused by the realpath containment check"
elif [ ! -f "$E9_ESCAPED" ] || [ -L "$E9_ESCAPED" ]; then
  fail "E9i fixture did not defeat the -f/-L guards, so it cannot reach the containment check"
else
  fail "E9i a symlinked directory component escaped the containment check: rc=$E9_RC '$E9_OUT'"
fi

# E9j — st_nlink != 1. lib/child-dispatch.sh, resolving the SAME contract id for
# the SAME six edges, calls a hardlinked contract `invalid_output_contract`; a
# Workflow transport that accepts it hands six reviewers an authority the routed
# transport would have refused. The fixture is verified to really be a hard link
# before the assertion is read, so a platform that copies instead of linking
# fails loudly rather than passing vacuously.
E9_FX="$(e9_fixture 'shared/phase1-reviewer-output-v1.md')"
printf 'contract\n' >"$E9_TMP/fx/hardlink-origin.md"
rm -f "$E9_FX/shared/phase1-reviewer-output-v1.md"
ln "$E9_TMP/fx/hardlink-origin.md" "$E9_FX/shared/phase1-reviewer-output-v1.md" 2>/dev/null
E9_NLINK="$(python3 -I -B -c 'import os,sys;print(os.lstat(sys.argv[1]).st_nlink)' \
  "$E9_FX/shared/phase1-reviewer-output-v1.md" 2>/dev/null)"
e9_call "$E9_FX" phase1-reviewer-v1
if [ "$E9_NLINK" = 2 ] && [ "$E9_RC" = 2 ] && [ -z "$E9_OUT" ] \
   && grep -Fq 'hard links' "$E9_TMP/err"; then
  pass "E9j a hardlinked contract (st_nlink=2) is refused under its own diagnostic, matching the routed resolver"
else
  fail "E9j hardlinked contract: nlink='$E9_NLINK' rc=$E9_RC out='$E9_OUT' err='$(cat "$E9_TMP/err")'"
fi

# E9k — the 1..65536 size window, at both edges AND just inside the upper one.
# The accept row is what stops "refuse everything big" from passing as "enforce
# the twin's bound". OWNERSHIP (st_uid == euid, the third refusal the routed
# resolver carries) is NOT covered here: constructing a regular file owned by
# another uid needs root, and this suite runs unprivileged on ubuntu and macOS.
# It is asserted only by the shared predicate being written once, in the same
# probe as these two — not by a row of its own.
E9_SIZE_BAD=0
E9_SIZE_WHICH=""
for e9_size in 0 65537 65536; do
  E9_FX="$(e9_fixture 'shared/phase1-reviewer-output-v1.md')"
  python3 -I -B -c 'import sys
with open(sys.argv[1],"wb") as fh: fh.write(b"x"*int(sys.argv[2]))' \
    "$E9_FX/shared/phase1-reviewer-output-v1.md" "$e9_size"
  e9_call "$E9_FX" phase1-reviewer-v1
  if [ "$e9_size" = 65536 ]; then
    if [ "$E9_RC" != 0 ] || [ "$E9_OUT" != "$E9_FX/shared/phase1-reviewer-output-v1.md" ]; then
      E9_SIZE_BAD=$((E9_SIZE_BAD + 1))
      E9_SIZE_WHICH="$E9_SIZE_WHICH ${e9_size}B-should-be-accepted(rc=$E9_RC)"
    fi
  elif [ "$E9_RC" != 2 ] || [ -n "$E9_OUT" ] || ! grep -Fq '1..65536 bytes' "$E9_TMP/err"; then
    E9_SIZE_BAD=$((E9_SIZE_BAD + 1))
    E9_SIZE_WHICH="$E9_SIZE_WHICH ${e9_size}B-should-be-refused(rc=$E9_RC)"
  fi
done
if [ "$E9_SIZE_BAD" = 0 ]; then
  pass "E9k an empty and an oversized contract are refused by size while exactly 65536 bytes is accepted"
else
  fail "E9k $E9_SIZE_BAD size boundary case(s) went the wrong way:$E9_SIZE_WHICH"
fi

# ---------------------------------------------------------------------------
# L — the six cross-fence carriers the #427 follow-up added, LOCKED
# ---------------------------------------------------------------------------
# Six real defects of one shape were fixed in commands/review-pr.md and
# lib/review-fleet-args.sh with ZERO regression coverage: a value produced in
# one `bash` fence and read in the next, where the next fence is a different
# process and the scalar is simply the empty string. Reverting both files to
# their pre-fix state left SIXTEEN suites green, so none of them was watching.
# These rows are that watch, and each one was written against a reverted copy of
# its own fix and kept only once it reddened for its own reason.
#
# Shape follows R45/R46 in tests/review-pr.test.sh: the command file is scanned
# STRUCTURALLY over an extracted fence body (bind-before-read, writer/reader
# position), never with a bare grep a prose sentence could satisfy — every one
# of these fences DOCUMENTS the carrier it hands forward, so a `grep -F` for the
# carrier name passes on the broken tree too. The lib halves are EXECUTED under
# `env -i`, for the same reason every E row is: an env-passing probe masks the
# whole fence-scoped-state class it exists to catch.
echo
echo "== L: the cross-fence carriers of the #427 follow-up (six, plus #479's seventh) =="

L_TMP="$TMP/locks"
mkdir -p "$L_TMP"

# l_extract TOKEN OUT — the body of the ONE review-pr.md ```bash fence holding
# TOKEN. EXACTLY one: a token matching two fences would silently scan the wrong
# one and a token matching none would scan nothing at all, which is how a
# structural lock decays into a row that cannot fail. Every anchor below is a
# token that predates all six fixes, so a reverted tree still resolves it and
# the mutation reds the LOCK rather than the anchor.
l_extract() {
  python3 -I -B - "$REVIEW_CMD" "$1" >"$2" 2>/dev/null <<'PY'
import re
import sys

path, token = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
bodies = []
index = 0
while index < len(lines):
    match = re.match(r"^([ \t]*)```bash", lines[index])
    if match:
        indent = match.group(1)
        close = index + 1
        while close < len(lines) and not re.match(r"^" + re.escape(indent) + r"```\s*$", lines[close]):
            close += 1
        body = "\n".join(lines[index + 1:close])
        if token in body:
            bodies.append(body)
        index = close + 1
    else:
        index += 1
if len(bodies) != 1:
    raise SystemExit(1)
sys.stdout.write(bodies[0])
PY
}

L_ANCHOR_MISS=""
l_anchor() {  # NAME TOKEN
  l_extract "$2" "$L_TMP/$1.fence" || { L_ANCHOR_MISS="$L_ANCHOR_MISS $1(no-unique-fence)"; return; }
  [ "$(grep -c '' "$L_TMP/$1.fence")" -ge 20 ] \
    || L_ANCHOR_MISS="$L_ANCHOR_MISS $1(body-too-short)"
}
l_anchor scope   'review_fleet_write_review_base'
# Re-anchored off `post_review_validated_evidence_complete` (#481): Phase 2 now
# calls the same builder from its OWN fence, so that token names two fences and
# `l_extract` would refuse both. This token names the Phase 1 validated-ledger
# path, sits inside the same 4w.2 fence, and predates the change — so every
# L-row below still reads byte-identical bytes.
l_anchor capture 'review-fleet-review.validated'
l_anchor gate    'project-verification-claims'
l_anchor publish 'review-fleet-verify-opinions-iter'

# l_field REPORT KEY — one `key=value` line out of a scanner report.
l_field() { sed -n "s/^$2=//p" "$1"; }

# ---------------------------------------------------------------------------
# L0 — the scan is non-vacuous. Every row below reads one of these four fence
# bodies or the fixture run built under it; if an anchor stops resolving, the
# locks scan an empty string and pass on anything.
# ---------------------------------------------------------------------------
if [ -z "$L_ANCHOR_MISS" ]; then
  pass "L0 all four locked fences (scope / capture / verify-gate / verify-publish) resolve to exactly one fence each"
else
  fail "L0 a locked fence anchor no longer names exactly one real fence:$L_ANCHOR_MISS"
fi

# ---------------------------------------------------------------------------
# L1 — the changed-path set crosses 4w.1 -> 4w.2 ON DISK.
#
# THE DEFECT: 4w.2 opened with `review_fleet_rehydrate`, which does not bind
# CHANGED_PATHS_JSON, and then wrote `printf '%s' "$CHANGED_PATHS_JSON"` into
# post-review/changed-paths.json. The binder is the Phase 1 scope fence, a dead
# shell by then, so the write published 0 bytes and the aggregate refused
# `changed-paths-unavailable` on a review that had run perfectly.
#
# Structural and not behavioural because the answer is a POSITION: the fence
# that owns the value must be the writer, and the fence a process later must
# read it back before it reads the name at all.
# ---------------------------------------------------------------------------
python3 -I -B - "$L_TMP/scope.fence" "$L_TMP/capture.fence" >"$L_TMP/l1.report" 2>"$L_TMP/l1.err" <<'PY'
import re
import sys

WRITE = re.compile(r'>\s*"?[^"\s]*changed-paths\.json')
BIND = re.compile(r"^\s*CHANGED_PATHS_JSON=")
READ = re.compile(r"\$\{?CHANGED_PATHS_JSON\b")


def lines_of(path):
    return open(path, encoding="utf-8").read().split("\n")


def is_comment(line):
    # Full-line comments only. Both fences EXPLAIN the carrier they hand over,
    # naming `$CHANGED_PATHS_JSON` in prose; counting that as a read would make
    # every fence an offender and the row meaningless.
    return line.lstrip().startswith("#")


scope = lines_of(sys.argv[1])
capture = lines_of(sys.argv[2])
scope_writes = [i for i, l in enumerate(scope) if not is_comment(l) and WRITE.search(l)]
capture_writes = [i for i, l in enumerate(capture) if not is_comment(l) and WRITE.search(l)]
binds = [i for i, l in enumerate(capture) if BIND.match(l)]
reads = [i for i, l in enumerate(capture) if not is_comment(l) and READ.search(l)]
bind_at = binds[0] if binds else -1
ambient = [i + 1 for i in reads if bind_at < 0 or i < bind_at]
source = ""
guarded = "no"
if bind_at >= 0:
    # The bind must come off DISK. `$(cat "<path>")` and not a re-derivation:
    # a second `git diff --name-only` here would be a second answer to a
    # question the diff artifact and the commit range are already frozen against.
    match = re.search(r'CHANGED_PATHS_JSON="\$\(cat\s+"([^"]+)"\)"', capture[bind_at])
    if match:
        source = match.group(1)
        pattern = re.compile(r'\[\s+-s\s+"?' + re.escape(source) + r'"?\s+\]')
        for index in range(bind_at):
            if pattern.search(capture[index]):
                window = "\n".join(capture[index:index + 6])
                if re.search(r"^\s*return\s+[0-9]+", window, re.M):
                    guarded = "yes"
                break
print("scope_writes=%d" % len(scope_writes))
print("capture_writes=%d" % len(capture_writes))
print("capture_reads=%d" % len(reads))
print("ambient=%s" % ",".join(str(i) for i in ambient))
print("source=%s" % source)
print("guarded=%s" % guarded)
PY
L1_RC=$?
if [ "$L1_RC" = 0 ] \
   && [ "$(l_field "$L_TMP/l1.report" scope_writes)" = 1 ] \
   && [ "$(l_field "$L_TMP/l1.report" capture_writes)" = 0 ] \
   && [ "$(l_field "$L_TMP/l1.report" capture_reads)" -gt 0 ] 2>/dev/null \
   && [ -z "$(l_field "$L_TMP/l1.report" ambient)" ] \
   && [ -n "$(l_field "$L_TMP/l1.report" source)" ] \
   && [ "$(l_field "$L_TMP/l1.report" guarded)" = yes ]; then
  pass "L1 the changed-path set is written by the scope fence and read back from disk by 4w.2, refused loudly when absent"
else
  fail "L1 4w.2 reads CHANGED_PATHS_JSON ambiently or is still its writer (rc=$L1_RC): $(tr '\n' ' ' <"$L_TMP/l1.report")"
fi

# ---------------------------------------------------------------------------
# L2 — the verification sidecar is RE-created on re-entry, not created-if-absent.
#
# THE DEFECT: `[ -e "$VERIFY_SIDECAR_PATH" ] || ( umask 077 && : > ... )`.
# phase1-verification.json is the one Step 6b.0 artifact that cannot be
# iteration-keyed (findings-to-issues binds it by that exact basename), so a
# Phase 3 CI-fix loop re-entered Phase 1 with iteration 1's PUBLISHED sidecar
# still on disk; publish-verification captures its target with
# `_capture_regular(path, 0, 0)` and refuses a non-empty file. Iteration 2 could
# not publish at all.
# ---------------------------------------------------------------------------
python3 -I -B - "$L_TMP/gate.fence" >"$L_TMP/l2.report" 2>"$L_TMP/l2.err" <<'PY'
import re
import sys

body = open(sys.argv[1], encoding="utf-8").read().split("\n")


def is_comment(line):
    return line.lstrip().startswith("#")


bind_at = next((i for i, l in enumerate(body) if re.match(r"^\s*VERIFY_SIDECAR_PATH=", l)), -1)
# An existence TEST on the sidecar is the defect itself wearing any spelling.
exists_tests = [
    i + 1 for i, l in enumerate(body)
    if not is_comment(l) and re.search(r'\[\s+-[ef]\s+"\$VERIFY_SIDECAR_PATH"', l)
]
removes = [
    i for i, l in enumerate(body)
    if bind_at >= 0 and i > bind_at and l.strip().startswith("rm ") and "VERIFY_SIDECAR_PATH" in l
]
creates = [
    i for i, l in enumerate(body)
    if bind_at >= 0 and i > bind_at and re.search(r':\s*>"\$VERIFY_SIDECAR_PATH"', l)
]
# The create must be the whole statement, not the right arm of a guard: a line
# that STARTS with `(` is the umask subshell; one that starts with `[` is the
# create-if-absent this row exists to keep out.
unconditional = "no"
if creates and body[creates[0]].strip().startswith("("):
    unconditional = "yes"
print("bind=%d" % (bind_at + 1))
print("exists_tests=%s" % ",".join(str(i) for i in exists_tests))
print("removes=%d" % len(removes))
print("creates=%d" % len(creates))
print("rm_before_create=%s" % ("yes" if removes and creates and removes[0] < creates[0] else "no"))
print("unconditional_create=%s" % unconditional)
PY
L2_RC=$?
if [ "$L2_RC" = 0 ] \
   && [ "$(l_field "$L_TMP/l2.report" bind)" -gt 0 ] 2>/dev/null \
   && [ -z "$(l_field "$L_TMP/l2.report" exists_tests)" ] \
   && [ "$(l_field "$L_TMP/l2.report" removes)" -ge 1 ] 2>/dev/null \
   && [ "$(l_field "$L_TMP/l2.report" creates)" -ge 1 ] 2>/dev/null \
   && [ "$(l_field "$L_TMP/l2.report" rm_before_create)" = yes ] \
   && [ "$(l_field "$L_TMP/l2.report" unconditional_create)" = yes ]; then
  pass "L2 the Step 6b.0 gate removes and re-creates phase1-verification.json, so re-entry cannot publish onto iteration 1's sidecar"
else
  fail "L2 the sidecar is created-if-absent again (rc=$L2_RC): $(tr '\n' ' ' <"$L_TMP/l2.report")"
fi

# L2p — THE PREMISE, executed against the shipped contract. `publish-verification`
# captures its target with `_capture_regular(path, 0, 0)`; the `digest` verb is
# the same helper reachable from a CLI, so this row proves that a NON-EMPTY
# sidecar really is refused and that L2 is not guarding a hazard that no longer
# exists. It is deliberately independent of the six mutations.
: >"$L_TMP/sidecar-empty"
printf '{"schema_version":1}\n' >"$L_TMP/sidecar-published"
L2P_EMPTY_RC=0
python3 -I -B "$CONTRACT" digest --path "$L_TMP/sidecar-empty" --minimum 0 --maximum 0 >/dev/null 2>&1 \
  || L2P_EMPTY_RC=$?
L2P_FULL_RC=0
python3 -I -B "$CONTRACT" digest --path "$L_TMP/sidecar-published" --minimum 0 --maximum 0 \
  >/dev/null 2>"$L_TMP/l2p.err" || L2P_FULL_RC=$?
if [ "$L2P_EMPTY_RC" = 0 ] && [ "$L2P_FULL_RC" != 0 ] && grep -Fq artifact_size_invalid "$L_TMP/l2p.err"; then
  pass "L2p an already-published sidecar really is refused artifact_size_invalid by the 0..0 capture (the hazard L2 locks is live)"
else
  fail "L2p the 0..0 capture no longer refuses a non-empty sidecar (empty rc=$L2P_EMPTY_RC, published rc=$L2P_FULL_RC)"
fi

# ---------------------------------------------------------------------------
# L3 — the verify-dispatch decision crosses the Workflow mandate ON DISK.
#
# THE DEFECT: the gate fence set `VERIFY_DISPATCH=0|1` and the fence after the
# mandate consumed it — a different process, where the scalar is gone. On a
# short-circuit (empty roster, or threshold 0) the second fence would re-publish
# a sidecar the first had already filled, and publish-verification refuses that
# with `artifact_size_invalid`: a GREEN review turned into rc 74.
#
# Behavioural half under `env -i`, rc asserted EXACTLY 2 and not merely
# non-zero: an absent function exits 127 with empty output, which satisfies
# "non-zero and silent" perfectly and would pass on a tree with no
# implementation at all (the E8d idiom).
# ---------------------------------------------------------------------------
L3_DIR="$L_TMP/verify-dispatch"
mkdir -p "$L3_DIR"
l3_write() {  # PATH VALUE -> rc
  env -i PATH="$PATH" bash -c '. "$1"; review_fleet_write_verify_dispatch "$2" "$3"' \
    _ "$ARGS_LIB" "$1" "$2" >/dev/null 2>&1
}
l3_read() {  # PATH -> "<rc>|<stdout>"
  local out rc
  out="$(env -i PATH="$PATH" bash -c '. "$1"; review_fleet_read_verify_dispatch "$2"' \
    _ "$ARGS_LIB" "$1" 2>/dev/null)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}
L3_BAD=""
for l3_value in 0 1; do
  l3_write "$L3_DIR/decision-$l3_value.txt" "$l3_value" \
    || L3_BAD="$L3_BAD write($l3_value)-refused"
  l3_got="$(l3_read "$L3_DIR/decision-$l3_value.txt")"
  [ "$l3_got" = "0|$l3_value" ] || L3_BAD="$L3_BAD roundtrip($l3_value)='$l3_got'"
done
# An absent, empty or malformed record is NOT read as `0`: "the gate cannot say
# what it did" and "the gate dispatched nothing" are different answers, and only
# one of them means the sidecar is already published.
: >"$L3_DIR/zero-byte.txt"
printf 'yes\n' >"$L3_DIR/word.txt"
printf '2\n' >"$L3_DIR/out-of-domain.txt"
for l3_case in absent.txt zero-byte.txt word.txt out-of-domain.txt; do
  l3_got="$(l3_read "$L3_DIR/$l3_case")"
  [ "$l3_got" = '2|' ] || L3_BAD="$L3_BAD read($l3_case)='$l3_got'"
done
# The writer's domain is closed on its own side, and a refused write leaves no
# file for the reader to find.
for l3_value in 2 '' true; do
  if l3_write "$L3_DIR/rejected.txt" "$l3_value"; then
    L3_BAD="$L3_BAD write('$l3_value')-accepted"
  fi
done
[ -e "$L3_DIR/rejected.txt" ] && L3_BAD="$L3_BAD refused-write-left-a-file"
python3 -I -B - "$L_TMP/gate.fence" "$L_TMP/publish.fence" >"$L_TMP/l3.report" 2>"$L_TMP/l3.err" <<'PY'
import re
import sys

ASSIGN = re.compile(r"(^|[\s;&|(])VERIFY_DISPATCH=")
READ = re.compile(r"\$\{?VERIFY_DISPATCH\b")


def lines_of(path):
    return open(path, encoding="utf-8").read().split("\n")


def is_comment(line):
    return line.lstrip().startswith("#")


gate = lines_of(sys.argv[1])
publish = lines_of(sys.argv[2])
assigns = [i for i, l in enumerate(gate) if not is_comment(l) and ASSIGN.search(l)]
writes = [i for i, l in enumerate(gate) if re.match(r"^\s*review_fleet_write_verify_dispatch\s", l)]
# The stderr line the orchestrator keys the Workflow mandate on, in the same
# place and for the same reason as setup's `REVIEW_CARRY RUN_ID=` line.
emits = [i for i, l in enumerate(gate) if "REVIEW_VERIFY_DISPATCH=%s" in l and ">&2" in l]
binds = [
    i for i, l in enumerate(publish)
    if re.match(r'^\s*VERIFY_DISPATCH="\$\(review_fleet_read_verify_dispatch\s', l)
]
reads = [i for i, l in enumerate(publish) if not is_comment(l) and READ.search(l)]
defaults = [
    i + 1 for i, l in enumerate(publish)
    if not is_comment(l) and re.search(r"\$\{VERIFY_DISPATCH:[-=]", l)
]
print("gate_assigns=%d" % len(assigns))
print("gate_writes=%d" % len(writes))
# EVERY arm records: a write placed above one of the three assignments would
# persist a decision two of them never made.
print("write_after_every_assign=%s" % (
    "yes" if writes and assigns and writes[0] > max(assigns) else "no"))
print("gate_emits=%d" % len(emits))
print("publish_binds=%d" % len(binds))
print("publish_reads=%d" % len(reads))
print("read_before_bind=%s" % (
    "yes" if reads and (not binds or min(reads) < binds[0]) else "no"))
print("defaults=%s" % ",".join(str(i) for i in defaults))
PY
L3_RC=$?
[ "$L3_RC" = 0 ] || L3_BAD="$L3_BAD scanner-rc=$L3_RC"
[ "$(l_field "$L_TMP/l3.report" gate_assigns)" -ge 3 ] 2>/dev/null || L3_BAD="$L3_BAD gate-assigns"
[ "$(l_field "$L_TMP/l3.report" gate_writes)" -ge 1 ] 2>/dev/null || L3_BAD="$L3_BAD gate-write-missing"
[ "$(l_field "$L_TMP/l3.report" write_after_every_assign)" = yes ] || L3_BAD="$L3_BAD write-before-an-assign"
[ "$(l_field "$L_TMP/l3.report" gate_emits)" -ge 1 ] 2>/dev/null || L3_BAD="$L3_BAD mandate-key-missing"
[ "$(l_field "$L_TMP/l3.report" publish_binds)" = 1 ] || L3_BAD="$L3_BAD publish-bind"
[ "$(l_field "$L_TMP/l3.report" publish_reads)" -ge 1 ] 2>/dev/null || L3_BAD="$L3_BAD publish-never-reads"
[ "$(l_field "$L_TMP/l3.report" read_before_bind)" = no ] || L3_BAD="$L3_BAD publish-reads-ambiently"
[ -z "$(l_field "$L_TMP/l3.report" defaults)" ] || L3_BAD="$L3_BAD publish-defaults-the-decision"
if [ -z "$L3_BAD" ]; then
  pass "L3 the verify-dispatch decision is written and read through the typed lib pair, refusing absent/malformed rather than defaulting to 0"
else
  fail "L3 the dispatch decision still crosses the mandate as a scalar:$L3_BAD"
fi

# ---------------------------------------------------------------------------
# X3 — the verify publish fence CONSUMES the binding it mints (#514 item 2)
# ---------------------------------------------------------------------------
# THE DEFECT: review_fleet_bind_verify mints a `binding` per verifier into every
# ledger row and NOTHING ever read it. The publish fence took `.result` straight
# off the row and handed the path to the strict validator, so a verifier that
# echoed a nonce this run never minted, wrote outside the derived layout, or
# published a torn file was indistinguishable from one whose opinion simply did
# not parse — every one of them landed `verifier-unavailable`.
#
# Structural, over the extracted fence, for the same reason every L row is: the
# fence DOCUMENTS its own carriers in prose, so a bare `grep -F` for the verb
# passes on the broken tree too. What is asserted here is ORDER (capture before
# the opinion is read) and the SHAPE OF THE FAILURE BRANCH (degrade, never
# abort) — neither of which a comment can satisfy.
echo
echo "== X3: the verification gate proves each verifier before reading its opinion =="

python3 -I -B - "$L_TMP/publish.fence" >"$L_TMP/x3.report" 2>"$L_TMP/x3.err" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")


def is_comment(line):
    return line.lstrip().startswith("#")


code = [(i, l) for i, l in enumerate(lines) if not is_comment(l)]
capture = [i for i, l in code if "capture-bound-child" in l]
binding = [i for i, l in code if re.search(r"jq -er \.binding", l)]
edge = [i for i, l in code if re.search(r"jq -er \.edge", l)]
validate = [
    i for i, l in code
    if "uberdev_child_validate_finding_verifier_result" in l
]
print("capture=%d" % len(capture))
print("binding=%d" % len(binding))
print("edge=%d" % len(edge))
print("validate=%d" % len(validate))
print("capture_before_validate=%s" % (
    "yes" if capture and validate and min(capture) < min(validate) else "no"))

# The failure branch attached to the capture. Its shape is the whole point: a
# malformed CHILD must be recorded and stepped over, while a malformed LEDGER
# ROW (a controller bug) keeps the surrounding `|| return 74` idiom. So the
# branch must END in `continue` — a branch whose terminal statement returns
# would abort a whole review because one verifier mis-published.
branch = []
if capture:
    start = min(capture)
    depth_end = None
    for j in range(start, len(lines)):
        stripped = lines[j].strip()
        if j > start and stripped in ("fi", "}", "};"):
            depth_end = j
            break
    if depth_end is not None:
        branch = [l for l in lines[start + 1:depth_end]
                  if l.strip() and not is_comment(l)]
tail = branch[-1].strip() if branch else ""
print("branch_lines=%d" % len(branch))
print("branch_records_unavailable=%s" % (
    "yes" if any("verifier-unavailable" in l for l in branch) else "no"))
print("branch_tail=%s" % tail)
# The fence must still be able to SAY a verifier was unusable at all.
print("fence_has_unavailable=%d" % sum(
    1 for _, l in code if "verifier-unavailable" in l))
PY
X3_RC=$?
X3_BAD=""
[ "$X3_RC" = 0 ] || X3_BAD="$X3_BAD scanner-rc=$X3_RC"
[ "$(l_field "$L_TMP/x3.report" capture)" -ge 1 ] 2>/dev/null || X3_BAD="$X3_BAD never-captures"
[ "$(l_field "$L_TMP/x3.report" binding)" -ge 1 ] 2>/dev/null || X3_BAD="$X3_BAD never-reads-binding"
[ "$(l_field "$L_TMP/x3.report" edge)" -ge 1 ] 2>/dev/null || X3_BAD="$X3_BAD hardcodes-the-edge-id"
[ "$(l_field "$L_TMP/x3.report" capture_before_validate)" = yes ] \
  || X3_BAD="$X3_BAD reads-the-opinion-before-proving-the-child"
if [ -z "$X3_BAD" ]; then
  pass "X3a the publish fence captures each verifier against its minted binding BEFORE validating the opinion"
else
  fail "X3a the minted verify binding is still never consumed:$X3_BAD"
fi

X3B_BAD=""
[ "$(l_field "$L_TMP/x3.report" fence_has_unavailable)" -ge 1 ] 2>/dev/null \
  || X3B_BAD="$X3B_BAD no-unavailable-reason"
[ "$(l_field "$L_TMP/x3.report" branch_records_unavailable)" = yes ] \
  || X3B_BAD="$X3B_BAD capture-failure-records-nothing"
[ "$(l_field "$L_TMP/x3.report" branch_tail)" = continue ] \
  || X3B_BAD="$X3B_BAD branch-tail='$(l_field "$L_TMP/x3.report" branch_tail)'"
if [ -z "$X3B_BAD" ]; then
  pass "X3b an unprovable verifier is recorded verifier-unavailable and stepped over, never aborting the review"
else
  fail "X3b the capture-failure branch does not degrade:$X3B_BAD"
fi

# Lock: the fix must reuse `verifier-unavailable`, which already means "no
# usable child opinion exists" and already lands SURVIVES. A new reason string
# would be a new vocabulary member the sidecar's schema refuses.
python3 -I -B - "$CONTRACT" >"$L_TMP/x3c.report" 2>/dev/null <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for name in ("VERIFICATION_CHILD_REASONS", "VERIFICATION_CONTROLLER_REASONS"):
    match = re.search(name + r"\s*=\s*\{(.*?)\}", text, re.S)
    members = re.findall(r'"([a-z-]+)"', match.group(1)) if match else []
    print("%s=%d" % (name, len(members)))
    print("%s_has_unavailable=%s" % (
        name, "yes" if "verifier-unavailable" in members else "no"))
PY
if [ "$(l_field "$L_TMP/x3c.report" VERIFICATION_CHILD_REASONS)" = 5 ] \
   && [ "$(l_field "$L_TMP/x3c.report" VERIFICATION_CONTROLLER_REASONS)" = 3 ] \
   && [ "$(l_field "$L_TMP/x3c.report" VERIFICATION_CONTROLLER_REASONS_has_unavailable)" = yes ]; then
  pass "X3c the verification reason vocabulary is unchanged (5 child + 3 controller), and verifier-unavailable is still a controller reason"
else
  fail "X3c the verification reason vocabulary moved: $(tr '\n' ' ' <"$L_TMP/x3c.report")"
fi

# ---------------------------------------------------------------------------
# X4 — the impossible cross-stage note carrier is GONE (#514 item 1)
# ---------------------------------------------------------------------------
# THE DEFECT: an envelope key was read into a scalar that no producer anywhere
# in the repo ever emitted, an in-call array collected notes that `finalize()`
# never returned, and the branch that would have embedded either one was
# therefore unreachable. The whole injection-hardening path around it — an
# envelope wrapper, a close-tag neutraliser, a per-note cell() — looked live and
# never executed once.
#
# It is DELETED rather than wired because no compliant producer can exist: a
# Workflow script has no filesystem verb, every fence is a fresh shell (#427),
# and no controller fence parses a Workflow return at all. The only remaining
# carrier would be an orchestrator copying untrusted agent text out of a return
# into a later fence's shell word — an LLM-composed handoff, which DR-2 forbids.
#
# Each literal is ASSEMBLED AT RUNTIME (the G14c idiom) so the fixture cannot
# match itself and the lock cannot decay into a row that always passes.
echo
echo "== X4: the severed cross-stage note carrier leaves no phantom names =="

# An ARRAY, not a space-joined scalar: this repository is routinely checked out
# under a path containing a space, and an unquoted scalar would split it into
# nonexistent roots — `grep -r` would then find nothing and every X4 row would
# pass on any tree at all. X4d is what catches that, but the array is what
# prevents it.
X4_ROOTS=("$REPO_ROOT/plugins" "$REPO_ROOT/docs" "$REPO_ROOT/tools" "$REPO_ROOT/tests")
x4_absent() {  # TOKEN LABEL
  if grep -rq -- "$1" "${X4_ROOTS[@]}" 2>/dev/null; then
    fail "X4 $2: the name '$1' is still spelled somewhere under plugins/ docs/ tools/ tests/"
  else
    pass "X4 $2"
  fi
}
X4_CN_TOKEN="child""Notes"
x4_absent "$X4_CN_TOKEN" "a the envelope key with no producer is gone from the script, the skill doc and the command files"
X4_ENV_TOKEN="review-fleet-""child-notes"
x4_absent "$X4_ENV_TOKEN" "b the envelope source tag that no prompt could ever emit is gone"
# Scoped to review-fleet ONLY: both names are live and correct in
# skills/uberthink-pipeline/workflow.js and skills/testers-pipeline/workflow.js,
# and the SHARED block is documented in skills/writing-skills/SKILL.md. What is
# wrong is carrying a copy in a script whose prompts embed no agent-returned
# content — that is the "looks hardened, never executes" shape itself.
X4_FLEET="$REPO_ROOT/plugins/uberdev/skills/review-fleet"
X4_WRAP_TOKEN="env""Wrap"
X4_CELL_TOKEN="env""Cell"
if grep -rq -e "$X4_WRAP_TOKEN" -e "$X4_CELL_TOKEN" "$X4_FLEET" 2>/dev/null; then
  fail "X4c review-fleet still carries an untrusted-input envelope helper that nothing in its prompts uses"
else
  pass "X4c review-fleet carries no envelope helper, because no prompt of its embeds agent-returned content"
fi
# Anti-vacuity: the SAME grep over the SAME roots must find a token that is
# certainly present, or X4a/X4b prove only that the roots or the tool moved.
if grep -rq -- "boundChildProtocol" "${X4_ROOTS[@]}" 2>/dev/null; then
  pass "X4d anti-vacuity: the same recursive grep over the same roots does find a known-present name"
else
  fail "X4d the X4 greps find nothing at all — the roots or the tool moved and X4a/X4b are vacuous"
fi

# ---------------------------------------------------------------------------
# X5 — `note` finally has a reader (#514 item 1)
# ---------------------------------------------------------------------------
# All seven reviewers, all three lenses, the fixer and the finding-verifier are
# asked for a `note`, eight schemas declare it, and the one thing that consumed
# it was the dead carrier above. Deleting the carrier without giving `note` a
# reader would leave every one of those prompts asking for a field nothing
# anywhere reads — the same defect with the hardening removed. The reader is the
# observability channel that already exists: the single structured
# `WORKFLOW_RESULT` line.
#
# The count of prompt builders is deliberately NOT restated as a number here.
# It was stated once as "nine", went stale the moment the verifier prompt
# landed, and then read as a dated counterfactual to its author and as a live
# count to everyone after. The assertion this block actually makes — eight
# schemas declare the field — is the one X5e checks, and it is checked rather
# than asserted in prose.
#
# It is CLAMPED, not passed through: the note is untrusted agent text derived
# from PR-author-controlled diff bytes. It cannot split the log line —
# JSON.stringify escapes every control character — but an unbounded or
# control-char-bearing note can corrupt a terminal and bloat the one structured
# line every fixture in this file asserts on.
echo
echo "== X5: the note a child returns is reported, bounded and control-char-free =="

X5A_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n '{status:"COMPLETE",
  resultPath:"", statusPath:"", note:"SENTINELNOTE-514"}')")"
[ "$(jq -r '[.result.children[] | select(.note == "SENTINELNOTE-514")] | length' <<<"$X5A_OUT")" = 7 ] \
  && pass "X5a a child's note reaches the structured return" \
  || fail "X5a the note a child returned is discarded: $(jq -c '.result.children[0]' <<<"$X5A_OUT")"

X5_LONG="$(printf 'x%.0s' $(seq 5000))"
X5B_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n --arg n "$X5_LONG" '{status:"COMPLETE",
  resultPath:"", statusPath:"", note:$n}')")"
[ "$(jq -r '.result.children[0].note | length' <<<"$X5B_OUT")" = 200 ] \
  && pass "X5b a 5000-character note is clamped to 200 before it reaches the log line" \
  || fail "X5b the note is unbounded (length $(jq -r '.result.children[0].note | length' <<<"$X5B_OUT")); one child can bloat the structured line every fixture reads"

# Built in the fixture rather than written as a literal byte, so the file stays
# grep-able and editor-safe. C0 includes \n and \r, which is exactly why the
# removal makes a newline-collapsing envelope unnecessary.
#
# The note is deliberately LONGER than the 200-character bound and front-loaded
# with control characters, because that is the only shape that can tell the two
# orderings apart. 150 control characters followed by 120 real ones survive as
# 120 real characters when removal runs FIRST, and as only 50 when truncation
# runs first and the padding has already spent the budget. A ten-character note
# is a no-op for truncation and passes identically either way — it cannot prove
# the ordering this row's message names, which is the case the source comment
# beside clampNote calls out.
X5C_CTRL="$(printf '\001%.0s' $(seq 150))"
X5C_REAL="$(printf 'p%.0s' $(seq 120))"
X5C_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n --arg n "${X5C_CTRL}${X5C_REAL}" '{status:"COMPLETE",
  resultPath:"", statusPath:"", note:$n}')")"
X5C_NOTE="$(jq -r '.result.children[0].note' <<<"$X5C_OUT")"
X5C_ESCAPED="$(jq -r '.result | tostring | contains("\\u0001")' <<<"$X5C_OUT")"
if [ "$X5C_NOTE" = "$X5C_REAL" ] && [ "$X5C_ESCAPED" = false ]; then
  pass "X5c control characters are REMOVED from the note, and removal happens BEFORE truncation (150 control + 120 real characters leave 120 real ones, not the 50 the other order would leave)"
else
  fail "X5c control-character removal or its ordering is wrong (surviving note is ${#X5C_NOTE} chars, want ${#X5C_REAL}; escaped-in-result=$X5C_ESCAPED)"
fi

# Anti-vacuity: with the DEFAULT return the key must be PRESENT and empty, not
# absent — `has()` and not `// ""`, because a missing key defaults to "" too and
# would make X5a look like it matched prose.
X5D_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' "$(jq -n '{status:"COMPLETE",
  resultPath:"", statusPath:""}')")"
if [ "$(jq -r '.result.children[0] | has("note")' <<<"$X5D_OUT")" = true ] \
   && [ "$(jq -r '.result.children[0].note' <<<"$X5D_OUT")" = "" ]; then
  pass "X5d the note key is uniformly present, and empty when the child returned none"
else
  fail "X5d children[] has no note key at all — X5a would match nothing rather than assert something"
fi
# The fix removes the CARRIER, never the field: `note` is the only channel a
# BLOCKED child has for saying why, and dropping it from schemas that declare
# additionalProperties:false while the prompts still ask for it would trip the
# structured-output retry instead of failing loudly.
X5E="$(grep -c 'note: { type: "string" }' "$WORKFLOW" || true)"
[ "$X5E" = 8 ] \
  && pass "X5e all eight schemas still declare note (the carrier went, the field stayed)" \
  || fail "X5e $X5E of 8 schemas declare note; a prompt still asking for one would trip the structured-output retry"

# ---------------------------------------------------------------------------
# X6 — the CI classifier's CLAIM is reported beside the proof (#514 item 3)
# ---------------------------------------------------------------------------
# THE DEFECT: `S.ciClassify.failureClass` had exactly three sites repo-wide —
# the comment justifying it, the schema property and the prompt request — and
# zero reads. The comment stated its whole purpose: the claim is carried "so the
# log line and the audit trail can say what the child claimed, and so a
# disagreement between the claim and the proof is visible." No log line printed
# it, no audit event recorded it, recordChild did not copy it. The routing
# scalar comes from `validate-ci-classification` controller-side, so this was
# never a routing bug — but the disagreement-detection mechanism the comment
# promised did not exist, on the one Phase 3 path that routes a mutating arm.
#
# X6e is the row that keeps the fix honest: reporting the claim must change the
# REPORT and change no control flow.
echo
echo "== X6: the CI classifier's claim is reported, membership-tested, and routes nothing =="

x6_run() {  # FAILURE_CLASS_JSON -> harness output
  stage_run_with_return ci-classify "$W_NONCE1" "$W_CI_COMMON" \
    "$(jq -n --argjson fc "$1" '{status:"CLASSIFIED", resultPath:"", statusPath:"",
       failureClass:$fc}')"
}
x6_claim() {  # HARNESS_OUT -> the claimed class the audit event recorded
  jq -r '[.result.auditEvents[] | select(.event == "ci_classify_child_claim")]
         | if length == 1 then .[0].claimedFailureClass else "EVENTS=\(length)" end' <<<"$1"
}

X6A_OUT="$(x6_run '"code_bug"')"
[ "$(x6_claim "$X6A_OUT")" = code_bug ] \
  && pass "X6a a recognised claim lands in exactly one ci_classify_child_claim audit event" \
  || fail "X6a the child's claimed failure class is discarded: $(x6_claim "$X6A_OUT")"
[ "$(jq -r '[.logs[] | select(contains("code_bug"))] | length' <<<"$X6A_OUT")" -ge 1 ] 2>/dev/null \
  && pass "X6b the claim is named on the run's log line, where a claim-vs-proof disagreement is readable" \
  || fail "X6b no log line names the claim; the disagreement the schema comment promises stays invisible"

X6C_OUT="$(x6_run '"nope_not_a_class"')"
if [ "$(x6_claim "$X6C_OUT")" = "(unrecognised)" ] \
   && [ "$(jq -r '(.result | tostring) + (.logs | tostring) | contains("nope_not_a_class")' <<<"$X6C_OUT")" = false ]; then
  pass "X6c an off-enum claim is reported as (unrecognised) and its raw bytes are never echoed"
else
  fail "X6c an arbitrary child-chosen string reached the audit row or the log: $(x6_claim "$X6C_OUT")"
fi

# `""` is a LEGITIMATE value, not a malformed one: the schema enum admits it and
# the prompt literally offers it as "the class you chose, or \"\"". Stamping a
# declined classification `(unrecognised)` would put a lie in the audit row.
X6D_OUT="$(x6_run '""')"
[ "$(x6_claim "$X6D_OUT")" = "(none)" ] \
  && pass "X6d a declined classification is reported as (none), not as (unrecognised)" \
  || fail "X6d an empty failureClass is mislabelled '$(x6_claim "$X6D_OUT")'; the enum admits \"\" on purpose"

X6_NOROUTE=""
for x6_out in "$X6A_OUT" "$X6C_OUT" "$X6D_OUT"; do
  [ "$(jq -r '.result.abortReason' <<<"$x6_out")" = "" ] || X6_NOROUTE="$X6_NOROUTE aborted"
  [ "$(jq -r '.result.dispatched' <<<"$x6_out")" = 1 ] || X6_NOROUTE="$X6_NOROUTE dispatch-changed"
done
if [ -z "$X6_NOROUTE" ]; then
  pass "X6e the claim changed the report and changed no control flow (no abort, no dispatch change)"
else
  fail "X6e the child's claim now steers the run:$X6_NOROUTE"
fi

# The read is SINGLE and it is an ASSIGNMENT, never a condition.
# commands/review-pr.md names ci-classify -> ci-fix a PROOF POINT: reading the
# class off the child's structured return "would delete all four checks and
# route the mutating arm on an LLM's word." Three code sites — the schema
# property, the prompt request, and the one read — plus comment prose.
python3 -I -B - "$WORKFLOW" >"$L_TMP/x6f.report" 2>/dev/null <<'PY'
import re
import sys

# Statement-level CONTROL FLOW. A ternary that picks between two STRINGS is
# not control flow — the membership test is exactly that, and it is the point.
# What must not exist is a statement whose execution depends on the claim.
FLOW = re.compile(r"(^\s*(if|while|switch|for)\s*\()|(\breturn\b)")
CLAIM_IDENT = re.compile(r"\b(failureClass|claim|claimedRaw|claimed)\b")
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
hits = [l for l in lines if "failureClass" in l]
comments = [l for l in hits if l.lstrip().startswith("//")]
code = [l for l in hits if not l.lstrip().startswith("//")]
# A read is a property access on the child's return; the schema property and
# the prompt request are neither.
reads = [l for l in code if re.search(r"\.failureClass\b", l)]
flow = [l for l in lines
        if not l.lstrip().startswith("//")
        and CLAIM_IDENT.search(l) and FLOW.search(l)]
print("code=%d" % len(code))
print("comment=%d" % len(comments))
print("reads=%d" % len(reads))
print("claim_controls_flow=%d" % len(flow))
PY
X6F_BAD=""
[ "$(l_field "$L_TMP/x6f.report" code)" = 3 ] 2>/dev/null \
  || X6F_BAD="$X6F_BAD code-sites=$(l_field "$L_TMP/x6f.report" code)"
[ "$(l_field "$L_TMP/x6f.report" reads)" = 1 ] 2>/dev/null \
  || X6F_BAD="$X6F_BAD reads=$(l_field "$L_TMP/x6f.report" reads)"
[ "$(l_field "$L_TMP/x6f.report" claim_controls_flow)" = 0 ] 2>/dev/null \
  || X6F_BAD="$X6F_BAD flow=$(l_field "$L_TMP/x6f.report" claim_controls_flow)"
[ "$(l_field "$L_TMP/x6f.report" comment)" -ge 1 ] 2>/dev/null \
  || X6F_BAD="$X6F_BAD unjustified"
if [ -z "$X6F_BAD" ]; then
  pass "X6f failureClass has one read, it is an assignment, and no statement's execution depends on the claim"
else
  fail "X6f the mutating arm may now route on the child's word:$X6F_BAD"
fi

# ---------------------------------------------------------------------------
# X7 — SKILL.md and the script agree about what a run RETURNS and RUNS (#514)
# ---------------------------------------------------------------------------
# The half of #514 that no test could previously see: three code contracts drifted
# from the doc that describes them, and the doc kept describing the mechanism as
# working. X7a is the comparator that stops the return shape drifting again —
# not a grep for a word, but the two key lists placed side by side.
echo
echo "== X7: the skill doc and the script agree (return shape, fallback roster) =="

python3 -I -B - "$SKILL" "$WORKFLOW" >"$L_TMP/x7.report" 2>"$L_TMP/x7.err" <<'PY'
import re
import sys

skill = open(sys.argv[1], encoding="utf-8").read()
script = open(sys.argv[2], encoding="utf-8").read()

# The documented children[] element, out of the fenced return-shape block.
doc = re.search(r"children:\s*\[\s*\{(.*?)\}\s*\]", skill, re.S)
doc_keys = sorted(set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", doc.group(1)))) if doc else []

# The children[] row now has ONE constructor, so this comparator reads the
# constructor's base literal instead of guessing which push carries the full
# shape. That guess was the hole: taking the LARGEST of three independent
# literals meant a key added to one site and missed on the other two still
# matched the doc — which is exactly the drift #514 had to repair by hand.
builder = re.search(r"function childRow\(entry, over\) \{\s*const row = \{(.*?)\n  \};",
                    script, re.S)
best = re.findall(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", builder.group(1)) if builder else []
print("doc_keys=%s" % ",".join(doc_keys))
print("code_keys=%s" % ",".join(sorted(set(best))))
# And there must be NO surviving object literal on the push path: a second
# construction site re-opens the door this builder closes, and the comparator
# above would go on comparing only the builder while the literal drifted.
print("literal_pushes=%d" % len(re.findall(r"children\.push\(\{", script)))

# The No-Workflow fallback must enumerate every stage the script can run, or a
# runtime without the Workflow tool silently skips one. `verify` is the gate
# that decides whether a blocker survives.
section = re.search(r"## No-Workflow fallback(.*?)(?=\n## |\Z)", skill, re.S)
body = section.group(1) if section else ""
print("fallback_names_verify=%s" % ("yes" if re.search(r"\bverify\b", body) else "no"))
PY
X7_RC=$?
X7_DOC="$(l_field "$L_TMP/x7.report" doc_keys)"
X7_CODE="$(l_field "$L_TMP/x7.report" code_keys)"
if [ "$X7_RC" = 0 ] && [ -n "$X7_DOC" ] && [ "$X7_DOC" = "$X7_CODE" ]; then
  pass "X7a SKILL.md's documented children[] shape equals the one childRow() actually builds"
else
  fail "X7a the documented return shape drifted from the code: doc=[$X7_DOC] code=[$X7_CODE]"
fi
[ "$(l_field "$L_TMP/x7.report" literal_pushes)" = 0 ] \
  && pass "X7a2 every children[] row comes from the ONE constructor — no push carries its own object literal to drift" \
  || fail "X7a2 $(l_field "$L_TMP/x7.report" literal_pushes) children.push({...}) literal(s) survive beside childRow(); X7a compares only the builder, so those sites are unguarded"
[ "$(l_field "$L_TMP/x7.report" fallback_names_verify)" = yes ] \
  && pass "X7b the No-Workflow fallback accounts for the verify stage" \
  || fail "X7b the No-Workflow fallback omits verify entirely; a non-Workflow runtime skips the precision gate in silence"

# ---------------------------------------------------------------------------
# X8 — the mid-fanout budget guard, which stops a HALF-RUN review reading as a
# clean one (#514)
# ---------------------------------------------------------------------------
# THE DEFECT THIS GUARD EXISTS FOR: a partial aggregate is indistinguishable
# downstream from a zero-finding review, and the trust signal /goal merges on is
# drawn from it. The ceiling gate refuses to START such a run; the budget must
# not be a second door into the same state, so every undispatched roster entry is
# recorded BLOCKED and abortReason is set.
#
# Nothing exercised it. This suite never set a budget at all (goal, scan-fleet
# and testers suites all do, so the fixture technique was already in the repo),
# the budget_exhausted event name appeared in no test, and abortReason was
# asserted for five other reasons but never this one. X7a cannot cover the rows
# it emits either: that comparator reads the ONE constructor, and both of these
# arms are deliberately the constructor's defaults.
echo
echo "== X8: a fanout the budget cut short reports itself, with the full row shape =="

# fanoutCap 1 makes each wave one child, so a budget of 1 is exhausted the moment
# the first reviewer returns — 1 dispatched, 6 never dispatched, out of a roster
# of 7.
X8_OUT="$(stage_run_with_budget review "$W_REVIEW_NONCES" '{"fanoutCap":1}' 1)"
X8_JQ() { jq -r "$1" <<<"$X8_OUT"; }

[ "$(X8_JQ '.threw // "null"')" = null ] \
  && pass "X8a a budget cut short mid-fanout is a REPORT, never a throw" \
  || fail "X8a the budget path threw: $(X8_JQ '.threw')"
[ "$(X8_JQ '.dispatched')" = 1 ] \
  && pass "X8b exactly one child was dispatched before the budget ran out" \
  || fail "X8b expected 1 dispatched child, got $(X8_JQ '.dispatched') — the run did not stop where this row assumes"
[ "$(X8_JQ '.result.abortReason')" = budget_exhausted ] \
  && pass "X8c abortReason names the budget — the caller's documented test for a truncated fanout" \
  || fail "X8c abortReason is '$(X8_JQ '.result.abortReason')', so a half-run review reads as a completed one"
# The event names the phase by its DISPLAY name, the same string dispatchRoster
# was called with — asserted literally so a renamed phase cannot quietly detach
# the event from the fanout it describes.
[ "$(X8_JQ '[.result.auditEvents[] | select(.event == "budget_exhausted" and .phase == "Phase 1 — Review fanout")] | length')" = 1 ] \
  && pass "X8d the budget_exhausted audit event fires once, naming the phase it cut" \
  || fail "X8d no budget_exhausted audit event for the review fanout — the second of the two independent signals is missing: $(X8_JQ '[.result.auditEvents[] | select(.event == "budget_exhausted")] | tojson')"
[ "$(X8_JQ '.result.children | length')" = 7 ] \
  && pass "X8e the roster is made SELF-DESCRIBING, not short: all 7 entries are still reported" \
  || fail "X8e only $(X8_JQ '.result.children | length') of 7 roster entries reached children[] — a truncated roster is exactly what reads as a completed fanout"
[ "$(X8_JQ '[.result.children[] | select(.reason == "never dispatched — token budget exhausted mid-fanout")] | length')" = 6 ] \
  && pass "X8f every undispatched slug is recorded BLOCKED with the reason that says so" \
  || fail "X8f $(X8_JQ '[.result.children[] | select(.reason == "never dispatched — token budget exhausted mid-fanout")] | length') of 6 undispatched entries carry the never-dispatched reason"
# THE ROW SHAPE, which is what this iteration rewrote and what nothing pinned:
# the never-dispatched entry must carry EVERY member of the published contract,
# in the absent-value spellings a consumer can read without guessing.
X8_SHAPE='[.result.children[] | select(.reason == "never dispatched — token budget exhausted mid-fanout")
  | select(.status == "BLOCKED" and .verdict == "" and .resultPath == "" and .statusPath == ""
      and .findingCount == null and .blockerCount == null and .note == ""
      and (.edgeId | length) > 0 and (.slug | length) > 0
      and (keys | length) == 10)] | length'
[ "$(X8_JQ "$X8_SHAPE")" = 6 ] \
  && pass "X8g ...with all 10 members present in the declared absent-value spellings, so an absent field is never mistaken for an empty one" \
  || fail "X8g only $(X8_JQ "$X8_SHAPE") of 6 never-dispatched rows carry the full 10-member shape: $(X8_JQ '[.result.children[] | select(.reason | startswith("never dispatched"))][0] // {} | tojson')"

# The OTHER arm that shares the constructor and had no fixture either: a child
# that returned null. Same shape, different reason.
X8N_OUT="$(stage_run_with_return review "$W_REVIEW_NONCES" '{}' 'null')"
X8N_SHAPE='[.result.children[] | select(.reason == "agent returned null")
  | select(.status == "BLOCKED" and .verdict == "" and .resultPath == "" and .statusPath == ""
      and .findingCount == null and .blockerCount == null and .note == ""
      and (keys | length) == 10)] | length'
[ "$(jq -r "$X8N_SHAPE" <<<"$X8N_OUT")" = 7 ] \
  && pass "X8h a reviewer returning null records the SAME 10-member shape, with its own reason" \
  || fail "X8h the null-return row shape drifted from the never-dispatched one: $(jq -c '.result.children[0] // {}' <<<"$X8N_OUT")"
[ "$(jq -r '.result.nullsByPhase["Phase 1 — Review fanout"] // 0' <<<"$X8N_OUT")" = 7 ] \
  && pass "X8i ...and every null return is counted under the review fanout in nullsByPhase" \
  || fail "X8i null returns are not counted: $(jq -c '.result.nullsByPhase' <<<"$X8N_OUT")"

# ANTI-VACUITY for the whole block: the identical run with NO budget must
# dispatch the full roster and set no abort reason, or X8c-X8g would be passing
# against a script that truncates every fanout.
X8Z_OUT="$(stage_run_with_budget review "$W_REVIEW_NONCES" '{"fanoutCap":1}' 0)"
if [ "$(jq -r '.dispatched' <<<"$X8Z_OUT")" = 7 ] \
   && [ -z "$(jq -r '.result.abortReason' <<<"$X8Z_OUT")" ]; then
  pass "X8z ANTI-VACUITY: the same wave size with no budget dispatches all 7 and aborts for nothing"
else
  fail "X8z the no-budget control did not run clean: $(jq -c '{dispatched,abort:.result.abortReason}' <<<"$X8Z_OUT")"
fi

# ---------------------------------------------------------------------------
# The fixture every remaining row runs against: a REAL /review-pr run on disk
# (real git repository, real uberdev_command_workspace_prepare, real descriptor
# and reservation markers), built exactly as section B builds it.
# ---------------------------------------------------------------------------
L_FIXTURE="$L_TMP/run"
mkdir -p "$L_FIXTURE"
L_RUN_ID=20260101-000000-facade
L_RUN_PR=4271
L_FIXTURE_OUT="$(bash "$REPO_ROOT/tests/_lib_review_run_fixture.sh" --make-run \
  "$L_FIXTURE" "$REPO_ROOT/plugins/uberdev" "$L_RUN_PR" "$L_RUN_ID" 2>"$L_TMP/fixture.err")" || L_FIXTURE_OUT=''
L_REPO="$(printf '%s\n' "$L_FIXTURE_OUT" | sed -n 1p)"
L_RESEARCH_DIR="$(printf '%s\n' "$L_FIXTURE_OUT" | sed -n 3p)"
L_RUN_DIR="$(printf '%s\n' "$L_FIXTURE_OUT" | sed -n 4p)"

# The head this fixture run stands on, recorded exactly the way the Phase 1
# scope fence records it (#479) — through the typed writer, before EITHER entry
# path is probed. Position is deliberate: L5 compares the two environments as
# they are captured below, so a carrier absent from the fixture is a carrier L5
# cannot see, and L7 needs a record that predates the shells it probes from.
L7_SEED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
L7_FIXED=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if [ -z "$L_RESEARCH_DIR" ] || ! env -i PATH="$PATH" HOME="${HOME:-$TMP}" bash -c \
     '. "$1"; review_fleet_write_reviewed_head "$2" "$3"' \
     _ "$ARGS_LIB" "$L_RESEARCH_DIR/reviewed-head.txt" "$L7_SEED" 2>"$L_TMP/l7.write.err"; then
  L7_SEED=''
fi

# l_probe SEED_FILE CWD SNIPPET — rehydrate in a shell that inherited NOTHING
# but SEED_FILE, then run SNIPPET. Output in $L_PROBE_OUT, rc in $L_PROBE_RC.
# The seed is a FILE of `NAME=value` lines rather than `env -i NAME=value ...`
# so a value carrying a space cannot be re-split on its way in.
l_probe() {
  L_PROBE_OUT="$(env -i PATH="$PATH" HOME="${HOME:-$TMP}" bash -c '
    while IFS= read -r assignment; do
      [ -n "$assignment" ] || continue
      export "$assignment"
    done <"$2"
    cd "$3" || exit 9
    . "$1" || exit 9
    review_fleet_rehydrate || exit 9
    eval "$4"' _ "$ARGS_LIB" "$1" "$2" "$3" 2>"$L_TMP/probe.err")"
  L_PROBE_RC=$?
}

# The RESOLVED path: nothing but a run id and a plugin root, from inside the
# repository, so every carrier comes off the descriptor.
{
  printf 'RUN_ID=%s\n' "$L_RUN_ID"
  printf 'UBERDEV_REVIEW_PLUGIN_ROOT=%s\n' "$REPO_ROOT/plugins/uberdev"
} >"$L_TMP/seed-resolved.env"
l_probe "$L_TMP/seed-resolved.env" "$L_REPO" env
L_RESOLVED_ENV="$L_PROBE_OUT"
L_RESOLVED_RC="$L_PROBE_RC"
printf '%s\n' "$L_RESOLVED_ENV" >"$L_TMP/resolved.env"

# The FAST path needs the eleven carriers already bound. They are taken from
# what the resolved path just produced — the second entry into this function
# must see what the first one published — but BY NAME, never by replaying the
# resolved environment wholesale: replaying it would carry the very
# present-but-empty export L5 exists to detect straight into the comparison.
L_FAST_SEED_NAMES='RUN_ID WORKTREE_ROOT RESEARCH_DIR_ABS MARKER_DIR DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH UBERDEV_COMMAND_WORKSPACE_JSON UBERDEV_CARRIER_RUN_DIR UBERDEV_REVIEW_PLUGIN_ROOT'
awk -v names="$L_FAST_SEED_NAMES" '
  BEGIN { count = split(names, wanted, " "); for (i = 1; i <= count; i++) keep[wanted[i]] = 1 }
  { split($0, parts, "="); if (parts[1] in keep && length($0) > length(parts[1]) + 1) print }
' "$L_TMP/resolved.env" >"$L_TMP/seed-fast.env"
L_FAST_SEED_COUNT="$(grep -c '' "$L_TMP/seed-fast.env")"

# cwd `/`, deliberately: the fast path returns before it ever asks git for a
# toplevel, so a probe that silently fell through to the resolved path fails
# here instead of proving the wrong half.
l_probe "$L_TMP/seed-fast.env" / env
L_FAST_ENV="$L_PROBE_OUT"
L_FAST_RC="$L_PROBE_RC"
printf '%s\n' "$L_FAST_ENV" >"$L_TMP/fast.env"

if [ -n "$L_REPO" ] && [ -n "$L_RUN_DIR" ] && [ "$L_RESOLVED_RC" = 0 ] && [ "$L_FAST_RC" = 0 ] \
   && [ "$L_FAST_SEED_COUNT" = 13 ]; then
  pass "L0b the fixture run rehydrates on BOTH entry paths (resolved from the descriptor, fast from the 13 carriers it published)"
else
  fail "L0b the fixture run did not rehydrate: repo='$L_REPO' resolved_rc=$L_RESOLVED_RC fast_rc=$L_FAST_RC seeded=$L_FAST_SEED_COUNT/13"
fi

# ---------------------------------------------------------------------------
# L4 — PR identity is RECOVERED from the run, never read ambiently.
#
# THE DEFECT: both Step 6b.0 fences read `$PR_NUMBER` — one into the args
# envelope, one into the audit row that has to make a suppressed blocker
# traceable — and neither fence binds it. `clampInt(CFG.prNumber, …, 0)` in
# workflow.js turns the empty string into a verifier prompt that says "PR #0",
# and the audit row records `pr:""`. REVIEW_REPO_SLUG had the same shape and is
# NOT a carrier: it is a pure function of the checkout and is re-derived.
# ---------------------------------------------------------------------------
L4_BAD=""
# Behavioural: the recovery source is the run's OWN reservation marker, and it
# works on both entry paths.
l_probe "$L_TMP/seed-fast.env" / 'printf "%s" "${PR_NUMBER:-}"'
[ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = "$L_RUN_PR" ] \
  || L4_BAD="$L4_BAD fast-path-pr='$L_PROBE_OUT'(rc=$L_PROBE_RC)"
l_probe "$L_TMP/seed-resolved.env" "$L_REPO" 'printf "%s" "${PR_NUMBER:-}"'
[ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = "$L_RUN_PR" ] \
  || L4_BAD="$L4_BAD resolved-path-pr='$L_PROBE_OUT'(rc=$L_PROBE_RC)"
# ...and it INVENTS nothing. A marker that is absent or cannot say which PR this
# is leaves PR_NUMBER empty and rehydration still succeeds: this is a recovery
# source, not a guard, and the two fences that put the number in a prompt or an
# audit row refuse for themselves (asserted structurally below).
mkdir -p "$L_TMP/marker-absent" "$L_TMP/marker-string" "$L_TMP/marker-zero"
printf '{"pr":"%s"}\n' "$L_RUN_PR" >"$L_TMP/marker-string/pr-context.json"
printf '{"pr":0}\n' >"$L_TMP/marker-zero/pr-context.json"
for l4_marker in marker-absent marker-string marker-zero; do
  grep -v '^MARKER_DIR=' "$L_TMP/seed-fast.env" >"$L_TMP/seed-$l4_marker.env"
  printf 'MARKER_DIR=%s\n' "$L_TMP/$l4_marker" >>"$L_TMP/seed-$l4_marker.env"
  l_probe "$L_TMP/seed-$l4_marker.env" / 'printf "%s" "${PR_NUMBER:-}"'
  { [ "$L_PROBE_RC" = 0 ] && [ -z "$L_PROBE_OUT" ]; } \
    || L4_BAD="$L4_BAD $l4_marker-invented='$L_PROBE_OUT'(rc=$L_PROBE_RC)"
done
python3 -I -B - "$L_TMP/gate.fence" "$L_TMP/publish.fence" >"$L_TMP/l4.report" 2>"$L_TMP/l4.err" <<'PY'
import re
import sys

READ = re.compile(r"\$\{?PR_NUMBER\b")


def lines_of(path):
    return open(path, encoding="utf-8").read().split("\n")


def is_comment(line):
    return line.lstrip().startswith("#")


def pr_guard(body, label):
    case_at = next(
        (i for i, l in enumerate(body) if re.match(r'^\s*case\s+"\$\{PR_NUMBER:-\}"\s+in', l)), -1)
    esac_at = -1
    typed = "no"
    refuses = "no"
    if case_at >= 0:
        for index in range(case_at, len(body)):
            if re.match(r"^\s*esac\s*$", body[index]):
                esac_at = index
                break
        block = "\n".join(body[case_at:esac_at + 1 if esac_at >= 0 else len(body)])
        # A non-numeric OR empty value, and a refusal -- not a default.
        # Both arms are required: `*[!0-9]*` alone does NOT match the empty
        # string, so narrowing the case to it lets an unbound PR_NUMBER through
        # as "PR #0" in the verifier prompt and pr:"" in the audit row -- the
        # exact defect this row locks. Asserting only the non-numeric arm let
        # that narrowing pass 251/0.
        if "*[!0-9]*" in block and re.search(r"(^|\|)\s*(''|\"\")\s*\|", block, re.M):
            typed = "yes"
        if re.search(r"^\s*return\s+[0-9]+", block, re.M):
            refuses = "yes"
    reads = [
        i for i, l in enumerate(body)
        if not is_comment(l) and READ.search(l) and not (case_at <= i <= max(esac_at, case_at))
    ]
    print("%s_case=%d" % (label, case_at + 1))
    print("%s_typed=%s" % (label, typed))
    print("%s_refuses=%s" % (label, refuses))
    print("%s_uses=%d" % (label, len(reads)))
    # The guard must come BEFORE the fence puts the number anywhere.
    print("%s_guard_first=%s" % (
        label, "yes" if case_at >= 0 and reads and min(reads) > case_at else "no"))


gate = lines_of(sys.argv[1])
publish = lines_of(sys.argv[2])
pr_guard(gate, "gate")
pr_guard(publish, "publish")
# The slug: re-derived from the checkout, shape-checked, and only then emitted.
derive_at = next(
    (i for i, l in enumerate(gate)
     if re.search(r'REVIEW_REPO_SLUG="\$\{REVIEW_REPO_SLUG:-\$\(gh repo view', l)), -1)
shape_at = next(
    (i for i, l in enumerate(gate)
     if i > derive_at >= 0 and "REVIEW_REPO_SLUG" in l and "=~" in l and "/" in l), -1)
emit_at = next(
    (i for i, l in enumerate(gate) if re.search(r'repoSlug="\$REVIEW_REPO_SLUG"', l)), -1)
print("slug_derive=%d" % (derive_at + 1))
print("slug_shape=%d" % (shape_at + 1))
print("slug_emit=%d" % (emit_at + 1))
print("slug_ordered=%s" % (
    "yes" if 0 <= derive_at < shape_at < emit_at else "no"))
PY
L4_RC=$?
[ "$L4_RC" = 0 ] || L4_BAD="$L4_BAD scanner-rc=$L4_RC"
for l4_fence in gate publish; do
  [ "$(l_field "$L_TMP/l4.report" "${l4_fence}_typed")" = yes ] || L4_BAD="$L4_BAD $l4_fence-untyped"
  [ "$(l_field "$L_TMP/l4.report" "${l4_fence}_refuses")" = yes ] || L4_BAD="$L4_BAD $l4_fence-no-refusal"
  [ "$(l_field "$L_TMP/l4.report" "${l4_fence}_uses")" -ge 1 ] 2>/dev/null \
    || L4_BAD="$L4_BAD $l4_fence-never-uses-pr"
  [ "$(l_field "$L_TMP/l4.report" "${l4_fence}_guard_first")" = yes ] \
    || L4_BAD="$L4_BAD $l4_fence-uses-pr-before-guard"
done
[ "$(l_field "$L_TMP/l4.report" slug_ordered)" = yes ] || L4_BAD="$L4_BAD slug-derive/shape/emit-order"
if [ -z "$L4_BAD" ]; then
  pass "L4 both Step 6b.0 fences recover the PR from the run and re-derive the slug, refusing loudly instead of emitting PR #0"
else
  fail "L4 the verification gate still reads its identity ambiently:$L4_BAD"
fi

# ---------------------------------------------------------------------------
# L5 — the two rehydration entry paths hand children the SAME environment.
#
# THE DEFECT: the resolved path exported STANDALONE_SNAPSHOT_PATH and
# UBERDEV_CARRIER_RUN_DIR unconditionally while the fast path exported them only
# when non-empty. For a /review-pr run the descriptor's own standalone_snapshot
# is deliberately the empty string, so which fence a child was dispatched from
# decided whether it inherited an empty-but-present value it cannot distinguish
# from a real one, or nothing at all.
#
# The comparison is over NAMES and emptiness, not values: the two paths resolve
# the same run, so any name present on one side and absent on the other is the
# defect, and any name present-but-empty is it wearing the other face.
#
# The two head carriers (#479) joined the universe with their record: the fast
# path returned before the reviewed-head recovery ran, so once the scope fence
# started recording the seed, WHICH fence a child was dispatched from decided
# whether it inherited the head of the review at all.
# ---------------------------------------------------------------------------
L_CARRIER_UNIVERSE="UBERDEV_REVIEW_PLUGIN_ROOT CODE_FIXER_CONTRACT RUN_ID MARKER_DIR WORKTREE_ROOT RESEARCH_DIR_ABS UBERDEV_COMMAND_WORKSPACE_JSON DIFF_ARTIFACT_PATH CRITERIA_PATH COMMIT_RANGE_PATH PHASE1_DISPOSITION_PATH PHASE2_DISPOSITION_PATH AGG_PATH UBERDEV_CARRIER_RUN_DIR STANDALONE_SNAPSHOT_PATH PR_NUMBER VALIDATED_FIXER_HEAD_SHA REVIEWED_HEAD_SHA"
l_carrier_report() {  # ENV_FILE OUT
  awk -v names="$L_CARRIER_UNIVERSE" '
    BEGIN { count = split(names, wanted, " "); for (i = 1; i <= count; i++) keep[wanted[i]] = 1 }
    { split($0, parts, "="); name = parts[1]
      if (name in keep) print name ":" (length($0) > length(name) + 1 ? "set" : "EMPTY") }
  ' "$1" | LC_ALL=C sort >"$2"
}
l_carrier_report "$L_TMP/resolved.env" "$L_TMP/resolved.carriers"
l_carrier_report "$L_TMP/fast.env" "$L_TMP/fast.carriers"
L5_DIFF="$(diff "$L_TMP/resolved.carriers" "$L_TMP/fast.carriers" 2>&1 || true)"
L5_EMPTY="$(grep -h ':EMPTY$' "$L_TMP/resolved.carriers" "$L_TMP/fast.carriers" || true)"
L5_COUNT="$(grep -c '' "$L_TMP/resolved.carriers")"
if [ "$L_RESOLVED_RC" = 0 ] && [ "$L_FAST_RC" = 0 ] && [ "$L5_COUNT" -ge 15 ] 2>/dev/null \
   && [ -z "$L5_DIFF" ] && [ -z "$L5_EMPTY" ]; then
  pass "L5 both rehydration entry paths export the same $L5_COUNT carriers, none of them present-but-empty"
else
  fail "L5 the two entry paths hand children different environments (resolved carriers=$L5_COUNT) empty='$(printf '%s' "$L5_EMPTY" | tr '\n' ' ')' diff='$(printf '%s' "$L5_DIFF" | tr '\n' ' ')'"
fi

# ---------------------------------------------------------------------------
# L6 — `.claude/worktrees` is pruned BY PATH; `.claude` itself is not.
#
# THE DEFECT: the prune list carried `-name .claude`, which reaches the sibling
# worktree copies by deleting the whole tree. `.claude/` is a documented
# location for project rule documents, and the citation lens is told that a rule
# document not on the allowlist does not exist for this review — so it would
# cull the citation of a real convention as `citation-not-in-allowlist`, and a
# repo that keeps its rules there reads as a repo that wrote none down.
#
# The twin row in tests/convention-citation.test.sh (D4) has the sibling-worktree
# half and NO rule document directly under `.claude/`, which is exactly why it
# stayed green through the defect. This fixture carries both halves.
# ---------------------------------------------------------------------------
L6_ROOT="$L_TMP/rule-sources"
mkdir -p "$L6_ROOT/.claude/worktrees/sibling" "$L6_ROOT/.worktrees/other"
: >"$L6_ROOT/AGENTS.md"
: >"$L6_ROOT/.claude/CLAUDE.md"
: >"$L6_ROOT/.claude/worktrees/sibling/CLAUDE.md"
: >"$L6_ROOT/.claude/worktrees/sibling/AGENTS.md"
: >"$L6_ROOT/.worktrees/other/AGENTS.md"
L6_OUT="$(env -i PATH="$PATH" bash -c '. "$1"; uberdev_review_rule_sources "$2"' \
  _ "$ARGS_LIB" "$L6_ROOT" 2>"$L_TMP/l6.err")"
L6_RC=$?
# Exact stdout, in LC_ALL=C order. Not a substring check: "contains
# .claude/CLAUDE.md" would pass on a prune regression that also emitted both
# sibling-worktree copies of it.
L6_WANT='.claude/CLAUDE.md
AGENTS.md'
if [ "$L6_RC" = 0 ] && [ "$L6_OUT" = "$L6_WANT" ]; then
  pass "L6 a rule document under .claude/ stays on the allowlist while .claude/worktrees copies stay off it"
else
  fail "L6 the rule-source prune drops .claude/ wholesale or admits a sibling worktree (rc=$L6_RC): '$(printf '%s' "$L6_OUT" | tr '\n' '|')'"
fi

# ---------------------------------------------------------------------------
# L7 — the reviewed head is SEEDED on disk by the Phase 1 scope fence (#479).
#
# THE DEFECT: `review_track_validated_fixer_head` opens with
# `[ "$before" = "${VALIDATED_FIXER_HEAD_SHA:-}" ] || return 76`, and the only
# thing that ever bound the left-hand side of that comparison was
# `VALIDATED_FIXER_HEAD_SHA="$REVIEWED_HEAD_SHA"` in the Phase 1 scope fence — a
# dead shell by the time the promote fence runs. `review_fleet_rehydrate`
# recovers the value from reviewed-head.txt, but the ONLY writer of that file was
# the APPLIED arm of the tracker itself, so on a FIRST Phase 1 entry there was
# nothing to recover: the guard compared a real 40-hex head against the empty
# string, returned 76, and the controller normalised that to MUTATED_BLOCKED on a
# run whose fixer had done everything right. Same class as L1/L3 — this one just
# had no carrier at all, and its failure accuses the repository of unreviewed
# history instead of naming the missing record.
#
# Structural half: the fence that BINDS the head must also be the fence that
# writes it down, through the typed lib writer, inside the run-dir-bound branch,
# with the failure refused rather than shrugged off. Behavioural half: the record
# really is what carries the seed across a process boundary — a fresh `env -i`
# rehydrate recovers it, the tracker accepts a validated fixer commit once it is
# there, and reproduces the exact rc 76 once it is not.
# ---------------------------------------------------------------------------
L7_BAD=""
python3 -I -B - "$L_TMP/scope.fence" >"$L_TMP/l7.report" 2>"$L_TMP/l7.err" <<'PY'
import re
import sys

BIND = re.compile(r'^\s*VALIDATED_FIXER_HEAD_SHA="\$REVIEWED_HEAD_SHA"\s*$')
GUARD = re.compile(r'^\s*if\s+\[\s+-n\s+"\$REVIEW_BASE_RUN_DIR"\s+\]')
WRITE = re.compile(r'review_fleet_write_reviewed_head\s+"([^"]+)"\s+"([^"]+)"')


def is_comment(line):
    # Full-line comments only: this fence EXPLAINS every carrier it hands
    # forward, so counting prose that names the writer would let a fence that
    # only documents the seed pass for one that records it.
    return line.lstrip().startswith("#")


lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
bind_at = next((i for i, l in enumerate(lines) if BIND.match(l)), -1)
guard_at = next((i for i, l in enumerate(lines) if GUARD.match(l)), -1)
writes = [i for i, l in enumerate(lines) if not is_comment(l) and WRITE.search(l)]
write_at = writes[0] if len(writes) == 1 else -1
target = value = ""
refuses = "no"
if write_at >= 0:
    match = WRITE.search(lines[write_at])
    target, value = match.group(1), match.group(2)
    # The STATEMENT, not a fixed window: a `|| { ... }` arm runs to the closing
    # brace at the write's own indent, and a window that overran it would find
    # the NEXT carrier's refusal and call this one guarded.
    statement = [lines[write_at]]
    if lines[write_at].rstrip().endswith("{"):
        indent = re.match(r"\s*", lines[write_at]).group(0)
        close = re.compile(r"^" + re.escape(indent) + r"\}")
        for index in range(write_at + 1, len(lines)):
            statement.append(lines[index])
            if close.match(lines[index]):
                break
    blob = "\n".join(statement)
    if "||" in blob and re.search(r"^\s*return\s+[0-9]+", blob, re.M):
        refuses = "yes"
print("bind=%d" % (bind_at + 1))
print("guard=%d" % (guard_at + 1))
print("writes=%d" % len(writes))
print("write=%d" % (write_at + 1))
print("target=%s" % target)
print("value=%s" % value)
print("refuses=%s" % refuses)
# Bound, then guarded by the run dir, then written: a write above the bind
# records the PREVIOUS entry's head, and a write outside the branch aims at
# `/reviewed-head.txt` whenever the fence runs without a run dir.
print("ordered=%s" % ("yes" if 0 <= bind_at < guard_at < write_at else "no"))
PY
L7_RC=$?
[ "$L7_RC" = 0 ] || L7_BAD="$L7_BAD scanner-rc=$L7_RC"
[ "$(l_field "$L_TMP/l7.report" writes)" = 1 ] \
  || L7_BAD="$L7_BAD scope-fence-writers=$(l_field "$L_TMP/l7.report" writes)"
[ "$(l_field "$L_TMP/l7.report" ordered)" = yes ] \
  || L7_BAD="$L7_BAD bind/rundir-guard/write-order(bind=$(l_field "$L_TMP/l7.report" bind),guard=$(l_field "$L_TMP/l7.report" guard),write=$(l_field "$L_TMP/l7.report" write))"
case "$(l_field "$L_TMP/l7.report" target)" in
  '$REVIEW_BASE_RUN_DIR/reviewed-head.txt'|'$RESEARCH_DIR_ABS/reviewed-head.txt') ;;
  *) L7_BAD="$L7_BAD target='$(l_field "$L_TMP/l7.report" target)'" ;;
esac
[ "$(l_field "$L_TMP/l7.report" value)" = '$REVIEWED_HEAD_SHA' ] \
  || L7_BAD="$L7_BAD value='$(l_field "$L_TMP/l7.report" value)'"
[ "$(l_field "$L_TMP/l7.report" refuses)" = yes ] || L7_BAD="$L7_BAD silent-write-failure"

# Behavioural, under `env -i`: the record is what crosses the process boundary.
# The tracker's own stubs: the residue receipt and the ancestry/commit-count
# probes are separate contracts with their own rows, and a real repository here
# would make this row fail for their reasons instead of for the seed's.
L7_TRACK='python3(){ printf "{\"status\":\"clean\"}\n"; }
git(){
  [ "$3" = merge-base ] && [ "$4" = --is-ancestor ] && return 0
  [ "$3" = rev-list ] && [ "$4" = --count ] && printf "1\n" && return 0
  return 2
}
review_track_validated_fixer_head APPLIED '"$L7_SEED"' '"$L7_FIXED"' '"$L7_FIXED"' >/dev/null 2>&1
printf "%s" "$?"'
if [ -n "$L7_SEED" ]; then
  for l7_seed_env in seed-fast seed-resolved; do
    if [ "$l7_seed_env" = seed-fast ]; then l7_cwd=/; else l7_cwd="$L_REPO"; fi
    l_probe "$L_TMP/$l7_seed_env.env" "$l7_cwd" \
      'printf "%s|%s" "${VALIDATED_FIXER_HEAD_SHA:-}" "${REVIEWED_HEAD_SHA:-}"'
    [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = "$L7_SEED|$L7_SEED" ] \
      || L7_BAD="$L7_BAD $l7_seed_env-recovered='$L_PROBE_OUT'(rc=$L_PROBE_RC)"
  done
  # With the seed on file the promote path accepts the validated commit...
  l_probe "$L_TMP/seed-fast.env" / "$L7_TRACK"
  [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = 0 ] \
    || L7_BAD="$L7_BAD seeded-track-rc='$L_PROBE_OUT'(probe=$L_PROBE_RC)"
  # ...and advancing it is itself recorded, so the NEXT fence starts where this
  # one finished rather than back at the seed.
  [ "$(cat "$L_RESEARCH_DIR/reviewed-head.txt" 2>/dev/null)" = "$L7_FIXED" ] \
    || L7_BAD="$L7_BAD advance-not-recorded='$(cat "$L_RESEARCH_DIR/reviewed-head.txt" 2>/dev/null)'"
  # Absent, it is exactly the 76 the live run hit — never a silent pass.
  rm -f "$L_RESEARCH_DIR/reviewed-head.txt"
  l_probe "$L_TMP/seed-fast.env" / "$L7_TRACK"
  [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = 76 ] \
    || L7_BAD="$L7_BAD unseeded-track-rc='$L_PROBE_OUT'(probe=$L_PROBE_RC)"
  rm -f "$L_RESEARCH_DIR/reviewed-head.txt"
else
  L7_BAD="$L7_BAD seed-write-failed"
fi
if [ -z "$L7_BAD" ]; then
  pass "L7 the Phase 1 scope fence records the reviewed head it binds, so the promote fence recovers the seed instead of refusing 76"
else
  fail "L7 the reviewed-head seed never reaches the promote fence:$L7_BAD"
fi

# ---------------------------------------------------------------------------
# L8 — the PUBLISHED head and the VALIDATED head are two facts, not one.
#
# THE DEFECT: _review_fleet_bind_reviewed_head closed with
# `REVIEWED_HEAD_SHA="${REVIEWED_HEAD_SHA:-$VALIDATED_FIXER_HEAD_SHA}"`, and the
# APPLIED arm of review_track_validated_fixer_head advances reviewed-head.txt to
# the post-fix LOCAL head. Step 6a is a fresh shell, so it rehydrated
# REVIEWED_HEAD_SHA to that advanced value and handed it to
# review_publish_same_repo_pr_head as `expected_remote_head_sha` — a value the
# remote cannot hold, because nothing has pushed yet. The gate's
# `[ "$live_head" = "$expected_remote_head_sha" ]` therefore failed on EVERY run
# whose Phase 1 fixer APPLIED, so the post-fixer push could never land and
# Phase 3 went on to probe the stale remote SHA that 6a's own error text warns
# about. Reproduced live on PR #627.
#
# The two facts diverge for exactly one window — after a fixer commits locally
# and before 6a publishes — which is precisely the window 6a runs in.
# ---------------------------------------------------------------------------
L8_BAD=""
if [ -n "$L7_SEED" ] && [ -n "$L_RESEARCH_DIR" ]; then
  env -i PATH="$PATH" HOME="${HOME:-$TMP}" bash -c \
    '. "$1"; review_fleet_write_reviewed_head "$2" "$3"' \
    _ "$ARGS_LIB" "$L_RESEARCH_DIR/reviewed-head.txt" "$L7_SEED" 2>/dev/null \
    || L8_BAD="$L8_BAD reviewed-seed-write-failed"
  env -i PATH="$PATH" HOME="${HOME:-$TMP}" bash -c \
    '. "$1"; review_fleet_write_published_head "$2" "$3"' \
    _ "$ARGS_LIB" "$L_RESEARCH_DIR/published-head.txt" "$L7_SEED" 2>/dev/null \
    || L8_BAD="$L8_BAD published-seed-write-failed"

  # Advance the LOCAL head exactly as an APPLIED fixer does. Nothing pushes, so
  # the remote still stands on the seed.
  l_probe "$L_TMP/seed-fast.env" / "$L7_TRACK"
  [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = 0 ] \
    || L8_BAD="$L8_BAD advance-rc='$L_PROBE_OUT'(probe=$L_PROBE_RC)"
  [ "$(cat "$L_RESEARCH_DIR/reviewed-head.txt" 2>/dev/null)" = "$L7_FIXED" ] \
    || L8_BAD="$L8_BAD local-head-not-advanced"
  # The advance must NOT have moved the published record: only a successful
  # publish may do that.
  [ "$(cat "$L_RESEARCH_DIR/published-head.txt" 2>/dev/null)" = "$L7_SEED" ] \
    || L8_BAD="$L8_BAD published-head-moved-without-a-push='$(cat "$L_RESEARCH_DIR/published-head.txt" 2>/dev/null)'"

  # THE ROW. A fresh 6a-shaped shell must see the two heads DISAGREE: local at
  # the fixer commit, remote still at the seed. Binding both to the advanced
  # head is the defect, and it is what makes the publish gate unsatisfiable.
  for l8_seed_env in seed-fast seed-resolved; do
    if [ "$l8_seed_env" = seed-fast ]; then l8_cwd=/; else l8_cwd="$L_REPO"; fi
    l_probe "$L_TMP/$l8_seed_env.env" "$l8_cwd" \
      'printf "%s|%s" "${VALIDATED_FIXER_HEAD_SHA:-}" "${REVIEWED_HEAD_SHA:-}"'
    [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = "$L7_FIXED|$L7_SEED" ] \
      || L8_BAD="$L8_BAD $l8_seed_env='$L_PROBE_OUT'(want '$L7_FIXED|$L7_SEED',rc=$L_PROBE_RC)"
  done

  # Absent published record => today's behaviour, so a run that predates the
  # seed is not made worse by the fix.
  rm -f "$L_RESEARCH_DIR/published-head.txt"
  l_probe "$L_TMP/seed-fast.env" / 'printf "%s" "${REVIEWED_HEAD_SHA:-}"'
  [ "$L_PROBE_RC" = 0 ] && [ "$L_PROBE_OUT" = "$L7_FIXED" ] \
    || L8_BAD="$L8_BAD no-published-record='$L_PROBE_OUT'(rc=$L_PROBE_RC)"
  rm -f "$L_RESEARCH_DIR/reviewed-head.txt"
else
  L8_BAD="$L8_BAD prerequisites-missing"
fi
if [ -z "$L8_BAD" ]; then
  pass "L8 a fixer that advanced the local head leaves the published head where the remote actually is, so 6a's expected_remote_head_sha is satisfiable"
else
  fail "L8 the published head is conflated with the validated head:$L8_BAD"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
uberdev_test_exit_floor_reached
[ "$FAIL" -eq 0 ] || exit 1
exit 0

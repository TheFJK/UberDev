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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REVIEW_CMD="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
SIMPLIFY_CMD="$REPO_ROOT/plugins/uberdev/commands/simplify.md"
ARGS_LIB="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
DISPATCH="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/review-fleet/workflow.js"
SKILL="$REPO_ROOT/plugins/uberdev/skills/review-fleet/SKILL.md"
CONTRACT="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"

for f in "$REVIEW_CMD" "$SIMPLIFY_CMD" "$ARGS_LIB" "$DISPATCH" "$WORKFLOW" "$SKILL" "$CONTRACT"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
# `node` joined this list with section W, which EXECUTES workflow.js rather
# than grepping it. A missing interpreter must be one FATAL line, never
# fifteen mysterious W-row failures that read as engine bugs. Both CI images
# ship node (tests/workflow-scripts.test.sh relies on the same fact).
for tool in jq python3 node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is required" >&2; exit 2; }
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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
for stage_token in 'stage=review' 'fixerEdgeId=review_pr.fix.phase1' 'stage=simplify' 'fixerEdgeId=review_pr.fix.phase2' 'stage=defer' 'stage=ci-classify' 'stage=ci-fix' 'stage=ci-conflicts' 'stage=ci-defer'; do
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
grep -Fq 'capture-bound-child' "$REVIEW_CMD" \
  && grep -Fq 'capture-review-terminal' "$REVIEW_CMD" \
  && grep -Fq 'capture-persistence-terminal' "$REVIEW_CMD" \
  && grep -Fq 'post_review_validated_evidence_complete' "$REVIEW_CMD" \
  && grep -Fq 'post_review_write_aggregate_v2' "$REVIEW_CMD" \
  && pass "G10a review-pr runs the capture verbs for all four stages after the call" \
  || fail "G10a review-pr is missing a post-return capture verb"
grep -Fq 'capture-bound-child' "$SIMPLIFY_CMD" \
  && grep -Fq 'capture-standalone-terminal' "$SIMPLIFY_CMD" \
  && grep -Fq 'capture-persistence-terminal' "$SIMPLIFY_CMD" \
  && pass "G10b simplify runs the capture verbs for all three stages after the call" \
  || fail "G10b simplify is missing a post-return capture verb"
grep -Fq 'validate-review-outcome' "$REVIEW_CMD" \
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

# ---------------------------------------------------------------------------
# B — behavioral: run the mint fences the command files actually carry
# ---------------------------------------------------------------------------
echo "== B: the extracted mint fences really mint, bind and emit =="

run_stage_fence() {  # FILE TOKEN OUTDIR -> envelope on stdout
  local file="$1" token="$2" out="$3" body
  body="$(extract_fence "$file" "$token")" || return 1
  mkdir -p "$out/repo/.uberdev/research/RID" || return 1
  {
    echo 'set -u'
    echo "UBERDEV_REVIEW_PLUGIN_ROOT='$REPO_ROOT/plugins/uberdev'"
    echo "CODE_FIXER_CONTRACT='$CONTRACT'"
    echo "WORKTREE_ROOT='$out/repo'"
    echo "RESEARCH_DIR_ABS='$out/repo/.uberdev/research/RID'"
    echo "DIFF_ARTIFACT_PATH='$out/repo/.uberdev/research/RID/diff.md'"
    echo "RUN_ID=20260101-000000-abc123"
    echo "REVIEW_ITERATION=1"
    echo "PR_NUMBER=41"
    echo "REVIEW_REPO_SLUG=acme/widget"
    echo "FOCUS=''"
    echo "SEQUENTIAL=0"
    echo "ASPECT_LIST=(tests)"
    echo "BASE_SHA=0000000000000000000000000000000000000000"
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
  bash "$out/fence.sh" 2>"$out/fence.err"
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
  ledger_count="$(grep -c . "$out/repo/.uberdev/research/RID/$ledger" 2>/dev/null || echo 0)"
  [ "$ledger_count" = "$count" ] \
    && pass "B[$label] the launched ledger carries $count binding rows" \
    || fail "B[$label] the launched ledger carries $ledger_count rows, expected $count"

  # THE CROSS-CHECK: pool[i] must be the run_nonce of ledger row i+1, in roster
  # order. This is what a dropped or reordered nonce actually breaks.
  matched="$(python3 - "$out/repo/.uberdev/research/RID/$ledger" "$(printf '%s' "$env_json" | jq -r '.config.runNonces')" <<'PY'
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
  for slug_dir in "$out/repo/.uberdev/research/RID/children/"*-iter01; do
    [ -d "$slug_dir" ] || { fail "B[$label] a derived child directory is missing"; return; }
  done
  [ "$(find "$out/repo/.uberdev/research/RID/children" -maxdepth 1 -type d -name '*-iter01' | wc -l | tr -d ' ')" = "$count" ] \
    && pass "B[$label] all $count per-child directories exist under children/" \
    || fail "B[$label] the per-child directory count does not match the roster"
}

assert_stage review-stage "$REVIEW_CMD" 'stage=review' review-pr review 6 review-fleet-review.launched

# B[review-contract] — the review stage is the only stage that owns an output
# contract, so this is a standalone block rather than a parameter on the shared
# assert_stage helper (which also drives stage=simplify and stage=defer). It
# runs the REAL fence against the REAL plugin root, so it proves the value the
# envelope carries is the file the plugin ships — not merely that a key exists.
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
// argv: <workflow.js> <args-json-file>. Prints one JSON line:
//   {"threw":<string|null>,"abortReason":...,"dispatched":N,"labels":[...]}
import fs from 'node:fs';
import vm from 'node:vm';

const scriptPath = process.argv[2];
const source = fs.readFileSync(scriptPath, 'utf8');
// Same preprocess as tests/_workflow_harness.js: the meta block is an ESM
// `export`, which vm cannot evaluate, and the file's top level is `await`ed.
const body = source.replace(/\/\* META-BEGIN \*\/[\s\S]*?\/\* META-END \*\//, '');
const wrapped = '(async () => {\n' + body + '\n})()';

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
    return { status: 'COMPLETE', issuesCreated: [], commentedUrls: [], skipped: 0,
             halted: false, resultPath: '', statusPath: '' };
  },
  parallel: async (thunks) => Promise.all(thunks.map(async (t) => {
    try { return await t(); } catch { return null; }
  })),
  pipeline: async () => [],
  workflow: async () => ({}),
  budget: null,
};
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
}) + '\n');
WHARNESS

W_HEX64_A="$(printf 'ab%.0s' $(seq 32))"
W_NONCE1="$(printf '0%.0s' $(seq 63))1"
W_NONCE2="$(printf '0%.0s' $(seq 63))2"
W_NONCE3="$(printf '0%.0s' $(seq 63))3"
W_NONCE4="$(printf '0%.0s' $(seq 63))4"
W_NONCE5="$(printf '0%.0s' $(seq 63))5"
W_NONCE6="$(printf '0%.0s' $(seq 63))6"

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

W_CI_COMMON="$(jq -n --arg sha "$W_HEX64_A" '{
  ciLoopIter:1, ciAuthorityPathAbs:"/r/run/ci-auth.json",
  ciAuthoritySha256:$sha, ciInputSha256:$sha,
  ciRunId:"12345", ciHeadSha:"0000000000000000000000000000000000000000",
  ciBaseSha:"0000000000000000000000000000000000000000",
  ciPrBranch:"feat/x", ciBaseBranch:"main"}')"

assert_stage_runs review review \
  "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6" '{}' 6
assert_stage_runs simplify simplify "$W_NONCE1,$W_NONCE2,$W_NONCE3" '{}' 3
assert_stage_runs fix fix "$W_NONCE1" \
  "$(jq -n --arg sha "$W_HEX64_A" '{fixerEdgeId:"review_pr.fix.phase1", commitType:"fix",
     findingsPathAbs:"/r/run/f.md", findingsSha256:$sha,
     commitRangePathAbs:"/r/run/cr.json", commitRangeSha256:$sha,
     authorityPathAbs:"/r/run/a.json", authoritySha256:$sha,
     dispositionPathAbs:"/r/run/disp.json", appliedContentPathAbs:"/r/run/ac.json"}')" 1
# THE #383 REGRESSION: the shipped Phase 2.5 stage. It is reached by BOTH
# /review-pr and /simplify and it is the one stage no other test executes.
assert_stage_runs defer defer "$W_NONCE1" '{}' 1
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

# --- W-CONTRACT: the Phase 1 reviewers must be TOLD the output contract (#403)
#
# lib/child-dispatch.sh validates a reviewer result with re.fullmatch over the
# WHOLE file, and lib/review-aggregate.sh re-parses with the byte-identical
# regex. A prompt that delegates the serialization to "your agent file's
# declared output contract" delegates it to five prose sections that regex can
# never accept, so every Phase 1 wave comes back BLOCKED and the aggregate is
# suppressed. These rows read the PROMPTS the script actually builds.
stage_args review "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6" '{}'
W_CONTRACT_OUT="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args.json" 2>&1)"
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("phase1-reviewer-output-v1"))] | length')" = 6 ]; then
  pass "W[review-contract-path] all six reviewer prompts carry the contract path"
else
  fail "W[review-contract-path] the contract path reaches $(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("phase1-reviewer-output-v1"))] | length') of 6 reviewer prompts"
fi
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("entire contents of the result file"))] | length')" = 6 ] \
   && [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("agent file.s declared output contract"))] | length')" = 0 ]; then
  pass "W[review-contract-wholefile] every reviewer prompt binds the WHOLE result file and delegates to no agent file"
else
  fail "W[review-contract-wholefile] a reviewer prompt still delegates the serialization to its agent file"
fi
if [ "$(printf '%s' "$W_CONTRACT_OUT" | jq -r '[.prompts[] | select(test("blocker") and test("suggestion"))] | length')" = 6 ]; then
  pass "W[review-contract-vocab] every reviewer prompt states the blocker/suggestion severity vocabulary"
else
  fail "W[review-contract-vocab] the severity vocabulary the validator accepts is not in every prompt"
fi

# The gate. A wiring regression must abort BEFORE the nonce gate, so no nonce is
# burned and no child is dispatched into an unstated contract.
w_contract_abort() {  # LABEL JQ_MUTATION
  local label="$1" mutation="$2" out abort prompts labels
  stage_args review "$W_NONCE1,$W_NONCE2,$W_NONCE3,$W_NONCE4,$W_NONCE5,$W_NONCE6" '{}'
  jq "$mutation" "$TMP/w-args.json" >"$TMP/w-args-contract.json"
  out="$(node "$W_HARNESS" "$WORKFLOW" "$TMP/w-args-contract.json" 2>&1)"
  abort="$(printf '%s' "$out" | jq -r '.abortReason')"
  prompts="$(printf '%s' "$out" | jq -r '.prompts | length')"
  labels="$(printf '%s' "$out" | jq -r '.labels | length')"
  if [ "$abort" = bad_contract_path ] && [ "$prompts" = 0 ] && [ "$labels" = 0 ]; then
    pass "W[$label] aborts bad_contract_path with zero prompts and zero dispatches"
  else
    fail "W[$label] abort='$abort' prompts=$prompts labels=$labels (want bad_contract_path/0/0)"
  fi
}
w_contract_abort review-contract-missing 'del(.config.phase1ContractPathAbs)'
w_contract_abort review-contract-empty '.config.phase1ContractPathAbs = ""'
w_contract_abort review-contract-relative '.config.phase1ContractPathAbs = "shared/x.md"'
w_contract_abort review-contract-traversal '.config.phase1ContractPathAbs = "/p/../etc/x"'

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
sed 's|^function f2iPrompt(notes, nonce) {|function f2iPrompt(notes, nonce) {\n  lines_that_do_not_exist.push(childInputPath(undeclared_slug));|' \
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

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

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
for tool in jq python3; do
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
for literal in 'Phase 3 — CI classify' 'Phase 3 — CI fix' 'Phase 3 — CI conflicts' 'Phase 3 — CI defer'; do
  grep -Fq "phase(\"$literal\")" "$WORKFLOW" || G17_MISSING="$G17_MISSING no-phase-call[$literal]"
  # META-BEGIN/META-END block must declare it.
  sed -n '/META-BEGIN/,/META-END/p' "$WORKFLOW" | grep -Fq "\"$literal\"" \
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

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

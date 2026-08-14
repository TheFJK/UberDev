#!/usr/bin/env bash
set -euo pipefail
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LIB="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
TMP="$(mktemp -d)"; mkdir -p "$TMP/run"
# Reap the symlink racer by its recorded PID before the tree goes away: an
# assertion that reds mid-race would otherwise leave a background fixture
# churning `mv`/`ln -s` against a directory this trap has already deleted.
# `RACE_PID` is cleared the moment it is waited on, so this never signals a
# reused PID.
RACE_PID=''
trap '[ -z "$RACE_PID" ] || kill "$RACE_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
trap 'echo "route-context failure: line=$LINENO command=$BASH_COMMAND" >&2' ERR
file_mode() {
  local value
  value="$(stat -c '%a' "$1" 2>/dev/null || true)"
  case "$value" in
    ''|*[!0-7]*) stat -f '%Lp' "$1" 2>/dev/null ;;
    *) printf '%s\n' "$value" ;;
  esac
}
# A standalone `! cmd` is EXEMPT from errexit -- POSIX: the shell does not exit
# when the failing command's status is being inverted with `!`. Every negated
# assertion in this file was therefore dead: when the forbidden outcome actually
# happened the statement evaluated to 1, errexit ignored it, the ERR trap never
# fired, and the run walked on to print its unconditional PASS line. These
# helpers fold the verdict into a call that stops on the spot and names the
# individual case, so a wrong outcome reds with a per-case diagnostic rather
# than being invisible behind a summary line a green run prints regardless.
fail() { printf 'route-context FAIL [%s]: %s\n' "$1" "$2" >&2; exit 1; }
# Stderr is captured INSIDE the helper, never by a redirection written on the
# call, so the diagnostic can never be swallowed into the very file the caller
# then greps.
assert_refused() {   # assert_refused LABEL ERRFILE CMD [ARG...]
  local label="$1" errfile="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>"$errfile" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label" 'expected a refusal; the command succeeded'
  # 126/127 mean "could not run it at all", which is not a refusal. Accepting it
  # as one is how a renamed or unsourced entry point turns an assertion vacuous;
  # no routing entry point returns >=126 (every failure path returns 1 or 2).
  [ "$rc" -lt 126 ] || fail "$label" "exited $rc without running: $(cat "$errfile")"
}
assert_absent() {    # assert_absent LABEL PATTERN FILE
  local label="$1" pattern="$2" target="$3"
  local rc=0
  grep -q "$pattern" "$target" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label" "forbidden pattern <$pattern> is present in $target"
  # grep's exit 2 is an error, not an absence proof: a mistyped or missing path
  # would otherwise report "not found" forever.
  [ "$rc" -eq 1 ] || fail "$label" "grep for <$pattern> in $target failed with $rc; absence unproven"
}
# Same, over the CODE half of a shell file only. The two catalog rows below are
# the reason: they read `! grep -q … "$LIB"`, which errexit ignored, and the
# condition they forbid is ALREADY true -- agent-dispatch.sh:235,237 explain in
# prose why there is no catalog input left. Both rows have therefore been
# passing while failing since #381 landed. A seam documenting the absence of a
# surface is not declaring that surface, so the assertion is scoped to code
# bytes: a real `UBERDEV_MODEL_CATALOG_FILE` read or `catalog` token in code
# still reds (proven by mutation), while the explanation of its removal does
# not. Comments are cut on the shell rule -- `#` at start of line or after
# whitespace -- so `x=a#b` keeps its bytes. Written through a file rather than a
# pipe so `grep -q`'s early exit cannot SIGPIPE `sed` into a bogus status.
assert_absent_in_code() {   # assert_absent_in_code LABEL PATTERN SHELL_FILE
  local label="$1" pattern="$2" target="$3"
  local rc=0
  [ -s "$target" ] || fail "$label" "$target is missing or empty; absence unproven"
  sed -E 's/(^|[[:space:]])#.*$//' "$target" >"$TMP/code-only.txt"
  [ -s "$TMP/code-only.txt" ] || fail "$label" "$target has no code left after comment stripping"
  grep -q "$pattern" "$TMP/code-only.txt" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label" "forbidden pattern <$pattern> is present in the code of $target"
  [ "$rc" -eq 1 ] || fail "$label" "grep for <$pattern> in $target failed with $rc; absence unproven"
}
. "$LIB"
# Config provenance is per-key, redacted, deterministic, and path-canonical.
mkdir -p "$TMP/project/.codex"
cat >"$TMP/project/.codex/uberdev.local.md" <<'EOF'
---
model_routing:
  mode: adaptive
  service_tier: fast
  roles:
    plan-writer: deep
---
do not parse secret-from-markdown
EOF
PROVENANCE="$(cd "$TMP/project" && CONFIG_LIB="$ROOT/plugins/uberdev/lib/config-read.sh" UBERDEV_SERVICE_TIER=flex bash -c '. "$CONFIG_LIB"; uberdev_read_model_routing; printf %s "$UBERDEV_ROUTING_PROVENANCE_JSON"')"
python3 - "$PROVENANCE" "$TMP/project/.codex/uberdev.local.md" <<'PY'
import json,pathlib,sys
p=json.loads(sys.argv[1]); expected=str(pathlib.Path(sys.argv[2]).resolve())
assert p['mode']=={'source':'project-codex','file':expected},p
assert p['service_tier']=={'source':'env','file':None},p
assert p['roles']=={'source':'project-codex','file':expected},p
assert 'secret-from-markdown' not in json.dumps(p) and 'flex' not in json.dumps(p)
PY
printf '%s\n' 'model_routing:' '  mode: adaptive' >"$TMP/explicit.md"
EXPLICIT="$(cd "$TMP/project" && CONFIG_LIB="$ROOT/plugins/uberdev/lib/config-read.sh" UBERDEV_CONFIG_FILE="$TMP/explicit.md" bash -c '. "$CONFIG_LIB"; uberdev_read_model_routing; printf %s "$UBERDEV_ROUTING_PROVENANCE_JSON"')"
python3 - "$EXPLICIT" "$TMP/explicit.md" <<'PY'
import json,pathlib,sys
p=json.loads(sys.argv[1]); assert p['mode']=={'source':'explicit-config-file','file':str(pathlib.Path(sys.argv[2]).resolve())}; assert p['roles']=={'source':'default','file':None}
PY
INVALID="$(cd "$TMP/project" && CONFIG_LIB="$ROOT/plugins/uberdev/lib/config-read.sh" UBERDEV_MODEL_ROUTING_MODE='secret-invalid-value' bash -c '. "$CONFIG_LIB"; uberdev_read_model_routing 2>/dev/null; printf %s "$UBERDEV_ROUTING_PROVENANCE_JSON"')"
python3 - "$INVALID" <<'PY'
import json,sys
p=json.loads(sys.argv[1]); assert p['mode']=={'source':'default','file':None}; assert 'secret-invalid-value' not in sys.argv[1]
PY
# RETIRED SURFACE (#381): this request used to carry routing_mode=adaptive and
# resolve to a concrete (frontier, max) pair. Adaptive per-rank routing is
# unenforceable on every shipped backend, so the canonical request no longer
# names a mode and the canonical decision is backend-neutral inherit. Asking for
# adaptive is now a typed refusal, asserted immediately below.
REQ='{"schema_version":1,"run_dir":"'"$TMP/run"'","run_id":"root-1","repository_id":"repo","backend":"workflow","workflow":"solve","phase":"plan","role":"plan-writer","task_tier":"medium","risk_signals":[],"issue_or_pr":7,"issue_num":7,"capacity":2,"timeout_s":30}'
DECISION="$(uberdev_agent_resolve_request "$REQ")"
python3 - "$DECISION" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d['route_source']=='backend-neutral-inherit',d
assert d['logical_route'] is None and d['reasoning_effort'] is None and d['model'] is None,d
assert d['routing_mode']=='inherit' and d['effective_policy']=='inherit',d
assert d['forced'] is False and d['minimum_route'] is None and d['fallback_chain']==[],d
PY
ADAPTIVE_REQ="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["routing_mode"]="adaptive";print(json.dumps(r,separators=(",",":")))' "$REQ")"
assert_refused 'adaptive routing_mode is a typed refusal' "$TMP/adaptive.err" \
  uberdev_agent_resolve_request "$ADAPTIVE_REQ"
grep -q route_unenforceable "$TMP/adaptive.err"
[ ! -e "$TMP/run/.agent-state-$(id -u)" ]
PROV='{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}'
META='{"run_id":"root-1","repository_id":"repo","workflow":"solve","backend":"workflow","issue_num":7,"task_tier":"medium","risk_signals":[]}'
OUT="$(uberdev_agent_context_create "$TMP/run" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"
CTX="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$OUT")"
SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$OUT")"
[ "$(file_mode "$CTX")" = 600 ]
uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run" >/dev/null
cp "$CTX" "$TMP/copy"; printf 'x' >> "$CTX"
assert_refused 'an appended byte invalidates the sealed context' "$TMP/validate.err" \
  uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run"
mv "$TMP/copy" "$CTX"; chmod 600 "$CTX"
# Even a caller-supplied matching hash cannot bless a valid-shaped but
# request-incoherent persisted decision.
cp "$CTX" "$TMP/coherent-copy"
TAMPERED_SHA="$(python3 - "$CTX" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); value=json.loads(p.read_text()); value['root_decision']['logical_route']='deep'; value['root_decision']['reasoning_effort']='high'; raw=json.dumps(value,sort_keys=True,separators=(',',':')).encode(); p.write_bytes(raw); print(hashlib.sha256(raw).hexdigest())
PY
)"
assert_refused 'a caller-supplied matching hash cannot bless a tampered decision' "$TMP/validate.err" \
  uberdev_agent_context_validate "$CTX" "$TAMPERED_SHA" "$TMP/run"
mv "$TMP/coherent-copy" "$CTX"; chmod 600 "$CTX"
ln "$CTX" "$TMP/hard"
assert_refused 'a hard-linked context is refused' "$TMP/validate.err" \
  uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run"
rm "$TMP/hard"
mv "$CTX" "$TMP/real"; ln -s "$TMP/real" "$CTX"
assert_refused 'a symlinked context is refused' "$TMP/validate.err" \
  uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run"
# Restore the immutable context, then prove a decision mismatch is rejected
# before lifecycle publication, lease acquisition, or the provider boundary.
# The guard is agent-dispatch.sh:1622 -- recomputed decision != sealed decision.
# It is LIVE and still asserted here; only the mutation used to trip it changed.
# This case used to flip task_tier medium->small, which changed the resolved
# logical_route and so changed the decision. The decision is backend-neutral
# now, so tier no longer appears in it and a tier flip no longer trips this
# guard -- a real, stated loss: nothing at this seam compares the supplied
# task_tier to the sealed one. `risk_signals` does still appear in the decision,
# so it is the mutation that keeps the guard under test.
rm "$CTX"; mv "$TMP/real" "$CTX"; chmod 600 "$CTX"
BAD_CONTEXT_REQ="$(python3 - "$REQ" "$CTX" "$SHA" "$DECISION" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); r['context_file']=sys.argv[2]; r['context_sha256']=sys.argv[3]; r['root_decision']=json.loads(sys.argv[4]); r['risk_signals']=['security']; print(json.dumps(r,separators=(',',':')))
PY
)"
_uberdev_agent_dispatch_backend() { printf invoked >"$TMP/provider-invoked"; return 1; }
export -f _uberdev_agent_dispatch_backend
printf prompt >"$TMP/run/prompt.txt"
assert_refused 'a decision mismatch is rejected before the provider boundary' "$TMP/mismatch-error" \
  uberdev_agent_dispatch "$BAD_CONTEXT_REQ" "$TMP/run/prompt.txt" "$TMP/run/result.md" "$TMP/run/status.json"
grep -q route_context_mismatch "$TMP/mismatch-error"
[ ! -e "$TMP/provider-invoked" ]
[ ! -e "$TMP/run/.agent-state-$(id -u)/agent-lifecycle.jsonl" ]
# The solve dispatch seam keeps CLI, raw environment, and project layers
# separate instead of promoting resolved config into explicit CLI fields.
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/assembled.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=workflow UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 \
    UBERDEV_DISPATCH_ROUTE=sol-ultra UBERDEV_MODEL_ROUTING_MODE=adaptive UBERDEV_SERVICE_TIER=fast \
    UBERDEV_AGENT_WORKFLOW=turbo UBERDEV_AGENT_PHASE=plan UBERDEV_AGENT_ROLE=plan-writer \
    UBERDEV_AGENT_RISK_SIGNALS_JSON='["security"]' \
    uberdev_dispatch_one 7 large "$TMP/run/prompt.txt"
)
python3 - "$TMP/assembled.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text()); assert r['explicit_route']=='sol-ultra'; assert 'routing_mode' not in r; assert 'explicit_service_tier' not in r
assert r['environment']=={'UBERDEV_MODEL_ROUTING_MODE':'adaptive','UBERDEV_SERVICE_TIER':'fast'}; assert 'project_routing' not in r
assert (r['workflow'],r['phase'],r['role'],r['risk_signals'])==('turbo','plan','plan-writer',['security'])
PY
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/env-map-assembled.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=workflow UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 UBERDEV_MODEL_ROUTING_MODE=adaptive \
    UBERDEV_MODEL_ROUTING_ROLES='{"plan-writer":"deep"}' UBERDEV_AGENT_ROLE=plan-writer UBERDEV_AGENT_PHASE=plan \
    uberdev_dispatch_one 7 medium "$TMP/run/prompt.txt"
)
python3 - "$TMP/env-map-assembled.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text()); assert r['environment']['UBERDEV_MODEL_ROUTING_ROLES']=={'plan-writer':'deep'}; assert 'project_routing' not in r
PY
# Invalid config-backed environment values must not be forwarded after the
# config reader has fallen back; concrete route/model/effort remain raw inputs.
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/invalid-assembled.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=workflow UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 \
    UBERDEV_MODEL_ROUTING_MODE=bogus UBERDEV_SERVICE_TIER=bogus \
    UBERDEV_MODEL_ROUTING_RISK_ESCALATION=bogus UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK=bogus UBERDEV_MODEL_ROUTING_SHADOW=bogus \
    UBERDEV_ROUTE=deep UBERDEV_MODEL=gpt-5.6-sol UBERDEV_REASONING_EFFORT=high \
    uberdev_dispatch_one 7 small "$TMP/run/prompt.txt" 2>/dev/null
)
python3 - "$TMP/invalid-assembled.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text()); e=r['environment']
assert e=={'UBERDEV_ROUTE':'deep','UBERDEV_MODEL':'gpt-5.6-sol','UBERDEV_REASONING_EFFORT':'high'},e
PY
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/invalid-risk.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=workflow UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 UBERDEV_MODEL_ROUTING_MODE=adaptive \
    UBERDEV_MODEL_ROUTING_RISK_ESCALATION=bogus UBERDEV_AGENT_ROLE=plan-writer UBERDEV_AGENT_PHASE=plan UBERDEV_AGENT_RISK_SIGNALS_JSON='["security"]' \
    uberdev_dispatch_one 7 small "$TMP/run/prompt.txt" 2>/dev/null
)
# The assembled request still carries the raw adaptive env value rather than a
# resolved one -- that layering is live and asserted here. What changed is the
# outcome: an invalid risk_escalation used to be dropped and the run resolved to
# `ultra`; asking for adaptive at all is now refused, so there is no route to
# escalate. LOST COVERAGE, named: risk escalation to the high-risk floor when
# UBERDEV_MODEL_ROUTING_RISK_ESCALATION is invalid and falls back to true.
python3 - "$TMP/invalid-risk.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r['environment']=={'UBERDEV_MODEL_ROUTING_MODE':'adaptive'},r['environment']
assert r['risk_signals']==['security'],r
PY
assert_refused 'adaptive env with an invalid risk_escalation is refused' "$TMP/invalid-risk.err" \
  uberdev_agent_resolve_request "$(cat "$TMP/invalid-risk.json")"
grep -q route_unenforceable "$TMP/invalid-risk.err"
# Every backend rejects every environment concrete/service pin, and the resolver
# seam no longer has a catalog input to be pointed at an unsafe file.
for key in UBERDEV_ROUTE UBERDEV_MODEL UBERDEV_REASONING_EFFORT UBERDEV_SERVICE_TIER; do
  VALUE=deep; [ "$key" != UBERDEV_MODEL ] || VALUE=gpt-5.6-sol; [ "$key" != UBERDEV_REASONING_EFFORT ] || VALUE=high; [ "$key" != UBERDEV_SERVICE_TIER ] || VALUE=fast
  PINNED="$(python3 - "$key" "$VALUE" <<'PY'
import json,sys
print(json.dumps({'backend':'background','workflow':'solve','role':'lead','task_tier':'small','risk_signals':[],'environment':{sys.argv[1]:sys.argv[2]}},separators=(',',':')))
PY
)"
  assert_refused "environment pin $key is refused by every backend" "$TMP/noncodex-$key.err" \
    uberdev_agent_resolve_request "$PINNED"
  grep -q route_unenforceable "$TMP/noncodex-$key.err"
done
UBERDEV_MODEL_CATALOG_FILE="$TMP/missing-catalog" uberdev_agent_resolve_request '{"backend":"background","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[]}' >/dev/null
# RETIRED SURFACE (#381): UBERDEV_MODEL_CATALOG_FILE was an injectable provider
# catalog read by the resolver. The line above still proves a stale value in the
# environment is inert, but the stronger statement is that the seam declares no
# catalog input at all -- so it cannot be steered at an attacker-chosen file.
assert_absent_in_code 'the resolver seam declares no catalog env input' 'UBERDEV_MODEL_CATALOG_FILE' "$LIB"
assert_absent_in_code 'the resolver seam declares no catalog input at all' 'catalog' "$LIB"

# Recursive request shapes are closed and secret-shaped nested keys fail.
for payload in \
  '{"backend":"workflow","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"environment":{"AWS_SECRET_ACCESS_KEY":"x"}}' \
  '{"backend":"workflow","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"environment":{"SURPRISE":"x"}}' \
  '{"backend":"workflow","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"project_routing":{"surprise":true}}' \
  '{"backend":"workflow","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"parent_run":{"surprise":"x"}}'; do
  assert_refused "recursive/secret-shaped request is refused: $payload" "$TMP/nested.err" \
    uberdev_agent_resolve_request "$payload"
done

# Context creation validates the complete closed schema before state mutation.
mkdir "$TMP/schema-root"
for kind in request decision provenance metadata created; do
  R="$REQ"; D="$DECISION"; P="$PROV"; M="$META"; C='2026-07-10T00:00:00Z'
  case "$kind" in
    request) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["surprise"]=1;print(json.dumps(r))' "$REQ")" ;;
    decision) D='{"surprise":true}' ;;
    provenance) P='{"surprise":{"source":"env","file":null}}' ;;
    metadata) M='{"run_id":"root-1","repository_id":"repo","workflow":"solve","backend":"workflow","issue_num":7,"task_tier":"gigantic","risk_signals":["AWS_SECRET_ACCESS_KEY"]}' ;;
    created) C='' ;;
  esac
  assert_refused "context_create rejects a malformed $kind before any state mutation" "$TMP/schema-$kind.err" \
    uberdev_agent_context_create "$TMP/schema-root" "$R" "$D" "$P" "$M" "$C"
  [ ! -e "$TMP/schema-root/.agent-state-$(id -u)" ]
done

# Allowed keys still require exact semantic values and the persisted decision
# must be the canonical decision for the persisted request.
SMALL_REQ="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["task_tier"]="small";print(json.dumps(r,separators=(",",":")))' "$REQ")"
SMALL_DECISION="$(uberdev_agent_resolve_request "$SMALL_REQ")"
RISK_REQ="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["task_tier"]="small";r["risk_signals"]=["security"];print(json.dumps(r,separators=(",",":")))' "$REQ")"
RISK_META='{"run_id":"root-1","repository_id":"repo","workflow":"solve","backend":"workflow","issue_num":7,"task_tier":"small","risk_signals":["security"]}'
# `request-decision` used to seal SMALL_DECISION against the medium REQ: the two
# differed because the resolved route was tier-dependent. Nothing in a
# backend-neutral decision varies with tier, so that mutation no longer produces
# a non-canonical pairing and the case was replaced by `backend-decision`, which
# mutates a field the decision does still carry. The live coherence check
# (agent-dispatch.sh:435 -- decision.backend vs metadata.backend) is unchanged.
for kind in env-bool project-scalar project-map parent-null decision-type backend-decision risk-decision service-decision; do
  ROOT_CASE="$TMP/schema-$kind"; mkdir "$ROOT_CASE"
  R="$REQ"; D="$DECISION"; M="$META"
  case "$kind" in
    env-bool) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["environment"]={"UBERDEV_MODEL_ROUTING_RISK_ESCALATION":"secret"};print(json.dumps(r,separators=(",",":")))' "$REQ")" ;;
    project-scalar) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["project_routing"]={"mode":"bogus"};print(json.dumps(r,separators=(",",":")))' "$REQ")" ;;
    project-map) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["project_routing"]={"roles":{"plan-writer":{"route":"bogus"}}};print(json.dumps(r,separators=(",",":")))' "$REQ")" ;;
    parent-null) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r.pop("routing_mode",None);r["parent_run"]={"forced":True,"logical_route":None,"model":"gpt-5.6-sol","reasoning_effort":"ultra"};print(json.dumps(r,separators=(",",":")))' "$REQ")" ;;
    decision-type) D="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["forced"]="false";print(json.dumps(d,separators=(",",":")))' "$DECISION")" ;;
    backend-decision) D="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["backend"]="background";print(json.dumps(d,separators=(",",":")))' "$DECISION")" ;;
    risk-decision) R="$RISK_REQ"; D="$SMALL_DECISION"; M="$RISK_META" ;;
    service-decision) D="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["service_tier"]="fast";print(json.dumps(d,separators=(",",":")))' "$DECISION")" ;;
  esac
  assert_refused "context_create rejects semantic case $kind" "$TMP/semantic-$kind.err" \
    uberdev_agent_context_create "$ROOT_CASE" "$R" "$D" "$PROV" "$M" '2026-07-10T00:00:00Z'
  [ ! -e "$ROOT_CASE/.agent-state-$(id -u)" ]
  [ -z "$(find "$ROOT_CASE" -name '.route-context.*' -print -quit)" ]
done

# Provenance must describe the selected config/env/project layer carried in the
# immutable request; it may not contradict or invent that layer. This is
# uberdev_agent_context_create's guard. Be precise about what still proves what:
# context_create re-resolves the request first (agent-dispatch.sh:453), so the
# five cases whose request names a concrete env/project layer (env-mode-default,
# env-service-default, project-role-default, project-source-wrong-file,
# project-env-wins) are now rejected at that earlier resolve gate with
# route_unenforceable, and no longer exercise the provenance comparison itself.
# The four that still reach it -- env-risk-default, env-source-missing,
# workflows-env-missing, invalid-source-file -- carry a request the resolver
# accepts, so they remain true tests of the provenance guard. Every case still
# proves the same user-facing property: the context is never sealed. The
# decision passed in is the canonical backend-neutral one with risk_signals
# matched to the case, since a per-case resolution can no longer be produced.
for kind in env-mode-default env-service-default env-risk-default env-source-missing workflows-env-missing project-role-default project-source-wrong-file project-env-wins invalid-source-file; do
  ROOT_CASE="$TMP/provenance-$kind"; mkdir "$ROOT_CASE"
  CASE_DATA="$(python3 - "$REQ" "$PROV" "$TMP/project/.codex/uberdev.local.md" "$kind" <<'PY'
import json,pathlib,sys
r=json.loads(sys.argv[1]); p=json.loads(sys.argv[2]); codex=str(pathlib.Path(sys.argv[3]).resolve()); kind=sys.argv[4]
if kind.startswith('env-'): r.pop('routing_mode',None)
if kind=='env-mode-default': r['environment']={'UBERDEV_MODEL_ROUTING_MODE':'adaptive'}
elif kind=='env-service-default': r['environment']={'UBERDEV_SERVICE_TIER':'fast'}
elif kind=='env-risk-default': r['environment']={'UBERDEV_MODEL_ROUTING_RISK_ESCALATION':False}; r['risk_signals']=['security']
elif kind=='env-source-missing': p['mode']={'source':'env','file':None}
elif kind=='workflows-env-missing': p['workflows']={'source':'env','file':None}
elif kind=='project-role-default': r['project_routing']={'roles':{'plan-writer':'deep'}}
elif kind=='project-source-wrong-file': r['project_routing']={'roles':{'plan-writer':'deep'}}; p['roles']={'source':'project-codex','file':codex.replace('/.codex/','/.claude/')}
elif kind=='project-env-wins': r.pop('routing_mode',None); r['environment']={'UBERDEV_MODEL_ROUTING_MODE':'adaptive'}; r['project_routing']={'mode':'inherit'}; p['mode']={'source':'project-codex','file':codex}
elif kind=='invalid-source-file': p['mode']={'source':'env','file':codex}
print(json.dumps(r,separators=(',',':'))); print(json.dumps(p,separators=(',',':')))
PY
)"
  CASE_REQ="$(printf '%s\n' "$CASE_DATA" | sed -n '1p')"; CASE_PROV="$(printf '%s\n' "$CASE_DATA" | sed -n '2p')"
  CASE_DECISION="$(python3 - "$DECISION" "$CASE_REQ" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); r=json.loads(sys.argv[2])
d['risk_signals']=r.get('risk_signals',[]); d['backend']=r['backend']
print(json.dumps(d,sort_keys=True,separators=(',',':')),end='')
PY
)"
  CASE_META="$(python3 - "$CASE_REQ" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); print(json.dumps({'run_id':'root-1','repository_id':'repo','workflow':r['workflow'],'backend':r['backend'],'issue_num':7,'task_tier':r['task_tier'],'risk_signals':r.get('risk_signals',[])},separators=(',',':')))
PY
)"
  assert_refused "provenance case $kind is never sealed" "$TMP/provenance-$kind.err" \
    uberdev_agent_context_create "$ROOT_CASE" "$CASE_REQ" "$CASE_DECISION" "$CASE_PROV" "$CASE_META" '2026-07-10T00:00:00Z'
  [ ! -e "$ROOT_CASE/.agent-state-$(id -u)" ]
done
# The positive counterpart: env-sourced provenance IS accepted and seals, so the
# rejections above are not a blanket refusal of the env layer. The env values
# used to be adaptive/fast/{plan-writer:deep}; those are concrete and now refuse
# at the resolve gate, so this case pins the strongest env layer that is still
# enforceable -- explicitly selected, but equal to the ambient default.
VALID_PROV_ROOT="$TMP/provenance-valid"; mkdir "$VALID_PROV_ROOT"
VALID_PROV_REQ="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["environment"]={"UBERDEV_MODEL_ROUTING_MODE":"inherit","UBERDEV_SERVICE_TIER":"default","UBERDEV_MODEL_ROUTING_ROLES":{}};print(json.dumps(r,separators=(",",":")))' "$REQ")"
VALID_PROV_DECISION="$(uberdev_agent_resolve_request "$VALID_PROV_REQ")"
VALID_PROV="$(python3 -c 'import json,sys;p=json.loads(sys.argv[1]);p["mode"]={"source":"env","file":None};p["service_tier"]={"source":"env","file":None};p["roles"]={"source":"env","file":None};print(json.dumps(p,separators=(",",":")))' "$PROV")"
VALID_PROV_OUT="$(uberdev_agent_context_create "$VALID_PROV_ROOT" "$VALID_PROV_REQ" "$VALID_PROV_DECISION" "$VALID_PROV" "$META" '2026-07-10T00:00:00Z')"
VALID_PROV_FILE="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$VALID_PROV_OUT")"; VALID_PROV_SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$VALID_PROV_OUT")"
uberdev_agent_context_validate "$VALID_PROV_FILE" "$VALID_PROV_SHA" "$VALID_PROV_ROOT" >/dev/null

# RETIRED SURFACE (#381). These three blocks asserted resolver semantics that no
# longer exist: (1) an environment role/workflow map replaced the whole project
# map, so a non-overlapping project `ultra` pin could not survive and `{}` was a
# meaningful clear; (2) a `sandbox` entry in either map selected the decision's
# sandbox with an `environment-role`/`environment-workflow` field source; (3) a
# plain route entry in either map produced logical_route `deep` with that same
# source label. LOST COVERAGE, named exactly that. There is no route_source, no
# field_sources and no sandbox selection left to assert -- see RFC 0013
# (2026-08-05 amendment).
# What is asserted instead is the property that actually protects the user: none
# of these shapes silently becomes a route. Every one is refused, including the
# `{}` clear paired with a project pin, so a project `ultra` can never leak
# through as an unannounced escalation.
for scope in roles workflows; do
  for env_kind in nonoverlap empty sandbox route; do
    MAP_REQ="$(python3 - "$scope" "$env_kind" <<'PY'
import json,sys
scope,kind=sys.argv[1:]
env={'nonoverlap':{'code-simplifier':'deep'},'empty':{},'sandbox':{'plan-writer':{'sandbox':'read-only'}},'route':{'plan-writer':'deep'}}[kind]
if scope=='roles':
 r={'backend':'workflow','workflow':'solve','phase':'plan','role':'plan-writer','task_tier':'medium','risk_signals':[],'project_routing':{'roles':{'plan-writer':'ultra'}},'environment':{'UBERDEV_MODEL_ROUTING_ROLES':env}}
else:
 env={'nonoverlap':{'turbo':'deep'},'empty':{},'sandbox':{'solve':{'sandbox':'read-only'}},'route':{'solve':'deep'}}[kind]
 r={'backend':'workflow','workflow':'solve','phase':'lead','role':'lead','task_tier':'medium','risk_signals':[],'project_routing':{'workflows':{'solve':'ultra'}},'environment':{'UBERDEV_MODEL_ROUTING_WORKFLOWS':env}}
print(json.dumps(r,separators=(',',':')))
PY
)"
    assert_refused "map $scope/$env_kind never silently becomes a route" "$TMP/map-$scope-$env_kind.err" \
      uberdev_agent_resolve_request "$MAP_REQ"
    grep -q route_unenforceable "$TMP/map-$scope-$env_kind.err"
    assert_absent "project ultra never leaks through map $scope/$env_kind" ultra "$TMP/map-$scope-$env_kind.err"
  done
done

# Presence is provenance: an explicit project value equal to the canonical
# default is project-sourced, never indistinguishable from absence/default.
for field in mode service_tier risk_escalation adaptive_fallback shadow workflows roles; do
  for source_case in default codex-wrong-family claude-wrong-family; do
    ROOT_CASE="$TMP/project-default-$field-$source_case"; mkdir "$ROOT_CASE"
    CASE_DATA="$(python3 - "$REQ" "$PROV" "$field" "$source_case" "$TMP/project/.codex/uberdev.local.md" <<'PY'
import json,pathlib,sys
r=json.loads(sys.argv[1]); p=json.loads(sys.argv[2]); field,case=sys.argv[3:5]; codex=str(pathlib.Path(sys.argv[5]).resolve())
defaults={'mode':'inherit','service_tier':'default','risk_escalation':True,'adaptive_fallback':True,'shadow':False,'workflows':{},'roles':{}}
r['project_routing']={field:defaults[field]}
if case=='codex-wrong-family': p[field]={'source':'project-codex','file':codex.replace('/.codex/','/.claude/')}
elif case=='claude-wrong-family': p[field]={'source':'project-claude','file':codex}
print(json.dumps(r,separators=(',',':'))); print(json.dumps(p,separators=(',',':')))
PY
)"
    CASE_REQ="$(printf '%s\n' "$CASE_DATA" | sed -n '1p')"; CASE_PROV="$(printf '%s\n' "$CASE_DATA" | sed -n '2p')"; CASE_DECISION="$(uberdev_agent_resolve_request "$CASE_REQ")"
    assert_refused "project default $field/$source_case stays project-sourced" "$TMP/project-default-$field-$source_case.err" \
      uberdev_agent_context_create "$ROOT_CASE" "$CASE_REQ" "$CASE_DECISION" "$CASE_PROV" "$META" '2026-07-10T00:00:00Z'
    [ ! -e "$ROOT_CASE/.agent-state-$(id -u)" ]
  done
done

# A state-directory ancestor cannot be replaced by a symlink outside run root.
mkdir "$TMP/escape-root"
ESC="$(uberdev_agent_context_create "$TMP/escape-root" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"
ESC_FILE="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$ESC")"; ESC_SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$ESC")"
mv "$TMP/escape-root/.agent-state-$(id -u)" "$TMP/escaped-state"; ln -s "$TMP/escaped-state" "$TMP/escape-root/.agent-state-$(id -u)"
assert_refused 'a state-dir ancestor replaced by an outside symlink is refused' "$TMP/escape.err" \
  uberdev_agent_context_validate "$ESC_FILE" "$ESC_SHA" "$TMP/escape-root"
# Race the state entry between its owned directory and an outside symlink. A
# validation that begins and ends on the symlink must never succeed.
mkdir "$TMP/race-root"
RACE="$(uberdev_agent_context_create "$TMP/race-root" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"; RACE_FILE="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$RACE")"; RACE_SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$RACE")"
cp -R "$TMP/race-root/.agent-state-$(id -u)" "$TMP/race-outside"
# Drive the oracle directly first, so it is exercised on EVERY run instead of
# only when the scheduler happens to line the racer up: with the outside symlink
# installed for the whole call, validation must refuse -- and must go back to
# accepting once the owned directory is restored, which is what makes the
# refusal attributable to the symlink rather than to any lasting damage.
mv "$TMP/race-root/.agent-state-$(id -u)" "$TMP/race-hold"
ln -s "$TMP/race-outside" "$TMP/race-root/.agent-state-$(id -u)"
assert_refused 'a symlinked state entry held for the whole call is refused' "$TMP/race-held.err" \
  uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root"
rm "$TMP/race-root/.agent-state-$(id -u)"; mv "$TMP/race-hold" "$TMP/race-root/.agent-state-$(id -u)"
uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root" >/dev/null
# The racer then fuzzes the same oracle across mid-flight flips. Its published
# phase must never OUTLIVE the state it names, or the verdict below becomes a
# machine-speed measurement instead of a correctness one. The first edition
# published `link-N`/`dir-N` only AFTER the matching state change, so a racer
# descheduled between restoring the real directory and its `dir-N` write left
# `link-N` published over a real directory: a validation that then succeeded --
# correctly, the directory was genuinely back -- looked like a success spanning
# the symlink, and the row red on a slow machine with the code untouched.
# Injecting a 0.35s stall at exactly that point (what a loaded machine adds
# there) red the old row 31 times in 60 iterations. Publishing `busy-N` BEFORE
# each mutation makes `link-N` observable only while the symlink is really
# installed, so `link-N` at both ends now means the symlink stood throughout.
printf 'busy-0\n' >"$TMP/race-phase"
race_phase_publish() { printf '%s\n' "$1" >"$TMP/race-phase.tmp"; mv "$TMP/race-phase.tmp" "$TMP/race-phase"; }
(
  for i in $(seq 1 150); do
    race_phase_publish "busy-$i"
    mv "$TMP/race-root/.agent-state-$(id -u)" "$TMP/race-hold" 2>/dev/null || continue
    ln -s "$TMP/race-outside" "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
    race_phase_publish "link-$i"
    command sleep 0.002
    race_phase_publish "busy-$i"
    rm "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
    mv "$TMP/race-hold" "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
    race_phase_publish "dir-$i"
  done
) & RACE_PID=$!
RACE_LINK_SPANS=0
for _ in $(seq 1 150); do
  BEFORE_PHASE="$(cat "$TMP/race-phase")"; RC=1
  uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root" >/dev/null 2>&1 && RC=0 || true
  AFTER_PHASE="$(cat "$TMP/race-phase")"
  case "$BEFORE_PHASE" in
    link-*)
      # Same `link-N` at both ends means the racer published nothing in between,
      # so the symlink stood for the entire call. Any other pair means the state
      # churned and either verdict is legitimate.
      if [ "$BEFORE_PHASE" = "$AFTER_PHASE" ]; then
        RACE_LINK_SPANS=$((RACE_LINK_SPANS + 1))
        [ "$RC" -ne 0 ] || fail 'symlink race' "validate succeeded across an uninterrupted $BEFORE_PHASE"
      fi
      ;;
  esac
done
wait "$RACE_PID"; RACE_PID=''
# Reported, never asserted on. How many spans a run catches is a property of the
# scheduler, so any floor here would be exactly the resource-dependent count
# this file was cleaned of; the held-symlink case above is what guarantees the
# same oracle runs every time. A fast host typically reports 0 -- lengthening
# the symlink hold to 0.35s reports ~130, and reds immediately against a
# symlink-permissive build.
printf 'route-context: symlink race observed %s validation(s) spanning an uninterrupted symlink phase\n' "$RACE_LINK_SPANS"
uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root" >/dev/null

# Repeated isolated resolution leaves a copied runtime byte-for-byte unchanged.
mkdir -p "$TMP/runtime/lib" "$TMP/runtime/policy"
cp "$ROOT/plugins/uberdev/lib/agent-dispatch.sh" "$ROOT/plugins/uberdev/lib/model_routing.py" "$ROOT/plugins/uberdev/lib/live-semaphore.sh" "$ROOT/plugins/uberdev/lib/run_manifest.py" "$TMP/runtime/lib/"
cp "$ROOT/plugins/uberdev/policy/model-routing-v1.json" "$TMP/runtime/policy/"
BEFORE="$(find "$TMP/runtime" -type f -exec shasum -a 256 {} + | sort)"
( . "$TMP/runtime/lib/agent-dispatch.sh"
  uberdev_agent_resolve_request '{"backend":"workflow","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[]}' >/dev/null
  uberdev_agent_resolve_request '{"backend":"workflow","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[]}' >/dev/null
  # The refusal path must be as side-effect-free as the accept path.
  uberdev_agent_resolve_request '{"backend":"workflow","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"adaptive"}' >/dev/null 2>&1 || true )
AFTER="$(find "$TMP/runtime" -type f -exec shasum -a 256 {} + | sort)"
[ "$BEFORE" = "$AFTER" ]
[ ! -d "$TMP/runtime/lib/__pycache__" ]
BAD='{"backend":"workflow","workflow":"solve","role":"plan-writer","task_tier":"small","risk_signals":[],"routing_mode":""}'
assert_refused 'an empty routing_mode is refused' "$TMP/error" uberdev_agent_resolve_request "$BAD"
assert_absent 'the refusal leaks no filesystem path' "$TMP" "$TMP/error"
# NB: this was a hardcoded literal, never a counter. It is now a plain verdict
# rather than a number the file does not actually compute.
echo 'route-context: PASS'

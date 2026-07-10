#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LIB="$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; mkdir -p "$TMP/run"
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
REQ='{"schema_version":1,"run_dir":"'"$TMP/run"'","run_id":"root-1","repository_id":"repo","backend":"codex","workflow":"solve","phase":"plan","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"adaptive","issue_or_pr":7,"issue_num":7,"capacity":2,"timeout_s":30}'
DECISION="$(uberdev_agent_resolve_request "$REQ")"
python3 - "$DECISION" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d['logical_route']=='frontier'; assert d['reasoning_effort']=='max'
PY
[ ! -e "$TMP/run/.agent-state-$(id -u)" ]
PROV='{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}'
META='{"run_id":"root-1","repository_id":"repo","workflow":"solve","backend":"codex","issue_num":7,"task_tier":"medium","risk_signals":[]}'
OUT="$(uberdev_agent_context_create "$TMP/run" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"
CTX="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$OUT")"
SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$OUT")"
[ "$(stat -f '%Lp' "$CTX" 2>/dev/null || stat -c '%a' "$CTX")" = 600 ]
uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run" >/dev/null
cp "$CTX" "$TMP/copy"; printf 'x' >> "$CTX"; ! uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run" >/dev/null 2>&1; mv "$TMP/copy" "$CTX"; chmod 600 "$CTX"
ln "$CTX" "$TMP/hard"; ! uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run" >/dev/null 2>&1; rm "$TMP/hard"
mv "$CTX" "$TMP/real"; ln -s "$TMP/real" "$CTX"; ! uberdev_agent_context_validate "$CTX" "$SHA" "$TMP/run" >/dev/null 2>&1
# Restore the immutable context, then prove a decision mismatch is rejected
# before lifecycle publication, lease acquisition, or the provider boundary.
rm "$CTX"; mv "$TMP/real" "$CTX"; chmod 600 "$CTX"
BAD_CONTEXT_REQ="$(python3 - "$REQ" "$CTX" "$SHA" "$DECISION" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); r['context_file']=sys.argv[2]; r['context_sha256']=sys.argv[3]; r['root_decision']=json.loads(sys.argv[4]); r['task_tier']='small'; print(json.dumps(r,separators=(',',':')))
PY
)"
_uberdev_agent_dispatch_backend() { printf invoked >"$TMP/provider-invoked"; return 1; }
export -f _uberdev_agent_dispatch_backend
printf prompt >"$TMP/run/prompt.txt"
! uberdev_agent_dispatch "$BAD_CONTEXT_REQ" "$TMP/run/prompt.txt" "$TMP/run/result.md" "$TMP/run/status.json" >/dev/null 2>"$TMP/mismatch-error"
grep -q route_context_mismatch "$TMP/mismatch-error"
[ ! -e "$TMP/provider-invoked" ]
[ ! -e "$TMP/run/.agent-state-$(id -u)/agent-lifecycle.jsonl" ]
# The solve dispatch seam keeps CLI, raw environment, and project layers
# separate instead of promoting resolved config into explicit CLI fields.
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/assembled.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=codex UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 \
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
# Invalid config-backed environment values must not be forwarded after the
# config reader has fallen back; concrete route/model/effort remain raw inputs.
(
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_agent_dispatch() { printf '%s' "$1" >"$TMP/invalid-assembled.json"; return 0; }
  UBERDEV_RESOLVED_BACKEND=codex UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 \
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
  UBERDEV_RESOLVED_BACKEND=codex UBERDEV_TMPDIR="$TMP/run" SOLVE_TIMEOUT=30 UBERDEV_MODEL_ROUTING_MODE=adaptive \
    UBERDEV_MODEL_ROUTING_RISK_ESCALATION=bogus UBERDEV_AGENT_ROLE=plan-writer UBERDEV_AGENT_PHASE=plan UBERDEV_AGENT_RISK_SIGNALS_JSON='["security"]' \
    uberdev_dispatch_one 7 small "$TMP/run/prompt.txt" 2>/dev/null
)
INVALID_RISK_DECISION="$(uberdev_agent_resolve_request "$(cat "$TMP/invalid-risk.json")")"
python3 - "$INVALID_RISK_DECISION" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); assert d['logical_route']=='ultra',d
PY
# Non-Codex backends reject every environment concrete/service pin, while
# ambient inherit does not consult an unrelated unsafe Codex catalog.
for key in UBERDEV_ROUTE UBERDEV_MODEL UBERDEV_REASONING_EFFORT UBERDEV_SERVICE_TIER; do
  VALUE=deep; [ "$key" != UBERDEV_MODEL ] || VALUE=gpt-5.6-sol; [ "$key" != UBERDEV_REASONING_EFFORT ] || VALUE=high; [ "$key" != UBERDEV_SERVICE_TIER ] || VALUE=fast
  PINNED="$(python3 - "$key" "$VALUE" <<'PY'
import json,sys
print(json.dumps({'backend':'background','workflow':'solve','role':'lead','task_tier':'small','risk_signals':[],'environment':{sys.argv[1]:sys.argv[2]}},separators=(',',':')))
PY
)"
  ! uberdev_agent_resolve_request "$PINNED" >/dev/null 2>"$TMP/noncodex-$key.err"
  grep -q route_unenforceable "$TMP/noncodex-$key.err"
done
UBERDEV_MODEL_CATALOG_FILE="$TMP/missing-catalog" uberdev_agent_resolve_request '{"backend":"background","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[]}' >/dev/null

# Recursive request shapes are closed and secret-shaped nested keys fail.
for payload in \
  '{"backend":"codex","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"environment":{"AWS_SECRET_ACCESS_KEY":"x"}}' \
  '{"backend":"codex","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"environment":{"SURPRISE":"x"}}' \
  '{"backend":"codex","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"project_routing":{"surprise":true}}' \
  '{"backend":"codex","workflow":"solve","role":"lead","task_tier":"small","risk_signals":[],"parent_run":{"surprise":"x"}}'; do
  ! uberdev_agent_resolve_request "$payload" >/dev/null 2>"$TMP/nested.err"
done

# Context creation validates the complete closed schema before state mutation.
mkdir "$TMP/schema-root"
for kind in request decision provenance metadata created; do
  R="$REQ"; D="$DECISION"; P="$PROV"; M="$META"; C='2026-07-10T00:00:00Z'
  case "$kind" in
    request) R="$(python3 -c 'import json,sys;r=json.loads(sys.argv[1]);r["surprise"]=1;print(json.dumps(r))' "$REQ")" ;;
    decision) D='{"surprise":true}' ;;
    provenance) P='{"surprise":{"source":"env","file":null}}' ;;
    metadata) M='{"run_id":"root-1","repository_id":"repo","workflow":"solve","backend":"codex","issue_num":7,"task_tier":"gigantic","risk_signals":["AWS_SECRET_ACCESS_KEY"]}' ;;
    created) C='' ;;
  esac
  ! uberdev_agent_context_create "$TMP/schema-root" "$R" "$D" "$P" "$M" "$C" >/dev/null 2>"$TMP/schema-$kind.err"
  [ ! -e "$TMP/schema-root/.agent-state-$(id -u)" ]
done

# A state-directory ancestor cannot be replaced by a symlink outside run root.
mkdir "$TMP/escape-root"
ESC="$(uberdev_agent_context_create "$TMP/escape-root" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"
ESC_FILE="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$ESC")"; ESC_SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$ESC")"
mv "$TMP/escape-root/.agent-state-$(id -u)" "$TMP/escaped-state"; ln -s "$TMP/escaped-state" "$TMP/escape-root/.agent-state-$(id -u)"
! uberdev_agent_context_validate "$ESC_FILE" "$ESC_SHA" "$TMP/escape-root" >/dev/null 2>&1
# Race the state entry between its owned directory and an outside symlink. A
# validation that begins and ends on the symlink must never succeed.
mkdir "$TMP/race-root"
RACE="$(uberdev_agent_context_create "$TMP/race-root" "$REQ" "$DECISION" "$PROV" "$META" '2026-07-10T00:00:00Z')"; RACE_FILE="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_file"])' "$RACE")"; RACE_SHA="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["context_sha256"])' "$RACE")"
cp -R "$TMP/race-root/.agent-state-$(id -u)" "$TMP/race-outside"
(
  for _ in $(seq 1 150); do
    mv "$TMP/race-root/.agent-state-$(id -u)" "$TMP/race-hold" 2>/dev/null || continue
    ln -s "$TMP/race-outside" "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
    rm "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
    mv "$TMP/race-hold" "$TMP/race-root/.agent-state-$(id -u)" 2>/dev/null || true
  done
) & RACE_PID=$!
for _ in $(seq 1 150); do
  BEFORE_LINK=0; AFTER_LINK=0; RC=1
  [ ! -L "$TMP/race-root/.agent-state-$(id -u)" ] || BEFORE_LINK=1
  uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root" >/dev/null 2>&1 && RC=0 || true
  [ ! -L "$TMP/race-root/.agent-state-$(id -u)" ] || AFTER_LINK=1
  [ "$BEFORE_LINK:$AFTER_LINK:$RC" != 1:1:0 ]
done
wait "$RACE_PID"
uberdev_agent_context_validate "$RACE_FILE" "$RACE_SHA" "$TMP/race-root" >/dev/null

# Repeated isolated resolution leaves a copied runtime byte-for-byte unchanged.
mkdir -p "$TMP/runtime/lib" "$TMP/runtime/policy"
cp "$ROOT/plugins/uberdev/lib/agent-dispatch.sh" "$ROOT/plugins/uberdev/lib/model_routing.py" "$ROOT/plugins/uberdev/lib/live-semaphore.sh" "$ROOT/plugins/uberdev/lib/run_manifest.py" "$TMP/runtime/lib/"
cp "$ROOT/plugins/uberdev/policy/model-routing-v1.json" "$TMP/runtime/policy/"
BEFORE="$(find "$TMP/runtime" -type f -exec shasum -a 256 {} + | sort)"
( . "$TMP/runtime/lib/agent-dispatch.sh"; uberdev_agent_resolve_request '{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"adaptive"}' >/dev/null; uberdev_agent_resolve_request '{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"medium","risk_signals":[],"routing_mode":"adaptive"}' >/dev/null )
AFTER="$(find "$TMP/runtime" -type f -exec shasum -a 256 {} + | sort)"
[ "$BEFORE" = "$AFTER" ]
[ ! -d "$TMP/runtime/lib/__pycache__" ]
BAD='{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"small","risk_signals":[],"routing_mode":""}'
! uberdev_agent_resolve_request "$BAD" >/dev/null 2>"$TMP/error"
! grep -q "$TMP" "$TMP/error"
echo 'route-context: 63 checks passed'

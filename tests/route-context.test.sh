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
BAD='{"backend":"codex","workflow":"solve","role":"plan-writer","task_tier":"small","risk_signals":[],"routing_mode":""}'
! uberdev_agent_resolve_request "$BAD" >/dev/null 2>"$TMP/error"
! grep -q "$TMP" "$TMP/error"
echo 'route-context: 32 checks passed'

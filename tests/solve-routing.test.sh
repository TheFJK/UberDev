#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/plugins/uberdev/lib/solve_triage.py"
PASS=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
parse() { python3 -I "$TOOL" parse-cli "$@"; }
expect_ok() {
  local out="$1" expr="$2"
  python3 - "$out" "$expr" <<'PY'
import json,sys
v=json.loads(sys.argv[1]); assert eval(sys.argv[2],{}, {"v":v}),v
PY
  PASS=$((PASS+1))
}
expect_bad() {
  local needle="$1"; shift
  if parse "$@" > /tmp/solve-routing-out.$$ 2>/tmp/solve-routing-err.$$; then echo "FAIL accepted: $*" >&2; exit 1; fi
  grep -q "$needle" /tmp/solve-routing-err.$$
  rm -f /tmp/solve-routing-{out,err}.$$
  PASS=$((PASS+1))
}

OUT="$(parse 9 3 9 --routing-mode=adaptive --service-tier=fast)"
expect_ok "$OUT" 'v["issues"]==[9,3] and v["routing_mode"]=="adaptive" and v["service_tier"]=="fast"'
OUT="$(parse --backend=codex 9)"
expect_ok "$OUT" 'v["issues"]==[9] and v["backend"]=="codex"'

# RFC 0015 regression guard. `workflow` is the backend `auto` resolves to on every
# Claude host, and /goal's driver passes it EXPLICITLY. This whitelist is the first
# gate lib/solve-launcher.sh runs (:87), so omitting the name here failed every
# /goal cycle at dispatch while the default `auto` path kept working — which is why
# it shipped unnoticed. The two asserts below pin the accept, and the loop pins the
# whitelist against lib/dispatch.sh's enum so the two can never drift again.
OUT="$(parse --backend=workflow 9)"
expect_ok "$OUT" 'v["issues"]==[9] and v["backend"]=="workflow"'
OUT="$(parse 9 --backend=workflow)"
expect_ok "$OUT" 'v["issues"]==[9] and v["backend"]=="workflow"'

DISPATCH_ENUM_LINE="$(grep -m1 "^_UBERDEV_DISPATCH_BACKEND_ENUM=" "$ROOT/plugins/uberdev/lib/dispatch.sh")"
DISPATCH_ENUM="${DISPATCH_ENUM_LINE#*=\'}"; DISPATCH_ENUM="${DISPATCH_ENUM%\'}"
if [ -z "$DISPATCH_ENUM" ]; then
  echo "  FAIL  could not read _UBERDEV_DISPATCH_BACKEND_ENUM from lib/dispatch.sh"
  FAIL=$((FAIL + 1))
else
  ENUM_OK=1
  OLD_IFS="$IFS"; IFS='|'
  for _backend in $DISPATCH_ENUM; do
    IFS="$OLD_IFS"
    if ! parse "--backend=$_backend" 9 >/dev/null 2>&1; then
      echo "  FAIL  dispatch.sh offers --backend=$_backend but solve_triage.py parse-cli rejects it"
      ENUM_OK=0
    fi
    IFS='|'
  done
  IFS="$OLD_IFS"
  if [ "$ENUM_OK" = "1" ]; then
    echo "  PASS  every backend in _UBERDEV_DISPATCH_BACKEND_ENUM survives parse-cli"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
fi
OUT="$(parse 1 --route=sol-ultra --fast)"
expect_ok "$OUT" 'v["route"]=="sol-ultra" and v["service_tier"]=="fast"'
OUT="$(parse 1 --fast --service-tier=fast)"
expect_ok "$OUT" 'v["service_tier"]=="fast"'
OUT="$(parse 1 --model=gpt-5.6-sol --effort=ultra --backend=codex)"
expect_ok "$OUT" 'v["model"]=="gpt-5.6-sol" and v["effort"]=="ultra"'

expect_bad routing_cli_duplicate 1 --route=sol --route=terra
expect_bad routing_cli_duplicate 1 --fast --fast
expect_bad routing_cli_conflict 1 --routing-mode=adaptive --route=sol
expect_bad routing_cli_conflict 1 --route=sol --effort=high
expect_bad routing_cli_conflict 1 --fast --service-tier=default
expect_bad routing_cli_invalid 1 --route=made-up
expect_bad routing_cli_invalid 1 --effort=extreme
expect_bad routing_cli_invalid 1 --service-tier=premium
expect_bad routing_cli_invalid 1 --routing-mode=shadow
expect_bad routing_cli_invalid 0
expect_bad routing_cli_unrecognized 1 --rout=sol

# Contract is visibly threaded through the executable launcher, not docs only.
grep -q 'solve_triage.py' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'parse-cli' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'UBERDEV_DISPATCH_ROUTING_MODE' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
grep -q 'no claims written; no agents dispatched' "$ROOT/plugins/uberdev/lib/solve-launcher.sh"
PASS=$((PASS+4))

# Root preparation resolves through the shared adapter and persists a verified
# context without invoking a provider.
RUN="$TMP/run"; mkdir -p "$RUN"
(
  export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" UBERDEV_TMPDIR="$RUN"
  export UBERDEV_RESOLVED_BACKEND=codex UBERDEV_DISPATCH_ROUTING_MODE=adaptive
  export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{"routing_mode":"inherit","issue_num":999}'
  # shellcheck source=/dev/null
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_dispatch_prepare_root 42 large '["security"]' turbo '{"schema_version":1,"issue":42,"raw_tier":"large","clamped_tier":"large","effective_tier":"large","tier":"large","source":"computed","matched_rules":["large-label:architectural","large:multi-component-high-risk"],"risk_signals":["security"],"file_count":2,"files":["api/b.py","auth/a.py"],"component_count":2,"components":["api","auth"]}'
) >"$TMP/prepared.json"
python3 - "$TMP/prepared.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r["workflow"]=="turbo" and r["issue_num"]==42 and r["task_tier"]=="large"
assert r["risk_signals"]==["security"]
assert pathlib.Path(r["context_file"]).is_file() and len(r["context_sha256"])==64
assert r["root_decision"]["backend"]=="codex"
context=json.loads(pathlib.Path(r["context_file"]).read_text())
triage=context["metadata"]["triage_decision"]
assert triage["matched_rules"]==["large-label:architectural","large:multi-component-high-risk"]
assert triage["raw_tier"]==triage["clamped_tier"]==triage["effective_tier"]=="large"
PY
PASS=$((PASS+1))

# Batch root validation is all-or-nothing: issue 1 resolves, issue 2's forced
# route is below its high-risk floor, and no claim/provider mutation occurs.
BATCH_BIN="$TMP/batch-bin"; mkdir "$BATCH_BIN"
cat >"$BATCH_BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$BATCH_GH_LOG"
case "$1 $2" in
  "repo view") echo owner/repo ;;
  "issue view")
    if [ "$3" = 1 ]; then echo '{"number":1,"title":"README typo","state":"OPEN","body":"Fix typo in README.md.","labels":[{"name":"docs"}],"assignees":[],"comments":[]}'
    else echo '{"number":2,"title":"Authorization race","state":"OPEN","body":"Security authorization concurrency spans auth/a.py and api/b.py.","labels":[{"name":"security"}],"assignees":[],"comments":[]}'
    fi ;;
  *) echo mutation >>"$BATCH_MUTATIONS"; exit 3 ;;
esac
SH
cat >"$BATCH_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo dispatched >>"$BATCH_MUTATIONS"; exit 3
SH
chmod +x "$BATCH_BIN/gh" "$BATCH_BIN/codex"
if PATH="$BATCH_BIN:$PATH" BATCH_GH_LOG="$TMP/batch-gh" BATCH_MUTATIONS="$TMP/batch-mutations" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 1 2 --backend=codex --route=terra >"$TMP/batch.out" 2>&1; then
  echo "FAIL: mixed-validity route batch unexpectedly succeeded" >&2; exit 1
fi
grep -q '#2 routing/context validation failed' "$TMP/batch.out"
[ ! -s "$TMP/batch-mutations" ]
! grep -Eq '^label create|^issue edit|^issue comment' "$TMP/batch-gh"
PASS=$((PASS+1))

: >"$TMP/batch-mutations"
if PATH="$BATCH_BIN:$PATH" BATCH_GH_LOG="$TMP/inverted-gh" BATCH_MUTATIONS="$TMP/batch-mutations" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  SOLVE_TIER_FLOOR=large SOLVE_TIER_CEILING=small \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 1 2 --backend=codex --routing-mode=adaptive >"$TMP/inverted.out" 2>&1; then
  echo "FAIL: deliberate label failure unexpectedly succeeded" >&2; exit 1
fi
[ "$(grep -c floor_gt_ceiling "$TMP/inverted.out")" -eq 1 ]
PASS=$((PASS+1))

# Nested/unbounded triage payloads fail before context/state mutation.
BAD_ROOT="$TMP/bad-context"; mkdir "$BAD_ROOT"; chmod 700 "$BAD_ROOT"
(
  . "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
  REQ='{"backend":"codex","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"triage_decision":{"secret":{"nested":"value"}}}'
  DEC="$(uberdev_agent_resolve_request "$REQ")"
  PROV='{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}'
  META='{"run_id":"bad-triage","repository_id":"repo","workflow":"solve","backend":"codex","issue_num":7,"task_tier":"small","risk_signals":[],"triage_decision":{"secret":{"nested":"value"}}}'
  ! uberdev_agent_context_create "$BAD_ROOT" "$REQ" "$DEC" "$PROV" "$META" '2026-07-10T00:00:00Z' >/dev/null 2>&1
)
[ ! -e "$BAD_ROOT/.agent-state-$(id -u)" ]; PASS=$((PASS+1))

cmp "$ROOT/plugins/uberdev/lib/dispatch.sh" "$ROOT/codex/uberdev-codex/lib/dispatch.sh"
if sed -n '/^[[:space:]]*case "\$os_class" in/,/^[[:space:]]*esac/p' "$ROOT/plugins/uberdev/lib/dispatch.sh" \
    | grep -q 'windows-native) return 2'; then
  echo 'solve-routing: unreachable nested windows-native auto arm remains' >&2
  exit 1
fi
cmp "$ROOT/plugins/uberdev/lib/solve-launcher.sh" "$ROOT/codex/uberdev-codex/lib/solve-launcher.sh"
cmp "$ROOT/plugins/uberdev/lib/solve_triage.py" "$ROOT/codex/uberdev-codex/lib/solve_triage.py"
PASS=$((PASS+3))

# Default shared /tmp gets a private owned launch root; classification and
# context creation complete before the deliberately failing claim write.
FAKE="$TMP/bin"; mkdir "$FAKE"
cat >"$FAKE/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") printf '%s\n' 'owner/repo' ;;
  "issue view") printf '%s\n' '{"number":77,"title":"README typo","state":"OPEN","body":"Fix typo in README.md.","labels":[{"name":"docs"}],"assignees":[],"comments":[]}' ;;
  "label create")
    echo claim-write-attempt >>"$GH_MUTATIONS"; printf '%s' "$UBERDEV_TMPDIR" >"$OBSERVED_ROOT"
    python3 - "$UBERDEV_TMPDIR" <<'PY'
import glob,os,stat,sys
e=os.stat(sys.argv[1],follow_symlinks=False)
assert e.st_uid==os.geteuid() and stat.S_IMODE(e.st_mode)==0o700
assert glob.glob(sys.argv[1]+"/.agent-state-*/route-context-v1-*.json")
PY
    exit 1 ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
SH
cat >"$FAKE/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE/gh" "$FAKE/codex"
SHARED_TMP="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
BEFORE="$(find "$SHARED_TMP" -maxdepth 1 -type d -name "uberdev-solve-$(id -u)-*" 2>/dev/null | sort)"
set +e
PATH="$FAKE:$PATH" GH_MUTATIONS="$TMP/mutations" OBSERVED_ROOT="$TMP/observed-root" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 77 --backend=codex --routing-mode=adaptive >"$TMP/launch.out" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ]; grep -q "failed to provision" "$TMP/launch.out"; [ "$(cat "$TMP/mutations")" = claim-write-attempt ]
OBSERVED="$(cat "$TMP/observed-root")"; [ -n "$OBSERVED" ]
AFTER="$(find "$SHARED_TMP" -maxdepth 1 -type d -name "uberdev-solve-$(id -u)-*" 2>/dev/null | sort)"
NEW_ROOT="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | tail -1)"
[ -z "$NEW_ROOT" ]
[ ! -e "$OBSERVED" ]
[ ! -e /tmp/solve-validate-77.json ]
PASS=$((PASS+1))

echo "solve-routing: $PASS passed"

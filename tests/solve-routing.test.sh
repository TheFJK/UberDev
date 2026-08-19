#!/usr/bin/env bash
set -euo pipefail
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/plugins/uberdev/lib/solve_triage.py"
PASS=0
# `set -u` is on and the two `FAIL=$((FAIL + 1))` arms below were the only
# mentions of this counter -- unset, they crashed the run instead of reporting
# the failure they exist to report. Initialising it alone would be WORSE than the
# crash: nothing read the counter, so a real failure would print its line and
# then exit 0. Both halves are needed -- initialise here, and gate the exit code
# on it at the bottom of the file. New cases use PASS and never that idiom.
FAIL=0
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
# RETIRED SURFACE (#381): `--backend=codex` used to PARSE here. It is out of
# the parser allowlist (lib/solve_triage.py:414) in lockstep with
# _UBERDEV_DISPATCH_BACKEND_ENUM, so the flag must now be refused at the very
# first gate lib/solve-launcher.sh runs, not survive to die in the resolver.
expect_bad routing_cli_invalid --backend=codex 9
OUT="$(parse --backend=background 9)"
expect_ok "$OUT" 'v["issues"]==[9] and v["backend"]=="background"'

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
# #381: backend retargeted off the retired codex transport; this line is about
# --model/--effort parsing, and the backend it rides on is incidental.
OUT="$(parse 1 --model=gpt-5.6-sol --effort=ultra --backend=background)"
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
  # #381: `codex` is gone and `adaptive` is unenforceable on every surviving
  # backend (lib/agent-dispatch.sh:298 gates the concrete-route resolver behind
  # `backend!="codex"`), so this fixture rides the live `background` backend on
  # the inherit path. What it asserts -- root prep resolves through the shared
  # adapter and persists a verified context WITHOUT invoking a provider -- is
  # backend-neutral and unchanged.
  export UBERDEV_RESOLVED_BACKEND=background
  export UBERDEV_AGENT_PREPARED_REQUEST_JSON='{"routing_mode":"inherit","issue_num":999}'
  # shellcheck source=/dev/null
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  uberdev_dispatch_prepare_root 42 medium '["security"]' turbo '{"schema_version":1,"issue":42,"raw_tier":"medium","clamped_tier":"medium","effective_tier":"medium","tier":"medium","source":"computed","matched_rules":["medium:fallback"],"risk_signals":["security"],"file_count":2,"files":["api/b.py","auth/a.py"],"component_count":2,"components":["api","auth"]}'
) >"$TMP/prepared.json"
python3 - "$TMP/prepared.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r["workflow"]=="turbo" and r["issue_num"]==42 and r["task_tier"]=="medium"
assert r["risk_signals"]==["security"]
assert pathlib.Path(r["context_file"]).is_file() and len(r["context_sha256"])==64
assert r["root_decision"]["backend"]=="background"
context=json.loads(pathlib.Path(r["context_file"]).read_text())
triage=context["metadata"]["triage_decision"]
assert triage["matched_rules"]==["medium:fallback"]
assert triage["raw_tier"]==triage["clamped_tier"]==triage["effective_tier"]=="medium"
PY
PASS=$((PASS+1))

# Batch root validation is all-or-nothing: one unenforceable root aborts the
# whole batch, and no claim/provider mutation occurs.
#
# #381: this used to read "issue 1 resolves, issue 2's forced route is below its
# high-risk floor" on `--backend=codex`. COVERAGE DELIBERATELY NARROWED: the
# MIXED-validity shape (one root valid, one invalid) is no longer reproducible,
# because the concrete-route resolver lives behind agent-dispatch.sh:298's
# `if backend!="codex":` gate and no surviving backend can enter it -- ANY
# --route= is now route_unenforceable everywhere, so #1 fails first. The
# all-or-nothing property itself, which is what this fixture exists for, is
# fully preserved and still asserted below (zero mutations, zero claim writes).
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
# A poisoned `claude` (the provider every surviving backend execs) stands in for
# the poisoned `codex` this used to plant: reaching a provider at all is the
# mutation this fixture forbids.
cat >"$BATCH_BIN/claude" <<'SH'
#!/usr/bin/env bash
# The launcher version-probes `claude` before any routing work
# (lib/solve-launcher.sh:137). Answer that honestly; ANY other invocation is a
# provider launch, which is exactly the mutation this fixture forbids.
if [ "$1" = --version ]; then echo "2.1.152 (Claude Code)"; exit 0; fi
echo dispatched >>"$BATCH_MUTATIONS"; exit 3
SH
chmod +x "$BATCH_BIN/gh" "$BATCH_BIN/claude"
if PATH="$BATCH_BIN:$PATH" BATCH_GH_LOG="$TMP/batch-gh" BATCH_MUTATIONS="$TMP/batch-mutations" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 1 2 --backend=background --route=terra >"$TMP/batch.out" 2>&1; then
  echo "FAIL: mixed-validity route batch unexpectedly succeeded" >&2; exit 1
fi
grep -q '#1 routing/context validation failed' "$TMP/batch.out"
[ ! -s "$TMP/batch-mutations" ]
! grep -Eq '^label create|^issue edit|^issue comment' "$TMP/batch-gh"
PASS=$((PASS+1))

: >"$TMP/batch-mutations"
if PATH="$BATCH_BIN:$PATH" BATCH_GH_LOG="$TMP/inverted-gh" BATCH_MUTATIONS="$TMP/batch-mutations" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  SOLVE_TIER_FLOOR=medium SOLVE_TIER_CEILING=small \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 1 2 --backend=background --routing-mode=adaptive >"$TMP/inverted.out" 2>&1; then
  echo "FAIL: deliberate label failure unexpectedly succeeded" >&2; exit 1
fi
[ "$(grep -c floor_gt_ceiling "$TMP/inverted.out")" -eq 1 ]
PASS=$((PASS+1))

# Nested/unbounded triage payloads fail before context/state mutation.
BAD_ROOT="$TMP/bad-context"; mkdir "$BAD_ROOT"; chmod 700 "$BAD_ROOT"
(
  . "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
  REQ='{"backend":"background","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"triage_decision":{"secret":{"nested":"value"}}}'
  DEC="$(uberdev_agent_resolve_request "$REQ")"
  PROV='{"mode":{"source":"default","file":null},"service_tier":{"source":"default","file":null},"risk_escalation":{"source":"default","file":null},"adaptive_fallback":{"source":"default","file":null},"shadow":{"source":"default","file":null},"workflows":{"source":"default","file":null},"roles":{"source":"default","file":null}}'
  META='{"run_id":"bad-triage","repository_id":"repo","workflow":"solve","backend":"background","issue_num":7,"task_tier":"small","risk_signals":[],"triage_decision":{"secret":{"nested":"value"}}}'
  ! uberdev_agent_context_create "$BAD_ROOT" "$REQ" "$DEC" "$PROV" "$META" '2026-07-10T00:00:00Z' >/dev/null 2>&1
)
[ ! -e "$BAD_ROOT/.agent-state-$(id -u)" ]; PASS=$((PASS+1))

if grep -q 'windows-native) return 2' \
    <<<"$(sed -n '/^[[:space:]]*case "\$os_class" in/,/^[[:space:]]*esac/p' "$ROOT/plugins/uberdev/lib/dispatch.sh")"; then
  echo 'solve-routing: unreachable nested windows-native auto arm remains' >&2
  exit 1
fi
PASS=$((PASS+1))

# Default shared /tmp gets a private owned launch root; classification and
# context creation complete before the deliberately failing claim write.
#
# #381: `--backend=codex --routing-mode=adaptive` became `--backend=background`
# on the inherit path. This fixture has to REACH the claim write to prove the
# launch root is private and owned; adaptive routing is route_unenforceable on
# every surviving backend, so keeping the flag would abort before provisioning
# and the assertion below would pass vacuously against the wrong failure.
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
cat >"$FAKE/claude" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo "2.1.152 (Claude Code)"; exit 0; fi
exit 0
SH
chmod +x "$FAKE/gh" "$FAKE/claude"
SHARED_TMP="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
BEFORE="$(find "$SHARED_TMP" -maxdepth 1 -type d -name "uberdev-solve-$(id -u)-*" 2>/dev/null | sort)"
set +e
PATH="$FAKE:$PATH" GH_MUTATIONS="$TMP/mutations" OBSERVED_ROOT="$TMP/observed-root" TMPDIR=/tmp CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" \
  bash "$ROOT/plugins/uberdev/lib/solve-launcher.sh" --auto-mode=0 -- 77 --backend=background >"$TMP/launch.out" 2>&1
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

# X1 (#532): an ESCALATED decision survives the routing-context validator.
#
# The producer and the validator are independent copies of one vocabulary:
# solve_triage.py emits `matched_rules`, lib/agent-dispatch.sh checks every entry
# against a closed `allowed_rule` alternation. A token emitted but not allowed
# makes uberdev_agent_context_create fail with route_context_create_failed, which
# does not decline one issue -- it aborts the ENTIRE batch, so every sibling in
# the same /solve, /turbo or /ubergoal run dies with it. `escalation-label:` is a
# NEW member of that vocabulary, so it needs the end-to-end assertion here and
# not only the containment check in tests/triage-rule-vocabulary.py: this is the
# call the launcher actually makes.
ESC_DECISION="$(python3 -I "$TOOL" classify --snapshot "$ROOT/tests/fixtures/solve-routing/escalated-trivial.json")"
ESC_FINAL="$(python3 -I "$TOOL" finalize --decision "$ESC_DECISION" --clamped medium)"
case "$ESC_FINAL" in
  *escalation-label:medium*) ;;
  *) echo "FAIL: escalated fixture carried no escalation-label token: $ESC_FINAL" >&2; exit 1 ;;
esac
ESC_RUN="$TMP/esc-run"; mkdir -p "$ESC_RUN"
(
  export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/uberdev" UBERDEV_TMPDIR="$ESC_RUN"
  export UBERDEV_RESOLVED_BACKEND=background
  # shellcheck source=/dev/null
  . "$ROOT/plugins/uberdev/lib/dispatch.sh"
  # task_tier must equal the decision's effective_tier/tier and risk_signals must
  # match exactly -- agent-dispatch.sh:421 cross-checks all three.
  uberdev_dispatch_prepare_root 6 medium '[]' solve "$ESC_FINAL"
) >"$TMP/escalated-prepared.json"
python3 - "$TMP/escalated-prepared.json" <<'PY'
import json,pathlib,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert r["issue_num"]==6 and r["task_tier"]=="medium", r
assert pathlib.Path(r["context_file"]).is_file() and len(r["context_sha256"])==64, r
triage=json.loads(pathlib.Path(r["context_file"]).read_text())["metadata"]["triage_decision"]
# Verbatim round-trip: the validator neither rejected nor rewrote the token.
assert "escalation-label:medium" in triage["matched_rules"], triage
assert triage["raw_tier"]=="medium" and triage["tier"]=="medium", triage
PY
PASS=$((PASS+1))

if [ "$FAIL" -ne 0 ]; then
  echo "solve-routing: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "solve-routing: $PASS passed"

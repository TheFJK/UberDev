#!/usr/bin/env bash
# Focused tests for RFC 0013 model-routing configuration.

set -u
set -o pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/plugins/uberdev/lib/config-read.sh"
PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

_isolate() {
  local body="$1"
  local sandbox stderr
  sandbox="$(mktemp -d)"
  stderr="$(mktemp)"
  mkdir -p "$sandbox/.codex" "$sandbox/.claude"
  (
    cd "$sandbox" || exit 1
    unset UBERDEV_CONFIG_FILE CODEX_HOME
    unset UBERDEV_MODEL_ROUTING_MODE UBERDEV_SERVICE_TIER
    unset UBERDEV_ROUTE UBERDEV_MODEL UBERDEV_REASONING_EFFORT
    unset UBERDEV_MODEL_ROUTING_RISK_ESCALATION
    unset UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK
    unset UBERDEV_MODEL_ROUTING_SHADOW
    unset UBERDEV_MODEL_ROUTING_WORKFLOWS UBERDEV_MODEL_ROUTING_ROLES
    # shellcheck source=/dev/null
    . "$HELPER"
    eval "$body"
  ) 2>"$stderr"
  _STATUS=$?
  _LAST_STDERR="$(cat "$stderr")"
  rm -rf "$sandbox" "$stderr"
}

assert_resolved() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name (expected=$expected actual=$actual)"; fi
}

echo "== R1: release defaults and exported public surface =="
_isolate '
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = inherit ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = default ] || exit 1
  [ "$UBERDEV_ROUTING_RISK_ESCALATION" = true ] || exit 1
  [ "$UBERDEV_ROUTING_ADAPTIVE_FALLBACK" = true ] || exit 1
  [ "$UBERDEV_ROUTING_SHADOW" = false ] || exit 1
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{}" ] || exit 1
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  grep -q "UBERDEV_ROUTING_MODE=" <<<"$(export -p)" || exit 1
  grep -q "UBERDEV_ROUTING_ROLES=" <<<"$(export -p)" || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R1: v0.40 safe inherit defaults exported" || fail "R1: routing defaults/public exports"
[ -z "$_LAST_STDERR" ] && pass "R1: absent routing config is warning-silent" || fail "R1: absent config warned: $_LAST_STDERR"

echo
echo "== R2: .codex primary, .claude fallback, env highest =="
_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  mode: adaptive
  service_tier: fast
---
EOF
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = fast ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2a: legacy .claude routing config remains fallback" || fail "R2a: .claude fallback"

_isolate '
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  mode: adaptive
  service_tier: fast
---
EOF
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: inherit
  service_tier: flex
---
EOF
  # Source again after files are created so default-path selection observes both.
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = inherit ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = flex ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2b: .codex wins when both files exist" || fail "R2b: .codex precedence"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: inherit
  service_tier: default
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  UBERDEV_MODEL_ROUTING_MODE=adaptive UBERDEV_SERVICE_TIER=fast
  UBERDEV_ROUTE=sol-high UBERDEV_MODEL=gpt-5.6-sol UBERDEV_REASONING_EFFORT=high
  export UBERDEV_MODEL_ROUTING_MODE UBERDEV_SERVICE_TIER
  export UBERDEV_ROUTE UBERDEV_MODEL UBERDEV_REASONING_EFFORT
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = fast ] || exit 1
  [ "$UBERDEV_SERVICE_TIER" = fast ] || exit 1
  [ "$UBERDEV_ROUTE" = sol-high ] || exit 1
  [ "$UBERDEV_MODEL" = gpt-5.6-sol ] || exit 1
  [ "$UBERDEV_REASONING_EFFORT" = high ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2c: env wins without output self-shadowing" || fail "R2c: env precedence/self-shadowing"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: adaptive
  roles:
    code-reviewer: deep
---
EOF
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  service_tier: fast
  shadow: true
  workflows:
    solve: quality
solve_tier_floor: medium
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = fast ] || exit 1
  [ "$UBERDEV_ROUTING_SHADOW" = true ] || exit 1
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{\"solve\":\"quality\"}" ] || exit 1
  [ "$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium" trivial)" = medium ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2d: omitted Codex keys fall through per-key to Claude" || fail "R2d: per-key Codex/Claude complement: $_LAST_STDERR"

_isolate '
  cat > explicit.md <<EOF
---
model_routing:
  mode: adaptive
---
EOF
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  service_tier: fast
---
solve_tier_floor: medium
EOF
  UBERDEV_CONFIG_FILE="$PWD/explicit.md"
  export UBERDEV_CONFIG_FILE
  unset _UBERDEV_CONFIG_READ_LOADED
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = default ] || exit 1
  [ "$(uberdev_read_enum solve_tier_floor SOLVE_TIER_FLOOR "trivial|small|medium" trivial)" = trivial ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2e: explicit UBERDEV_CONFIG_FILE remains the sole file" || fail "R2e: explicit config isolation"

_isolate '
  cat > late-explicit.md <<EOF
---
model_routing:
  service_tier: flex
---
EOF
  # Existing callers may select their explicit file after sourcing the helper.
  UBERDEV_CONFIG_FILE="$PWD/late-explicit.md"
  export UBERDEV_CONFIG_FILE
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = flex ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2f: post-source UBERDEV_CONFIG_FILE remains explicit" || fail "R2f: late explicit config ignored"

_isolate '
  cat > explicit.md <<EOF
---
model_routing:
  service_tier: flex
---
EOF
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  service_tier: fast
---
EOF
  UBERDEV_CONFIG_FILE="$PWD/explicit.md"
  export UBERDEV_CONFIG_FILE
  unset _UBERDEV_CONFIG_READ_LOADED
  . "$HELPER"
  unset UBERDEV_CONFIG_FILE
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = fast ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R2g: unsetting explicit file restores per-key project lookup" || fail "R2g: unset explicit file remained sticky"

echo
echo "== R3: all scalar keys and validation =="
_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: adaptive
  service_tier: flex
  risk_escalation: false
  adaptive_fallback: false
  shadow: true
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = flex ] || exit 1
  [ "$UBERDEV_ROUTING_RISK_ESCALATION" = false ] || exit 1
  [ "$UBERDEV_ROUTING_ADAPTIVE_FALLBACK" = false ] || exit 1
  [ "$UBERDEV_ROUTING_SHADOW" = true ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R3a: valid scalar routing keys accepted" || fail "R3a: scalar keys"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: turbo
  service_tier: priority
  risk_escalation: yes
  adaptive_fallback: 1
  shadow: TRUE
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = inherit ] || exit 1
  [ "$UBERDEV_ROUTING_SERVICE_TIER" = default ] || exit 1
  [ "$UBERDEV_ROUTING_RISK_ESCALATION" = true ] || exit 1
  [ "$UBERDEV_ROUTING_ADAPTIVE_FALLBACK" = true ] || exit 1
  [ "$UBERDEV_ROUTING_SHADOW" = false ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R3b: malformed scalars safely default" || fail "R3b: malformed scalar defaults"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c '^warning: model_routing\..*invalid (invalid_enum); falling back to default' || true)
[ "$warn_count" -eq 5 ] && pass "R3b: exactly one existing-format warning per invalid key" || fail "R3b: expected 5 warnings, got $warn_count: $_LAST_STDERR"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: turbo
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing >/dev/null
  uberdev_read_model_routing >/dev/null
'
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.mode = 'turbo'" || true)
[ "$warn_count" -eq 1 ] && pass "R3c: sentinel emits one warning across repeated reads" || fail "R3c: warning sentinel count=$warn_count"

echo
echo "== R4: bounded role/workflow maps are data only =="
_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  workflows:
    solve: quality
    turbo:
      effort: high
      sandbox: read-only
  roles:
    triage-scout: economy
    code-reviewer:
      route: sol-high
      sandbox: read-only
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  python3 - "$UBERDEV_ROUTING_WORKFLOWS" "$UBERDEV_ROUTING_ROLES" <<PY
import json, sys
w, r = map(json.loads, sys.argv[1:])
assert w == {"solve": "quality", "turbo": {"reasoning_effort": "high", "sandbox": "read-only"}}
assert r == {"code-reviewer": {"route": "sol-high", "sandbox": "read-only"}, "triage-scout": "economy"}
PY
  request="$(python3 - "$UBERDEV_ROUTING_WORKFLOWS" "$UBERDEV_ROUTING_ROLES" <<PY
import json, sys
w, r = map(json.loads, sys.argv[1:])
print(json.dumps({"backend":"workflow","workflow":"solve","phase":"lead","role":"lead","task_tier":"small","risk_signals":[],"project_config":{"model_routing":{"workflows":w,"roles":r}}}))
PY
)"
  # RETIRED SURFACE (#381): the parsed map used to be handed to
  # model_routing.py resolve, which turned a project-workflow override into a
  # concrete logical_route. No shipped backend owns the provider invocation any
  # more, so the live consumer is uberdev_agent_resolve_request and the honest
  # outcome is a typed refusal, not a fabricated route. The bounded-JSON
  # normalization above is still the point of R4a; what changed is who reads it.
  . "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
  if decision="$(uberdev_agent_resolve_request "$request" 2>/dev/null)"; then
    echo "project override resolved instead of being refused: $decision" >&2
    exit 1
  fi
  err="$(uberdev_agent_resolve_request "$request" 2>&1 >/dev/null || true)"
  case "$err" in
    *route_unenforceable*) : ;;
    *) echo "expected route_unenforceable, got: $err" >&2; exit 1 ;;
  esac
  python3 -c "import json,sys; json.loads(sys.argv[1])" "$request"
'
[ "$_STATUS" -eq 0 ] && pass "R4a: YAML maps normalize to bounded JSON data and a project override is refused, not routed" || fail "R4a: YAML map parsing/refusal handoff: $_LAST_STDERR"

_isolate '
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":{"reasoning_effort":"ultra"}}'"'"'
  export UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":{\"reasoning_effort\":\"ultra\"}}" ] || exit 1
  request="$(python3 - "$UBERDEV_ROUTING_ROLES" <<PY
import json, sys
roles = json.loads(sys.argv[1])
print(json.dumps({"backend":"workflow","workflow":"solve","phase":"review","role":"code-reviewer","task_tier":"medium","risk_signals":[],"project_config":{"model_routing":{"roles":roles}}}))
PY
)"
  # RETIRED SURFACE (#381): this used to invoke `model_routing.py resolve` and
  # rely on a zero exit. That CLI is deleted -- and the module is still
  # executable, so an unchanged invocation would now exit 0 having done nothing
  # and the case would pass vacuously. The live consumer is the dispatch seam,
  # and it must refuse a project-supplied reasoning_effort rather than quietly
  # dropping it. The config-read half above (the effort survives parsing as an
  # independent field) is unchanged and is still the point of R4b.
  . "$ROOT/plugins/uberdev/lib/agent-dispatch.sh"
  if uberdev_agent_resolve_request "$request" >/dev/null 2>&1; then
    echo "project reasoning_effort resolved instead of being refused" >&2; exit 1
  fi
  err="$(uberdev_agent_resolve_request "$request" 2>&1 >/dev/null || true)"
  case "$err" in
    *route_unenforceable*) : ;;
    *) echo "expected route_unenforceable, got: $err" >&2; exit 1 ;;
  esac
'
[ "$_STATUS" -eq 0 ] && pass "R4b: independent reasoning_effort survives config parsing and is refused, not dropped" || fail "R4b: reasoning_effort handoff: $_LAST_STDERR"

_isolate '
  UBERDEV_MODEL_ROUTING_WORKFLOWS='"'"'{"solve":{"effort":"extreme"}}'"'"'
  export UBERDEV_MODEL_ROUTING_WORKFLOWS
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4c: invalid effort rejects the whole map" || fail "R4c: invalid effort rejection"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.workflows = '<invalid-map>'" || true)
[ "$warn_count" -eq 1 ] && pass "R4c: invalid effort warning is single/redacted" || fail "R4c: invalid effort warning count=$warn_count"

_isolate '
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-revewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4d: unknown role typo rejects" || fail "R4d: unknown role accepted"

_isolate '
  UBERDEV_MODEL_ROUTING_WORKFLOWS='"'"'{"solv":"quality"}'"'"'
  export UBERDEV_MODEL_ROUTING_WORKFLOWS
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4e: unknown workflow typo rejects" || fail "R4e: unknown workflow accepted"

_isolate '
  UBERDEV_ROUTING_POLICY_FILE="$PWD/missing-policy.json"
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_ROUTING_POLICY_FILE UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4f: unavailable explicit policy fails map closed" || fail "R4f: unavailable policy did not fail closed"

_isolate '
  printf "%s" '"'"'{"roles":{"code-reviewer":{},"code-reviewer":{}}}'"'"' > malformed-policy.json
  UBERDEV_ROUTING_POLICY_FILE="$PWD/malformed-policy.json"
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_ROUTING_POLICY_FILE UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4g: malformed/duplicate-key policy fails map closed" || fail "R4g: malformed policy accepted"

_isolate '
  python3 - "$ROOT/plugins/uberdev/policy/model-routing-v1.json" <<PY
import copy, json, pathlib, sys
base = json.loads(pathlib.Path(sys.argv[1]).read_text())
cases = {}
p = copy.deepcopy(base)
del p["routes"]["economy"]["codex"]["service_tier"]
cases["incomplete-route.json"] = p
p = copy.deepcopy(base)
p["routes"]["standard"]["rank"] = p["routes"]["economy"]["rank"]
cases["duplicate-rank.json"] = p
p = copy.deepcopy(base)
p["routes"]["standard"]["codex"] = copy.deepcopy(p["routes"]["economy"]["codex"])
cases["duplicate-pair.json"] = p
p = copy.deepcopy(base)
p["roles"]["code-reviewer"] = {"route": "deep"}
cases["malformed-role.json"] = p
p = copy.deepcopy(base)
p["routes"]["economy"]["codex"]["reasoning_effort"] = "warp"
cases["bogus-effort.json"] = p
for name, value in cases.items():
    pathlib.Path(name).write_text(json.dumps(value))
PY
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_ROLES
  for policy in incomplete-route.json duplicate-rank.json duplicate-pair.json malformed-role.json bogus-effort.json; do
    UBERDEV_ROUTING_POLICY_FILE="$PWD/$policy"
    export UBERDEV_ROUTING_POLICY_FILE
    unset UBERDEV_VALIDATED_MODEL_ROUTING_ROLES
    uberdev_read_model_routing
    [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  done
'
[ "$_STATUS" -eq 0 ] && pass "R4h: complete canonical validator rejects semantic-invalid policies" || fail "R4h: semantic-invalid policy authorized map"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
[ "$warn_count" -eq 5 ] && pass "R4h: each semantic-invalid policy emits one redacted warning" || fail "R4h: semantic policy warning count=$warn_count"
if grep -qE 'warp|incomplete-route|duplicate-rank|duplicate-pair|malformed-role|bogus-effort' <<<"$_LAST_STDERR"; then
  fail "R4h: semantic validator leaked hostile policy tokens"
else
  pass "R4h: semantic validator diagnostics remain redacted"
fi

_isolate '
  mkdir -p untrusted
  printf "%s\n" "open(\"VALIDATOR_EXECUTED\", \"w\").write(\"bad\")" > untrusted/model_routing.py
  UBERDEV_MODEL_ROUTING_LIB="$PWD/untrusted/model_routing.py"
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_LIB UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  [ ! -e VALIDATOR_EXECUTED ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4i: untrusted explicit validator path fails closed without import" || fail "R4i: arbitrary validator path executed/accepted"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
[ "$warn_count" -eq 1 ] && pass "R4i: invalid validator emits one redacted warning" || fail "R4i: validator warning count=$warn_count"

_isolate '
  UBERDEV_MODEL_ROUTING_LIB="$ROOT/plugins/uberdev/lib/model_routing.py"
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_LIB UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4i: trusted explicit validator hook is testable" || fail "R4i: trusted explicit validator rejected"

_isolate '
  mkdir -p plugins/uberdev/lib
  printf "%s\n" "open(\"PWD_SHAPE_EXECUTED\", \"w\").write(\"bad\")" > plugins/uberdev/lib/model_routing.py
  UBERDEV_MODEL_ROUTING_LIB="$PWD/plugins/uberdev/lib/model_routing.py"
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_LIB UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  [ ! -e PWD_SHAPE_EXECUTED ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4i: hostile PWD trusted-shape validator is never imported" || fail "R4i: PWD shape bypass executed"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
[ "$warn_count" -eq 1 ] && pass "R4i: PWD bypass emits one redacted warning" || fail "R4i: PWD bypass warning count=$warn_count"

for spoof_case in pwd claude codex; do
  _isolate '
    case "'"$spoof_case"'" in
      pwd)
        mkdir -p copied/lib plugins/uberdev/lib
        hostile="$PWD/plugins/uberdev/lib/model_routing.py"
        marker=HOSTILE_PWD_EXECUTED
        ;;
      claude)
        mkdir -p copied/lib fake-claude/lib
        CLAUDE_PLUGIN_ROOT="$PWD/fake-claude"
        export CLAUDE_PLUGIN_ROOT
        hostile="$CLAUDE_PLUGIN_ROOT/lib/model_routing.py"
        marker=HOSTILE_CLAUDE_EXECUTED
        ;;
      codex)
        mkdir -p copied/lib fake-codex/plugins/uberdev-codex/lib
        CODEX_HOME="$PWD/fake-codex"
        export CODEX_HOME
        hostile="$CODEX_HOME/plugins/uberdev-codex/lib/model_routing.py"
        marker=HOSTILE_CODEX_EXECUTED
        ;;
    esac
    cp "$HELPER" copied/lib/config-read.sh
    printf "open(\"%s\", \"w\").write(\"bad\")\n" "$marker" > "$hostile"
    UBERDEV_ROUTING_POLICY_FILE="$ROOT/plugins/uberdev/policy/model-routing-v1.json"
    export UBERDEV_ROUTING_POLICY_FILE
    unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_MODEL_ROUTING_LIB
    . "$PWD/copied/lib/config-read.sh"
    UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
    export UBERDEV_MODEL_ROUTING_ROLES
    uberdev_read_model_routing
    [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
    [ ! -e "$marker" ] || exit 1
  '
  [ "$_STATUS" -eq 0 ] && pass "R4i: copied helper rejects spoofed $spoof_case root" || fail "R4i: copied helper trusted spoofed $spoof_case root"
  warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
  [ "$warn_count" -eq 1 ] && pass "R4i: spoofed $spoof_case root emits one redacted warning" || fail "R4i: spoofed $spoof_case warning count=$warn_count"
done

if command -v zsh >/dev/null 2>&1; then
  if UBERDEV_MODEL_ROUTING_ROLES='{"code-reviewer":{"effort":"high"}}' \
    zsh -c '. "$1"; uberdev_read_model_routing; [[ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":{\"reasoning_effort\":\"high\"}}" ]]' zsh "$HELPER"; then
    pass "R4i: actual sibling validator succeeds under zsh"
  else
    fail "R4i: actual sibling validator failed under zsh"
  fi
else
  pass "R4i: zsh unavailable (runtime probe skipped)"
fi

_isolate '
  printf "%s\n" "open(\"JSON_SHADOW_EXECUTED\", \"w\").write(\"bad\")" > json.py
  printf "%s\n" "open(\"IMPORTLIB_SHADOW_EXECUTED\", \"w\").write(\"bad\")" > importlib.py
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
  [ ! -e JSON_SHADOW_EXECUTED ] || exit 1
  [ ! -e IMPORTLIB_SHADOW_EXECUTED ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4i: isolated Python ignores hostile PWD stdlib shadows" || fail "R4i: hostile PWD Python module executed/broke parsing"
if grep -qE 'JSON_SHADOW|IMPORTLIB_SHADOW|Traceback' <<<"$_LAST_STDERR"; then
  fail "R4i: isolated Python leaked hostile token/traceback"
else
  pass "R4i: isolated Python diagnostics remain silent/redacted"
fi

_isolate '
  touch PWNED
  rm PWNED
  UBERDEV_MODEL_ROUTING_ROLES='"'"'{"code-reviewer":"$(touch PWNED)","code-reviewer":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  [ ! -e PWNED ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4j: hostile env map is never evaluated and duplicate keys reject" || fail "R4j: hostile/duplicate map safety"
warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
[ "$warn_count" -eq 1 ] && pass "R4j: invalid map emits exactly one redacted warning" || fail "R4j: invalid-map warning count=$warn_count: $_LAST_STDERR"

_isolate '
  UBERDEV_MODEL_ROUTING_WORKFLOWS='"'"'{"../solve":"deep"}'"'"'
  export UBERDEV_MODEL_ROUTING_WORKFLOWS
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4k: traversal-shaped override keys reject" || fail "R4k: traversal rejection"

_isolate '
  UBERDEV_MODEL_ROUTING_ROLES="$(python3 -c '"'"'import json; print(json.dumps({f"role-{i}": "deep" for i in range(65)}))'"'"')"
  export UBERDEV_MODEL_ROUTING_ROLES
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4l: override count is bounded" || fail "R4l: entry bound"

_isolate '
  UBERDEV_MODEL_ROUTING_WORKFLOWS="$(python3 -c '"'"'print("x" * 17000)'"'"')"
  export UBERDEV_MODEL_ROUTING_WORKFLOWS
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_WORKFLOWS" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4m: override bytes are bounded" || fail "R4m: size bound"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  roles:
    code-reviewer: deep
    code-reviewer: ultra
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4n: duplicate YAML override keys reject" || fail "R4n: duplicate YAML keys"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
integration_branch: feature/legacy
fanout_concurrency:
  research: 4
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  before="$(cksum .codex/uberdev.local.md)"
  uberdev_read_model_routing
  after="$(cksum .codex/uberdev.local.md)"
  [ "$before" = "$after" ] || exit 1
  [ "$UBERDEV_ROUTING_MODE" = inherit ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4o: legacy-only config remains byte-stable/compatible" || fail "R4o: legacy compatibility"
[ -z "$_LAST_STDERR" ] && pass "R4o: legacy-only config is warning-silent" || fail "R4o: legacy config warned: $_LAST_STDERR"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  roles:
    code-reviewer: deep
---

# Human notes below frontmatter are never configuration.
	model_routing:
  roles:
    code-revewer: warp
\$(touch NOTES_EXECUTED)
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
  [ ! -e NOTES_EXECUTED ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4p: notes tabs/headings/hostile text after frontmatter are ignored" || fail "R4p: notes corrupted routing frontmatter"
[ -z "$_LAST_STDERR" ] && pass "R4p: ignored notes are warning-silent" || fail "R4p: ignored notes warned/leaked: $_LAST_STDERR"

_isolate '
  cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  mode: adaptive
---
model_routing:
  roles:
    code-reviewer: ultra
EOF
  cat > .claude/uberdev.local.md <<EOF
---
model_routing:
  roles:
    code-reviewer: deep
---
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_MODE" = adaptive ] || exit 1
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4q: notes-only Codex key does not block per-key Claude fallback" || fail "R4q: notes key shadowed Claude fallback"

for delimiter_case in unterminated multiple; do
  _isolate '
    if [ "'"$delimiter_case"'" = unterminated ]; then
      cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  roles:
    code-reviewer: deep
EOF
    else
      cat > .codex/uberdev.local.md <<EOF
---
model_routing:
  roles:
    code-reviewer: deep
---
---
extra: document
---
EOF
    fi
    unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
    . "$HELPER"
    uberdev_read_model_routing
    [ "$UBERDEV_ROUTING_ROLES" = "{}" ] || exit 1
  '
  [ "$_STATUS" -eq 0 ] && pass "R4r: $delimiter_case frontmatter fails map closed" || fail "R4r: $delimiter_case frontmatter accepted"
  warn_count=$(printf '%s\n' "$_LAST_STDERR" | grep -c "model_routing.roles = '<invalid-map>'" || true)
  [ "$warn_count" -eq 1 ] && pass "R4r: $delimiter_case emits one redacted warning" || fail "R4r: $delimiter_case warning count=$warn_count"
done

_isolate '
  cat > .codex/uberdev.local.md <<EOF
model_routing:
  roles:
    code-reviewer: deep
EOF
  unset _UBERDEV_CONFIG_READ_LOADED UBERDEV_CONFIG_FILE
  . "$HELPER"
  uberdev_read_model_routing
  [ "$UBERDEV_ROUTING_ROLES" = "{\"code-reviewer\":\"deep\"}" ] || exit 1
'
[ "$_STATUS" -eq 0 ] && pass "R4s: delimiter-free legacy routing config remains supported" || fail "R4s: delimiter-free legacy config rejected"

echo
echo "== R5: documentation locks =="
for token in 'per key' 'UBERDEV_ROUTING_POLICY_FILE' 'UBERDEV_MODEL_ROUTING_LIB' 'actual sourced' 'sibling' 'isolated Python' 'first YAML frontmatter' 'delimiter-free' 'complete validator' 'reasoning_effort' 'solve.*turbo'; do
  if grep -qiE "$token" "$ROOT/plugins/uberdev/skills/using-uberdev/references/configuration.md"; then
    pass "R5: docs contain $token"
  else
    fail "R5: docs missing $token"
  fi
done

echo
echo "model-routing-config: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

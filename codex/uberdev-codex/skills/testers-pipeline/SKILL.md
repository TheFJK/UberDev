---
name: testers-pipeline
description: Use when /uberdev:testers is invoked. Orchestrates a read-only 8-agent adversarial QA audit squad (6 personas + 2 monitors) across N coordinated rounds against a web/api/native target via an on-disk Workflow script; routes findings into findings-to-issues. RFC 0012 §3.10 proving-ground migration.
model: inherit
---

# Testers Pipeline

Owns the lifecycle of `/uberdev:testers`. Read-only audit — the squad never writes app code. Findings are evidence-anchored and gated through monitors before being filed as GitHub issues.

This pipeline is the **RFC 0012 proving ground**: `/testers` is the uberdev plugin's FIRST shipped Workflow script. The orchestration (per-round persona fan-out, the aggregate→monitor→aggregate barrier, the politeness-breach gate, report synthesis, issue filing) lives in an on-disk `workflow.js` that the deterministic Workflow runtime executes in the background; only its return value and `log()` lines reach the main session. The thin preflight below does only what the script cannot (the filesystem-dependent steps) and then mandates the Workflow call.

## Phases

- **Preflight** — parse + auto-detect target, mint RUN_ID, refuse prod URLs, emit Workflow args.
- **waves** (in `workflow.js`) — per round r in 1..rounds: 6 personas in parallel → aggregate pass A (`--no-audit`) → monitor-primary + devils-advocate in parallel → aggregate pass B (the SOLE authoritative politeness audit). Follow-ups carry forward; the budget guard bounds rounds.
- **synthesis** (in `workflow.js`) — `report.py` → `report.md` (+ findings-to-issues aggregate unless `--no-issues`).
- **issue-filing** (in `workflow.js`) — `findings-to-issues` via the registered agent (envelope `source=testers-aggregate`).
- **Post-Workflow** — print the Phase-6 summary from the return and **EXIT 1 on `politeBreach`** (the headline contract).

## Schemas

### `wave-N.yaml` — aggregated per-round findings

Written to `.uberdev/research/$RUN_ID/testers/wave-<N>.yaml` after each round (by `aggregate.py`).

```yaml
schema_version: 1
wave: 1 | 2 | 3
run_id: <ulid>
target:
  surface: web | api | native | all
  url: <url-or-binary-path>
agents_dispatched: [panicked_grandma, power_user, adversarial_security, chaos_engineer, a11y_critic, mobile_thumb, monitor_primary, monitor_devils_advocate]
findings:
  - id: <stable-id>             # sha256(persona + invariant + location)[:16]
    severity: blocker | critical | major | important | suggestion
    persona: <one-of-agents>
    location: <url-or-endpoint-or-selector>
    invariant_violated: <id-from-invariants.yaml>
    summary: <1-line>
    detail: <prose>
    evidence:
      screenshot: <path-or-null>
      dom_hash: <sha256-or-null>
      network_request:
        method: <verb-or-null>
        url: <url-or-null>
        status: <code-or-null>
        timestamp: <iso8601-or-epoch-ms-or-null>   # required for rate-cap audit
      repro_steps: [<step>, ...]
      observed: <text>
      expected: <text>
    confidence: low | medium | high
cross_refs:
  - finding_id: <id>
    reproduced_by: [<persona>, <persona>]
    verified: true | false
follow_ups_for_next_wave:                 # populated by monitor-primary, empty on the final round
  <persona-name>:
    - <natural-language-prompt>
```

### Workflow return (the main-session contract)

`workflow.js` returns `{runId, surface, target, rounds, totalFindings, verifiedFindings, politeBreach, nullsByRound, auditEvents, reportPath, issues}`. `politeBreach` is the fail-the-run signal; `nullsByRound[r-1]` counts null persona/monitor returns in round r (a `-1` sentinel marks a round aborted by a throw); `issues` is `{issuesCreated:[...], skipped:N}`.

### `findings-to-issues` aggregate

Re-uses the existing `findings-to-issues` aggregate shape (see `agents/findings-to-issues.md`). Severity mapping: `blocker → BLOCKER`, `critical → CRITICAL`, `major → MAJOR`. Only `verified: true` findings are filed. The aggregate is written by `report.py` wrapped in the `<external-untrusted-input source="testers-aggregate">` envelope (leading file bytes).

## Reuses

- `agents/testers-*.md` — the 6 personas + 2 monitors, dispatched unmodified via `agentType` (DR-3).
- `agents/findings-to-issues.md` — durable persistence (HTML-comment fingerprint dedupe, MAX_NEW cap).
- `lib/config-read.sh` — `uberdev_emit_workflow_args` (the preflight → Workflow args seam, RFC 0012 §4.3).
- `lib/rl-curl` + `lib/rate-limit-curl.sh` — the per-host RPS shim personas invoke (referenced in the No-Workflow fallback directive).
- `skills/testers-pipeline/{aggregate.py,report.py,invariants.yaml}` — aggregation, reporting, the 10-invariant oracle.

## Preflight — parse, auto-detect, emit Workflow args

The skill is invoked with `$ARGUMENTS` in scope from `commands/testers.md`. Run the fence below — it does only the filesystem-dependent work the Workflow script cannot (PyYAML probe, RUN_ID mint, surface auto-detect, prod-url refusal, mkdir), parses flags, then prints the canonical Workflow args JSON between the `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` markers via `uberdev_emit_workflow_args`.

```bash
# PyYAML is the only runtime dep beyond python3 + bash. aggregate.py and
# report.py both import yaml; fail fast if it's missing.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to emit the Workflow args (RFC 0012 §4.3); install jq or use the No-Workflow fallback below" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' "$RANDOM")"
RUN_DIR=".uberdev/research/$RUN_ID/testers"
mkdir -p "$RUN_DIR/scratch" "$RUN_DIR/screenshots" "$RUN_DIR/traces" "$RUN_DIR/.rate-state"

# Parse flags (Bash substring matching; not getopt-grade). WATCH selects the
# No-Workflow fallback (the retained inline directive path / interactive mode).
TARGET=""; SURFACE="auto"; WATCH=0; ROUNDS=3; MAX_ISSUES=10; PERSONA_LIST=""; NO_ISSUES=0; RPS_CAP=10
for arg in $ARGUMENTS; do
  case "$arg" in
    --watch) WATCH=1 ;;
    --no-issues) NO_ISSUES=1 ;;
    --target=*) SURFACE="${arg#--target=}" ;;
    --rounds=*) ROUNDS="${arg#--rounds=}" ;;
    --max-issues=*) MAX_ISSUES="${arg#--max-issues=}" ;;
    --persona=*) PERSONA_LIST="${arg#--persona=}" ;;
    --rps-cap=*)
      RPS_CAP="${arg#--rps-cap=}"
      if ! [[ "$RPS_CAP" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: --rps-cap must be a positive integer (no leading zero, no sign); got '$RPS_CAP'" >&2
        exit 2
      fi
      if [ "$RPS_CAP" -lt 1 ] || [ "$RPS_CAP" -gt 1000 ]; then
        echo "error: --rps-cap must be in [1, 1000]; got '$RPS_CAP'" >&2
        exit 2
      fi
      ;;
    --*) echo "warning: unknown flag $arg" >&2 ;;
    *) TARGET="$arg" ;;
  esac
done

# CLAMP rounds to [1, 10]: a large value collides mid-run with the 1000-agent
# Workflow lifetime cap (RFC 0012 §3.10). Default 3; non-integer falls back to 3.
if ! [[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]]; then ROUNDS=3; fi
if [ "$ROUNDS" -lt 1 ]; then ROUNDS=1; fi
if [ "$ROUNDS" -gt 10 ]; then ROUNDS=10; fi

# Auto-detect surface if needed.
if [ "$SURFACE" = "auto" ]; then
  if [ -f package.json ] && grep -q '"playwright"' package.json; then SURFACE="web"
  elif find . -maxdepth 3 -name "openapi.yaml" -o -name "openapi.json" -o -name "swagger.yaml" 2>/dev/null | head -1 | read -r _; then SURFACE="api"
  elif [ -f electron-builder.json ] || ( [ -f Cargo.toml ] && grep -q tauri Cargo.toml ); then SURFACE="native"
  elif [ -d app ] || [ -d pages ] || [ -f next.config.js ] || [ -f wrangler.toml ]; then SURFACE="web"
  else SURFACE="all"
  fi
fi

# Refuse if target matches prod patterns.
if [ -f .uberdev/config.yaml ]; then
  PROD_PATTERNS="$(python3 -c "import yaml; cfg=yaml.safe_load(open('.uberdev/config.yaml')); print('\n'.join(cfg.get('prod_url_patterns', [])))" 2>/dev/null || true)"
  if [ -n "$PROD_PATTERNS" ] && [ -n "$TARGET" ]; then
    while IFS= read -r pat; do
      if echo "$TARGET" | grep -qE "$pat"; then
        echo "error: target '$TARGET' matches prod_url_pattern '$pat' — refusing to run" >&2; exit 2
      fi
    done <<< "$PROD_PATTERNS"
  fi
fi

PERSONAS="${PERSONA_LIST:-panicked_grandma,power_user,adversarial_security,chaos_engineer,a11y_critic,mobile_thumb}"
RUN_DIR_ABS="$(pwd)/$RUN_DIR"
INVARIANTS_ABS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/testers-pipeline/invariants.yaml"
# The invariant IDs travel as a comma list (path + IDs, never the YAML bytes —
# RFC 0012 §3.10). One python3 read keeps the ID set the SINGLE source of truth.
INVARIANT_IDS="$(python3 -c "import yaml,sys; print(','.join(i['id'] for i in yaml.safe_load(open(sys.argv[1]))['invariants']))" "$INVARIANTS_ABS" 2>/dev/null || true)"
NO_ISSUES_BOOL=false; [ "$NO_ISSUES" = "1" ] && NO_ISSUES_BOOL=true
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$WATCH" = "1" ]; then
  echo "[testers] --watch set — using the No-Workflow fallback (inline directive path)."
  echo "[testers] run_id=$RUN_ID surface=$SURFACE target=${TARGET:-(auto)} rounds=$ROUNDS rps_cap=$RPS_CAP"
else
  # RFC 0012 §4.1: validate the on-disk Workflow script exists BEFORE emitting
  # args and mandating the call. On a target install with a missing/misnamed
  # workflow.js the args envelope would otherwise be emitted and the Workflow
  # call mandated regardless — failing later at the runtime layer with a worse
  # error than this clean preflight refusal. (--watch reaches the No-Workflow
  # fallback above, so the guard sits inside this non-watch arm only.)
  WORKFLOW_JS="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/testers-pipeline/workflow.js"
  [ -f "$WORKFLOW_JS" ] || { echo "error: $WORKFLOW_JS missing (RFC 0012 §4.1); reinstall the plugin or use --watch for the No-Workflow fallback" >&2; exit 2; }
  . "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/config-read.sh"
  uberdev_emit_workflow_args testers \
    run_id="$RUN_ID" \
    runId="$RUN_ID" \
    runDirAbs="$RUN_DIR_ABS" \
    pluginRootAbs="$PLUGIN_ROOT" \
    target="$TARGET" \
    surface="$SURFACE" \
    rounds="$ROUNDS" \
    rpsCap="$RPS_CAP" \
    maxIssues="$MAX_ISSUES" \
    personas="$PERSONAS" \
    noIssues="$NO_ISSUES_BOOL" \
    invariantsPathAbs="$INVARIANTS_ABS" \
    invariantIds="$INVARIANT_IDS" \
    timestampIso="$NOW_ISO"
fi
```

**Workflow mandate (unless `--watch`):** the preflight validated `[ -f "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/testers-pipeline/workflow.js" ]`. Relay the JSON between `WORKFLOW_ARGS_BEGIN`/`WORKFLOW_ARGS_END` **verbatim** (DR-2 — no LLM-composed handoffs) into:

```
Workflow({scriptPath: "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/skills/testers-pipeline/workflow.js"}, <the JSON between the markers>)
```

**Post-Workflow mandate (stated explicitly — the one remaining prose directive at the seam):** when the Workflow returns, print the Phase-6 summary from its return value and **EXIT 1 on `politeBreach`**:

```
[testers] === DONE ===
  run_id:            <return.runId>
  surface:           <return.surface>
  target:            <return.target or (auto)>
  rounds:            <return.rounds>
  total findings:    <return.totalFindings>
  verified findings: <return.verifiedFindings>
  null returns:      <return.nullsByRound>
  report:            <return.reportPath>
  issues:            <return.issues.issuesCreated> (<return.issues.skipped> skipped)
```

If `return.politeBreach` is `true`, additionally print `[testers] --rps-cap=<N> was exceeded during the run; see polite_rate_cap findings in report.md` to stderr and **exit 1** — this is the headline contract (live for the first time). Otherwise exit 0.

## No-Workflow fallback

Run this path when **Workflow is not among your tools** (Gemini / Copilot / pre-Workflow Claude Code — see `references/{gemini,copilot,codex}-tools.md`) OR when the user passed `--watch` (the retained inline directive path, which is also the interactive mode that keeps the QA-squad windows visible — workflow agent transcripts never reach the main session, so the watch-the-squad UX is otherwise unrecoverable).

The never-worked master-dispatch mode is **removed**, not guarded: `lib/dispatch.sh` never provided `dispatch_master` (its public surface is `uberdev_dispatch_preflight`/`_resolve_env`/`_one`), so the old default printed "dispatched master" with nothing running (#306). There is no detached-session path here — use the inline directive recipe below.

Inline directive recipe (one round at a time, `1..ROUNDS`):

1. In ONE assistant message, dispatch all 6 personas (`Task` with `subagent_type: uberdev:testers-<persona>`) plus `monitor_primary` and `monitor_devils_advocate`. Each Task prompt carries: the target spec + surface; the invariants oracle by absolute PATH (`$INVARIANTS_ABS`, Read it — never inline the YAML); the previous round's `wave-<N-1>.yaml` path (null on round 1); monitor-primary's follow-ups for that persona (empty on round 1); and the persona's scratch dir `$RUN_DIR/scratch/<persona>/`. Each persona writes its canonical YAML to scratch (the evidence channel).
2. **Polite-rate (enforcement) — embed verbatim in every persona prompt** with `$RPS_CAP`, `$RATE_STATE_DIR` and `${PLUGIN_ROOT}` expanded to concrete values. For EVERY curl request, the persona invokes the executable shim as a SINGLE command word (the persona allowlists carry `Bash(*/lib/rl-curl*)`; a compound `export ...; source ...; uberdev_rate_limit_curl` form matches no allowlist pattern, and the preflight fence's exports never reach a fresh Task agent):

   ```
   "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}/lib/rl-curl" --rate-state-dir="$RATE_STATE_DIR" --rps-cap=$RPS_CAP <URL> [curl-args...]
   ```

   The shim sources `lib/rate-limit-curl.sh` and calls `uberdev_rate_limit_curl`, hard-capping per-host RPS at `$RPS_CAP`. Playwright / `browser_*` MCP calls cannot be HTTP-wrapped; the audit reads `findings[].evidence.network_request.timestamp` and fails the run if the per-host rolling 1-second RPS exceeds `$RPS_CAP`. (`RATE_STATE_DIR="$RUN_DIR_ABS/.rate-state"`.)
3. After the 6 personas + 2 monitors return, aggregate the round: run `aggregate.py` (with `PLUGIN_ROOT` exported) over `$RUN_DIR/scratch` → `$RUN_DIR/wave-<N>.yaml`. Capture its exit code: `1` = politeness breach → set `POLITE_BREACH=1`; `2` = error → abort. Carry monitor-primary's `follow_ups_for_next_wave` into the next round.
4. After the last round, run `report.py` → `$RUN_DIR/report.md`, and (unless `--no-issues`) emit the `findings-to-issues` aggregate and dispatch `Task(subagent_type: uberdev:findings-to-issues)` with `max_new=$MAX_ISSUES`.
5. Print the Phase-6 summary and **exit 1 if `POLITE_BREACH=1`** (same headline contract as the Workflow path).

This fallback recipe is intentionally thin; the Workflow path is the default and carries the enforced barriers, real budget guard, and null-counting.

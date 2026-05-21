---
name: testers-pipeline
description: Use when /uberdev:testers is invoked. Orchestrates a read-only 8-agent adversarial QA audit squad (6 personas + 2 monitors) across 3 coordinated waves against a web/api/native target; routes findings into findings-to-issues.
model: opus
---

# Testers Pipeline

Owns the lifecycle of `/uberdev:testers`. Read-only audit — the squad never writes app code. Findings are evidence-anchored and gated through monitors before being filed as GitHub issues.

## Phases

- **Phase 0 — Parse + auto-detect target**
- **Phase 1 — Dispatch master agent (or run inline if --watch)**
- **Phase 2 — Wave 1 (fresh eyes): 8-agent parallel Task() fan-out**
- **Phase 3 — Wave 2 (verify + dig): monitor follow-ups → re-dispatch 8 agents**
- **Phase 4 — Wave 3 (final cross-confirmation): adversarial monitor pass**
- **Phase 5 — Synthesize report.md + dispatch findings-to-issues**
- **Phase 6 — Emit summary line and exit**

## Schemas

### `wave-N.yaml` — aggregated per-wave findings

Written to `.uberdev/research/$RUN_ID/testers/wave-<N>.yaml` after each wave.

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
      repro_steps: [<step>, ...]
      observed: <text>
      expected: <text>
    confidence: low | medium | high
cross_refs:
  - finding_id: <id>
    reproduced_by: [<persona>, <persona>]
    verified: true | false
follow_ups_for_next_wave:                 # populated by monitor-primary, empty on wave 3
  <persona-name>:
    - <natural-language-prompt>
```

### `findings-to-issues` aggregate (Phase 5 output)

Re-uses the existing `findings-to-issues` aggregate shape (see `agents/findings-to-issues.md` for the canonical schema). Severity mapping: `blocker → BLOCKER`, `critical → CRITICAL`, `major → MAJOR`. Only `verified: true` findings are filed.

## Reuses

- `lib/dispatch.sh` — master backgrounding (RFC 0004)
- `agents/findings-to-issues.md` — durable persistence (HTML-comment fingerprint dedupe, MAX_NEW=10 cap)
- Reviewer YAML contract — `verdict: AUDITED | findings | confidence` shape

## Sub-skill imports

None. This skill is fully self-contained.


## Phase 0 — Parse + auto-detect target

The skill is invoked with `$ARGUMENTS` in scope from `commands/testers.md`. Parse the following flags (Bash substring matching is fine; this isn't getopt-grade):

```bash
# Phase 0 precheck — PyYAML is the only runtime dep beyond python3 + bash.
# aggregate.py and report.py both import yaml; fail fast if it's missing.
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML required (pip install pyyaml or python3 -m pip install pyyaml)" >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)"
RUN_DIR=".uberdev/research/$RUN_ID/testers"
mkdir -p "$RUN_DIR/scratch" "$RUN_DIR/screenshots" "$RUN_DIR/traces"

# Parse flags
TARGET=""; SURFACE="auto"; WATCH=0; ROUNDS=3; MAX_ISSUES=10; PERSONA_LIST=""; NO_ISSUES=0; RPS_CAP=10
for arg in $ARGUMENTS; do
  case "$arg" in
    --watch) WATCH=1 ;;
    --no-issues) NO_ISSUES=1 ;;
    --target=*) SURFACE="${arg#--target=}" ;;
    --rounds=*) ROUNDS="${arg#--rounds=}" ;;
    --max-issues=*) MAX_ISSUES="${arg#--max-issues=}" ;;
    --persona=*) PERSONA_LIST="${arg#--persona=}" ;;
    --rps-cap=*) RPS_CAP="${arg#--rps-cap=}" ;;
    --*) echo "warning: unknown flag $arg" >&2 ;;
    *) TARGET="$arg" ;;
  esac
done

# Auto-detect surface if needed
if [ "$SURFACE" = "auto" ]; then
  if [ -f package.json ] && grep -q '"playwright"' package.json; then SURFACE="web"
  elif find . -maxdepth 3 -name "openapi.yaml" -o -name "openapi.json" -o -name "swagger.yaml" 2>/dev/null | head -1 | read -r _; then SURFACE="api"
  elif [ -f electron-builder.json ] || ( [ -f Cargo.toml ] && grep -q tauri Cargo.toml ); then SURFACE="native"
  elif [ -d app ] || [ -d pages ] || [ -f next.config.js ] || [ -f wrangler.toml ]; then SURFACE="web"
  else SURFACE="all"
  fi
fi

# Refuse if target matches prod patterns
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
```

## Phase 1 — Dispatch master (or run inline)

If `--watch` is set, the skill continues in the current session (the wave loop below runs inline). Otherwise, dispatch a master via `plugins/uberdev/lib/dispatch.sh`:

```bash
if [ "$WATCH" = "1" ]; then
  echo "[testers] running inline (--watch); session occupied for the duration."
else
  # Build the master prompt that re-enters this skill with the same args plus --watch
  MASTER_PROMPT="/uberdev:testers $ARGUMENTS --watch"
  source plugins/uberdev/lib/dispatch.sh
  dispatch_master "$MASTER_PROMPT" "$RUN_DIR/master.log"
  echo "[testers] dispatched master. Watch progress: $RUN_DIR/master.log"
  echo "[testers] run_id=$RUN_ID surface=$SURFACE target=$TARGET"
  exit 0
fi
```

## Phase 2–4 — Three coordinated waves

Wave loop. For each round in `1..ROUNDS`:

```bash
PERSONAS="${PERSONA_LIST:-panicked_grandma,power_user,adversarial_security,chaos_engineer,a11y_critic,mobile_thumb}"
PREV_FINDINGS="null"

# Per-wave fan-out cap (RFC 0006 §Risks). Default 8 matches wave size.
# Precedence env > config > default; range [1, 16].
if [ -r "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh" ]; then
  . "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
  TESTERS_FANOUT="$(uberdev_read_int_in_range fanout_concurrency.testers UBERDEV_TESTERS_FANOUT 1 16 8)"
else
  TESTERS_FANOUT=8
fi

for WAVE in $(seq 1 "$ROUNDS"); do
  WAVE_FILE="$RUN_DIR/wave-$WAVE.yaml"
  echo "[testers] wave $WAVE/$ROUNDS starting"

  # In ONE assistant message, dispatch all 6 personas + 2 monitors via Task() calls.
  # The skill emits the dispatch directives below; the wrapping orchestrator (this Claude
  # session) reads them and fires the actual Task() calls in a single message.
  cat > "$RUN_DIR/dispatch-wave-$WAVE.yaml" <<EOF
schema_version: 1
wave: $WAVE
run_id: $RUN_ID
target:
  surface: $SURFACE
  url: $TARGET
prev_findings_path: $PREV_FINDINGS
budget:
  max_actions: 200
  max_clock_seconds: 300
  rps_cap: $RPS_CAP
agents_to_dispatch:
  personas: [$PERSONAS]
  monitors: [monitor_primary, monitor_devils_advocate]
EOF

  # ============================================================================
  # DISPATCH POINT — the orchestrating session reads dispatch-wave-N.yaml above
  # and fires N Task() calls IN A SINGLE assistant message. Each Task receives:
  #   - target spec
  #   - invariants.yaml (path)
  #   - prev wave's findings (path or null)
  #   - monitor-primary's follow_ups for this persona (from prev wave; empty on wave 1)
  #   - scratch dir scoped to .uberdev/research/$RUN_ID/testers/scratch/<agent>/
  # Each Task returns the canonical reviewer YAML on stdout.
  # ============================================================================

  # After all Task() returns, aggregate to wave-N.yaml:
  python3 plugins/uberdev/skills/testers-pipeline/aggregate.py \
    --run-id "$RUN_ID" \
    --wave "$WAVE" \
    --scratch-dir "$RUN_DIR/scratch" \
    --invariants plugins/uberdev/skills/testers-pipeline/invariants.yaml \
    --out "$WAVE_FILE"

  PREV_FINDINGS="$WAVE_FILE"
  echo "[testers] wave $WAVE complete: $(python3 -c "import sys,yaml; print(len((yaml.safe_load(open(sys.argv[1])) or {}).get('findings') or []))" "$WAVE_FILE") findings"
done
```

The skill ships `aggregate.py` alongside SKILL.md — a tiny script (~50 lines) that:

1. Globs `scratch/<agent>/*.yaml`
2. Parses each via `yaml.safe_load`
3. Drops findings without `invariant_violated` OR without any `evidence.*` populated
4. Computes stable `id` per finding via `sha256(persona + invariant_violated + location)[:16]`
5. Merges all findings into one wave-N.yaml
6. Runs monitor-primary's cross_refs logic IF the monitor agents' outputs are in scratch (else passes them through verbatim)


## Phase 5 — Synthesize report.md and persist findings

```bash
# Generate the human-readable report
python3 plugins/uberdev/skills/testers-pipeline/report.py \
  --run-id "$RUN_ID" \
  --waves-dir "$RUN_DIR" \
  --invariants plugins/uberdev/skills/testers-pipeline/invariants.yaml \
  --out "$RUN_DIR/report.md"

echo "[testers] report written: $RUN_DIR/report.md"

# Dispatch findings-to-issues unless --no-issues
if [ "$NO_ISSUES" != "1" ]; then
  # Build a findings-to-issues-compatible aggregate from the final wave file.
  # Only verified: true findings with severity blocker|critical|major are filed.
  python3 plugins/uberdev/skills/testers-pipeline/report.py \
    --run-id "$RUN_ID" \
    --waves-dir "$RUN_DIR" \
    --invariants plugins/uberdev/skills/testers-pipeline/invariants.yaml \
    --emit-findings-to-issues-aggregate "$RUN_DIR/findings-to-issues-aggregate.md"

  # The Task() dispatch happens in the orchestrating session, not in this skill.
  echo "DISPATCH: findings-to-issues with $RUN_DIR/findings-to-issues-aggregate.md (max_new=$MAX_ISSUES)"
fi
```

The findings-to-issues aggregate is shaped to match the existing post-impl-review-final.md schema (see `agents/findings-to-issues.md`). The orchestrator session reads the `DISPATCH:` line and fires `Task(subagent_type: uberdev:findings-to-issues)` in the standard idiom.

## Phase 6 — Summary + exit

```bash
TOTAL="$(python3 -c "import yaml; f=yaml.safe_load(open('$RUN_DIR/wave-$ROUNDS.yaml')); print(len(f['findings']))")"
VERIFIED="$(python3 -c "import yaml; f=yaml.safe_load(open('$RUN_DIR/wave-$ROUNDS.yaml')); print(sum(1 for cr in (f.get('cross_refs') or []) if cr.get('verified')))")"

echo
echo "[testers] === DONE ==="
echo "  run_id:        $RUN_ID"
echo "  surface:       $SURFACE"
echo "  target:        ${TARGET:-(auto)}"
echo "  rounds:        $ROUNDS"
echo "  total findings:    $TOTAL"
echo "  verified findings: $VERIFIED"
echo "  report:        $RUN_DIR/report.md"
[ "$NO_ISSUES" != "1" ] && echo "  issues:        see findings-to-issues output above"
```
<!-- Phase logic implementations land via T15 (waves 2-4) and T17 (Phase 5). -->

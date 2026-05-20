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

<!-- Phase logic implementations land via T15 (waves 2-4) and T17 (Phase 5). -->

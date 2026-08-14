#!/usr/bin/env bash
# Shape + wiring test suite for /uberthink (T13 of the uberthink ideation engine).
#
# Mirrors tests/uberscan.test.sh + tests/ubersimplify.test.sh — structural
# integrity assertions across the feature so a refactor that breaks a contract
# (frontmatter, persona key, single-message invariant, label drift, bashism leak,
# missing CB) turns CI red.
#
# DRIFT NOTE (T13/T15 ordering): the allowed-tools <-> aliases-sync.sh drift
# guard (block U10) WILL FAIL if T15 (wave-4) hasn't landed yet — that is its
# intended job. The failure message points the operator at the missing
# aliases-sync row.
set -u; set -o pipefail
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/uberthink.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/SKILL.md"
PERSONAS="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/personas.yaml"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
F2I="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
AGENTS_DIR="$REPO_ROOT/plugins/uberdev/agents"
REPORT_TEST="$REPO_ROOT/tests/uberthink-report.test.sh"
REPORT_PY="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/report.py"
# RFC 0012 §3.7 moved the orchestration out of SKILL.md into workflow.js. Asserts
# that used to anchor on directive-emitter bash now anchor HERE; the behavioral
# coverage lives in tests/uberthink-workflow.test.sh.
WORKFLOW="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/workflow.js"

PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
ck_msg() { # $1=label $2=command $3=fail-detail-message
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; echo "        $3"; FAIL=$((FAIL+1)); fi
}

echo "== U1: command file structure + delegation =="
ck "command file exists" "[ -r '$CMD' ]"
ck "has description frontmatter" "grep -q '^description:' '$CMD'"
ck "has argument-hint frontmatter" "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools frontmatter" "grep -q '^allowed-tools:' '$CMD'"
# Command delegates to the pipeline skill. Mirror uberscan.test.sh / ubersimplify.test.sh:
# look for the skill name token (with or without the Skill(uberdev:...) wrapper).
ck "command body invokes uberthink-pipeline skill" "grep -qE 'uberdev:uberthink-pipeline' '$CMD'"

echo "== U2: READ-ONLY invariant (no Edit/MultiEdit in allowed-tools) =="
# Mirrors uberscan U2 — /uberthink is read-only by spec; presence of Edit/MultiEdit
# would mean an agent could write application source.
ck "allowed-tools omits Edit/MultiEdit" "[ \$(grep '^allowed-tools:' '$CMD' | grep -cE '\"Edit\"|MultiEdit') -eq 0 ]"
# RFC 0012 §3.7: SKILL.md MANDATES Workflow({scriptPath: .../uberthink-pipeline/workflow.js}).
# A command whose allowed-tools omits Workflow cannot invoke the tool its own
# pipeline requires. Same assert uberscan.test.sh + ubersimplify.test.sh carry.
ck "allowed-tools carries Workflow (the migration's dispatch tool)" \
  "grep -q '\"Workflow\"' <<<\"\$(grep '^allowed-tools:' '$CMD')\""

echo "== U3: personas.yaml parses + has required top-level + donor_catalog tier keys =="
PY_KEYS=$(python3 - <<PYEOF
import sys, yaml
try:
    d = yaml.safe_load(open("$PERSONAS"))
except Exception as e:
    print(f"PARSE_ERROR:{e}"); sys.exit(0)
top_required = {"frame_lenses","donor_catalog","generator_personas","moderator","synthesizer_lenses","falsifier_lenses"}
donor_required = {"tier1_swe_cs","tier2_gamedev","tier3_it_sys","tier4_math","tier5_wildcard"}
missing_top = sorted(top_required - set((d or {}).keys()))
donor = (d or {}).get("donor_catalog") or {}
missing_donor = sorted(donor_required - set(donor.keys()))
print(f"OK:missing_top={','.join(missing_top)}:missing_donor={','.join(missing_donor)}")
PYEOF
)
ck_msg "personas.yaml parses (yaml.safe_load)" "[[ '$PY_KEYS' != PARSE_ERROR* ]]" "personas.yaml YAML parse failed: $PY_KEYS"
ck_msg "personas.yaml top-level keys: frame_lenses+donor_catalog+generator_personas+moderator+synthesizer_lenses+falsifier_lenses" \
  "[[ '$PY_KEYS' == *missing_top=:* ]]" "missing top-level keys (see PY_KEYS=$PY_KEYS)"
ck_msg "personas.yaml donor_catalog tiers: tier1..tier5 ALL present" \
  "[[ '$PY_KEYS' == *missing_donor=* ]] && [[ '$PY_KEYS' == *missing_donor=:* || '$PY_KEYS' == *missing_donor=*$'\n'* || '$PY_KEYS' == *missing_donor= ]]" \
  "missing donor_catalog tiers (see PY_KEYS=$PY_KEYS)"

echo "== U4: all 6 agent files exist with uberthink-* names + valid models =="
# Spec §2.5 model assignments:
#   all 6 agents now pin model: inherit (session model — Opus 4.8 1M),
#   overriding the original spec §2.5 per the all-inherit policy.
declare -a AGENTS=(frame generator moderator falsifier synthesizer arbiter)
declare -A WANT_MODEL=(
  [frame]=inherit [generator]=inherit [moderator]=inherit [falsifier]=inherit
  [synthesizer]=inherit [arbiter]=inherit
)
for a in "${AGENTS[@]}"; do
  f="$AGENTS_DIR/uberthink-$a.md"
  ck "agent file exists: uberthink-$a.md" "[ -r '$f' ]"
  ck "agent frontmatter name is uberthink-$a" "grep -qE '^name: uberthink-$a\$' '$f'"
  # model is one of opus|sonnet|haiku|fable|inherit (fable added per RFC 0012
  # §5 — enum extension only; the per-agent WANT_MODEL lock below stays
  # all-inherit, and no agent pins fable until open question Q5 resolves)
  ck "agent model in {opus,sonnet,haiku,fable,inherit}: uberthink-$a" "grep -qE '^model: (opus|sonnet|haiku|fable|inherit)\$' '$f'"
  # spec §2.5 specific assignment
  want="${WANT_MODEL[$a]}"
  ck "agent model matches all-inherit policy: uberthink-$a == $want" "grep -qE '^model: $want\$' '$f'"
done

echo "== U5: Workflow seam + the fallback's single-message invariant =="
# The single-message fanout invariant survives the migration inside the
# '## No-Workflow fallback' recipe — it is the load-bearing token a refactor
# would most likely weaken, and it still governs every hand-driven wave.
ck "SKILL.md contains 'SINGLE assistant message' invariant" "grep -q 'SINGLE assistant message' '$SKILL'"
# Post-migration framing: SKILL.md is a thin preflight + args seam that mandates
# the on-disk Workflow script (RFC 0012 §3.7). The directive-emitter bash it
# replaced lived here; the orchestration now lives in workflow.js.
ck "workflow.js exists on disk (the orchestration moved out of SKILL.md)" "[ -r '$WORKFLOW' ]"
ck "SKILL.md mandates the uberthink Workflow script" \
  "grep -qF 'Workflow({scriptPath: \"\$CLAUDE_PLUGIN_ROOT/skills/uberthink-pipeline/workflow.js\"}' '$SKILL'"
ck "SKILL.md carries the mandatory '## No-Workflow fallback' section" \
  "grep -qF '## No-Workflow fallback' '$SKILL'"

echo "== U6: SKILL.md documents every LIVE circuit breaker as a breaker-table row =="
# The old form looped over CB-LOOP/CB-WAVE/CB-FLOOD/CB-CLOCK/CB-CONVERGE/CB-ISLAND
# and grepped the WHOLE file — so "CB-WAVE … are **retired**" satisfied the assert
# "SKILL.md mentions CB-WAVE": prose asserting the OPPOSITE of what was claimed.
# Anchor the live breakers on the breaker TABLE instead, and assert the two dead
# wall-clock breakers appear ONLY as retirement prose. CB-BUDGET (the genuinely
# new one, RFC 0012 DR-7) is now covered too.
CB_TABLE="$(awk '/^\| ID \| Guard \| Trip condition \| Action \|/{active=1} active{print} active && /^$/{exit}' "$SKILL")"
ck_msg "the circuit-breaker table exists in SKILL.md" "[ -n \"\$CB_TABLE\" ]" \
  "no '| ID | Guard | Trip condition | Action |' table header found in $SKILL"
for cb in CB-ISLAND CB-BUDGET CB-FLOOD CB-LOOP CB-CONVERGE; do
  ck_msg "breaker table carries a LIVE row for $cb" \
    "grep -qF '**$cb**' <<<\"\$CB_TABLE\"" \
    "$cb is not a row in the breaker table (a mention elsewhere in the file does not count)"
done
for cb in CB-WAVE CB-CLOCK; do
  ck_msg "$cb is retired — named in the file but NOT a live breaker row" \
    "grep -qF '$cb' '$SKILL' && ! grep -qF '**$cb**' <<<\"\$CB_TABLE\"" \
    "$cb must survive only as retirement prose (DR-7: the wall-clock globals are forbidden)"
done
ck "SKILL.md states both wall-clock breakers are retired on one line" \
  "grep -qE 'CB-WAVE.*CB-CLOCK.*retired' '$SKILL'"

echo "== U7: SKILL.md handles island, gap-gate, loop-back(3), --handoff =="
ck "SKILL.md references islands ('island-' token)" "grep -q 'island-' '$SKILL'"
ck "SKILL.md references gap-gate via gaps.yaml" "grep -q 'gaps\\.yaml' '$SKILL'"
# loop-back cap of 3 — accept either the assignment 'LOOP_BACK_CAP=3'
# or a prose reference to '≤3' / 'cap 3' / 'capped at 3'
ck "SKILL.md caps the genetic loop-back at 3" \
  "grep -qE 'LOOP_BACK_CAP=3|loop_count >= 3|loop-back.*[<≤=]+ ?3|cap.* 3' '$SKILL'"
ck "SKILL.md handles --handoff flag" "grep -q '\\-\\-handoff' '$SKILL'"
ck "SKILL.md hands off to brainstorm via Skill(uberdev:brainstorm)" \
  "grep -q 'Skill(uberdev:brainstorm)' '$SKILL'"

echo "== U8: no bashisms in SKILL.md (type -t / BASH_REMATCH) =="
# Bashisms run through /bin/zsh in the Bash tool — silent runtime failures.
# Mirrors the global rule from MEMORY: bit /uberscan CB7 and /finish-branch
# Option-2 PR-extraction. Shape-only guard so a copy-pasted snippet from
# another shell trips CI immediately.
ck "SKILL.md contains no 'type -t' bashism" "! grep -nE 'type -t' '$SKILL'"
ck "SKILL.md contains no 'BASH_REMATCH' bashism" "! grep -nE 'BASH_REMATCH' '$SKILL'"

echo "== U9: scope-gate REFUSE halt present (verdict-first safety lens) =="
# The schema lens runs ALONE; its REFUSE verdict records a SCOPE_REFUSE halt and
# stops the run before any fanout (spec §5). The halt id used to be an
# append-only run-state.txt line; it is now a return-value halt raised by
# workflow.js, so assert it on BOTH the contract (SKILL.md) and the code.
ck "SKILL.md documents the SCOPE_REFUSE halt" "grep -q 'SCOPE_REFUSE' '$SKILL'"
ck "workflow.js raises SCOPE_REFUSE on a REFUSE verdict" \
  "grep -qF 'addHalt(\"SCOPE_REFUSE\")' '$WORKFLOW'"
ck "SKILL.md describes the scope gate halting before fanout" \
  "grep -qE 'Halt before ANY fanout|before any sibling agent is dispatched|stop before any other dispatch' '$SKILL'"
# Verdict-first is the whole point: the gate must be a solo awaited dispatch, not
# a member of a parallel burst.
ck "workflow.js dispatches the scope gate solo (no pre-verdict parallel wave)" \
  "grep -qE '^[[:space:]]+const scopeRet = await agent\(scopePrompt' '$WORKFLOW'"

echo "== U10: allowed-tools drift guard (commands/uberthink.md <-> lib/aliases-sync.sh) =="
# This is the same drift guard pattern uberscan.test.sh + ubersimplify.test.sh use:
# the alias row's tool list must byte-match the command file's allowed-tools.
# T15 (wave-4) adds the aliases-sync.sh row — if T15 hasn't landed yet, this
# single assert will FAIL by design (the gate's whole job is to surface the gap).
# Mirror uberscan's strip-quotes normalization (closing ' on the ALIASES heredoc
# line shows up in the cut result on the last row).
if grep -q '^uberthink|uberthink|' "$SYNC"; then
  ck "aliases-sync.sh has uberthink row" "true"
  ALIAS_TOOLS="$(grep '^uberthink|uberthink|' "$SYNC" | cut -d'|' -f3 | tr -d "'")"
  CMD_TOOLS="$(grep '^allowed-tools:' "$CMD" | sed 's/^allowed-tools: //' | tr -d "'")"
  ck_msg "alias tools byte-match command allowed-tools" \
    "[ \"\$ALIAS_TOOLS\" = \"\$CMD_TOOLS\" ]" \
    "drift: ALIAS_TOOLS=[$ALIAS_TOOLS]  CMD_TOOLS=[$CMD_TOOLS]"
else
  ck_msg "[drift] aliases-sync.sh has uberthink row" "false" \
    "does the lib/aliases-sync.sh ALIASES row for 'uberthink' exist yet? T15 may not have landed."
fi

echo "== U11: findings-to-issues accepts uberthink-aggregate source =="
# Post-#198 the accepted-source allow-list is a SINGLE closed set in Step 1 (the
# SSOT); the redundant prose enumeration was collapsed to a pointer, so the old
# "expect >= 2 line-hits" no longer holds (uberthink-aggregate now lives on the
# one closed-set line). Assert MEMBERSHIP in the Step-1 closed set instead — that
# membership is what makes findings-to-issues ACCEPT the source. (Suite 15 in
# tests/findings-to-issues.test.sh cross-checks the full closed-set ==
# report_primitives.ACCEPTED_SOURCES frozenset.)
# Fail-loud preflight: gate the count on a readable $F2I so a missing/renamed
# findings-to-issues.md surfaces as its own FAIL with the right message instead
# of being swallowed into a vacuous "uberthink-aggregate not in the allow-list"
# (which the old `… 2>/dev/null || echo 0` masked) (#275).
ck "findings-to-issues.md exists (closed-set source)" "[ -r '$F2I' ]"
# Drop the `2>/dev/null || echo 0` count-masking idiom: grep -c already prints
# its natural `0` (and exits 1) when 'uberthink-aggregate' is absent, so the
# assert still fails CLOSED — but a genuine grep error (e.g. unreadable $F2I)
# is no longer hidden, restoring the diagnostic that distinguishes a real
# allow-list regression from brittle-anchor drift (#275).
F2I_IN_CLOSED_SET=$(grep -oE 'closed set `\{[^}]*\}`' "$F2I" | grep -c 'uberthink-aggregate')
ck_msg "findings-to-issues.md Step-1 closed set includes uberthink-aggregate" \
  "[ '$F2I_IN_CLOSED_SET' -ge 1 ]" \
  "uberthink-aggregate not in the Step-1 closed-set allow-list of $F2I"

echo "== U12: standalone findings dispatch uses the closed caller contract =="
# The dispatch moved from a SKILL.md "DISPATCH POINT" comment block into
# workflow.js's f2iPrompt(); re-anchored on that builder. Herestrings instead of
# `printf | grep` — a pipe into `grep -q` can EPIPE-race under pipefail on Linux CI.
UBERTHINK_F2I_REGION="$(awk 'index($0,"function f2iPrompt("){active=1} active{print} active && $0=="}"{exit}' "$WORKFLOW")"
ck "uberthink f2i builder was found in workflow.js" "[ -n \"\$UBERTHINK_F2I_REGION\" ]"
# Bind the KEY to its VALUE *inside the builder*. The weaker form checked
# `aggregate_path=` in the region and then grepped `f2i-aggregate.md` against the
# WHOLE workflow.js — where aggregatePrompt() also contains it — so the region
# could lose the value entirely and the assert would still pass.
ck "uberthink dispatch binds aggregate_path to the caller-supplied path" \
  "grep -qF 'aggregate_path=\" + aggregatePathAbs' <<<\"\$UBERTHINK_F2I_REGION\""
UBERTHINK_AGG_REGION="$(awk 'index($0,"function aggregatePrompt("){active=1} active{print} active && $0=="}"{exit}' "$WORKFLOW")"
ck "uberthink aggregate builder was found in workflow.js" "[ -n \"\$UBERTHINK_AGG_REGION\" ]"
ck "the aggregate relay writes f2i-aggregate.md under the run dir" \
  "grep -qF 'runDirAbs + \"/f2i-aggregate.md\"' <<<\"\$UBERTHINK_AGG_REGION\""
ck "uberthink dispatch sends numeric pr_number=0" \
  "grep -q 'pr_number=0' <<<\"\$UBERTHINK_F2I_REGION\""
ck "uberthink dispatch sends fixed label, marker, and max_new" \
  "grep -q 'finding_label=uberthink-idea' <<<\"\$UBERTHINK_F2I_REGION\" \
    && grep -q 'finding_marker_slug=uberthink' <<<\"\$UBERTHINK_F2I_REGION\" \
    && grep -q 'max_new=' <<<\"\$UBERTHINK_F2I_REGION\""
ck "uberthink dispatch selects variant=legacy.uberthink" \
  "grep -q 'variant=legacy.uberthink' <<<\"\$UBERTHINK_F2I_REGION\""
ck "uberthink dispatch omits agent-derived and legacy path fields" \
  "! grep -qE '(run_id|repo_slug|pr_commit_sha|source_ref|phase1_aggregate_path)=' <<<\"\$UBERTHINK_F2I_REGION\""

echo "== U14: flag parse, donor catalog, Wave-5 path derivation, relay payload =="
# --resume is documented with a SPACE in the argument-hint, the flag table and
# RFC 0009. Parsing only `--resume=VALUE` sent the run id into GOAL and launched a
# full fresh (~30x a normal chat) ideation run on the literal id string.
ck "SKILL.md parses --resume=VALUE" "grep -qF -- '--resume=*)' '$SKILL'"
ck "SKILL.md parses the documented '--resume VALUE' space form" \
  "grep -qE -- '--resume\\)[[:space:]]+WANT=resume' '$SKILL'"
ck "SKILL.md parses the space form of --islands and --max-new too" \
  "grep -qE -- '--islands\\)[[:space:]]+WANT=islands' '$SKILL' \
    && grep -qE -- '--max-new\\)[[:space:]]+WANT=max-new' '$SKILL'"
ck "SKILL.md refuses a value-taking flag that has no value" \
  "grep -q 'requires a value' '$SKILL'"
ck "commands/uberthink.md preflight accepts BOTH --resume spellings" \
  "grep -qF -- '--resume(=|\$)' '$CMD'"

# Every donor_catalog entry is returned VERBATIM by the schema lens and then run
# through the pipeline's ^[a-z0-9][a-z0-9-]{1,48}$ slug validator. A decorated
# entry is dropped with no log, silently weakening the mandatory >=2 tier-5
# wildcard rule.
DONOR_BAD=$(python3 - <<PYEOF
import re, yaml
try:
    d = yaml.safe_load(open("$PERSONAS")) or {}
except Exception as e:
    print(f"PARSE_ERROR:{e}"); raise SystemExit(0)
rx = re.compile(r"^[a-z0-9][a-z0-9-]{1,48}\$")
bad = [str(s) for tier in (d.get("donor_catalog") or {}).values() for s in (tier or [])
       if not rx.match(str(s))]
print(" | ".join(bad))
PYEOF
)
ck_msg "every donor_catalog slug survives the pipeline's isSlug() validator" \
  "[ -z '$DONOR_BAD' ]" \
  "these catalog entries are silently dropped before any Field Scout is dispatched: $DONOR_BAD"

# Wave 5 must attack the composite_path report.py wrote into the shortlist row.
# The composite id (comp-island-K-NNN) is NOT the composite file stem
# (comp-NNN-<synth-lens>), so a path rebuilt from the id points at nothing.
ck "the Wave-4 relay returns the authoritative composite_path per shortlist row" \
  "grep -qF 'compositePaths' '$WORKFLOW'"
ck "workflow.js never rebuilds a composite path from the shortlist id" \
  "! grep -qF '/composites/\" + cid' '$WORKFLOW'"
ck "the falsify artifact name is derived from the composite FILE stem" \
  "grep -qF 'baseStem(compositePath)' '$WORKFLOW'"
# report.py globs the falsify dossiers off the composite basename — the two
# conventions must stay in lockstep.
ck "report.py globs falsify dossiers off basename(composite_path)" \
  "grep -qF 'base.replace(\".yaml\", \"-*.yaml\")' '$REPORT_PY'"

# rc 0 from the personas SSOT relay only says "the file parsed" — it says nothing
# about the payload SHAPE, and every wave prompt is composed from that payload.
ck "workflow.js validates the personas relay PAYLOAD, not just its rc" \
  "grep -qF 'function missingPersonas' '$WORKFLOW' \
    && grep -qF 'personas payload unusable' '$WORKFLOW'"
# A resumed run must not lose the donor catalog (the Field Scout fleet is the
# cross-domain import /uberthink exists for).
ck "a resumed run rehydrates the donor catalog before skipping the scope gate" \
  "grep -qF 'resumedDonors.donors.length > 0' '$WORKFLOW'"
ck "scope-verdict.yaml is contracted to record the donor slugs" \
  "grep -qF 'donors:' '$AGENTS_DIR/uberthink-frame.md'"

echo "== U13: report.py tests pass (source tests/uberthink-report.test.sh) =="
# T1 owns report.py and its own unit tests in tests/uberthink-report.test.sh.
# We do not duplicate those asserts here — we run that file and assert green +
# 'ALL REPORT TESTS PASS' marker line in its stdout (the python heredoc inside
# T1's test prints that token on success).
if [ -r "$REPORT_TEST" ]; then
  if REPORT_OUT="$(bash "$REPORT_TEST" 2>&1)"; then
    REPORT_RC=0
  else
    REPORT_RC=$?
  fi
  ck_msg "tests/uberthink-report.test.sh exits 0" \
    "[ $REPORT_RC -eq 0 ]" \
    "report.py test exited $REPORT_RC; last lines: $(printf '%s\n' \"\$REPORT_OUT\" | tail -5)"
  ck_msg "report.py output contains 'ALL REPORT TESTS PASS' marker" \
    "grep -q 'ALL REPORT TESTS PASS' <<<\"\$REPORT_OUT\"" \
    "marker missing from report.py test stdout (scoring-contract python heredoc did not reach print)"
else
  ck_msg "tests/uberthink-report.test.sh present" "false" \
    "expected sibling file $REPORT_TEST (owned by T1)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

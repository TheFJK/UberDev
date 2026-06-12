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
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$REPO_ROOT/plugins/uberdev/commands/uberthink.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/SKILL.md"
PERSONAS="$REPO_ROOT/plugins/uberdev/skills/uberthink-pipeline/personas.yaml"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
F2I="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
AGENTS_DIR="$REPO_ROOT/plugins/uberdev/agents"
REPORT_TEST="$REPO_ROOT/tests/uberthink-report.test.sh"

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

echo "== U5: SKILL.md single-message invariant =="
# Match the wording the orchestrator pipeline actually uses ("SINGLE assistant message")
# — this is the load-bearing token that gets repeated at every wave dispatch and
# the one a refactor would most likely accidentally weaken.
ck "SKILL.md contains 'SINGLE assistant message' invariant" "grep -q 'SINGLE assistant message' '$SKILL'"
# Sanity: the directive-emitter framing line should be present too — the bash
# blocks return in ms and the orchestrating session fires the Task() fanout.
ck "SKILL.md describes directive-emitter pattern" "grep -qE 'each bash block emits directives' '$SKILL'"

echo "== U6: SKILL.md has all 6 CB ids =="
for cb in CB-LOOP CB-WAVE CB-FLOOD CB-CLOCK CB-CONVERGE CB-ISLAND; do
  ck "SKILL.md mentions $cb" "grep -q '$cb' '$SKILL'"
done

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

echo "== U9: scope-gate REFUSE halt present =="
# The schema lens's scope-gate writes CIRCUIT_BREAKER_HALT=SCOPE_REFUSE to
# run-state.txt and exits before any fanout (spec §5 safety lens).
ck "SKILL.md sets CIRCUIT_BREAKER_HALT=SCOPE_REFUSE on REFUSE" \
  "grep -q 'CIRCUIT_BREAKER_HALT=SCOPE_REFUSE' '$SKILL'"
ck "SKILL.md describes scope-gate halting before fanout" \
  "grep -qE 'scope-gate REFUSE|halted before any fanout' '$SKILL'"

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

echo "== U12: report.py tests pass (source tests/uberthink-report.test.sh) =="
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
    "printf '%s' \"\$REPORT_OUT\" | grep -q 'ALL REPORT TESTS PASS'" \
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

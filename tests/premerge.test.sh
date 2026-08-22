#!/usr/bin/env bash
# tests/premerge.test.sh — shape gates for /uberdev:premerge (RFC 0021).
# Pure grep + structural assertions, no execution. Runs on ubuntu + windows.
# The BEHAVIOUR of lib/premerge-findings.py is covered by the Unix-only
# tests/premerge-findings.test.sh, which imports and runs it — this file
# deliberately asserts only what a grep can honestly prove.
#
# Sections:
#   P1   — commands/premerge.md frontmatter (description, argument-hint, allowed-tools)
#   P1b  — allowed-tools omits Workflow: the pipeline mandates no Workflow call,
#          and an unused grant in a file this repo treats as a security surface
#          is a real over-grant
#   P2   — skills/premerge-pipeline/SKILL.md name + all six phase headings
#   P2b  — renderer-hazard free: no `awk '...$N...'` column refs in either file
#          (the skill renderer substitutes $ARGUMENTS positionals into them)
#   P2c  — THE never-merge invariant: no merge primitive anywhere in either file
#   P2d  — no `for x in $SCALAR` bashism; the argument loop uses `while IFS= read -r`
#   P3   — lib/premerge-findings.py exposes both verbs and the anti-drift gate
#   P4   — premerge-aggregate is declared in all THREE sites that must agree
#   P5   — agents/findings-to-issues.md SUGGESTION tier: arm, default-closed gate,
#          rank, non-halting, and its own distinct label
#   P5b  — the gate is single-armed: SUGGESTION_TIER_ENABLED is SET in exactly one
#          place, so no other caller can reach the new tier
#   P6   — alias SSOT row present + byte-match against premerge.md allowed-tools
#   P7   — vendor.json carries the new skill directory (C-COVER would red without it)
#   P8   — docs/rfc/0021-premerge-stack-integration.md exists, non-empty, unique
#   P9   — README carries the TL;DR row and the per-command section
#   P10  — no trust-trail emission: /premerge must not claim review evidence
#          /merge's PATH_2 would accept
#   P11  — the convergence loop's surfaces (RFC 0021 Amendment A1): the CONVERGE
#          and VERIFY headings, the repair routing, the CI-repair agents
#   P11b — every uberdev:<agent> the SKILL dispatches resolves to an agent card
#          on disk. A typo here is a dispatch that fails at runtime, in the
#          middle of an autonomous loop, with nobody watching
#   P12  — the new flags are declared in BOTH the command and the pipeline
#          skill. One surface knowing about a flag the other refuses is how an
#          argument-hint starts advertising a refusal
#   P13  — the loop is bounded: a ceiling is named and the never-merge and
#          never-loop-forever claims are both stated

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

CMD="$REPO_ROOT/plugins/uberdev/commands/premerge.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/SKILL.md"
LIB="$REPO_ROOT/plugins/uberdev/lib/premerge-findings.py"
PRIMITIVES="$REPO_ROOT/plugins/uberdev/lib/report_primitives.py"
F2I="$REPO_ROOT/plugins/uberdev/agents/findings-to-issues.md"
SYNC="$REPO_ROOT/plugins/uberdev/lib/aliases-sync.sh"
VENDOR="$REPO_ROOT/plugins/uberdev/vendor.json"
RFC="$REPO_ROOT/docs/rfc/0021-premerge-stack-integration.md"
README="$REPO_ROOT/README.md"

# Pre-flight: refuse to run if any asserted-against file is missing. A shape test
# whose subject vanished must fail loudly, never report zero findings.
for f in "$CMD" "$SKILL" "$LIB" "$PRIMITIVES" "$F2I" "$SYNC" "$VENDOR" "$RFC" "$README"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

assert_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" "$file"; then
    echo "  FAIL  $desc"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

assert_fixed() {
  local file="$1" literal="$2" desc="$3"
  if grep -qF -e "$literal" "$file"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; FAIL=$((FAIL + 1))
  fi
}

# SKILL.md holds executable fences AND the prose that documents them, so a
# whole-file grep for a flag is satisfied by the paragraph EXPLAINING the flag
# even after the fence that passes it is gone. Every assertion about what the
# pipeline actually RUNS is made against this extraction instead.
#
# Pure bash state machine, not awk: a single-quoted awk program with a column
# reference is rewritten by the skill renderer before awk ever parses it (P2b),
# and this file is where that hazard is documented.
extract_fences() {
  local source_file="$1" target_file="$2" inside=0 raw
  : >"$target_file"
  while IFS= read -r raw; do
    case "$raw" in
      # Only at column 0, and only when NOT already inside a fence. An opener
      # quoted as an example inside another block would otherwise start
      # capturing prose — and prose is precisely what these assertions exist to
      # tell apart from executable content.
      '```bash uberdev-executable'*)
        [ "$inside" = "1" ] || inside=1
        continue ;;
      '```'*)
        [ "$inside" = "1" ] && inside=0
        continue ;;
    esac
    [ "$inside" = "1" ] && printf '%s\n' "$raw" >>"$target_file"
  done <"$source_file"
  # An unterminated fence would silently swallow the rest of the file.
  if [ "$inside" = "1" ]; then
    echo "  FAIL  extract_fences: unterminated fence in $source_file"
    FAIL=$((FAIL + 1))
    return 1
  fi
  return 0
}

assert_count_fixed() {
  local file="$1" literal="$2" want="$3" desc="$4"
  local got
  got="$(grep -cF -e "$literal" "$file")"
  if [ "$got" = "$want" ]; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (want $want, got $got)"; FAIL=$((FAIL + 1))
  fi
}

echo "== P1: commands/premerge.md frontmatter =="
assert_grep "$CMD" '^description: ".+"$' "P1: description present and double-quoted"
assert_grep "$CMD" '^argument-hint: ".*"$' "P1: argument-hint present"
assert_grep "$CMD" '^allowed-tools: \[".+"\]$' "P1: allowed-tools is a one-line JSON array"

echo "== P1b: allowed-tools omits Workflow =="
CMD_TOOLS="$(grep '^allowed-tools:' "$CMD" | head -1 | sed -E 's/^allowed-tools:[[:space:]]*//')"
case "$CMD_TOOLS" in
  *Workflow*)
    echo "  FAIL  P1b: allowed-tools grants Workflow, but the pipeline mandates no Workflow call"
    FAIL=$((FAIL + 1)) ;;
  *)
    echo "  PASS  P1b: allowed-tools grants no unused Workflow"; PASS=$((PASS + 1)) ;;
esac
case "$CMD_TOOLS" in
  *Task*) echo "  PASS  P1b: allowed-tools grants Task (the fixer + lens fanouts)"; PASS=$((PASS + 1)) ;;
  *)      echo "  FAIL  P1b: allowed-tools must grant Task"; FAIL=$((FAIL + 1)) ;;
esac

echo "== P2: SKILL.md identity and phase coverage =="
assert_grep "$SKILL" '^name: premerge-pipeline$' "P2: skill name matches its directory"
assert_grep "$SKILL" '^description: Use when /uberdev:premerge is invoked\.' "P2: description opens with the invocation clause"
assert_grep "$SKILL" '^## Phase 0 — PACK$' "P2: Phase 0 PACK heading"
assert_grep "$SKILL" '^## Phase 1 — REVIEW$' "P2: Phase 1 REVIEW heading"
assert_grep "$SKILL" '^## Phase 2 — TRIAGE$' "P2: Phase 2 TRIAGE heading"
assert_grep "$SKILL" '^## Phase 3 — CLEAN GATE$' "P2: Phase 3 CLEAN GATE heading"
assert_grep "$SKILL" '^## Phase 4 — SIMPLIFY$' "P2: Phase 4 SIMPLIFY heading"
assert_grep "$SKILL" '^## Phase 5 — BUMP \+ PARK$' "P2: Phase 5 BUMP + PARK heading"
assert_fixed "$SKILL" 'Skill("code-review"' "P2: dispatches the BUILT-IN code-review skill"
assert_fixed "$SKILL" 'subagent_type: uberdev:code-simplifier' "P2: Phase 4 names the code-simplifier agent"
assert_fixed "$SKILL" 'subagent_type: uberdev:findings-to-issues' "P2: Phase 2b names the findings-to-issues agent"

echo "== P2b: skill-renderer awk collision hazard absent =="
# The renderer substitutes $ARGUMENTS positionals into single-quoted awk bodies,
# so `awk '{print $1}'` arrives with $1 already replaced.
assert_no_grep "$CMD" "awk '[^']*\\\$[0-9]" "P2b: command has no awk \$N column ref"
assert_no_grep "$SKILL" "awk '[^']*\\\$[0-9]" "P2b: SKILL.md has no awk \$N column ref"

echo "== P2c: the never-merge invariant =="
# `^[^`]*` and not a bare match: BOTH files talk ABOUT merging, at length, to say
# they never do it — and a prose prohibition is the opposite of a violation. The
# leading no-backtick run is what distinguishes an executable occurrence from a
# cited one, so this stays falsifiable without punishing the documentation that
# makes the rule enforceable in the first place.
for f in "$CMD" "$SKILL"; do
  base="${f##*/}"
  assert_no_grep "$f" '^[^`]*gh pr merge' "P2c: $base issues no gh pr merge"
  assert_no_grep "$f" '^[^`]*gh pr merge .*--auto' "P2c: $base enables no auto-merge"
  assert_no_grep "$f" '^[^`]*gh pr review .*--approve' "P2c: $base self-approves nothing"
done
# Anti-vacuity: the guarded literal must actually occur SOMEWHERE in the file, or
# a future rewrite that drops the never-merge prose would leave three assertions
# passing over a subject that no longer discusses merging at all.
assert_fixed "$SKILL" 'gh pr merge' "P2c: SKILL.md names the forbidden primitive (anti-vacuity)"
assert_fixed "$SKILL" "never merges" "P2c: SKILL.md states the never-merge rule"
assert_fixed "$CMD" "never merges" "P2c: command states the never-merge rule"

echo "== P2d: cross-shell argument parsing =="
# `for x in $SCALAR` runs ONCE over the whole string under zsh; the fences run
# through /bin/zsh, so the read-loop form is the only correct one.
assert_no_grep "$SKILL" '^[^`]*for [A-Za-z_]+ in \$\{?ARGUMENTS' "P2d: no for-loop over \$ARGUMENTS"
assert_fixed "$SKILL" 'while IFS= read -r PREMERGE_TOKEN' "P2d: argument loop uses while IFS= read -r"
# The SPLIT is the half that is easy to get wrong: `printf '%s\n' $ARGUMENTS`
# emits one line per token under bash and ONE line under zsh, so the loop above
# would see a single unmatched token and refuse a valid invocation. The fences
# run through /bin/zsh, so the expansion must be quoted and split by `tr`.
assert_no_grep "$SKILL" "^[^\`]*printf '%s..n' \\\$\\{?ARGUMENTS" "P2d: the argument split does not rely on bash word-splitting"
assert_fixed "$SKILL" "printf '%s' \"\${ARGUMENTS:-}\" | tr '[:space:]' '\\n'" "P2d: the split quotes the expansion and lets tr do the work"
assert_no_grep "$SKILL" '\btype -t\b' "P2d: no type -t bashism"
assert_no_grep "$SKILL" 'BASH_REMATCH' "P2d: no BASH_REMATCH bashism"

echo "== P3: lib/premerge-findings.py surface =="
assert_fixed "$LIB" 'sub.add_parser("plan"' "P3: the plan verb is registered"
assert_fixed "$LIB" 'sub.add_parser("assert-green"' "P3: the assert-green verb is registered"
assert_fixed "$LIB" 'AGGREGATE_SOURCE = "premerge-aggregate"' "P3: aggregate source constant"
assert_fixed "$LIB" 'CLEANUP_CATEGORIES' "P3: the cleanup-category set exists"
assert_fixed "$LIB" '"severity_contradicts_category"' "P3: the category-overrules-controller gate exists"
assert_fixed "$LIB" 'SEVERITIES = frozenset({"blocker", "suggestion"})' "P3: severity vocabulary matches schema v2"

echo "== P4: premerge-aggregate declared in all three sites =="
assert_fixed "$PRIMITIVES" '"premerge-aggregate",' "P4: report_primitives ACCEPTED_SOURCES"
assert_fixed "$F2I" 'premerge-aggregate' "P4: findings-to-issues closed source set"
assert_fixed "$LIB" 'premerge-aggregate' "P4: premerge-findings.py"

echo "== P5: findings-to-issues SUGGESTION tier =="
assert_fixed "$F2I" 'row_tier="SUGGESTION"' "P5: the SUGGESTION arm exists"
assert_fixed "$F2I" '${SUGGESTION_TIER_ENABLED:-0}' "P5: the arm is gated, default-closed"
assert_fixed "$F2I" 'severity_rank(suggestion)=0' "P5: suggestion ranks below every other tier"
assert_grep "$F2I" 'MAJOR\|SUGGESTION\)' "P5: SUGGESTION files silently, like MAJOR"
assert_fixed "$F2I" 'premerge.defer.findings' "P5: the origin-routing arm exists"
assert_fixed "$F2I" 'premerge-finding' "P5: the tier gets its own label, not review-pr-finding"
assert_fixed "$F2I" 'suggestion: 0' "P5: by_severity carries a suggestion counter"

echo "== P5b: the gate is single-armed =="
# Exactly ONE assignment. If a second appears, some other caller can reach the
# tier and every /review-pr suggestion in the repo starts getting filed.
assert_count_fixed "$F2I" 'SUGGESTION_TIER_ENABLED=1' 1 "P5b: SUGGESTION_TIER_ENABLED is set in exactly one place"

echo "== P6: alias SSOT row =="
assert_grep "$SYNC" '^premerge\|premerge\|' "P6: alias SSOT row present"
SSOT_TOOLS="$(grep -F 'premerge|premerge|' "$SYNC" | sed 's/.*premerge|//')"
if [ "$CMD_TOOLS" = "$SSOT_TOOLS" ]; then
  echo "  PASS  P6: SSOT allowed-tools byte-match"; PASS=$((PASS + 1))
else
  echo "  FAIL  P6: SSOT allowed-tools drift"; FAIL=$((FAIL + 1))
  echo "        cmd : $CMD_TOOLS"
  echo "        ssot: $SSOT_TOOLS"
fi

echo "== P7: vendor register coverage =="
assert_fixed "$VENDOR" '"id": "skills/premerge-pipeline"' "P7: vendor.json declares the new skill dir"

echo "== P8: RFC =="
if [ -s "$RFC" ]; then
  echo "  PASS  P8: RFC 0021 exists and is non-empty"; PASS=$((PASS + 1))
else
  echo "  FAIL  P8: RFC 0021 missing or empty"; FAIL=$((FAIL + 1))
fi
RFC_COUNT="$(ls "$REPO_ROOT/docs/rfc/" | grep -c '^0021-')"
if [ "$RFC_COUNT" -eq 1 ]; then
  echo "  PASS  P8: RFC number 0021 is unique"; PASS=$((PASS + 1))
else
  echo "  FAIL  P8: RFC number 0021 appears $RFC_COUNT times"; FAIL=$((FAIL + 1))
fi
assert_grep "$RFC" '^# RFC 0021 — ' "P8: RFC header carries its number"

echo "== P9: README surfaces =="
assert_fixed "$README" '**`/premerge [<level>]`**' "P9: TL;DR table row"
assert_grep "$README" '^## `/premerge` — ' "P9: per-command section"

echo "== P10: no trust trail =="
for f in "$CMD" "$SKILL"; do
  base="${f##*/}"
  assert_no_grep "$f" 'uberdev-approved' "P10: $base emits no approval label"
  assert_no_grep "$f" '^[^#]*Reviewed-by:' "P10: $base emits no Reviewed-by trailer"
done

echo "== P11: the convergence loop's surfaces =="
assert_grep "$SKILL" '^## Phase 3b — CONVERGE$' "P11: the CONVERGE phase heading"
assert_grep "$SKILL" '^### 4c — VERIFY$' "P11: the post-simplify VERIFY heading"
assert_grep "$SKILL" '^### 3c — Repair, by reason$' "P11: the repair routing heading"
assert_fixed "$SKILL" 'subagent_type: uberdev:ci-failure-classifier' "P11: red CI is classified before it is repaired"
assert_fixed "$SKILL" 'uberdev:ci-code-fixer' "P11: the code_bug/env_drift arm names its fixer"
assert_fixed "$SKILL" 'uberdev:ci-rebase-handler' "P11: the stale_base arm names its handler"
# The two classes no number of attempts can fix. Looping on either burns the
# budget and then reports exhaustion, which describes the wrong thing entirely.
assert_fixed "$SKILL" 'billing_quota' "P11: billing_quota is named as a non-loopable class"
assert_fixed "$SKILL" 'platform_outage' "P11: platform_outage is named as a non-loopable class"
echo "== P11c: what the pipeline actually RUNS, read from the fences only =="
FENCES="$(mktemp)"
trap 'rm -f "$FENCES"' EXIT
extract_fences "$SKILL" "$FENCES" || :
# Anti-vacuity: an extraction that silently produced nothing would make every
# row below pass over an empty file.
FENCE_LINES="$(grep -c . "$FENCES")"
if [ "$FENCE_LINES" -ge 100 ]; then
  echo "  PASS  P11c: extracted $FENCE_LINES lines of executable fence"; PASS=$((PASS + 1))
else
  echo "  FAIL  P11c: fence extraction yielded only $FENCE_LINES lines — every row below is vacuous"; FAIL=$((FAIL + 1))
fi
assert_fixed "$FENCES" 'premerge-findings.py" converge' "P11c: a fence calls the converge verb"
assert_fixed "$FENCES" '--carry-prior' "P11c: a fence carries prior suggestions into the aggregate"
assert_fixed "$FENCES" '--attempt "$PREMERGE_ATTEMPT"' "P11c: a fence scopes the plan to the attempt"
# The settle-window race (RFC 0021 §9) becomes load-bearing under a loop: every
# attempt ends in a push, so `no_checks` reading as green is not an edge case.
# These two must be PASSED, not merely explained — the paragraph explaining a
# flag survives the deletion of the fence that passes it.
assert_fixed "$FENCES" 'set -- "$@" --after-push' "P11c: a fence tells the gate the attempt pushed"
assert_fixed "$FENCES" '--head-sha "$PREMERGE_HEAD_SHA"' "P11c: a fence tells the gate which SHA the evidence describes"
assert_fixed "$FENCES" '--wait-passes "$PREMERGE_WAIT_PASSES"' "P11c: a fence carries the WAIT_CI counter across the fence boundary"
# The ordering guard. Fixers dispatched BEFORE the gate deadlock the loop: plan
# stamps the reviewed SHA, the fix commit moves HEAD, and the gate then reports
# stale_evidence on every attempt that actually worked. The commit fence refuses
# without a not_green verdict for the attempt, which is what makes the ordering
# structural instead of a convention someone can quietly invert.
assert_fixed "$FENCES" 'gate-$PREMERGE_ATTEMPT_PAD.json' "P11c: a fence keys evidence to the attempt it belongs to"
assert_fixed "$FENCES" 'the gate runs BEFORE the fixers' "P11c: the fix commit refuses without a gate verdict for its attempt"
assert_fixed "$FENCES" 'PREMERGE_GATE_SAID" != "not_green"' "P11c: the fix commit refuses when the gate did not ask for a repair"
# The PREDICATE, not just its message. The two rows above match the printf text
# and the verdict comparison, so neutralising the file-existence test (`if false`,
# or dropping the `!`) left all of them green — the guard was only half-locked.
assert_fixed "$FENCES" '[ ! -s "$PREMERGE_GATE_FILE" ]' "P11c: the missing-gate-file predicate itself is locked"
assert_grep "$SKILL" '^## The order within one attempt$' "P11c: the load-bearing ordering is written down, not inferred"

echo "== P11b: every dispatched agent resolves to a card on disk =="
# EVERY `uberdev:<name>` the file mentions, not only the `subagent_type:` ones.
# Two of the five agents this pipeline dispatches — ci-code-fixer and
# ci-rebase-handler — are named in the 3c routing table without that prefix, so a
# subagent_type-only scan checked three of five and reported success. A rename or
# a typo in the routing table would then surface as a failed Task dispatch
# mid-loop, on a stale_base CI failure, unattended.
P11B_MISSING=""
P11B_SEEN=0
while IFS= read -r P11B_NAME; do
  [ -n "$P11B_NAME" ] || continue
  P11B_SEEN=$((P11B_SEEN + 1))
  if [ ! -r "$REPO_ROOT/plugins/uberdev/agents/$P11B_NAME.md" ]; then
    P11B_MISSING="$P11B_MISSING $P11B_NAME"
  fi
done <<EOF_P11B
$(grep -oE 'uberdev:[a-z0-9-]+' "$SKILL" | sed 's/.*uberdev://' | sort -u \
  | grep -vE '^(premerge|premerge-pipeline|simplify|review-pr|merge|goal|solve|turbo|turbox|issue|dev|testers|cluster|uberscan|ubersimplify|uberthink|code-review)$')
EOF_P11B
if [ "$P11B_SEEN" -lt 5 ]; then
  echo "  FAIL  P11b: only $P11B_SEEN agent names found, expected >=5 — this row is vacuous"; FAIL=$((FAIL + 1))
elif [ -n "$P11B_MISSING" ]; then
  echo "  FAIL  P11b: dispatched agents with no card:$P11B_MISSING"; FAIL=$((FAIL + 1))
else
  echo "  PASS  P11b: all $P11B_SEEN dispatched uberdev agents resolve"; PASS=$((PASS + 1))
fi

echo "== P12: the new flags are declared on BOTH surfaces =="
# A flag the command advertises and the skill's ONE parse site refuses is an
# argument-hint that documents a refusal. Both files, every flag.
for P12_FLAG in --converge --no-converge --no-ci-fix --no-post-simplify-review; do
  assert_fixed "$CMD" "$P12_FLAG" "P12: commands/premerge.md documents $P12_FLAG"
done
# Against the parse ARMS, not the flag name, and not the whole SKILL. Two layers
# of vacuity to get past here: the paragraph that EXPLAINS a flag survives the
# deletion of the arm that accepts it, and so does the refusal message inside the
# very same fence, which lists every flag by name. Only the `case` arm makes the
# invocation work, so the `)` is what the assertion has to see.
for P12_ARM in '--converge=*)' '--no-converge)' '--no-ci-fix)' '--no-post-simplify-review)'; do
  assert_fixed "$FENCES" "$P12_ARM" "P12: a SKILL fence has a parse arm for ${P12_ARM%)}"
done
# The parse site stays singular. A second `case` arm for a level or a flag
# somewhere else in the file is how two spellings of one option drift apart.
assert_count_fixed "$SKILL" 'this fence is the ONLY parse site' 1 "P12: the argument parse site is still declared singular"

echo "== P13: the loop is bounded, and says so =="
assert_fixed "$LIB" 'CONVERGE_REPAIR_CEILING' "P13: the library declares a runaway ceiling"
# The budget counts REPAIRS. Counting reviews makes --converge=1 buy zero
# repairs, under a flag documented as reproducing the pre-loop behaviour.
assert_fixed "$LIB" 'attempt > max_repairs' "P13: the backstop is spent only PAST the repair budget"
assert_fixed "$LIB" 'CONVERGE_WAIT_CI_CEILING' "P13: the library bounds CI waiting too"
assert_fixed "$LIB" 'sub.add_parser("converge"' "P13: the converge verb is registered"
assert_fixed "$LIB" 'CONVERGE_DECISIONS' "P13: the decision vocabulary is a declared set"
assert_fixed "$SKILL" 'STOP_NO_PROGRESS' "P13: the SKILL names the evidence-based stop"
assert_fixed "$SKILL" 'STOP_REGRESSED' "P13: the SKILL names the regression stop"
# The whole point of the amendment: the counter is the backstop, not the rule.
# If a future edit deletes the progress detectors and leaves only the counter,
# this row is what notices.
assert_grep "$SKILL" 'runaway backstop' "P13: the counter is described as a backstop, not the stop condition"

echo "== P14: the three promises that used to have no producer =="
assert_fixed "$LIB" 'sub.add_parser("defer"' "P14: the defer verb is registered"
assert_fixed "$FENCES" 'premerge-findings.py" defer' "P14: a fence actually calls it"
assert_fixed "$FENCES" '[ "$PREMERGE_SURVIVORS" = "1" ] && set -- "$@" --include-blockers' "P14: surviving blockers reach the aggregate, on the condition that names them"
assert_fixed "$FENCES" '--lens-findings' "P14: un-applied lens findings reach the aggregate"
assert_fixed "$SKILL" 'lens-deferred.json' "P14: Phase 4b names the file it must write"
# 4c re-gating without re-stamping compares pre-simplify evidence against the
# post-simplify SHA — stale_evidence by construction, so the verify step would
# fire on every run and revert every correct polish pass.
assert_fixed "$SKILL" 'The **Phase 2 triage fence** at the new attempt index' "P14: 4c re-stamps the evidence before re-gating"
assert_fixed "$SKILL" 'do not route this' "P14: 4c does not crash on a spent repair budget"
# The CI agents DO run git locally; conflating them with the wave agents makes a
# CI repair silently no-op through a commit fence that finds a clean tree.
assert_fixed "$SKILL" '--force-with-lease' "P14: the rebase arm publishes under a lease"
assert_grep "$SKILL" 'Assuming that rule covers the CI agents too' "P14: the wave-agent git rule is scoped away from the CI agents"

echo "== P15: the gate builds an argv LIST, not a string =="
# The fences run through /bin/zsh, which does NOT word-split an unquoted scalar.
# `assert-green $ARGS` hands argparse one giant argv element, argparse exits 2,
# and the fail-closed default pins EVERY gate to not_green/gate_unreadable —
# including a clean stack. STOP_GREEN becomes unreachable and the loop can never
# finish. This shipped in v0.53.0 behind the plugin's only SC2086 waiver.
assert_fixed "$FENCES" 'set -- --classified "$PREMERGE_CLASSIFIED"' "P15: the gate accumulates argv with set --"
assert_fixed "$FENCES" 'assert-green "$@"' "P15: the gate passes the list, quoted"
# Anchored past a leading `#`, and to a directive line that is ONLY the
# directive: the fence explains this hazard at length in comments, and an
# assertion that cannot tell the warning from the bug would force the
# explanation out — which is how the lesson gets lost the next time.
assert_no_grep "$FENCES" '^[^#]*assert-green \$PREMERGE_GATE_ARGS' "P15: no unquoted-scalar argument splatting survives"
assert_no_grep "$FENCES" '^[[:space:]]*# shellcheck disable=SC2086[[:space:]]*$' "P15: the SC2086 waiver that hid it is gone"
assert_fixed "$SKILL" 'zsh does not word-split an unquoted scalar' "P15: and the reason is written down (anti-vacuity)"

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

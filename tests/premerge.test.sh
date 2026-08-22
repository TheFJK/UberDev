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

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

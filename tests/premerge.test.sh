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
#   P3b  — the CLEANUP_CATEGORIES set transcribed into SKILL.md is compared,
#          set-for-set, with the one the library actually EVALUATES. The only
#          other test touching the constant is a grep that the identifier
#          exists, which stays green whichever copy drifts (#699)
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
#   P17  — the stack-gate blockers, every row scoped to an extracted fence body:
#          the scope guard's two halves fail in the same direction (#693), one
#          rule for advancing PREMERGE_ATTEMPT (#692), one aggregate_path (#694),
#          --after-push asks whether the PR gets checks (#695), the flaky rerun
#          is bounded from the ledger (#696), the CI-repair arm carries the three
#          load-bearing checks (#697), every fence root resolution is guarded
#          (#700), and a defer overflow is survivable and loud (#690)
#   P16  — repo-agnosticism: Phase 5's bump probes the TARGET repo (not the
#          plugin install), passes that root through to bump-version.sh, and
#          skips with a typed reason elsewhere; Phase 0 publishes the private
#          ignore policy that keeps the run dir out of a foreign repo's
#          cleanliness gate

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
GOAL_STATE="$REPO_ROOT/plugins/uberdev/lib/goal-state.sh"

# Pre-flight: refuse to run if any asserted-against file is missing. A shape test
# whose subject vanished must fail loudly, never report zero findings.
for f in "$CMD" "$SKILL" "$LIB" "$PRIMITIVES" "$F2I" "$SYNC" "$VENDOR" "$RFC" "$README" "$GOAL_STATE"; do
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
assert_fixed "$SKILL" 'subagent_type: uberdev:findings-to-issues' "P2: Phase 5-file names the findings-to-issues agent"

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

echo "== P3b: the CLEANUP_CATEGORIES copy in SKILL.md == the library's real set =="
# #699. The set is TRANSCRIBED into SKILL.md because the controller that writes
# `severity` never opens the library, and until now the only test touching the
# constant was `assert_fixed "$LIB" 'CLEANUP_CATEGORIES'` above — a grep that the
# identifier exists, which stays green whichever copy drifts. That is the "one
# contract, N uncompared copies" class this repo registered as #370/#371, and the
# copy with nothing behind it is the one the controller actually reads.
#
# So: EVALUATE the library's set (never parse it — a frozenset can be built by
# any expression) and compare it with the tokens in the tagged SKILL.md block.
# Drift is `severity_contradicts_category`: `plan` exits 74 having written
# nothing, and the attempt dies because the reviewer used a synonym.
#
# Cross-platform import (#268 CI): `cd` into the lib dir and hand python3 a
# RELATIVE filename — a Git Bash absolute path (/d/a/...) is not a path native
# Windows python can open. `tr -d '\r'`: native-Windows python writes CRLF.
LIB_DIR="$(dirname "$LIB")"
LIB_BASE="$(basename "$LIB")"
P3B_ERR="$(mktemp)"
P3B_PY_SET="$( (cd "$LIB_DIR" && python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('premerge_findings', '$LIB_BASE')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('\n'.join(sorted(mod.CLEANUP_CATEGORIES)))
") 2>"$P3B_ERR" | tr -d '\r')"
# The tagged block, split on whitespace. Tagged rather than positional so a
# reflow of the surrounding prose cannot silently move the anchor.
P3B_DOC_SET="$(sed -n '/^[[:space:]]*```text premerge-cleanup-categories$/,/^[[:space:]]*```$/p' "$SKILL" \
  | sed -e '1d' -e '$d' | tr '[:space:]' '\n' | grep -v '^$' | LC_ALL=C sort -u)"
P3B_PY_N="$(grep -c . <<<"$P3B_PY_SET")"
P3B_DOC_N="$(grep -c . <<<"$P3B_DOC_SET")"
# Anti-vacuity FIRST: two empty strings compare equal, which is exactly how this
# row would report success over an import that failed and an anchor that moved.
if [ "$P3B_PY_N" -lt 10 ]; then
  echo "  FAIL  P3b: CLEANUP_CATEGORIES did not import ($P3B_PY_N members)"
  [ -s "$P3B_ERR" ] && echo "        python stderr: $(tr '\n' ' ' <"$P3B_ERR")"
  FAIL=$((FAIL + 1))
elif [ "$P3B_DOC_N" -lt 10 ]; then
  echo "  FAIL  P3b: the premerge-cleanup-categories block yielded $P3B_DOC_N tokens — the tag moved"; FAIL=$((FAIL + 1))
elif [ "$P3B_PY_SET" = "$P3B_DOC_SET" ]; then
  echo "  PASS  P3b: SKILL.md's cleanup vocabulary == the library's $P3B_PY_N-slug CLEANUP_CATEGORIES"; PASS=$((PASS + 1))
else
  echo "  FAIL  P3b: the two cleanup-category copies have drifted"
  echo "        library only: $(comm -23 <(printf '%s\n' "$P3B_PY_SET") <(printf '%s\n' "$P3B_DOC_SET") | tr '\n' ' ')"
  echo "        SKILL only:   $(comm -13 <(printf '%s\n' "$P3B_PY_SET") <(printf '%s\n' "$P3B_DOC_SET") | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
fi
rm -f "$P3B_ERR"

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
# --- fence extraction --------------------------------------------------------
# Every P16 row below asserts against a FENCE BODY, never against the whole file.
# The first draft of this section did the latter and was worthless: each row was
# satisfiable by the surrounding prose, so a SKILL.md that had stopped bumping
# altogether still passed 6/6. Prose is not the program.
# The opener match is EXACT, not a prefix. `index(...) == 1` accepted
# `origin=premerge-ci-rerun-DISABLED` as `premerge-ci-rerun`, so renaming a tag —
# which is exactly how a fence gets orphaned from the orchestrator that calls it
# by name — extracted the body anyway and every row scoped to it stayed green.
fence_body() {  # fence_body FILE ORIGIN_TAG -> body on stdout
  awk -v tag="$2" '
    $0 == "```bash uberdev-executable origin=" tag { inf = 1; next }
    inf && index($0, "```") == 1 { exit }
    inf { print }
  ' "$1"
}

BUMP_FENCE="$(fence_body "$SKILL" premerge-bump)"
APPLY_FENCE="$(fence_body "$SKILL" premerge-bump-apply)"
SCAN_FENCE="$(fence_body "$SKILL" premerge-scan)"

assert_in() {  # assert_in "<body>" <literal> <desc>
  local body="$1" literal="$2" desc="$3"
  if grep -qF -e "$literal" <<<"$body"; then
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"; FAIL=$((FAIL + 1))
  fi
}
assert_not_in() {
  local body="$1" pattern="$2" desc="$3"
  if grep -qE -e "$pattern" <<<"$body"; then
    echo "  FAIL  $desc"; FAIL=$((FAIL + 1))
  else
    echo "  PASS  $desc"; PASS=$((PASS + 1))
  fi
}

echo "== P16: repo-agnostic Phase 5 =="
# Pre-flight: an empty fence body would make every assert_not_in below vacuously
# green, which is the failure mode this whole section exists to avoid.
for pair in "bump:$BUMP_FENCE" "apply:$APPLY_FENCE" "scan:$SCAN_FENCE"; do
  if [ -z "${pair#*:}" ]; then
    echo "  FAIL  P16: fence '${pair%%:*}' extracted empty — the origin tag moved or renamed"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  P16: fence '${pair%%:*}' extracted non-empty"; PASS=$((PASS + 1))
  fi
done

# /premerge is a general PR-phase gate; the version ratchet it drives is UberDev
# SELF-HOSTING machinery. The separation must be decided by the TARGET repo, not
# by the plugin install, which is present in every repo by definition. Forbid the
# CLASS (any test of a path under the plugin root), not one variable spelling.
assert_not_in "$BUMP_FENCE" '\[ ! -[refdxs].*PLUGIN_ROOT' \
  "P16: the bump gate does not decide on a path under the plugin install"
assert_not_in "$APPLY_FENCE" '\[ ! -[refdxs].*PLUGIN_ROOT' \
  "P16: the apply fence does not decide on a path under the plugin install"
assert_in "$BUMP_FENCE" '[ ! -f "$PREMERGE_ROOT/$PREMERGE_VERSION_MANIFEST" ]' \
  "P16: the bump gate probes the target repo's version manifest"
assert_in "$BUMP_FENCE" 'REASON=no-version-ratchet' \
  "P16: a repo without the ratchet is SKIPPED with a typed reason, not failed"

# bump-version.sh resolves its target by walking up from its own on-disk location,
# which under a marketplace install is the plugin cache and not any repo. Passing
# --repo-root is what makes the call correct in the UberDev checkout too.
assert_in "$APPLY_FENCE" 'lib/bump-version.sh' \
  "P16: the apply fence still invokes bump-version.sh (anti-vacuity)"
assert_in "$APPLY_FENCE" '--repo-root "$PREMERGE_ROOT"' \
  "P16: bump-version.sh is told which repo to bump"

# The duplicated probe must sit ABOVE the PREMERGE_NEXT requirement. A run that
# skipped 5a never produced a BUMP_CLASS, so PREMERGE_NEXT is unset — a probe
# below that line dies at `:?` in the one case it was added to cover.
APPLY_PROBE_LN="$(grep -nF -e 'PREMERGE_VERSION_MANIFEST=' <<<"$APPLY_FENCE" | head -1 | cut -d: -f1)"
APPLY_NEXT_LN="$(grep -nF -e 'PREMERGE_NEXT:?' <<<"$APPLY_FENCE" | head -1 | cut -d: -f1)"
if [ -z "$APPLY_PROBE_LN" ] || [ -z "$APPLY_NEXT_LN" ]; then
  echo "  FAIL  P16: apply fence is missing the probe or the PREMERGE_NEXT requirement"; FAIL=$((FAIL + 1))
elif [ "$APPLY_PROBE_LN" -lt "$APPLY_NEXT_LN" ]; then
  echo "  PASS  P16: the apply-fence probe is reachable (precedes PREMERGE_NEXT:?)"; PASS=$((PASS + 1))
else
  echo "  FAIL  P16: the apply-fence probe sits below PREMERGE_NEXT:? and can never fire"; FAIL=$((FAIL + 1))
fi

# ONE decision literal, shared with /goal's own ratchet probe. Compare the
# EXECUTED copies — the Constants row is documentation and drifting it is
# harmless, while drifting either fence silently disables the mandatory bump.
GOAL_MANIFEST="$(sed -n "s/^_UBERDEV_GOAL_VERSION_MANIFEST='\([^']*\)'.*/\1/p" "$GOAL_STATE" | sed -n '1p')"
DOC_MANIFEST="$(sed -n 's/^PREMERGE_VERSION_MANIFEST[[:space:]]*=[[:space:]]\(.*\)$/\1/p' "$SKILL" | sed -n '1p')"
FENCE_MANIFESTS="$(sed -n "s/^PREMERGE_VERSION_MANIFEST='\([^']*\)'.*/\1/p" "$SKILL")"
FENCE_COUNT="$(grep -c . <<<"$FENCE_MANIFESTS")"
FENCE_UNIQ="$(sort -u <<<"$FENCE_MANIFESTS" | grep -c .)"
if [ -z "$GOAL_MANIFEST" ]; then
  echo "  FAIL  P16: could not read _UBERDEV_GOAL_VERSION_MANIFEST from goal-state.sh"; FAIL=$((FAIL + 1))
elif [ "$FENCE_COUNT" != 2 ]; then
  echo "  FAIL  P16: expected 2 executable manifest literals (5a + 5a-apply), found $FENCE_COUNT"; FAIL=$((FAIL + 1))
elif [ "$FENCE_UNIQ" != 1 ]; then
  echo "  FAIL  P16: the two executable manifest literals disagree:"; sed 's/^/          /' <<<"$FENCE_MANIFESTS"
  FAIL=$((FAIL + 1))
elif [ "$FENCE_MANIFESTS" != "$GOAL_MANIFEST"$'\n'"$GOAL_MANIFEST" ]; then
  echo "  FAIL  P16: executed manifest drift — goal='$GOAL_MANIFEST' premerge='$(sed -n 1p <<<"$FENCE_MANIFESTS")'"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  P16: both executed manifest literals agree with /goal"; PASS=$((PASS + 1))
fi
if [ "$DOC_MANIFEST" = "$GOAL_MANIFEST" ]; then
  echo "  PASS  P16: the Constants row documents the same path it executes"; PASS=$((PASS + 1))
else
  echo "  FAIL  P16: Constants row says '$DOC_MANIFEST', code uses '$GOAL_MANIFEST'"; FAIL=$((FAIL + 1))
fi

echo "== P16b: the run dir cannot dirty a foreign working tree =="
# Phase 0a creates .uberdev/premerge/<RUN_ID>/ INSIDE the repo being packed, and
# Phase 0b then refuses to build a combine branch over an unclean tree. This repo
# survives only because its own .gitignore lists `.uberdev/`.
assert_in "$SCAN_FENCE" 'PREMERGE_IGNORE_POLICY="$UBERDEV_PREMERGE_ROOT/.uberdev/premerge/.gitignore"' \
  "P16b: the policy is published inside .uberdev/premerge/"
# NOT at .uberdev/ — that parent is the documented per-repo config root
# (.uberdev/config.yaml, RFC 0006; .uberdev/config.json, RFC 0007), and a `*` one
# level up would permanently un-add a repository's own committed config.
assert_not_in "$SCAN_FENCE" 'PREMERGE_IGNORE_POLICY="[^"]*/\.uberdev/\.gitignore"' \
  "P16b: the policy does not blanket the repo's .uberdev config root"
assert_in "$SCAN_FENCE" 'printf '"'"'*\n'"'"' >"$PREMERGE_IGNORE_POLICY"' \
  "P16b: the policy body is exactly the catch-all, written to the policy path"
assert_in "$SCAN_FENCE" 'if [ ! -e "$PREMERGE_IGNORE_POLICY" ]' \
  "P16b: the policy is written no-clobber"
# No-clobber means "do not truncate someone else's file"; it does NOT mean the
# file that already existed does the job. Verify the EFFECT.
assert_in "$SCAN_FENCE" 'git -C "$UBERDEV_PREMERGE_ROOT" check-ignore -q "$PREMERGE_RUN_DIR"' \
  "P16b: the run dir's ignored-ness is verified, not assumed"
assert_in "$SCAN_FENCE" 'exit 2' \
  "P16b: a run dir git can still see is a refusal (anti-vacuity)"

echo "== P17: the stack-gate blockers (#692-#697, #700) =="
# Every row here is scoped to an EXTRACTED FENCE BODY or to a literal that only
# occurs in prose that is itself the contract. SKILL.md holds code AND the
# paragraphs documenting it, so a whole-file grep for a guard is satisfied by the
# paragraph explaining the guard after the guard is gone.
FIX_FENCE="$(fence_body "$SKILL" premerge-fix-commit)"
GATE_FENCE="$(fence_body "$SKILL" premerge-gate)"
RERUN_FENCE="$(fence_body "$SKILL" premerge-ci-rerun)"
PUBLISH_FENCE="$(fence_body "$SKILL" premerge-ci-publish)"
DEFER_FENCE="$(fence_body "$SKILL" premerge-defer)"
SIMPLIFY_FENCE="$(fence_body "$SKILL" premerge-simplify-commit)"
for pair in "fix-commit:$FIX_FENCE" "gate:$GATE_FENCE" "ci-rerun:$RERUN_FENCE" \
            "ci-publish:$PUBLISH_FENCE" "defer:$DEFER_FENCE" \
            "simplify-commit:$SIMPLIFY_FENCE"; do
  if [ -z "${pair#*:}" ]; then
    echo "  FAIL  P17: fence '${pair%%:*}' extracted empty — the origin tag moved or was renamed"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  P17: fence '${pair%%:*}' extracted non-empty"; PASS=$((PASS + 1))
  fi
done
# The two fences this PR adds are called BY TAG from the prose above them, so the
# tag is a contract and not a label. Anchored to the whole opener line.
assert_grep "$SKILL" '^```bash uberdev-executable origin=premerge-ci-rerun$' \
  "P17: the ci-rerun fence carries exactly its documented origin tag"
assert_grep "$SKILL" '^```bash uberdev-executable origin=premerge-ci-publish$' \
  "P17: the ci-publish fence carries exactly its documented origin tag"
assert_grep "$SKILL" '^```bash uberdev-executable origin=premerge-simplify-commit$' \
  "P17/#710: the simplify-commit fence carries exactly its documented origin tag"

# --- #706: the sort/comm trio is locale-pinned wherever it guards scope -------
# The guard compares PATHS AS BYTES. `sort` orders by the ambient collation and
# `comm`'s merge walk assumes its own; when they disagree the walk desynchronises
# and reports a file present in BOTH lists as a stray, aborting an attempt whose
# fixers behaved correctly. Executed: the same two paths sorted under
# en_US.UTF-8 and under C, compared with `comm -23`, print `lib/Zebra.sh`.
for scope_pair in "fix-commit:$FIX_FENCE" "ci-publish:$PUBLISH_FENCE" \
                  "simplify-commit:$SIMPLIFY_FENCE"; do
  scope_tag="${scope_pair%%:*}"; scope_body="${scope_pair#*:}"
  # COMMENT LINES ARE STRIPPED FIRST. These fences carry their own rationale, and
  # the paragraphs above each guard say the words "sort" and "comm" — so a probe
  # run over the raw body is satisfied by the fence's own prose, which is the
  # failure mode this repo has already shipped in a whole-file grep.
  scope_unpinned="$(printf '%s\n' "$scope_body" \
    | grep -vE '^[[:space:]]*#' \
    | grep -nE '(^|[^=[:alnum:]_./-])(sort|comm)[[:space:]]' \
    | grep -v 'LC_ALL=C' || :)"
  if [ -z "$scope_unpinned" ]; then
    echo "  PASS  P17/#706: every sort/comm in '$scope_tag' is LC_ALL=C-pinned"; PASS=$((PASS + 1))
  else
    echo "  FAIL  P17/#706: unpinned sort/comm in '$scope_tag': $scope_unpinned"; FAIL=$((FAIL + 1))
  fi
done

# --- #710: Phase 4b commits behind the SAME scope guard as Phase 2a ----------
# 4b dispatches the identical one-file-per-agent waves with the identical
# `git add -u`, and had only the branch assertion and the untracked refusal —
# neither of which catches an agent that edited a second TRACKED file, or a
# stray hunk an earlier CI repair left in the tree.
assert_in "$SIMPLIFY_FENCE" 'simplify-scope-$PREMERGE_ATTEMPT_PAD.allowed' \
  "P17/#710: 4b declares an allowed set, since it has no fix-waves file to reuse"
assert_in "$SIMPLIFY_FENCE" 'if [ ! -s "$PREMERGE_SIMPLIFY_SCOPE" ]; then' \
  "P17/#710: a missing allowed set is a refusal, not an empty set"
assert_in "$SIMPLIFY_FENCE" 'comm -23 "$PREMERGE_SIMPLIFY_MODIFIED" "$PREMERGE_SIMPLIFY_ALLOWED"' \
  "P17/#710: and the scope comparison actually runs before git add -u"
assert_in "$SIMPLIFY_FENCE" 'git -C "$PREMERGE_ROOT" diff --name-only --no-renames HEAD >"$PREMERGE_SIMPLIFY_RAW" || exit 2' \
  "P17/#710: it uses the #693-safe producer shape, not a pipeline"

# --- #707: PREMERGE_PUSHED has a stated value at EVERY gate call site --------
# The fence takes it with `:?` and no default precisely so forgetting is loud —
# which only holds if the file says what the value IS everywhere the gate runs.
# It used to say so at `### 4c` step 3 alone; a controller inferring 0 at a gate
# that just pushed gets `no_checks` read as green.
assert_grep "$SKILL" '^### What `PREMERGE_PUSHED` is at each call site$' \
  "P17/#707: the call-site table exists"
for pushed_site in 'first entry at attempt 1' 'premerge-fix-commit' \
                   'premerge-ci-publish' 'WAIT_CI'; do
  assert_grep "$SKILL" "$pushed_site" \
    "P17/#707: the table names the '$pushed_site' call site"
done

# --- #693: the scope guard's two halves must fail in the SAME direction -------
# `<producer> | sort -u >LIST || exit 2` binds the `||` to `sort`'s status, and
# `sort` succeeds on empty input. A failed `git diff` therefore produced an empty
# modified set, an empty stray set, and `git add -u` swept the whole tree into the
# stack commit — a fail-OPEN inside the guard Common Mistakes calls "the
# enforcement". Forbid the SHAPE, not one spelling of it.
assert_not_in "$FIX_FENCE" '\| *sort -u >"\$PREMERGE_(MODIFIED|ASSIGNED)_LIST"' \
  "P17/#693: neither scope list is produced through a pipeline"
assert_in "$FIX_FENCE" 'git -C "$PREMERGE_ROOT" diff --name-only --no-renames HEAD >"$PREMERGE_SCOPE_RAW" || exit 2' \
  "P17/#693: git diff's OWN status is checked before anything sorts it"
assert_in "$FIX_FENCE" 'sort -u <"$PREMERGE_SCOPE_RAW" >"$PREMERGE_MODIFIED_LIST" || exit 2' \
  "P17/#693: the sort is a separate, separately-checked step"
assert_in "$FIX_FENCE" 'jq -r '"'"'.waves[][].file'"'"' <"$PREMERGE_WAVES_FILE" >"$PREMERGE_SCOPE_RAW" || exit 2' \
  "P17/#693: the sibling half is written the same way"

# --- #700: no fence resolves the repo root without checking rev-parse ---------
# Under `set -u` with no `set -e`, a failing rev-parse leaves PREMERGE_ROOT empty
# and the fence continues against `/.uberdev/premerge/<id>` — a path the operator
# never chose, diagnosed against the wrong file.
P17_ROOT_TOTAL="$(grep -cF -e 'rev-parse --show-toplevel' "$FENCES")"
P17_ROOT_BARE="$(grep -F -e 'rev-parse --show-toplevel' "$FENCES" | grep -cvF -e '|| exit 2')"
if [ "$P17_ROOT_TOTAL" -lt 8 ]; then
  echo "  FAIL  P17/#700: only $P17_ROOT_TOTAL root resolutions found in the fences — this row is vacuous"; FAIL=$((FAIL + 1))
elif [ "$P17_ROOT_BARE" = "0" ]; then
  echo "  PASS  P17/#700: all $P17_ROOT_TOTAL fence root resolutions carry || exit 2"; PASS=$((PASS + 1))
else
  echo "  FAIL  P17/#700: $P17_ROOT_BARE of $P17_ROOT_TOTAL root resolutions are unguarded:"
  grep -F -e 'rev-parse --show-toplevel' "$FENCES" | grep -vF -e '|| exit 2' | sed 's/^/          /'
  FAIL=$((FAIL + 1))
fi

# --- #695: --after-push asks whether THIS PR gets checks ----------------------
# A repo whose only workflow is `on: schedule` has a workflow FILE and never a PR
# check, so conditioning on the file spun the WAIT_CI ceiling and reported
# STOP_UNREADABLE on a stack that was fine. Forbid the old variable outright: it
# IS the wrong question, and a row that only checked for the new one would pass
# with both present.
assert_not_in "$GATE_FENCE" 'PREMERGE_HAS_WORKFLOWS' \
  "P17/#695: the gate no longer decides on a bare workflow-FILE count"
assert_in "$GATE_FENCE" 'PREMERGE_CI_SEEN="$PREMERGE_RUN_DIR/ci-observed"' \
  "P17/#695: an observed check on this PR is recorded, run-scoped"
assert_in "$GATE_FENCE" 'if [ -e "$PREMERGE_CI_SEEN" ]; then' \
  "P17/#695: and it is the FIRST thing the condition consults"
# BOTH probes, each with its full expression. Asserting the bare alternation was
# satisfied by either one of them, so widening the first back to `.` left the row
# green on the strength of the second.
assert_in "$GATE_FENCE" '(- )?(pull_request|pull_request_target|push|merge_group)([[:space:],:]|$)' \
  "P17/#695: the block-form trigger probe is narrowed to PR-reachable events"
assert_in "$GATE_FENCE" '^[^[:space:]]*on[^[:space:]]*:.*(pull_request|pull_request_target|push|merge_group)' \
  "P17/#695: and so is the inline on:-line probe"
assert_in "$GATE_FENCE" '[ "$PREMERGE_PUSHED" = "1" ] && [ "$PREMERGE_PR_HAS_CHECKS" = "1" ]' \
  "P17/#695: the flag is gated on the push AND on the PR having checks"

# --- #696: the flaky rerun is bounded, from the ledger -----------------------
# `_count_wait_rows` filters on decision == "WAIT_CI", so the CONTINUE rows this
# route appends are invisible to it and PREMERGE_RERUN_FLAKY_CAP was prose.
assert_in "$RERUN_FENCE" 'PREMERGE_RERUN_FLAKY_CAP=1' \
  "P17/#696: the cap is a value the fence reads, not a constant in a table"
assert_in "$RERUN_FENCE" 'converge.jsonl' \
  "P17/#696: the bound is DERIVED from the ledger, not carried across fences"
# #708 RETARGETS THIS ROW. It asserted `.attempt == $want`, which is what made
# the cap dead: a CONTINUE advances PREMERGE_ATTEMPT (`## Phase 2` rule 1 carves
# out only WAIT_CI), so each pass asked about a fresh index and computed USED=0
# forever. The count is now run-scoped, and the row asserts the ABSENCE of the
# index filter as well as the presence of the decision filter — a bare
# `.decision == "CONTINUE"` assertion would also pass on the old expression.
assert_in "$RERUN_FENCE" 'select(.decision == "CONTINUE")' \
  "P17/#708: it counts every red CONTINUE in the RUN, not at one index"
# Asserted against the fence's CODE, not its comments. The comment above the jq
# call names the old expression in order to explain why it was wrong, and a probe
# run over the raw body is satisfied by that explanation — the same
# prose-satisfies-grep trap the #706 rows strip comments for.
#
# `assert_not_in` is grep -qE, so the metacharacters are escaped too: an
# unescaped `$want` makes `$` an end-of-line anchor and the row passes vacuously,
# which is how this assertion first shipped green against the unfixed fence.
RERUN_FENCE_CODE="$(printf '%s\n' "$RERUN_FENCE" | grep -vE '^[[:space:]]*#' || :)"
assert_not_in "$RERUN_FENCE_CODE" '\.attempt == \$want' \
  "P17/#708: the index filter that made the cap dead prose is gone"
assert_in "$RERUN_FENCE" 'index("ci=red")' \
  "P17/#696: and only the ones whose reason was a red build"
assert_in "$RERUN_FENCE" 'DECISION=STOP_FLAKY_CAP' \
  "P17/#696: reaching the cap is a named stop, not a shrug"
# A crashed jq must not read as a count of zero — the shape that would restore
# the unbounded loop while looking perfectly healthy.
assert_in "$RERUN_FENCE" 'case "$PREMERGE_RED_CONTINUES" in '"''"'|*[!0-9]*)' \
  "P17/#696: a non-numeric ledger answer is a refusal, not 0"
assert_fixed "$SKILL" 'the `premerge-ci-rerun` fence' \
  "P17/#696: the 3c routing table sends the flaky arm through that fence"

# --- #697: the CI-repair arm carries the three load-bearing checks ------------
# Common Mistakes: "the prompt is the instruction; the commit fence's scope check
# is the enforcement". The CI arm published agent-authored commits with none of
# them.
assert_in "$PUBLISH_FENCE" 'PREMERGE_HEAD_BRANCH="$(git symbolic-ref -q --short HEAD)"' \
  "P17/#697: check 1 — the branch assertion"
assert_in "$PUBLISH_FENCE" 'PREMERGE_UNTRACKED="$(git ls-files --others --exclude-standard)"' \
  "P17/#697: check 2 — the untracked refusal"
assert_in "$PUBLISH_FENCE" 'comm -23 "$PREMERGE_CI_CHANGED" "$PREMERGE_CI_ALLOWED"' \
  "P17/#697: check 3 — the signal_anchor scope comparison"
assert_in "$PUBLISH_FENCE" 'if [ ! -s "$PREMERGE_CI_SCOPE" ]; then' \
  "P17/#697: a missing scope declaration is a refusal, not a free pass"
assert_in "$PUBLISH_FENCE" 'git -C "$PREMERGE_ROOT" diff --name-only --no-renames "$PREMERGE_CI_BEFORE" HEAD >"$PREMERGE_CI_RAW" || exit 2' \
  "P17/#697: and it uses the #693-safe producer shape, not a pipeline"
assert_in "$PUBLISH_FENCE" '--force-with-lease="$PREMERGE_BRANCH:$PREMERGE_CI_LEASE"' \
  "P17/#697: the rebase arm still publishes under the controller's lease"
# #709 RETARGETS THIS ROW. `!=` was stricter than the question the fence's own
# comment poses ("added none of its own") and blocked the repair it gates: a
# stale_base rebase legitimately DROPS commits that already landed on the new
# base — the commonest cause of stale_base in the first place — and refusing
# there leaves a rewritten local branch that was never force-pushed.
assert_in "$PUBLISH_FENCE" '[ "$PREMERGE_COUNT_AFTER" -gt "$PREMERGE_COUNT_BEFORE" ]' \
  "P17/#709: a rebase that ADDED a commit of its own is refused"
assert_not_in "$PUBLISH_FENCE" 'PREMERGE_COUNT_BEFORE" != "\$PREMERGE_COUNT_AFTER' \
  "P17/#709: and a rebase that dropped a landed commit is no longer refused"
assert_in "$PUBLISH_FENCE" 'PREMERGE CI REBASE_DROPPED BEFORE=%s AFTER=%s' \
  "P17/#709: a dropped commit is announced, not passed silently"
assert_in "$PUBLISH_FENCE" 'git rev-parse --absolute-git-dir' \
  "P17/#697: the in-progress-rebase probe cannot be defeated by the cwd"

# --- #692: ONE rule for advancing PREMERGE_ATTEMPT ---------------------------
# Phase 2 said "advanced only by Phase 3b" while 4c advances it itself and
# requires it to stay advanced. An orchestrator obeying the Phase-2 sentence
# re-runs triage at the SAME index, overwriting the evidence the ledger's row for
# that attempt attests to.
assert_no_grep "$SKILL" 'is advanced only by' \
  "P17/#692: the single-writer sentence that contradicted 4c is gone"
assert_fixed "$SKILL" '**Exactly two places advance it, and there is no third:**' \
  "P17/#692: both advancing sites are declared together"
assert_fixed "$SKILL" '**Never re-use an index.**' \
  "P17/#692: and the per-attempt evidence is declared immutable"

# --- #694: ONE aggregate_path, named in ONE place ----------------------------
# §2b and §5-file gave the controller two different values for the same single
# Phase-5 dispatch; §2b's dropped exactly the rows the defer verb was added to
# produce. This BIT a real run: the dispatch filed only suggestions.
assert_count_fixed "$SKILL" '`aggregate_path` = ' 1 \
  "P17/#694: exactly one section assigns the dispatch's aggregate_path"
assert_no_grep "$SKILL" 'aggregate_path.*suggestions-aggregate' \
  "P17/#694: and it is never the plan-intermediate suggestions aggregate"
assert_fixed "$SKILL" 'deferred-aggregate.md' \
  "P17/#694: the canonical aggregate is named (anti-vacuity)"

# --- #690: a defer overflow is survivable, and a dropped blocker is loud ------
assert_not_in "$DEFER_FENCE" 'defer "\$@" \|\| exit 74' \
  "P17/#690: the fence no longer ends at the bare fatal call"
assert_in "$DEFER_FENCE" 'defer "$@")" || exit 74' \
  "P17/#690: but a genuine refusal is still exit 74"
assert_in "$DEFER_FENCE" 'PREMERGE_DEFER_PATH="${PREMERGE_DEFER_LINE#* PATH=}"' \
  "P17/#690: PATH= is read as a suffix — run dirs contain spaces"
assert_in "$DEFER_FENCE" 'carries no OVERFLOW= count' \
  "P17/#690: a missing OVERFLOW= is a contract break, never a silent zero"
assert_in "$DEFER_FENCE" 'CLASS=blocker' \
  "P17/#690: the state where a dropped row may be a blocker reports differently"
assert_in "$DEFER_FENCE" 'CLASS=cleanup' \
  "P17/#690: and the ordinary cleanup overflow does not borrow that wording"
assert_fixed "$SKILL" '#### When the envelope overflows' \
  "P17/#690: §5-file says what happens to the rows that did not fit"

# --- #722: the defer line's FILES= field, and its placement -------------------
assert_in "$DEFER_FENCE" 'carries no FILES= count' \
  "P17/#722: a missing FILES= is a contract break, never a silent zero"
assert_in "$DEFER_FENCE" 'PREMERGE_DEFER_OVERFLOW="${PREMERGE_DEFER_HEAD##* OVERFLOW=}"' \
  "P17/#722: FILES= went in BEFORE OVERFLOW=, so the suffix read is untouched"
assert_fixed "$SKILL" 'FILES=<n> OVERFLOW=<n> PATH=<path>' \
  "P17/#722: the documented line shows FILES= in its real position"
assert_in "$DEFER_FENCE" 'PREMERGE DEFER_FILES=%s' \
  "P17/#722: the fence surfaces how many issues the dispatch will open"

# --- #722: grouping REMOVED the row-level "every blocker fit" guarantee -------
# `defer` now admits whole FILES, blocker-bearing ones first, and row-fills the
# leftover budget from the single next-ranked file. A blocker-bearing file drags
# its own cleanup rows into the envelope with it, so `SUGGESTION > 0` no longer
# witnesses that every blocker fit. Executed against the shipped rule — one file
# holding 40 cleanup rows plus a blocker, one holding 30 blockers — the verb
# prints `TOTAL=64 BLOCKER=24 SUGGESTION=40 FILES=2 OVERFLOW=7`, and all seven
# dropped rows are blockers. The mild arm must not reassure an operator there.
assert_not_in "$DEFER_FENCE" 'every blocker was kept' \
  "P17/#722: the cleanup arm no longer promises what grouping took away"
assert_in "$DEFER_FENCE" 'check BLOCKER= on the line below' \
  "P17/#722: it points at the only field that answers 'did every blocker fit'"
assert_in "$DEFER_FENCE" 'CLASS=blocker — the 64-row envelope was filled ENTIRELY by blockers' \
  "P17/#722: the severe arm is untouched — that state is still provable"

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

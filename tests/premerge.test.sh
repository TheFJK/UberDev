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
#   P16  — repo-agnosticism: Phase 5's bump probes the TARGET repo (not the
#          plugin install), passes that root through to bump-version.sh, and
#          skips with a typed reason elsewhere; Phase 0 publishes the private
#          ignore policy that keeps the run dir out of a foreign repo's
#          cleanliness gate
#   P17  — the stack-gate blockers, every row scoped to an extracted fence body:
#          the scope guard's two halves fail in the same direction (#693), one
#          rule for advancing PREMERGE_ATTEMPT (#692), one aggregate_path (#694),
#          --after-push asks whether the PR gets checks (#695), the flaky rerun
#          is bounded from the ledger (#696), the CI-repair arm carries the three
#          load-bearing checks (#697), every fence root resolution is guarded
#          (#700), a defer overflow is survivable and loud (#690), and the
#          grouped-filing contract reads the same way in every place it is
#          stated at all (#722)
#   P18  — every `git push` in an executable fence captures git's stderr and
#          hands it to a typed `error:` line. Universal, not four site greps: a
#          sixth push site is covered the day it is written (#724)
#   P19  — PREMERGE_RERUN_FLAKY_CAP is declared once and RUN at the value
#          declared. The fence re-assigns the number, so editing the Constants
#          block -- the only copy the prose points at -- changed nothing at
#          runtime and no test noticed (#724)
#   P20  — every backticked heading reference in the Constants block resolves to
#          a heading that exists in this file (#724)
#   P21  — the growth ratio's surfaces: the library declares the ceiling and the
#          decision, the SKILL documents both and prints GROWTH=, and the command
#          file names the stop for the operator. The BEHAVIOUR — that the ratio
#          is computed, that one round warns and two stop, and that repointing
#          the repair scope moves the decision — is driven in B32 of
#          tests/premerge-findings.test.sh, which executes the module
#   P22  — the fixer-wave return contract names `blocked_on_file` and BOTH of
#          its emission cases, scoped to the §2a prompt block rather than to the
#          whole file
#   P22b — the security row: the commit fence's allowed set STILL derives only
#          from `fix-waves-<NN>.json`, so a path is committable only while
#          exactly one agent owns it. Exactly one producer, and no fence names
#          the blocked-on artifact
#   P22c — the widening is declared on both surfaces, capped, and reads exactly
#          one predecessor; both bypass entries are in common-mistakes.md. The
#          cap is compared VALUE-for-value with the library's MAX_BLOCKED_ON,
#          and the wave size the SKILL says it equals is compared with what the
#          fence actually passes as --max-per-wave — a name grep on either side
#          is green at any value (#370/#371)

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/tests/_lib_assert_structural.sh" || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }

CMD="$REPO_ROOT/plugins/uberdev/commands/premerge.md"
SKILL="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/SKILL.md"
# #747 — four reference files now hold what the body used to: the Phase 0/1/2/3
# contracts, the finding-overflow arms, and Common Mistakes. The BYTES are
# unchanged; only the file holding them moved. $SKILL_MISTAKES and
# $SKILL_CONTRACTS name the two that assertions below read; $SKILL stays the
# body, because every fence extraction still comes out of it.
SKILL_CONTRACTS="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/references/phase-contracts.md"
SKILL_MISTAKES="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/references/common-mistakes.md"
SKILL_OVERFLOW="$REPO_ROOT/plugins/uberdev/skills/premerge-pipeline/references/finding-overflow.md"
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
for f in "$CMD" "$SKILL" "$SKILL_CONTRACTS" "$SKILL_MISTAKES" "$SKILL_OVERFLOW" "$LIB" "$PRIMITIVES" "$F2I" "$SYNC" "$VENDOR" "$RFC" "$README" "$GOAL_STATE"; do
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
# WHICH copy this reads is itself the assertion, and it is $SKILL — SKILL.md.
# SKILL.md is the only file loaded eagerly when the skill fires, so it is the
# only copy the controller is guaranteed to have in front of it; a file under
# references/ is loaded on demand and may never be opened in a given run. This
# row used to extract from $SKILL_CONTRACTS, which left the read copy unguarded
# and guarded a copy nothing reads — #370/#371 one level down: green row,
# drifted controller. SKILL.md is authoritative for `## The severity rule` and
# for the block below; references/phase-contracts.md points at it.
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
assert_grep "$SKILL_MISTAKES" 'Assuming that rule covers the CI agents too' "P14: the wave-agent git rule is scoped away from the CI agents"

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
assert_grep "$SKILL_CONTRACTS" '^### What `PREMERGE_PUSHED` is at each call site$' \
  "P17/#707: the call-site table exists"
for pushed_site in 'first entry at attempt 1' 'premerge-fix-commit' \
                   'premerge-ci-publish' 'WAIT_CI'; do
  assert_grep "$SKILL_CONTRACTS" "$pushed_site" \
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

# --- #722: ONE grouped-filing contract, not N uncompared copies ---------------
# §2b and §3b were restated against grouping; `## Common Mistakes` kept a third
# copy of the premise they retired, and grouping INVERTS it — the ISSUE key is
# `sha256("<slug>:<file_path>")[:16]`, so a second dispatch over the same file
# COMMENTS. That bullet said it duplicates. Its conclusion survives on its other
# clauses, but a rule whose stated MECHANISM is false is one the next editor
# checks, finds untrue, and deletes — putting filing back inside the loop. Lock
# the COUNT the way the aggregate_path row above does (#694): the per-finding
# identity belongs to §2b and §3b, and a third copy is one that drifts unnoticed.
assert_count_fixed "$SKILL" 'file:line:summary' 2 \
  "P17/#722: the per-finding identity is stated in exactly two places"
assert_no_grep "$SKILL" 'duplicates rather than comments' \
  "P17/#722: no copy says per-attempt filing duplicates instead of commenting"
assert_fixed "$SKILL_MISTAKES" 'keys the ISSUE' \
  "P17/#722: Common Mistakes states the grouped mechanism (anti-vacuity)"
assert_fixed "$SKILL_MISTAKES" 'File once, at Phase 5.' \
  "P17/#722: and keeps the conclusion the corrected mechanism still carries"

# --- #722: DEFER_FILES= must name the bound the operator actually feels -------
# FILES= is an upper bound, not a forecast: `max_new` bounds the dispatch and it
# now counts FILES, so above the cap the surplus files are deferred whole and
# come back only as `overflow_count`. The executed run B24 pins in
# tests/premerge-findings.test.sh is FILES=64 — "at most 64 issues, one per file"
# is literally true there while at most 10 open. Compare the stated caps by
# VALUE the way P16 compares the manifest literals, so changing the cap needs no
# test edit while drifting one copy out of step with the others reds here.
assert_in "$DEFER_FENCE" 'no more than max_new=' \
  "P17/#722: the operator line names the cap that actually bounds the dispatch"
assert_fixed "$SKILL" "one issue each up to the dispatch's" \
  "P17/#722: and the documented FILES= field is hedged to that same cap"
DEFER_CAPS="$(
  sed -n 's/^PREMERGE_MAX_ISSUES[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SKILL"
  sed -n 's/.*max_new`\{0,1\}[[:space:]]\{0,1\}=[[:space:]]\{0,1\}\([0-9][0-9]*\).*/\1/p' "$SKILL"
)"
DEFER_CAP_COUNT="$(grep -c . <<<"$DEFER_CAPS")"
DEFER_CAP_UNIQ="$(sort -u <<<"$DEFER_CAPS" | grep -c .)"
if [ "$DEFER_CAP_COUNT" -lt 4 ]; then
  echo "  FAIL  P17/#722: expected the 4 stated max_new caps (Constants row, §2b, the §5-file dispatch, the defer fence), found $DEFER_CAP_COUNT"
  FAIL=$((FAIL + 1))
elif [ "$DEFER_CAP_UNIQ" != 1 ]; then
  echo "  FAIL  P17/#722: the stated max_new caps disagree:"; sed 's/^/          /' <<<"$DEFER_CAPS"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  P17/#722: all $DEFER_CAP_COUNT stated max_new caps agree on $(sed -n 1p <<<"$DEFER_CAPS")"; PASS=$((PASS + 1))
fi

echo "== P18: every git push in this file explains its own failure (#724) =="
# Four of the five pushes ended `>/dev/null 2>&1 || exit 2`. A non-fast-forward,
# an expired token or a protected-branch rule made the fence exit 2 having printed
# nothing at all -- mid-run, inside an autonomous loop, with no PREMERGE FIX
# COMMIT= line and no cause. The fifth printed a typed line but still sent git's
# own words to /dev/null.
#
# The rule asserted here is UNIVERSAL rather than four site greps: every git push
# in every fence captures stderr and hands it to a typed `error:` line, so a sixth
# push site is covered the day someone writes it.
#
# What "every git push" means, spelled out, because a census whose recogniser is
# vague is wrong in BOTH directions (#724): a line counts when it holds `git`,
# then git's own global options, then `push` AS A WHOLE WORD. So `git push` alone
# at the end of a line — the bare push to the configured upstream — counts. It did
# not while the filter looked for the literal `push ` with a trailing space, which
# left the one push shape carrying no error handling at all as the one shape the
# audit could not see. And in the other direction `git` and `push` merely
# co-occurring is not a push: a hint printf naming `git fetch … push again` is
# prose ABOUT pushing, and it used to be counted and reported as a site swallowing
# git's stderr. Both directions were measured against this file before the
# recogniser was changed.
#
# The boundary: a push spelled through a variable (`"$GIT" push`) or hidden behind
# a helper function is invisible to this. No fence ships either today, and the one
# that grew one would be worth a row of its own.
#
# Scoped to $FENCES, never the whole file: SKILL.md holds code AND the prose
# documenting it, and a whole-file grep for the capture idiom is satisfied by the
# paragraph explaining the capture idiom after the code is gone. The line numbers
# a failure reports are therefore $FENCES line numbers, not SKILL.md ones.
PUSH_AUDIT="$(awk -v SQ="'" -v HMAX=25 '
  # TRAILING whitespace is stripped as well as leading, because `line == "}"` is
  # the one EXACT compare here and this suite also runs on windows, where the
  # checkout is CRLF (/.gitattributes is scoped to plugins/uberdev/hooks/**). A
  # `}\r` that missed that compare would leave the walk inside the handler
  # forever — which the `unclosed=` field reports directly now, on whatever
  # platform it happens, instead of being inferred from `total` sagging.
  function strip(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  # A line is a push when it holds `git`, then the global options git accepts,
  # then `push` as a WHOLE WORD -- the recogniser the header above describes. The
  # candidate is padded with a space on each side so a push at the very start or
  # the very end of a line needs no `^`/`$` special-case in the pattern.
  #
  # A dynamic regex carrying POSIX classes is not a new bet on the awks this
  # suite runs under -- tests/epipe-guard.test.sh assembles EPIPE_RE the same way
  # and passes it through `awk -v` on both CI jobs -- but that file also treats
  # "unsupported POSIX class in a dynamic regex on some awk" as a real failure
  # mode, and it is right to. Here that failure is not silent: an awk that
  # refuses this pattern prints nothing, every field below is unreadable, and all
  # four rows FAIL rather than one of them reporting a clean census.
  function is_push(s) { return (" " s " ") ~ PUSHRE }
  BEGIN {
    PUSHRE = "[^[:alnum:]_]git([[:space:]]+-[^[:space:]]*([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+push[^[:alnum:]_-]"
    MARK = "2>&1 1>/dev/null)\" || {"
  }
  {
    line = strip($0)
    if (inh) {
      if (index(line, "printf " SQ "error:") == 1) seen = 1
      if (line == "}") { if (!seen) untyped = untyped " " start; inh = 0; next }
      # THE WALK IS BOUNDED, and that is what makes the census and the `untyped=`
      # row mean anything. Unbounded, a handler whose close this cannot match
      # hands it the REST OF THE FILE: every later push site is eaten as body -- the
      # census then under-counts -- and the first typed printf and bare `}` it
      # meets, in any later fence, belonging to anything at all, close the walk
      # and let it report clean. Measured, both halves, on this file.
      #
      # So the walk gives up at the next push site, or after HMAX lines, and says
      # so under `unclosed=`. HMAX is ~2x the longest handler shipped here (the
      # rebase arm, 11 body lines); the point of the number is that overrunning it
      # is a RED, so being generous with it costs nothing.
      if ((substr(line, 1, 1) != "#" && is_push(line)) || NR - start >= HMAX) {
        unclosed = unclosed " " start; inh = 0
      } else next
    }
    if (substr(line, 1, 1) == "#") next
    if (!is_push(line)) next
    total++
    idx = index(line, MARK)
    if (idx == 0) { swallowed = swallowed " " NR; next }
    # Whatever follows `|| {` ON THE PUSH LINE is a handler written on one line.
    # It closes there, so it is judged there. Walking forward for a bare `}` that
    # will never come is exactly how a handler of `{ exit 2; }` -- a push that
    # prints NOTHING, the defect this whole section exists to catch -- used to
    # score `total=5 swallowed=- untyped=-` with the file at 206 passed 0 failed.
    # An END-of-input guard alone did not fix that either: the walk left the fence
    # and closed on a handler in the NEXT one, taking its typed line on the way.
    start = NR
    tail = strip(substr(line, idx + length(MARK)))
    seen = (index(tail, "printf " SQ "error:") > 0)
    if (tail ~ /}$/) { if (!seen) untyped = untyped " " start; next }
    inh = 1
  }
  # And a walk that reaches EOF still inside a handler measured nothing from
  # `start` on. `unclosed` is reported whether or not a typed line was seen,
  # because `seen` stops being evidence once the walk is lost: the printf that
  # set it may belong to any code after the handler.
  END {
    if (inh) unclosed = unclosed " " start
    printf "total=%d swallowed=%s untyped=%s unclosed=%s\n", total, (swallowed == "" ? "-" : swallowed), (untyped == "" ? "-" : untyped), (unclosed == "" ? "-" : unclosed)
  }
' "$FENCES")"
PUSH_TOTAL="${PUSH_AUDIT#total=}"; PUSH_TOTAL="${PUSH_TOTAL%% *}"
case "$PUSH_TOTAL" in ''|*[!0-9]*) PUSH_TOTAL=0 ;; esac
if [ "$PUSH_TOTAL" -ge 5 ]; then
  echo "  PASS  P18: the audit found all $PUSH_TOTAL push sites (anti-vacuity)"; PASS=$((PASS + 1))
else
  echo "  FAIL  P18: only $PUSH_TOTAL push site(s) found — the audit below is vacuous"; FAIL=$((FAIL + 1))
fi
case "$PUSH_AUDIT" in
  *"swallowed=-"*) echo "  PASS  P18: no push discards git's explanation"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL  P18: push(es) swallowing git's stderr — $PUSH_AUDIT"; FAIL=$((FAIL + 1)) ;;
esac
case "$PUSH_AUDIT" in
  *"untyped=-"*) echo "  PASS  P18: every push failure prints a typed error: line"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL  P18: push handler(s) printing no typed error: line — $PUSH_AUDIT"; FAIL=$((FAIL + 1)) ;;
esac
# The two rows above are only worth their PASS while the walk reached the end of
# every handler it entered. This row is what makes that a claim rather than an
# assumption; the $FENCES line number it prints is where the walk got stuck.
case "$PUSH_AUDIT" in
  *"unclosed=-"*) echo "  PASS  P18: every push handler's close was found — the census measured all of them"; PASS=$((PASS + 1)) ;;
  *) echo "  FAIL  P18: the audit never found the close of the push handler(s) it entered — $PUSH_AUDIT"; FAIL=$((FAIL + 1)) ;;
esac
# The rebase arm is the one push that rewrites remote history and the one whose
# failure is genuinely ambiguous: a lease rejection is the safety mechanism firing
# correctly, an expired token is not. Same discrimination commands/review-pr.md
# makes, and the same lease + --force-if-includes pair agents/ci-rebase-handler.md
# calls the single sanctioned exception to never-force.
#
# What the flag row pins is CONSISTENCY with that sanctioned pair, not a second
# refusal: `git push --help` documents --force-if-includes as a "no-op" alongside
# an explicit-form `--force-with-lease=<refname>:<expect>`, which is the form the
# row above at P17/#697 pins as a fixed string. The safety property is carried by
# the LEASE. Saying so here keeps this file from becoming the next place the
# overclaim lives -- which is the defect class #724 exists to close.
#
# BOTH ROWS ARE SCOPED TO THE FENCE'S CODE, not its raw body. The paragraph that
# explains the flag names it twice, so `assert_in "$PUBLISH_FENCE"` stays green
# with the flag DELETED from the push line — measured, not assumed. Same reason
# the #706 rows and the #708 row above strip comments before probing, and the
# same prose-satisfies-grep failure #724 exists to close.
PUBLISH_FENCE_CODE="$(printf '%s\n' "$PUBLISH_FENCE" | grep -vE '^[[:space:]]*#' || :)"
assert_in "$PUBLISH_FENCE_CODE" '--force-if-includes' \
  "P18/#724: the force-push pairs the lease with --force-if-includes"
assert_in "$PUBLISH_FENCE_CODE" 'stale info|fetch first|non-fast-forward' \
  "P18/#724: a lease rejection is told apart from a generic push failure"

echo "== P19: RERUN_FLAKY_CAP is declared once and RUN at the value declared (#724) =="
# PREMERGE_AGGREGATE_SOURCE has three declaration sites AND P4 above to assert
# they agree. PREMERGE_VERSION_MANIFEST has two executable sites and the P16 rows
# that compare them with each other, with /goal's _UBERDEV_GOAL_VERSION_MANIFEST
# and with the Constants row — that half of #724's second item was already
# covered, and a second comparison here would be the very drift class the issue
# registers. PREMERGE_RERUN_FLAKY_CAP had the sites and no test: the fence
# RE-ASSIGNS the number, so editing the Constants block — which reads like the
# SSOT and is the only copy the prose points at — changed nothing at runtime.
#
# The Constants row is spaced (`NAME = 1`) and the executable copy is not
# (`NAME=1`). That is what tells the documentation apart from the program here.
#
# Unlike P18 and P20 this section is green on both sides of #724's fix, and that
# is correct: it is a DRIFT detector, which is exactly what the issue's second
# acceptance item asks for. It reds the day one copy moves without the other.
DOC_CAP="$(sed -n 's/^PREMERGE_RERUN_FLAKY_CAP[[:space:]][[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$SKILL" | sed -n '1p')"
FENCE_CAPS="$(sed -n 's/^PREMERGE_RERUN_FLAKY_CAP=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$FENCES")"
FENCE_CAP_COUNT="$(grep -c . <<<"$FENCE_CAPS")"
FENCE_CAP="$(sort -u <<<"$FENCE_CAPS")"
FENCE_CAP_UNIQ="$(grep -c . <<<"$FENCE_CAP")"
if [ -z "$DOC_CAP" ]; then
  echo "  FAIL  P19: the Constants block declares no PREMERGE_RERUN_FLAKY_CAP"; FAIL=$((FAIL + 1))
elif [ "$FENCE_CAP_COUNT" -lt 1 ]; then
  echo "  FAIL  P19: no fence assigns PREMERGE_RERUN_FLAKY_CAP — the cap is prose with nothing behind it"; FAIL=$((FAIL + 1))
elif [ "$FENCE_CAP_UNIQ" != 1 ]; then
  echo "  FAIL  P19: the executable copies of PREMERGE_RERUN_FLAKY_CAP disagree:"; sed 's/^/          /' <<<"$FENCE_CAPS"
  FAIL=$((FAIL + 1))
elif [ "$FENCE_CAP" != "$DOC_CAP" ]; then
  echo "  FAIL  P19: Constants says '$DOC_CAP', the fence runs '$FENCE_CAP'"; FAIL=$((FAIL + 1))
else
  echo "  PASS  P19: the fence runs the cap the Constants block declares ($DOC_CAP)"; PASS=$((PASS + 1))
fi
# Anti-vacuity: the cap must be CONSUMED, not merely assigned. An assignment
# nothing compares against is how it became prose in the first place.
assert_in "$RERUN_FENCE" '[ "$PREMERGE_RERUNS_USED" -ge "$PREMERGE_RERUN_FLAKY_CAP" ]' \
  "P19: and the fence compares the run's spent reruns against it"

echo "== P20: the Constants block's cross-references resolve (#724) =="
# PREMERGE_CI_SETTLE_SECS's comment pointed at `## The CI settle window`; the
# section is `###`. A pointer into your own file is worth having only while it
# lands, and this one survived a rewrite of the very section it names.
#
# Generic on purpose: EVERY backticked heading reference on EVERY row that
# assigns a PREMERGE_ constant must match a heading line in this file byte for
# byte, so the next constant that grows a pointer is covered without another row.
#
# "EVERY" is load-bearing twice over, and the first spelling of this extraction
# was narrower than its own comment on both counts (#724):
#
#   * ALL refs on the row, not the last. A greedy `.*` before the capture kept
#     only the final backticked ref, so a row carrying two — the first dangling,
#     the second resolving — passed. Measured on this file.
#   * BOTH assignment spellings. Requiring whitespace before `=` skipped the real
#     `PREMERGE_AGGREGATE_SOURCE= premerge-aggregate` row, so a pointer added
#     there would never have been checked. Requiring none also takes in the
#     fences' own `NAME=value` lines, which is a superset and the right one: a
#     dangling pointer is a dangling pointer wherever the constant is assigned.
CONST_REFS="$(awk '
  /^PREMERGE_[A-Z_]*[[:space:]]*=/ {
    rest = $0
    while (match(rest, /`#+[[:space:]][^`]*`/)) {
      print substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
' "$SKILL")"
CONST_REF_COUNT="$(grep -c . <<<"$CONST_REFS")"
if [ "$CONST_REF_COUNT" -ge 1 ]; then
  echo "  PASS  P20: the Constants block carries $CONST_REF_COUNT heading reference(s) (anti-vacuity)"; PASS=$((PASS + 1))
else
  echo "  FAIL  P20: no heading reference found in the Constants block — the row below is vacuous"; FAIL=$((FAIL + 1))
fi
# Heredoc, not a pipe: the loop's reader is the EPIPE class tests/epipe-guard.test.sh
# bans, and grep -qxF reads a FILE so it has no writer to poison. The body and the
# EOF_P20_REFS terminator must stay at column 0 — indenting them would prepend
# whitespace to every reference and red this row for the wrong reason.
P20_DANGLING=""
while IFS= read -r P20_REF; do
  [ -n "$P20_REF" ] || continue
  grep -qxF -e "$P20_REF" "$SKILL" "$SKILL_CONTRACTS" "$SKILL_MISTAKES" "$SKILL_OVERFLOW" \
    >/dev/null || P20_DANGLING="$P20_DANGLING [$P20_REF]"
done <<EOF_P20_REFS
$CONST_REFS
EOF_P20_REFS
if [ -z "$P20_DANGLING" ]; then
  echo "  PASS  P20: every Constants cross-reference names a heading that exists"; PASS=$((PASS + 1))
else
  echo "  FAIL  P20: dangling Constants cross-reference(s):$P20_DANGLING"; FAIL=$((FAIL + 1))
fi
# And the judgement #724 asked for is written down, so the next audit does not
# re-file a constant whose consumer is the controller by design.
assert_fixed "$SKILL" '`PREMERGE_CI_SETTLE_SECS` is consumed by the **controller**' \
  "P20: the settle constant's consumer is stated, not left to be re-discovered"

echo "== P21: the growth ratio's surfaces (#754) =="
# Grep-only, on purpose, and NOT the proof that the detector works: a literal in
# the source is satisfied by a comment mentioning it. What these rows catch is a
# surface DELETED or renamed — a library constant with no restatement, a
# decision the SKILL stopped documenting, an operator file that never learned
# the loop grew a third stop. B32 in tests/premerge-findings.test.sh is the half
# that executes.
assert_fixed "$LIB" 'CONVERGE_GROWTH_CEILING = 0.50' "P21: the library declares the break-even ceiling"
assert_fixed "$LIB" 'CONVERGE_GROWTH_RUNS = 2' "P21: the library declares the consecutive-round requirement"
assert_fixed "$LIB" '"STOP_SELF_REFERENTIAL",' "P21: the decision is a member of the closed vocabulary"
assert_fixed "$LIB" 'fix-scope-%02d.modified' "P21: the ratio reads the scope list the commit fence already writes"
assert_grep  "$SKILL" '^PREMERGE_GROWTH_CEILING' "P21: the SKILL restates the ceiling in the Constants block"
assert_grep  "$SKILL" '^PREMERGE_GROWTH_RUNS' "P21: the SKILL restates the consecutive-round requirement"
assert_fixed "$SKILL" '| `STOP_SELF_REFERENTIAL` |' "P21: the decision table routes the new stop"
assert_fixed "$SKILL" 'GROWTH=<0.00-1.00|->' "P21: the documented output line carries the ratio"
assert_fixed "$SKILL" 'growth=0.20' "P21: the run summary's converge row carries the ratio per attempt"
assert_fixed "$CMD" 'STOP_SELF_REFERENTIAL' "P21: the command file names the stop for the operator"
assert_fixed "$SKILL_MISTAKES" 'GROWTH=-' "P21: Common Mistakes warns against reading unmeasured as zero"
assert_fixed "$RFC" '### A5 — the growth ratio is computed and stops the loop' "P21: RFC 0021 records the amendment"
# The measurement takes NO new argument: both its inputs are in the run
# directory the fence already passes. This row reds if someone "fixes" the
# measurement by widening the verb's surface and threading a value through a
# fence.
#
# LINE-BASED, and deliberately NOT `converge.*--growth` on one line: grep judges
# one line at a time, and this fence writes every argument on its own
# backslash-continued line — `--run-dir`, `--attempt`, `--max-repairs`,
# `--verdict`, `--reasons`, `--wait-passes` all sit BELOW the word `converge`.
# A same-line pattern is therefore blind to the only shape a seventh argument
# would ever be written in. Measured, not reasoned: with
# `--growth "$PREMERGE_GROWTH" \` spliced into the converge invocation exactly
# the way its six siblings are written, the same-line pattern still reported
# PASS on this suite. It would have shipped permanently green.
#
# The widened claim — no fence passes a growth argument AT ALL — is true today
# and errs in the safe direction: it also catches the value being threaded into
# the `plan` or `defer` call instead, which is the same mistake wearing a
# different verb.
#
# `^[^#]*` is P15's idiom, for P15's reason: a fence COMMENT that mentions the
# flag while explaining why nothing passes it must not red this row. The
# `[^-[:alnum:]]` before the flag keeps `----growth` and `x--growth` out, and
# the trailing class keeps `--growth-ceiling` out.
#
# Anti-vacuity is already established ABOVE, in this same run, and is not
# restated here: P11c FAILS the extraction outright below 100 lines, and P11c's
# own `assert_fixed "$FENCES" 'premerge-findings.py" converge'` is what proves
# the converge invocation is in the slice at all. A second copy of either
# predicate is the drift this suite exists to prevent.
assert_no_grep "$FENCES" '^[^#]*[^-[:alnum:]]--growth([^[:alnum:]_-]|$)' \
  "P21: no fence passes a growth argument — the inputs are in the run dir"

echo "== P22: the fixer-wave return contract names blocked_on_file (#755) =="
# AC 1: the field and BOTH emission cases. Scoped to the §2a prompt block, not
# to the whole file — SKILL.md holds the contract AND the paragraphs about it,
# and a whole-file grep for the field name is satisfied by the paragraph that
# explains it after the contract itself has gone.
P22_PROMPT="$(awk '
  $0 == "### 2a — The fixer-wave mechanism" { in2a = 1 }
  in2a && $0 == "Return exactly this YAML and nothing else:" { infield = 1 }
  infield && index($0, "```") == 1 { exit }
  infield { print }
' "$SKILL")"
P22_PROMPT_LINES="$(grep -c . <<<"$P22_PROMPT")"
if [ "$P22_PROMPT_LINES" -ge 6 ]; then
  echo "  PASS  P22: the §2a return block extracted $P22_PROMPT_LINES lines"; PASS=$((PASS + 1))
else
  echo "  FAIL  P22: the §2a return block extracted $P22_PROMPT_LINES lines — every row below is vacuous"; FAIL=$((FAIL + 1))
fi
assert_in "$P22_PROMPT" 'blocked_on_file:' "P22: the return contract declares the field"
assert_in "$P22_PROMPT" '- file:' "P22: and it carries a path"
assert_in "$P22_PROMPT" 'reason:' "P22: and a reason"
# BOTH emission cases, against the RULES block that the agent actually obeys.
P22_RULES="$(awk '
  $0 == "### 2a — The fixer-wave mechanism" { in2a = 1 }
  in2a && $0 == "Rules:" { inrules = 1; next }
  inrules && $0 == "Return exactly this YAML and nothing else:" { exit }
  inrules { print }
' "$SKILL")"
P22_RULE_LINES="$(grep -c . <<<"$P22_RULES")"
if [ "$P22_RULE_LINES" -ge 8 ]; then
  echo "  PASS  P22: the §2a rules block extracted $P22_RULE_LINES lines"; PASS=$((PASS + 1))
else
  echo "  FAIL  P22: the §2a rules block extracted $P22_RULE_LINES lines — the rows below are vacuous"; FAIL=$((FAIL + 1))
fi
assert_in "$P22_RULES" 'status: REFUSED' "P22: the REFUSED emission case is stated in the rules"
assert_in "$P22_RULES" 'status: APPLIED' "P22: the APPLIED emission case is stated in the rules"
assert_in "$P22_RULES" 'blocked_on_file' "P22: both cases name the field the agent must emit"
assert_in "$P22_RULES" 'never a line range' "P22: the reason is carried, the coordinates are not"

echo "== P22b: the allowed set still derives ONLY from the wave plan (#755) =="
# THE SECURITY ROW. `blocked_on_file` must reach the next attempt through
# `_fix_waves`, so a path is committable only while exactly one agent owns it.
# A fence that reads the blocked-on artifact directly has bypassed that, and
# the symptom is two agents editing one file with the disjointness guard silent.
#
# The two bypass patterns are HOISTED into variables because P22c drives the
# SAME strings over a body that does bypass. A second, freshly-typed copy of a
# pattern down there would make that anti-vacuity row constant-true: a typo in
# either pattern here leaves the row it guards matching nothing, and the row
# that exists to catch exactly that stays green because it reads its own copy.
# One string, two readers — that is the whole mechanism.
P22B_BYPASS_RE='blocked.on'
P22B_APPEND_RE='PREMERGE_ASSIGNED_LIST"$'
assert_in "$FIX_FENCE" 'jq -r '"'"'.waves[][].file'"'"' <"$PREMERGE_WAVES_FILE" >"$PREMERGE_SCOPE_RAW" || exit 2' \
  "P22b: the allowed set is still derived from the wave plan, unchanged"
assert_not_in "$FIX_FENCE" "$P22B_BYPASS_RE" \
  "P22b: and the fix-commit fence names no blocked-on artifact"
assert_not_in "$FIX_FENCE" "$P22B_APPEND_RE" \
  "P22b: nothing appends to the assigned list after it is built"
# Exactly ONE producer for the assigned list. A second `>>` or a second `jq`
# writing it is the widening this design refuses, and a row asserting only that
# the first producer survives would pass with both present.
P22B_PRODUCERS="$(grep -cE '>+[[:space:]]*"\$PREMERGE_ASSIGNED_LIST"' <<<"$FIX_FENCE")"
if [ "$P22B_PRODUCERS" = "1" ]; then
  echo "  PASS  P22b: the assigned list has exactly one producer"; PASS=$((PASS + 1))
else
  echo "  FAIL  P22b: the assigned list has $P22B_PRODUCERS producers, wanted 1"; FAIL=$((FAIL + 1))
fi

echo "== P22c: the widening is declared, bounded and non-accumulating (#755) =="
assert_fixed "$FENCES" '--carry-blocked' "P22c: a fence turns the widening on"
assert_fixed "$FENCES" '--repo-root "$PREMERGE_ROOT"' "P22c: and hands it a root to contain against"
assert_fixed "$SKILL" 'PREMERGE_MAX_BLOCKED_ON' "P22c: the SKILL declares the cap"
assert_fixed "$LIB" 'MAX_BLOCKED_ON' "P22c: the library declares the cap it enforces"
# ...and the VALUE behind both those names. The two rows above are
# `assert_fixed` — a fixed-string grep for the identifier, on each side — so the
# pair stayed green at any value and the two copies were free to drift the
# moment either moved: the SKILL's number is what a reader plans against, the
# library's is what actually drops rows. That is the #370/#371 "one contract, N
# uncompared copies" class P3b names above, and this stack's other restated
# constants are not exposed to it — PREMERGE_REPAIR_CEILING /
# PREMERGE_WAIT_CI_CEILING and the growth pair are compared value-for-value in
# tests/premerge-findings.test.sh (B15b, B32). This one is compared here,
# beside the Constants block's other locks (P19, P20).
#
# EVALUATE the library's constant, never parse it: P3b states that rule for this
# repo, and the cross-platform import recipe is P3b's too — cd into the lib dir,
# hand python3 a RELATIVE filename (a Git Bash absolute path is not openable by
# native Windows python), strip the CR native-Windows python writes.
P22C_ERR="$(mktemp)"
P22C_LIB_CAP="$( (cd "$LIB_DIR" && python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('premerge_findings', '$LIB_BASE')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.MAX_BLOCKED_ON)
") 2>"$P22C_ERR" | tr -d '\r')"
# Spaced (`NAME = 8`) is the documentation, as in P19: the Constants block is the
# only copy of this number the prose points at.
P22C_DOC_CAP="$(sed -n 's/^PREMERGE_MAX_BLOCKED_ON[[:space:]][[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$SKILL" | sed -n '1p')"
case "$P22C_LIB_CAP" in
  ''|*[!0-9]*)
    echo "  FAIL  P22c: could not evaluate MAX_BLOCKED_ON from the library (got '$P22C_LIB_CAP')"
    [ -s "$P22C_ERR" ] && echo "        python stderr: $(tr '\n' ' ' <"$P22C_ERR")"
    FAIL=$((FAIL + 1)) ;;
  *)
    if [ -z "$P22C_DOC_CAP" ]; then
      echo "  FAIL  P22c: the Constants block declares no PREMERGE_MAX_BLOCKED_ON value"; FAIL=$((FAIL + 1))
    elif [ "$P22C_DOC_CAP" != "$P22C_LIB_CAP" ]; then
      echo "  FAIL  P22c: Constants says PREMERGE_MAX_BLOCKED_ON=$P22C_DOC_CAP, the library enforces $P22C_LIB_CAP"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS  P22c: the SKILL's restated cap == the library's enforced MAX_BLOCKED_ON ($P22C_LIB_CAP)"
      PASS=$((PASS + 1))
    fi ;;
esac
rm -f "$P22C_ERR"

# The equality the SKILL argues from. It says the cap is equal to
# PREMERGE_MAX_FIX_WAVE "on purpose" — the widening is one extra wave's worth of
# files rather than a number someone picked — and that reasoning is the entire
# justification for the value. Nothing enforced it: PREMERGE_MAX_FIX_WAVE exists
# on its own Constants row and inside the sentence claiming the equality, and
# nowhere else in tests/ or lib/, so the argument could go false with no row
# moving. What makes the wave size real is the fence, which passes
# `--max-per-wave` EXPLICITLY rather than leaning on the library's argparse
# default — so the fence's literal, not the default, is what the cap must equal.
P22C_DOC_WAVE="$(sed -n 's/^PREMERGE_MAX_FIX_WAVE[[:space:]][[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$SKILL" | sed -n '1p')"
P22C_FENCE_WAVES="$(sed -n 's/^[[:space:]]*--max-per-wave[[:space:]][[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$FENCES")"
P22C_FENCE_WAVE="$(sort -u <<<"$P22C_FENCE_WAVES")"
P22C_FENCE_WAVE_N="$(grep -c . <<<"$P22C_FENCE_WAVE")"
if [ -z "$P22C_DOC_WAVE" ]; then
  echo "  FAIL  P22c: the Constants block declares no PREMERGE_MAX_FIX_WAVE value"; FAIL=$((FAIL + 1))
elif [ "$P22C_FENCE_WAVE_N" != "1" ]; then
  echo "  FAIL  P22c: the fences pass $P22C_FENCE_WAVE_N distinct --max-per-wave values:"
  sed 's/^/          /' <<<"$P22C_FENCE_WAVES"
  FAIL=$((FAIL + 1))
elif [ "$P22C_FENCE_WAVE" != "$P22C_DOC_WAVE" ]; then
  echo "  FAIL  P22c: Constants says PREMERGE_MAX_FIX_WAVE=$P22C_DOC_WAVE, the fence runs --max-per-wave $P22C_FENCE_WAVE"
  FAIL=$((FAIL + 1))
elif [ "$P22C_DOC_WAVE" != "$P22C_DOC_CAP" ]; then
  echo "  FAIL  P22c: the SKILL says the cap equals the wave size, but declares $P22C_DOC_CAP and $P22C_DOC_WAVE"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  P22c: the fence runs the declared wave size and the cap equals it ($P22C_DOC_WAVE)"
  PASS=$((PASS + 1))
fi

assert_fixed "$LIB" 'blocked-on-%02d.json' "P22c: the library reads ONE predecessor by name, not a range"
assert_fixed "$LIB" '_beneath_repo_root' "P22c: containment is a filesystem check the library actually has"
assert_fixed "$SKILL" 'blocked-on-<NN>.json' "P22c: the SKILL names the artifact the controller writes"
assert_fixed "$SKILL" 'BLOCKED=<n>' "P22c: the triage line documents the new field"
assert_grep "$SKILL_MISTAKES" 'Adding a `blocked_on_file` path straight to the commit fence' \
  "P22c: the bypass is written down as a mistake, not left to be rediscovered"
assert_grep "$SKILL_MISTAKES" 'Unioning `blocked_on_file` across every earlier attempt' \
  "P22c: and so is the accumulating union"
# ANTI-VACUITY for the two assert_not_in rows above: the SAME two patterns —
# read out of $P22B_BYPASS_RE and $P22B_APPEND_RE, never re-typed — over a body
# that DOES bypass. Both must match here, or the row they guard is asserting
# nothing about the real fence. Herestrings, not pipes: an early-exiting reader
# behind a pipe is the EPIPE class tests/epipe-guard.test.sh bans.
P22C_MUTANT='PREMERGE_ASSIGNED_LIST="$PREMERGE_RUN_DIR/x.assigned"
jq -r ".blocked_on[].file" <"$PREMERGE_RUN_DIR/blocked-on-01.json" >>"$PREMERGE_ASSIGNED_LIST"'
if grep -qE -e "$P22B_BYPASS_RE" <<<"$P22C_MUTANT"; then
  echo "  PASS  P22c: the bypass detector sees a bypass when there is one"; PASS=$((PASS + 1))
else
  echo "  FAIL  P22c: the bypass detector cannot see a bypass — P22b is vacuous"; FAIL=$((FAIL + 1))
fi
if grep -qE -e "$P22B_APPEND_RE" <<<"$P22C_MUTANT"; then
  echo "  PASS  P22c: the append detector sees an append when there is one"; PASS=$((PASS + 1))
else
  echo "  FAIL  P22c: the append detector cannot see an append — P22b is vacuous"; FAIL=$((FAIL + 1))
fi

echo "== P23: the 4c verify review is scoped to the polish, not the stack (#795) =="
# 4c asks "did the polish do harm", never "what else is wrong with the stack".
# Pointed at the stack PR it re-samples an unbounded finding set, and any blocker
# it happens to roll -- including one present all along that the green gate simply
# did not sample -- reads as "a blocker the polish introduced" and REVERTS a
# correct, behaviour-preserving refactor.
#
# The scope comes from the CHECKOUT, not from a target argument: 4b commits and
# does NOT push, so the reviewer's no-target default `git diff @{upstream}...HEAD`
# resolves to exactly the polish. Passing a range instead would be interpreted
# rather than enforced on the default cell, and an IGNORED target falls back to
# that same default -- which on an already-pushed branch is EMPTY. That is the
# trap these rows exist to keep shut: the failure is a vacuous green, not a wider
# review.
SIMPLIFY_PUSH_FENCE="$(fence_body "$SKILL" premerge-simplify-push)"
if [ -n "$SIMPLIFY_PUSH_FENCE" ]; then
  echo "  PASS  P23: the simplify-push fence extracts non-empty"; PASS=$((PASS + 1))
else
  echo "  FAIL  P23: the simplify-push fence extracted empty - the origin tag moved"; FAIL=$((FAIL + 1))
fi
assert_grep "$SKILL" '^```bash uberdev-executable origin=premerge-simplify-push$' \
  "P23: the simplify-push fence carries exactly its documented origin tag"
# THE LOAD-BEARING ROW. The commit fence must not push: the unpushed window IS
# 4c's review scope. A push here re-creates the empty-default vacuous green.
# assert_not_in / assert_in, NOT assert_no_grep / assert_grep: a fence body is a
# STRING, and handing it to a helper that greps a FILE makes the row vacuous --
# grep cannot open it, reports no match, and a "must not contain" row passes for
# the wrong reason. The anti-vacuity mutant below is what caught that here.
assert_not_in "$SIMPLIFY_FENCE" 'push origin' \
  "P23: the simplify-COMMIT fence does not push - the unpushed window is the scope"
assert_in "$SIMPLIFY_PUSH_FENCE" 'push origin "$PREMERGE_BRANCH"' \
  "P23: the simplify-PUSH fence is the one that pushes"
# THE PROSE HALF. The fence-body row above cannot see 4b's SURROUNDING TEXT, and a
# leftover "Push." sentence next to a fence that must not push is a contradiction a
# controller resolves by pushing -- which closes the unpushed window and hands 4c an
# empty review. Scoped to the 4b section, extracted by heading, not the whole file.
P23_4B="$(awk '/^### 4b — Apply the behaviour-preserving findings$/{f=1;next} /^### 4b-defer/{f=0} f' "$SKILL")"
if [ -z "$P23_4B" ]; then
  echo "  FAIL  P23: could not extract the 4b section - its heading moved"; FAIL=$((FAIL + 1))
else
  echo "  PASS  P23: the 4b section extracts non-empty"; PASS=$((PASS + 1))
fi
assert_not_in "$P23_4B" '(^|[^-])[Pp]ush\.' \
  "P23: 4b's prose does not tell the controller to push"
assert_in "$P23_4B" 'Do not push' \
  "P23: 4b's prose says the opposite, in words"
# THE FLAG. The push is the ONLY push of the simplify commit, so it must not sit
# behind --no-post-simplify-review: that flag is documented as costing the
# verification, never the polish. Without this row the polish is committed locally
# and never reaches the stack PR on `/premerge --no-post-simplify-review`.
assert_fixed "$SKILL" 'Step 2 — the push —' \
  "P23: 4c distinguishes the flag-gated steps from the push"
assert_fixed "$SKILL" 'runs regardless' \
  "P23: and says the push runs regardless of --no-post-simplify-review"
# 4b's non-zero exits leave the lens edits UNCOMMITTED in a dirty tree, where the
# reviewer's empty-range fallback would sweep them into the review.
assert_fixed "$SKILL" 'a non-zero exit' \
  "P23: 4c has an arm for 4b refusing, not just for 4b finding nothing to do"
# 4c passes a level and no target. Both halves matter: the old bare-PR call is
# gone, and nothing reintroduced a target of any shape.
P23_BARE_PR_RE='code-review", "<level> <PREMERGE_PR>"'
assert_no_grep "$SKILL" "$P23_BARE_PR_RE" \
  "P23: 4c no longer dispatches the verify review at the bare stack PR"
assert_fixed "$SKILL" 'Skill("code-review", "<level>")' \
  "P23: 4c dispatches with a level and no target argument"
assert_fixed "$SKILL" 'No target' \
  "P23: and says so in words, so the next editor does not helpfully add one"
# The no-edits arm: 4b can exit before making a commit, and 4c must skip rather
# than verify a commit that was never made.
assert_fixed "$SKILL" 'COMMIT=none REASON=no-edits`** — skip 4c entirely' \
  "P23: 4c has an explicit skip arm for 4b's no-edits early exit"
# The pointer 4c hands the next editor must resolve. A "do not do X, see Y for why"
# whose Y does not exist is how X gets re-added by someone acting in good faith.
assert_fixed "$SKILL_MISTAKES" 'Handing 4c a target argument' \
  "P23: the mistake entry 4c points at actually exists"
assert_fixed "$SKILL_MISTAKES" 'It degrades to an empty' \
  "P23: and it records the empty-review failure direction, not a wider-review one"
# The retraction of the false range claim stays retracted.
assert_no_grep "$SKILL" 'not a two-SHA range' \
  "P23: the false 'ranges are not a target form' claim is gone"
# ANTI-VACUITY, one per assert_no_grep above, each re-reading the SAME pattern
# rather than re-typing it. Herestrings, not pipes (EPIPE guard).
P23_PUSH_RE='push origin'
P23_PUSH_MUTANT='PREMERGE_PUSH_ERR="$(git push origin "$PREMERGE_BRANCH" 2>&1 1>/dev/null)" || {'
if grep -qE -e "$P23_PUSH_RE" <<<"$P23_PUSH_MUTANT"; then
  echo "  PASS  P23: the push detector sees a push when there is one"; PASS=$((PASS + 1))
else
  echo "  FAIL  P23: the push detector cannot see a push - the row above is vacuous"; FAIL=$((FAIL + 1))
fi
P23_MUTANT='1. `Skill("code-review", "<level> <PREMERGE_PR>")` again, scoped to the refactor.'
if grep -qE -e "$P23_BARE_PR_RE" <<<"$P23_MUTANT"; then
  echo "  PASS  P23: the bare-PR detector sees the old call when it is present"; PASS=$((PASS + 1))
else
  echo "  FAIL  P23: the bare-PR detector cannot see the old call - the row above is vacuous"; FAIL=$((FAIL + 1))
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

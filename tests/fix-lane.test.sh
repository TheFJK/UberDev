#!/usr/bin/env bash
# tests/fix-lane.test.sh — suite for the /fix lean single-issue lane (RFC 0022).
#
# Two kinds of row, kept apart on purpose.
#
# FX-E* are EXECUTED. They run the real launcher and the real lib and read the
# real exit codes. Every guard this lane adds that can be reached without a
# network round-trip is proved here rather than described: the whole point of
# putting FX1 and the FX2 knob-validation ahead of `gh repo view` is that they
# are reachable before a claim is written — which also makes them reachable
# from CI. A row that could be executed and is only grepped is a row that
# passes when the code stops working.
#
# FX-S* are SHAPE checks over source bytes, for the instructions this change
# ships to a MODEL rather than to a shell — the skill's phases, invariants and
# return contracts, which no test can execute. The launcher and lib behaviour
# they used to stand in for is executed above, against a stubbed `gh`.
#
# Both kinds are portable (bash + grep + awk + python3, no git, no gh, no
# network), so this file runs on both CI jobs.
#
# Sections:
#   FX-E1  — --fix requires --standard (rc 64, before anything)
#   FX-E2  — FX1: two or more issues is refused before any claim (rc 1)
#   FX-E3  — FX1: one issue passes the gate, claims, and emits a plan
#   FX-E4  — the emitted plan envelope, PARSED: lane, prefix, key set, key count
#   FX-E4b — FX2: the rounds knob reaches the plan, canonicalised
#   FX-E5  — FX2: a malformed UBERDEV_FIX_FIX_ROUNDS is refused before a claim
#   FX-E6  — audit --basename: default preserved, honoured, traversal refused
#   FX-S1  — command file structure + the no-Workflow invariant
#   FX-S2  — the command mandates the launcher call, the flags and the skill
#   FX-S3  — skill structure: frontmatter, every phase, invariants, contracts
#   FX-S4  — the lane's give-ups and keeps are STATED, not assumed
#   FX-S5  — controller-owned git + explicit-path staging are stated as rules
#   FX-S6  — TOO_BIG is a first-class return, distinct from BLOCKED
#   FX-S7  — the review result goes through the CANONICAL validator, not a copy
#   FX-S8  — launcher: --fix parsed, FX1 sits before gh, Step 5f emits FIX_PLAN
#   FX-S9  — the skill reads the envelope's fields, never a literal
#   FX-S10 — circuit breakers FX1..FX4 are named in the skill and the RFC
#   FX-S11 — the lib is invoked as an executable, never sourced (zsh trap)
#   FX-S12 — RFC 0022 exists, is numbered uniquely, and states the decision
#   FX-S13 — the lane forbids a version bump and never merges
set -u; set -o pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
CMD="$PLUGIN_ROOT/commands/fix.md"
SKILL="$PLUGIN_ROOT/skills/fix-fleet/SKILL.md"
# The SKILL is SKILL.md PLUS the reference files its body points at: a rule the
# skill still states is still stated BY THE SKILL wherever progressive disclosure
# moved it. Globbed, not listed, so a new reference file is covered on arrival.
# Only the frontmatter rows read "$SKILL" alone — frontmatter belongs to the body.
SKILL_SET=( "$PLUGIN_ROOT/skills/fix-fleet/SKILL.md" )
for _fx_ref in "$PLUGIN_ROOT/skills/fix-fleet/references"/*.md; do
  [ -r "$_fx_ref" ] && SKILL_SET+=( "$_fx_ref" )
done
LIB="$PLUGIN_ROOT/lib/turbox-fleet.sh"
LAUNCHER="$PLUGIN_ROOT/lib/solve-launcher.sh"
RFC="$REPO_ROOT/docs/rfc/0022-fix-lean-lane.md"

for f in "$CMD" "$SKILL" "$LIB" "$LAUNCHER" "$RFC"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0; FAIL=0
ck() { if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

# --- the executed-row harness ------------------------------------------------
#
# HERMETIC BY CONSTRUCTION, and that is not a nicety. The launcher's Step 4.5
# claim protocol MUTATES GitHub: `gh label create --force`, `gh issue edit
# --add-label --add-assignee`, `gh issue comment`. FX-E3 exists precisely to
# drive a run PAST the FX1 arity gate, so with a real `gh` on PATH it would
# reach all three and write a live claim on whatever repo `gh repo view`
# resolves from the caller's cwd — a claim nothing in the run releases. The
# stub below is what makes an executed launcher row safe to write at all; it is
# the same device tests/solve-routing.test.sh uses for the same reason.
#
# It also makes the rows MEAN something in CI, where an unstubbed run would die
# at `gh repo view` for want of auth and every negative assertion below would
# pass vacuously.
FX_TMP="$(mktemp -d)"
trap 'rm -rf "$FX_TMP"' EXIT
FX_BIN="$FX_TMP/bin"; mkdir -p "$FX_BIN" "$FX_TMP/home"
FX_GH_LOG="$FX_TMP/gh-calls"

cat >"$FX_BIN/gh" <<'FXGH'
#!/usr/bin/env bash
# Every invocation is logged BEFORE it is answered, so a row can assert on what
# the launcher tried to do and not merely on what it printed.
printf '%s\n' "$*" >>"$GH_CALL_LOG"
case "$1 $2" in
  "repo view")     printf '%s\n' 'owner/repo' ;;
  "issue view")    printf '%s\n' '{"number":100,"title":"stub issue","state":"OPEN","body":"A stub body for the fix lane harness.","labels":[],"assignees":[],"comments":[]}' ;;
  "label create")  : ;;
  "api user")      printf '%s\n' 'fixtureuser' ;;
  "issue edit")    : ;;
  "issue comment") cat >/dev/null ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
FXGH

cat >"$FX_BIN/claude" <<'FXCC'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo "2.1.152 (Claude Code)"; exit 0; fi
exit 0
FXCC
chmod +x "$FX_BIN/gh" "$FX_BIN/claude"

# run_launcher <launcher args...>
# Leaves the combined output in $FX_OUT and returns the launcher's exit code.
# Every run gets a FRESH gh call log, so `gh_calls` reports this row's calls.
FX_OUT=""
run_launcher() {
  : >"$FX_GH_LOG"
  FX_OUT="$(env PATH="$FX_BIN:$PATH" HOME="$FX_TMP/home" TMPDIR="$FX_TMP" \
             GH_CALL_LOG="$FX_GH_LOG" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
             UBERDEV_FIX_FIX_ROUNDS="${FX_ROUNDS_ENV:-}" \
             bash "$LAUNCHER" "$@" 2>&1)"
  return $?
}
# awk, not `grep -c`: grep prints 0 and EXITS 1 on no match, so a `|| echo 0`
# fallback emits a second zero and the caller's `[ $(...) -eq 0 ]` becomes a
# shell error rather than a false — which `if` then swallows into a pass.
gh_calls()     { awk 'END{print NR+0}' "$FX_GH_LOG" 2>/dev/null; }
gh_mutations() { awk '/^(label create|issue edit|issue comment)/{n++} END{print n+0}' "$FX_GH_LOG" 2>/dev/null; }

echo "== FX-E1: --fix requires --standard =="
# Refused in the launcher-option loop, so it fires before the CLI is parsed at
# all — no issue number is even needed to trip it.
FX_ROUNDS_ENV=1 run_launcher --auto-mode=1 --turbo --fix -- 100
FX_RC=$?
ck "exits 64 (launcher-option error)"  "[ $FX_RC -eq 64 ]"
ck "names the --standard requirement"  "grep -q 'requires --standard' <<<\"\$FX_OUT\""
ck "names RFC 0022"                    "grep -q 'RFC 0022' <<<\"\$FX_OUT\""

echo
echo "== FX-E2: FX1 — two or more issues is refused BEFORE any claim =="
FX_ROUNDS_ENV=1 run_launcher --auto-mode=1 --turbo --standard --fix -- 100 101
FX_RC=$?
ck "exits 1"                            "[ $FX_RC -eq 1 ]"
ck "says exactly one issue"             "grep -q 'takes exactly one issue' <<<\"\$FX_OUT\""
ck "reports the count it saw"           "grep -q 'got 2' <<<\"\$FX_OUT\""
ck "points at /turbox for a batch"      "grep -q '/turbox' <<<\"\$FX_OUT\""
# The load-bearing half: the refusal must be reachable before Step 4.5, or a
# rejected run leaves `uberdev:active` labels behind with nothing running.
ck "declares no claims were written"    "grep -q 'no claims written; no agents dispatched' <<<\"\$FX_OUT\""
# The load-bearing proof, and it is a COUNT rather than a string: the launcher
# invoked `gh` zero times, so it cannot have written a claim whatever it
# printed. If the arity refusal ever drifts below `gh repo view` this reds.
ck "invoked gh zero times"              "[ \$(gh_calls) -eq 0 ]"

echo
echo "== FX-E3: FX1 — one issue PASSES the arity gate, all the way to a plan =="
# The positive control for FX-E2: without it, an FX1 that refused *everything*
# would look identical. One issue must get past the gate, reach the claim
# protocol, and emit a plan.
FX_ROUNDS_ENV=3 run_launcher --auto-mode=1 --turbo --standard --fix -- 100
FX_RC=$?
ck "does not trip the arity refusal"    "! grep -q 'takes exactly one issue' <<<\"\$FX_OUT\""
ck "does not trip the --standard rule"  "! grep -q 'requires --standard' <<<\"\$FX_OUT\""
ck "does not trip the FX2 knob rule"    "! grep -q 'UBERDEV_FIX_FIX_ROUNDS' <<<\"\$FX_OUT\""
ck "exits 0"                            "[ $FX_RC -eq 0 ]"
# It DID reach the claim protocol — against the stub, never GitHub. This is the
# half FX-E2's zero-call assertion is measured against: both rows are vacuous
# unless one of them shows the calls actually happen when the gate opens.
ck "reached the claim protocol"         "[ \$(gh_mutations) -ge 1 ]"
ck "emitted the plan"                   "grep -q '^FIX_PLAN_BEGIN$' <<<\"\$FX_OUT\""
ck "closed the plan envelope"           "grep -q '^FIX_PLAN_END$' <<<\"\$FX_OUT\""

echo
echo "== FX-E4: the emitted envelope, parsed — not grepped =="
# The RFC and the launcher each describe this envelope in prose, and prose
# copies drift: RFC 0022 said 13 keys while Step 5f emitted 14, and no grep
# over either file could see the disagreement. These rows read the JSON the
# launcher actually printed.
FX_PLAN="$(awk '/^FIX_PLAN_BEGIN$/{f=1;next} /^FIX_PLAN_END$/{f=0} f' <<<"$FX_OUT")"
ck "the envelope is non-empty"          "[ -n \"\$FX_PLAN\" ]"
fx_plan_field() { printf '%s' "$FX_PLAN" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1" 2>/dev/null; }
fx_plan_keys()  { printf '%s' "$FX_PLAN" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))' 2>/dev/null; }
ck "it is valid JSON"                   "[ -n \"\$(fx_plan_keys)\" ]"
ck "lane is fix-lean"                   "[ \"\$(fx_plan_field lane)\" = 'fix-lean' ]"
ck "issueCount is 1"                    "[ \"\$(fx_plan_field issueCount)\" = '1' ]"
ck "branchPrefix is worktree-fix-issue-" "[ \"\$(fx_plan_field branchPrefix)\" = 'worktree-fix-issue-' ]"
# A NON-DEFAULT value on purpose: `1` is what `${UBERDEV_FIX_FIX_ROUNDS:-1}`
# produces on its own, so asserting 1 here would hold even if the launcher
# ignored the env var completely.
ck "fixRounds carries a non-default env value" "[ \"\$(fx_plan_field fixRounds)\" = '3' ]"
for fx_absent in riskIssueCount concurrency implementBudget maxAgents; do
  ck "OMITS $fx_absent"                 "! grep -qw '$fx_absent' <<<\"\$(fx_plan_keys)\""
done
# The key COUNT is what catches a field added to the composer and to nothing
# else. Update this number and RFC 0022 section 2 together, or not at all.
ck "carries exactly 14 keys"            "[ \$(wc -w <<<\"\$(fx_plan_keys)\" | tr -d ' ') -eq 14 ]"
ck "RFC 0022 states the same 14"        "grep -q '| Plan envelope | 18 keys | \*\*14\*\*' '$RFC'"

echo
echo "== FX-E4b: FX2 — leading zeros are stripped, never read as octal =="
# `007` alone cannot see this bug: 7 is the same number in base 8 and base 10.
# `010` and `08` are the discriminating cases — `$(( 010 + 0 ))` is 8, and
# `$(( 08 + 0 ))` is a fatal arithmetic error, so a canonicaliser built on
# arithmetic passes the first row here and silently halves the cap on the next.
for fx_pair in 007:7 010:10 08:8 09:9 0100:100; do
  FX_ROUNDS_ENV="${fx_pair%%:*}" run_launcher --auto-mode=1 --turbo --standard --fix -- 100
  FX_PLAN="$(awk '/^FIX_PLAN_BEGIN$/{f=1;next} /^FIX_PLAN_END$/{f=0} f' <<<"$FX_OUT")"
  ck "UBERDEV_FIX_FIX_ROUNDS=${fx_pair%%:*} reaches the plan as ${fx_pair##*:}" \
     "[ \"\$(fx_plan_field fixRounds)\" = '${fx_pair##*:}' ]"
done

echo
echo "== FX-E5: FX2 — a malformed rounds knob is refused before a claim =="
# `00` is the case a string-glob-only guard misses; `0` is the one it catches.
for bad in 0 00 000 -1 abc 1.5; do
  FX_ROUNDS_ENV="$bad" run_launcher --auto-mode=1 --turbo --standard --fix -- 100
  FX_RC=$?
  ck "UBERDEV_FIX_FIX_ROUNDS='$bad' exits 2"        "[ $FX_RC -eq 2 ]"
  ck "UBERDEV_FIX_FIX_ROUNDS='$bad' names the knob" "grep -q 'UBERDEV_FIX_FIX_ROUNDS must be a positive integer' <<<\"\$FX_OUT\""
  ck "UBERDEV_FIX_FIX_ROUNDS='$bad' wrote no claim" "grep -q 'no claims written; no agents dispatched' <<<\"\$FX_OUT\""
  ck "UBERDEV_FIX_FIX_ROUNDS='$bad' invoked gh zero times" "[ \$(gh_calls) -eq 0 ]"
done

echo
echo "== FX-E6: audit --basename — shared lib, separate sinks =="
FX_AUDIT_DIR="$FX_TMP/audit"
mkdir -p "$FX_AUDIT_DIR"
bash "$LIB" audit --run-dir "$FX_AUDIT_DIR" --event turbox_row >/dev/null 2>&1
ck "default basename is still turbox-audit.jsonl" "[ -s '$FX_AUDIT_DIR/turbox-audit.jsonl' ]"
bash "$LIB" audit --run-dir "$FX_AUDIT_DIR" --event fix_row --basename fix-audit.jsonl >/dev/null 2>&1
ck "--basename writes the named sink"             "[ -s '$FX_AUDIT_DIR/fix-audit.jsonl' ]"
ck "the two sinks do not mix"                     "[ \$(grep -c fix_row '$FX_AUDIT_DIR/turbox-audit.jsonl') -eq 0 ]"
# A basename that is really a path would let a caller write outside the run
# dir, which is the one thing an audit sink must not do.
bash "$LIB" audit --run-dir "$FX_AUDIT_DIR" --event escape --basename ../escaped.jsonl >/dev/null 2>&1
ck "a traversing --basename exits 2"              "[ \$? -eq 2 ]"
ck "and wrote nothing outside the run dir"        "[ ! -e '$FX_TMP/escaped.jsonl' ]"

echo
echo "== FX-S1: command file structure + the no-Workflow invariant =="
ck "has description frontmatter"   "grep -q '^description:' '$CMD'"
ck "has argument-hint"             "grep -q '^argument-hint:' '$CMD'"
ck "has allowed-tools"             "grep -q '^allowed-tools:' '$CMD'"
ck "allowed-tools declares Task"   "[ \$(grep '^allowed-tools:' '$CMD' | grep -c '\"Task\"') -ge 1 ]"
# The lane's defining negative, inherited from /turbox: a fix plan relayed into
# Workflow() would run the wrong pipeline rather than produce an error, and the
# cheapest place to make that impossible is the tool list.
ck "allowed-tools OMITS Workflow"  "[ \$(grep '^allowed-tools:' '$CMD' | grep -c 'Workflow') -eq 0 ]"
# The ALIASES-row byte-equality contract is NOT re-asserted here:
# tests/aliases.test.sh A6 owns it and this change added `fix` to its loop.

echo
echo "== FX-S2: the command mandates the launcher call and the skill =="
ck "runs lib/solve-launcher.sh"          "grep -q 'lib/solve-launcher.sh' '$CMD'"
ck "passes --auto-mode=1 --turbo"        "grep -q '\-\-auto-mode=1 --turbo' '$CMD'"
ck "passes --standard"                   "grep -q '\-\-standard' '$CMD'"
ck "passes --fix"                        "grep -q '\-\-standard --fix' '$CMD'"
ck "forwards \$ARGUMENTS after --"       "grep -q '\-\- \$ARGUMENTS' '$CMD'"
ck "names the fix-fleet skill"           "grep -q 'uberdev:fix-fleet' '$CMD'"
ck "names FIX_PLAN_BEGIN"                "grep -q 'FIX_PLAN_BEGIN' '$CMD'"
ck "names FIX_PLAN_END"                  "grep -q 'FIX_PLAN_END' '$CMD'"
ck "says relay verbatim"                 "grep -qi 'verbatim' '$CMD'"
ck "forbids calling Workflow in prose"   "grep -q 'Do not call \`Workflow\`' '$CMD'"
ck "documents that --backend is refused" "grep -q '\`--backend=<name>\` is REFUSED' '$CMD'"
ck "documents the arity of exactly one"  "grep -q 'Exactly one issue' '$CMD'"

echo
echo "== FX-S3: skill structure =="
ck "skill has name frontmatter"  "grep -q '^name: fix-fleet' '$SKILL'"
ck "skill has description"       "grep -q '^description:' '$SKILL'"
for phase in 0 1 2 3 4 5 6; do
  ck "has '## Phase $phase'"     "grep -q '^## Phase $phase ' '$SKILL'"
done
# Seven phases, not eight: a '## Phase 7' here would mean the turbox pipeline
# was copied in rather than narrowed.
ck "has NO '## Phase 7'"         "! grep -q '^## Phase 7' '$SKILL'"
ck "has an Inputs section"       "grep -q '^## Inputs' '$SKILL'"
ck "has an Invariants section"   "grep -q '^## Invariants' '$SKILL'"
ck "has Return contracts"        "grep -q '^## Return contracts' '$SKILL'"
ck "has Circuit breakers"        "grep -q '^## Circuit breakers' '$SKILL'"
# Anthropic's ceiling; tests/skill-size.test.sh ratchets it repo-wide, and a
# lean lane whose skill is not lean is the first sign the narrowing did not
# happen.
ck "skill is under the 500-line ceiling" "[ \$(wc -l < '$SKILL') -lt 500 ]"

echo
echo "== FX-S4: the lane's give-ups and keeps are STATED =="
ck "names the design rungs it drops"       "grep -q 'design-planner' \"\${SKILL_SET[@]}\""
ck "names plan-reviewer as dropped"        "grep -q 'plan-reviewer' \"\${SKILL_SET[@]}\""
ck "states the rung count it trades"       "grep -qi 'sequential' \"\${SKILL_SET[@]}\""
ck "states what it does NOT drop"          "grep -q 'drops is design, not\\? *$\\|design, not' \"\${SKILL_SET[@]}\""
ck "keeps the full test suite"             "grep -qi 'full test suite' '$SKILL'"
ck "keeps the untrusted-input envelope"    "grep -q 'external-untrusted-input' '$SKILL'"
ck "keeps the issue_body_file channel"     "grep -q 'issue_body_file' '$SKILL'"
ck "warns context_file is NOT the body"    "grep -q 'NOT the issue body' '$SKILL'"

echo
echo "== FX-S5: controller-owned git + explicit-path staging =="
ck "states the controller owns git"        "grep -q 'You own git' '$SKILL'"
ck "forbids agents running git"            "grep -q 'GIT: do not run git' '$SKILL'"
ck "mandates stage-commit"                 "grep -q 'stage-commit' '$SKILL'"
ck "names the staging refusals"            "grep -q 'refuses \`-A\`' '$SKILL'"
ck "forbids reconstructing a file list"    "grep -q 'not guess a file list' '$SKILL'"

echo
echo "== FX-S6: TOO_BIG is first-class and distinct from BLOCKED =="
ck "TOO_BIG is in the return vocabulary"   "grep -q 'TOO_BIG' '$SKILL'"
ck "TOO_BIG and BLOCKED are not collapsed" "grep -q 'TOO_BIG\` and \`BLOCKED\` are different answers' '$SKILL'"
ck "TOO_BIG routes the operator to /turbox" "grep -q 'run \`/turbox\`' '$SKILL'"
ck "TOO_BIG is not treated as a failure"   "grep -qi 'not\\*\\* a failure\\|not a failure' '$SKILL'"
ck "the controller may not argue it away"  "grep -qi 'Never talk an agent out of it' '$SKILL'"

echo
echo "== FX-S7: the review result goes through the CANONICAL validator =="
# A second copy of the phase1-reviewer schema would drift from the first, and
# prose asserting the two agree is not a producer. The skill must call the
# canonical boundary by name.
ck "calls uberdev_child_validate_phase1_review_result" \
   "grep -q 'uberdev_child_validate_phase1_review_result' '$SKILL'"
ck "names the phase1-reviewer contract file" \
   "grep -q 'phase1-reviewer-output-v1.md' '$SKILL'"
ck "invokes it through bash -c (the zsh trap)" \
   "grep -q 'bash -c .\\. \"\\\${@:1:1}/lib/child-dispatch.sh\"' '$SKILL'"
# The controller may read the verdict and the blocker count; it may not read
# the findings.
ck "reads only the verdict line"           "grep -q \"grep -m1 '^verdict:'\" '$SKILL'"
ck "counts blockers rather than reading them" "grep -q 'severity:\\[\\[:space:\\]\\]\\*blocker' '$SKILL'"
# `grep -c` exits 1 on zero matches, and zero blockers IS the success path, so
# the clean review would report itself as a failed probe.
ck "counts with awk, never grep -c"           "! grep -q \"grep -cE '^  - severity\" '$SKILL'"
ck "states findings travel on disk only"   "grep -qi 'never the findings text' '$SKILL'"
# The boundary this row guards really exists where the skill says it does.
ck "the validator is defined in lib/child-dispatch.sh" \
   "grep -q '^uberdev_child_validate_phase1_review_result()' '$PLUGIN_ROOT/lib/child-dispatch.sh'"

echo
echo "== FX-S8: launcher — the --fix seam =="
ck "parses --fix as a launcher option"     "grep -q '\-\-fix)         FIX_MODE=1' '$LAUNCHER'"
ck "lists --fix in the unknown-option error" "grep -q 'only --auto-mode=0|1, --turbo, --standard, --fix' '$LAUNCHER'"
ck "requires --standard"                   "grep -q 'requires --standard' '$LAUNCHER'"
ck "emits FIX_PLAN_BEGIN"                  "grep -q 'echo \"FIX_PLAN_BEGIN\"' '$LAUNCHER'"
ck "emits FIX_PLAN_END"                    "grep -q 'echo \"FIX_PLAN_END\"' '$LAUNCHER'"
ck "validates the fix-fleet SKILL exists"  "grep -q 'skills/fix-fleet/SKILL.md' '$LAUNCHER'"
ck "audits the prepared lane"              "grep -q 'fix_lean_lane_prepared' '$LAUNCHER'"
# Placement is the whole guarantee, and a line-number comparison is the only
# thing that can see it drift. `gh repo view` is the launcher's first network
# round-trip; Step 4.5 writes claims after it.
FX1_LINE="$(grep -n 'takes exactly one issue' "$LAUNCHER" | head -1 | cut -d: -f1)"
GH_LINE="$(grep -n 'gh repo view' "$LAUNCHER" | head -1 | cut -d: -f1)"
ck "FX1 is located before the first gh call (${FX1_LINE:-?} < ${GH_LINE:-?})" \
   "[ -n '$FX1_LINE' ] && [ -n '$GH_LINE' ] && [ '$FX1_LINE' -lt '$GH_LINE' ]"
KNOB_LINE="$(grep -n 'UBERDEV_FIX_FIX_ROUNDS must be a positive integer' "$LAUNCHER" | head -1 | cut -d: -f1)"
ck "the FX2 knob check is before the first gh call (${KNOB_LINE:-?} < ${GH_LINE:-?})" \
   "[ -n '$KNOB_LINE' ] && [ -n '$GH_LINE' ] && [ '$KNOB_LINE' -lt '$GH_LINE' ]"

echo
echo "== FX-S9: the skill reads the envelope, never a literal =="
# The envelope's SHAPE is not grepped out of the composer's source here — FX-E4
# parses it out of the JSON the launcher actually printed, which is strictly
# better evidence and cannot be satisfied by a composer that no longer runs.
# What execution cannot see is the skill hardcoding a value the plan carries.
ck "the skill reads branchPrefix, not a literal" \
   "! grep -q 'worktree-fix-issue-' '$SKILL'"

echo
echo "== FX-S10: circuit breakers FX1..FX4 =="
for bk in FX1 FX2 FX3 FX4; do
  ck "$bk named in the skill"  "grep -q '\*\*$bk\*\*' '$SKILL'"
  ck "$bk named in RFC 0022"   "grep -q '\*\*$bk\*\*' '$RFC'"
done
# FX2's cap must be READ from the plan, never restated. Restating it is how the
# two copies drift, and turbox's fix_rounds is a different number for a
# different loop.
ck "FX2 reads fixRounds from the plan"     "grep -q 'The cap is the plan' '$SKILL'"
ck "FX2 warns against turbox's fix_rounds" "grep -q 'never substitute' '$SKILL'"
ck "FX3 reads retest_rounds from the lib"  "grep -q 'loop-cap retest_rounds' '$SKILL'"

echo
echo "== FX-S11: the lib is an executable, never sourced =="
ck "skill states \$LIB is turbox-fleet.sh" "grep -q 'lib/turbox-fleet.sh' '$SKILL'"
ck "skill forbids sourcing it"             "grep -q 'never sourced' '$SKILL'"
ck "every \$LIB call goes through bash"    "[ \$(grep -c 'bash \"\$LIB\"' '$SKILL') -ge 4 ]"
ck "no bare \". \\\$LIB\" sourcing"        "! grep -qE '^\\s*\\.\\s+\"\\\$LIB\"' '$SKILL'"

echo
echo "== FX-S12: RFC 0022 =="
ck "RFC 0022 exists"                       "[ -r '$RFC' ]"
ck "RFC 0022 is Accepted"                  "grep -q '^| \*\*Status\*\* | Accepted |' '$RFC'"
ck "RFC 0022 states the decision"          "grep -q '^## 1. Decision' '$RFC'"
ck "RFC 0022 argues command-not-flag"      "grep -q 'Why a new command rather than a' '$RFC'"
ck "RFC 0022 lists alternatives"           "grep -q '^## 5. Alternatives considered' '$RFC'"
ck "RFC 0022 lists acceptance criteria"    "grep -q '^## 6. Acceptance criteria' '$RFC'"
# RFC-number uniqueness is NOT re-asserted here: docs-accuracy.test.sh already
# fails on `uniq -d` over every docs/rfc/NNNN-*.md, which covers 0022 too.

echo
echo "== FX-S13: no version bump, and the lane never merges =="
ck "skill forbids bumping the version"     "grep -q 'Do not bump the project version' '$SKILL'"
ck "skill says the bump rides the landing commit" "grep -qi 'bump belongs to the commit that lands' '$SKILL'"
ck "skill states the lane never merges"    "grep -q 'The lane \*\*never merges\*\*' '$SKILL'"
ck "command states the PR is parked"       "grep -qi 'parks\\*\\* the PR\\|park the PR' '$CMD'"
# Two seams that are wrong-by-default rather than wrong-by-omission, so each
# needs its own row: the shared audit sink and gh's head-branch inference.
ck "every audit call names the fix sink"   "grep -q 'passes \`--basename fix-audit.jsonl\`' '$SKILL'"
ck "gh pr create pins --head explicitly"   "grep -q 'gh pr create --repo <repoSlug> --base <baseBranch> --head' '$SKILL'"
ck "and says why --head is not optional"   "grep -q 'the head branch from the current' '$SKILL'"
# CLAUDE.md's bump-lane table must name this lane, or a reviewer reading a /fix
# PR as an unbumped user-facing change has nothing telling them otherwise.
ck "CLAUDE.md's lane table names /fix"     "grep -q 'fix-fleet/SKILL.md\` Phase 5' '$REPO_ROOT/CLAUDE.md'"

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]

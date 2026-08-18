#!/usr/bin/env bash
# tests/turbox-fleet-runtime.test.sh — RUNTIME behaviour of lib/turbox-fleet.sh
# and the launcher's --standard guards (RFC 0020).
#
# Split from tests/turbox-fleet.test.sh deliberately. That file greps source
# bytes and is portable; this one EXECUTES the helpers, which needs mktemp -d,
# a throwaway git repo with real worktrees, and python3 handed temp-dir paths on
# argv — the exact combination Git Bash mistranslates. Declared Unix-only in the
# test.yml windows-skip-list rather than left to fail confusingly there.
#
# Every guard is asserted by its EXIT CODE, not by its message, because the exit
# code is what the controller branches on. Messages are checked separately and
# only where the message is the only way to tell two refusals apart.
#
# Sections:
#   R1  — loop-cap is the single source for every cap
#   R2  — round-permitted: rc 0 under the cap, rc 3 at it, rc 2 called wrong
#   R3  — issue-concurrency: default 3, clamps ABOVE the cap, floors at 1
#   R4  — project-agents (TB1): the projection, and rc 3 over the ceiling
#   R5  — budget-spend (TB2): accumulates across calls, rc 3 at the limit
#   R6  — plan-tasks: parses waves + Owns, and reports unwaved/unowned
#   R7  — wave-disjoint (TB3): equality, CONTAINMENT, missing, cross-wave
#   R8  — stage-commit: refuses every stage-everything form; commits explicitly
#   R9  — worktree-add: cuts the checkout and is re-entrant
#   R10 — audit: one JSONL line per event, malformed data preserved not dropped
#   R11 — launcher --standard: refuses --backend flag AND env, before any claim
set -u; set -o pipefail
# ci-wiring: declared Unix-only in the test.yml windows-skip-list.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/plugins/uberdev/lib/turbox-fleet.sh"
LAUNCHER="$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh"

. "$REPO_ROOT/tests/_lib_exit_floor.sh" || { echo "FATAL: _lib_exit_floor.sh missing/unreadable" >&2; exit 2; }

for f in "$LIB" "$LAUNCHER"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "FATAL: git is required by this fixture" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required by this fixture" >&2; exit 2; }

TMP="$(mktemp -d)"
trap '_floor_rc=$?; rm -rf "$TMP"; uberdev_test_exit_floor turbox-fleet-runtime "$_floor_rc"' EXIT

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

# rc_is <expected-rc> <label> -- <command...>
# Runs the command, captures stdout+stderr, and asserts the exit code.
LAST_OUT=""
rc_is() {
  local want="$1" label="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local rc
  LAST_OUT="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label (rc=$rc)"; else
    bad "$label — expected rc=$want, got rc=$rc: $(printf '%s' "$LAST_OUT" | tr '\n' '|')"
  fi
}

out_is() {
  local want="$1" label="$2"
  if [ "$LAST_OUT" = "$want" ]; then ok "$label"; else
    bad "$label — expected '$want', got '$(printf '%s' "$LAST_OUT" | tr '\n' '|')'"
  fi
}

out_has() {
  local needle="$1" label="$2"
  case "$LAST_OUT" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label — '$needle' not in '$(printf '%s' "$LAST_OUT" | tr '\n' '|')'" ;;
  esac
}

echo "== R1: loop-cap is the single source for every cap =="
rc_is 0 "loop-cap fix_rounds"     -- bash "$LIB" loop-cap fix_rounds;     out_is 3 "fix_rounds is 3"
rc_is 0 "loop-cap retest_rounds"  -- bash "$LIB" loop-cap retest_rounds;  out_is 2 "retest_rounds is 2"
rc_is 0 "loop-cap context_rounds" -- bash "$LIB" loop-cap context_rounds; out_is 2 "context_rounds is 2"
rc_is 0 "loop-cap issue_cap"      -- bash "$LIB" loop-cap issue_cap;      out_is 3 "issue_cap is 3"
rc_is 2 "loop-cap rejects an unknown loop" -- bash "$LIB" loop-cap nonesuch
rc_is 64 "unknown subcommand exits 64"     -- bash "$LIB" definitely-not-a-subcommand

echo "== R2: round-permitted =="
rc_is 0 "round 1 permitted"  -- bash "$LIB" round-permitted --loop fix_rounds --round 1
rc_is 0 "round 3 permitted (at the cap)" -- bash "$LIB" round-permitted --loop fix_rounds --round 3
rc_is 3 "round 4 REFUSED"    -- bash "$LIB" round-permitted --loop fix_rounds --round 4
out_has "fix_rounds_exhausted" "the refusal names the loop it exhausted"
rc_is 3 "retest round 3 REFUSED" -- bash "$LIB" round-permitted --loop retest_rounds --round 3
rc_is 2 "round 0 is a caller error"      -- bash "$LIB" round-permitted --loop fix_rounds --round 0
rc_is 2 "non-numeric round is an error"  -- bash "$LIB" round-permitted --loop fix_rounds --round two
rc_is 2 "missing --loop is an error"     -- bash "$LIB" round-permitted --round 1

echo "== R3: issue-concurrency (the hard cap of 3) =="
rc_is 0 "default"            -- bash "$LIB" issue-concurrency;                 out_is 3 "defaults to 3"
rc_is 0 "configured 1"       -- bash "$LIB" issue-concurrency --configured 1;  out_is 1 "1 is honoured"
rc_is 0 "configured 2"       -- bash "$LIB" issue-concurrency --configured 2;  out_is 2 "2 is honoured"
rc_is 0 "configured 6"       -- bash "$LIB" issue-concurrency --configured 6
out_has "clamping to 3" "a value above the cap is clamped, and says so"
case "$LAST_OUT" in *3) ok "clamped value is 3" ;; *) bad "clamped value is not 3: $LAST_OUT" ;; esac
rc_is 0 "configured 0"       -- bash "$LIB" issue-concurrency --configured 0
out_has "below 1" "a value below 1 is floored, and says so"

echo "== R4: project-agents (TB1) =="
rc_is 0 "1 small + 2 design fits" -- bash "$LIB" project-agents --small 1 --design 2 --implement-budget 24 --max 600
out_is 67 "projection is small + (9 + budget) x design = 1 + 33*2 = 67"
rc_is 0 "all-small batch is cheap" -- bash "$LIB" project-agents --small 5 --design 0 --max 600
out_is 5 "five single solvers project five agents"
rc_is 3 "30 design issues REFUSED at 600" -- bash "$LIB" project-agents --small 0 --design 30 --implement-budget 24 --max 600
out_has "TB1 projected_agents=990" "the refusal reports the projection it computed"
rc_is 2 "missing --design is an error" -- bash "$LIB" project-agents --small 1

echo "== R5: budget-spend (TB2) =="
mkdir -p "$TMP/run"
rc_is 0 "spend 10 of 24"  -- bash "$LIB" budget-spend --run-dir "$TMP/run" --issue 355 --count 10 --limit 24
out_is 10 "tally is 10"
rc_is 0 "spend 10 more"   -- bash "$LIB" budget-spend --run-dir "$TMP/run" --issue 355 --count 10 --limit 24
out_is 20 "tally accumulates across calls (it lives on disk, not in context)"
rc_is 0 "a different issue has its own tally" -- bash "$LIB" budget-spend --run-dir "$TMP/run" --issue 356 --count 3 --limit 24
out_is 3 "issue 356 starts at 3, not 23"
rc_is 3 "reaching the limit REFUSES" -- bash "$LIB" budget-spend --run-dir "$TMP/run" --issue 355 --count 4 --limit 24
out_has "implement_budget_exhausted" "the refusal is named so the report can quote it"
rc_is 2 "an absent run dir is an error" -- bash "$LIB" budget-spend --run-dir "$TMP/nope" --issue 1 --count 1

echo "== R6: plan-tasks =="
cat > "$TMP/plan.md" <<'PLAN'
# Implementation plan

## Execution Waves

- wave-1: Task 1, Task 2
- wave-2: Task 3

### Task 1: Add the parser
**Wave:** [wave-1 — tasks in the same wave dispatch in parallel]
**Owns (file allowlist):** [lib/parser.sh, tests/parser.test.sh]
**Depends on:** none

### Task 2: Add the writer
**Wave:** wave-1
**Owns (file allowlist):** lib/writer.sh, tests/writer.test.sh

### Task 3: Wire them together
**Wave:** wave-2
**Owns (file allowlist):** `lib/main.sh`
PLAN
rc_is 0 "parses a well-formed plan" -- bash "$LIB" plan-tasks --plan "$TMP/plan.md"
PLAN_JSON="$LAST_OUT"
out_has '"task_count":3'   "finds all three tasks"
out_has '"waves":[1,2]'    "finds both waves"
out_has '"unwaved":[]'     "no task is missing a wave"
out_has '"unowned":[]'     "no task is missing ownership"
out_has 'lib/parser.sh'    "strips the template's square brackets from Owns"
out_has 'lib/main.sh'      "strips backticks from Owns"
rc_is 2 "a missing plan is an error" -- bash "$LIB" plan-tasks --plan "$TMP/does-not-exist.md"

cat > "$TMP/plan-bad.md" <<'PLAN'
### Task 1: Never says which wave
**Owns (file allowlist):** lib/a.sh

### Task 2: Never says what it owns
**Wave:** wave-1
PLAN
rc_is 0 "parses a defective plan without throwing" -- bash "$LIB" plan-tasks --plan "$TMP/plan-bad.md"
out_has '"unwaved":[1]'  "a task with no wave is REPORTED, never defaulted to wave 1"
out_has '"unowned":[2]'  "a task with no Owns list is reported"

echo "== R7: wave-disjoint (TB3) =="
rc_is 0 "wave 1 of the good plan is disjoint" -- bash "$LIB" wave-disjoint --tasks "$PLAN_JSON" --wave 1
rc_is 0 "wave 2 is a single task"             -- bash "$LIB" wave-disjoint --tasks "$PLAN_JSON" --wave 2
rc_is 3 "identical paths REFUSED" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/a.sh"]},{"id":2,"wave":1,"owns":["lib/a.sh"]}]}'
out_has "wave_paths_overlap" "the refusal is named"
out_has "task_a=1 task_b=2"  "the refusal names BOTH colliding tasks"
# The row this guard exists for: a plain set intersection calls these disjoint.
rc_is 3 "DIRECTORY CONTAINMENT refused (lib/ vs lib/x.sh)" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/"]},{"id":2,"wave":1,"owns":["lib/x.sh"]}]}'
rc_is 3 "containment refused in the other direction" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/x.sh"]},{"id":2,"wave":1,"owns":["lib"]}]}'
rc_is 0 "a shared PREFIX that is not a directory is fine (lib/a.sh vs lib/ab.sh)" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/a.sh"]},{"id":2,"wave":1,"owns":["lib/ab.sh"]}]}'
rc_is 0 "the SAME path in DIFFERENT waves is fine" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/a.sh"]},{"id":2,"wave":2,"owns":["lib/a.sh"]}]}' --wave 1
rc_is 2 "absent ownership is a caller error, not a pass" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":[]},{"id":2,"wave":1,"owns":["lib/b.sh"]}]}'
out_has "wave_paths_missing" "missing ownership is named differently from an overlap"
rc_is 2 "a task duplicating its OWN path is an error" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/a.sh","lib/a.sh"]},{"id":2,"wave":1,"owns":["lib/b.sh"]}]}'
rc_is 2 "malformed JSON is an error"  -- bash "$LIB" wave-disjoint --tasks 'not json at all'
rc_is 0 "a one-task wave cannot collide" -- bash "$LIB" wave-disjoint \
  --tasks '{"tasks":[{"id":1,"wave":1,"owns":["lib/a.sh"]}]}'

echo "== R8: stage-commit (controller-only git, explicit paths) =="
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email tester@example.invalid
git -C "$REPO" config user.name "Turbox Tester"
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -qm "chore: seed"

mkdir -p "$REPO/lib"
printf 'a\n' > "$REPO/lib/a.sh"
printf 'b\n' > "$REPO/lib/b.sh"

rc_is 3 "-A REFUSED"          -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path "-A"
out_has "stage_everything_refused" "the -A refusal is named"
rc_is 3 "--all REFUSED"       -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path "--all"
rc_is 3 "'.' pathspec REFUSED" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path "."
rc_is 3 "':/' pathspec REFUSED" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path ":/"
rc_is 3 "an absolute path REFUSED" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path "/etc/hosts"
rc_is 3 "a ../ escape REFUSED" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x" --path "../outside.sh"
rc_is 2 "no paths at all is an error" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: x"
rc_is 2 "a missing worktree is an error" -- bash "$LIB" stage-commit --worktree "$TMP/nope" --message "feat: x" --path lib/a.sh

# The positive control: the boundary is only meaningful if the allowed form
# actually commits, and commits ONLY what it was given. lib/b.sh is sitting
# untracked in the same tree the whole time.
rc_is 0 "commits exactly the given path" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: add a" --path "lib/a.sh"
if git -C "$REPO" ls-files --error-unmatch lib/a.sh >/dev/null 2>&1; then ok "lib/a.sh is tracked"; else bad "lib/a.sh was not committed"; fi
if git -C "$REPO" ls-files --error-unmatch lib/b.sh >/dev/null 2>&1; then
  bad "lib/b.sh leaked into the commit — the explicit-path boundary does not hold"
else
  ok "the untracked sibling did NOT leak into the commit"
fi
rc_is 3 "re-committing an unchanged path is refused" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: again" --path "lib/a.sh"
out_has "nothing_staged" "an empty commit is named, not silently made"

printf 'lib/b.sh\n' > "$TMP/paths.txt"
rc_is 0 "--paths-file stages the listed paths" -- bash "$LIB" stage-commit --worktree "$REPO" --message "feat: add b" --paths-file "$TMP/paths.txt"
if git -C "$REPO" ls-files --error-unmatch lib/b.sh >/dev/null 2>&1; then ok "lib/b.sh committed via --paths-file"; else bad "--paths-file did not commit lib/b.sh"; fi

echo "== R9: worktree-add =="
WT_OUT="$(cd "$REPO" && bash "$LIB" worktree-add --root "$TMP/wt" --issue 355 --branch turbox-issue-355 2>/dev/null)"
if [ -d "$WT_OUT" ]; then ok "cuts the worktree and prints its path"; else bad "worktree not created at '$WT_OUT'"; fi
case "$WT_OUT" in */issue-355) ok "the path is derived from the issue number" ;; *) bad "unexpected worktree path: $WT_OUT" ;; esac
WT_AGAIN="$(cd "$REPO" && bash "$LIB" worktree-add --root "$TMP/wt" --issue 355 --branch turbox-issue-355 2>/dev/null)"
if [ "$WT_AGAIN" = "$WT_OUT" ]; then ok "re-entrant: an existing checkout is reported, not duplicated"; else bad "re-entry produced a different path: $WT_AGAIN"; fi
rc_is 2 "a non-numeric issue is an error" -- bash "$LIB" worktree-add --root "$TMP/wt" --issue abc --branch b

echo "== R10: audit =="
rc_is 0 "writes an event" -- bash "$LIB" audit --run-dir "$TMP/run" --event wave_paths_overlap --data '{"issue":355,"wave":1}'
rc_is 0 "writes a second event" -- bash "$LIB" audit --run-dir "$TMP/run" --event implement_budget_exhausted --data '{"issue":356}'
AUDIT="$TMP/run/turbox-audit.jsonl"
if [ -r "$AUDIT" ]; then ok "the audit log exists"; else bad "no audit log at $AUDIT"; fi
if [ "$(wc -l < "$AUDIT" | tr -d ' ')" = "2" ]; then ok "one line per event (append, never truncate)"; else bad "expected 2 audit lines, got $(wc -l < "$AUDIT")"; fi
if grep -q '"event":"wave_paths_overlap"' "$AUDIT"; then ok "the event name is recorded"; else bad "event name missing from the audit line"; fi
rc_is 0 "malformed data does not drop the event" -- bash "$LIB" audit --run-dir "$TMP/run" --event odd --data 'not-json'
if grep -q '"raw":"not-json"' "$AUDIT"; then ok "unparseable data is preserved verbatim, not discarded"; else bad "unparseable audit data was dropped"; fi

echo "== R11: launcher --standard guards (refuse before any claim) =="
rc_is 1 "--standard + --backend=background REFUSED" -- \
  bash "$LAUNCHER" --auto-mode=1 --turbo --standard -- 355 --backend=background
out_has "mutually exclusive" "the refusal explains why"
out_has "no claims written" "the refusal states that nothing was claimed"
rc_is 1 "--standard + UBERDEV_DISPATCH_BACKEND REFUSED" -- \
  env UBERDEV_DISPATCH_BACKEND=wezterm bash "$LAUNCHER" --auto-mode=1 --turbo --standard -- 355
out_has "UBERDEV_DISPATCH_BACKEND=wezterm" "the env refusal names the variable it saw"
rc_is 64 "an unknown launcher option still exits 64" -- \
  bash "$LAUNCHER" --auto-mode=1 --turbo --nonsense -- 355
out_has "--standard" "the usage error advertises --standard"

echo "== R12: the TURBOX_PLAN envelope composes from the SHIPPED bytes =="
# The launcher's plan composer only runs after a live `gh` round-trip and a
# claim write, so no fixture can reach it end-to-end. Extract the python
# program from the launcher VERBATIM and run it on sample argv instead — a
# hand-copied twin would pass while the shipped one was broken, which is the
# disjoint-predicate failure this suite exists to avoid.
awk "
  /TURBOX_PLAN_JSON=\"\\\$\(python3 -I -B -c '/ { inb=1; next }
  inb && /^' / { inb=0 }
  inb { print }
" "$LAUNCHER" > "$TMP/composer.py"
composer_lines="$(wc -l < "$TMP/composer.py" | tr -d ' ')"
if [ "${composer_lines:-0}" -ge 10 ]; then
  ok "extracted the composer from the launcher ($composer_lines lines)"
else
  bad "composer extraction produced $composer_lines lines — the block moved or was renamed"
fi

rc_is 0 "the composer runs on sample argv" -- python3 -I -B "$TMP/composer.py" \
  /run/solve-fleet-manifest.json "355,356,357" 3 1 3 /run \
  /repo /plugin owner/repo main 24 600 3
ENVELOPE="$LAST_OUT"

if printf '%s' "$ENVELOPE" | python3 -c '
import json,sys
d=json.load(sys.stdin)
expected={"v":1,"lane":"turbox-standard","issueCount":3,"riskIssueCount":1,
          "concurrency":3,"worktreeRootAbs":"/run/worktrees",
          "branchPrefix":"worktree-turbox-issue-","implementBudget":24,
          "maxAgents":600,"fixRounds":3,"autoMode":True,"baseBranch":"main",
          "issues":"355,356,357"}
required=["manifestPathAbs","runDirAbs","repoRootAbs","pluginRootAbs","repoSlug"]
bad=[k for k,v in expected.items() if d.get(k)!=v]
missing=[k for k in required if not d.get(k)]
if bad or missing:
    print("mismatched:",bad,"missing:",missing,file=sys.stderr); sys.exit(1)
# Types matter to the consumer: a string "true" is not a bool, and a string
# "3" is not a wave size. json.dumps of the wrong type would still look fine.
if not isinstance(d["autoMode"],bool): print("autoMode is not a bool",file=sys.stderr); sys.exit(1)
for k in ("issueCount","riskIssueCount","concurrency","implementBudget","maxAgents","fixRounds"):
    if not isinstance(d[k],int) or isinstance(d[k],bool):
        print(f"{k} is not an int",file=sys.stderr); sys.exit(1)
' 2>/dev/null; then
  ok "every envelope key is present, correct, and correctly typed"
else
  bad "envelope keys/types wrong: $(printf '%s' "$ENVELOPE" | head -c 300)"
fi

# The branch prefix must differ from the Workflow lane's, or the two lanes
# collide on branch names for the same issue.
case "$ENVELOPE" in
  *worktree-solve-issue-*) bad "turbox reuses the Workflow lane's branch prefix — the lanes would collide" ;;
  *worktree-turbox-issue-*) ok "turbox uses its own branch prefix (no collision with /turbo)" ;;
  *) bad "no recognisable branch prefix in the envelope" ;;
esac

echo "== R13: the issue-body writer refuses a bad cap and truncates by BYTES =="
# Extracted VERBATIM from the launcher, like R12 -- a hand-copied twin would
# pass while the shipped one was broken.
#
# Every row here is a bug that shipped and was caught in review: cap=0 wrote a
# ZERO-BYTE requirements document and still exited 0, so every research lens and
# the spec writer would have received an empty issue; cap=-1 silently trimmed the
# body from the END; and character-slicing let a 4-byte-per-char body reach 4x
# the byte ceiling the comment promises downstream.
awk '
  /^root,target,cap_raw,raw=sys.argv\[1:5\]/ { inb=1; print "import json,os,stat,sys"; print; next }
  inb && /^'"'"' / { inb=0 }
  inb { print }
' "$LAUNCHER" > "$TMP/writer.py"
writer_lines="$(wc -l < "$TMP/writer.py" | tr -d ' ')"
if [ "${writer_lines:-0}" -ge 20 ]; then
  ok "extracted the issue-body writer from the launcher ($writer_lines lines)"
else
  bad "writer extraction produced $writer_lines lines -- the block moved or was renamed"
fi

# The launcher hands python an already-realpath-derived UBERDEV_TMPDIR, so the
# fixture must too or the containment guard false-trips on macOS /var.
WRITER_ROOT="$(cd "$TMP" && pwd -P)"
WRITER_RAW='{"number":619,"title":"t","labels":[],"body":"REAL REQUIREMENTS THAT MUST REACH THE AGENTS"}'

rc_is 0 "a valid cap writes the body" -- python3 -I -B "$TMP/writer.py" \
  "$WRITER_ROOT" "$WRITER_ROOT/ib-ok.md" 65536 "$WRITER_RAW"
if [ -s "$WRITER_ROOT/ib-ok.md" ]; then ok "the artifact is non-empty"; else bad "artifact empty on a valid cap"; fi
# GNU FIRST, then BSD. `stat -f` on GNU coreutils is --file-system: it SUCCEEDS
# and prints filesystem info, so a `-f || -c` chain never reaches the fallback
# and compares that output to a mode. This fixture shipped that way and reddened
# ubuntu while macOS and Windows passed. Int-validate too, so no future
# succeeds-but-wrong probe can masquerade as a mode.
ib_mode="$(stat -c '%a' "$WRITER_ROOT/ib-ok.md" 2>/dev/null || stat -f '%Lp' "$WRITER_ROOT/ib-ok.md" 2>/dev/null)"
case "$ib_mode" in ''|*[!0-7]*) ib_mode="unreadable" ;; esac
if [ "$ib_mode" = "600" ]; then ok "the artifact is 0600"; else bad "artifact mode is '$ib_mode', not 600"; fi

rc_is 2 "cap=0 REFUSED (was a zero-byte requirements doc)" -- python3 -I -B "$TMP/writer.py" \
  "$WRITER_ROOT" "$WRITER_ROOT/ib-zero.md" 0 "$WRITER_RAW"
out_has "cap must be >= 1" "the refusal says why"
if [ -e "$WRITER_ROOT/ib-zero.md" ]; then bad "a refused cap still created a file"; else ok "no file is left behind on refusal"; fi

rc_is 2 "cap=-1 REFUSED (was an end-trim)" -- python3 -I -B "$TMP/writer.py" \
  "$WRITER_ROOT" "$WRITER_ROOT/ib-neg.md" -1 "$WRITER_RAW"
rc_is 2 "a non-numeric cap REFUSED" -- python3 -I -B "$TMP/writer.py" \
  "$WRITER_ROOT" "$WRITER_ROOT/ib-abc.md" abc "$WRITER_RAW"
out_has "not an integer" "the non-numeric refusal is distinguishable"

# Byte truncation, on a body where characters and bytes differ 4x.
EMOJI_RAW="$(python3 -c 'import json;print(json.dumps({"number":1,"title":"t","labels":[],"body":"\U0001F642"*100}))')"
rc_is 0 "a multi-byte body writes" -- python3 -I -B "$TMP/writer.py" \
  "$WRITER_ROOT" "$WRITER_ROOT/ib-emoji.md" 200 "$EMOJI_RAW"
emoji_bytes="$(wc -c < "$WRITER_ROOT/ib-emoji.md" | tr -d ' ')"
if [ "${emoji_bytes:-0}" -le 200 ]; then
  ok "truncated by BYTES, not characters ($emoji_bytes <= 200)"
else
  bad "byte cap exceeded: $emoji_bytes > 200 -- slicing characters again?"
fi
if python3 -c "open('$WRITER_ROOT/ib-emoji.md','rb').read().decode('utf-8')" 2>/dev/null; then
  ok "no partial multi-byte sequence at the tail"
else
  bad "the truncation split a multi-byte character"
fi

echo
echo "== Summary =="
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
uberdev_test_exit_floor_reached
echo "turbox-fleet-runtime: $PASS checks passed"

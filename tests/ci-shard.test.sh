#!/usr/bin/env bash
# tests/ci-shard.test.sh — BEHAVIOUR gates for the CI shard pack.
#
# tests/ci-wiring.test.sh W13 already proves the property that matters most —
# the union of a job's shards is that job's whole list — by running these scripts
# against the live workflow. This file covers what W13 cannot see from there: the
# refusal paths, and the determinism the union property silently depends on.
#
# Determinism is load-bearing and easy to lose. Every shard computes the pack
# independently, in its own runner, and they agree only because the same inputs
# produce the same answer. A pack that depended on stdin order, or on `set`
# iteration order, would still pass W13 (which drives every shard from one
# machine, in one order) and would drop tests in CI, where each shard reads the
# workflow itself and nothing forces the list to arrive identically. So the
# order-independence row here is not redundant with W13; it is the assumption
# W13 rests on.

set -u

PASS=0; FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="$REPO_ROOT/tests/ci-shard-plan.py"
FIXTURES="$REPO_ROOT/tests/ci-job-fixtures.sh"
ENVSH="$REPO_ROOT/tests/ci-shard-env.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

for f in "$PLAN" "$FIXTURES" "$ENVSH" "$WORKFLOW"; do
  [ -r "$f" ] || { echo "FATAL: required file missing or unreadable: $f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required by ${0##*/}" >&2; exit 2; }

ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A corpus with a deliberately skewed cost distribution — one fixture worth more
# than all the others combined. A pack that ignored weights would put it with
# others and the balance row below would catch it.
cat >"$WORK/weights.tsv" <<'EOF'
# seconds	fixture
200	heavy.test.sh
10	m1.test.sh
10	m2.test.sh
10	m3.test.sh
10	m4.test.sh
EOF
printf '%s\n' heavy.test.sh m1.test.sh m2.test.sh m3.test.sh m4.test.sh unweighted.test.sh >"$WORK/corpus"

plan_shard() { # plan_shard N K -> that shard's fixtures on stdout
  python3 -I -B "$PLAN" --shards "$1" --shard "$2" --weights "$WORK/weights.tsv" <"$WORK/corpus"
}

# ONE reader per shape of the workflow, shared by every section below.
#
# The job anchor, the stop-at-the-next-job rule and the ten-space de-indent the
# `run: |` block scalar carries are ONE contract about the workflow's YAML, and
# a second transcription of it is the "one contract, N uncompared copies" class
# tests/ci-wiring.test.sh W12.4 exists to refuse: a fix to the shape lands on
# one copy, leaves the other narrow, and every row built on the narrow one then
# passes over a truncated block instead of failing.

# run_block_of <job-key> <marker> -> that job's `run: |` body, de-indented.
#   marker NON-EMPTY  every `run_one` line is replaced by ONE marker line, so
#                     synthetic invocations can be spliced in at that point
#   marker EMPTY      the block exactly as the workflow ships it, invocations
#                     included
run_block_of() {
  awk -v JOB="$1" -v MARK="$2" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+run:[[:space:]]*[|][[:space:]]*$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { in_run = 0; next }
      sub(/^          /, "")
      if (MARK != "" && $0 ~ /^run_one /) { if (!ins) { print MARK; ins = 1 } next }
      print
    }
  ' "$WORKFLOW"
}

# matrix_shards_of <job-key> -> how many shards that job's matrix declares, or
# the empty string. Read out of the job's own `shard: [1, 2, ...]` row.
matrix_shards_of() {
  awk -v JOB="$1" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+shard:[[:space:]]*\[/ { print gsub(/,/, ",") + 1; exit }
  ' "$WORKFLOW"
}

# DECLARE, THEN COMPARE — the order tests/ci-wiring.test.sh W13.0 uses, and the
# reason these are constants rather than literals scattered through the rows.
# Every row below plans for these counts; S10 checks each one against the job's
# OWN matrix before any row is allowed to trust it. Written as literals in each
# row instead, a job resharded in the workflow would leave those rows planning
# for a count that is no longer shipped — and their properties still hold for
# that count, so they would stay green over a configuration nobody runs.
LINUX_SHARDS=6
MACOS_SHARDS=2
WINDOWS_SHARDS=6

echo "== S1: the pack is complete and disjoint =="
: >"$WORK/union"
S1_RC=0
for k in 1 2 3; do
  plan_shard 3 "$k" >>"$WORK/union" || S1_RC=1
done
[ "$S1_RC" -eq 0 ] && ok "S1: every shard planned without error" \
  || bad "S1: a shard refused to plan"
LC_ALL=C sort "$WORK/corpus" >"$WORK/corpus.sorted"
LC_ALL=C sort "$WORK/union" >"$WORK/union.sorted"
if cmp -s "$WORK/corpus.sorted" "$WORK/union.sorted"; then
  ok "S1: the union of 3 shards is the corpus, each fixture exactly once"
else
  bad "S1: union != corpus — $(diff "$WORK/corpus.sorted" "$WORK/union.sorted" | tr '\n' ' ')"
fi

echo "== S2: the pack is weight-aware, not round-robin =="
# Round-robin over a 6-item corpus would put heavy.test.sh with two others. LPT
# gives it a shard to itself, because nothing else comes close to 200s.
S2_HEAVY="$(for k in 1 2 3; do plan_shard 3 "$k" | grep -q '^heavy\.test\.sh$' && plan_shard 3 "$k" | wc -l; done | tr -d ' ')"
if [ "$S2_HEAVY" = "1" ]; then
  ok "S2: the 200s fixture is packed alone; the rest carry the remainder"
else
  bad "S2: the heavy fixture shares a shard with $((S2_HEAVY - 1)) other(s) — the pack is ignoring weights"
fi

echo "== S3: the pack does not depend on the order the list arrives in =="
# Each shard computes this independently, in its own runner. If the answer moved
# with stdin order the shards would disagree and tests would vanish between them.
LC_ALL=C sort -r "$WORK/corpus" >"$WORK/corpus.rev"
S3_DRIFT=''
for k in 1 2 3; do
  plan_shard 3 "$k" | LC_ALL=C sort >"$WORK/fwd.$k"
  python3 -I -B "$PLAN" --shards 3 --shard "$k" --weights "$WORK/weights.tsv" <"$WORK/corpus.rev" \
    | LC_ALL=C sort >"$WORK/rev.$k"
  cmp -s "$WORK/fwd.$k" "$WORK/rev.$k" || S3_DRIFT="$S3_DRIFT $k"
done
[ -z "$S3_DRIFT" ] && ok "S3: reversing stdin changes no shard's contents" \
  || bad "S3: shard(s)$S3_DRIFT changed when stdin was reordered"

echo "== S4: an unweighted fixture is packed, never dropped =="
# The weights file is a HINT. A fixture missing from it must still run, or a
# stale weights file silently stops testing whatever it forgot.
if grep -qx 'unweighted.test.sh' "$WORK/union.sorted"; then
  ok "S4: a fixture absent from the weights file still lands in a shard"
else
  bad "S4: an unweighted fixture was dropped from the pack"
fi

echo "== S5: every bad input is a refusal, never a partial plan =="
s5_refuses() { # s5_refuses <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >"$WORK/s5.out" 2>"$WORK/s5.err"; then
    bad "S5: $desc was ACCEPTED (stdout: $(head -c 80 "$WORK/s5.out"))"
  elif [ ! -s "$WORK/s5.err" ]; then
    bad "S5: $desc refused with no diagnostic"
  elif grep -q 'Traceback' "$WORK/s5.err"; then
    bad "S5: $desc refused with a traceback, not a message: $(head -1 "$WORK/s5.err")"
  else
    ok "S5: $desc refused — $(head -c 70 "$WORK/s5.err")"
  fi
}
printf 'a.test.sh\na.test.sh\n' >"$WORK/dup"
s5_refuses "a duplicate on stdin" \
  sh -c "python3 -I -B '$PLAN' --shards 2 --shard 1 <'$WORK/dup'"
s5_refuses "an empty stdin" \
  sh -c ": | python3 -I -B '$PLAN' --shards 2 --shard 1"
s5_refuses "a shard index past --shards" \
  sh -c "python3 -I -B '$PLAN' --shards 3 --shard 4 <'$WORK/corpus'"
s5_refuses "a zero shard index" \
  sh -c "python3 -I -B '$PLAN' --shards 3 --shard 0 <'$WORK/corpus'"
printf 'not-an-int\tx.test.sh\n' >"$WORK/badw"
s5_refuses "a non-integer weight" \
  sh -c "python3 -I -B '$PLAN' --shards 2 --shard 1 --weights '$WORK/badw' <'$WORK/corpus'"
printf 'oneField\n' >"$WORK/badw2"
s5_refuses "a weights row with no tab" \
  sh -c "python3 -I -B '$PLAN' --shards 2 --shard 1 --weights '$WORK/badw2' <'$WORK/corpus'"
s5_refuses "an unknown job key" \
  sh -c "bash '$FIXTURES' no-such-job '$WORKFLOW'"
s5_refuses "an unreadable workflow" \
  sh -c "bash '$FIXTURES' shape-checks '$WORK/does-not-exist.yml'"
s5_refuses "ci-shard-env with the wrong argument count" \
  sh -c "bash '$ENVSH' shape-checks 6"
s5_refuses "ci-shard-env with a non-numeric shard" \
  sh -c "bash '$ENVSH' shape-checks 6 two"

echo "== S6: ci-shard-env emits exactly the three variables the harness reads =="
if bash "$ENVSH" supervision-smoke-macos "$MACOS_SHARDS" 1 >"$WORK/env.out" 2>"$WORK/env.err"; then
  S6_KEYS="$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$WORK/env.out" | tr '\n' ',')"
  [ "$S6_KEYS" = "UBERDEV_SHARD_PLAN,UBERDEV_SHARD,UBERDEV_SHARDS," ] \
    && ok "S6: the three GITHUB_ENV keys are present and in order" \
    || bad "S6: wrong keys emitted: $S6_KEYS"
  # One line per key. A raw newline inside a value would silently truncate the
  # variable at the `>> $GITHUB_ENV` boundary and hand the harness a short plan.
  [ "$(wc -l <"$WORK/env.out" | tr -d ' ')" = "3" ] \
    && ok "S6: exactly three lines, so no value carries an embedded newline" \
    || bad "S6: expected 3 lines, got $(wc -l <"$WORK/env.out" | tr -d ' ')"
  # The diagnostics belong on stderr, where they cannot corrupt GITHUB_ENV.
  grep -q 'slowest shard' "$WORK/env.err" \
    && ok "S6: the balance report goes to stderr, not into GITHUB_ENV" \
    || bad "S6: no balance report on stderr"
else
  bad "S6: ci-shard-env refused on a valid request: $(cat "$WORK/env.err")"
fi

echo "== S7: the harness's membership test matches whole names only =="
# The harness keys on `case " $PLAN " in *" $name "*`. Without the sentinel
# spaces, a plan containing `goal.test.sh` would also match `goal-state.test.sh`
# — a shard would run a fixture it was not assigned and another would skip it.
S7_PLAN="goal.test.sh merge.test.sh"
s7_member() { case " $S7_PLAN " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
s7_member goal.test.sh && ok "S7: an assigned fixture matches" || bad "S7: an assigned fixture did not match"
s7_member goal-state.test.sh && bad "S7: a LONGER name matched a shorter plan entry" \
  || ok "S7: a longer name sharing a prefix does not match"
s7_member oal.test.sh && bad "S7: a SUFFIX of a plan entry matched" \
  || ok "S7: a suffix of a plan entry does not match"

echo "== S8: the WORKFLOW'S OWN run_one routes by the plan =="
# THE ROW THAT MATTERS MOST, and the one S7 above cannot stand in for. S7 tests
# the membership rule against a plain string; run_one gets an argv. The first
# version of this harness used `${*##*/}`, which applies the strip to EACH
# positional and then joins -- `bash tests/x.test.sh` became `bash x.test.sh`,
# matched no plan entry, skipped every fixture, and reported a GREEN job that had
# run nothing. Only driving the real function with a real argv can see that.
#
# The harness is carved out of the LIVE workflow, never transcribed: a copy here
# would keep agreeing with itself while CI drifted away from it.
#
# SPLICED, NOT APPENDED. The extracted block ends with the job's failure tail,
# which exits non-zero when anything raised `fail`. Appending the synthetic
# invocations AFTER that tail means a tail that can fail runs BEFORE them and
# the script exits having invoked nothing. tests/ci-wiring.test.sh W12.3
# already carves its fixtures in at a marker for the same reason; this is that
# shape, so the rows below keep measuring the harness rather than the position
# they happened to be pasted at.
S8_MARK='@@S8-INVOCATIONS@@'
s8_script() { # s8_script <body-file> <invocations-file> <out-file>
  # FAILS LOUDLY, never splices into nothing. A marker that moved, or an empty
  # invocation file, would write a harness that invokes NOTHING -- and every row
  # below would then go red for a reason that has nothing to do with routing.
  # Same doctrine as the FATAL preflight at the top of this file: a scaffold
  # that could not be built must say so, not hand the rows a vacuous script.
  [ -s "$2" ] || { echo "FATAL: ${0##*/}: no invocations to splice from $2" >&2; exit 2; }
  # One statement per line, deliberately: `} close(INV);` on the same line as the
  # while-block's closing brace parses under BSD awk and is not worth betting on
  # under the gawk/mawk that run this file on ubuntu and Git Bash.
  awk -v MARK="$S8_MARK" -v INV="$2" '
    $0 == MARK {
      while ((getline line < INV) > 0) { print line; n++ }
      close(INV)
      spliced++
      next
    }
    { print }
    END { if (spliced != 1 || n < 1) exit 3 }
  ' "$1" >"$3" \
    || { echo "FATAL: ${0##*/}: $S8_MARK did not splice exactly one non-empty invocation set into $1" >&2; exit 2; }
}
S8_BODY="$(run_block_of shape-checks "$S8_MARK")"
if [ -z "$S8_BODY" ]; then
  bad "S8: the ubuntu harness extracted empty — the job key or the block shape moved"
else
  ok "S8: the ubuntu harness extracted non-empty"
  printf '%s\n' "$S8_BODY" >"$WORK/s8.body"
  {
    # Two fixtures, one in the plan and one not, invoked exactly the way the
    # workflow invokes them -- including the zsh spelling, which is the case that
    # makes keying on the FIRST argument wrong.
    printf 'run_one bash tests/in-plan.test.sh\n'
    printf 'run_one zsh tests/zsh-in-plan.test.sh\n'
    printf 'run_one bash tests/not-in-plan.test.sh\n'
    # THE THREE SHAPES THE WINDOWS JOB ACTUALLY USES, and the reason the key is a
    # scan rather than a positional. A trailing flag makes the LAST argument the
    # flag; an `env VAR=x` prefix makes the FIRST argument `env`; and one fixture
    # is python, not shell. Keying on the last argument silently dropped the two
    # flagged rows from every shard — they were wired, planned, and never run.
    printf 'run_one bash tests/flagged.test.sh --artifact-publication-only\n'
    printf 'run_one env MSYSTEM=MSYS bash tests/env-prefixed.test.sh\n'
    printf 'run_one python -I -B tests/pyfixture.test.py\n'
  } >"$WORK/s8.inv"
  s8_script "$WORK/s8.body" "$WORK/s8.inv" "$WORK/s8.sh"
  S8_OUT="$(
    UBERDEV_SHARD_PLAN="in-plan.test.sh zsh-in-plan.test.sh flagged.test.sh env-prefixed.test.sh pyfixture.test.py" \
    UBERDEV_SHARD=1 UBERDEV_SHARDS=2 \
    bash -e "$WORK/s8.sh" 2>&1 || true
  )"
  case "$S8_OUT" in
    *"RUN  bash tests/in-plan.test.sh"*) ok "S8: a planned bash fixture RUNS" ;;
    *) bad "S8: a planned bash fixture was skipped — every shard would run nothing" ;;
  esac
  case "$S8_OUT" in
    *"RUN  zsh tests/zsh-in-plan.test.sh"*) ok "S8: a planned zsh fixture RUNS (the key is not the interpreter)" ;;
    *) bad "S8: a planned zsh fixture was skipped — the key is reading the interpreter" ;;
  esac
  case "$S8_OUT" in
    *"SKIP bash tests/not-in-plan.test.sh"*) ok "S8: an unplanned fixture is SKIPPED" ;;
    *) bad "S8: an unplanned fixture was not skipped — the shards would each run everything" ;;
  esac

  # Polarity: with no plan the SAME harness must run every row. This is the
  # standalone case ci-wiring W12.3 depends on, asserted here at the routing seam.
  #
  # THE UNSET IS EXPLICIT, and it has to be. This fixture runs INSIDE a shard,
  # where UBERDEV_SHARD_PLAN is exported by the planning step -- so a subshell
  # that merely declines to set it inherits the real plan, which holds none of
  # the synthetic names below and skips all six. It passed locally for the only
  # reason such a row ever does: the variable happened not to exist in the
  # author's shell.
  S8_ALL="$(
    unset UBERDEV_SHARD_PLAN UBERDEV_SHARD UBERDEV_SHARDS
    bash -e "$WORK/s8.sh" 2>&1 || true
  )"
  S8_N="$(printf '%s\n' "$S8_ALL" | grep -c '^--- RUN ')"
  [ "$S8_N" = "6" ] && ok "S8: with no plan set, all six run (the standalone case)" \
    || bad "S8: an unset plan ran $S8_N of 6 — the default is not fail-open"

  # S9 — the routing KEY, driven through the same extracted harness.
  #
  # These rows carry their own identifier and therefore their own header: printed
  # under S8's, twelve S9 rows would read as S8's and a row shipped as a
  # duplicate of its predecessor would have nothing to distinguish it, which is
  # the row-id ambiguity ci-wiring's own anti-vacuity row exists to refuse.
  echo "== S9: the routing key survives every argv shape the workflow uses =="
  case "$S8_OUT" in
    *"RUN  bash tests/flagged.test.sh --artifact-publication-only"*)
      ok "S9: a fixture with a TRAILING FLAG runs (the key is not the last argument)" ;;
    *) bad "S9: a flagged fixture was skipped — the two Windows rows would vanish from every shard" ;;
  esac
  case "$S8_OUT" in
    *"RUN  env MSYSTEM=MSYS bash tests/env-prefixed.test.sh"*)
      ok "S9: an env-PREFIXED fixture runs (the key is not the first argument either)" ;;
    *) bad "S9: an env-prefixed fixture was skipped" ;;
  esac
  case "$S8_OUT" in
    *"RUN  python -I -B tests/pyfixture.test.py"*)
      ok "S9: a .test.py fixture in the plan runs" ;;
    *) bad "S9: a .test.py fixture was skipped — it is wired but unplannable" ;;
  esac
  # THE ROW THAT MAKES THE ONE ABOVE MEAN SOMETHING. Asserting the .py RUNS is
  # satisfied either way: drop `.test.py` from the matcher and the key comes out
  # empty, the fail-open default takes over, and it runs -- in EVERY shard, six
  # times, silently. Only a .py held OUT of the plan can tell "routed" apart from
  # "fell through", and that mutation survived until this row existed.
  S9_PY="$(
    printf 'run_one python -I -B tests/pyfixture.test.py\n' >"$WORK/s9py.inv"
    s8_script "$WORK/s8.body" "$WORK/s9py.inv" "$WORK/s9py.sh"
    UBERDEV_SHARD_PLAN="in-plan.test.sh" UBERDEV_SHARD=1 UBERDEV_SHARDS=2 \
      bash -e "$WORK/s9py.sh" 2>&1 || true
  )"
  case "$S9_PY" in
    *"SKIP python -I -B tests/pyfixture.test.py"*)
      ok "S9: a .test.py OUTSIDE the plan is skipped — it is routed, not fail-open" ;;
    *) bad "S9: an unplanned .test.py ran anyway — it would run in every shard" ;;
  esac

  # And the sentinel spaces, driven through the REAL harness rather than S7's
  # local reimplementation of the rule. Without them `*"$name"*` is a plain
  # substring test, and the direction that breaks is the fixture being a
  # substring of the PLAN: with `long-plan.test.sh` planned, an unassigned
  # `plan.test.sh` matches and runs in a shard that was never given it -- while
  # the shard that WAS given it also runs it. S7 alone could not catch this; the
  # mutation survived until this row drove the harness itself.
  S9_SUB="$(
    printf 'run_one bash tests/plan.test.sh\n' >"$WORK/s9sub.inv"
    s8_script "$WORK/s8.body" "$WORK/s9sub.inv" "$WORK/s9sub.sh"
    UBERDEV_SHARD_PLAN="long-plan.test.sh" UBERDEV_SHARD=1 UBERDEV_SHARDS=2 \
      bash -e "$WORK/s9sub.sh" 2>&1 || true
  )"
  case "$S9_SUB" in
    *"SKIP bash tests/plan.test.sh"*)
      ok "S9: a name CONTAINED IN a plan entry is skipped — the sentinel spaces hold" ;;
    *) bad "S9: plan.test.sh matched the plan entry long-plan.test.sh — the match is a substring test" ;;
  esac
  # An argv with NO fixture path must fall through to RUN. This is exactly the
  # shape ci-wiring W12.3 executes (`run_one bash <tmpdir>/a.sh`), so a filter
  # that refused it would red a row about something else entirely.
  S8_SYN="$(
    printf 'run_one true /somewhere/else/a.sh\n' >"$WORK/s9.inv"
    s8_script "$WORK/s8.body" "$WORK/s9.inv" "$WORK/s9.sh"
    UBERDEV_SHARD_PLAN="in-plan.test.sh" UBERDEV_SHARD=1 UBERDEV_SHARDS=2 \
      bash -e "$WORK/s9.sh" 2>&1 || true
  )"
  case "$S8_SYN" in
    *"RUN  true /somewhere/else/a.sh"*)
      ok "S9: an argv naming no fixture runs — W12.3's synthetic fixtures survive the filter" ;;
    *) bad "S9: a non-fixture argv was skipped — ci-wiring W12.3 would red" ;;
  esac
fi

echo "== S10: every shard of every job runs its whole plan (aggregate) =="
# THE ROW ACCEPTANCE CRITERION 3 ASKS FOR, and the one S8 above structurally
# cannot be. S8 extracts the UBUNTU harness and drives it with a synthetic
# plan of this file's own making: it measures the routing RULE, and no plan it
# writes can carry a delimiter the runner introduced. This row replays each
# job's real argv against its real per-shard plan and compares the AGGREGATE
# run count to the job's wired fixture count. The denominator comes from
# tests/ci-job-fixtures.sh, which reads the run_one lines back out of the
# workflow -- a guard that re-derived the count the way the harness does would
# agree with the harness by construction and see nothing.
# The four interpreters the workflow's run_one lines use, stubbed so the
# replay costs nothing. `--- RUN` is echoed BEFORE the invocation, so the
# count is unaffected by the stub.
s10_runner() { # $1 = job key -> path to a replayable script
  {
    printf 'bash() { :; }\n'
    printf 'zsh() { :; }\n'
    printf 'python() { :; }\n'
    printf 'env() { shift; "$@"; }\n'
    run_block_of "$1" ''
  } >"$WORK/s10.$1.sh"
  printf '%s\n' "$WORK/s10.$1.sh"
}
s10_run_count() { # $1 = script, $2 = plan value, $3 = shard, $4 = shards
  UBERDEV_SHARD_PLAN="$2" UBERDEV_SHARD="$3" UBERDEV_SHARDS="$4" \
    bash -e "$1" 2>&1 | grep -c '^--- RUN '
}
while IFS= read -r s10_spec; do
  [ -n "$s10_spec" ] || continue
  s10_job="${s10_spec%%|*}"
  s10_shards="${s10_spec##*|}"
  # DECLARE, THEN COMPARE. The count above comes from this file's own constants;
  # nothing below may plan for it until the job's own matrix agrees. A job
  # resharded in the workflow reds here — and stops, rather than measuring a
  # shard count that is no longer shipped and calling the result green.
  s10_matrix="$(matrix_shards_of "$s10_job")"
  if [ "$s10_matrix" != "$s10_shards" ]; then
    bad "S10: $s10_job's matrix declares ${s10_matrix:-<none>} shard(s), this file plans for $s10_shards — reshard the constants at the top"
    continue
  fi
  # ONE extraction per job, not one per shard. The wired list is a pure function
  # of (job key, workflow file) and neither moves during the run, so re-deriving
  # it inside the shard loop bought a fresh process tree per shard and nothing
  # else. Both consumers below read the same capture.
  s10_fixtures="$(bash "$FIXTURES" "$s10_job")"
  s10_wired="$(printf '%s\n' "$s10_fixtures" | grep -c .)"
  s10_script="$(s10_runner "$s10_job")"
  s10_total=0
  s10_bad=''
  s10_k=1
  while [ "$s10_k" -le "$s10_shards" ]; do
    s10_plan="$(printf '%s\n' "$s10_fixtures" | python3 -I -B "$PLAN" --shards "$s10_shards" --shard "$s10_k")"
    s10_len="$(printf '%s\n' "$s10_plan" | grep -c .)"
    s10_flat="$(printf '%s' "$s10_plan" | tr '\n' ' ')"
    s10_run="$(s10_run_count "$s10_script" "$s10_flat" "$s10_k" "$s10_shards")"
    s10_total=$((s10_total + s10_run))
    [ "$s10_run" = "$s10_len" ] || s10_bad="$s10_bad ${s10_k}(ran=$s10_run,plan=$s10_len)"
    s10_k=$((s10_k + 1))
  done
  if [ -n "$s10_bad" ]; then
    bad "S10: $s10_job shard(s)$s10_bad ran fewer fixtures than they were planned"
  else
    ok "S10: every $s10_job shard ran its whole plan"
  fi
  if [ "$s10_total" = "$s10_wired" ]; then
    ok "S10: $s10_job shards executed $s10_total of $s10_wired wired fixtures (aggregate)"
  else
    bad "S10: $s10_job executed $s10_total of $s10_wired wired fixtures — $((s10_wired - s10_total)) never ran in ANY shard"
  fi
done <<S10_SPECS
shape-checks|$LINUX_SHARDS
supervision-smoke-macos|$MACOS_SHARDS
shape-checks-windows|$WINDOWS_SHARDS
S10_SPECS

echo "== S11: a CR-delimited plan cannot buy a green short run =="
# S11a is a statement about the PLATFORM and stays true forever: with the
# plan's entries CR-terminated and the last one's CR eaten at the file
# boundary, exactly one name is bounded by real spaces, so exactly one runs.
# S11b is the statement about THIS repo: the harness must refuse to call that
# a pass. Before the SHARD-COVERAGE tail exists, S11b is RED and S11a is not.
S11_JOB=shape-checks-windows
S11_SCRIPT="$(s10_runner "$S11_JOB")"
S11_VALUE="$(bash "$REPO_ROOT/tests/ci-shard-diagnose.sh" crlf-plan "$S11_JOB" "$WINDOWS_SHARDS" 2)"
S11_LEN="$(bash "$FIXTURES" "$S11_JOB" | python3 -I -B "$PLAN" --shards "$WINDOWS_SHARDS" --shard 2 | grep -c .)"
S11_OUT="$(UBERDEV_SHARD_PLAN="$S11_VALUE" UBERDEV_SHARD=2 UBERDEV_SHARDS="$WINDOWS_SHARDS" bash -e "$S11_SCRIPT" 2>&1)"
S11_RC=$?
S11_RUN="$(printf '%s\n' "$S11_OUT" | grep -c '^--- RUN ')"
# The `-n` is not decoration. An EMPTY value is read by the harness as an unset
# plan and fails OPEN, so on a one-fixture shard "ran 1" would be indistinguish-
# able from the CR signature -- the row would agree with a dead crlf-plan verb.
if [ -n "$S11_VALUE" ] && [ "$S11_LEN" -gt 1 ] && [ "$S11_RUN" = "1" ]; then
  ok "S11a: the CR-delimited plan runs 1 of $S11_LEN — the #753 signature reproduces"
else
  bad "S11a: expected 1 of $S11_LEN under the CR model, got $S11_RUN — the byte model no longer matches the harness"
fi
if [ "$S11_RC" -ne 0 ]; then
  ok "S11b: the harness exits non-zero rather than reporting a short run as a pass"
else
  bad "S11b: the harness ran $S11_RUN of $S11_LEN fixtures and exited 0 — a shard can still report green over a skipped suite"
fi
case "$S11_OUT" in
  *SHARD-COVERAGE*) ok "S11b: the log names the shortfall, so the cause is readable from the job log" ;;
  *) bad "S11b: nothing in the output names the coverage shortfall" ;;
esac

echo "== S12: the aggregate comparison is not vacuous =="
# S10 asserts a number equals a number. Both come out right on a healthy tree,
# so on its own S10 cannot say whether it would notice a wrong one. Dropping
# one entry from a shard's plan is the smallest defect it must catch.
S12_JOB=shape-checks-windows
S12_SCRIPT="$(s10_runner "$S12_JOB")"
S12_FULL="$(bash "$FIXTURES" "$S12_JOB" | python3 -I -B "$PLAN" --shards "$WINDOWS_SHARDS" --shard 3)"
S12_LEN="$(printf '%s\n' "$S12_FULL" | grep -c .)"
S12_SHORT="$(printf '%s\n' "$S12_FULL" | sed '$d' | tr '\n' ' ')"
S12_RUN="$(s10_run_count "$S12_SCRIPT" "$S12_SHORT" 3 "$WINDOWS_SHARDS")"
if [ "$S12_RUN" = "$((S12_LEN - 1))" ] && [ "$S12_RUN" != "$S12_LEN" ]; then
  ok "S12: a plan one fixture short runs one fixture fewer — S10's comparison can see it"
else
  bad "S12: a plan of $((S12_LEN - 1)) ran $S12_RUN against a full plan of $S12_LEN — the count is not tracking the plan"
fi

echo "== S13: the producer refuses a pack its packer delivered with CRs =="
# Driven through the REAL tests/ci-shard-env.sh with a CR-reapplying python3
# underneath it -- the Windows condition, reproduced. A producer that strips
# the CR would pass a weaker version of this row while leaving the packer
# wrong; the assertion is therefore on the REFUSAL, not on clean output.
#
# The shim `simulate` uses re-terminates the packer's lines at the PROCESS
# BOUNDARY, so this row keeps reproducing the defect after the packer pins its
# own stdout -- see the TWO SHIMS note in tests/ci-shard-diagnose.sh. A row fed
# only through the producer it is meant to test stops testing it the moment
# that producer is fixed.
S13_OUT="$(bash "$REPO_ROOT/tests/ci-shard-diagnose.sh" simulate shape-checks-windows "$WINDOWS_SHARDS" 2 2>"$WORK/s13.err")"
S13_RC=$?
if [ "$S13_RC" -ne 0 ]; then
  ok "S13: ci-shard-env.sh refuses a CR-bearing pack (rc=$S13_RC)"
else
  bad "S13: ci-shard-env.sh accepted a CR-bearing pack and emitted a plan — the shard filter will match only its last entry"
fi
case "$S13_OUT" in
  *UBERDEV_SHARD_PLAN=*) bad "S13: a plan line was emitted despite the CR" ;;
  *) ok "S13: no UBERDEV_SHARD_PLAN line reaches GITHUB_ENV when the pack is tainted" ;;
esac
if grep -q 'CR' "$WORK/s13.err"; then
  ok "S13: the refusal names the CR, so the planning step's failure is self-explaining"
else
  bad "S13: the refusal diagnostic does not mention a CR: $(head -c 100 "$WORK/s13.err" | tr '\n' ' ')"
fi

echo "== S14: the packer pins its own stdout to LF =="
# The falsifiable form of a Windows-only property. The REAL packer runs with
# its stdout wrapped in a CRLF-translating text stream -- the same wrapper
# python.exe installs by default -- and must still emit LF. A packer that
# leaves the newline to the host emits CRLF here, on every host.
#
# THE BYTES ARE CAPTURED BEFORE THEY ARE JUDGED, and the producer's status is
# read off the producer rather than off `od`. Piping straight into `od | tr`
# would hand $? the status of `tr`, so a packer that died would arrive as an
# empty haystack containing no CR -- and the row would report PASS for the one
# reason that is not a pass.
bash "$REPO_ROOT/tests/ci-shard-diagnose.sh" packer-bytes shape-checks-windows "$WINDOWS_SHARDS" 2 \
  >"$WORK/s14.bytes" 2>"$WORK/s14.err"
S14_RC=$?
if [ "$S14_RC" -ne 0 ] || [ ! -s "$WORK/s14.bytes" ]; then
  bad "S14: packer-bytes produced nothing to judge (rc=$S14_RC) — $(head -c 100 "$WORK/s14.err")"
else
  case "$(od -c "$WORK/s14.bytes" | tr -s ' ')" in
    *'\r'*) bad "S14: ci-shard-plan.py emitted a CR through a CRLF-translating stdout — the plan reaches the harness CR-delimited" ;;
    *) ok "S14: ci-shard-plan.py emits LF even when the host's stdout translates newlines" ;;
  esac
fi

echo "== S15: every sharded job dumps its plan bytes before it runs =="
# The od -c dump is the evidence this issue turned on: with it the next
# delimiter defect is one grep away in the job log, and without it the next one
# is invisible exactly as this one was. The step is a single line of YAML and
# nothing else in this suite would notice it going away -- S10 replays the
# harness, not the job's step list, so a job that had lost its dump would still
# pass every row above. The expected shard count is read out of the job's own
# matrix, so a job resharded from 6 to 8 fails here rather than quietly dumping
# a plan for a shard count it no longer has.
#
# THE NEEDLE IS QUALIFIED, and that is not fussiness. `ci-shard-diagnose.sh
# dump` occurs TWICE inside each of these jobs -- once as the step, once inside
# the SHARD-COVERAGE tail's own "Dump the plan bytes with:" hint -- so a row
# keyed on the bare string is satisfied by the prose that merely mentions the
# step and stays green after the step itself is deleted. Every needle below
# carries the `run:` prefix, which only the step has.
S15_PLAN_RE='^[[:space:]]+run:[[:space:]]+bash tests/ci-shard-env[.]sh '
S15_DUMP_RE='^[[:space:]]+run:[[:space:]]+bash tests/ci-shard-diagnose[.]sh dump '
S15_HARNESS_RE='^[[:space:]]+run_one '
s15_dump_line_of() { # $1 = job key -> that job's dump step, leading indent stripped
  # The trailing CR is stripped because this fixture runs on windows-latest too,
  # and /.gitattributes:44-51 deliberately scopes `eol=lf` to
  # plugins/uberdev/hooks/** -- nothing pins the checkout of this workflow, so
  # whether its lines arrive LF or CRLF on that runner is the runner's
  # core.autocrlf, not this repo's decision. Only the exact-equality row needs
  # it: the two helpers below count commas and report line numbers, neither of
  # which a line terminator can move. This normalises a CHECKOUT artifact and
  # weakens nothing -- the CR that this issue is about is in the plan the packer
  # emits at runtime, and S13/S14 are what hold that.
  awk -v JOB="$1" -v PAT="$S15_DUMP_RE" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && $0 ~ PAT { sub(/^[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }
  ' "$WORKFLOW"
}
s15_lineno_of() { # $1 = job key, $2 = ERE -> line number of its first match inside the job
  awk -v JOB="$1" -v PAT="$2" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && $0 ~ PAT { print NR; exit }
  ' "$WORKFLOW"
}
for s15_job in shape-checks supervision-smoke-macos shape-checks-windows; do
  s15_shards="$(matrix_shards_of "$s15_job")"
  s15_line="$(s15_dump_line_of "$s15_job")"
  s15_want="run: bash tests/ci-shard-diagnose.sh dump $s15_job $s15_shards \"\${{ matrix.shard }}\""
  if [ -z "$s15_shards" ]; then
    bad "S15: $s15_job declares no shard matrix — the expected shard count cannot be read"
  elif [ "$s15_line" = "$s15_want" ]; then
    ok "S15: $s15_job dumps its plan bytes for all $s15_shards shards"
  else
    bad "S15: $s15_job's dump step is missing or drifted — want [$s15_want], got [$s15_line]"
  fi
  # POSITION IS PART OF THE WIRING, and no amount of matching on the line's TEXT
  # can see it. A dump placed before the planning step would od an unset
  # variable and report that absence as the finding; one placed after the
  # harness would print the bytes of a job that had already decided. The three
  # landmarks are therefore compared as line numbers inside the job's own block.
  s15_plan_at="$(s15_lineno_of "$s15_job" "$S15_PLAN_RE")"
  s15_dump_at="$(s15_lineno_of "$s15_job" "$S15_DUMP_RE")"
  s15_harness_at="$(s15_lineno_of "$s15_job" "$S15_HARNESS_RE")"
  if [ -n "$s15_plan_at" ] && [ -n "$s15_dump_at" ] && [ -n "$s15_harness_at" ] &&
     [ "$s15_plan_at" -lt "$s15_dump_at" ] && [ "$s15_dump_at" -lt "$s15_harness_at" ]; then
    ok "S15: $s15_job dumps between planning (:$s15_plan_at) and the harness (:$s15_harness_at)"
  else
    bad "S15: $s15_job's dump is not between the planning step and the harness — plan=[$s15_plan_at] dump=[$s15_dump_at] harness=[$s15_harness_at]"
  fi
done

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

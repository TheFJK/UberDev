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
if bash "$ENVSH" supervision-smoke-macos 2 1 >"$WORK/env.out" 2>"$WORK/env.err"; then
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
s8_harness() { # s8_harness <job-key> -> the run: block with invocations stripped
  awk -v JOB="$1" '
    $0 ~ ("^  " JOB ":[[:space:]]*$") { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+run:[[:space:]]*[|][[:space:]]*$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { in_run = 0; next }
      sub(/^          /, "")
      if ($0 ~ /^run_one /) next
      print
    }
  ' "$WORKFLOW"
}
S8_BODY="$(s8_harness shape-checks)"
if [ -z "$S8_BODY" ]; then
  bad "S8: the ubuntu harness extracted empty — the job key or the block shape moved"
else
  ok "S8: the ubuntu harness extracted non-empty"
  {
    printf '%s\n' "$S8_BODY"
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
  } >"$WORK/s8.sh"
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
    printf '%s\n' "$S8_BODY" >"$WORK/s9py.sh"
    printf 'run_one python -I -B tests/pyfixture.test.py\n' >>"$WORK/s9py.sh"
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
    printf '%s\n' "$S8_BODY" >"$WORK/s9sub.sh"
    printf 'run_one bash tests/plan.test.sh\n' >>"$WORK/s9sub.sh"
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
    printf '%s\n' "$S8_BODY" >"$WORK/s9.sh"
    printf 'run_one true /somewhere/else/a.sh\n' >>"$WORK/s9.sh"
    UBERDEV_SHARD_PLAN="in-plan.test.sh" UBERDEV_SHARD=1 UBERDEV_SHARDS=2 \
      bash -e "$WORK/s9.sh" 2>&1 || true
  )"
  case "$S8_SYN" in
    *"RUN  true /somewhere/else/a.sh"*)
      ok "S9: an argv naming no fixture runs — W12.3's synthetic fixtures survive the filter" ;;
    *) bad "S9: a non-fixture argv was skipped — ci-wiring W12.3 would red" ;;
  esac

  # Polarity: with no plan the SAME harness must run every row. This is the
  # standalone case ci-wiring W12.3 depends on, asserted here at the routing seam.
  S8_ALL="$(bash -e "$WORK/s8.sh" 2>&1 || true)"
  S8_N="$(printf '%s\n' "$S8_ALL" | grep -c '^--- RUN ')"
  [ "$S8_N" = "6" ] && ok "S8: with no plan set, all six run (the standalone case)" \
    || bad "S8: an unset plan ran $S8_N of 6 — the default is not fail-open"
fi

echo ""
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

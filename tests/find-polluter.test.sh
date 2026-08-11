#!/usr/bin/env bash
# tests/find-polluter.test.sh — behavioural lock for the vendored bisection
# script plugins/uberdev/skills/systematic-debugging/find-polluter.sh (#430).
#
# THE BUG THIS LOCKS. `find .` emits every path with a leading `./`, so
# `find . -path 'src/**/*.test.ts'` — the pattern the script's own usage line
# AND plugins/uberdev/skills/systematic-debugging/root-cause-tracing.md both
# document — matched nothing at all. The count was then taken with
# `echo "$TEST_FILES" | wc -l`, and `echo ""` is one line, so a zero-match
# enumeration counted as 1. The observable result:
#
#     Found 1 test files
#     <no [i/N] Testing: line at all>
#     No polluter found - all tests clean!      rc=0
#
# Zero files enumerated, zero tests run, and a confident clean bill of health.
# A debugging tool that reports "clean" without having looked is worse than no
# tool: it terminates the investigation with a false negative.
#
# Two independent defects are involved and BOTH are locked here:
#   1. Enumeration. The `./` prefix mismatch, plus `find -path`'s inability to
#      match `**/` against zero directory levels (so `src/**/*.test.ts` skips
#      `src/top.test.ts` even once the prefix is right). Fixed by re-syncing to
#      upstream superpowers v6.2.0, which strips a caller-supplied `./` and ORs
#      in the `**/`-collapsed alternative — F1, F2, F3, F10.
#   2. The vacuous verdict. Even with a correct enumeration, a pattern that
#      matches nothing still printed `Found 0 test files` and exited 0 with
#      `No polluter found`. Upstream keeps that green exit; UberDev deliberately
#      does not (see the divergence note in
#      docs/uberdev/audits/2026-05-04-superpowers-vendor-audit.md). A run that
#      executed zero tests proves nothing, so it now refuses on stderr and
#      exits 2 — F5, and F4 as the general count-vs-work reconciliation.
#
# EXIT CONTRACT under test:
#   0  every matched test ran and none polluted
#   1  polluter found, or bad usage (both pre-existing)
#   2  verdict refused — nothing matched, the file search was incomplete, or the
#      pollution target was already present so a test would not have run
#      (local addition; upstream returns a green 0 in all three shapes)
#
# WHY THIS SUITE EXECUTES THE SCRIPT INSTEAD OF GREPPING IT. A structural test
# that grepped find-polluter.sh for the new `-o -path` token would be a
# counterfeit lock: it would pass against a "fix" that still enumerates nothing,
# which is precisely the failure mode under repair (the #419 class). Every
# BEHAVIOURAL case — F1-F3, F5-F7, F10-F12 — runs `bash "$SCRIPT"` against a
# real on-disk fixture with a stubbed `npm` first on PATH, and asserts on real
# stdout, real stderr and a real exit code. The fixture's file list is written
# out LITERALLY and never derived from the same `find -path` expression the
# script uses — deriving it would make the test reproduce the bug it guards.
# The three cases that do NOT execute a fixture run are deliberate and named as
# such: F4 is a derived lock (it reconciles counts from F1's already-captured
# output), F8 is the usage arm (no fixture, no stub — the script exits before it
# would need either), and F9 is a provenance/mode lock read off the repo file.
#
# FIND_POLLUTER_SCRIPT overrides which copy is executed. It exists for the
# red-first run (point it at `git show HEAD:…` bytes and watch F1-F7, F10 fail);
# CI never sets it. F9 deliberately ignores it and reads the repo file, so the
# override cannot make the provenance assertion pass against a temp copy.
#
# Assertions use ASCII substrings only (`FOUND POLLUTER!`, `No polluter found`,
# `No test files matched`, `Pollution already exists`, `Usage:`) — never the
# script's emoji, because Git Bash's locale on windows-latest is not ours to
# assume.
set -u
set -o pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
REPO_SCRIPT_REL="plugins/uberdev/skills/systematic-debugging/find-polluter.sh"
REPO_SCRIPT="$REPO_ROOT/$REPO_SCRIPT_REL"
DOC="$REPO_ROOT/plugins/uberdev/skills/systematic-debugging/root-cause-tracing.md"
SCRIPT="${FIND_POLLUTER_SCRIPT:-$REPO_SCRIPT}"

# Fail-loud preflight — a missing input must abort with rc=2, never read as a
# clean sweep (the repo's FATAL-preflight convention, cf. install.test.sh).
[ -r "$SCRIPT" ] || { echo "FATAL: find-polluter.sh missing/unreadable: $SCRIPT" >&2; exit 2; }
[ -r "$REPO_SCRIPT" ] || { echo "FATAL: repo find-polluter.sh missing/unreadable: $REPO_SCRIPT" >&2; exit 2; }
[ -r "$DOC" ] || { echo "FATAL: root-cause-tracing.md missing/unreadable: $DOC" >&2; exit 2; }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
# Green must mean "all EXPECTED_CASES ran and passed", never "the failure
# counter happens to be zero" — the latter certifies a truncated or
# short-circuited run, the same vacuous-green shape the script under test now
# refuses. Bump this with every case added or removed.
EXPECTED_CASES=12
pass_case() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail_case() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "## find-polluter.sh behavioural suite (#430)"

# ---------------------------------------------------------------------------
# Stubs. `npm` is shadowed by prepending a stub directory to PATH; the stub is
# the FIRST entry, so lookup resolves to it before any real npm on any platform
# (no wholesale PATH replacement, which would force symlinking every coreutil
# the script shells out to — find, sort, wc, tr, ls — under `set -e`).
#
#   bin/npm   clean:     never creates the marker
#   binp/npm  polluting: creates the marker only for ./src/top.test.ts, i.e.
#                        the depth-0 file the pre-fix enumeration skipped, so a
#                        half-fix that finds only the nested file still fails F6
mkdir -p "$TMP/bin" "$TMP/binp"
{
  echo '#!/usr/bin/env bash'
  echo 'exit 0'
} > "$TMP/bin/npm"
{
  echo '#!/usr/bin/env bash'
  echo 'if [ "${2:-}" = "./src/top.test.ts" ]; then : > .pollute; fi'
  echo 'exit 0'
} > "$TMP/binp/npm"
chmod +x "$TMP/bin/npm" "$TMP/binp/npm"

# Fixtures are re-created before every case, and the pollution marker removed —
# a marker present when the loop starts now makes the script REFUSE a verdict
# (rc 2) rather than skip every test under a green exit. F11 exercises that
# branch deliberately; every other case must start clean or it would never
# reach the enumeration it is there to assert on.
#
# Fixture A — the discriminating tree:
#   src/a/x.test.ts     nested match      (the only file the pre-fix ./-form saw)
#   src/top.test.ts     depth-0 match     (skipped unless '**/' is collapsed)
#   src/a/notatest.ts   near-miss         (tail is `atest.ts`, not `.test.ts`)
#   other/y.test.ts     outside the base  (must never be enumerated)
make_fixture_a() {
  rm -rf "$TMP/fixA"
  mkdir -p "$TMP/fixA/src/a" "$TMP/fixA/other"
  : > "$TMP/fixA/src/a/x.test.ts"
  : > "$TMP/fixA/src/top.test.ts"
  : > "$TMP/fixA/src/a/notatest.ts"
  : > "$TMP/fixA/other/y.test.ts"
}

# Fixture B — a tree whose ONLY match sits at depth 0. Pre-fix this printed
# `Found 1 test files` (the empty-string miscount) and visited nothing, so the
# count alone cannot discriminate; F3 asserts the visit line too.
make_fixture_b() {
  rm -rf "$TMP/fixB"
  mkdir -p "$TMP/fixB/src"
  : > "$TMP/fixB/src/top.test.ts"
}

# Fixture C — the ONLY match sits behind a directory name containing a space.
# The count was taken by line while the loop re-read the same string as
# IFS-split words, so this path was torn into two bogus iterations, the real
# file was never run, and the count line still said 1 under a green verdict.
make_fixture_c() {
  rm -rf "$TMP/fixC"
  mkdir -p "$TMP/fixC/src/a b"
  : > "$TMP/fixC/src/a b/x.test.ts"
}

# ---------------------------------------------------------------------------
# Runner. Captures stdout, stderr and rc separately; the script exits non-zero
# on purpose, so rc is taken explicitly rather than left to `set -e`.
RC=0
OUT=""
ERR=""
run_fp() {
  local fp_dir="$1" fp_bin="$2" fp_pat="$3"
  RC=0
  # Truncate the stderr sink first: if the subshell never reached the script,
  # a stale file from the previous case would let a stderr assertion pass on
  # evidence this run never produced.
  : > "$TMP/err"
  OUT="$(cd "$fp_dir" && PATH="${fp_bin}:${PATH}" bash "$SCRIPT" .pollute "$fp_pat" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# The enumeration block: the `Found N` line plus every visit line, in order.
# This is what F2 compares across the two spellings of the same pattern — NOT
# whole stdout, because the script echoes the caller's pattern verbatim before
# stripping a leading `./`, so `Test pattern:` legitimately differs.
# Herestrings throughout (never `printf | grep`): this file sets pipefail, so a
# pipe into an early-exiting reader would enter the epipe-guard class.
enum_block() { grep -E '^Found [0-9]+ test files$|^\[[0-9]+/[0-9]+\] Testing: ' <<<"$1" || true; }
visit_count() { grep -c '^\[[0-9]*/[0-9]*\] Testing: ' <<<"$1" || true; }
found_n() {
  local fn_line
  fn_line="$(grep -E '^Found [0-9]+ test files$' <<<"$1" || true)"
  fn_line="${fn_line#Found }"
  printf '%s\n' "${fn_line% test files}"
}

# ---------------------------------------------------------------------------
# F1 — the documented pattern enumerates every matching depth, and nothing else.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/bin" 'src/**/*.test.ts'
F1_OUT="$OUT"
F1_ENUM="$(enum_block "$OUT")"
f1_bad=""
[ "$RC" -eq 0 ] || f1_bad="${f1_bad} rc=${RC}(want 0)"
grep -q '^Found 2 test files$' <<<"$OUT" || f1_bad="${f1_bad} missing-'Found 2 test files'"
grep -qF '[1/2] Testing: ./src/a/x.test.ts' <<<"$OUT" || f1_bad="${f1_bad} missing-nested-visit"
grep -qF '[2/2] Testing: ./src/top.test.ts' <<<"$OUT" || f1_bad="${f1_bad} missing-depth0-visit"
if grep -qE 'notatest|other/' <<<"$OUT"; then f1_bad="${f1_bad} enumerated-a-non-match"; fi
if [ -z "$f1_bad" ]; then
  pass_case "F1 'src/**/*.test.ts' enumerates ./src/a/x.test.ts + ./src/top.test.ts, and only those"
else
  fail_case "F1 documented pattern must enumerate both depths and no near-miss —${f1_bad}"
fi

# ---------------------------------------------------------------------------
# F2 — a caller-supplied './' prefix is accepted, not treated as a second path
# component. Same enumeration, same order, same count.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/bin" './src/**/*.test.ts'
F2_ENUM="$(enum_block "$OUT")"
f2_bad=""
[ "$RC" -eq 0 ] || f2_bad="${f2_bad} rc=${RC}(want 0)"
# Anti-vacuity: an empty block on both sides would compare equal and prove
# nothing, so the reference block must itself carry a visit line.
grep -qE '^\[[0-9]+/[0-9]+\] Testing: ' <<<"$F1_ENUM" || f2_bad="${f2_bad} F1-reference-block-has-no-visit-line"
[ "$F2_ENUM" = "$F1_ENUM" ] || f2_bad="${f2_bad} enumeration-differs-from-F1"
if [ -z "$f2_bad" ]; then
  pass_case "F2 './src/**/*.test.ts' yields byte-identical enumeration lines to F1"
else
  fail_case "F2 leading './' must not change the enumeration —${f2_bad}"
  echo "        F1 block: $(printf '%s' "$F1_ENUM" | tr '\n' '|')"
  echo "        F2 block: $(printf '%s' "$F2_ENUM" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
# F3 — a file directly under the base directory is not skipped. Both halves
# matter: pre-fix the COUNT line was already `Found 1 test files` (by accident,
# from the empty-string miscount) while nothing was visited.
make_fixture_b
run_fp "$TMP/fixB" "$TMP/bin" 'src/**/*.test.ts'
f3_bad=""
[ "$RC" -eq 0 ] || f3_bad="${f3_bad} rc=${RC}(want 0)"
grep -q '^Found 1 test files$' <<<"$OUT" || f3_bad="${f3_bad} missing-'Found 1 test files'"
grep -qF '[1/1] Testing: ./src/top.test.ts' <<<"$OUT" || f3_bad="${f3_bad} depth-0-file-never-visited"
if [ -z "$f3_bad" ]; then
  pass_case "F3 depth-0 match ./src/top.test.ts is counted AND visited"
else
  fail_case "F3 '**/' must also match zero directory levels —${f3_bad}"
fi

# ---------------------------------------------------------------------------
# F4 — the reported count reconciles with the work actually done. This is the
# general form of the bug: `Found N` must equal the number of tests visited.
f4_found="$(found_n "$F1_OUT")"
f4_visits="$(visit_count "$F1_OUT")"
if [ "$f4_found" = "2" ] && [ "$f4_visits" = "2" ]; then
  pass_case "F4 'Found N test files' (${f4_found}) equals the number of tests visited (${f4_visits})"
else
  fail_case "F4 count must reconcile with work done — Found=${f4_found} visited=${f4_visits} (want 2 and 2)"
fi

# ---------------------------------------------------------------------------
# F5 — zero matches refuse to render a verdict. THE root-cause case: the count
# must be an honest 0 on stdout, the refusal must reach stderr, the exit code
# must be 2, and the clean-bill-of-health line must NOT be printed.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/bin" 'nope/**/*.test.ts'
f5_bad=""
grep -q '^Found 0 test files$' <<<"$OUT" || f5_bad="${f5_bad} missing-'Found 0 test files'-on-stdout"
grep -qF 'No test files matched' <<<"$ERR" || f5_bad="${f5_bad} missing-refusal-on-stderr"
[ "$RC" -eq 2 ] || f5_bad="${f5_bad} rc=${RC}(want 2)"
if grep -qF 'No polluter found' <<<"$OUT"; then f5_bad="${f5_bad} claimed-clean-after-running-zero-tests"; fi
if [ -z "$f5_bad" ]; then
  pass_case "F5 zero matches -> 'Found 0 test files', refusal on stderr, rc=2, no clean verdict"
else
  fail_case "F5 a run that executed zero tests must refuse a verdict —${f5_bad}"
fi

# ---------------------------------------------------------------------------
# F6 — the bisection actually finds the polluter, at depth 0. The stub pollutes
# only on ./src/top.test.ts, so this fails unless the enumeration reaches it.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binp" 'src/**/*.test.ts'
f6_bad=""
[ "$RC" -eq 1 ] || f6_bad="${f6_bad} rc=${RC}(want 1)"
grep -qF 'FOUND POLLUTER!' <<<"$OUT" || f6_bad="${f6_bad} missing-'FOUND POLLUTER!'"
grep -qF 'Test: ./src/top.test.ts' <<<"$OUT" || f6_bad="${f6_bad} did-not-name-the-polluting-test"
grep -qF '[1/2] Testing: ./src/a/x.test.ts' <<<"$OUT" || f6_bad="${f6_bad} clean-test-was-not-visited-first"
if [ -z "$f6_bad" ]; then
  pass_case "F6 polluting test at depth 0 is found and named, rc=1"
else
  fail_case "F6 bisection must reach and report the polluter —${f6_bad}"
fi
rm -f "$TMP/fixA/.pollute"

# ---------------------------------------------------------------------------
# F7 — a genuinely clean run still exits 0, and says so having done the work.
# The visit lines are what separate this from the pre-fix vacuous green.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/bin" 'src/**/*.test.ts'
f7_bad=""
[ "$RC" -eq 0 ] || f7_bad="${f7_bad} rc=${RC}(want 0)"
grep -qF 'No polluter found' <<<"$OUT" || f7_bad="${f7_bad} missing-'No polluter found'"
grep -qF '[1/2] Testing: ' <<<"$OUT" || f7_bad="${f7_bad} missing-[1/2]-visit"
grep -qF '[2/2] Testing: ' <<<"$OUT" || f7_bad="${f7_bad} missing-[2/2]-visit"
if [ -z "$f7_bad" ]; then
  pass_case "F7 genuine clean run exits 0 with both tests visited"
else
  fail_case "F7 a clean verdict must be backed by visited tests —${f7_bad}"
fi

# ---------------------------------------------------------------------------
# F8 — the usage arm is untouched by the fix (rc=1, `Usage:` on stdout).
f8_bad=""
f8_rc=0
f8_out="$(bash "$SCRIPT" 2>"$TMP/err")" || f8_rc=$?
[ "$f8_rc" -eq 1 ] || f8_bad="${f8_bad} zero-arg-rc=${f8_rc}(want 1)"
grep -qF 'Usage:' <<<"$f8_out" || f8_bad="${f8_bad} zero-arg-missing-Usage"
f8_rc=0
f8_out="$(bash "$SCRIPT" a b c 2>"$TMP/err")" || f8_rc=$?
[ "$f8_rc" -eq 1 ] || f8_bad="${f8_bad} three-arg-rc=${f8_rc}(want 1)"
grep -qF 'Usage:' <<<"$f8_out" || f8_bad="${f8_bad} three-arg-missing-Usage"
if [ -z "$f8_bad" ]; then
  pass_case "F8 wrong argument count still prints Usage and exits 1"
else
  fail_case "F8 usage arm must be unchanged —${f8_bad}"
fi

# ---------------------------------------------------------------------------
# F9 — provenance and mode lock, read from the REPO file unconditionally (never
# $SCRIPT), so FIND_POLLUTER_SCRIPT cannot satisfy it with a temp copy.
#
# The header must name the upstream SHA the bytes actually came from — the
# v6.2.0 tag peels to 3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9 — and must
# declare the local divergence, or the next vendor re-diff compares against a
# SHA these bytes never matched. `git ls-files -s` reads the INDEX, so the mode
# assertion is meaningful on a Windows checkout too.
f9_line="$(sed -n '2p' "$REPO_SCRIPT")"
f9_bad=""
for f9_needle in \
  'obra/superpowers@3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9' \
  '(v6.2.0, MIT)' \
  'superpowers-MIT.txt' \
  'local addition:'
do
  grep -qF "$f9_needle" <<<"$f9_line" || f9_bad="${f9_bad} missing[${f9_needle}]"
done
f9_mode="$(git -C "$REPO_ROOT" ls-files -s -- "$REPO_SCRIPT_REL" || true)"
case "$f9_mode" in
  '100755 '*) : ;;
  '') f9_bad="${f9_bad} git-ls-files-returned-nothing" ;;
  *) f9_bad="${f9_bad} mode=${f9_mode%% *}(want 100755)" ;;
esac
if [ -z "$f9_bad" ]; then
  pass_case "F9 header pins upstream v6.2.0 + declares the local addition, and the file stays executable"
else
  fail_case "F9 provenance/mode lock —${f9_bad}"
fi

# ---------------------------------------------------------------------------
# F10 — the pattern the SKILL documentation tells operators to type is the one
# the script can actually execute. The literal is extracted from
# root-cause-tracing.md (2nd single-quoted field of the `./find-polluter.sh`
# example) rather than restated here, so doc and behaviour cannot drift apart
# silently. Assertions match F1's because the doc pattern IS the working
# pattern; what F10 adds is that the doc is the source of the input.
f10_pat="$(sed -n "s|^\./find-polluter\.sh '[^']*' '\([^']*\)'.*$|\1|p" "$DOC")"
f10_bad=""
if [ -z "$f10_pat" ]; then
  f10_bad=" could-not-extract-example-pattern-from-root-cause-tracing.md"
elif [ "$(wc -l <<<"$f10_pat" | tr -d '[:space:]')" != "1" ]; then
  f10_bad=" extracted-more-than-one-example-pattern"
else
  make_fixture_a
  run_fp "$TMP/fixA" "$TMP/bin" "$f10_pat"
  [ "$RC" -eq 0 ] || f10_bad="${f10_bad} rc=${RC}(want 0)"
  [ "$(found_n "$OUT")" = "2" ] || f10_bad="${f10_bad} Found=$(found_n "$OUT")(want 2)"
  [ "$(visit_count "$OUT")" = "2" ] || f10_bad="${f10_bad} visited=$(visit_count "$OUT")(want 2)"
  grep -qF 'Testing: ./src/top.test.ts' <<<"$OUT" || f10_bad="${f10_bad} depth-0-file-not-visited"
fi
if [ -z "$f10_bad" ]; then
  pass_case "F10 the documented example pattern ('${f10_pat}') really enumerates and runs the fixture's tests"
else
  fail_case "F10 the documented example must be executable —${f10_bad}"
fi

# ---------------------------------------------------------------------------
# F11 — a pollution target already present when the loop starts must refuse a
# verdict. This is the sibling of F5's zero-match case and the last path that
# could still reach the clean bill of health having run nothing: every match
# took the `Skipping:` branch, the loop fell through, and the script printed
# `No polluter found` with rc 0. Zero tests run, confident green.
make_fixture_a
: > "$TMP/fixA/.pollute"
run_fp "$TMP/fixA" "$TMP/bin" 'src/**/*.test.ts'
f11_bad=""
[ "$RC" -eq 2 ] || f11_bad="${f11_bad} rc=${RC}(want 2)"
grep -qF 'Pollution already exists' <<<"$ERR" || f11_bad="${f11_bad} missing-refusal-on-stderr"
if grep -qF 'No polluter found' <<<"$OUT"; then f11_bad="${f11_bad} claimed-clean-after-a-dirty-start"; fi
[ "$(visit_count "$OUT")" = "0" ] || f11_bad="${f11_bad} visited=$(visit_count "$OUT")(want 0)"
if [ -z "$f11_bad" ]; then
  pass_case "F11 pollution present before the first test -> refusal on stderr, rc=2, no clean verdict"
else
  fail_case "F11 a bisection that starts dirty must refuse a verdict —${f11_bad}"
fi
rm -f "$TMP/fixA/.pollute"

# ---------------------------------------------------------------------------
# F12 — count and iteration must agree for a matched path containing a space.
# The general invariant is F4's; this pins the input that used to break it, and
# it breaks it in the direction that matters: the reported total stayed at 1
# while the real file was never handed to the runner at all.
make_fixture_c
run_fp "$TMP/fixC" "$TMP/bin" 'src/**/*.test.ts'
f12_bad=""
[ "$RC" -eq 0 ] || f12_bad="${f12_bad} rc=${RC}(want 0)"
[ "$(found_n "$OUT")" = "1" ] || f12_bad="${f12_bad} Found=$(found_n "$OUT")(want 1)"
[ "$(visit_count "$OUT")" = "1" ] || f12_bad="${f12_bad} visited=$(visit_count "$OUT")(want 1)"
grep -qF 'Testing: ./src/a b/x.test.ts' <<<"$OUT" || f12_bad="${f12_bad} space-path-not-visited-intact"
if [ -z "$f12_bad" ]; then
  pass_case "F12 a matched path containing a space is counted once and visited intact"
else
  fail_case "F12 enumeration and iteration must agree for whitespace paths —${f12_bad}"
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
# Anti-vacuity: a run that ended early (or lost a case to an edit) must red,
# not certify green off a zero failure count.
if [ "$((PASS + FAIL))" -ne "$EXPECTED_CASES" ]; then
  echo "  FAIL  suite ran $((PASS + FAIL)) cases, expected $EXPECTED_CASES - refusing to report green" >&2
  exit 1
fi
if [ "$FAIL" -ne 0 ]; then exit 1; fi

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
# Three independent defects are involved and ALL are locked here:
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
#   3. Lossy iteration. Upstream iterates the unquoted match string, so a
#      matched path containing a space is torn into fragments and one
#      containing a glob metacharacter is substituted — both while the
#      reported count stays unchanged and the verdict stays green. This copy
#      reads the matches into an array and counts the array. Purely local:
#      upstream still does not carry it (see the vendor audit), which is why
#      F12 asserts a correct green run rather than a refusal — F12.
#
# A FOURTH defect, of the same class one layer down, is locked here too (#476).
# Everything above is about the runner being EXECUTABLE; none of it establishes
# that it is CAPABLE of running a test, and presence is not capability. A project
# defining no `test` script makes `npm test <file>` exit 1 for every file: the
# `npm --version` preflight passes, the in-loop 126/127 backstop never fires, and
# the loop deliberately reads a non-zero status as "the test ran and failed" — so
# RAN increments for every match, the ran-vs-matched reconciliation is satisfied,
# and the run reaches the clean verdict having executed nothing. A suite wired
# under `test:unit`, `vitest`, or a monorepo package filter is the ordinary case,
# not an exotic one. Closed by a pre-loop capability probe that refuses
# [runner-incapable]. Four cases lock it, and three of them exist to stop a
# plausible wrong repair rather than to assert the fix: F16 is the defect itself;
# F17 is the counter-case that reds an over-broad "refuse on any non-zero runner
# status" (a genuinely failing test is a legitimate outcome and must still
# complete the bisection); F18 pins that the pre-loop probe did not make the
# mid-run backstop redundant; and F19 pins the probe's cost and ordering through
# a runner ledger — once, before the loop, and never by running a test.
#
# EXIT CONTRACT under test:
#   0  every matched test ran and none polluted
#   1  polluter found, or bad usage (both pre-existing). This code deliberately
#      FUSES two structurally unrelated outcomes — "the tool worked and has an
#      answer" and "the tool was never told what to do" — so a wrapper cannot
#      tell a real finding from its own bad invocation. That fusion is a
#      CARRY-OVER kept on purpose, not a refined part of the contract #430
#      codifies: splitting usage onto its own code is a compatibility break for
#      every existing caller of the vendored script, and #430 scoped itself to
#      the refusal codes. Recorded here as a known wart so the next reader does
#      not mistake it for a considered design alongside the exit-2 tokens below.
#      F8 asserts the fused behaviour as it stands.
#   2  verdict refused — nothing matched, the file search was incomplete, the
#      test runner could not be executed, the runner starts but the project
#      defines no test script it could run, a matched path did not survive the
#      file list intact, the pollution target was already present so a test
#      would not have run, or fewer tests ran than were matched (local
#      addition; upstream returns a green 0 in every one of these shapes).
#      Seven causes share one integer, so every exit-2 message carries a
#      machine-readable reason token as the first bracketed field of its first
#      line — [search-failed], [no-matches], [runner-unusable],
#      [runner-incapable], [dirty-start], [path-missing], [ran-lt-matched].
#      Prefer the token over the prose when adding a case: the substring
#      assertions below predate it and weld the contract to English.
#      The ran-vs-matched shape is a deliberate tripwire for a future skip path,
#      not a reachable branch: every skip refuses before the loop ends, so no
#      case here drives it and none should be written pretending to.
#
# WHY THIS SUITE EXECUTES THE SCRIPT INSTEAD OF GREPPING IT. A structural test
# that grepped find-polluter.sh for the new `-o -path` token would be a
# counterfeit lock: it would pass against a "fix" that still enumerates nothing,
# which is precisely the failure mode under repair (the #419 class). Every
# BEHAVIOURAL case — F1-F3, F5-F7, F10-F19 — runs `bash "$SCRIPT"` against a
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
# red-first run: point it at the pre-fix `git show` bytes and F1-F7 and F10-F19
# all go red — only F8 (the usage arm, which the fix does not touch) and F9
# (which reads the repo file) stay green. Keep that list honest when a case is
# added, or the documented red-first check sends the reader chasing phantom
# regressions in a suite whose whole point is that a green must be earned.
# CI never sets the override. F9 deliberately ignores it and reads the repo
# file, so the override cannot make the provenance assertion pass against a
# temp copy.
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
EXPECTED_CASES=19
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
#   binf/find truncated: emits a partial list and exits non-zero, the shape of a
#                        walk that could not read part of the tree. Shadowing
#                        the walker is portable; a chmod-based unreadable
#                        directory is not on the windows-latest job. Used by F13
#                        prepended in front of bin, so npm still resolves.
#   binc/npm  incapable: starts fine (`--version` succeeds) but the project
#                        defines no test script, so `npm pkg get scripts.test`
#                        answers `{}` and every `npm test <file>` exits 1 — the
#                        #476 shape. Used by F16.
#   binr/npm  failing:   fully capable, and its FIRST test genuinely fails
#                        (exit 1, distinct output per file). The counter-case
#                        that reds an over-broad "refuse on any non-zero runner
#                        status" fix. Used by F17.
#   binb/npm  breaking:  capable at the probe, then unexecutable mid-run — the
#                        second `test` invocation exits 127. Used by F18.
#   binl/npm  ledger:    records every invocation's argv to $FP_NPM_LOG, then
#                        behaves like bin/npm. Used by F19 to pin what the
#                        script asks the runner, and in what order.
#
# Every npm stub that models a real project answers `npm pkg get scripts.test`
# with a JSON string, because the script now PROBES capability before the loop:
# a stub that stayed silent there would refuse every fixture and F1-F15 would
# red for a reason none of them is about.
mkdir -p "$TMP/bin" "$TMP/binp" "$TMP/binf" "$TMP/binm" "$TMP/binc" "$TMP/binr" "$TMP/binb" "$TMP/binl"
cat > "$TMP/bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
case "${1:-}" in pkg) printf '"vitest run"\n'; exit 0 ;; esac
exit 0
NPM_STUB
cat > "$TMP/binp/npm" <<'NPM_STUB'
#!/usr/bin/env bash
case "${1:-}" in pkg) printf '"vitest run"\n'; exit 0 ;; esac
if [ "${2:-}" = "./src/top.test.ts" ]; then : > .pollute; fi
exit 0
NPM_STUB
# The #476 fixture: a runner that STARTS but cannot run a test. `--version` must
# succeed, or the whole-run preflight refuses first — for the wrong reason — and
# the case reads as fixed when it is not (the issue body records making exactly
# that mistake). `pkg get scripts.test` answers `{}`, which is what npm returns
# for a manifest with no `scripts.test` key, and every `test` invocation fails
# with npm's real missing-script envelope on stderr and exit 1 — indistinguishable
# from a test that ran and failed, which is the whole defect.
cat > "$TMP/binc/npm" <<'NPM_STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "10.0.0"; exit 0 ;;
  pkg) printf '{}\n'; exit 0 ;;
esac
echo 'npm error Missing script: "test"' >&2
exit 1
NPM_STUB
# A fully capable runner whose first test genuinely FAILS. Nothing here is
# broken: a failing test is a legitimate outcome and the pollution check is the
# verdict, not the runner's status. This is the counter-case that stops the fix
# from being "refuse whenever npm exits non-zero", which would refuse every real
# red suite the bisection exists to investigate.
cat > "$TMP/binr/npm" <<'NPM_STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "10.0.0"; exit 0 ;;
  pkg) printf '"vitest run"\n'; exit 0 ;;
esac
if [ "${2:-}" = "./src/a/x.test.ts" ]; then
  echo "FAIL ${2:-} 1 failed"
  exit 1
fi
echo "PASS ${2:-}"
exit 0
NPM_STUB
# Capable at the probe, then broken mid-run: the SECOND `test` invocation exits
# 127. Counts only `test` invocations, in a file outside every fixture (a
# counter written into the fixture would be enumerated as tree state). The `:?`
# form makes a forgotten export fail loud instead of silently writing to "".
cat > "$TMP/binb/npm" <<'NPM_STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "10.0.0"; exit 0 ;;
  pkg) printf '"vitest run"\n'; exit 0 ;;
esac
NPM_COUNT_FILE="${FP_NPM_COUNT:?FP_NPM_COUNT unset}"
printf 'x' >> "$NPM_COUNT_FILE"
if [ "$(wc -c < "$NPM_COUNT_FILE" | tr -d '[:space:]')" -ge 2 ]; then
  echo "npm: command not found" >&2
  exit 127
fi
exit 0
NPM_STUB
# The ledger. Records the full argv of every invocation, then behaves exactly
# like bin/npm, so what F19 asserts is only the sequence of asks — one probe,
# before the loop, and never a test run twice.
cat > "$TMP/binl/npm" <<'NPM_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FP_NPM_LOG:?FP_NPM_LOG unset}"
case "${1:-}" in pkg) printf '"vitest run"\n'; exit 0 ;; esac
exit 0
NPM_STUB
cat > "$TMP/binm/find" <<'FIND_STUB'
#!/usr/bin/env bash
# A SUCCESSFUL walk that names a path which is not there: one real match and one
# phantom, exit 0. This is the shape F13's stub cannot produce — F13 is the
# search FAILING, this is the search succeeding and the list being wrong — and
# it is what an earlier test deleting a file mid-bisection, or a newline-bearing
# filename torn by the newline-delimited list, looks like by the time the loop
# reaches it. Used by F15.
#
# The phantom is named to sort AFTER the real match: the script runs the list
# through `sort -u`, so a name like `gone.test.ts` would sort FIRST and the
# refusal would land before anything was visited — which is a weaker assertion
# and not the one F15 makes.
printf './src/a/x.test.ts\n./src/a/zgone.test.ts\n'
exit 0
FIND_STUB
cat > "$TMP/binf/find" <<'FIND_STUB'
#!/usr/bin/env bash
# A truncated walk: one real match on stdout, a diagnostic on stderr, non-zero
# exit — exactly what an unreadable subtree, an I/O error or a depth limit
# produces. The partial list is the point: it looks like a usable enumeration.
printf './src/a/x.test.ts\n'
echo "find: ./src/a: Permission denied" >&2
exit 1
FIND_STUB
chmod +x "$TMP/bin/npm" "$TMP/binp/npm" "$TMP/binf/find" "$TMP/binm/find" \
         "$TMP/binc/npm" "$TMP/binr/npm" "$TMP/binb/npm" "$TMP/binl/npm"

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
  ERR="$(<"$TMP/err")"
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
[ "$(found_n "$OUT")" = "2" ] || f1_bad="${f1_bad} missing-'Found 2 test files'"
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
[ "$(found_n "$OUT")" = "1" ] || f3_bad="${f3_bad} missing-'Found 1 test files'"
grep -qF '[1/1] Testing: ./src/top.test.ts' <<<"$OUT" || f3_bad="${f3_bad} depth-0-file-never-visited"
if [ -z "$f3_bad" ]; then
  pass_case "F3 depth-0 match ./src/top.test.ts is counted AND visited"
else
  fail_case "F3 '**/' must also match zero directory levels —${f3_bad}"
fi

# ---------------------------------------------------------------------------
# F4 — the reported count reconciles with the work actually done. This is the
# general form of the bug: `Found N` must equal the number of tests visited.
# Scope note: it is a derived lock over F1's already-captured stdout, NOT a
# lock on the script's end-of-loop RAN-vs-TOTAL guard. That guard is the
# unreachable tripwire described in the EXIT CONTRACT above; nothing here
# drives it, so do not read a green F4 as coverage of it.
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
[ "$(found_n "$OUT")" = "0" ] || f5_bad="${f5_bad} missing-'Found 0 test files'-on-stdout"
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
# The header must name BOTH upstream SHAs BY ROLE, and must declare the local
# divergence, or the next vendor re-diff compares against a SHA these bytes never
# matched. The two roles are NOT interchangeable:
#   * BASE — e7a2d16476bf042e9add4699c9d018a90f86e4a6. The audit-wide SHA this
#     file and its 10 siblings were copied from, and the one vendor.json records
#     for the whole component. This is the SHA to re-diff against: every local
#     change shows up, the adopted v6.2.0 hunk among them.
#   * ADOPTED HUNK — 3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9, which the v6.2.0
#     tag peels to. The commit the search-expression fix ALONE was taken from.
#     Explicitly NOT a component re-baseline (that is #462's job), so re-diffing
#     this file at that SHA renders every local change as upstream drift.
# Asserting only the adopted-hunk SHA would let the base be dropped from the
# header without reddening this case — the same misread stated the other way —
# so both are needles below. `git ls-files -s` reads the INDEX, so the mode
# assertion is meaningful on a Windows checkout too.
f9_line="$(sed -n '2p' "$REPO_SCRIPT")"
f9_bad=""
for f9_needle in \
  'obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6' \
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
  pass_case "F9 header pins BOTH upstream SHAs by role + declares the local addition, and the file stays executable"
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
  f10_found="$(found_n "$OUT")"
  f10_visits="$(visit_count "$OUT")"
  [ "$RC" -eq 0 ] || f10_bad="${f10_bad} rc=${RC}(want 0)"
  [ "$f10_found" = "2" ] || f10_bad="${f10_bad} Found=${f10_found}(want 2)"
  [ "$f10_visits" = "2" ] || f10_bad="${f10_bad} visited=${f10_visits}(want 2)"
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

# ---------------------------------------------------------------------------
# F13 — a file search that could not complete refuses a verdict. This is the
# third exit-2 shape of the contract above and the one whose regression costs a
# single token: drop the `set -o pipefail` wrapper from the enumeration command
# substitution and the assignment observes the sorter's status instead of the
# walker's, so a truncated walk hands a partial file list to a confident clean
# verdict — a false negative in a debugging tool, the #430 class itself.
# `find` is shadowed by a stub first on PATH (the mechanism the npm stub
# already uses), with the npm stub directory behind it so the runner still
# resolves; no chmod-unreadable-directory trick, which would not behave on the
# windows-latest job.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binf:$TMP/bin" 'src/**/*.test.ts'
f13_bad=""
[ "$RC" -eq 2 ] || f13_bad="${f13_bad} rc=${RC}(want 2)"
grep -qF 'search for test files failed' <<<"$ERR" || f13_bad="${f13_bad} missing-refusal-on-stderr"
if grep -qF 'No polluter found' <<<"$OUT"; then f13_bad="${f13_bad} claimed-clean-after-a-truncated-search"; fi
[ "$(visit_count "$OUT")" = "0" ] || f13_bad="${f13_bad} visited=$(visit_count "$OUT")(want 0)"
if [ -z "$f13_bad" ]; then
  pass_case "F13 an incomplete file search -> refusal on stderr, rc=2, no clean verdict, nothing visited"
else
  fail_case "F13 a truncated walk must refuse a verdict —${f13_bad}"
fi

# ---------------------------------------------------------------------------
# F14 — a runner that cannot be executed refuses a verdict, BEFORE any test is
# attributed to it. This is the fourth exit-2 shape of the contract above, and
# until this case existed it had no behavioural lock: deleting the runner guard
# outright left the suite fully green (verified by mutation), so a regression
# there would silently restore the exact vacuous green #430 exists to abolish.
# F15 covers the path-missing shape for the same reason, and F16 the
# runner-incapable one; between them every REACHABLE exit-2 branch is now driven
# by a fixture. The ran-vs-matched tripwire is the sole exception and is
# unreachable by construction — see the contract note at the top.
#
# The fixture is the stale-shim shape — an npm that is present and carries the
# execute bit but cannot start. That is what a stale nvm/volta/asdf shim looks
# like once its runtime is uninstalled, and it is precisely the case a PATH
# lookup cannot see: `command -v` finds the file, so only EXECUTING the runner
# refuses it. The stub exits non-zero for `--version` rather than relying on a
# missing interpreter, because the kernel's "bad interpreter" status is not
# portable (bash and sh report 126, zsh reports 127) and this suite also runs
# on the windows-latest job.
#
# `visited=0` is the load-bearing assertion, not rc=2 alone: it is what pins the
# refusal to the WHOLE-RUN preflight rather than to the mid-run backstop. A
# build that lost the preflight but kept the in-loop guard would still exit 2 —
# after visiting a file — and only this assertion tells the two apart.
mkdir -p "$TMP/binx"
cat > "$TMP/binx/npm" <<'NPM_STUB'
#!/usr/bin/env bash
exit 127
NPM_STUB
chmod +x "$TMP/binx/npm"
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binx" 'src/**/*.test.ts'
f14_bad=""
[ "$RC" -eq 2 ] || f14_bad="${f14_bad} rc=${RC}(want 2)"
grep -qF 'runner-unusable' <<<"$ERR" || f14_bad="${f14_bad} missing-refusal-on-stderr"
if grep -qF 'No polluter found' <<<"$OUT"; then f14_bad="${f14_bad} claimed-clean-with-an-unusable-runner"; fi
[ "$(visit_count "$OUT")" = "0" ] || f14_bad="${f14_bad} visited=$(visit_count "$OUT")(want 0 — refusal must precede any test)"
if [ -z "$f14_bad" ]; then
  pass_case "F14 an unusable runner -> refusal on stderr, rc=2, no clean verdict, nothing visited"
else
  fail_case "F14 a runner that cannot execute must refuse a verdict —${f14_bad}"
fi

# ---------------------------------------------------------------------------
# F15 — a matched path that is not there refuses a verdict. Sixth of the seven
# exit-2 shapes (the count and this ordinal both moved when [runner-incapable]
# was inserted after [runner-unusable] for #476), and the last of #430's
# REACHABLE shapes to gain a lock: deleting the guard outright left the suite at
# PASS=14 FAIL=0 (verified by mutation), so the branch was deletable while the
# suite stayed green.
#
# The fixture is a SUCCESSFUL walk that names a phantom — one real match, one
# path that does not exist, exit 0. That is deliberately not F13's shape: F13 is
# the search FAILING (non-zero, partial list), this is the search SUCCEEDING and
# the list being wrong. Both reach exit 2, and only the reason token and the
# visit count tell them apart.
#
# It is the shape a real run produces two ways: an earlier test in the same
# bisection deleting a file, and a newline-bearing filename torn in half by the
# newline-delimited list (the residual the array fix cannot close, since command
# substitution cannot carry NUL). The second is why the guard exists at all.
#
# The assertions pin WHERE the refusal happens, not just that it does: the real
# match is visited first, so visited=1 — a build that refused earlier or later
# would still exit 2 and only this discriminates.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binm:$TMP/bin" 'src/**/*.test.ts'
f15_bad=""
[ "$RC" -eq 2 ] || f15_bad="${f15_bad} rc=${RC}(want 2)"
grep -qF 'path-missing' <<<"$ERR" || f15_bad="${f15_bad} missing-reason-token-on-stderr"
grep -qF 'zgone.test.ts' <<<"$ERR" || f15_bad="${f15_bad} refusal-does-not-name-the-absent-path"
if grep -qF 'No polluter found' <<<"$OUT"; then f15_bad="${f15_bad} claimed-clean-on-a-phantom-path"; fi
[ "$(visit_count "$OUT")" = "1" ] || f15_bad="${f15_bad} visited=$(visit_count "$OUT")(want 1 — refuse AT the phantom, after the real match)"
if [ -z "$f15_bad" ]; then
  pass_case "F15 a matched path that no longer exists -> refusal on stderr, rc=2, no clean verdict"
else
  fail_case "F15 a phantom entry in the file list must refuse a verdict —${f15_bad}"
fi

# ---------------------------------------------------------------------------
# F16 — a runner that STARTS but can never run a test refuses a verdict, before
# any test. Sixth exit-2 shape, and the #476 defect: every guard above is about
# the runner being EXECUTABLE, and presence is not capability. `npm --version`
# passes (the runner is fine), the 126/127 backstop never fires (npm exits 1,
# not 126/127), and RAN increments for every file because a non-zero status is
# deliberately read as "the test ran and failed" — so the reconciliation is
# satisfied and the run reaches the clean verdict having executed nothing.
#
# Two assertions carry the case beyond rc=2. `visited=0` pins the refusal to a
# PRE-LOOP probe: a build that noticed only inside the loop would still exit 2,
# after attributing a file to a runner that never ran it. And `Found 2` must
# still be on stdout, so the refusal is the capability probe and not an
# enumeration that quietly failed upstream of it.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binc" 'src/**/*.test.ts'
f16_bad=""
[ "$RC" -eq 2 ] || f16_bad="${f16_bad} rc=${RC}(want 2)"
grep -qF '[runner-incapable]' <<<"$ERR" || f16_bad="${f16_bad} missing-[runner-incapable]-on-stderr"
# The two refusal shapes must stay distinguishable: a runner that cannot start
# is a different repair from a project that defines no test script, and a
# wrapper branching on the token must not be handed both under one name.
if grep -qF 'runner-unusable' <<<"$ERR"; then f16_bad="${f16_bad} conflated-with-[runner-unusable]"; fi
if grep -qF 'No polluter found' <<<"$OUT"; then f16_bad="${f16_bad} claimed-clean-having-run-zero-tests"; fi
[ "$(visit_count "$OUT")" = "0" ] || f16_bad="${f16_bad} visited=$(visit_count "$OUT")(want 0 — refusal must precede any test)"
[ "$(found_n "$OUT")" = "2" ] || f16_bad="${f16_bad} Found=$(found_n "$OUT")(want 2 — refusal must not hide an enumeration failure)"
if [ -z "$f16_bad" ]; then
  pass_case "F16 a runner that starts but has no test script -> [runner-incapable] on stderr, rc=2, nothing visited"
else
  fail_case "F16 a runner that cannot run a test must refuse a verdict —${f16_bad}"
fi

# ---------------------------------------------------------------------------
# F17 — a genuinely FAILING test is still a legitimate outcome. The counter-case
# to F16: the runner is capable, the first test really fails, and the bisection
# must run to completion and report the pollution verdict, because the pollution
# check is the verdict and the runner's status is not.
#
# This is the case that reds an over-broad repair of #476 — "refuse whenever npm
# exits non-zero" passes F16 and breaks every red suite the tool exists to
# investigate, which is the population it is most often pointed at.
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binr" 'src/**/*.test.ts'
f17_bad=""
[ "$RC" -eq 0 ] || f17_bad="${f17_bad} rc=${RC}(want 0)"
grep -qF 'No polluter found' <<<"$OUT" || f17_bad="${f17_bad} missing-'No polluter found'"
if grep -qF 'runner-incapable' <<<"$ERR"; then f17_bad="${f17_bad} refused-a-capable-runner-over-a-failing-test"; fi
[ "$(visit_count "$OUT")" = "2" ] || f17_bad="${f17_bad} visited=$(visit_count "$OUT")(want 2 — a failing test must not stop the bisection)"
if [ -z "$f17_bad" ]; then
  pass_case "F17 a capable runner whose first test fails still completes the bisection, rc=0"
else
  fail_case "F17 a failing test is a legitimate outcome, not an incapable runner —${f17_bad}"
fi

# ---------------------------------------------------------------------------
# F18 — a runner that is capable at the probe and breaks mid-run still refuses.
# The capability probe runs once, up front, so it cannot see a runner that is
# replaced afterwards; the in-loop 126/127 backstop is what covers that, and
# adding a pre-loop probe must not be read as making the backstop redundant.
# Before this case that backstop was deletable while the suite stayed green.
#
# `visited=2` is the load-bearing assertion, the mirror of F16's `visited=0`: it
# pins the refusal to the in-loop guard rather than the preflight or the probe.
export FP_NPM_COUNT="$TMP/npm-runs"
rm -f "$FP_NPM_COUNT"
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binb" 'src/**/*.test.ts'
f18_bad=""
[ "$RC" -eq 2 ] || f18_bad="${f18_bad} rc=${RC}(want 2)"
grep -qF 'runner-unusable' <<<"$ERR" || f18_bad="${f18_bad} missing-[runner-unusable]-on-stderr"
if grep -qF 'No polluter found' <<<"$OUT"; then f18_bad="${f18_bad} claimed-clean-after-the-runner-broke"; fi
[ "$(visit_count "$OUT")" = "2" ] || f18_bad="${f18_bad} visited=$(visit_count "$OUT")(want 2 — refusal must come from the in-loop backstop)"
if [ -z "$f18_bad" ]; then
  pass_case "F18 a runner that breaks mid-run -> [runner-unusable] on stderr, rc=2, after the tests it did run"
else
  fail_case "F18 the mid-run backstop must survive the pre-loop capability probe —${f18_bad}"
fi
unset FP_NPM_COUNT

# ---------------------------------------------------------------------------
# F19 — the capability probe costs exactly one invocation, runs BEFORE the loop,
# and is not a test run. The ledger is the only thing that can assert ordering
# and cost; rc and stdout cannot tell a pre-loop probe from a per-file one.
#
# Both properties are load-bearing. A probe inside the loop would multiply its
# cost by the file count and, worse, could be misread as a per-file outcome. A
# probe that ran the SUITE to test capability (the issue's candidate direction 1)
# would execute tests before the pollution check had established a clean start —
# it could create the very marker the bisection is about to look for.
export FP_NPM_LOG="$TMP/npm-ledger"
: > "$FP_NPM_LOG"
make_fixture_a
run_fp "$TMP/fixA" "$TMP/binl" 'src/**/*.test.ts'
f19_bad=""
[ "$RC" -eq 0 ] || f19_bad="${f19_bad} rc=${RC}(want 0)"
f19_lines="$(wc -l < "$FP_NPM_LOG" | tr -d '[:space:]')"
if [ "$f19_lines" != "4" ]; then
  f19_bad="${f19_bad} invocations=${f19_lines}(want 4: one --version, one probe, two tests)"
else
  case "$(sed -n '1p' "$FP_NPM_LOG")" in
    '--version'*) : ;;
    *) f19_bad="${f19_bad} first-invocation-is-not---version" ;;
  esac
  case "$(sed -n '2p' "$FP_NPM_LOG")" in
    'pkg get scripts.test'*) : ;;
    *) f19_bad="${f19_bad} second-invocation-is-not-the-capability-probe" ;;
  esac
  case "$(sed -n '3p' "$FP_NPM_LOG")" in
    'test '*) : ;;
    *) f19_bad="${f19_bad} third-invocation-is-not-a-test-run(probe-ran-inside-the-loop?)" ;;
  esac
  case "$(sed -n '4p' "$FP_NPM_LOG")" in
    'test '*) : ;;
    *) f19_bad="${f19_bad} fourth-invocation-is-not-a-test-run(probe-ran-inside-the-loop?)" ;;
  esac
fi
if [ -z "$f19_bad" ]; then
  pass_case "F19 the capability probe runs once, before the loop, and runs no test"
else
  fail_case "F19 probe cost and ordering must be pinned —${f19_bad}"
fi
unset FP_NPM_LOG

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

#!/usr/bin/env bash
# Tests for issue #209 — every tests/*.test.sh that sources
# _lib_assert_structural.sh must do so with a fail-loud guard, so a missing
# or unreadable helper aborts with rc=2 instead of producing a vacuous-green
# run.
#
# Why: the suite uses the repo's deliberate `set -u; set -o pipefail` +
# manual PASS/FAIL counter convention (NOT `set -e`; see install.test.sh
# header for the rationale). Without the guard, an absent helper makes
# `source` print to stderr, the structural `assert_in_section` /
# `assert_subagent_type` / `assert_count` calls fail with rc=127, but the
# test can still `exit 0` if its locally-defined `assert_grep` checks all
# pass — silent green.
#
# The fix is mechanical and repo-wide: every source line must end with
#   || { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }
# matching the existing FATAL-preflight convention these files already use
# for `.md` inputs (cf. install.test.sh:26-29, aliases.test.sh:49-54).
#
# This test is a structural drift guard: it auto-discovers any current or
# future tests/*.test.sh that sources the helper and asserts the guard is
# present on the same line. Adding a new test that sources the helper
# without the guard fails this check at CI time.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
HELPER="$TESTS_DIR/_lib_assert_structural.sh"

if [ ! -r "$HELPER" ]; then
  echo "FATAL: _lib_assert_structural.sh missing/unreadable: $HELPER" >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "FATAL: tests/ directory missing: $TESTS_DIR" >&2
  exit 2
fi

PASS=0
FAIL=0

# Source-site detection: matches both the `. <path>` (POSIX dot) and
# `source <path>` (bash) forms, with any leading whitespace. Stops at the
# `.sh` suffix so the literal guard tail (`|| { ... exit 2; }`) is captured
# on the same line as part of the surrounding string match.
SOURCE_RE='^[[:space:]]*(\.|source)[[:space:]]+[^|&;]*_lib_assert_structural\.sh'

# The literal guard tail every source site must carry. The exact FATAL
# message is part of the contract — operators grep for it in CI logs to
# pinpoint a missing-helper failure mode, so don't accept paraphrases.
GUARD_FRAGMENT='|| { echo "FATAL: _lib_assert_structural.sh missing/unreadable" >&2; exit 2; }'

echo "== A1: every tests/*.test.sh sourcing _lib_assert_structural.sh has the fail-loud guard =="

# Walk every tests/*.test.sh via the shell glob (handles spaces in the repo
# path — e.g. "/Volumes/FJK SSD/" — without any NUL-delimited gymnastics
# that depend on a GNU vs BSD sort/grep -z split). For each file, every
# line matching the source pattern is asserted to carry the guard tail.
SAW_ANY_SOURCING_FILE=0
for f in "$TESTS_DIR"/*.test.sh; do
  # Skip files that don't source the helper at all (most of the suite).
  grep -qE -e "$SOURCE_RE" "$f" 2>/dev/null || continue
  SAW_ANY_SOURCING_FILE=1
  # Per-line scan — a file may source the helper more than once across
  # test fixtures (rare today, but the guard must be present on every
  # source line, not just one).
  while IFS=: read -r lineno line; do
    if grep -qF -- "$GUARD_FRAGMENT" <<<"$line"; then
      echo "  PASS  $(basename "$f"):$lineno carries the fail-loud guard"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $(basename "$f"):$lineno sources _lib_assert_structural.sh without the fail-loud guard"
      echo "        file:   $f"
      echo "        line:   $line"
      echo "        expect: ... || { echo \"FATAL: _lib_assert_structural.sh missing/unreadable\" >&2; exit 2; }"
      FAIL=$((FAIL + 1))
    fi
  done < <(grep -nE -e "$SOURCE_RE" "$f")
done

if [ "$SAW_ANY_SOURCING_FILE" -eq 0 ]; then
  echo "  FAIL  no tests/*.test.sh files source _lib_assert_structural.sh — this drift guard would not detect a regression"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A2: CI shell harnesses have no undeclared ripgrep runtime dependency =="
RG_HITS="$(python3 -I - "$TESTS_DIR" "$0" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1]); current=pathlib.Path(sys.argv[2]).resolve()
command="r"+"g"
pattern=re.compile(r"(^|[;&|()\\s])"+command+r"(?=\\s|$)")
hits=[]
for path in sorted(root.glob("*.test.sh")):
    if path.resolve()==current: continue
    for number,line in enumerate(path.read_text(encoding="utf-8").splitlines(),1):
        if line.lstrip().startswith("#"): continue
        if pattern.search(line): hits.append(f"{path.name}:{number}:{line.strip()}")
print("\\n".join(hits))
PY
)"
if [ -n "$RG_HITS" ]; then
  echo "  FAIL  CI harnesses invoke ripgrep without installing it"
  printf '        %s\n' "$RG_HITS"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  CI harnesses use repository-portable text tools"
  PASS=$((PASS + 1))
fi

echo
echo "== A3: no tests/*.test.sh walks the repository root without excluding worktree checkouts =="
# Issue #445: tests/docs-accuracy.test.sh built its corpus by walking the
# working directory, so it read the CHANGELOG and RFC copies inside every
# scratch checkout below the repo root and reported them as shipped-doc
# violations. The sting is that UberDev's own tooling creates those checkouts
# (/solve, /turbo, the Workflow runtime's isolation:"worktree", /merge's
# scratch worktree), so the guard was green on a fresh CI checkout and red on
# any working developer machine — the inverse of the signal it should give, and
# a fast way to train people to ignore a red suite.
#
# The general rule: a walk rooted at the repository root must exclude the
# scratch checkout roots, which plugins/uberdev/lib/goal-state.sh enumerates as
# "", ".claude/worktrees/*/", ".worktrees/*/" and "worktrees/*/". Preferring
# `git ls-files` satisfies this by construction (it derives the exclusion set
# from .gitignore instead of restating it) and is what docs-accuracy and
# epipe-guard both now do; a hand-written exclusion list satisfies it too, as
# long as it actually names the scratch roots.
#
# BOUNDARY NOTE: this is a real predicate over real bytes, not a CONTRACT:
# marker. tests/contract_markers.py scans only plugins/uberdev/** (SCAN_ROOTS),
# so a marker placed on a tests/-side exclusion list would never be compared
# against goal-state.sh's list — it would be documentation, not enforcement.
#
# SELF-TRIP WARNING: this block is itself a tests/*.test.sh and is scanned by
# its own predicate. Never write the literal walk-command token followed by
# whitespace and `.`/`$REPO_ROOT` in a comment or message here — phrase it as
# "walks the repository root". The definition below is safe because the token
# is followed by `[`, not by whitespace.

# Joins backslash continuations into logical lines. The live site spans three
# physical lines, and a physical-line scan would judge the root argument and
# the exclusion list separately — each half innocent, the whole non-compliant.
# Comment-only logical lines are dropped so prose about the rule is not a site.
# A trailing space is appended so the predicate can require a delimiter after
# the root argument without an end-of-line anchor.
# Uses $0 only — no positional column refs.
A3_JOIN_AWK='
FNR == 1 { if (buf != "") { print fname "\t" start "\t" buf " " } buf = ""; start = 0 }
{ fname = FILENAME; if (start == 0) start = FNR; buf = buf $0 }
/\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, " ", buf); next }
{ if (buf !~ /^[[:space:]]*#/) print fname "\t" start "\t" buf " "; buf = ""; start = 0 }
END { if (buf != "" && buf !~ /^[[:space:]]*#/) print fname "\t" start "\t" buf " " }
'

# Site predicate: the root argument must TERMINATE at `.` or `$REPO_ROOT`. A
# walk rooted at a subdirectory ("$REPO_ROOT/plugins/uberdev", "$ROOT_CASE",
# "$ROOT/tests/_fixtures") is correctly scoped by construction and is NOT a
# site — without the termination requirement those four correctly-scoped walks
# would be flagged and this guard would red on the day it shipped.
#
# Single-quoted so $REPO_ROOT stays literal. Deliberately carries no `^`/`$`
# anchors: every logical line reaches this pattern with a TAB in front and a
# space appended, so a plain delimiter class works, and anchor-inside-
# alternation is the ERE construct most likely to differ across the BSD, GNU
# and MSYS greps this suite runs under.
A3_ROOT_WALK='[^[:alnum:]_.-]find[[:space:]]+("\$REPO_ROOT"|\$REPO_ROOT|\.)[[:space:]]'

# One awk over the whole glob and one grep over its output — NOT a process per
# line. Per-line spawns are disproportionately expensive on shape-checks-windows,
# already the CI critical path.
A3_SCANNED=0
while IFS=$'\t' read -r a3_file a3_lineno a3_logical; do
  [ -n "$a3_logical" ] || continue
  A3_SCANNED=$((A3_SCANNED + 1))
  # Herestrings, not pipes: this file sets pipefail and `grep -q` exits on its
  # first match (tests/epipe-guard.test.sh).
  a3_missing=""
  grep -qF -- '.worktrees' <<<"$a3_logical" || a3_missing="${a3_missing} .worktrees"
  grep -qF -- '.claude'    <<<"$a3_logical" || a3_missing="${a3_missing} .claude"
  if [ -z "$a3_missing" ]; then
    echo "  PASS  $(basename "$a3_file"):$a3_lineno excludes the scratch checkout roots"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $(basename "$a3_file"):$a3_lineno walks the repository root without excluding scratch checkouts"
    echo "        file:    $a3_file"
    echo "        line:    $(printf '%s' "$a3_logical" | sed 's/^[[:space:]]*//')"
    echo "        missing:${a3_missing}"
    echo "        fix:     prefer \`git ls-files\`, or name the scratch roots in the exclusion list"
    FAIL=$((FAIL + 1))
  fi
done < <(awk "$A3_JOIN_AWK" "$TESTS_DIR"/*.test.sh | grep -E -e "$A3_ROOT_WALK")

# Vacuity arm: a guard that matches nothing cannot red. This is the #430 defect
# class (a vendored scanner whose predicate matched zero test files), and it is
# the same silent-vacuous-PASS shape #445 itself was about, so it must not be
# reproduced here.
if [ "$A3_SCANNED" -eq 0 ]; then
  echo "  FAIL  A3 matched no repository-root walkers — the guard cannot red (vacuous)"
  echo "        Either the predicate drifted from the code it must police, or the"
  echo "        last such walker was removed. If the latter, delete this block."
  FAIL=$((FAIL + 1))
fi

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

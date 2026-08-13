#!/usr/bin/env bash
# tests/test-harness-source-guards.test.sh — the home of every `tests/`-wide
# SOURCE CONVENTION, one lettered row per convention. A convention that holds
# across the whole test corpus belongs here as one scanner, not as an in-file
# guard copied into each suite that happens to obey it: the third copy is where
# duplication stops being cheaper than a scanner (issue #447).
#
#   A1  every tests/*.test.sh that sources _lib_assert_structural.sh does so
#       with the fail-loud guard tail                                  (#209)
#   A2  no CI shell harness has an undeclared ripgrep runtime dependency
#   A3  no tests/*.test.sh walks the repository root without excluding the
#       scratch worktree checkouts                                     (#445)
#   A4  python `tempfile` scratch trees created under tests/ are torn down
#       with unlink errors suppressed, so teardown cannot decide a verdict
#                                                                (#428, #447)
#
# Every row scans this file too — none of them is self-exempt — so each row
# that needs a literal token assembles it at runtime. See the SELF-TRIP
# WARNING comments in A3 and A4.
#
# ---------------------------------------------------------------------------
# A1 (#209) — every tests/*.test.sh that sources _lib_assert_structural.sh must
# do so with a fail-loud guard, so a missing or unreadable helper aborts with
# rc=2 instead of producing a vacuous-green run.
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
echo "== A4: python scratch trees under tests/ are torn down off the verdict path =="
# Issue #447, the follow-up to #428. `TemporaryDirectory.__exit__` re-raises
# every OSError but PermissionError and FileNotFoundError, so an unlink race
# during TEARDOWN reds the whole shape-checks job with a traceback pointing at a
# file the PR author never touched (run 31369242976). #428 fixed that in
# tests/code-fixer-contract.test.sh and its Windows twin with a `scratch_dir()`
# factory plus an in-file S1-S6 drift guard scoped to those two files — already a
# two-file duplication, while six sibling suites still carried the raw
# constructor. This row is the one scanner that replaces the per-file copies.
#
# THE RULE. A python scratch TREE created under tests/ must be made with
# `mkdtemp` and torn down with unlink errors suppressed — via the
# `scratch_dir(prefix, parent=None)` context manager, or, when the tree outlives
# a lexical scope, `atexit.register(shutil.rmtree, root, <suppressing kwarg>)`.
# Both halves are enforced: A4.1 bans the raw constructor, A4.2 requires every
# factory call to sit within 10 lines of a suppressed teardown. A ban-only
# predicate would BLESS a bare factory that is never torn down at all, and that
# was a real shape in this repo — prkit-generate.test.sh:622 was exactly one, so
# the pairing arm is what makes this a convention rather than a keyword ban.
#
# DECLARED BOUNDARY — this row governs python `tempfile` scratch TREES created
# under tests/ only. It does NOT govern the ~266 shell `mktemp -d` trees: those
# suites run `set -u; set -o pipefail` WITHOUT `set -e` and count PASS/FAIL by
# hand, so a failing `rm -rf` in a `trap` cannot change a verdict. Nor does it
# govern `NamedTemporaryFile`/`TemporaryFile` (single files, not trees). A guard
# whose name promises more than its predicate delivers is the #370 / RFC 0016
# shape, so the promise is written down rather than left implied.
#
# CORPUS. `tests/*.sh` and `tests/*.py`, non-recursive — deliberately not a walk.
# tests/_fixtures/ and tests/__pycache__/ hold generated and untracked scratch;
# descending into them would make the verdict depend on local residue, which is
# the #445 defect A3 above exists to prevent.
#
# SELF-TRIP WARNING: this file is a tests/*.sh and IS inside A4's own corpus — it
# is not self-exempt (A4.4i proves it). Never write any of the three needles
# contiguously anywhere in this file, including in FAIL messages and prose: the
# banned constructor, the factory call, or the ignore-errors kwarg. All three are
# assembled from fragments below and interpolated wherever they are needed.
_A4_BAN_LITERAL='tempfile.Temporary''Directory('
_A4_FACTORY_LITERAL='tempfile.''mkdtemp('
_A4_SUPPRESS_LITERAL='ignore_errors''=True'
_A4_ERR_MARK='DETECTOR-ERROR: '

# Windows Git Bash ships `python`, not `python3`; ubuntu-latest ships both.
# Mirrors the portable resolver in tests/contract-markers.test.sh:50-58.
# Hardcoding `python3` is how a sibling guard can pass VACUOUSLY on a host that
# lacks it, so an unresolvable interpreter must reach the DETECTOR-ERROR arm
# below and never silence. UBERDEV_A4_PY_OVERRIDE lets an operator pin the
# interpreter (e.g. reproduce Git Bash locally); A4.4h drives the same variable
# to prove the error arm is live.
if A4_PY="$(command -v python3 2>/dev/null)" && [ -n "$A4_PY" ]; then
  :
elif A4_PY="$(command -v python 2>/dev/null)" && [ -n "$A4_PY" ]; then
  :
else
  A4_PY=""
fi
A4_PY="${UBERDEV_A4_PY_OVERRIDE:-$A4_PY}"

# The detector emits PURE FACTS, no policy: floors, sentinel rules and messages
# all live in bash below, so A4.4 can reuse it against two-file fixture corpora
# without tripping the 100-file floor.
#
#   FILES <n>
#   EXT <sh|py> <n>
#   FACTORIES <n>
#   BAN <basename>:<lineno>
#   UNPAIRED <basename>:<lineno>
#   SENTINEL <basename> <factory-count>      (-1 = not in the corpus at all)
#
# `FILES <n>` is emitted unconditionally, so an empty report unambiguously means
# the detector died and can never be read as "clean".
A4_DETECTOR="$(cat <<'PY'
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
sentinels = [name for name in sys.argv[2].split(",") if name] if len(sys.argv) > 2 else []

# Assembled from fragments: the host guard lives inside its own corpus, so a
# contiguous literal here would make A4.1 report the guard itself.
BAN = "tempfile.Temporary" + "Directory("
FACTORY = "tempfile." + "mkdtemp("
SUPPRESS = "ignore_errors" + "=True"
WINDOW = 10

corpus = sorted(set(directory.glob("*.sh")) | set(directory.glob("*.py")))
out = ["FILES %d" % len(corpus)]
for extension in ("sh", "py"):
    out.append("EXT %s %d" % (extension, sum(1 for p in corpus if p.suffix == "." + extension)))

per_file = dict((path.name, 0) for path in corpus)
factories = 0
for path in corpus:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for number, line in enumerate(lines, 1):
        if BAN in line:
            out.append("BAN %s:%d" % (path.name, number))
        if FACTORY in line:
            factories += 1
            per_file[path.name] += 1
            if not any(SUPPRESS in near for near in lines[number - 1:number + WINDOW]):
                out.append("UNPAIRED %s:%d" % (path.name, number))
out.insert(3, "FACTORIES %d" % factories)
for name in sentinels:
    out.append("SENTINEL %s %d" % (name, per_file.get(name, -1)))
print("\n".join(out))
PY
)"

# _a4_scan CORPUS_DIR [SENTINEL_CSV] -> the fact records, or one DETECTOR-ERROR
# line. Never a pipe on the consuming side: this file sets pipefail and
# tests/epipe-guard.test.sh scans it, so every reader below is a herestring.
#
# CORPUS_DIR is handed over as a plain argv path, with no `cygpath -w`. Under Git
# Bash on windows-latest, MSYS rewrites an absolute POSIX argument into a native
# Windows path before a native python sees it — the same thing
# tests/contract-markers.test.sh relies on when it passes $REPO_ROOT to the
# marker guard, whose C2/C3 arms would red if the rewrite ever stopped working.
# If it does stop working here, A4.3a reports a 0-file corpus and FAILS; it can
# never degrade into a silent green.
_a4_scan() {
  local _dir="$1" _sentinels="${2:-}" _out
  if [ -z "$A4_PY" ]; then
    printf '%sno python3/python interpreter resolved (PATH, or an empty override)\n' "$_A4_ERR_MARK"
    return 0
  fi
  if ! _out="$("$A4_PY" -I -c "$A4_DETECTOR" "$_dir" "$_sentinels" 2>/dev/null)"; then
    printf '%sinterpreter %s exited non-zero while scanning %s\n' "$_A4_ERR_MARK" "$A4_PY" "$_dir"
    return 0
  fi
  if [ -z "$_out" ]; then
    printf '%sdetector produced no output while scanning %s\n' "$_A4_ERR_MARK" "$_dir"
    return 0
  fi
  printf '%s\n' "$_out"
}

# _a4_parse REPORT — populates the A4_* globals. Globals rather than a subshell,
# because the parsed facts (and, in A4.4, the PASS/FAIL counters) must survive
# back into the caller.
_a4_parse() {
  A4_FILES=-1
  A4_EXT_SH=-1
  A4_EXT_PY=-1
  A4_FACTORIES=-1
  A4_BANS=""
  A4_UNPAIRED=""
  A4_SENTINEL_ROWS=""
  A4_ERROR=""
  local _line
  while IFS= read -r _line; do
    # STRIP THE TRAILING CR AT THE READER, which is the single choke point.
    #
    # TWO facts compose into this bug, and only the pair explains it.
    #
    #   1. NATIVE-WINDOWS python writes CRLF to stdout. Its TextIOWrapper
    #      translates every "\n" to os.linesep, so `print("\n".join(out))` puts a
    #      CR before EVERY newline. Neither `-u` nor PYTHONIOENCODING turns that
    #      off — both are about buffering and codec, not newline translation;
    #      only `sys.stdout.buffer` or newline="" bypasses it.
    #   2. MSYS2 bash's `$(...)` strips the trailing CR along with the trailing
    #      newline. So the LAST line of a captured report comes back CLEAN and
    #      every line before it keeps its CR.
    #
    # Fact 2 is why this looked impossible to pin down. A single-line capture is
    # unaffected (its only line is the last one), which is why sibling tests that
    # capture one line of python output — finish-branch F14, review-pr's R45/R47
    # field reports, dispatch-background's resolver rows — all pass on Windows.
    # Only a MULTI-line report loses, and only on the fields that are not last.
    #
    # The measured proof, from the first Windows run of this file: `out.insert(3,
    # "FACTORIES …")` puts FACTORIES last for a corpus with no BAN/UNPAIRED row,
    # so A4.4d/e/g reported ONLY `FILES=…` as differing, while A4.4a/b/c/f — whose
    # reports carry a trailing BAN/UNPAIRED line — reported FACTORIES *and* FILES.
    # A uniform-CR story cannot produce that split; this one predicts it exactly.
    #
    # The failure is also invisible in the log: the runner splits its output on
    # the embedded CR, so "(want 0)" lands on its own line and the row reads
    # `FACTORIES=0` — a value identical to the one it was compared against.
    #
    # Fixed HERE and not at each comparison, nor in the detector's `print`: every
    # A4_* global flows through this one loop, so a field added to the `case`
    # below is clean automatically, and the fix holds for whatever interpreter
    # UBERDEV_A4_PY_OVERRIDE is pointed at rather than only for this detector.
    # A no-op on LF input.
    _line="${_line%$'\r'}"
    [ -n "$_line" ] || continue
    case "$_line" in
      "$_A4_ERR_MARK"*) A4_ERROR="${_line#"$_A4_ERR_MARK"}" ;;
      "FILES "*)        A4_FILES="${_line#FILES }" ;;
      "EXT sh "*)       A4_EXT_SH="${_line#EXT sh }" ;;
      "EXT py "*)       A4_EXT_PY="${_line#EXT py }" ;;
      "FACTORIES "*)    A4_FACTORIES="${_line#FACTORIES }" ;;
      "BAN "*)          A4_BANS="${A4_BANS}${_line#BAN }"$'\n' ;;
      "UNPAIRED "*)     A4_UNPAIRED="${A4_UNPAIRED}${_line#UNPAIRED }"$'\n' ;;
      "SENTINEL "*)     A4_SENTINEL_ROWS="${A4_SENTINEL_ROWS}${_line#SENTINEL }"$'\n' ;;
    esac
  done <<<"$1"
}

# _a4_vacuous FILES FLOOR -> rc 0 when the corpus is too small for A4 to be able
# to red at all. ONE definition, applied by the A4.3a arm and asserted by A4.4g,
# so the guard and its own proof can never become two uncompared copies of the
# same predicate (#370 / RFC 0016).
_a4_vacuous() {
  [ "$1" -lt "$2" ]
}

# _a4_rows BLOCK -> the number of non-empty lines in a newline-terminated block.
_a4_rows() {
  local _n=0 _line
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _n=$((_n + 1))
  done <<<"${1:-}"
  printf '%s' "$_n"
}

# The eight files known to build python scratch trees. Named, so a rename or a
# silent deletion cannot quietly shrink what A4 actually polices.
A4_SENTINELS='child-contract-v2.test.sh,child-dispatch-receipts.test.sh,code-fixer-contract.test.sh,code-fixer-contract-windows.test.py,crossplatform-shell-wrappers.test.sh,model-routing.test.sh,prkit-generate.test.sh,run-manifest.test.sh'
# Exact-fit ratchet: 13 factories across those 8 files today, zero headroom, so
# deleting or unrouting one FAILs immediately. Adding a converted suite is
# allowed and should raise this number in the same change — a floor that lags
# the truth is a ratchet that has quietly stopped ratcheting.
A4_FACTORY_FLOOR=13
A4_FILE_FLOOR=100

_a4_parse "$(_a4_scan "$TESTS_DIR" "$A4_SENTINELS")"

if [ -n "$A4_ERROR" ]; then
  echo "  FAIL  A4 the detector could not run, so NOTHING was checked"
  echo "        cause:  $A4_ERROR"
  echo "        fix:    put python3 (or python) on PATH, or point UBERDEV_A4_PY_OVERRIDE at one"
  FAIL=$((FAIL + 1))
else
  # --- A4.1 ban -------------------------------------------------------------
  if [ "$(_a4_rows "$A4_BANS")" -eq 0 ]; then
    echo "  PASS  A4.1 no tests/ source builds a raw scratch tree on the verdict path"
    PASS=$((PASS + 1))
  else
    while IFS= read -r a4_row; do
      [ -n "$a4_row" ] || continue
      echo "  FAIL  A4.1 $a4_row builds a raw scratch tree whose teardown can red this job"
      FAIL=$((FAIL + 1))
    done <<<"$A4_BANS"
    echo "        banned: ${_A4_BAN_LITERAL}) — its __exit__ re-raises every OSError but"
    echo "                PermissionError/FileNotFoundError, so a cleanup race decides the verdict"
    echo "        fix:    with scratch_dir(\"<suite>-\") as temporary:"
    echo "                i.e. ${_A4_FACTORY_LITERAL}prefix=...) paired with shutil.rmtree(path, ${_A4_SUPPRESS_LITERAL})"
  fi

  # --- A4.2 pairing ---------------------------------------------------------
  if [ "$(_a4_rows "$A4_UNPAIRED")" -eq 0 ]; then
    echo "  PASS  A4.2 every scratch-tree factory is paired with a suppressed teardown"
    PASS=$((PASS + 1))
  else
    while IFS= read -r a4_row; do
      [ -n "$a4_row" ] || continue
      echo "  FAIL  A4.2 $a4_row creates a scratch tree with no suppressed teardown within 10 lines"
      FAIL=$((FAIL + 1))
    done <<<"$A4_UNPAIRED"
    echo "        fix:    pair the factory with shutil.rmtree(path, ${_A4_SUPPRESS_LITERAL}) within 10"
    echo "                lines, or atexit.register(shutil.rmtree, root, ${_A4_SUPPRESS_LITERAL}) when the"
    echo "                tree outlives its lexical scope"
  fi

  # --- A4.3 anti-vacuity ----------------------------------------------------
  # A scanner that matches nothing cannot red — the #430 class, and the same
  # silent-vacuous-PASS shape A3 above guards against one level up.
  if _a4_vacuous "$A4_FILES" "$A4_FILE_FLOOR"; then
    if [ "$A4_FILES" -eq 0 ]; then
      echo "  FAIL  A4.3a scanned no files — the predicate drifted, or the last such site was removed"
      echo "        If tests/ genuinely holds no *.sh or *.py, delete this row rather than let it pass."
    else
      echo "  FAIL  A4.3a scanned only $A4_FILES tests/ sources (floor $A4_FILE_FLOOR) — the corpus glob regressed"
    fi
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  A4.3a files scanned: $A4_FILES  (.sh $A4_EXT_SH / .py $A4_EXT_PY)"
    PASS=$((PASS + 1))
  fi

  if [ "$A4_EXT_SH" -gt 0 ] && [ "$A4_EXT_PY" -gt 0 ]; then
    echo "  PASS  A4.3b both halves of the corpus are live (.sh $A4_EXT_SH, .py $A4_EXT_PY)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A4.3b one half of the corpus is empty (.sh $A4_EXT_SH, .py $A4_EXT_PY) — half the rule is unenforced"
    FAIL=$((FAIL + 1))
  fi

  if [ "$A4_FACTORIES" -ge "$A4_FACTORY_FLOOR" ]; then
    echo "  PASS  A4.3c $A4_FACTORIES scratch-tree factories under tests/ (floor $A4_FACTORY_FLOOR)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A4.3c only $A4_FACTORIES scratch-tree factories under tests/, floor is $A4_FACTORY_FLOOR"
    echo "        Factories were deleted or unrouted. A4.1 alone stays green on a file that"
    echo "        simply stopped creating scratch trees through the convention."
    FAIL=$((FAIL + 1))
  fi

  A4_SENTINEL_PROBLEMS=""
  A4_SENTINEL_SEEN=0
  while IFS= read -r a4_row; do
    [ -n "$a4_row" ] || continue
    A4_SENTINEL_SEEN=$((A4_SENTINEL_SEEN + 1))
    a4_name="${a4_row%% *}"
    a4_count="${a4_row##* }"
    if [ "$a4_count" -lt 0 ]; then
      A4_SENTINEL_PROBLEMS="${A4_SENTINEL_PROBLEMS} ${a4_name}(absent-from-corpus)"
    elif [ "$a4_count" -eq 0 ]; then
      A4_SENTINEL_PROBLEMS="${A4_SENTINEL_PROBLEMS} ${a4_name}(no-factory)"
    fi
  done <<<"$A4_SENTINEL_ROWS"
  if [ "$A4_SENTINEL_SEEN" -eq 0 ]; then
    echo "  FAIL  A4.3d the detector reported no sentinel rows — the sentinel list never reached it"
    FAIL=$((FAIL + 1))
  elif [ -n "$A4_SENTINEL_PROBLEMS" ]; then
    echo "  FAIL  A4.3d named sentinels are absent or hold no scratch factory:$A4_SENTINEL_PROBLEMS"
    echo "        Each named file must keep at least one factory, so a rename or a silent"
    echo "        deletion cannot make A4 vacuously green."
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  A4.3d all $A4_SENTINEL_SEEN named sentinels are present and hold a scratch factory"
    PASS=$((PASS + 1))
  fi
fi

# --- A4.4: the detector actually detects — both polarities, in-suite ---------
# A guard whose RED path is only ever proven by hand is not proven. The committed
# precedent is tests/epipe-guard.test.sh E2 (`_ep_case`), which runs its detector
# against synthesized fixtures under `mktemp -d`, in both polarities, every run.
#
# Every fixture body is assembled at RUNTIME from the split fragments above, so
# no needle ever appears contiguously in this file — A4.1 scans this file, and
# epipe-guard.test.sh:294 records the identical trap for its own literals.
# Fixtures are written with plain `printf ... >file` redirection; never
# `printf ... | grep -q`, which reds tests/epipe-guard.test.sh (known class).
if ! A4_TMPD="$(mktemp -d)"; then
  echo "FATAL: mktemp -d failed; A4.4 cannot build its fixture corpora" >&2
  exit 2
fi
trap 'rm -rf "$A4_TMPD"' EXIT

# _a4_corpus NAME -> a fresh, empty fixture corpus directory, printed on stdout.
_a4_corpus() {
  local _d="$A4_TMPD/$1"
  mkdir -p "$_d"
  printf '%s' "$_d"
}

# _a4_case NAME DIR WANT_BAN WANT_UNPAIRED WANT_FACTORIES WANT_FILES.
# Deliberately not fed from a pipe: the right-hand side of a pipeline runs in a
# subshell and the PASS/FAIL counters would never make it back out.
_a4_case() {
  local _name="$1" _dir="$2" _want_ban="$3" _want_unpaired="$4" _want_fac="$5" _want_files="$6"
  local _got_ban _got_unpaired _problems=""
  _a4_parse "$(_a4_scan "$_dir")"
  if [ -n "$A4_ERROR" ]; then
    echo "  FAIL  $_name — the detector could not run: $A4_ERROR"
    FAIL=$((FAIL + 1))
    return
  fi
  _got_ban="$(_a4_rows "$A4_BANS")"
  _got_unpaired="$(_a4_rows "$A4_UNPAIRED")"
  [ "$_got_ban" = "$_want_ban" ] || _problems="$_problems BAN=$_got_ban(want $_want_ban)"
  [ "$_got_unpaired" = "$_want_unpaired" ] || _problems="$_problems UNPAIRED=$_got_unpaired(want $_want_unpaired)"
  [ "$A4_FACTORIES" = "$_want_fac" ] || _problems="$_problems FACTORIES=$A4_FACTORIES(want $_want_fac)"
  [ "$A4_FILES" = "$_want_files" ] || _problems="$_problems FILES=$A4_FILES(want $_want_files)"
  if [ -z "$_problems" ]; then
    echo "  PASS  $_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $_name —$_problems"
    FAIL=$((FAIL + 1))
  fi
}

A4_DIR_A="$(_a4_corpus ban-sh)"
{ printf 'def body():\n'; printf '    with %s) as temporary:\n' "$_A4_BAN_LITERAL"; printf '        pass\n'; } >"$A4_DIR_A/case.sh"
_a4_case "A4.4a raw constructor in a .sh is flagged" "$A4_DIR_A" 1 0 0 1

A4_DIR_B="$(_a4_corpus ban-py)"
{ printf 'def body():\n'; printf '    with %s) as temporary:\n' "$_A4_BAN_LITERAL"; printf '        pass\n'; } >"$A4_DIR_B/case.py"
_a4_case "A4.4b raw constructor in a .py is flagged (the .py half of the corpus is live)" "$A4_DIR_B" 1 0 0 1

A4_DIR_C="$(_a4_corpus bare-factory)"
{ printf 'root = %sprefix="bare-")\n' "$_A4_FACTORY_LITERAL"; printf 'use(root)\n'; } >"$A4_DIR_C/case.sh"
_a4_case "A4.4c a factory with no suppressed teardown is flagged" "$A4_DIR_C" 0 1 1 1

A4_DIR_D="$(_a4_corpus paired-factory)"
{
  printf 'path = %sprefix=prefix)\n' "$_A4_FACTORY_LITERAL"
  printf 'try:\n'
  printf '    yield path\n'
  printf 'finally:\n'
  printf '    shutil.rmtree(path, %s)\n' "$_A4_SUPPRESS_LITERAL"
} >"$A4_DIR_D/case.sh"
_a4_case "A4.4d the canonical factory is not flagged" "$A4_DIR_D" 0 0 1 1

A4_DIR_E="$(_a4_corpus atexit-factory)"
{
  printf 'root = %sprefix="unscoped-")\n' "$_A4_FACTORY_LITERAL"
  printf 'atexit.register(shutil.rmtree, root, %s)\n' "$_A4_SUPPRESS_LITERAL"
} >"$A4_DIR_E/case.sh"
_a4_case "A4.4e the atexit shape (tree outlives its scope) is not flagged" "$A4_DIR_E" 0 0 1 1

A4_DIR_F="$(_a4_corpus far-suppression)"
{
  printf 'root = %sprefix="far-")\n' "$_A4_FACTORY_LITERAL"
  for a4_filler in 1 2 3 4 5 6 7 8 9 10 11; do printf 'filler_%s = %s\n' "$a4_filler" "$a4_filler"; done
  printf 'shutil.rmtree(root, %s)\n' "$_A4_SUPPRESS_LITERAL"
} >"$A4_DIR_F/case.sh"
_a4_case "A4.4f suppression 12 lines away still flags (proximity, not a per-file count)" "$A4_DIR_F" 0 1 1 1

A4_DIR_G="$(_a4_corpus empty)"
_a4_case "A4.4g an empty corpus reports FILES 0 rather than 'clean'" "$A4_DIR_G" 0 0 0 0
if _a4_vacuous "$A4_FILES" "$A4_FILE_FLOOR"; then
  echo "  PASS  A4.4g the vacuity predicate calls that corpus vacuous, so A4.3a would FAIL on it"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A4.4g a $A4_FILES-file corpus was NOT called vacuous (floor $A4_FILE_FLOOR) — A4.3a would go green on nothing"
  FAIL=$((FAIL + 1))
fi

# A detector that cannot RUN must not read as "nothing found". Drive the same
# variable UBERDEV_A4_PY_OVERRIDE writes, both ways: an interpreter that does not
# exist, and no interpreter at all. Both must produce a non-empty report carrying
# the marker, which _a4_parse turns into A4_ERROR and the caller turns into FAIL.
A4_SAVED_PY="$A4_PY"
A4_PY="$A4_TMPD/nonexistent-interpreter"
A4_H_BOGUS="$(_a4_scan "$A4_DIR_A")"
A4_PY=""
A4_H_EMPTY="$(_a4_scan "$A4_DIR_A")"
A4_PY="$A4_SAVED_PY"
_a4_parse "$A4_H_BOGUS"; A4_H_BOGUS_ERR="$A4_ERROR"
_a4_parse "$A4_H_EMPTY"; A4_H_EMPTY_ERR="$A4_ERROR"
if [ -n "$A4_H_BOGUS" ] && [ -n "$A4_H_BOGUS_ERR" ] && [ -n "$A4_H_EMPTY" ] && [ -n "$A4_H_EMPTY_ERR" ]; then
  echo "  PASS  A4.4h an unrunnable interpreter reports an error, not 'clean' (both bogus-path and unresolved)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A4.4h a broken interpreter returned bogus='$A4_H_BOGUS' unresolved='$A4_H_EMPTY' — A4 would go vacuously green"
  FAIL=$((FAIL + 1))
fi

# Self-scan. Two independent halves: this file carries no contiguous needle (or
# A4.1/A4.2 would report the guard itself), and this file IS inside the corpus it
# scans (or the guard would be exempt from its own rule).
A4_SELF="$0"
A4_SELF_PROBLEMS=""
if [ ! -r "$A4_SELF" ]; then
  A4_SELF_PROBLEMS=" this file is unreadable at \$0 ($A4_SELF), so the self-scan proves nothing"
else
  for a4_literal in "$_A4_BAN_LITERAL" "$_A4_FACTORY_LITERAL" "$_A4_SUPPRESS_LITERAL"; do
    a4_hits="$(grep -cF -- "$a4_literal" "$A4_SELF")" || a4_hits=0
    [ "$a4_hits" -eq 0 ] || A4_SELF_PROBLEMS="$A4_SELF_PROBLEMS ${a4_literal}x${a4_hits}"
  done
  _a4_parse "$(_a4_scan "$TESTS_DIR" "$(basename "$A4_SELF")")"
  a4_self_count=-2
  while IFS= read -r a4_row; do
    [ -n "$a4_row" ] || continue
    a4_self_count="${a4_row##* }"
  done <<<"$A4_SENTINEL_ROWS"
  [ "$a4_self_count" -ge 0 ] || A4_SELF_PROBLEMS="$A4_SELF_PROBLEMS not-in-own-corpus($a4_self_count)"
fi
if [ -z "$A4_SELF_PROBLEMS" ]; then
  echo "  PASS  A4.4i this guard carries no contiguous needle and is inside its own corpus (not self-exempt)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A4.4i self-scan:$A4_SELF_PROBLEMS"
  FAIL=$((FAIL + 1))
fi

echo
echo "== A4: no tests/*.test.sh arms set -e inside a subshell used as a condition =="
# Issue #469. POSIX: "the -e setting shall be ignored when executing … any
# command of an AND-OR list other than the last" and, likewise, the compound
# list a construct tests for its exit status. So in
#
#   if (
#     set -euo pipefail
#     …assertions…
#     <last command>
#   ); then
#
# the subshell IS the `if` condition, and bash suppresses errexit for its ENTIRE
# body — re-executing `set -e` on the first line does not re-arm it. Every
# assertion above the last becomes a no-op and the row's verdict collapses to
# the exit status of the LAST command alone. That is not a style nit: V2.7e in
# post-impl-review.test.sh reported PASS *because* its subject failed (a stale
# sha256 pin aborted the stub before the writer ran, which made the trailing
# `[ ! -e "$out" ]` true), and a deliberately wrong `deadbeef` pin scored 142/0
# on macOS. Only ubuntu CI caught the drift, and only incidentally.
#
# The fix shape — the one this guard leaves alone — runs the subshell OUTSIDE
# the condition and tests its captured status:
#
#   (
#     set -euo pipefail
#     …assertions, each `|| exit <distinct code>`…
#   )
#   ROW_RC=$?
#   if [ "$ROW_RC" -eq 0 ]; then …
#
# DETECTOR BOUNDARY: only shell subshells are sites. `if (` inside an embedded
# python/awk heredoc (`if (not swapped and …`, `if (index(buf, …) > 0) {`) is
# not one, and neither is `if ( VAR=x bash -c '… set -e …' )` — the inner
# `bash -c` is a fresh process whose errexit context starts clean. The opener is
# therefore required to be a bare `(` closing the line, or a one-line `( set -`,
# which is exactly how a multi-assertion shell subshell is written.
A4_VERDICT="$(python3 -I - "$TESTS_DIR" <<'PY'
import pathlib, re, sys

# `(` alone at end of line (the multi-line shell form), or `( set -…` inline.
OPENER = re.compile(r"^[ \t]*(?:if|elif|while|until)[ \t]+(?:!\s*)?\([ \t]*(?:$|set[ \t]+-)")
# Closer for the multi-line form: `)` (optionally `; then` / `; do`) at line start.
CLOSER = re.compile(r"^[ \t]*\)[ \t]*(?:;[ \t]*(?:then|do)[ \t]*)?$")
ERREXIT = re.compile(r"^[ \t]*set[ \t]+(?:-[A-Za-z]*e[A-Za-z]*\b|-o[ \t]+errexit\b)")

offenders, scanned = [], 0
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.test.sh")):
    lines = path.read_text(encoding="utf-8").split("\n")
    for number, line in enumerate(lines, 1):
        if not OPENER.search(line):
            continue
        scanned += 1
        if ERREXIT.search(line.split("(", 1)[1]):
            offenders.append("%s:%d" % (path.name, number))
            continue
        for body in lines[number:]:
            if CLOSER.match(body):
                break
            if ERREXIT.match(body):
                offenders.append("%s:%d" % (path.name, number))
                break

# Self-test, so a detector that has stopped matching anything cannot go green on
# an empty corpus. The steady state for the real corpus is ZERO offenders, so
# vacuity cannot be measured against it the way A3 measures its own scan count.
FIXTURE = [
    "if (",                     # 1  offender: multi-line condition subshell
    "  set -euo pipefail",
    "  true",
    "); then",
    "  :",
    "fi",
    "while ( set -e; false ); do",   # 7  offender: one-line condition subshell
    "  :",
    "done",
    "(",                        # 10 clean: subshell OUTSIDE the condition
    "  set -euo pipefail",
    "  true",
    ")",
    "RC=$?",
    "if ( VAR=1 bash -c 'set -e; true' ); then",  # 15 clean: fresh child shell
    "  :",
    "fi",
]
found = []
for number, line in enumerate(FIXTURE, 1):
    if not OPENER.search(line):
        continue
    if ERREXIT.search(line.split("(", 1)[1]):
        found.append(number)
        continue
    for body in FIXTURE[number:]:
        if CLOSER.match(body):
            break
        if ERREXIT.match(body):
            found.append(number)
            break

if found != [1, 7]:
    print("SELFTEST:detector flagged %r, wanted [1, 7]" % (found,))
elif offenders:
    print("OFFENDERS:" + " ".join(offenders))
else:
    print("OK:%d" % scanned)
PY
)"
case "$A4_VERDICT" in
  OK:*)
    echo "  PASS  A4 — no condition-position subshell arms set -e (${A4_VERDICT#OK:} subshell opener(s) scanned)"
    PASS=$((PASS + 1))
    ;;
  SELFTEST:*)
    echo "  FAIL  A4 — the detector no longer detects its own fixture: ${A4_VERDICT#SELFTEST:}"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  FAIL  A4 — set -e is inert in these condition-position subshells; every assertion above the last is a no-op"
    printf '        %s\n' "${A4_VERDICT#OFFENDERS:}"
    echo "        fix:  run the subshell outside the condition, capture \$?, then test the captured status"
    FAIL=$((FAIL + 1))
    ;;
esac

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

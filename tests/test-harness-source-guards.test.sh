#!/usr/bin/env bash
# tests/test-harness-source-guards.test.sh — the home of every `tests/`-wide
# SOURCE CONVENTION, one lettered row per convention. A convention that holds
# across the whole test corpus belongs here as one scanner, not as an in-file
# guard copied into each suite that happens to obey it: the third copy is where
# duplication stops being cheaper than a scanner (issue #447).
#
#   A0  every section id printed by this file is unique, so a red row is
#       unambiguous and an out-of-file reference to an id cannot drift  (#486)
#   A1  every tests/*.test.sh that sources _lib_assert_structural.sh does so
#       with the fail-loud guard tail                                  (#209)
#   A2  no tests/*.test.sh has an undeclared ripgrep runtime dependency (#486)
#   A3  no tests/*.test.sh walks the repository root without excluding the
#       scratch worktree checkouts                                     (#445)
#   A4  python `tempfile` scratch trees created under tests/ are torn down
#       with unlink errors suppressed, so teardown cannot decide a verdict
#                                                                (#428, #447)
#   A5  no tests/*.test.sh arms `set -e` inside a subshell used as a
#       condition, where errexit is inert                        (#469, #495)
#   A6  no tests/*.test.sh binds a stub-prepend PATH that drops the host
#       $PATH behind it                                          (#521, #548)
#
# Row ids are load-bearing outside this file (docs/testing.md and the
# code-fixer-contract suites name A4 by id), which is why A0 exists: A5 above
# shipped as a SECOND row called `A4` and nothing noticed (#486).
#
# Every row scans this file too — none of them is self-exempt — so each row
# that needs a literal token assembles it at runtime. See the SELF-TRIP
# WARNING comments in A2, A3 and A4.
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

# ---------------------------------------------------------------------------
# SHARED DETECTOR PLUMBING — one interpreter resolver, one error marker, one
# scratch root, ONE trap, for every fixture-driven row in this file.
#
# Hoisted here rather than declared per row because `trap … EXIT` is
# LAST-WRITE-WINS, not additive: a second `trap 'rm -rf "$A2_TMPD"' EXIT`
# installed by the A2 block below would be silently REPLACED by A4's trap
# further down, and the A2 scratch tree would leak on every run with nothing
# in the output to say so. One root plus one trap makes that unrepresentable.
# ---------------------------------------------------------------------------

# Windows Git Bash ships `python`, not `python3`; ubuntu-latest ships both.
# Mirrors the portable resolver in tests/contract-markers.test.sh:50-58.
# Hardcoding `python3` is how a guard can pass VACUOUSLY on a host that lacks
# it (issue #486 — that is exactly what row A2 did), so an unresolvable
# interpreter must reach a DETECTOR-ERROR arm and never silence.
if GUARD_PY="$(command -v python3 2>/dev/null)" && [ -n "$GUARD_PY" ]; then
  :
elif GUARD_PY="$(command -v python 2>/dev/null)" && [ -n "$GUARD_PY" ]; then
  :
else
  GUARD_PY=""
fi

# The marker a detector wrapper prints INSTEAD of facts when it could not run.
# Parsed into a `*_ERROR` global, which the owning row turns into a FAIL.
_GUARD_ERR_MARK='DETECTOR-ERROR: '

# The single scratch root, and this file's ONLY trap.
if ! GUARD_TMPD="$(mktemp -d)"; then
  echo "FATAL: mktemp -d failed; the fixture-driven arms cannot run" >&2
  exit 2
fi
trap 'rm -rf "$GUARD_TMPD"' EXIT

# ---------------------------------------------------------------------------
# A0 (#486) — every section id this file prints must be unique.
#
# Row ids are the handle everything downstream uses: CI log triage, the header
# index at the top of this file, and out-of-file references
# (plugins/uberdev/docs/testing.md, tests/code-fixer-contract.test.sh). Two
# rows printing the same id makes "row A4 is red" ambiguous and makes an
# out-of-file reference silently point at the wrong predicate — which is
# precisely what happened when #469's condition-position row was added under
# the id #447 had already taken.
#
# Implementation notes, all load-bearing:
#   * ids are read through PROCESS SUBSTITUTION, never a pipe — this file sets
#     pipefail and tests/epipe-guard.test.sh scans it.
#   * duplicate detection is a padded-haystack `case`, not `sort | uniq -d`:
#     no pipeline, no second reader, and it works identically under bash and
#     zsh.
#   * the vacuity arm below is not optional. A uniqueness check over an empty
#     set is green by construction, which is the same blind-green shape the
#     rest of this file exists to prevent.
echo "== A0: every section id printed by this file is unique =="
A0_SEEN=" "
A0_DUPES=""
A0_IDS=0
while IFS= read -r a0_line; do
  [ -n "$a0_line" ] || continue
  # `echo "== A4: …` -> `A4`
  a0_id="${a0_line#*== }"
  a0_id="${a0_id%%:*}"
  [ -n "$a0_id" ] || continue
  A0_IDS=$((A0_IDS + 1))
  case "$A0_SEEN" in
    *" $a0_id "*) A0_DUPES="$A0_DUPES $a0_id" ;;
  esac
  A0_SEEN="$A0_SEEN$a0_id "
done < <(grep -E '^echo "== [A-Za-z][0-9]+[a-z]?:' "$0")

if [ "$A0_IDS" -eq 0 ]; then
  echo "  FAIL  A0 the id extractor matched no section headers — the guard cannot red (vacuous)"
  echo "        Either the header form drifted from \`echo \"== <id>: …\"\`, or \$0 is unreadable."
  FAIL=$((FAIL + 1))
elif [ -n "$A0_DUPES" ]; then
  echo "  FAIL  A0 duplicate section id:$A0_DUPES"
  echo "        Two rows print the same id, so a red row is ambiguous in the CI log and any"
  echo "        out-of-file reference to that id points at whichever predicate you did not mean."
  echo "        fix:    give the newer row the next free letter+digit and update the header index"
  FAIL=$((FAIL + 1))
else
  a0_list="${A0_SEEN# }"
  echo "  PASS  A0 all $A0_IDS section ids are unique (${a0_list% })"
  PASS=$((PASS + 1))
fi

echo
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
echo "== A2: no tests/*.test.sh has an undeclared ripgrep runtime dependency =="
# Issue #486. The shipped form of this row enforced almost nothing, twice over:
# its needle was over-escaped (inside a `<<'PY'` heredoc a raw-string `\\s` is a
# LITERAL backslash and the letter `s`, not whitespace, so only a bare command
# alone on a line could ever match), and it hardcoded `python3`, so on a host
# without that name the capture came back empty and the row printed PASS having
# scanned nothing. Both halves are now proven in-suite, in both polarities, on
# every run: A2.1 flags seven real invocation shapes; A2.2 spares seven
# non-invocation shapes (A2.2a-g) PLUS one real invocation that is spared only
# because it sits outside the scanned corpus (A2.2h) — two different reasons for
# a clean result, and folding them into one count hides the corpus boundary this
# header documents; A2.3 proves a broken interpreter FAILs instead of silencing.
#
# DECLARED BOUNDARY — what this row does NOT cover, written down rather than
# left implied (the #370 / RFC 0016 shape, where a guard's name promises more
# than its predicate delivers):
#   * CORPUS is `tests/*.test.sh`, NON-RECURSIVE. Not tests/_lib_*.sh, not
#     tests/*.py, not tests/manual/*.sh, not plugins/uberdev/lib/*.sh, not the
#     extension-less shipped hooks, not .github/workflows/*.yml. Widening the
#     corpus is a deliberate change with its own floor and sentinel updates.
#   * A WHOLE-LINE `#` comment is not a site (prose about the tool must stay
#     writable). A TRAILING comment on a code line IS a site — a live
#     invocation does not stop being one because a comment follows it.
#   * A PROBE — `command -v` / `which` / `hash` / `type` followed by the
#     command — is a DECLARED dependency, i.e. the opposite of what this row
#     polices, so it is excluded. Zero such lines exist today; the exclusion is
#     forward-looking, so writing the guard is never punished.
#
# SELF-TRIP WARNING: this file is a tests/*.test.sh and IS inside A2's own
# corpus — it is not self-exempt (A2.5 proves it). Never write the needle
# contiguously anywhere in this file, in fixture bodies, FAIL messages or
# trailing comments: after a space, `|`, `;`, `&`, `(`, `)` or a backtick it is
# a site and this row would report itself. It is assembled from fragments into
# $_A2_CMD below and interpolated wherever it is needed. The word "ripgrep" is
# safe — it contains no contiguous occurrence of the two-character command.
_A2_CMD='r''g'

# UBERDEV_A2_PY_OVERRIDE mirrors UBERDEV_A4_PY_OVERRIDE: it lets an operator pin
# the interpreter, and A2.3 drives it to prove the error arm is live.
A2_PY="${UBERDEV_A2_PY_OVERRIDE:-$GUARD_PY}"

# The detector emits PURE FACTS, no policy: floors, sentinel rules and messages
# all live in bash below, so A2.1/A2.2 can reuse it against small fixture
# corpora without tripping the 100-file floor.
#
#   FILES <n>
#   HIT <basename>:<lineno>:<stripped line>
#   SENTINEL <basename> <hit-count>          (-1 = not in the corpus at all)
#
# `FILES <n>` is emitted unconditionally, so an empty report unambiguously means
# the detector died and can never be read as "clean".
A2_DETECTOR="$(cat <<'PY'
import pathlib
import re
import sys

directory = pathlib.Path(sys.argv[1])
sentinels = [name for name in sys.argv[2].split(",") if name] if len(sys.argv) > 2 else []

# Assembled from fragments: the host guard lives inside its own corpus, so a
# contiguous literal here would make A2 report the guard itself.
command = "r" + "g"
# SINGLE backslashes: this heredoc is `<<'PY'`, so python receives these bytes
# verbatim. The shipped form doubled them, which in a RAW string is a literal
# backslash plus the letter `s` — a character class of `[;&|()\s]` members, not
# whitespace — so no invocation followed by a space could ever match (#486).
# A backtick joins the delimiter class as well, or an invocation opening a
# backtick substitution would slip through (A2.1g pins that shape).
pattern = re.compile(r"(^|[;&|()`\s])" + command + r"(?=\s|$)")
# A `command -v` / `which` / `hash` / `type` guard is a DECLARED dependency —
# the opposite of what this row polices — so it is skipped before the site test.
probe = re.compile(r"\b(?:command\s+-v|which|hash|type)\s+" + command + r"\b")

# No self-exclusion: the guard is inside the corpus it scans (A2.5 asserts it).
corpus = sorted(directory.glob("*.test.sh"))
out = ["FILES %d" % len(corpus)]
per_file = dict((path.name, 0) for path in corpus)
for path in corpus:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        if probe.search(line):
            continue
        if pattern.search(line):
            per_file[path.name] += 1
            out.append("HIT %s:%d:%s" % (path.name, number, line.strip()))
for name in sentinels:
    out.append("SENTINEL %s %d" % (name, per_file.get(name, -1)))
print("\n".join(out))
PY
)"

# _a2_scan CORPUS_DIR [SENTINEL_CSV] -> the fact records, or one DETECTOR-ERROR
# line. Never a pipe on the consuming side: this file sets pipefail and
# tests/epipe-guard.test.sh scans it, so every reader below is a herestring.
_a2_scan() {
  local _dir="$1" _sentinels="${2:-}" _out
  if [ -z "$A2_PY" ]; then
    printf '%sno python3/python interpreter resolved (PATH, or an empty override)\n' "$_GUARD_ERR_MARK"
    return 0
  fi
  if ! _out="$("$A2_PY" -I -c "$A2_DETECTOR" "$_dir" "$_sentinels" 2>/dev/null)"; then
    printf '%sinterpreter %s exited non-zero while scanning %s\n' "$_GUARD_ERR_MARK" "$A2_PY" "$_dir"
    return 0
  fi
  if [ -z "$_out" ]; then
    printf '%sdetector produced no output while scanning %s\n' "$_GUARD_ERR_MARK" "$_dir"
    return 0
  fi
  printf '%s\n' "$_out"
}

# _a2_parse REPORT — populates the A2_* globals. Globals rather than a subshell,
# because the parsed facts (and the PASS/FAIL counters the arms bump) must
# survive back into the caller.
_a2_parse() {
  A2_FILES=-1
  A2_HITS=""
  A2_HIT_COUNT=0
  A2_HIT_NAMES=" "
  A2_SENTINEL_ROWS=""
  A2_ERROR=""
  local _line _row _name
  while IFS= read -r _line; do
    # Strip the trailing CR at the single reader. Native-Windows python writes
    # CRLF and MSYS `$(...)` eats only the LAST one, so every line but the last
    # keeps its CR — see the full write-up on _a4_parse below, which carries the
    # measured proof. A no-op on LF input.
    _line="${_line%$'\r'}"
    [ -n "$_line" ] || continue
    case "$_line" in
      "$_GUARD_ERR_MARK"*) A2_ERROR="${_line#"$_GUARD_ERR_MARK"}" ;;
      "FILES "*)           A2_FILES="${_line#FILES }" ;;
      "HIT "*)
        _row="${_line#HIT }"
        A2_HITS="${A2_HITS}${_row}"$'\n'
        A2_HIT_COUNT=$((A2_HIT_COUNT + 1))
        _name="${_row%%:*}"
        A2_HIT_NAMES="${A2_HIT_NAMES}${_name} "
        ;;
      "SENTINEL "*)        A2_SENTINEL_ROWS="${A2_SENTINEL_ROWS}${_line#SENTINEL }"$'\n' ;;
    esac
  done <<<"$1"
}

A2_FILE_FLOOR=100

# --- A2.0 the real corpus ----------------------------------------------------
# The sentinel CSV is this file's own basename, so A2.5 below can read the
# self-scan result out of THIS launch rather than paying for a second one.
_a2_parse "$(_a2_scan "$TESTS_DIR" "$(basename "$0")")"
# The fixture arms reuse the same globals, so pin the real-corpus facts now.
A2_REAL_FILES="$A2_FILES"
A2_REAL_SENTINELS="$A2_SENTINEL_ROWS"

if [ -n "$A2_ERROR" ]; then
  echo "  FAIL  A2.0 the detector could not run, so NOTHING was checked"
  echo "        cause:  $A2_ERROR"
  echo "        fix:    put python3 (or python) on PATH, or point UBERDEV_A2_PY_OVERRIDE at one"
  FAIL=$((FAIL + 1))
elif [ "$A2_HIT_COUNT" -gt 0 ]; then
  echo "  FAIL  A2.0 $A2_HIT_COUNT tests/*.test.sh line(s) invoke the tool without declaring it"
  while IFS= read -r a2_row; do
    [ -n "$a2_row" ] || continue
    printf '        %s\n' "$a2_row"
  done <<<"$A2_HITS"
  echo "        fix:    use a portable text tool (grep -E, awk), or guard the call with"
  echo "                \`command -v\` and install the tool in the workflow that needs it"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  A2.0 no tests/*.test.sh invokes the tool ($A2_REAL_FILES files scanned)"
  PASS=$((PASS + 1))
fi

# --- A2.1 / A2.2: the detector actually detects — both polarities, in-suite ---
# A guard whose RED path is only ever proven by hand is not proven. The
# committed precedents are A4.4 below and tests/epipe-guard.test.sh E2.
#
# Fixture corpora live under GUARD_TMPD, OUTSIDE tests/, so a fixture holding a
# genuine invocation cannot become a real A2 violation and cannot perturb A4's
# FILES/FACTORIES floors. Every body is assembled at RUNTIME from $_A2_CMD and
# written with plain `printf ... >file` redirection; never `printf ... | grep
# -q`, which reds tests/epipe-guard.test.sh (known class).

# _a2_corpus NAME -> a fresh, empty fixture corpus directory, printed on stdout.
_a2_corpus() {
  local _d="$GUARD_TMPD/$1"
  mkdir -p "$_d"
  printf '%s' "$_d"
}

# _a2_expect_flagged ID BASENAME / _a2_expect_clean ID BASENAME — read the
# already-parsed globals and emit one verdict line each. Deliberately not fed
# from a pipe and not run in a condition-position subshell: the PASS/FAIL
# counters are plain globals and would never make it back out of either.
_a2_expect_flagged() {
  local _id="$1" _base="$2" _what="$3"
  case "$A2_HIT_NAMES" in
    *" $_base "*)
      echo "  PASS  $_id $_base ($_what) is flagged"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL  $_id $_base ($_what) holds a real invocation and was NOT flagged"
      echo "        The needle is blind to that shape, so this row cannot police it."
      FAIL=$((FAIL + 1))
      ;;
  esac
}

_a2_expect_clean() {
  local _id="$1" _base="$2" _what="$3"
  case "$A2_HIT_NAMES" in
    *" $_base "*)
      echo "  FAIL  $_id $_base ($_what) is not an invocation but was flagged — false positive"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "  PASS  $_id $_base ($_what) is correctly not flagged"
      PASS=$((PASS + 1))
      ;;
  esac
}

A2_DIR_FLAG="$(_a2_corpus a2-flag)"
printf '  %s -n '"'"'pat'"'"' file.txt\n' "$_A2_CMD" >"$A2_DIR_FLAG/ws.test.sh"
printf 'cat x | %s foo\n'                 "$_A2_CMD" >"$A2_DIR_FLAG/pipe.test.sh"
printf 'if %s -q pat; then\n'             "$_A2_CMD" >"$A2_DIR_FLAG/keyword.test.sh"
printf 'out=$(%s -l pat)\n'               "$_A2_CMD" >"$A2_DIR_FLAG/cmdsub.test.sh"
printf 'false && %s bar\n'                "$_A2_CMD" >"$A2_DIR_FLAG/andlist.test.sh"
printf '%s\n'                             "$_A2_CMD" >"$A2_DIR_FLAG/bare.test.sh"
printf 'x=`%s -l pat`\n'                  "$_A2_CMD" >"$A2_DIR_FLAG/backtick.test.sh"

_a2_parse "$(_a2_scan "$A2_DIR_FLAG")"
if [ -n "$A2_ERROR" ]; then
  echo "  FAIL  A2.1 the detector could not run against the must-flag corpus: $A2_ERROR"
  FAIL=$((FAIL + 1))
else
  _a2_expect_flagged "A2.1a" "ws.test.sh"       "leading whitespace, flags and a pattern"
  _a2_expect_flagged "A2.1b" "pipe.test.sh"     "right-hand side of a pipeline"
  _a2_expect_flagged "A2.1c" "keyword.test.sh"  "condition of an if"
  _a2_expect_flagged "A2.1d" "cmdsub.test.sh"   "inside a \$( ) command substitution"
  _a2_expect_flagged "A2.1e" "andlist.test.sh"  "right-hand side of an AND list"
  _a2_expect_flagged "A2.1f" "bare.test.sh"     "bare, alone on the line"
  _a2_expect_flagged "A2.1g" "backtick.test.sh" "inside a backtick substitution"
  if [ "$A2_HIT_COUNT" -eq 7 ] && [ "$A2_FILES" -eq 7 ]; then
    echo "  PASS  A2.1h the must-flag corpus produced exactly 7 hits over 7 files"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A2.1h the must-flag corpus produced $A2_HIT_COUNT hit(s) over $A2_FILES file(s), want 7/7"
    echo "        A blind shape and a double-matching shape cancel out in a bare total, so this"
    echo "        exactness backstop sits behind the per-file arms rather than replacing them."
    FAIL=$((FAIL + 1))
  fi
fi

# The must-NOT-flag side. Without it a needle could go green by flagging
# everything, which is the same unfalsifiable shape as flagging nothing.
# `notes.sh` carries a genuine invocation under the wrong extension, so it also
# proves the `*.test.sh` glob is the corpus boundary rather than a formality.
A2_DIR_CLEAN="$(_a2_corpus a2-clean)"
printf 'echo "ripgrep is not installed"\n'            >"$A2_DIR_CLEAN/prose.test.sh"
printf 'foo --%s bar\n'          "$_A2_CMD"           >"$A2_DIR_CLEAN/longflag.test.sh"
printf 'my%s -n pat\n%s_helper x\n' "$_A2_CMD" "$_A2_CMD" >"$A2_DIR_CLEAN/prefix.test.sh"
printf 'config.%s\n'             "$_A2_CMD"           >"$A2_DIR_CLEAN/dotted.test.sh"
printf '# %s -n pat file\n'      "$_A2_CMD"           >"$A2_DIR_CLEAN/comment.test.sh"
printf '_C='"'"'%s'"'"''"'"'%s'"'"'\n' "${_A2_CMD%?}" "${_A2_CMD#?}" >"$A2_DIR_CLEAN/fragment.test.sh"
printf 'command -v %s >/dev/null\n' "$_A2_CMD"        >"$A2_DIR_CLEAN/probe.test.sh"
printf '  %s -n '"'"'pat'"'"' file.txt\n' "$_A2_CMD"  >"$A2_DIR_CLEAN/notes.sh"

_a2_parse "$(_a2_scan "$A2_DIR_CLEAN")"
if [ -n "$A2_ERROR" ]; then
  echo "  FAIL  A2.2 the detector could not run against the must-not-flag corpus: $A2_ERROR"
  FAIL=$((FAIL + 1))
else
  _a2_expect_clean "A2.2a" "prose.test.sh"    "prose naming the tool in full"
  _a2_expect_clean "A2.2b" "longflag.test.sh" "a long flag that ends in the command name"
  _a2_expect_clean "A2.2c" "prefix.test.sh"   "a longer command with the name as a substring"
  _a2_expect_clean "A2.2d" "dotted.test.sh"   "a dotted attribute reference"
  _a2_expect_clean "A2.2e" "comment.test.sh"  "a whole-line comment"
  _a2_expect_clean "A2.2f" "fragment.test.sh" "the name assembled from fragments"
  _a2_expect_clean "A2.2g" "probe.test.sh"    "a command -v probe, i.e. a declared dependency"
  if [ "$A2_FILES" -eq 7 ] && [ "$A2_HIT_COUNT" -eq 0 ]; then
    echo "  PASS  A2.2h notes.sh holds a real invocation but is outside the *.test.sh corpus (7 files scanned, 0 hits)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  A2.2h the must-not-flag corpus scanned $A2_FILES file(s) with $A2_HIT_COUNT hit(s), want 7/0"
    echo "        8 files were written and one is notes.sh, so a count of 8 means the corpus glob"
    echo "        widened past *.test.sh and the declared boundary above is no longer true."
    FAIL=$((FAIL + 1))
  fi
fi

# --- A2.3 the detector-error arm ---------------------------------------------
# A detector that cannot RUN must not read as "nothing found" — the #486 defect
# in one line. Drive the same variable UBERDEV_A2_PY_OVERRIDE writes, both ways:
# an interpreter that does not exist, and no interpreter at all.
A2_SAVED_PY="$A2_PY"
A2_PY="$GUARD_TMPD/nonexistent-interpreter"
A2_H_BOGUS="$(_a2_scan "$A2_DIR_FLAG")"
A2_PY=""
A2_H_EMPTY="$(_a2_scan "$A2_DIR_FLAG")"
A2_PY="$A2_SAVED_PY"
_a2_parse "$A2_H_BOGUS"; A2_H_BOGUS_ERR="$A2_ERROR"
_a2_parse "$A2_H_EMPTY"; A2_H_EMPTY_ERR="$A2_ERROR"
if [ -n "$A2_H_BOGUS" ] && [ -n "$A2_H_BOGUS_ERR" ] && [ -n "$A2_H_EMPTY" ] && [ -n "$A2_H_EMPTY_ERR" ]; then
  echo "  PASS  A2.3 an unrunnable interpreter reports an error, not 'clean' (both bogus-path and unresolved)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A2.3 a broken interpreter returned bogus='$A2_H_BOGUS' unresolved='$A2_H_EMPTY' — A2 would go vacuously green"
  FAIL=$((FAIL + 1))
fi

# --- A2.4 corpus reach --------------------------------------------------------
# Parity, not the floor, is what catches an MSYS path-rewrite or a glob
# regression: both numbers move together under a real corpus change, and apart
# only when the detector stopped seeing what the shell can see.
A2_GLOB_COUNT=0
for a2_f in "$TESTS_DIR"/*.test.sh; do
  [ -e "$a2_f" ] || continue
  A2_GLOB_COUNT=$((A2_GLOB_COUNT + 1))
done
if [ "$A2_REAL_FILES" -eq "$A2_GLOB_COUNT" ]; then
  echo "  PASS  A2.4a the detector saw every tests/*.test.sh (detector $A2_REAL_FILES, shell glob $A2_GLOB_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A2.4a corpus parity broke: detector saw $A2_REAL_FILES, the shell glob sees $A2_GLOB_COUNT"
  echo "        Either the corpus glob regressed, or the directory argument did not survive"
  echo "        the MSYS POSIX-to-Windows path rewrite on its way to a native interpreter."
  FAIL=$((FAIL + 1))
fi

if [ "$A2_REAL_FILES" -ge "$A2_FILE_FLOOR" ]; then
  echo "  PASS  A2.4b files scanned: $A2_REAL_FILES (floor $A2_FILE_FLOOR)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  A2.4b scanned only $A2_REAL_FILES tests/*.test.sh (floor $A2_FILE_FLOOR) — the corpus glob regressed"
  echo "        A scanner that matches almost nothing cannot red (the #430 class)."
  FAIL=$((FAIL + 1))
fi

# --- A2.5 self-scan -----------------------------------------------------------
# Two halves from ONE sentinel row, read out of A2.0's launch:
#   count >= 0  -> this file IS inside its own corpus (not self-exempt), which
#                  is what makes the header claim at the top of this file true;
#   count == 0  -> this file carries no needle in a SITE position.
# Deliberately NOT the `grep -cF` substring self-scan A4.4i uses. A4's needles
# are long literals; A2's is two characters, and it occurs harmlessly inside
# ordinary words all over this file (`sys.argv`, `worktree`, `target`,
# `argument`, `large`) — a substring count here could only ever be a false
# alarm. The sentinel asks the real question: does the DETECTOR, run over its
# real corpus, find a site in this file? That is strictly stronger.
a2_self_count=-2
while IFS= read -r a2_row; do
  [ -n "$a2_row" ] || continue
  a2_self_count="${a2_row##* }"
done <<<"$A2_REAL_SENTINELS"
if [ "$a2_self_count" -lt 0 ]; then
  echo "  FAIL  A2.5 self-scan: not-in-own-corpus($a2_self_count) — this guard is exempt from its own rule"
  echo "        The sentinel row never came back, so \$0 is outside the corpus or the launch died."
  FAIL=$((FAIL + 1))
elif [ "$a2_self_count" -gt 0 ]; then
  echo "  FAIL  A2.5 self-scan: this guard carries $a2_self_count site(s) of its own needle"
  echo "        Assemble it from \$_A2_CMD instead — see the SELF-TRIP WARNING above."
  FAIL=$((FAIL + 1))
else
  echo "  PASS  A2.5 this guard is inside its own corpus (not self-exempt) and carries no site of its own needle"
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

# The portable interpreter (resolved once, up in SHARED DETECTOR PLUMBING).
# UBERDEV_A4_PY_OVERRIDE lets an operator pin it (e.g. reproduce Git Bash
# locally); A4.4h drives the same variable to prove the error arm is live.
A4_PY="${UBERDEV_A4_PY_OVERRIDE:-$GUARD_PY}"

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
    printf '%sno python3/python interpreter resolved (PATH, or an empty override)\n' "$_GUARD_ERR_MARK"
    return 0
  fi
  if ! _out="$("$A4_PY" -I -c "$A4_DETECTOR" "$_dir" "$_sentinels" 2>/dev/null)"; then
    printf '%sinterpreter %s exited non-zero while scanning %s\n' "$_GUARD_ERR_MARK" "$A4_PY" "$_dir"
    return 0
  fi
  if [ -z "$_out" ]; then
    printf '%sdetector produced no output while scanning %s\n' "$_GUARD_ERR_MARK" "$_dir"
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
      "$_GUARD_ERR_MARK"*) A4_ERROR="${_line#"$_GUARD_ERR_MARK"}" ;;
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
#
# The scratch root and the EXIT trap live once, up in SHARED DETECTOR PLUMBING:
# traps are last-write-wins, so a second `trap … EXIT` here would silently void
# the first and leak whichever tree it was meant to remove.
A4_TMPD="$GUARD_TMPD/a4"
if ! mkdir -p "$A4_TMPD"; then
  echo "FATAL: could not create $A4_TMPD; A4.4 cannot build its fixture corpora" >&2
  exit 2
fi

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
echo "== A5: no tests/*.test.sh arms set -e inside a subshell used as a condition =="
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
A5_VERDICT="$(python3 -I - "$TESTS_DIR" <<'PY'
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
case "$A5_VERDICT" in
  OK:*)
    echo "  PASS  A5 — no condition-position subshell arms set -e (${A5_VERDICT#OK:} subshell opener(s) scanned)"
    PASS=$((PASS + 1))
    ;;
  SELFTEST:*)
    echo "  FAIL  A5 — the detector no longer detects its own fixture: ${A5_VERDICT#SELFTEST:}"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  FAIL  A5 — set -e is inert in these condition-position subshells; every assertion above the last is a no-op"
    printf '        %s\n' "${A5_VERDICT#OFFENDERS:}"
    echo "        fix:  run the subshell outside the condition, capture \$?, then test the captured status"
    FAIL=$((FAIL + 1))
    ;;
esac

echo
echo "== A6: no tests/*.test.sh binds a stub-prepend PATH that drops the host \$PATH =="
# Issues #521 and #548. A fixture that builds a stub bin and then binds the
# runtime PATH its dispatch runs under to "$TMP/bin:/usr/bin:/bin" does not
# merely pin the environment — it DELETES every other directory a host installs
# coreutils into. On a host whose `timeout` lives outside those two directories
# (Darwin: /opt/homebrew/bin) `_uberdev_dispatch_preflight_timeout_bin` in
# plugins/uberdev/lib/dispatch.sh then resolves nothing, so the fixture silently
# drives the UNBOUNDED preflight arm while ubuntu drives the bounded one:
# different production code, and every other verdict in the fixture is
# byte-identical on both arms, so nothing reds. #521 fixed the literal at one
# site and left no detector; #548 was the same defect at three more. Per this
# file's header, that is where a scanner replaces the per-suite copy.
#
# DECLARED BOUNDARY — what is, and is not, a site:
#   * the corpus is tests/*.test.sh, NON-RECURSIVE (the glob below), as in
#     A2-A5.
#   * a whole-line `#` comment is NOT a site, so prose about the old literal
#     stays writable — the same corpus boundary A2 declares, and what spares
#     the narrating comments in child-dispatch.test.sh and run-manifest.test.sh.
#   * an APPEND (`VAR="$VAR:…"` — colon, no slash, after the name) is not a
#     prepend and is not a site: it preserves whatever the left-hand side held.
#     review-pr-consolidate.test.sh's SCAN_PATH is that shape.
#   * `env -i PATH=…` (review-pr.test.sh) and python `env={'PATH': …}` dict
#     literals (prkit-generate.test.sh) are deliberate HERMETIC environments,
#     not stub-dir prepends, and fall outside the predicate by shape.
#   * this row bans ONE shape. It is not a general claim that every fixture
#     environment in the corpus is honest.
#
# SELF-TRIP WARNING: this file is inside the corpus it scans, so the pinned
# literal the self-test fixture needs is assembled at runtime and never written
# contiguously in an assignment here — as A2, A3 and A4 do for their needles.
A6_VERDICT="$(python3 -I - "$TESTS_DIR" <<'PY'
import pathlib, re, sys

# A shell assignment — standalone or command-env-prefix — whose value opens with
# an expansion-rooted directory segment: VAR="$SOMEVAR/<seg>:…".
# Keyed on the `$VAR/` prefix, NOT on the directory being named `bin`: the #521
# donor's stub dir is `background-timeout-bin` and review-pr.test.sh uses
# `shim`, and a guard that misses the site it exists to protect is worse than
# none. The `/` is also what separates a PREPEND from an APPEND ("$VAR:…").
ASSIGN = re.compile(r'(?:^|[\s;(])([A-Za-z_][A-Za-z0-9_]*)="(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/[^"]*)"')
BRACED = re.compile(r'\$\{[^}]*\}')

def is_path_list(value):
    # Brace expansions are masked first so `${x:-y}` colons cannot fake a segment.
    segments = BRACED.sub("$V", value).split(":")
    return len(segments) >= 2 and all(s[:1] in ("/", "$") and " " not in s for s in segments)

def preserves_host_path(value):
    return "$PATH" in value or "${PATH}" in value

def scan(lines):
    candidates, offenders = 0, []
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        for match in ASSIGN.finditer(line):
            value = match.group(2)
            if not is_path_list(value):
                continue
            candidates += 1
            if not preserves_host_path(value):
                offenders.append((number, match.group(1)))
    return candidates, offenders

corpus_candidates, corpus_offenders = 0, []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.test.sh")):
    count, hits = scan(path.read_text(encoding="utf-8").split("\n"))
    corpus_candidates += count
    corpus_offenders += ["%s:%d %s" % (path.name, n, v) for n, v in hits]

# SELF-TRIP WARNING: assembled, never contiguous — this file is in the corpus.
STUB = '"$FIXTURE_TMP/stub-bin:'
PINNED = "/usr" + "/bin:" + "/bin"
FIXTURE = [
    "A_PATH=" + STUB + PINNED + '"',                   # 1 offender: the #548 shape
    "B_PATH=" + STUB + "$PATH:" + PINNED + '"',        # 2 clean: widened tail form
    "C_PATH=" + STUB + "$PATH" + '"',                  # 3 clean: the #521 donor form
    "# prose about the old " + PINNED + " literal",    # 4 clean: whole-line comment
    'D_PATH="$D_PATH:' + PINNED + ':/usr/local/bin"',  # 5 clean: append, preserves LHS
    "E_PATH=" + '"$E_TMP/shim:' + PINNED + '"',        # 6 offender: stub dir not named bin
]
_, self_hits = scan(FIXTURE)
found = [n for n, _ in self_hits]

if found != [1, 6]:
    print("SELFTEST:detector flagged %r, wanted [1, 6]" % (found,))
elif corpus_candidates == 0:
    print("VACUOUS:0")
elif corpus_offenders:
    print("OFFENDERS:" + " ".join(corpus_offenders))
else:
    print("OK:%d" % corpus_candidates)
PY
)"
# Four arms, every one of them scored through this file's PASS/FAIL counters.
# The vacuity denominator is CANDIDATE stub-prepend bindings, not offenders:
# the steady state for offenders is zero, so — exactly as A5 records — a
# zero-offender corpus cannot tell a clean repo from a detector that stopped
# matching. The `SELFTEST:` arm is the primary anti-rot device; `VACUOUS:0`
# catches the corpus glob or the assignment shape drifting out from under it.
# An empty verdict (no interpreter, or the scanner died) reaches the catch-all
# and FAILs too — a detector that could not run is never "clean".
case "$A6_VERDICT" in
  OK:*)
    echo "  PASS  A6 — every stub-prepend PATH binding keeps the host \$PATH (${A6_VERDICT#OK:} binding(s) scanned)"
    PASS=$((PASS + 1))
    ;;
  SELFTEST:*)
    echo "  FAIL  A6 — the detector no longer detects its own fixture: ${A6_VERDICT#SELFTEST:}"
    FAIL=$((FAIL + 1))
    ;;
  VACUOUS:0)
    echo "  FAIL  A6 — the scanner matched no stub-prepend PATH binding at all, so the row cannot red"
    echo "        Either the tests/*.test.sh glob or the assignment shape drifted out from under the detector."
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo "  FAIL  A6 — these bindings drop the host \$PATH behind a stub dir, so the code they drive is chosen by the host, not by the fixture"
    printf '        %s\n' "${A6_VERDICT#OFFENDERS:}"
    echo "        fix:  keep the host \$PATH behind the stub dir — \"\$TMP/bin:\$PATH…\" (precedent: child-dispatch.test.sh:1043)"
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

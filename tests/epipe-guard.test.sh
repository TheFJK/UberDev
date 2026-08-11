#!/usr/bin/env bash
# tests/epipe-guard.test.sh — issue #313, the class fix the M49.1 patch never
# generalised.
#
# ROOT CAUSE. Under `set -o pipefail`, a pipeline whose reader can exit BEFORE
# its writer is done writing is a RACE, not a test:
#
#     <anything> | <early-exiting reader>
#
# The reader (`grep -q`, `grep -m N`, `grep -l`, `head`, `read`) exits the
# instant it has what it needs and closes the read end of the pipe. The writer's
# remaining chunked writes then take EPIPE. On a normal interactive shell the
# writer dies by SIGPIPE and bash reports the pipeline's rc from the LAST
# command (rc=0) — so the bug is invisible locally. On GitHub Actions the Node
# runner starts the job shell with SIGPIPE ignored, and an ignored disposition
# is inherited across fork/exec, so the writer does NOT die: it returns rc=1
# with `write error: Broken pipe`, and pipefail promotes that 1 over the
# reader's 0. The pipeline's rc is poisoned even though the reader succeeded,
# and it is poisoned more often the earlier the reader exits and the bigger the
# payload.
#
# Reproduced deterministically with `trap "" PIPE` + pipefail + a 200 KB payload
# whose match is in the first chunk. EVERY reader in the set below was measured,
# not assumed — 20 iterations each, piped form vs herestring form:
#
#     printf | grep -q    20/20 false-nonzero      grep -q  <<<   0/20
#     printf | grep -m1   20/20 false-nonzero      grep -m1 <<<   0/20
#     printf | head -1    20/20 false-nonzero      head -1  <<<   0/20
#     printf | read       20/20 false-nonzero      read     <<<   0/20
#
# `head`, `read` and `grep -m` poison the rc exactly as reliably as `grep -q`,
# which is why a detector that knew only `grep -q` was not a detector for this
# class. The herestring feeds the reader from a temp file — there is no writer
# process, so there is no rc for pipefail to poison.
#
# INVERTED POLARITY is the worse half: written as `<writer> | grep -q BAD && fail`,
# an EPIPE after a MATCH makes the pipeline rc non-zero, the `&&` short-circuits,
# and a genuine defect is reported as a PASS. That shape masks failures instead
# of inventing them.
#
# ---------------------------------------------------------------------------
# RISK MODEL — when a poisoned rc is actually a DEFECT.
#
# The EPIPE poisons the PIPELINE'S EXIT STATUS. It never corrupts the reader's
# stdout. So the poisoning is a defect exactly when the shell CONSUMES that
# exit status:
#
#   (a) as a truth value — `if PIPE`, `PIPE && ...`, `PIPE || fail ...`,
#       `! PIPE`, `while PIPE`, or a bare statement (including one inside a
#       `ck`/`check`/`expect` string, which this suite `eval`s); or
#   (b) implicitly, under `set -e`, where a poisoned rc on an assignment
#       `X=$(... | head -1)` aborts the whole run.
#
# It is NOT a defect when the pipeline sits inside `$( ... )` purely to produce
# a VALUE, in a file that does not `set -e`: the substitution's rc is discarded
# and the captured text is unaffected. Flagging that shape would be syntax
# policing, not risk control, so this guard deliberately does not.
#
# ---------------------------------------------------------------------------
# WHAT IS FLAGGED. A pipe token immediately followed by an early-exiting reader,
# on a LOGICAL line (backslash continuations and trailing-pipe continuations are
# joined first), where the rc is consumed per the risk model above:
#
#   * ANY writer on the left — `echo`, `printf`, `cat`, `jq`, `sed`, `awk`,
#     `git`, `find`, `python3`, a shell function, a command substitution.
#     The left-hand side is completely unconstrained; that is the point.
#   * ANY declared early-exiting reader on the right — `grep` with a `-q`/`-l`/
#     `-L`/`-m` bundle or the `--quiet`/`--silent`/`--files-with-matches`/
#     `--files-without-match`/`--max-count` long forms, `head`, `read`
#     (optionally behind a `{ ` group opener).
#   * ANY position in the pipeline — a reader in the middle poisons the rc just
#     as a reader at the end does.
#
# DECLARED BOUNDARY — what this guard does NOT flag, and why. A narrow rule that
# is honest is worth more than a broad one that lies:
#
#   1. Value-producing `$( ... )` pipelines in files without `set -e` (rc is
#      discarded — see the risk model). Adding `set -e` to such a file makes
#      every one of them flagged on the next run; that is the intended trigger.
#   2. Draining readers — plain `grep`, `grep -c`, `grep -o`, `wc`, `sort`,
#      `tail`, `jq`, `cut`, `tr`. They read to EOF, so there is no early close.
#   3. Early exits that are not declared by command name or flag: `sed`'s `q`
#      command, `awk`'s `exit`, `python3 -c` with an early `break`, or any
#      project script that stops reading stdin. Deciding those needs the
#      script argument parsed, not matched, so they are out of scope by
#      construction rather than by oversight.
#   4. Pipes written with no whitespace on either side (`cat f|grep -q x`). The
#      whitespace requirement is what distinguishes a shell pipe operator from
#      an ERE alternation inside a quoted pattern (`assert_grep "$f" 'A|head'`),
#      where a space would be literal pattern content. Every pipeline in this
#      repo is written with the space; an unspaced one would slip through.
#   5. Markdown `bash` fences inside `skills/**/SKILL.md`. They are executed, but
#      their pipefail state is per-fence (Bash-tool calls share no shell state), so
#      file-level exposure cannot be decided the way it can for a `.sh` file.
#      Checked by hand rather than assumed: the repo's one instance,
#      `merge-pipeline/SKILL.md:700`, sits in a fence that sets NEITHER pipefail
#      nor -e, so its rc is grep's rc and it is not exposed. Re-check by hand if a
#      fence ever gains `set -o pipefail`.
#
# SCAN SET. Every tracked `*.sh` file in the repo — tests, `plugins/uberdev/lib`,
# `tools/prkit`, `install.sh` — that turns
# pipefail on. Files that do NOT set pipefail are not exposed (the pipeline's rc
# is the last command's rc) and are out of scope by construction; the day one of
# them adds `set -o pipefail`, this guard reds on every site it just exposed.
#
# Comment-only lines are skipped so the class can still be DESCRIBED in prose
# (this header does exactly that). Quoted strings are NOT skipped: several suites
# (`ck`/`check`/`expect` helpers in uberscan*.test.sh, lib-assert-count.test.sh)
# `eval` their assertion strings, so a string in this suite is executable code
# and must obey the same rule. This guard is not self-exempt — it scans itself.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$REPO_ROOT/tests" ]; then
  echo "FATAL: tests/ directory missing: $REPO_ROOT/tests" >&2
  exit 2
fi

PASS=0
FAIL=0

# A file is exposed only when it turns pipefail on: `set -o pipefail`,
# `set -euo pipefail`, and every other flag spelling of the same switch.
PIPEFAIL_RE='set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail'
# `set -e` in any spelling (`set -e`, `set -eu`, `set -euo pipefail`), at the
# start of a line so a `-e` inside prose or an argument list does not count.
ERREXIT_RE='^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)'

# The forbidden shape, assembled from fragments so this guard's own source can
# never match the pattern it enforces (same trick as the ripgrep guard in
# tests/test-harness-source-guards.test.sh). No backslashes appear anywhere in
# the assembled regex, so passing it through `awk -v` is escape-safe.
#
#   _EP_PIPE   a pipe OPERATOR: `|` that is not part of `||` and carries
#              whitespace on at least one side (boundary note 4 above).
#   _EP_READER a reader whose exit can precede its writer's last write.
_EP_GREP_FLAG='[[:space:]]+-[^[:space:]|]+'
_EP_GREP_EARLY='[[:space:]]+(-[A-Za-z]*[qlLm]|--(quiet|silent|files-with-matches|files-without-match|max-count))'
_EP_PIPE='([[:space:]][|][[:space:]]*|[^|[:space:]][|][[:space:]]+)'
_EP_READER="([{][[:space:]]+)?(grep(${_EP_GREP_FLAG})*${_EP_GREP_EARLY}|head([[:space:]]|\$)|read([[:space:]]|\$))"
EPIPE_RE="${_EP_PIPE}${_EP_READER}"

# The detector. Joins logical lines, then reports the first offending match per
# logical line as `startline<TAB>joined-line`.
#
#   -v RE=    the assembled shape regex
#   -v SETE=  1 when the file sets -e (then even a value-producing `$( ... )`
#             pipeline aborts the run, so it is in scope unless its rc is
#             explicitly neutralised with `|| true` / `|| :`)
#
# Backslash and pipe terminators are tested with substr()/string compare rather
# than a regex, because awk's regex-literal escape handling for `\` differs
# between implementations and this must behave identically on Git Bash.
_EP_AWK='
function neutralised(s) {
  return (s ~ /[|][|][[:space:]]*(true|:)([[:space:]]|;|[)]|$)/)
}
function subdepth(s,   i, n, c, d) {
  # Substitution depth at a match position: > 0 means the pipeline is producing
  # a VALUE inside `$( ... )` rather than a truth value. Parens are counted
  # after skipping backslash-escaped characters, so an ERE `\(` (a literal
  # paren, not a group) does not skew the count, and a balanced ERE group
  # `(a|b)` inside a quoted pattern nets out to zero. An UNBALANCED, unescaped
  # paren in a quoted pattern would skew it — `(` alone is not a valid ERE, so
  # the reachable case is a stray `)`, which can only lower the depth and
  # therefore only ever flags MORE, never less.
  d = 0; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "(") { d++ }
    else if (c == ")") { if (d > 0) { d-- } }
    i++
  }
  return d
}
function flush(   pos, abs, rest, d) {
  if (buf == "") { return }
  pos = 1
  while (match(substr(buf, pos), RE)) {
    abs = pos + RSTART - 1
    rest = substr(buf, abs)
    d = subdepth(substr(buf, 1, abs - 1))
    if (d == 0 || (SETE == 1 && neutralised(rest) == 0)) {
      printf "%d\t%s\n", start, buf
      buf = ""
      return
    }
    pos = abs + RLENGTH
  }
  buf = ""
}
{
  raw = $0
  sub(/[[:space:]]+$/, "", raw)
  if (raw ~ /^[[:space:]]*#/) { next }
  if (buf == "") { start = NR; buf = raw } else { buf = buf " " raw }
  if (substr(buf, length(buf), 1) == "\\") {
    buf = substr(buf, 1, length(buf) - 1)
    next
  }
  if (substr(buf, length(buf), 1) == "|" && substr(buf, length(buf) - 1, 1) != "|") { next }
  flush()
}
END { flush() }
'

# A detector that CANNOT RUN must not read as "nothing found" — that is the same
# vacuous-green failure this file exists to prevent, one level up. If awk exits
# non-zero (unsupported POSIX class in a dynamic regex on some awk, unreadable
# file, ...) the helper emits this marker instead of an empty result, and E1
# turns it into a FAIL naming the file.
_EP_ERR_MARK='DETECTOR-ERROR: '

# _epipe_hits FILE [REGEX_OVERRIDE]
#   -> `startline<TAB>logical-line` for every offending site,
#      or `0<TAB>DETECTOR-ERROR: ...` if the detector could not run.
# REGEX_OVERRIDE exists so E2 can prove the error path is live.
_epipe_hits() {
  local _f="$1" _re="${2:-$EPIPE_RE}" _sete=0 _out
  grep -qE -e "$ERREXIT_RE" "$_f" 2>/dev/null && _sete=1
  if ! _out="$(awk -v RE="$_re" -v SETE="$_sete" "$_EP_AWK" "$_f" 2>/dev/null)"; then
    printf '0\t%sawk exited non-zero while scanning this file\n' "$_EP_ERR_MARK"
    return 0
  fi
  [ -z "$_out" ] || printf '%s\n' "$_out"
}

# _epipe_sh_files -> every tracked shell source in the repo, one per line.
# `git ls-files` is the right enumerator: it excludes ignored scratch trees
# (tests/_fixtures/*, .claude/worktrees/*) that a bare `find` would descend into
# and that can contain generated, deliberately-hostile fixture scripts.
_epipe_sh_files() {
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$REPO_ROOT" ls-files -- '*.sh'
  else
    # The non-git fallback must restate by hand what .gitignore states for the
    # branch above, and it was missing the two bare worktree roots that
    # plugins/uberdev/lib/goal-state.sh enumerates alongside .claude/worktrees —
    # the same corpus-scope gap #445 fixed in tests/docs-accuracy.test.sh.
    # Both globs are listed on purpose: '*/worktrees/*' alone would cover
    # '.worktrees' nowhere, and naming each states the intent explicitly.
    find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' \
      -not -path '*/tests/_fixtures/*' -not -path '*/.claude/*' \
      -not -path '*/.worktrees/*' -not -path '*/worktrees/*' \
      | sed "s#^$REPO_ROOT/##"
  fi
}

echo "## EPIPE class guard (#313) — pipefail-exposed shell must not pipe into an early-exiting reader"

echo
echo "== E1: no pipefail-setting shell source pipes into an early-exiting reader =="
SCANNED=0
SCANNED_LIST=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  grep -qE -e "$PIPEFAIL_RE" "$f" 2>/dev/null || continue
  SCANNED=$((SCANNED + 1))
  SCANNED_LIST="$SCANNED_LIST$rel
"
  HITS="$(_epipe_hits "$f")"
  [ -n "$HITS" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    body="${hit#*$'\t'}"
    case "$body" in
      "$_EP_ERR_MARK"*)
        echo "  FAIL  $rel — the detector could not run, so this file was NOT checked"
        echo "        cause:  ${body#"$_EP_ERR_MARK"}"
        ;;
      *)
        echo "  FAIL  $rel:${hit%%$'\t'*} pipes into an early-exiting reader under pipefail"
        echo "        line:   $body"
        echo "        expect: reader PATTERN <<<\"\$(writer)\"   (herestring — no writer process, no EPIPE)"
        ;;
    esac
    FAIL=$((FAIL + 1))
  done <<<"$HITS"
done <<<"$(_epipe_sh_files)"
if [ "$FAIL" -eq 0 ]; then
  echo "  PASS  all $SCANNED pipefail-setting shell sources are herestring-clean"
  PASS=$((PASS + 1))
fi

echo
echo "== E2: the detector actually detects — one independent case per shape =="
# Every offending fixture line is assembled at RUNTIME from split reader tokens,
# so the literal never appears contiguously in this file (E1 scans this file).
_G='gr''ep'
_H='he''ad'
_R='re''ad'
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# _ep_case NAME EXPECT(BAD|OK) FIXTURE_FILE.
# Deliberately NOT fed from a pipe: the right-hand side of a pipeline runs in a
# subshell, and the PASS/FAIL counters would never make it back out.
_ep_case() {
  local _name="$1" _expect="$2" _file="$3" _hits
  if [ ! -s "$_file" ]; then
    echo "  FAIL  $_name — fixture is missing or empty; the case proves nothing"
    FAIL=$((FAIL + 1))
    return
  fi
  _hits="$(_epipe_hits "$_file")"
  if [ "$_expect" = BAD ]; then
    if [ -n "$_hits" ]; then
      echo "  PASS  $_name — flagged"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $_name — NOT flagged; the detector is blind to this shape"
      FAIL=$((FAIL + 1))
    fi
  else
    if [ -z "$_hits" ]; then
      echo "  PASS  $_name — not flagged"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  $_name — false positive: $_hits"
      FAIL=$((FAIL + 1))
    fi
  fi
}

# --- shapes that MUST be flagged -------------------------------------------
{ printf 'set -o pipefail\n'; printf 'ec''ho "$V" | %s -q PATTERN\n' "$_G"; } >"$TMPD/b1.sh"
_ep_case "E2.B1  echo writer, single line" BAD "$TMPD/b1.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -qE PATTERN\n' "$_G"; } >"$TMPD/b2.sh"
_ep_case "E2.B2  non-echo writer (cat)" BAD "$TMPD/b2.sh"
{ printf 'set -o pipefail\n'; printf 'printf "%%s" "$V" \\\n'; printf '  | %s -qE PATTERN\n' "$_G"; } >"$TMPD/b3.sh"
_ep_case "E2.B3  backslash-continuation pipeline" BAD "$TMPD/b3.sh"
{ printf 'set -o pipefail\n'; printf 'jq -r .x <<<"$V" |\n'; printf '  %s -q PATTERN\n' "$_G"; } >"$TMPD/b4.sh"
_ep_case "E2.B4  trailing-pipe-continuation pipeline" BAD "$TMPD/b4.sh"
{ printf 'set -o pipefail\n'; printf 'printf "%%s" "$V" | jq -r .x | %s -qE PATTERN\n' "$_G"; } >"$TMPD/b5.sh"
_ep_case "E2.B5  multi-stage writer chain (jq in the middle)" BAD "$TMPD/b5.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -3\n' "$_H"; } >"$TMPD/b6.sh"
_ep_case "E2.B6  head reader" BAD "$TMPD/b6.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s line\n' "$_R"; } >"$TMPD/b7.sh"
_ep_case "E2.B7  read reader" BAD "$TMPD/b7.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | { %s line; }\n' "$_R"; } >"$TMPD/b8.sh"
_ep_case "E2.B8  read reader behind a group opener" BAD "$TMPD/b8.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -m 1 PATTERN\n' "$_G"; } >"$TMPD/b9.sh"
_ep_case "E2.B9  grep -m reader" BAD "$TMPD/b9.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -l PATTERN\n' "$_G"; } >"$TMPD/b10.sh"
_ep_case "E2.B10 grep -l reader" BAD "$TMPD/b10.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s --quiet PATTERN\n' "$_G"; } >"$TMPD/b11.sh"
_ep_case "E2.B11 grep --quiet long form" BAD "$TMPD/b11.sh"
{ printf 'set -o pipefail\n'; printf 'check "label" "cat \\"$f\\" | %s -q PAT"\n' "$_G"; } >"$TMPD/b12.sh"
_ep_case "E2.B12 pipeline inside an eval'd assertion string" BAD "$TMPD/b12.sh"
{ printf 'set -euo pipefail\n'; printf 'X=$(cat "$f" | %s -1)\n' "$_H"; } >"$TMPD/b13.sh"
_ep_case "E2.B13 value substitution under set -e" BAD "$TMPD/b13.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -q BAD && fail "leak"\n' "$_G"; } >"$TMPD/b14.sh"
_ep_case "E2.B14 inverted polarity (&& fail)" BAD "$TMPD/b14.sh"
{ printf 'set -o pipefail\n'; printf 'my_helper "$f"| %s -q PATTERN\n' "$_G"; } >"$TMPD/b15.sh"
_ep_case "E2.B15 shell-function writer, no space before the pipe" BAD "$TMPD/b15.sh"

# --- shapes that MUST NOT be flagged (the declared boundary) ----------------
{ printf 'set -o pipefail\n'; printf '%s -q PATTERN <<<"$V"\n' "$_G"; } >"$TMPD/o1.sh"
_ep_case "E2.O1  herestring form" OK "$TMPD/o1.sh"
{ printf 'set -o pipefail\n'; printf '# ec''ho "$V" | %s -q PATTERN (prose)\n' "$_G"; } >"$TMPD/o2.sh"
_ep_case "E2.O2  the class described in a comment" OK "$TMPD/o2.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -c PATTERN\n' "$_G"; } >"$TMPD/o3.sh"
_ep_case "E2.O3  draining reader (grep -c)" OK "$TMPD/o3.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | wc -l\n'; } >"$TMPD/o4.sh"
_ep_case "E2.O4  draining reader (wc)" OK "$TMPD/o4.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | while %s line; do :; done\n' "$_R"; } >"$TMPD/o5.sh"
_ep_case "E2.O5  while-read loop drains its input" OK "$TMPD/o5.sh"
{ printf 'set -o pipefail\n'; printf "assert_grep \"\$f\" 'CAP|%s -c 100' label\\n" "$_H"; } >"$TMPD/o6.sh"
_ep_case "E2.O6  ERE alternation inside a quoted pattern" OK "$TMPD/o6.sh"
{ printf 'set -o pipefail\n'; printf 'X=$(%s -n P "$f" | %s -1 | cut -d: -f1)\n' "$_G" "$_H"; } >"$TMPD/o7.sh"
_ep_case "E2.O7  value substitution without set -e (rc discarded)" OK "$TMPD/o7.sh"
{ printf 'set -euo pipefail\n'; printf 'X=$(%s -n P "$f" | %s -1 || true)\n' "$_G" "$_H"; } >"$TMPD/o8.sh"
_ep_case "E2.O8  rc explicitly neutralised under set -e" OK "$TMPD/o8.sh"
{ printf 'set -o pipefail\n'; printf 'false || %s -q P "$f"\n' "$_G"; } >"$TMPD/o9.sh"
_ep_case "E2.O9  '||' is not a pipe operator" OK "$TMPD/o9.sh"
{ printf 'set -o pipefail\n'; printf 'cat "$f" | %s -e PATTERN\n' "$_G"; } >"$TMPD/o10.sh"
_ep_case "E2.O10 non-early grep flags (-e)" OK "$TMPD/o10.sh"

# A detector that cannot RUN must not read as "nothing found". Force awk to fail
# with an invalid regex over a known-CLEAN fixture: the result must be the error
# marker (which E1 turns into a FAIL), not the empty output that means clean.
_EP_X1="$(_epipe_hits "$TMPD/o1.sh" '[')"
case "$_EP_X1" in
  *"$_EP_ERR_MARK"*)
    echo "  PASS  E2.X1 a detector that cannot run reports an error, not 'clean'"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL  E2.X1 a broken detector returned '$_EP_X1' — E1 would go vacuously green"
    FAIL=$((FAIL + 1))
    ;;
esac

# The per-file pipefail gate lives in E1's loop rather than in _epipe_hits, so
# assert it the way E1 does: an identical offending body in a file that never
# turns pipefail on must not enter the scan at all.
{ printf 'set -u\n'; printf 'ec''ho "$V" | %s -q PATTERN\n' "$_G"; } >"$TMPD/o11.sh"
if [ -n "$(_epipe_hits "$TMPD/o11.sh")" ] \
  && ! grep -qE -e "$PIPEFAIL_RE" "$TMPD/o11.sh"; then
  echo "  PASS  E2.O11 pipefail gate keeps a non-pipefail file out of scope"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E2.O11 pipefail gate is wrong (fixture unflagged, or it matched the gate)"
  FAIL=$((FAIL + 1))
fi

echo
echo "== E3: the scan reached the whole shell surface =="
# A glob/gate regression that scanned zero (or a handful of) files would make E1
# green while checking nothing. Three independent checks: parity with a second
# enumerator, membership of known-exposed sentinels, and an absolute floor.
EXPECTED=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  grep -qE -e "$PIPEFAIL_RE" "$REPO_ROOT/$rel" 2>/dev/null && EXPECTED=$((EXPECTED + 1))
done <<<"$(_epipe_sh_files)"
if [ "$SCANNED" -eq "$EXPECTED" ]; then
  echo "  PASS  E3.1 E1 scanned every pipefail-setting shell source ($SCANNED)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E3.1 E1 scanned $SCANNED of $EXPECTED pipefail-setting shell sources"
  FAIL=$((FAIL + 1))
fi

E3_MISSING=""
for sentinel in \
  tests/config-override.test.sh \
  tests/workflow-scripts.test.sh \
  tests/epipe-guard.test.sh \
  plugins/uberdev/lib/bump-version.sh
do
  grep -qxF "$sentinel" <<<"$SCANNED_LIST" || E3_MISSING="$E3_MISSING $sentinel"
done
if [ -z "$E3_MISSING" ]; then
  echo "  PASS  E3.2 known-exposed sentinels are in the scanned set (incl. this guard — not self-exempt)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E3.2 sentinels missing from the scanned set:$E3_MISSING"
  FAIL=$((FAIL + 1))
fi

if [ "$SCANNED" -ge 80 ]; then
  echo "  PASS  E3.3 scanned $SCANNED pipefail-setting shell sources"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E3.3 only $SCANNED pipefail-setting shell sources scanned — enumerator regressed"
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

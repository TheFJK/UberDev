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
#   5. Markdown fences are not judged as FILES. Every fence is walked, whatever
#      its info string says, because the walk opens on the backtick run and never
#      reads the info string; over-scanning is the safe direction for a guard.
#      A fence is executed as its own Bash-tool call, and those calls share no
#      shell state, so a fence that turns pipefail on says nothing about the next
#      fence in the same file — the per-file gate E1 applies to shell sources
#      cannot decide a markdown file at all.
#      The fences are NOT exempt from the class, though: the `E4` rows below
#      cut the markdown corpus into fences, gate each fence on its own body, and
#      re-derive the verdict from live bytes on every run, so no answer about them
#      is written down here to rot and no hand-check is owed. What does remain out
#      of scope is state a fence would INHERIT from elsewhere: each fence is judged
#      in isolation, which is sound precisely because a Bash-tool call starts a
#      fresh shell in production too.
#
# SCAN SET. Every tracked `*.sh` file in the repo — tests, `plugins/uberdev/lib`,
# `tools/prkit`, `install.sh` — that turns
# pipefail on. Files that do NOT set pipefail are not exposed (the pipeline's rc
# is the last command's rc) and are out of scope by construction; the day one of
# them adds `set -o pipefail`, this guard reds on every site it just exposed.
#
# Alongside it, the markdown corpus: every tracked file matching the pathspec
# `plugins/uberdev/*.md`, cut into fenced code blocks, with the same pipefail gate
# applied per FENCE rather than per file (see the markdown note in the declared
# boundary above). The pathspec is stated instead of the directories it happens to
# cover, because the pathspec is what `_epipe_md_files` actually walks: a list of
# directory names would be a second description of the same set, kept in step by
# hand, and free to drift the moment one is added or emptied. `_epipe_sh_files`
# and `_epipe_md_files` enumerate the two corpora; `E1` and `E4` judge them.
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

# _epipe_md_files -> every tracked markdown source under plugins/uberdev, one
# per line. Same two-branch shape as _epipe_sh_files, and `git ls-files` is
# mandatory on the primary branch for a sharper reason than tidiness: scratch
# checkouts on a working machine hold UNTRACKED mirrors of the very SKILL.md
# files being counted, and a bare walk would count each of them again.
# git's pathspec `*` crosses `/`, so the one glob takes every tracked `*.md`
# under plugins/uberdev at whatever depth it sits. Deliberately NOT written as a
# list of the subdirectories that glob happens to reach: such a list is a second
# description of the same set, kept in step by hand, and it drifts in both
# directions at once — the retired form here named a directory holding no
# markdown and omitted one that does. That is the defect this suite exists to
# stop, so state the rule and let E4.0a report the count it measures.
_epipe_md_files() {
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$REPO_ROOT" ls-files -- 'plugins/uberdev/*.md'
  else
    # The fallback restates by hand what .gitignore states for the branch above:
    # the same scratch roots plugins/uberdev/lib/goal-state.sh enumerates, which
    # tests/test-harness-source-guards.test.sh A3 requires of any walk rooted at
    # the repository root (#445 is what happens without them).
    #
    # Every exclusion is anchored at $REPO_ROOT rather than written as `*/name/*`,
    # and that is load-bearing, not style. find matches -path against the WHOLE
    # constructed path, ancestors of the repository root included, so an
    # unanchored `*/worktrees/*` excludes the entire corpus whenever the checkout
    # itself happens to live under a directory of that name — which is exactly
    # where UberDev's own /solve and /turbo worktrees put it. Measured on such a
    # checkout: unanchored returns 0 of 120 files, anchored returns all 120.
    # (_epipe_sh_files above still carries the unanchored form and has the same
    # latent hole; fixing it is a separate change from this one.)
    find "$REPO_ROOT" -path "$REPO_ROOT/plugins/uberdev/*" -name '*.md' \
      -not -path "$REPO_ROOT/.git/*" -not -path "$REPO_ROOT/tests/_fixtures/*" \
      -not -path "$REPO_ROOT/.claude/*" -not -path "$REPO_ROOT/.worktrees/*" \
      -not -path "$REPO_ROOT/worktrees/*" \
      | sed "s#^$REPO_ROOT/##"
  fi
}

# The markdown fence extractor. ONE awk per file, which walks the fences AND
# computes each fence's pipefail gate and forbidden-shape count in the same pass.
# The alternative — extract, then re-open each fence from the shell — costs a
# process per fence instead of per file, and per-line spawns are
# disproportionately expensive on shape-checks-windows, already the CI critical
# path (the same constraint A3 records in test-harness-source-guards.test.sh).
#
#   -v FILE=  the path to report with, so reports name the repo-relative file
#   -v TAG=   a per-file token keying the written fence bodies. Start line alone
#             would let two files with a gated fence at the same line clobber
#             each other; TAG plus start line cannot collide either way.
#   -v OUT=   directory for gated fence bodies (must already exist)
#   -v RE=    EPIPE_RE, the forbidden shape
#   -v PFRE=  PIPEFAIL_RE, the per-fence gate
#
# Emits one row per fence:
#   F<TAB>file<TAB>start<TAB>end<TAB>gated<TAB>shapehits<TAB>bodypath
# and, for a file whose last line is still inside a fence:
#   U<TAB>file<TAB>start
# `bodypath` is emitted rather than recomputed by the caller so the naming rule
# lives in one place; it is empty for a fence that is not gated.
#
# FENCE RULES — CommonMark, with one deliberate relaxation:
#   * OPEN on a run of >= 3 backticks whose remainder holds no further backtick.
#     CommonMark forbids backticks in a backtick fence's info string, and that is
#     exactly what stops an inline code span from being read as a fence opener.
#   * CLOSE only on a run of >= the OPENING run followed by whitespace alone. A
#     3-backtick line therefore does NOT close a 4-backtick fence. This is the
#     whole reason a parity toggle is unusable rather than merely imprecise: over
#     a 4-backtick fence wrapping a 3-backtick example it reports two fences and
#     leaves the wrapped body OUTSIDE both, i.e. silently unscanned. E4.2d/E4.2e
#     lock the count and the extent, not just the verdict.
#   * Indentation is not capped. CommonMark stops honouring a fence past three
#     spaces of indent; this corpus carries fences indented far deeper. Being
#     permissive over-scans, which is the conservative direction for a guard.
#
# DECLARED BOUNDARY: tilde (`~~~`) fences are not walked. This corpus has none,
# and one appearing would leave its body unscanned rather than misread.
#
# COMMENT POLICY: a body line matching `^[[:space:]]*#` is kept in the body but
# counts toward NEITHER the gate NOR the shape. A commented-out `set -o pipefail`
# turns nothing on, and _EP_AWK already skips comments for the same reason. This
# is outcome-changing rather than cosmetic: without it the gated set grows, the
# extras being fences that only ever MENTION pipefail in prose. The written body
# keeps its comment lines, because _epipe_hits derives each body's `set -e` state
# itself and does its own comment skip.
#
# Trailing whitespace is stripped before every test, so a CRLF checkout cannot
# break the open/close match on the Windows job. No backslashes appear in the
# assembled regexes, so passing them through `awk -v` stays escape-safe there.
_EP_MD_AWK='
function lead_bt(s,   t, n) {
  # Length of the leading backtick run, after any indent.
  t = s
  sub(/^[[:space:]]+/, "", t)
  n = 0
  while (substr(t, n + 1, 1) == "`") { n++ }
  return n
}
function after_bt(s,   t) {
  # Whatever follows that run: a fence info string, or "" on a closing fence.
  t = s
  sub(/^[[:space:]]+/, "", t)
  sub(/^`+/, "", t)
  return t
}
function emit(e,   path) {
  path = ""
  if (gated == 1 && OUT != "") {
    path = OUT "/fence." TAG "." fstart ".sh"
    # Parenthesised argument list: `printf a, b > c` is the one place awk has to
    # guess between a redirect and a comparison, and this form does not ask it to.
    printf("%s", body) > path
    close(path)
  }
  printf "F\t%s\t%d\t%d\t%d\t%d\t%s\n", FILE, fstart, e, gated, shape, path
}
BEGIN { open = 0 }
{
  raw = $0
  sub(/[[:space:]]+$/, "", raw)
  n = lead_bt(raw)
  if (open == 0) {
    if (n >= 3 && index(after_bt(raw), "`") == 0) {
      open = n; fstart = FNR; body = ""; gated = 0; shape = 0
    }
    next
  }
  if (n >= open && after_bt(raw) == "") { emit(FNR); open = 0; next }
  body = body raw "\n"
  if (raw !~ /^[[:space:]]*#/) {
    if (raw ~ PFRE) { gated = 1 }
    if (raw ~ RE) { shape++ }
  }
}
END { if (open != 0) { printf "U\t%s\t%d\n", FILE, fstart } }
'

# _epipe_md_index PATH LABEL TAG
#   -> the fence index for one markdown file (rows as described above), or
#      `X<TAB>LABEL<TAB>DETECTOR-ERROR: ...` when the extractor could not run.
# The error row exists for the same reason _epipe_hits' does: an extractor that
# CANNOT RUN must not be indistinguishable from one that found no fences, or the
# file drops out of the corpus with nothing to show for it.
# Writes gated fence bodies under $TMPD/md, which E2 creates — this helper is
# never called before that point.
_epipe_md_index() {
  local _f="$1" _label="$2" _tag="$3" _out
  if ! _out="$(awk -v FILE="$_label" -v TAG="$_tag" -v OUT="$TMPD/md" \
      -v RE="$EPIPE_RE" -v PFRE="$PIPEFAIL_RE" "$_EP_MD_AWK" "$_f" 2>/dev/null)"; then
    printf 'X\t%s\t%sawk exited non-zero while extracting fences\n' "$_label" "$_EP_ERR_MARK"
    return 0
  fi
  [ -z "$_out" ] || printf '%s\n' "$_out"
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
echo "== E4: markdown bash fences, cut into fences and re-derived every run =="
# Issue #549. Boundary note 5 used to exempt markdown `bash` fences on the
# strength of a hand-check recorded in prose and anchored on a line number. Both
# halves rotted: the anchor stopped pointing at a pipeline, so the exemption
# became a claim nobody could re-verify without redoing the whole search. The
# durable fix is not a fresh anchor — it is to stop remembering the answer and
# re-derive it from the corpus on every run.
#
# WHY A FENCE, NOT A FILE, IS THE UNIT. Each Bash-tool call runs its own shell,
# so `set -o pipefail` inside one fence says nothing about the next fence in the
# same file. E1's per-FILE gate is therefore the wrong instrument here, and the
# corpus has to be cut into fences before any gate can be applied at all.

# The corpus, walked once. Every quantity below is MEASURED here and PRINTED in
# the row that uses it. None of them is written down in prose anywhere — a
# recorded count is the defect this section exists to retire, and it would start
# rotting the moment the corpus moved.
mkdir -p "$TMPD/md"
MD_FILES=0
MD_INDEX=""
while IFS= read -r md_rel; do
  [ -n "$md_rel" ] || continue
  md_f="$REPO_ROOT/$md_rel"
  [ -f "$md_f" ] || continue
  MD_FILES=$((MD_FILES + 1))
  MD_INDEX="$MD_INDEX$(_epipe_md_index "$md_f" "$md_rel" "$MD_FILES")
"
done <<<"$(_epipe_md_files)"

MD_FENCES=0
MD_SHAPE_FENCES=0
MD_UNCLOSED=""
MD_BROKEN=""
# All seven fields are named even where a census row does not read them: reading
# fewer would make the LAST variable swallow every remaining field, tabs and all,
# and silently turn the shape count into a path comparison.
while IFS=$'\t' read -r md_k md_file md_start md_end md_gated md_shape md_body; do
  case "$md_k" in
    F)
      MD_FENCES=$((MD_FENCES + 1))
      if [ "${md_shape:-0}" -gt 0 ]; then MD_SHAPE_FENCES=$((MD_SHAPE_FENCES + 1)); fi
      ;;
    U) MD_UNCLOSED="$MD_UNCLOSED $md_file:$md_start" ;;
    X) MD_BROKEN="$MD_BROKEN $md_file" ;;
  esac
done <<<"$MD_INDEX"

# --- E4.0  non-vacuity: prove the walk reached real bytes ---------------------
# Four independent floors. A guard that silently walks nothing is the failure
# mode this whole file exists to prevent, one level up, and a fence extractor is
# an unusually easy place to produce one: a single wrong character in the open
# rule yields zero fences and a clean bill of health for the entire corpus.
if [ "$MD_FILES" -ge 90 ]; then
  echo "  PASS  E4.0a enumerated $MD_FILES markdown sources under plugins/uberdev"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.0a enumerated only $MD_FILES markdown sources — the corpus glob regressed"
  FAIL=$((FAIL + 1))
fi

if [ "$MD_FENCES" -ge 400 ]; then
  echo "  PASS  E4.0b extracted $MD_FENCES fences from $MD_FILES markdown sources"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.0b extracted only $MD_FENCES fences — the fence open/close rule regressed"
  FAIL=$((FAIL + 1))
fi

# The count below is a PHYSICAL-line, comment-skipped match count. It is a coarse
# SUPERSET of what the real detector flags — it joins no logical lines and weighs
# no substitution depth — and it is deliberately not the verdict. Its one job is
# to prove EPIPE_RE still engages against markdown bytes, so that a regression in
# the fence rules or the regex cannot leave the live check vacuously green.
if [ "$MD_SHAPE_FENCES" -ge 6 ]; then
  echo "  PASS  E4.0c $MD_SHAPE_FENCES fences carry the forbidden shape (coarse count — not the verdict)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.0c only $MD_SHAPE_FENCES fences carry the forbidden shape — the regex stopped engaging"
  FAIL=$((FAIL + 1))
fi

# Both arms below mean "part of the corpus was not really walked": a file that
# ends mid-fence has an unknown extent, and a file whose extractor died has no
# fences for the reason that matters least. Either one silently shrinks the
# corpus, so neither may pass as clean.
if [ -z "$MD_UNCLOSED" ] && [ -z "$MD_BROKEN" ]; then
  echo "  PASS  E4.0d every markdown source was walked to EOF outside any fence"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.0d part of the markdown corpus was not walked"
  [ -z "$MD_UNCLOSED" ] || echo "        ends inside an unclosed fence (file:start):$MD_UNCLOSED"
  [ -z "$MD_BROKEN" ] || echo "        extractor could not run:$MD_BROKEN"
  FAIL=$((FAIL + 1))
fi

# _epipe_md_files' hand-written fallback runs only off a git checkout, so nothing
# else in this suite ever executes it — and an exclusion pattern that silently
# matches EVERYTHING is indistinguishable from an empty repository. That is not
# hypothetical: written unanchored as `*/worktrees/*`, the fallback returned zero
# of these files on any checkout living under a directory named `worktrees`,
# which is precisely where /solve and /turbo put theirs.
# `git` is shadowed rather than the tree copied, because what is under test is
# which BRANCH runs, not which files exist.
# Containment, not equality: find also sees UNTRACKED files, and a developer's
# scratch note under plugins/uberdev must not red the suite for everyone — the
# #445 lesson about guards that are green on CI and red on a working machine.
MD_GIT_LIST="$(_epipe_md_files)"
git() { return 1; }
MD_FIND_HAY="
$(_epipe_md_files)
"
unset -f git
MD_FALLBACK_MISSING=""
while IFS= read -r md_rel; do
  [ -n "$md_rel" ] || continue
  # Padded-haystack case, not a grep per line: 120 spawns is a real cost on the
  # Windows job, and the padding is what makes the match whole-line.
  case "$MD_FIND_HAY" in
    *"
$md_rel
"*) ;;
    *) MD_FALLBACK_MISSING="$MD_FALLBACK_MISSING $md_rel" ;;
  esac
done <<<"$MD_GIT_LIST"
if [ -z "$MD_FALLBACK_MISSING" ]; then
  echo "  PASS  E4.0e the non-git fallback enumerator reaches all $MD_FILES of them too"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.0e the non-git fallback enumerator drops part of the corpus"
  echo "        missing:$MD_FALLBACK_MISSING"
  FAIL=$((FAIL + 1))
fi

echo

# --- E4.1  the live verdict: is any gated fence actually exposed? -------------
# Every fence that turns pipefail on IN ITS OWN BODY gets the same detector E1
# runs over shell sources. This row is what replaces the retired hand-check: the
# question the old boundary note answered once, in prose, anchored on a line
# number, is re-asked here against live bytes on every run. Nothing is
# remembered, so nothing can rot.
#
# THE GATE IS pipefail ALONE, not "pipefail or -e". Without pipefail a pipeline's
# rc is its LAST command's rc — the reader's — so an early exit poisons nothing
# and errexit by itself is not exposure. `set -e` still matters, but it enters
# one level down: _epipe_hits derives each BODY's own errexit state and uses it
# to widen the flagged set to value-producing `$( ... )`, which is per-fence
# semantics for free. The retired note's "NEITHER pipefail nor -e" was merely
# conservative, not a second gate.
#
# THE GATED COUNT IS PRINTED, NEVER ASSERTED. A floor on it would be precisely
# the defect this section retires — a measurement recorded once and trusted
# afterwards — and the count may legitimately fall to zero as fences move. That
# this row can fire at all is proven by E4.2a/E4.2e, which are fixtures rather
# than a memory.
MD_GATED=0
MD_GATED_LIST=""
MD_EXPOSED=0
while IFS=$'\t' read -r md_k md_file md_start md_end md_gated md_shape md_body; do
  [ "$md_k" = F ] || continue
  [ "${md_gated:-0}" = 1 ] || continue
  MD_GATED=$((MD_GATED + 1))
  MD_GATED_LIST="$MD_GATED_LIST $md_file:$md_start-$md_end"
  # A gated fence whose body never reached disk cannot be judged, and an unjudged
  # fence must not read as clean — the same rule as the DETECTOR-ERROR arm below.
  if [ ! -s "$md_body" ]; then
    echo "  FAIL  $md_file — the fence opening at line $md_start is gated but its body was not written"
    echo "        so it was NOT checked; the extractor, not the corpus, is what failed"
    MD_EXPOSED=$((MD_EXPOSED + 1))
    FAIL=$((FAIL + 1))
    continue
  fi
  md_hits="$(_epipe_hits "$md_body")"
  [ -n "$md_hits" ] || continue
  while IFS= read -r md_hit; do
    [ -n "$md_hit" ] || continue
    md_line="${md_hit#*$'\t'}"
    case "$md_line" in
      "$_EP_ERR_MARK"*)
        echo "  FAIL  $md_file — the detector could not run on the fence opening at line $md_start"
        echo "        cause:  ${md_line#"$_EP_ERR_MARK"}"
        ;;
      *)
        # The body holds the lines AFTER the opening marker, so body line N is
        # file line (fence-open + N). The citation is therefore computed from
        # this run's bytes — the one kind of line number that cannot rot.
        md_no="${md_hit%%$'\t'*}"
        echo "  FAIL  $md_file:$((md_start + md_no)) pipes into an early-exiting reader under pipefail"
        echo "        fence:  opens at line $md_start, gated by its own set -o pipefail"
        echo "        line:   $md_line"
        echo "        expect: reader PATTERN <<<\"\$(writer)\"   (herestring — no writer process, no EPIPE)"
        ;;
    esac
    MD_EXPOSED=$((MD_EXPOSED + 1))
    FAIL=$((FAIL + 1))
  done <<<"$md_hits"
done <<<"$MD_INDEX"
if [ "$MD_EXPOSED" -eq 0 ]; then
  echo "  PASS  E4.1 all $MD_GATED pipefail-gated markdown fences are herestring-clean"
  echo "        gated (file:open-close):$MD_GATED_LIST"
  PASS=$((PASS + 1))
fi

echo

# --- E4.2  the extractor can FAIL: one fixture per decision it makes ----------
# Fixture bodies are assembled at RUNTIME from the split reader fragments in E2,
# so no offending literal ever appears contiguously in this file (E1 scans this
# file). $TMPD and its EXIT trap are E2's; do NOT arm a second one, traps are
# last-write-wins.
#
# _ep_md_case NAME FILE TAG WANT_FENCES WANT_START WANT_END WANT_GATED WANT_SHAPE
#   WANT_SHAPE is `0` (must be zero) or `+` (must be greater than zero).
# Every row asserts the fence COUNT and EXTENT as well as the verdict. Asserting
# the verdict alone would be too weak: an unsound extractor can reach the right
# verdict for the wrong reason on some inputs, and extent is exactly what it gets
# wrong. Not fed from a pipe — the right-hand side of a pipeline runs in a
# subshell and the PASS/FAIL counters would never make it back out.
_ep_md_case() {
  local _name="$1" _file="$2" _tag="$3" _xn="$4" _xs="$5" _xe="$6" _xg="$7" _xshape="$8"
  local _rows _n=0 _s="" _e="" _g="" _sh="" _bp="" _why=""
  # Declared local so a row's fields cannot leak into the global scope the later
  # sections read; `read` would otherwise create them as globals.
  local _k _rfile _rs _re _rg _rsh _rbp
  if [ ! -s "$_file" ]; then
    echo "  FAIL  $_name — fixture is missing or empty; the case proves nothing"
    FAIL=$((FAIL + 1))
    return
  fi
  _rows="$(_epipe_md_index "$_file" "$_name" "$_tag")"
  case "$_rows" in
    *"$_EP_ERR_MARK"*)
      echo "  FAIL  $_name — the fence extractor could not run, so the case proves nothing"
      echo "        cause:  $_rows"
      FAIL=$((FAIL + 1))
      return
      ;;
  esac
  while IFS=$'\t' read -r _k _rfile _rs _re _rg _rsh _rbp; do
    [ "$_k" = F ] || continue
    _n=$((_n + 1))
    if [ "$_n" -eq 1 ]; then _s="$_rs"; _e="$_re"; _g="$_rg"; _sh="$_rsh"; _bp="$_rbp"; fi
  done <<<"$_rows"
  [ "$_n" = "$_xn" ] || _why="$_why fences=$_n(want $_xn)"
  if [ "$_n" -ge 1 ]; then
    [ "$_s" = "$_xs" ] || _why="$_why start=$_s(want $_xs)"
    [ "$_e" = "$_xe" ] || _why="$_why end=$_e(want $_xe)"
    [ "$_g" = "$_xg" ] || _why="$_why gated=$_g(want $_xg)"
    if [ "$_xshape" = 0 ]; then
      [ "$_sh" = 0 ] || _why="$_why shape=$_sh(want 0)"
    else
      [ "${_sh:-0}" -gt 0 ] || _why="$_why shape=$_sh(want >0)"
    fi
    # A gated fence whose body was never written is a broken extractor: the body
    # file is what the per-fence verdict is computed over, so its absence would
    # read as "clean" one level up.
    if [ "$_xg" = 1 ]; then
      [ -s "$_bp" ] || _why="$_why gated-body-not-written"
    else
      [ -z "$_bp" ] || _why="$_why body-written-for-an-ungated-fence"
    fi
  fi
  if [ -z "$_why" ]; then
    echo "  PASS  $_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $_name —$_why"
    FAIL=$((FAIL + 1))
  fi
}

# a: plain fence, pipefail ON and the forbidden shape present -> gated, flagged.
{ printf '```bash\n'
  printf 'set -o pipefail\n'
  printf 'ec''ho "$V" | %s -q PATTERN\n' "$_G"
  printf '```\n'
} >"$TMPD/md2a.md"
_ep_md_case "E4.2a exposed fence (pipefail + forbidden shape)" "$TMPD/md2a.md" md2a 1 1 4 1 +

# b: the SAME body without pipefail. The gate is per fence, so this one never
# enters scope even though its shape is identical to a's.
{ printf '```bash\n'
  printf 'ec''ho "$V" | %s -q PATTERN\n' "$_G"
  printf '```\n'
} >"$TMPD/md2b.md"
_ep_md_case "E4.2b same shape, no pipefail — not gated" "$TMPD/md2b.md" md2b 1 1 3 0 +

# c: gated but herestring-clean. Guards the other direction — the gate must not
# manufacture a finding out of a fence that merely turns pipefail on.
{ printf '```bash\n'
  printf 'set -o pipefail\n'
  printf '%s -q PATTERN <<<"$V"\n' "$_G"
  printf '```\n'
} >"$TMPD/md2c.md"
_ep_md_case "E4.2c gated but herestring-clean — no false positive" "$TMPD/md2c.md" md2c 1 1 4 1 0

# d: a 4-backtick fence wrapping a 3-backtick block. ONE fence spanning the OUTER
# markers. A 3-backtick parity toggle instead reports two fences and leaves the
# wrapped body outside both — silently unscanned.
{ printf '````markdown\n'
  printf '```bash\n'
  printf 'ec''ho hi\n'
  printf '```\n'
  printf '````\n'
} >"$TMPD/md2d.md"
_ep_md_case "E4.2d nested fence extracted once, spanning the outer markers" "$TMPD/md2d.md" md2d 1 1 5 0 0

# e: the decisive row — d's nesting with a's exposed body. A parity toggle puts
# BOTH the pipefail line and the offending line outside every fence, so the
# verdict is a silent green. Nothing else in E4 would notice.
{ printf '````markdown\n'
  printf '```bash\n'
  printf 'set -o pipefail\n'
  printf 'ec''ho "$V" | %s -q PATTERN\n' "$_G"
  printf '```\n'
  printf '````\n'
} >"$TMPD/md2e.md"
_ep_md_case "E4.2e nested fence still gated and flagged (parity toggle goes green here)" "$TMPD/md2e.md" md2e 1 1 6 1 +

echo

# --- E4.3  the declared boundary carries no anchor that can rot ---------------
# The filed defect itself, turned into a test. The markdown-fence boundary note
# used to justify its exemption with a hand-check pinned to a `file:line`
# literal. The code moved, the literal did not, and the note ended up citing a
# line that is not a pipeline at all — an exemption nobody could re-verify
# without redoing the whole search by hand. E4.1 above removes the NEED for the
# anchor by re-deriving the answer from live bytes every run; these rows make
# putting one back a FAILURE rather than a matter of remembering not to.
#
# The slice runs from the DECLARED BOUNDARY header to the first line of code,
# so it covers the numbered notes AND the SCAN SET paragraph that follows them.
# That paragraph is in scope deliberately: it describes the corpora in prose, so
# it is exactly as able to rot as the notes are, and leaving it just past the
# closing anchor would have left a seam where un-derived prose could be written
# without any row here being able to see it. The `[^:]` after the header word is
# load-bearing rather than decorative: a second `# DECLARED BOUNDARY:` line
# declares the tilde-fence limitation further down this file, and a matcher that
# silently grabs the wrong block is exactly the failure mode these rows exist to
# prevent. `^set -u` is the closing anchor because it is CODE — rewording any
# paragraph inside the header cannot move it, and it is unique in the file.
EP_SELF="$0"

# The walk reports on ITSELF. Existence and termination are different questions,
# and asking the first while reporting the second is how a slice that ran to EOF
# gets called "bounded": reorder the two headers without renaming either and both
# still exist, so an existence check stays green while the walk never terminates.
# The END rule fires only when the closing anchor was never reached, which is the
# question the row below actually reports on — and because the sentinel comes from
# the same walk, it cannot drift out of step with the anchors the way a second
# copy of them would. `f=0` before `exit` is load-bearing: `exit` runs the END
# rule, so the flag has to be cleared first or a terminated walk would raise the
# sentinel too. Anchors stay backslash-free (`[.]`, not `\.`) so that `awk -v`
# stays escape-safe on Git Bash, where an undefined `\.` escape is not portable.
#
# `openre`/`stopre`, not `open`/`close`: `close` is an awk BUILT-IN function name,
# and using it as a variable is a syntax error on the BSD awk that macOS ships —
# a bailout, not a wrong answer, so it fails loudly, but only where a BSD awk runs.
EP_SENTINEL='EP-SLICE-RAN-TO-EOF'
_epipe_slice() {
  awk -v openre="$1" -v stopre="$2" -v sentinel="$EP_SENTINEL" '
    $0 ~ openre { f = 1 }
    f && $0 ~ stopre { f = 0; exit }
    f
    END { if (f) print sentinel }
  '
}

EP_HEADER="$(_epipe_slice '^# DECLARED BOUNDARY[^:]' '^set -u' <"$EP_SELF")"
EP_HEADER_LINES="$(grep -c . <<<"$EP_HEADER" || true)"
EP_HEADER_UNTERMINATED=""
case "$EP_HEADER" in *"$EP_SENTINEL") EP_HEADER_UNTERMINATED=yes ;; esac

# Non-vacuity first, the T9.0 shape from tests/docs-accuracy.test.sh: a renamed
# header must FAIL loudly here instead of passing every row below it over a slice
# that is not the block anyone meant. A prose lint that lints the wrong bytes is
# worse than none, because it reads as evidence.
#
# EVERY failure direction is covered, each by the predicate it actually needs,
# because they are three different questions and no one of them implies another:
#
#   * ran to EOF        -> the sentinel. A length floor cannot see this: losing the
#                          closing anchor makes the slice LONGER, not shorter, so a
#                          floor waves through the whole rest of the file.
#   * never started     -> the floor. The opening anchor renamed leaves nothing.
#   * started and ended
#     but under-covers  -> containment. Reorder the SCAN SET paragraph above the
#                          DECLARED BOUNDARY header and the walk still terminates
#                          honestly at `set -u` — bounded, non-empty, and quietly
#                          no longer covering the paragraph E4.3b is here to lint.
#                          Asserting the paragraph is INSIDE the extracted slice is
#                          what catches that; asking whether it exists in the FILE
#                          would not, since a reorder renames nothing.
#
# EP_SLICE_OK then gates the rows below, so a slice nobody meant is never linted
# and never reported green.
EP_SLICE_OK=""
if [ -n "$EP_HEADER_UNTERMINATED" ]; then
  echo "  FAIL  E4.3a declared-boundary header block never terminated — the walk ran to EOF"
  echo "        expect: the DECLARED BOUNDARY header, the numbered notes, the SCAN SET paragraph, then 'set -u'"
  echo "        cause:  the closing 'set -u' anchor was renamed, so the walk never stopped"
  echo "        file:   $EP_SELF"
  FAIL=$((FAIL + 1))
elif [ "${EP_HEADER_LINES:-0}" -lt 20 ]; then
  echo "  FAIL  E4.3a declared-boundary header block is empty or too short ($EP_HEADER_LINES non-blank lines)"
  echo "        expect: the DECLARED BOUNDARY header, the numbered notes, then the SCAN SET paragraph"
  echo "        cause:  the opening DECLARED BOUNDARY header was renamed, or this file could not be read"
  echo "        file:   $EP_SELF"
  FAIL=$((FAIL + 1))
elif ! grep -qE -e '^# SCAN SET\.' <<<"$EP_HEADER"; then
  echo "  FAIL  E4.3a declared-boundary header block does not contain the SCAN SET paragraph"
  echo "        expect: the DECLARED BOUNDARY header, the numbered notes, then the SCAN SET paragraph"
  echo "        cause:  SCAN SET was renamed, or moved ABOVE the DECLARED BOUNDARY header — the walk"
  echo "                then still terminates, but over a block that silently stops covering it"
  echo "        file:   $EP_SELF"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  E4.3a declared-boundary header block extracted and bounded ($EP_HEADER_LINES non-blank lines)"
  PASS=$((PASS + 1))
  EP_SLICE_OK=yes
fi

# Restated locally on purpose: tests/docs-accuracy.test.sh T9.1 carries the
# sibling regex for RFC prose, and hoisting two call sites in two suites into a
# shared regex library would buy indirection rather than reuse.
EP_ANCHOR_RE='\.(md|sh|py|js|json|yaml|yml):[0-9]+'
if [ -z "$EP_SLICE_OK" ]; then
  echo "  FAIL  E4.3b not linted — E4.3a could not extract the header block, so any verdict here would be over bytes nobody meant"
  FAIL=$((FAIL + 1))
elif grep -qE -e "$EP_ANCHOR_RE" <<<"$EP_HEADER"; then
  echo "  FAIL  E4.3b the header block cites a file:line anchor — the literal that rotted:"
  grep -oE -e "$EP_ANCHOR_RE" <<<"$EP_HEADER" | sort -u | sed 's/^/        /'
  echo "        fix:    name the symbol, the marker or the section instead; a line number cannot be re-verified"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  E4.3b the header block carries no file:line anchor"
  PASS=$((PASS + 1))
fi

# _EP_PIPE's comment points at "boundary note 4 above" by number, so the numbering
# is a live cross-reference and not merely a layout choice. Renumbering the notes
# rots it silently; this row is what stops that.
if [ -z "$EP_SLICE_OK" ]; then
  echo "  FAIL  E4.3c not linted — E4.3a could not extract the header block, so the numbering cannot be checked"
  FAIL=$((FAIL + 1))
elif grep -qE -e '^#[[:space:]]+4\.' <<<"$EP_HEADER"; then
  echo "  PASS  E4.3c the notes are still numbered through 4, so _EP_PIPE's cross-reference resolves"
  PASS=$((PASS + 1))
else
  echo "  FAIL  E4.3c no note numbered 4 in the slice — _EP_PIPE cites 'boundary note 4' and it no longer resolves"
  FAIL=$((FAIL + 1))
fi

echo

# --- E4.4  the markdown-fence note states a boundary, never a measurement -----
# The anchor was only half of what rotted. The other half was a COUNT: the note
# recorded how many offending sites the corpus held at the moment somebody looked,
# and a number written down in prose starts drifting the next time anyone edits a
# fence. E4.1 re-derives that number every run, which is what makes recording it
# unnecessary; this row makes re-pasting one impossible.
#
# WHAT THIS LINT IS AND IS NOT. It bans numerals and cardinal quantifiers inside
# one block of prose. It is not a general claim-detector and cannot be — prose
# lints do not generalise, and a determined sentence can always smuggle a count
# past a word list. Its job is narrower and achievable: make the CHEAP regression
# — pasting a freshly measured number back into the note — fail on the next run.
# The scope is deliberately this one block, because this is where a count was
# stated as evidence.
#
# `grep -w` (word match) rather than an anchored alternation: it is portable
# across the BSD, GNU and MSYS greps this suite runs under, and it avoids the
# anchor-inside-alternation construct that tests/test-harness-source-guards.test.sh
# A3 records as a portability trap. It is also what keeps section ids readable —
# the `4` in `E4` is preceded by a word character, so it is not a word match.
# Note 5 ends where the SCAN SET paragraph begins. That terminator is explicit
# for the same reason E4.3a asserts one: the header block now runs past SCAN SET,
# so a sub-slice that just ran to the end of it would drag the corpus paragraph
# into a count lint scoped to note 5 — the wrong bytes again, one level down.
EP_NOTE5="$(_epipe_slice '^#[[:space:]]+5[.]' '^# SCAN SET[.]' <<<"$EP_HEADER")"
EP_NOTE5_UNTERMINATED=""
case "$EP_NOTE5" in *"$EP_SENTINEL") EP_NOTE5_UNTERMINATED=yes ;; esac
# The `#` prefix and the `5.` enumerator are stripped before the match, or the
# enumerator would match the lint's own numeral rule on every run.
EP_NOTE5_TEXT="$(sed -e 's/^#//' -e 's/^[[:space:]]*5\.//' <<<"$EP_NOTE5")"
EP_COUNT_RE='one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|single|sole|lone|instance|instances|exactly|[0-9]+'
EP_NOTE5_LINES="$(grep -c . <<<"$EP_NOTE5" || true)"
if [ -z "$EP_SLICE_OK" ]; then
  echo "  FAIL  E4.4 not linted — E4.3a could not extract the header block, so note 5 could not be located"
  FAIL=$((FAIL + 1))
elif [ -n "$EP_NOTE5_UNTERMINATED" ]; then
  echo "  FAIL  E4.4 note 5 never terminated — the walk ran past the end of the header block"
  echo "        expect: note 5, then the SCAN SET paragraph that closes it"
  echo "        cause:  the SCAN SET header was renamed, so note 5's extent can no longer be determined"
  FAIL=$((FAIL + 1))
elif [ "${EP_NOTE5_LINES:-0}" -lt 3 ]; then
  echo "  FAIL  E4.4 the markdown-fence note is absent or too short to be stating a boundary — nothing was linted"
  echo "        expect: a note numbered 5 inside the declared boundary; renumbering it makes this row vacuous"
  FAIL=$((FAIL + 1))
elif grep -qwE -e "$EP_COUNT_RE" <<<"$EP_NOTE5_TEXT"; then
  echo "  FAIL  E4.4 the markdown-fence note states a measurement instead of a boundary:"
  grep -owE -e "$EP_COUNT_RE" <<<"$EP_NOTE5_TEXT" | sort -u | sed 's/^/        /'
  echo "        fix:    say what is out of scope and why; the corpus counts are E4's output, re-derived every run"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  E4.4 the markdown-fence note states a boundary and records no count ($EP_NOTE5_LINES lines linted)"
  PASS=$((PASS + 1))
fi

echo
echo "== L0: the shipped-code lint corpus =="
# The corpus every ported repo-wide guard scans. It is declared and floored HERE,
# once, so a guard folded in later cannot quietly bring its own narrower walk —
# the failure mode that made several one-document guards look repo-wide when they
# were not.
#
# SHELL-NESS IS DECIDED BY CONTENT, NOT BY FILENAME. `git ls-files -- '*.sh'`
# silently drops every shipped hook: hooks/session-start, hooks/session-end,
# hooks/pre-compact, hooks/inject-brainstorm-answers and lib/rl-curl carry no
# extension. A corpus that named hooks/ and still globbed '*.sh' would list the
# directory and read nothing out of it. Matching on the shebang instead means a
# sixth extension-less surface joins the corpus the day it is added, with no edit
# here — a hardcoded list of the five would rot on exactly that commit.
#
# The reader below takes its input from a herestring, not a pipe: this file is
# inside E1's own scan set (E3.2 asserts it is not self-exempt), so a
# `... | grep -q` here would be the very defect this suite exists to stop.
_lint_shipped_shell() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$REPO_ROOT/$rel" ] || continue
    case "$rel" in
      *.sh) printf '%s\n' "$rel"; continue ;;
    esac
    case "$(head -1 "$REPO_ROOT/$rel" 2>/dev/null)" in
      '#!'*sh|'#!'*sh\ *) printf '%s\n' "$rel" ;;
    esac
  done <<<"$(git -C "$REPO_ROOT" ls-files -- 'plugins/uberdev/*')"
}

# The THIRD shipped surface, and the one a shell-plus-markdown corpus silently
# omits: plugins/uberdev/skills/*/workflow.js. These files carry no shebang and
# are not markdown, so neither enumerator above reaches them — yet they hold live
# `gh pr create` / `gh issue view` call sites (scan-fleet/workflow.js:422,
# solve-fleet/workflow.js:752) and live agent dispatch. Any guard about gh
# argument shape or agent resolution that scans only shell+markdown is blind to
# ~9k lines of exactly the code it is about.
_lint_shipped_js() {
  git -C "$REPO_ROOT" ls-files -- 'plugins/uberdev/*.js'
}

LINT_SH_LIST="$(_lint_shipped_shell)"
LINT_SH_COUNT="$(grep -c . <<<"$LINT_SH_LIST")"
LINT_MD_LIST="$(_epipe_md_files)"
LINT_MD_COUNT="$(grep -c . <<<"$LINT_MD_LIST")"
LINT_JS_LIST="$(_lint_shipped_js)"
LINT_JS_COUNT="$(grep -c . <<<"$LINT_JS_LIST")"

# Floors carry real headroom below the observed counts: they exist to catch an
# enumerator that COLLAPSED, not to pin the current inventory. A floor equal to
# the live count reds on the first legitimate deletion and teaches everyone to
# raise it without looking, which is how a floor stops being a guard.
if [ "$LINT_SH_COUNT" -ge 30 ]; then
  echo "  PASS  L0.1 shipped shell corpus: $LINT_SH_COUNT files (floor 30)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.1 shipped shell corpus collapsed to $LINT_SH_COUNT (floor 30) — enumerator regressed"
  FAIL=$((FAIL + 1))
fi

if [ "$LINT_MD_COUNT" -ge 100 ]; then
  echo "  PASS  L0.2 shipped markdown corpus: $LINT_MD_COUNT files (floor 100)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.2 shipped markdown corpus collapsed to $LINT_MD_COUNT (floor 100) — enumerator regressed"
  FAIL=$((FAIL + 1))
fi

# L0.3 names the five extension-less surfaces one at a time. The floor above
# cannot catch their loss — dropping all five still leaves the count well over
# 30 — and they are precisely the files an extension-gated rewrite would lose.
L0_MISSING=""
for sentinel in \
  plugins/uberdev/hooks/session-start \
  plugins/uberdev/hooks/session-end \
  plugins/uberdev/hooks/pre-compact \
  plugins/uberdev/hooks/inject-brainstorm-answers \
  plugins/uberdev/lib/rl-curl
do
  grep -qxF "$sentinel" <<<"$LINT_SH_LIST" || L0_MISSING="$L0_MISSING $sentinel"
done
if [ -z "$L0_MISSING" ]; then
  echo "  PASS  L0.3 all five extension-less shipped shell surfaces are in the corpus"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.3 extension-less shipped surfaces missing from the corpus:$L0_MISSING"
  echo "        cause:  the enumerator went back to matching on filename instead of shebang"
  FAIL=$((FAIL + 1))
fi

# L0.4 is the anti-vacuity row for L0.3: it proves the corpus is not merely a
# '*.sh' glob that happens to satisfy the sentinels by coincidence. At least one
# member must carry no .sh suffix, or the shebang branch never fired.
L0_EXTLESS=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    *.sh) ;;
    *) L0_EXTLESS=$((L0_EXTLESS + 1)) ;;
  esac
done <<<"$LINT_SH_LIST"
if [ "$L0_EXTLESS" -ge 5 ]; then
  echo "  PASS  L0.4 the shebang branch fired — $L0_EXTLESS corpus members carry no .sh suffix"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.4 only $L0_EXTLESS extension-less members (expected >= 5) — the corpus is filename-gated"
  FAIL=$((FAIL + 1))
fi

if [ "$LINT_JS_COUNT" -ge 6 ]; then
  echo "  PASS  L0.5 shipped javascript corpus: $LINT_JS_COUNT files (floor 6)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.5 shipped javascript corpus collapsed to $LINT_JS_COUNT (floor 6) — enumerator regressed"
  FAIL=$((FAIL + 1))
fi

# L0.6 is L0.5's anti-vacuity partner and states the reason the JS corpus exists:
# these files really do carry the gh call sites a shell-only scan would miss. It
# counts the class rather than pinning a line number, so a call site moving
# between workflow.js files keeps it green while all of them going away reds it.
L0_JS_GH=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  l0_n="$(grep -cE 'gh (pr|issue) ' "$REPO_ROOT/$rel" 2>/dev/null)" || l0_n=0
  L0_JS_GH=$((L0_JS_GH + l0_n))
done <<<"$LINT_JS_LIST"
if [ "$L0_JS_GH" -ge 5 ]; then
  echo "  PASS  L0.6 the javascript corpus carries $L0_JS_GH live gh call sites a shell-only scan would miss"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L0.6 only $L0_JS_GH gh call sites found in the javascript corpus (expected >= 5)"
  echo "        cause:  either the corpus is empty or the scan stopped reading these files"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L1: retired terminal-dispatch transports =="
# Ported from tests/ghostty-dispatch-no-instance-leak.test.sh:55-88 (#31 Ghostty
# sticky --command=, #85 the five-branch cmux|ghostty|iterm|terminal|nohup
# dispatcher, RFC 0015). The donor read ONE hardcoded file — solve-launcher.sh —
# so a transport re-entering through lib/dispatch.sh, lib/child-dispatch.sh or a
# hook was invisible to it. Here the corpus is L0's.
#
# Full-line shell comments are skipped so the retirement can still be DESCRIBED
# in prose (lib/dispatch.sh and lib/goal-phase0.sh both name `cmux` in comments
# today). A TRAILING comment is deliberately NOT stripped: a `#` inside a quoted
# string or a URL is not a comment, and guessing is worse than the rule.
RETIRED_TRANSPORT_RE='open -na Ghostty --args --command=|cmux new-workspace|osascript -e|tell application "iTerm"|tell application "Terminal"|nohup zsh -l'
# No backslash appears in the regex, so passing it through `awk -v` is
# escape-safe (same argument as _EP_AWK above). awk does the comment skip and the
# match in one pass, so line numbers survive without piping into `grep -v` —
# this file is inside E1's own scan set and must not use a piped early-exit reader.
_RT_AWK='
/^[[:space:]]*#/ { next }
$0 ~ RE { printf "%s:%d\n", REL, FNR }
'
L1_HITS=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if ! _rt_out="$(awk -v RE="$RETIRED_TRANSPORT_RE" -v REL="$rel" "$_RT_AWK" "$REPO_ROOT/$rel" 2>/dev/null)"; then
    _rt_out="$rel:0 DETECTOR-ERROR awk exited non-zero while scanning this file"
  fi
  [ -z "$_rt_out" ] || L1_HITS="$L1_HITS$_rt_out
"
done <<<"$LINT_SH_LIST"
if [ -z "$L1_HITS" ]; then
  echo "  PASS  L1.1 no retired terminal-dispatch transport in the $LINT_SH_COUNT-file shipped shell corpus"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L1.1 retired terminal-dispatch transport present in shipped shell:"
  sed 's/^/        /' <<<"$L1_HITS"
  echo "        cause:  a transport retired in #85 (cmux / iTerm / Terminal AppleScript / nohup)"
  echo "                or #31 (Ghostty --args --command=) re-entered the dispatch path"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L2: the retired codex arm has not returned =="
# Ported from tests/route-unsupported.test.sh:40-45. The donor's `if grep -n ...;
# then <report>; exit 1; fi` spelling is deliberate and is carried: the obvious
# `! grep -q` rewrite is exempt from errexit and scored a false green with the
# regression actually on disk.
#
# Three-way on the grep rc, which the donor collapsed to two: rc=0 violations,
# rc=1 clean, rc>=2 the detector could not read the file. A subject that cannot
# be read must not be reported as clean.
L2_TARGET="plugins/uberdev/lib/solve-launcher.sh"
if ! grep -qxF "$L2_TARGET" <<<"$LINT_SH_LIST"; then
  echo "  FAIL  L2.1 $L2_TARGET is not in the L0 shell corpus — this guard has no subject"
  FAIL=$((FAIL + 1))
else
  L2_ARMS="$(grep -nE '^[^#]*\bcodex\b' "$REPO_ROOT/$L2_TARGET")"
  L2_RC=$?
  if [ "$L2_RC" -eq 0 ]; then
    echo "  FAIL  L2.1 retired codex transport re-introduced outside a comment in $L2_TARGET:"
    sed 's/^/        /' <<<"$L2_ARMS"
    FAIL=$((FAIL + 1))
  elif [ "$L2_RC" -eq 1 ]; then
    echo "  PASS  L2.1 no codex arm outside a comment in $L2_TARGET"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  L2.1 DETECTOR-ERROR: grep exited $L2_RC on $L2_TARGET — the file was NOT checked"
    FAIL=$((FAIL + 1))
  fi
fi

echo
echo "== L3: quoted-literal-tilde path assignments (#194) =="
# Ported from tests/using-git-worktrees.test.sh:62, which read one SKILL.md.
# Tilde expansion is suppressed inside "..." and '...' in bash AND zsh, so
# `path="~/x"` creates a directory literally named `~` under the cwd.
#
# The `=` immediately before the quote is load-bearing, not decoration. Two
# neighbouring shapes are legitimate and must survive: an unquoted RHS
# (`path=~/x`, where the tilde really does expand), and a quoted tilde used as a
# `case` PATTERN with no `=` in front of it — using-git-worktrees/SKILL.md:95
# matches LOCATION in both its literal and expanded forms, and a ban on "quoted
# ~/ anywhere" reds four shipped lines, three of them prose.
TILDE_RE='(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=\$?["'"'"']~'
TILDE_HITS=""
TILDE_DENOM=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  _t_d="$(grep -cE -e '[A-Za-z_][A-Za-z0-9_]*=["'"'"']' "$REPO_ROOT/$rel" 2>/dev/null)" || _t_d=0
  TILDE_DENOM=$((TILDE_DENOM + _t_d))
  _t_h="$(grep -nE -e "$TILDE_RE" "$REPO_ROOT/$rel" 2>/dev/null)" || _t_h=""
  [ -z "$_t_h" ] || TILDE_HITS="$TILDE_HITS$rel:$_t_h
"
done <<<"$LINT_SH_LIST
$LINT_MD_LIST"
if [ -z "$TILDE_HITS" ]; then
  echo "  PASS  L3.1 no quoted-literal-tilde path assignment in shipped code"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L3.1 quoted-literal-tilde path assignment (#194):"
  sed 's/^/        /' <<<"$TILDE_HITS"
  echo "        fix:    build the path with \"\${HOME}/...\""
  FAIL=$((FAIL + 1))
fi
# L3.2 is L3.1's denominator. L3.1 is an ABSENCE assertion over a regex that has
# never fired, so on its own it cannot distinguish "clean corpus" from "regex
# that stopped matching anything". Floored well under the live count.
if [ "$TILDE_DENOM" -ge 3000 ]; then
  echo "  PASS  L3.2 the tilde scan inspected $TILDE_DENOM quoted-RHS assignments (floor 3000)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L3.2 only $TILDE_DENOM quoted-RHS assignments scanned (floor 3000) — corpus or matcher regressed"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L4: no non-portable in-place sed flag =="
# Ported from tests/bump-version.test.sh:250, which read only $BUMP_SH. GNU sed
# reads the backup suffix ATTACHED (-i.bak); BSD/macOS sed reads the NEXT
# ARGUMENT as the suffix. Both CI jobs are GNU, so a regression here passes CI
# and breaks the maintainer's macOS release ritual — it fails on the one machine
# with no automated check.
SED_INPLACE_RE='(^|[^[:alnum:]_])sed([[:space:]]+-[[:alnum:]]+)*[[:space:]]+--?i'
SEDPORT_HITS=""
SEDPORT_DENOM=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  _s_d="$(grep -cE -e '(^|[^[:alnum:]_])sed[[:space:]]+-' "$REPO_ROOT/$rel" 2>/dev/null)" || _s_d=0
  SEDPORT_DENOM=$((SEDPORT_DENOM + _s_d))
  _s_h="$(grep -nE -e "$SED_INPLACE_RE" "$REPO_ROOT/$rel" 2>/dev/null)" || _s_h=""
  [ -z "$_s_h" ] || SEDPORT_HITS="$SEDPORT_HITS$rel:$_s_h
"
done <<<"$LINT_SH_LIST
$LINT_MD_LIST"
if [ -z "$SEDPORT_HITS" ]; then
  echo "  PASS  L4.1 no in-place sed flag in shipped code ($SEDPORT_DENOM flagged sed invocations cleared)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L4.1 non-portable in-place sed flag in shipped code:"
  sed 's/^/        /' <<<"$SEDPORT_HITS"
  echo "        fix:    render through a tempfile and copy back — see bv_edit_inplace() in lib/bump-version.sh"
  FAIL=$((FAIL + 1))
fi
if [ "$SEDPORT_DENOM" -ge 20 ]; then
  echo "  PASS  L4.2 the sed scan inspected $SEDPORT_DENOM flagged sed invocations (floor 20)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L4.2 only $SEDPORT_DENOM flagged sed invocations scanned (floor 20) — corpus or matcher regressed"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L5: the zsh-NOMATCH echo-ternary transcription trap =="
# Ported from tests/audit-fixups.test.sh C8 (:242 ban, :280 partner).
#
# POLARITY, because it is easy to get backwards: the nested form
# `echo "<label>: $([[ cond ]] && echo '<a>' || echo '<b>')"` is the BANNED one.
# It is valid in both shells as written; the defect is that the INNER quote pair
# is what gets dropped when the line is re-emitted into a generated launcher.
# Degraded, a parenthesised bare word makes bash die with a syntax error, while
# zsh under default NOMATCH either aborts with `no matches found:` or silently
# prints an EMPTY permission mode. The required form hoists both strings into a
# flat variable via if/else and echoes the variable.
#
# The illustrative one-liner is deliberately not written literally in this
# comment: a verbatim copy would self-match the regex the day the corpus widens.
NOMATCH_RE='echo "[^"]*\$\(\[\[.*\]\][[:space:]]*&&[[:space:]]*echo[[:space:]]*'"'"
NOMATCH_HITS=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  _n_h="$(grep -nE -e "$NOMATCH_RE" "$REPO_ROOT/$rel" 2>/dev/null)" || _n_h=""
  [ -z "$_n_h" ] || NOMATCH_HITS="$NOMATCH_HITS$rel:$_n_h
"
done <<<"$LINT_SH_LIST
$LINT_MD_LIST"
if [ -z "$NOMATCH_HITS" ]; then
  echo "  PASS  L5.1 no nested-substitution echo ternary in shipped shell or markdown"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L5.1 nested-substitution echo ternary (zsh-NOMATCH transcription trap):"
  sed 's/^/        /' <<<"$NOMATCH_HITS"
  echo "        fix:    hoist the two strings into a flat var via if/else, then echo the var"
  FAIL=$((FAIL + 1))
fi
# L5.2 is the partner the donor shipped and the ban depends on: without it the
# ban goes quietly green the moment the line it protects is deleted or relabelled.
# Indentation-tolerant, unlike the donor's column-0 `^echo` anchor.
if grep -qE '^[[:space:]]*echo "Permission mode: \$PERM_DESC"' \
     "$REPO_ROOT/plugins/uberdev/lib/solve-launcher.sh" 2>/dev/null; then
  echo "  PASS  L5.2 solve-launcher still prints the flat-var 'Permission mode: \$PERM_DESC'"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L5.2 solve-launcher's flat-var 'Permission mode: \$PERM_DESC' print is gone —"
  echo "        L5.1 would now be guarding a line that no longer exists"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L6: no gh-issue write passes an inline --body expansion =="
# Ported from tests/cluster.test.sh C2.c (security.md Q2). The donor's ANCHORED
# spelling is carried, NOT tests/solve-fleet-workflow.test.sh:375's bare
# `grep -q 'body-file'` presence check — that one matches a comment or a doc
# string and stays green next to a live inline --body.
#
# Forbidden: gh issue (close|edit|comment) ... --body "$...
# Allowed:   --body-file <path> / --body-file -
#
# The JS corpus is scanned too. L0.6 measures 18 live gh call sites in
# plugins/uberdev/skills/*/workflow.js, and those files carry neither a shebang
# nor a .md suffix — a shell-plus-markdown scan would have missed every one.
L6_RE='gh issue (close|edit|comment)[^|]*--body "\$'
L6_ANY_RE='gh issue (close|edit|comment)'
L6_HITS=""
L6_DENOM=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  _b_d="$(grep -cE -e "$L6_ANY_RE" "$REPO_ROOT/$rel" 2>/dev/null)" || _b_d=0
  L6_DENOM=$((L6_DENOM + _b_d))
  _b_h="$(grep -nE -e "$L6_RE" "$REPO_ROOT/$rel" 2>/dev/null)" || _b_h=""
  [ -z "$_b_h" ] || L6_HITS="$L6_HITS$rel:$_b_h
"
done <<<"$LINT_SH_LIST
$LINT_MD_LIST
$LINT_JS_LIST"
if [ -z "$L6_HITS" ]; then
  echo "  PASS  L6.1 no gh-issue write passes an inline --body \"\$…\" (security.md Q2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L6.1 gh-issue write with an inline --body variable expansion:"
  sed 's/^/        /' <<<"$L6_HITS"
  echo "        fix:    write the body to a mktemp file, then --body-file <path>"
  FAIL=$((FAIL + 1))
fi
if [ "$L6_DENOM" -ge 24 ]; then
  echo "  PASS  L6.2 the gh-write scan inspected $L6_DENOM gh issue close/edit/comment call sites (floor 24)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L6.2 only $L6_DENOM gh issue write call sites scanned (floor 24) — corpus regressed"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# The shared code/prose projection L7, L9 and L11 run their bans against.
#
# All three ports are BANS on a token, and the corpus is shipped shell PLUS
# shipped markdown. Every one of them therefore has the same problem: the token
# is legitimately NAMED far more often than it is used. `mapfile` appears
# thirteen times in shipped code and every one is a comment or a prose line
# explaining why it must not be used; a naive repo-wide ban on the word reds on
# its own documentation, and the only way to keep it green is to stop writing
# the documentation. That is the wrong trade, so the exemption is mechanical:
#
#   * a FULL-LINE shell comment is dropped whole. This is the same rule L1
#     already applies and for the same reason — a retirement has to stay
#     describable in prose.
#   * every BACKTICK-DELIMITED span is blanked. A backticked token is a NAME
#     being discussed, not a statement being executed, and it is how this repo
#     writes markdown prose (`BASH_REMATCH` in docs/testing.md), in-fence
#     comments, and the assertion-string mentions the donors carved out by hand.
#
# DECLARED BOUNDARY: the backtick rule also blanks a legacy `cmd` command
# substitution, so a banned token inside one would be missed. Measured on the
# corpus at the time of writing: the shipped shell surface contains no backtick
# substitution at all — every backtick in it opens a comment's prose span — and
# the repo's own convention is $(...). The rule is stated rather than hedged.
#
# ONE program, three bans. Each ban supplies its needle and, where a sanctioned
# spelling of the same token exists, the exempt form to subtract BEFORE the
# needle is applied — subtracted rather than merely tested, so a line carrying
# both the sanctioned form and a real violation is still reported.
_LINT_BAN_AWK='
function project(s,   t) {
  t = s
  gsub(/`[^`]*`/, " ", t)
  return t
}
/^[[:space:]]*#/ { next }
{
  line = project($0)
  if (EXEMPT != "") gsub(EXEMPT, " ", line)
  if (line ~ RE) printf "%s:%d: %s\n", REL, FNR, $0
}
'
# _lint_ban REL RE EXEMPT FILE -> `rel:line: text` per violation, empty when clean.
# A detector that cannot run must never look like a clean file, so a non-zero awk
# is turned into a DETECTOR-ERROR row the caller reports as a failure — the
# three-way rc discipline L2 states.
_lint_ban() {
  if ! awk -v REL="$1" -v RE="$2" -v EXEMPT="$3" "$_LINT_BAN_AWK" "$4" 2>/dev/null; then
    printf '%s:0: DETECTOR-ERROR awk exited non-zero while scanning this file\n' "$1"
  fi
}

# _lint_ban_corpus RE EXEMPT -> every violation across shell + markdown.
_lint_ban_corpus() {
  local _re="$1" _ex="$2" _rel _out
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    [ -f "$REPO_ROOT/$_rel" ] || continue
    _out="$(_lint_ban "$_rel" "$_re" "$_ex" "$REPO_ROOT/$_rel")"
    [ -z "$_out" ] || printf '%s\n' "$_out"
  done <<<"$LINT_SH_LIST
$LINT_MD_LIST"
}

# _lint_mentions RE -> how many corpus lines name the token in ANY context.
# This is the denominator every ban below reports: an ABSENCE assertion over a
# regex that has never fired cannot tell "clean corpus" from "regex that stopped
# matching", and for these three bans the population is not merely small — it is
# zero by construction, because the projection is what makes them green.
_lint_mentions() {
  local _re="$1" _rel _n _total=0
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    [ -f "$REPO_ROOT/$_rel" ] || continue
    _n="$(grep -cE -e "$_re" "$REPO_ROOT/$_rel" 2>/dev/null)" || _n=0
    _total=$((_total + _n))
  done <<<"$LINT_SH_LIST
$LINT_MD_LIST"
  printf '%s' "$_total"
}

# _lint_ban_case NAME EXPECT RE EXEMPT BODY — one polarity fixture. EXPECT is
# `flag` or `clean`. The fixture body is written to $TMPD and run through the
# SAME _lint_ban the verdict rows use, never through a re-implementation of it.
_lint_ban_case() {
  local _name="$1" _expect="$2" _re="$3" _ex="$4" _body="$5" _f _hits
  _f="$TMPD/lintban-case.sh"
  printf '%s\n' "$_body" > "$_f"
  if [ ! -s "$_f" ]; then
    echo "  FAIL  $_name — fixture is missing or empty; the case proves nothing"
    FAIL=$((FAIL + 1))
    return
  fi
  _hits="$(_lint_ban "fixture" "$_re" "$_ex" "$_f")"
  case "$_expect" in
    flag)
      if [ -n "$_hits" ]; then
        echo "  PASS  $_name — flagged"
        PASS=$((PASS + 1))
      else
        echo "  FAIL  $_name — NOT flagged; the ban is blind to this shape"
        FAIL=$((FAIL + 1))
      fi ;;
    clean)
      if [ -z "$_hits" ]; then
        echo "  PASS  $_name — not flagged"
        PASS=$((PASS + 1))
      else
        echo "  FAIL  $_name — false positive: $_hits"
        FAIL=$((FAIL + 1))
      fi ;;
  esac
}

echo
echo "== L7: cross-shell bashisms in shipped code =="
# Ported from tests/status.test.sh S1.12/S1.13 (one file, via a `sed 's/#.*//'`
# CODE_ONLY projection), tests/cluster.test.sh C2.b (one SKILL.md) and
# tests/uberthink.test.sh U8 (one SKILL.md). Three files were covered; the
# corpus is 158.
#
# Every shipped SKILL.md `bash` fence and every lib/ file re-sourced from one
# runs under /bin/zsh on macOS, where `type -t` does not exist and BASH_REMATCH
# is never populated (zsh fills $match instead). Both fail SILENTLY — `type -t`
# misreports, BASH_REMATCH reads as empty — so there is no crash to notice.
#
# THE MANDATORY CARVE-OUT. `${match[N]:-${BASH_REMATCH[N]}}` is the CORRECT
# dual-shell fix, not a violation: it reads whichever array the live shell
# populated. lib/goal-state.sh uses it for the only `Blocks: #N` parser in the
# repo, and a naive repo-wide BASH_REMATCH ban reds on exactly the line that
# fixed the bug. The exempt form is subtracted from the line before the ban is
# applied, and L7.4 asserts the form is still LIVE in shipped code — without
# that partner the carve-out would go on standing after the line it protects was
# deleted, which is how an exemption becomes a hole.
#
# DECLARED BOUNDARY — `for x in $SCALAR` is NOT in this ban. zsh does not
# word-split an unquoted scalar, so the loop runs once over the whole string;
# it is the same class and it is in this repo's memory as a recurring one. It is
# left out because the shipped corpus carries ~15 live instances (commands/
# cluster.md, lib/goal-phase1.sh, lib/live-semaphore.sh, several SKILL.md
# fences), several of them deliberate, and re-classifying them is a change to
# shipped behaviour rather than a test consolidation. The runtime bash-vs-zsh
# differential at tests/review-pr-consolidate.test.sh RCXZa-d covers the one lib
# where the split is load-bearing. Stated here so the gap is a decision on the
# record and not an oversight.
#
# Needles assembled, never contiguous: these bytes sit in several corpora that
# grep tests/ for exactly these tokens.
L7_REMATCH='BASH_'; L7_REMATCH="${L7_REMATCH}REMATCH"
L7_TYPET='type[[:space:]]+'; L7_TYPET="${L7_TYPET}-t([[:space:]]|$)"
L7_RE="${L7_TYPET}|${L7_REMATCH}"
# Bracket classes throughout instead of backslash escapes: the value crosses an
# `awk -v` boundary, where backslash handling differs between the BSD, GNU and
# MSYS awks this suite runs under.
L7_EXEMPT="[$][{]match[[][0-9]+[]][:][-][$][{]${L7_REMATCH}[[][0-9]+[]][}][}]"
L7_HITS="$(_lint_ban_corpus "$L7_RE" "$L7_EXEMPT")"
if [ -z "$L7_HITS" ]; then
  echo "  PASS  L7.1 no zsh-hostile bashism in executable shipped code"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L7.1 zsh-hostile bashism in shipped code:"
  sed 's/^/        /' <<<"$L7_HITS"
  echo "        fix:    'command -v' for type -t; \${match[N]:-\${BASH_REMATCH[N]}} for the capture"
  FAIL=$((FAIL + 1))
fi
# The floor carries deliberate headroom, per the L0 convention above: it exists
# to catch a matcher that COLLAPSED to zero, not to pin the inventory. Live
# count is 12 and all twelve are prose — six comment lines in lib/goal-state.sh,
# one in each of lib/review-fleet-args.sh, lib/turbox-fleet.sh and
# docs/testing.md, and the rest documentation of why the token must not be used.
# A floor of 12 would red on the first legitimate comment tidy and report it as
# "corpus or matcher regressed", which is a false accusation and trains the next
# reader to raise the number without looking. 6 is half the live count: a
# collapsed matcher reads 0 and still reds.
#
# The lower floor costs nothing, because a COUNT was never what proves the two
# alternatives are live. Measured: all 12 lines come from the BASH_REMATCH arm
# and ZERO from the `type -t` arm — the corpus writes that token backticked, and
# the arm requires whitespace or end-of-line after `-t`. So the `type -t` half
# has a denominator of 0 at ANY floor, and what actually proves it fires is
# L7.3b, which runs a seeded `type -t` through the same _lint_ban the verdict
# uses, on every run. Do not raise this floor back to the inventory: the
# per-arm proof is the polarity fixtures, and this row only catches a TOTAL
# collapse.
L7_DENOM="$(_lint_mentions "$L7_RE")"
if [ "$L7_DENOM" -ge 6 ]; then
  echo "  PASS  L7.2 the bashism scan inspected $L7_DENOM corpus lines naming these tokens (floor 6)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L7.2 only $L7_DENOM corpus lines name these tokens (floor 6) — corpus or matcher regressed"
  FAIL=$((FAIL + 1))
fi
_lint_ban_case "L7.3a live capture-array read" flag "$L7_RE" "$L7_EXEMPT" \
  "$(printf 'if [[ "$x" =~ ^a([0-9]+)$ ]]; then\n  n="${%s[1]}"\nfi\n' "$L7_REMATCH")"
L7_TYPET_LIT='type '; L7_TYPET_LIT="${L7_TYPET_LIT}-t"
_lint_ban_case "L7.3b live shell-builtin type probe" flag "$L7_RE" "$L7_EXEMPT" \
  "$(printf 'if [ "$(%s helper)" = function ]; then :; fi\n' "$L7_TYPET_LIT")"
_lint_ban_case "L7.3c the sanctioned dual-shell capture" clean "$L7_RE" "$L7_EXEMPT" \
  "$(printf 'local pr_num="${match[1]:-${%s[1]}}"\n' "$L7_REMATCH")"
_lint_ban_case "L7.3d a comment naming the token" clean "$L7_RE" "$L7_EXEMPT" \
  "$(printf '# never %s here: zsh populates $match instead\n' "$L7_REMATCH")"
_lint_ban_case "L7.3e backticked prose naming the token" clean "$L7_RE" "$L7_EXEMPT" \
  "$(printf 'Bashisms such as `%s` and `%s` misfire under zsh.\n' "$L7_REMATCH" "$L7_TYPET_LIT")"
# L7.4 — the carve-out's partner. An exemption whose subject has been deleted is
# a permanent hole nobody can see; this is L5.2's discipline applied to L7.
if grep -rqE -e "$L7_EXEMPT" "$REPO_ROOT/plugins/uberdev" 2>/dev/null; then
  echo "  PASS  L7.4 the sanctioned dual-shell capture form is still live in shipped code"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L7.4 nothing in shipped code uses \${match[N]:-\${BASH_REMATCH[N]}} any more —"
  echo "        the L7 carve-out is now exempting a form that does not exist"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L8: gh label descriptions inside GitHub's 100-BYTE limit =="
# Ported from tests/cluster.test.sh C4 (one literal in one SKILL.md, found by
# grepping for its own opening words) and tests/findings-to-issues.test.sh
# S21.10 (every --description in one agent .md).
#
# THE UNIT. The two donors disagree: C4 measures with `wc -c` (bytes), S21.10
# with `wc -m` (characters, and locale-dependent at that). GitHub's limit is on
# BYTES, so the port resolves in favour of `wc -c`. The difference is not
# academic here — this repo's label prose is full of em-dashes and typographic
# punctuation at three bytes each, so a 40-character description can be 120
# bytes. `wc -m` calls it 40 and passes; the API returns 422 and label
# provisioning fails for the whole run. L8.3c is that exact fixture.
#
# THE VACUITY TRAP. A resolver that walks the corpus for `<VAR>=` and takes the
# first hit binds a variable to some OTHER file's value: a seeded 113-byte
# violation once measured as 5 bytes and passed. So nothing is resolved from a
# call site. Every literal is measured WHERE IT IS WRITTEN, through three
# mechanically-derivable shapes, and a `--description "$VAR"` call site is not a
# measurement subject at all:
#   direct    --description "<literal>"           (S21.10's shape)
#   assign    <NAME>LABEL_DESC[RIPTION]=<literal> (C4's subject, by role)
#   record    a prose literal inside a *_trust_label() record producer, which is
#             how commands/review-pr.md's descriptions reach gh — through a
#             tab-separated triple, so they have no assignment to find and both
#             donors were blind to them
L8_TAB="$(printf '\t')"
# ONE awk over each corpus file. It does the comment skip, the three shapes and
# the tab framing in a single pass, so the extraction has no sed-quoting seam and
# emits real tabs on every platform's sed. `_trust_label()` is matched by ROLE —
# any function whose name ends that way — rather than by a file:line anchor that
# would rot the next time review-fleet-args.sh is edited.
_L8_EXTRACT_AWK='
  /^[A-Za-z_][A-Za-z0-9_]*_trust_label\(\)[[:space:]]*\{/ { infn = 1 }
  infn && /^\}/ { infn = 0 }
  /^[[:space:]]*#/ { next }
  {
    if (match($0, /--description[[:space:]]+"[^"$]*"/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^--description[[:space:]]+"/, "", s); sub(/"$/, "", s)
      if (s != "") printf "direct\t%s\n", s
    }
    if (match($0, /LABEL_DESC(RIPTION)?="[^"$]*"/)) {
      s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s)
      if (s != "") printf "assign\t%s\n", s
    }
    if (match($0, "LABEL_DESC(RIPTION)?=" Q "[^" Q "]*" Q)) {
      s = substr($0, RSTART, RLENGTH); sub("^[^" Q "]*" Q, "", s); sub(Q "$", "", s)
      if (s != "") printf "assign\t%s\n", s
    }
    if (infn) {
      s = $0
      while (match(s, Q "[^" Q "]*" Q)) {
        lit = substr(s, RSTART + 1, RLENGTH - 2)
        if (lit ~ / /) printf "record\t%s\n", lit
        s = substr(s, RSTART + RLENGTH)
      }
    }
  }
'
L8_LITERALS=""
L8_FILE_COUNT=0
while IFS= read -r l8_rel; do
  [ -n "$l8_rel" ] || continue
  [ -f "$REPO_ROOT/$l8_rel" ] || continue
  l8_found="$(awk -v Q="'" "$_L8_EXTRACT_AWK" "$REPO_ROOT/$l8_rel" 2>/dev/null)" || l8_found=""
  [ -n "$l8_found" ] || continue
  L8_FILE_COUNT=$((L8_FILE_COUNT + 1))
  while IFS= read -r l8_row; do
    [ -n "$l8_row" ] || continue
    L8_LITERALS="$L8_LITERALS$l8_rel$L8_TAB$l8_row
"
  done <<<"$l8_found"
done <<<"$LINT_SH_LIST
$LINT_MD_LIST
$LINT_JS_LIST"

# _l8_overlong LITERAL-BLOCK -> `rel<TAB>shape<TAB>bytes<TAB>text` per breach.
# `wc -c` over the exact bytes, with printf '%s' so no trailing newline is counted.
_l8_overlong() {
  local _rel _shape _text _len
  while IFS="$L8_TAB" read -r _rel _shape _text; do
    [ -n "$_shape" ] || continue
    _len="$(printf '%s' "$_text" | wc -c | tr -d '[:space:]')"
    [ "${_len:-0}" -le 100 ] || printf '%s\t%s\t%s\t%s\n' "$_rel" "$_shape" "$_len" "$_text"
  done <<<"$1"
}
L8_COUNT="$(grep -c . <<<"$L8_LITERALS")"
L8_BREACH="$(_l8_overlong "$L8_LITERALS")"
if [ -z "$L8_BREACH" ]; then
  echo "  PASS  L8.1 all $L8_COUNT gh label description literals are <= 100 bytes"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L8.1 gh label description over GitHub's 100-BYTE limit (422s on create AND update):"
  sed 's/^/        /' <<<"$L8_BREACH"
  FAIL=$((FAIL + 1))
fi
# L8.2 — the denominator, in two independent directions. A count alone would stay
# green if one extractor shape silently stopped matching while another grew, so
# the file spread is asserted too.
if [ "$L8_COUNT" -ge 6 ] && [ "$L8_FILE_COUNT" -ge 4 ]; then
  echo "  PASS  L8.2 measured $L8_COUNT description literals across $L8_FILE_COUNT files (floors 6 / 4)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L8.2 measured $L8_COUNT literals across $L8_FILE_COUNT files (floors 6 / 4) — an extractor shape stopped matching"
  FAIL=$((FAIL + 1))
fi
# L8.2b — all three shapes must be live. This is the row that keeps the port
# honest about subsuming BOTH donors plus the record producer neither saw.
L8_SHAPES_MISSING=""
while IFS= read -r l8_shape; do
  [ -n "$l8_shape" ] || continue
  grep -q "$L8_TAB$l8_shape$L8_TAB" <<<"$L8_LITERALS" \
    || L8_SHAPES_MISSING="$L8_SHAPES_MISSING $l8_shape"
done <<EOF
direct
assign
record
EOF
if [ -z "$L8_SHAPES_MISSING" ]; then
  echo "  PASS  L8.2b all three extraction shapes (direct / assign / record) found live literals"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L8.2b extraction shape(s) found nothing:$L8_SHAPES_MISSING"
  echo "        each one covers a donor this row replaced; a dead shape is silent lost coverage"
  FAIL=$((FAIL + 1))
fi
# L8.3 — polarity, through the SAME _l8_overlong the verdict uses. Three cases:
# over the limit, exactly at it, and the unit discriminator. Built with a counted
# loop rather than `seq`, which is not guaranteed on Git Bash.
L8_FX_OVER=""; while [ "${#L8_FX_OVER}" -lt 113 ]; do L8_FX_OVER="${L8_FX_OVER}x"; done
L8_FX_EDGE=""; while [ "${#L8_FX_EDGE}" -lt 100 ]; do L8_FX_EDGE="${L8_FX_EDGE}x"; done
L8_FX_EM="$(printf '\342\200\224')"
L8_FX_WIDE=""; l8_i=0
while [ "$l8_i" -lt 40 ]; do L8_FX_WIDE="$L8_FX_WIDE$L8_FX_EM"; l8_i=$((l8_i + 1)); done
L8_FX_IN="fx${L8_TAB}direct${L8_TAB}$L8_FX_OVER
fx${L8_TAB}direct${L8_TAB}$L8_FX_EDGE
fx${L8_TAB}record${L8_TAB}$L8_FX_WIDE"
L8_FX_OUT="$(_l8_overlong "$L8_FX_IN")"
L8_FX_N="$(grep -c . <<<"$L8_FX_OUT")"
L8_FX_LENS="$(awk -F'\t' 'NF >= 4 { print $3 }' <<<"$L8_FX_OUT" | sort -n | tr '\n' ' ')"
if [ "$L8_FX_N" -eq 2 ] && [ "$L8_FX_LENS" = "113 120 " ]; then
  echo "  PASS  L8.3 the measurement flags 113 bytes and the 40-char/120-byte string, and spares 100 bytes"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L8.3 the measurement is not discriminating: flagged $L8_FX_N with lengths [$L8_FX_LENS]"
  echo "        expected exactly 2 breaches at 113 and 120 bytes; 120 from 40 em-dashes is the"
  echo "        wc -m / wc -c discriminator — a character count reads it as 40 and passes"
  FAIL=$((FAIL + 1))
fi
echo
echo "== L9: the macOS bash-3.2 floor =="
# Ported from tests/bump-version.test.sh B1.11, which banned the three builtins
# on ONE file (lib/bump-version.sh). Every shipped lib states the same floor in
# its own header — lib/solve-launcher.sh:28, lib/turbox-fleet.sh:17,
# lib/rl-curl:26 — and none of them was checked.
#
# macOS ships /bin/bash 3.2. mapfile and readarray arrive in bash 4, `declare -A`
# in bash 4 as well, and zsh has none of them. All three fail the same way: the
# builtin is missing, the array it should have filled stays EMPTY, and the next
# statement reads that as "nothing to do". #398 is the recorded instance.
#
# CARVE-OUT: probe and comment contexts. The token is named far more often than
# it is used — thirteen shipped lines name it and every one is documentation of
# why not to. The shared projection above handles both: a full-line comment is
# dropped, a backticked mention is blanked. That is the same exemption the issue
# asks for in tests/crossplatform-shell-wrappers.test.sh (a live `mapfile` inside
# a zsh negative-control probe) and tests/goal.test.sh:534 (the token inside an
# assertion string); those two are outside this corpus by construction — L0 is
# scoped to plugins/uberdev — because the bash-3.2 floor is a SHIPPED-code
# contract. The CI harness runs on bash 5 and Git Bash 4.4, so banning the
# builtins there would be a rule with no defect behind it.
L9_MAPFILE='map'; L9_MAPFILE="${L9_MAPFILE}file"
L9_READARRAY='read'; L9_READARRAY="${L9_READARRAY}array"
L9_DECLARE_A='declare[[:space:]]+'; L9_DECLARE_A="${L9_DECLARE_A}-A([[:space:]]|$)"
L9_RE="${L9_MAPFILE}|${L9_READARRAY}|${L9_DECLARE_A}"
L9_HITS="$(_lint_ban_corpus "$L9_RE" "")"
if [ -z "$L9_HITS" ]; then
  echo "  PASS  L9.1 no bash-4 builtin executed in shipped code (macOS /bin/bash is 3.2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L9.1 bash-4-only builtin in shipped code:"
  sed 's/^/        /' <<<"$L9_HITS"
  echo "        fix:    while IFS= read -r over a herestring; parallel indexed arrays, never declare -A"
  FAIL=$((FAIL + 1))
fi
# Floored with headroom for the same reason as L7.2, and the reason bites harder
# here: every one of the 8 live lines is documentation of why NOT to use the
# builtin (lib/goal-phase3.sh:218 describes a mapfile that no longer exists —
# precisely the stale prose a later cleanup deletes). A floor of 8 would make
# writing that documentation mandatory, inverting L9's own carve-out, whose
# whole purpose is to let the ban stay describable in prose. 4 is half the live
# count and still reds on a matcher that stopped matching.
#
# Per-arm, measured: mapfile 6, declare -A 2, readarray 0. The readarray arm has
# no corpus line at any floor, and at 4 a lone declare -A arm going dark would
# leave 6 and pass. Neither is a hole, because the arms are proven by EXECUTION,
# not by counting: L9.3a/b/c push a seeded mapfile, readarray and declare -A
# through the same _lint_ban the verdict uses and each must flag. This row's job
# is the total collapse the fixtures cannot see — a corpus that stopped being
# enumerated at all.
L9_DENOM="$(_lint_mentions "$L9_RE")"
if [ "$L9_DENOM" -ge 4 ]; then
  echo "  PASS  L9.2 the bash-3.2 scan inspected $L9_DENOM corpus lines naming these builtins (floor 4)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L9.2 only $L9_DENOM corpus lines name these builtins (floor 4) — corpus or matcher regressed"
  FAIL=$((FAIL + 1))
fi
_lint_ban_case "L9.3a live array slurp" flag "$L9_RE" "" \
  "$(printf '%s -t rows < <(printf "a\\nb\\n")\n' "$L9_MAPFILE")"
_lint_ban_case "L9.3b live readarray" flag "$L9_RE" "" \
  "$(printf '%s -t rows <<<"$payload"\n' "$L9_READARRAY")"
L9_DECL_LIT='declare '; L9_DECL_LIT="${L9_DECL_LIT}-A"
_lint_ban_case "L9.3c live associative array" flag "$L9_RE" "" \
  "$(printf '%s WANT=()\nWANT[a]=1\n' "$L9_DECL_LIT")"
_lint_ban_case "L9.3d a comment naming the builtin" clean "$L9_RE" "" \
  "$(printf '# portable while-read loop — NOT %s, which is bash-4-only\n' "$L9_MAPFILE")"
_lint_ban_case "L9.3e a backticked probe mention in prose" clean "$L9_RE" "" \
  "$(printf 'The Z2 negative control runs `%s -t probe` under zsh -f and expects rc=127.\n' "$L9_MAPFILE")"

echo
echo "== L10: every plugin-namespaced name the corpus dispatches or cites resolves =="
# Ported from tests/turbox-fleet.test.sh TX11b, which read ONE SKILL.md through
# an extractor requiring BACKTICK delimiters:  `uberdev:<name>`  . That spelling
# is documentation. The OPERATIVE spelling — the one a dispatch actually fails
# on — is `subagent_type: uberdev:<agent>`, and the donor's extractor cannot see
# a single one of them. Both shapes are read here, and they are judged
# differently because they mean different things:
#
#   L10.1  a DISPATCH position (subagent_type) must name a real agent. A dead
#          agentType fails at dispatch time, mid-run, after the claims are
#          already written.
#   L10.2  a CITATION (backticked) must name a real shipped artifact of some
#          kind. This is TX11b's own predicate, widened from one file to the
#          whole markdown corpus.
#
# CARVE-OUTS, all mechanically derived — no hand-maintained allow-list:
#   * template placeholders. `subagent_type: uberdev:testers-<persona>` is a
#     substitution site, not a name; anything carrying < or > is skipped.
#   * skill names — in a CITATION, and ONLY there. TX11b hardcoded `continue`
#     on `turbox-fleet` because that is the skill's own namespaced name being
#     NAMED in prose, and the donor read backticked citations exclusively, so a
#     citation is the only position its carve-out ever covered. Widening it to
#     the dispatch position would admit all ~30 shipped skill names there, and
#     every one of them is a dead dispatch: `subagent_type:` resolves against
#     agents/ alone, so `subagent_type: uberdev:solve-fleet` fails at dispatch
#     time even though skills/solve-fleet/SKILL.md exists — which is exactly the
#     mid-run failure L10.1 exists to prevent, waved through by its own
#     exemption. L10.1 therefore admits `agent` and nothing else; L10.2 admits
#     all four kinds. L10.4 proves both directions on the same name.
#   * plugin-namespaced non-agents. Commands (uberdev:review-pr) and gh label
#     literals (uberdev:active, defined as *LABEL*='uberdev:…' in shipped shell)
#     are real artifacts that are not agents; L10.2 resolves against all four
#     kinds, and the label set is DERIVED from the corpus rather than listed.
#   * other namespaces. prkit rewrites uberdev: to prkit: wholesale, and
#     tests/prkit-verify.test.sh deliberately seeds `subagent_type:
#     prkit:ghost-agent` as a fixture. Only the uberdev: namespace is resolved,
#     because only this plugin's agents/ directory can answer for it — L10.4c
#     pins that a foreign namespace stays untouched.
L10_AGENT_DIR="$REPO_ROOT/plugins/uberdev/agents"
L10_SKILL_DIR="$REPO_ROOT/plugins/uberdev/skills"
L10_CMD_DIR="$REPO_ROOT/plugins/uberdev/commands"
# Label literals, derived: `<ANYTHING>LABEL<ANYTHING>='uberdev:name'`.
#
# The shell scrape alone is NOT the whole label vocabulary. `lib/solve_triage.py`
# BUILDS the tier-escalation label names by concatenation
# (`ESCALATION_LABEL_PREFIX + tier`), so no `uberdev:tier-…` literal exists in any
# shipped file for a `sed` to find, and every one of them resolved to `none`. That
# is not hypothetical: #619 collapsed the `large` rung but deliberately KEPT
# `uberdev:tier-large` as a migration alias so a pre-#619 ratchet write still
# lifts instead of being dropped as an unknown tier, and the retained alias is
# named in `skills/solve-pipeline/SKILL.md` and `docs/rfc/0019`. A scrape-only
# label set flags that prose as a dangling citation.
#
# So the escalation half is DERIVED from the shipped module at run time rather
# than transcribed here — the same discipline L10.4's kind lists follow. Reading
# `ESCALATION_LABELS` keys means a rung added, removed or aliased moves this set
# with it, and a transcribed copy cannot drift out of step with the classifier.
# Fails CLOSED: if the module cannot be loaded the extraction is empty and the
# citations red, which is the honest outcome for a corpus whose classifier is
# unreadable.
L10_LABELS="$( { while IFS= read -r l10_rel; do
  [ -n "$l10_rel" ] || continue
  [ -f "$REPO_ROOT/$l10_rel" ] || continue
  sed -n "s/.*LABEL[A-Za-z0-9_]*=[\"']uberdev:\([a-z0-9-]*\)[\"'].*/\1/p" "$REPO_ROOT/$l10_rel"
done <<<"$LINT_SH_LIST"
  python3 - "$REPO_ROOT/plugins/uberdev/lib/solve_triage.py" <<'L10_PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_l10_st", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
prefix = getattr(mod, "ESCALATION_LABEL_PREFIX", "uberdev:")
for name in getattr(mod, "ESCALATION_LABELS", {}):
    if name.startswith("uberdev:"):
        print(name[len("uberdev:"):])
L10_PY
} | sort -u)"

# _l10_kind NAME -> agent | skill | command | label | none
_l10_kind() {
  [ -r "$L10_AGENT_DIR/$1.md" ] && { printf 'agent'; return; }
  [ -r "$L10_SKILL_DIR/$1/SKILL.md" ] && { printf 'skill'; return; }
  [ -r "$L10_CMD_DIR/$1.md" ] && { printf 'command'; return; }
  grep -qxF "$1" <<<"$L10_LABELS" && { printf 'label'; return; }
  printf 'none'
}

# The two extractors. `subagent_type` is matched with either `:` or `=` after it
# because the corpus uses both spellings (Task(subagent_type=…) in agent
# frontmatter prose, `subagent_type: …` in skill steps).
L10_DISPATCH_RE='subagent_type[[:space:]]*[:=][[:space:]]*["'"'"']?uberdev:[a-z0-9<>_-]+'
L10_CITE_RE='`uberdev:[a-z0-9<>_-]+`'
_l10_names() {  # $1 = extractor regex
  local _rel
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    [ -f "$REPO_ROOT/$_rel" ] || continue
    grep -oE -e "$1" "$REPO_ROOT/$_rel" 2>/dev/null
  done <<<"$LINT_SH_LIST
$LINT_MD_LIST
$LINT_JS_LIST" | sed -e 's/.*uberdev://' -e 's/`$//' | sort -u
}
L10_DISPATCHED="$(_l10_names "$L10_DISPATCH_RE")"
L10_CITED="$(_l10_names "$L10_CITE_RE")"

# _l10_unresolved NAMES ALLOWED-KINDS -> the names that resolve to none of them.
_l10_unresolved() {
  local _names="$1" _allowed="$2" _n _k _bad=""
  while IFS= read -r _n; do
    [ -n "$_n" ] || continue
    case "$_n" in *"<"*|*">"*) continue ;; esac
    _k="$(_l10_kind "$_n")"
    case "$_allowed" in
      *"$_k"*) ;;
      *) _bad="$_bad $_n($_k)" ;;
    esac
  done <<<"$_names"
  printf '%s' "$_bad"
}
# The TWO policies, named once and consumed by BOTH the verdicts below and the
# L10.4 polarity fixtures. Restating a policy at its fixture site is what makes
# a polarity row a COPY of the rule instead of a test of it — it then stays
# green no matter what the verdict actually allows, which is the uncompared-copy
# defect this suite refuses elsewhere. One definition, four readers.
L10_DISPATCH_KINDS="agent"
L10_CITE_KINDS="agent skill command label"
L10_D_BAD="$(_l10_unresolved "$L10_DISPATCHED" "$L10_DISPATCH_KINDS")"
if [ -z "$L10_D_BAD" ]; then
  echo "  PASS  L10.1 every uberdev: agent type in a subagent_type position resolves in agents/"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.1 dangling agent type(s) in a dispatch position:$L10_D_BAD"
  echo "        a dead agentType fails at dispatch time, mid-run, after the claims are written"
  FAIL=$((FAIL + 1))
fi
L10_C_BAD="$(_l10_unresolved "$L10_CITED" "$L10_CITE_KINDS")"
if [ -z "$L10_C_BAD" ]; then
  echo "  PASS  L10.2 every cited \`uberdev:<name>\` resolves to an agent, skill, command or label"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.2 cited uberdev: name(s) that resolve to nothing shipped:$L10_C_BAD"
  FAIL=$((FAIL + 1))
fi
L10_D_N="$(grep -c . <<<"$L10_DISPATCHED")"
L10_C_N="$(grep -c . <<<"$L10_CITED")"
L10_A_N="$(ls "$L10_AGENT_DIR"/*.md 2>/dev/null | grep -c .)"
L10_L_N="$(grep -c . <<<"$L10_LABELS")"
if [ "$L10_D_N" -ge 6 ] && [ "$L10_C_N" -ge 30 ] && [ "$L10_A_N" -ge 30 ] && [ "$L10_L_N" -ge 1 ]; then
  echo "  PASS  L10.3 scanned $L10_D_N dispatched + $L10_C_N cited names against $L10_A_N agents and $L10_L_N label literal(s)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.3 an extractor collapsed: dispatched=$L10_D_N (floor 6) cited=$L10_C_N (floor 30) agents=$L10_A_N (floor 30) labels=$L10_L_N (floor 1)"
  FAIL=$((FAIL + 1))
fi
# L10.3b — the whole point of the port, MEASURED rather than asserted in prose.
# TX11b's extractor needs a BARE backticked span, `uberdev:<name>`, with the
# backtick immediately before the namespace. Not one dispatch site in the corpus
# is written that way: they are `subagent_type: uberdev:<name>` inside a WIDER
# backticked span, or a bold heading, or an agent frontmatter description, or an
# in-fence comment — in every case the character before `uberdev:` is a space or
# a colon, never a backtick. So the donor's extractor reaches zero of them, and
# this row measures how many sites and how many FILES the subagent_type
# extractor adds. The donor read one file.
_L10_SITE_AWK='
  $0 ~ DRE { sites++; if ($0 !~ BT) blind++ }
  END { printf "%d %d\n", sites + 0, blind + 0 }
'
L10_SITES=0
L10_BLIND=0
L10_SITE_FILES=0
while IFS= read -r l10_rel; do
  [ -n "$l10_rel" ] || continue
  [ -f "$REPO_ROOT/$l10_rel" ] || continue
  l10_pair="$(awk -v DRE="$L10_DISPATCH_RE" -v BT='`uberdev:' "$_L10_SITE_AWK" "$REPO_ROOT/$l10_rel" 2>/dev/null)" || l10_pair="0 0"
  l10_s="${l10_pair%% *}"
  l10_b="${l10_pair##* }"
  [ "${l10_s:-0}" -gt 0 ] || continue
  L10_SITE_FILES=$((L10_SITE_FILES + 1))
  L10_SITES=$((L10_SITES + l10_s))
  L10_BLIND=$((L10_BLIND + l10_b))
done <<<"$LINT_SH_LIST
$LINT_MD_LIST
$LINT_JS_LIST"
if [ "$L10_SITES" -ge 15 ] && [ "$L10_BLIND" -ge 10 ] && [ "$L10_SITE_FILES" -ge 4 ]; then
  echo "  PASS  L10.3b $L10_BLIND of $L10_SITES dispatch sites across $L10_SITE_FILES files are invisible to a bare-backtick extractor"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.3b sites=$L10_SITES (floor 15) backtick-invisible=$L10_BLIND (floor 10) files=$L10_SITE_FILES (floor 4)"
  echo "        the subagent_type extractor is adding nothing over the donor's backtick-only one,"
  echo "        so the blindness this port exists to fix has not actually been fixed"
  FAIL=$((FAIL + 1))
fi
# L10.4 — polarity, through the SAME _l10_unresolved / _l10_kind AND the same
# two policy variables the verdicts read. Every case is stated in the position
# it belongs to, because the two positions do not agree: a skill name is a
# legitimate CITATION and a dead DISPATCH, and a row that only ever tries it in
# one position cannot tell the two policies apart.
L10_FX_BAD="$(_l10_unresolved "$(printf 'ghost-agent\n')" "$L10_DISPATCH_KINDS")"
L10_FX_TMPL="$(_l10_unresolved "$(printf 'testers-<persona>\n')" "$L10_DISPATCH_KINDS")"
L10_FX_SKILL_CITE="$(_l10_unresolved "$(printf 'turbox-fleet\n')" "$L10_CITE_KINDS")"
L10_FX_SKILL_DISPATCH="$(_l10_unresolved "$(printf 'turbox-fleet\n')" "$L10_DISPATCH_KINDS")"
L10_FX_LABEL="$(_l10_unresolved "$(printf 'active\n')" "$L10_CITE_KINDS")"
L10_FX_LABEL_STRICT="$(_l10_unresolved "$(printf 'active\n')" "$L10_DISPATCH_KINDS")"
L10_FX_ERR=""
[ -n "$L10_FX_BAD" ]            || L10_FX_ERR="$L10_FX_ERR a-nonexistent-agent-was-not-flagged"
[ -z "$L10_FX_TMPL" ]           || L10_FX_ERR="$L10_FX_ERR a-template-placeholder-was-flagged"
[ -z "$L10_FX_SKILL_CITE" ]     || L10_FX_ERR="$L10_FX_ERR a-skill-name-was-flagged-as-a-citation"
[ -n "$L10_FX_SKILL_DISPATCH" ] || L10_FX_ERR="$L10_FX_ERR a-skill-name-passed-the-dispatch-rule"
[ -z "$L10_FX_LABEL" ]          || L10_FX_ERR="$L10_FX_ERR a-label-citation-was-flagged"
[ -n "$L10_FX_LABEL_STRICT" ]   || L10_FX_ERR="$L10_FX_ERR a-label-passed-the-dispatch-rule"
if [ -z "$L10_FX_ERR" ]; then
  echo "  PASS  L10.4 the resolver flags a ghost agent, a skill and a label in a dispatch position, and spares template / skill / label citations"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.4 the resolver is not discriminating:$L10_FX_ERR"
  FAIL=$((FAIL + 1))
fi
# L10.4b — the foreign-namespace carve-out, on the SAME extractor. prkit rewrites
# uberdev: to prkit: wholesale and tests/prkit-verify.test.sh seeds exactly this
# line as a fixture; if the extractor stripped the namespace instead of matching
# it, that fixture would resolve here as a ghost agent.
L10_FX_FOREIGN="$(printf 'subagent_type: prkit:ghost-agent\nsubagent_type: uberdev:code-fixer\n' \
  | grep -oE -e "$L10_DISPATCH_RE" | sed 's/.*uberdev://' | sort -u)"
if [ "$L10_FX_FOREIGN" = "code-fixer" ]; then
  echo "  PASS  L10.4b the dispatch extractor takes the uberdev: namespace only and ignores prkit:"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L10.4b the dispatch extractor mis-read a foreign namespace: got '$L10_FX_FOREIGN', expected 'code-fixer'"
  FAIL=$((FAIL + 1))
fi

echo
echo "== L11: the /goal surface uses no shell-evaluation primitive =="
# Ported from tests/goal.test.sh G19.no-eval / G19.no-bash-c, which banned both
# on ONE hardcoded path ($GOAL_LIB = lib/goal-state.sh). The T3 hard rule is
# about the /goal surface, not about one file of it: lib/goal-state.sh is
# re-sourced from the goal-pipeline SKILL.md fences, and lib/goal-phase0.sh,
# goal-phase1.sh, goal-phase3.sh, goal-watch.sh, goal-abort.sh and
# skills/goal-pipeline/workflow.js all read the same attacker-influenced
# run-state records. tests/goal-state-sidecar.test.sh writes `GOAL_ID=x; touch
# …/PWNED` into one and asserts the marker never appears — that proof holds only
# while NOTHING on the surface evaluates the value it read.
#
# The surface is DERIVED from the corpus by path, so a new lib/goal-*.sh joins
# it the day it is added, with no edit here — the failure mode of the donor's
# single hardcoded path.
#
# CARVE-OUT: the shared projection's comment and backtick rules. lib/goal-state.sh
# names this very assertion in a comment at its dual-shell indirect reader, and
# commands/goal.md discusses evaluation in prose. The issue's other two
# carve-outs — the live `eval` harness in tests/goal-state-zsh.test.sh and the
# prose mention in tests/goal-state-sidecar.test.sh — are outside this corpus by
# construction: L0 is scoped to plugins/uberdev, and a test harness evaluating
# its own probe specs is not the shipped surface the T3 rule is about.
L11_EVAL='ev'; L11_EVAL="${L11_EVAL}al"
L11_RE="(^|[^A-Za-z0-9_])${L11_EVAL}[[:space:]]|(^|[^A-Za-z0-9_])bash[[:space:]]+-c([[:space:]]|$)"
L11_SURFACE="$(while IFS= read -r l11_rel; do
  [ -n "$l11_rel" ] || continue
  case "$l11_rel" in
    *goal-*|*/goal.md) printf '%s\n' "$l11_rel" ;;
  esac
done <<<"$LINT_SH_LIST
$LINT_MD_LIST
$LINT_JS_LIST")"
L11_HITS=""
while IFS= read -r l11_rel; do
  [ -n "$l11_rel" ] || continue
  [ -f "$REPO_ROOT/$l11_rel" ] || continue
  l11_out="$(_lint_ban "$l11_rel" "$L11_RE" "" "$REPO_ROOT/$l11_rel")"
  [ -z "$l11_out" ] || L11_HITS="$L11_HITS$l11_out
"
done <<<"$L11_SURFACE"
L11_N="$(grep -c . <<<"$L11_SURFACE")"
if [ -z "$L11_HITS" ]; then
  echo "  PASS  L11.1 no shell-evaluation primitive on the $L11_N-file /goal surface (T3 hard rule)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L11.1 shell-evaluation primitive on the /goal surface:"
  sed 's/^/        /' <<<"$L11_HITS"
  echo "        cause:  run-state records are attacker-influenced; evaluating one executes it"
  FAIL=$((FAIL + 1))
fi
# L11.2 — the denominator. Two directions again: the surface must be big enough
# to be the surface, and it must contain the file the donor named, or a path
# rule that stopped matching would leave this row asserting nothing.
L11_HAS_LIB=no
grep -qxF 'plugins/uberdev/lib/goal-state.sh' <<<"$L11_SURFACE" && L11_HAS_LIB=yes
if [ "$L11_N" -ge 5 ] && [ "$L11_HAS_LIB" = yes ]; then
  echo "  PASS  L11.2 the derived /goal surface holds $L11_N files including lib/goal-state.sh (floor 5)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  L11.2 the derived /goal surface holds $L11_N files (floor 5), lib/goal-state.sh present: $L11_HAS_LIB"
  FAIL=$((FAIL + 1))
fi
_lint_ban_case "L11.3a live eval of a read value" flag "$L11_RE" "" \
  "$(printf '%s "$(printf "%%s" "$record")"\n' "$L11_EVAL")"
L11_BASHC='bash '; L11_BASHC="${L11_BASHC}-c"
_lint_ban_case "L11.3b live child-shell evaluation" flag "$L11_RE" "" \
  "$(printf '%s ". $lib; uberdev_goal_read_run_state"\n' "$L11_BASHC")"
_lint_ban_case "L11.3c a comment naming the assertion" clean "$L11_RE" "" \
  "$(printf '# never a shell-evaluation primitive, which the T3 rule (G19.no-%s) forbids\n' "$L11_EVAL")"
_lint_ban_case "L11.3d backticked prose naming the primitive" clean "$L11_RE" "" \
  "$(printf 'The validating reader must NOT `%s` or source the value it read.\n' "$L11_EVAL")"

echo
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

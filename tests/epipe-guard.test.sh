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
# git's pathspec `*` crosses `/`, so the one glob covers agents/, commands/,
# docs/, hooks/ and skills/** in a single enumeration.
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
echo "==================================================================="
echo "  PASS=$PASS  FAIL=$FAIL"
echo "==================================================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

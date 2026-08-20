#!/usr/bin/env python3
"""tests/launcher_edge_ids.py — every run-tree edge id the solve launcher names
must resolve to a real edge in the run-tree manifest (issue #536).

THE CLASS. `plugins/uberdev/lib/solve-launcher.sh` set
`UBERDEV_ROOT_EDGE_ID="solve.lead.$TIER"`, and `$TIER` is one of
trivial|small|medium — so every value that line could produce named an
edge that does not exist in `plugins/uberdev/policy/solve-run-tree-v1.json`
(whose only `solve.lead.*` edges WERE `.orchestrator`, `.brainstorm` and
`.finish_branch` — themselves orphans, dispatched by nothing, retired by #607, so
that namespace now holds no edge at all: see RETIRED_PREFIXES under L1). Nothing
read the variable, so nothing ever noticed. This is the #370 shape — a
declaration naming a pipeline surface that nobody compares against the tree — on
the shell-runtime side; issue #510 fixed the manifest side with
`tests/solve-run-tree-scope.test.sh`.

WHAT IT CHECKS. Four rules, all anchored on the manifest as the single source
of truth. What RESOLVES is the manifest's business alone — no edge id is
hardcoded here, so renaming an edge in the manifest changes what this guard
accepts. What is IN SCOPE is that vocabulary plus one declared list of retired
namespaces (`RETIRED_PREFIXES`), and the two are held from drifting by a
precondition error rather than left to agree by luck; L1 says why.

  L1 — LITERAL RESOLUTION. Guarded prefixes are the tree's own plus the ones
       this file declares retired. DERIVED: every key of `edges` with three or
       more dot-segments whose first segment is `solve` contributes
       `<seg0>.<seg1>.` (today: `solve.issue.`, and nothing else). DECLARED:
       every entry of `RETIRED_PREFIXES` (today: `solve.lead.`). Every
       `<prefix>[A-Za-z0-9_${}<>-]+` token in the launcher — in code, in a
       comment, in a string alike — must be an exact key of `edges`. The
       vocabulary is closed, so an UNRESOLVABLE id is a WRONG id:
       `solve.lead.$TIER`, `solve.lead.${TIER}` and `solve.lead.<tier>` are
       violations by construction. Requiring a third segment is what keeps the
       launcher's `commands/solve.md` references out of the match set.

       WHY THE DECLARED HALF EXISTS (#607). Derivation alone made this guard's
       reach an ACCIDENT of the manifest's contents. The three `solve.lead.*`
       edges were orphans — `role: null`, `route: null`, dispatched by nothing —
       and they were also the SOLE source of the `solve.lead.` prefix, so
       retiring them silently un-guarded the exact namespace #536 was filed
       about: with the tree at 51 edges and no declared half, the E4 row of
       tests/solve-run-tree.test.sh (a fictional `solve.lead.$TIER` in the
       carrier-failure string) went rc 1 -> rc 0, measured. A retired prefix
       therefore stays GUARDED and becomes permanently UNRESOLVABLE — every
       token under it is a finding by construction, since `edges` can hold no key
       there. That converts a coupling nobody declared into one that is written
       down, and the two halves may never disagree: an `edges` key under a
       retired prefix is a PRECONDITION ERROR (exit 2), not a verdict, because at
       that point the prefix is both retired and live and no answer about the
       launcher would mean anything. E71 and E72 in tests/solve-run-tree.test.sh
       pin the declaration, the refusal and its want-0 floor.

  L2 — ASSIGNMENT-SITE BACKSTOP. Every line assigning a `*EDGE_ID` variable must
       have a bare double-quoted literal RHS (no `$`, no backtick, no backslash)
       that is a key of `edges`. This catches a future
       `UBERDEV_ROOT_EDGE_ID="$SOMETHING"`, whose value L1's token scan cannot
       see at all.

  L2b — BINDING SITES THAT WRITE NO `NAME=`. `printf -v NAME …` and the `read`
       builtin bind a variable without ever putting `NAME=` on the line, so L2
       cannot see them and L1 cannot either once the value is composed from a
       format string (`printf -v UBERDEV_ROOT_EDGE_ID 'solve.lead.%s' "$TIER"`
       leaves no `solve.lead.` token in the source at all). Every name such a
       command binds is classified: one matching `*EDGE_ID` is a violation
       regardless of the VALUE — an edge id is a closed literal vocabulary, so
       composing one at runtime is the defect whether or not this particular
       run would have produced a real id. A target the text cannot decide
       (`printf -v "$_name"`) is a violation too: the checker cannot prove a
       name it cannot read is not an edge id, so it refuses instead of guessing.
       The `read` option grammar is modelled rather than approximated —
       `-a -d -i -n -N -p -t -u` take an argument and the rest do not, which is
       what keeps `read -r UBERDEV_ROOT_EDGE_ID _b` from being read as "`-r`
       took the first word, `_b` is the only binding" and classified clean.
       `read -a NAME` binds NAME, so that argument is a target, not a value.
       The command is read ONLY where the shell would read one, and EVERYWHERE
       the shell would: the line is walked the way the shell reads it, carrying
       one bit of state — may a command word stand here. Text that RUNS NOTHING
       yields no verb (a comment, an argument, a heredoc body), and a command
       that DOES run yields one however it is spelled, because quoting a command
       word removes nothing but alias expansion and a redirection may precede
       one. So `"read" -r VAR`, `'printf' -v VAR`, `rea"d" -r VAR`,
       `\read -r VAR` and `>/dev/null read -r VAR` are every one of them the
       same finding as a bare `read` — exactly as the transparent prefixes `!`,
       `command`, `builtin`, `time` and an inline `NAME=value` are. That scope
       covers the ARGUMENTS as well as the verb, because the words after a `read`
       stop at a comment exactly as the search for the verb does.

  L3 — ANTI-VACUITY FLOOR. Tree-derived and positive, not a bare count: L1 must
       have matched at least one token, AND `tree["root_edge_id"]` must be among
       the matched tokens. A reword that quietly drops the real root edge reds
       with the edge id named, rather than passing because there is nothing left
       to disagree with.

DECLARED LIMITS — read these before trusting a green run. A guard whose name
promises more than its predicate delivers is the very class this file exists to
close, so the gap is written down rather than left implied.

  * NOT A TREE-CONSISTENCY CHECKER. It deliberately does NOT assert that
    `root_edge_id` is a key of `edges` — that invariant belongs to
    `tests/solve-run-tree.test.sh`, and duplicating it here would give a
    mutated-tree fixture two possible causes and destroy the attribution. The
    ONE precondition it does read across the two inputs is the retired-prefix
    collision under L1, and the distinction is not a loophole: that one compares
    the tree against a declaration THIS FILE OWNS, which no other guard knows
    exists, so there is nowhere else it could live and no second cause it could
    be confused with.
  * NOT A READER CHECK. It proves an emitted id RESOLVES; it cannot prove any
    descendant ever reads it. The orphan half of #536 is a human judgement.
  * L1 AND L2 ARE NOT SHELL-AWARE. For those two the launcher is scanned as
    text: a `solve.lead.*` token inside a comment or a heredoc is a finding on
    purpose, because the comment prose is exactly where the fictional
    `solve.lead.<tier>` id survived review. This bullet stops at L1 and L2 —
    L2b IS shell-aware about where a command may appear, and the bullet below
    says how far that goes.
  * TAIL EXCLUDES `.`. A token stops at its third segment, so a future
    four-segment `solve.<area>.<a>.<b>` edge would be matched as
    `solve.<area>.<a>` and reported unresolvable. That is a loud false red to be
    fixed here, never a silent pass.
  * L2 IS LINE-ANCHORED — L2b IS NOT. This bullet describes `ASSIGNMENT` only:
    an `EDGE_ID=` tucked mid-line after a `;` is invisible to L2. L2b anchors on
    a COMMAND BOUNDARY instead of on `^`, and the boundary set is exactly the
    characters `; & | ( ) {` plus the keywords
    `while`/`until`/`if`/`elif`/`then`/`else`/`do` — so a `printf -v`/`read`
    after a `;`, a `&&`, a `$(`, a case arm's `)` or a group's `{` is in scope
    (measured rc 1 each: the mid-line row, the `while IFS= read` loop head,
    `trivial) read -r UBERDEV_ROOT_EDGE_ID ;;` and `{ read -r … ; }`), and so is
    one reached through the transparent prefixes `!`, `command`, `builtin`,
    `time`, an inline `NAME=` or a REDIRECTION (measured rc 1 each:
    `if ! read -r UBERDEV_ROOT_EDGE_ID; then :; fi`, `command read -r …`,
    `builtin printf -v …`, `time read -r …`, `IFS= command read -r …`,
    `>/dev/null read -r …`, `2>/dev/null read -r …`, `>&2 read -r …`,
    `command >/dev/null read -r …`) — every one of those nine executed under
    bash and read back, because a shape the rule reaches is only worth reaching
    if it BINDS. The one ORDER that does not is `command IFS= read -r …`: once
    `command` has taken the command-word position an assignment word is no longer
    recognised, so bash answers `IFS=: command not found` and binds nothing. The
    walk reports it anyway (rc 1) — an over-approximation in the loud direction,
    the same trade as the `$( … )` one below, and not a shape anybody writes.
    `}` is NOT a boundary: it closes a group
    rather than opening a command. The keywords count only WHERE A COMMAND WORD
    MAY STAND, which is the shell's own rule and not merely a tightening:
    `echo if read -r UBERDEV_ROOT_EDGE_ID` runs `echo` with three arguments and
    binds nothing, so it is rc 0 (it was rc 1 while the boundary was matched as
    text anywhere on the line).
  * L2b READS ONLY COMMAND TEXT — L1 READS EVERYTHING, and here the asymmetry IS
    a design choice rather than a side effect. L1 must see comments, because the
    fictional `solve.lead.<tier>` id survived review inside comment prose. L2b
    must not, because a comment binds nothing and treating prose as a command
    manufactures findings out of English: `# Inconclusive (read blip or comment
    not yet indexed)` — a real line of solve-launcher.sh, quoted here rather
    than numbered because a number for it went stale before it was written and
    the same wrong one reached three rows of tests/solve-run-tree.test.sh —
    parses as a `read`
    binding the six words after it, and adding any `$VAR` to that sentence used
    to red this guard (measured rc 1 before, rc 0 now). An ARGUMENT is out of
    scope for the same reason (`echo "a; printf -v UBERDEV_ROOT_EDGE_ID x"`,
    rc 0), while the code BEFORE a trailing `#` stays in scope
    (`printf -v UBERDEV_ROOT_EDGE_ID '%s' "$V"  # bind it`, rc 1).
    WHAT PUTS THAT ARGUMENT OUT OF SCOPE IS ITS POSITION, NOT ITS QUOTES, and for
    one round the rule had that backwards: it blanked every quoted run before
    looking for a verb, so `echo "…"` came out right for the wrong reason and
    `"read" -r UBERDEV_ROOT_EDGE_ID` — a real binding, since quoting a command
    word removes only alias expansion — came out rc 0. The walk keeps the two
    apart: after `echo` no command word may stand until a boundary, whatever the
    next word is quoted like, while at a command position a word is unquoted
    before the verb test and `rea"d"` is `read`.
    THE ARGUMENT LIST IS SCOPED THE SAME WAY, and for one round it was not: the
    site search ran on a blanked copy of the line while
    the words after the verb were taken from the raw line, so a TRAILING comment
    on a real command became its target list. `read -r line  # read the value out
    of $TMPDIR` yielded the "bound names" line/#/read/the/value/out/of/$TMPDIR
    and was rc 1. The word scan now stops at a `#` that STARTS a word, which is
    the shell's own rule and not the same thing as treating `#` as a terminator:
    `${#A[@]}` must not split, and
    `printf -v UBERDEV_ROOT_EDGE_ID '%s' "${#A[@]}"` is rc 1. An argument keeps
    its QUOTES, which is the one place the spelling still carries meaning — the
    verb is unquoted before the verb test, but `"$_name"` is a target the text
    cannot decide while `'$_name'` is a literal — so
    `read -p "Enter a name: " UBERDEV_ROOT_EDGE_ID` keeps its prompt whole and is
    rc 1.
    A heredoc BODY is NOT command text either, and this is the strongest of the
    three: nothing a body contains can bind a variable in the CURRENT shell. An
    unquoted body is expanded, but every expansion that could run a command
    (`$( … )`, a backtick) runs it in a SUBSHELL, so a binding reached that way
    binds nothing that outlives it (measured rc 0). A `$( … )` or a `|` written
    directly IN CODE is still reported (rc 1 each), and the two rationales only
    look opposed. `echo x | read -r VAR` genuinely binds under zsh, whose last
    pipeline element runs in the current shell, and this repo's shell surfaces
    run under both. `$(read -r VAR)` binds in neither, so reporting it IS an
    over-approximation — a deliberate one, in the direction that costs a loud
    false red rather than a silent miss, and one a body cannot be given because
    the launcher's bodies are prose that would red on a wording edit. What a body
    does contain is prose. THIS IS THE ONE PLACE THE COUNT LIVES, cited here and
    referred to everywhere else: the launcher has SEVEN, and `CLAIM_BODY` (:799),
    the claim JSON (:871), the four agent prompts (:967, :984, :1006, :1022) and
    `RELEASE_BODY` (:1314) are all user-facing English with `$VAR` throughout.
    Naming it once is not tidiness. A round shipped this count in two docstrings
    at the same time and they disagreed -- `seven` here, `three` in
    `heredoc_body_lines` -- with nothing in the file able to compare them, which
    in a file whose whole thesis is that a declaration must be a measurement is
    the defect and not the typo. Adding one clause
    to the live `Auto-clears on /merge or issue close.` line so that it reads
    `... close (read $ISSUE_NUM to confirm).` was measured rc 1 before, rc 0 now.
    A binding written at column 0 inside a body is therefore rc 0 as well; that
    red was an over-approximation rather than coverage, since it could not have
    happened. Three costs, all measured: a delimiter outside
    `[A-Za-z_][A-Za-z0-9_]*` is not modelled, so `cat <<X.EOF` leaves its body in
    scope (rc 1, the safe direction); an opener whose delimiter never arrives
    is treated as no opener at all (`cat <<X_NEVER` plus a binding is rc 1),
    which is what stops a `<<WORD` written literally inside a double-quoted
    string from blanking the rest of the file
    (`echo "a <<NOTADELIM b"; printf -v UBERDEV_ROOT_EDGE_ID ...` stays rc 1);
    and — the one cost a HEREDOC body does not pay — the scan is LINE-ORIENTED
    and carries no cross-line quote state, so the continuation lines of a
    MULTI-LINE DOUBLE-QUOTED STRING are read as command text. That third one is
    not latent. The launcher writes most of its prose through heredocs, but four
    multi-line double-quoted strings are open in it today: `DISPATCH_BACKEND=
    "$(uberdev_read_enum …` (:265) and the three embedded python programs at
    :365, :1180 and :1261 — the last being the run carrier of #536, this file's
    own subject. Inserting the prose line `read the $ISSUE_NUM log` as a
    continuation of any one of the four is rc 1 apiece, and the same line without
    the `$` is rc 0 apiece, so the cost is a loud false red on an unrelated
    wording edit — one `$` away, in the same safe direction as the two costs
    above rather than a silent miss. It is NOT closed because carrying that state
    would let an unbalanced `"` in a comment blank the rest of the file, which is
    the failure the unterminated-opener rule above is written to forbid; `E61` in
    tests/solve-run-tree.test.sh pins the behaviour so that closing it cannot
    leave this paragraph stale, and asserts this sentence's own presence so that
    deleting the paragraph cannot leave that row pinning nothing.
    A heredoc whose body IS executed downstream is a residue mechanism, not a
    hole in this scoping: see the EXECUTED-BODY entry of the residue register
    below. Named by its content and not by its ordinal, because the round that
    wrote this sentence pointed it at "entry 7", which is the CORPUS limit -- a
    reference that rots the moment an entry is added or removed, and one that
    reads as intact while sending the reader somewhere else entirely.
    BOTH HALVES OF THE TRACKER ARE PINNED, because for one round neither was and
    the omission was invisible: the body rows (E28-E30) exercise the tracker only
    through an UNQUOTED `cat <<WORD` that terminates, so deleting the
    unterminated-opener rule, or teaching the delimiter scan to skip double-quoted
    text, each left every row from E1 to E30 passing while L2b went silent over
    part of the file. E32 pins the first and E31 the second — the latter against
    the launcher's own `CLAIM_BODY="$(cat <<EOF` form, which is the whole reason
    the scan looks THROUGH a double quote and not the obvious way round.
  * NO SHELL-KEYWORD FILTER on `read` targets, deliberately, though an earlier
    revision of this rule called for one (`do done then else fi in`). It is
    neither sufficient nor sound. NOT SUFFICIENT: it catches none of the prose false positives above
    (`blip`, `or`, `comment`, `not`, `yet`, `indexed` are not keywords), which is
    why scoping the TEXT rather than filtering the WORDS is what fixed them.
    NOT SOUND: with the text scoped, a keyword that reaches the target list is
    genuinely in target position, and `read -r x do` binds `do` exactly as it
    binds `x`, so filtering it would invent a blind spot in order to fix nothing.
    An earlier wording of this bullet argued instead that a keyword could no
    longer REACH the list. That was false while the argument tokeniser still read
    the raw line — `read -r x  # do not use $y` put `do` in it, measured — and it
    is why the reason is now stated as soundness rather than as reachability. A
    filter that fixes no measured case is the "guard whose name outruns its
    predicate" shape this file exists to police; so is a reason for omitting one
    that measurement refutes.
  * L2b RESIDUE — eight mechanisms that bind an edge id and reach neither L1 nor
    L2b, each measured against the live launcher rather than reasoned about
    (insert the line, run the checker, read `$?`). The set is the CLOSED list of
    what escapes, so it is re-measured whenever the rule moves — and a review
    round found the claim false while the site search was still a regex over a
    blanked copy of the line: five shapes escaped that the list did not name.
    `"read" -r VAR`, `'printf' -v VAR`, `rea"d" -r VAR`, `\read -r VAR` and
    `>/dev/null read -r VAR` were rc 0 apiece, and every one of them binds in the
    current shell under both `bash -c` and `zsh -c`. They are not on this list
    because they are no longer residue: walking the line the way the shell reads
    it closed all five (rc 1 apiece now), and E35-E39 in
    tests/solve-run-tree.test.sh pin them shut. A SECOND round found five more,
    and they say what kind of claim "closed" is: the transparent prefixes above
    parse OPTIONS OF THEIR OWN, and the walk shut the command position on the
    option instead of reaching the verb behind it. `command -p read -r VAR`,
    `command -- read -r VAR`, `builtin -- read -r VAR`, `time -- read -r VAR` and
    `eval -- read -r VAR` were rc 0 apiece and every one of them binds under bash,
    executed and read back. A THIRD round found the same hole one SPELLING
    further in, which is what fixes the size of the claim: modelling an option as
    an exact WORD reached `command -p read -r VAR` and left `command -pp read -r
    VAR` — rc 0, and binding, because bash parses `command`'s options with getopts
    and `-pp` is one word carrying two `-p` flags. That is the attached spelling
    the file already treats as a member of its own everywhere else (`printf -vNAME`
    is E34 beside `printf -v NAME`, and E50 pins `read -aNAME` while the spaced
    form is unmoved), so the one prefix whose option can be attached to itself
    could not be the exception. None of the eleven is on this list: `PREFIX_OPTIONS`
    above models each prefix's option WORDS, `PREFIX_CLUSTERS` models the attached
    letters, and E62-E67 plus E69 pin every member of both, including the want-0
    direction. A closed list that omits a live, executed,
    rc-0 binding form is a declaration whose predicate is disjoint from what it
    claims -- the shape this whole file exists to police -- so the standard for
    landing on it is that the mechanism is genuinely out of reach, never that
    reaching it was more work. What remains below is what that walk still cannot
    see, re-measured against it.
      1. ANY BUILTIN THAT RE-PARSES A QUOTED PAYLOAD AND RUNS IT IN THE CURRENT
         SHELL. Stated as a CLASS rather than as a verb, because for one round it
         was written as a fact about `eval` and a second builtin with exactly that
         property went unnamed underneath it. Two of them today, each measured:
         `eval` that COMPOSES the id so no literal token survives —
         `eval "UBERDEV_ROOT_EDGE_ID=solve.$AREA.$NAME"`, rc 0 — which also covers
         an `eval` whose PAYLOAD is itself a binding command
         (`eval "printf -v UBERDEV_ROOT_EDGE_ID '%s' \\"$V\\""`, rc 0); and
         `trap`, whose payload is re-parsed and run in the CURRENT shell at exit
         or on a signal — `trap 'printf -v UBERDEV_ROOT_EDGE_ID "%s" "$V"' EXIT`,
         rc 0, and executed under bash: the EXIT handler prints the bound value
         back, and `trap 'read -r UBERDEV_ROOT_EDGE_ID <<<"midrun"' USR1` binds
         mid-run on a `kill -USR1 $$`. So neither is the SUBSHELL case the
         heredoc and `$( … )` reasoning above disposes of. In both the payload is
         ONE quoted word the walk never scans, though for different reasons:
         `eval` is transparent, so the walk reaches its payload and stops there
         because that word's literal text is not a verb, while `trap` is not
         transparent at all — it takes a payload and never a command word, so
         the command position is already shut on `trap` itself. Either way the
         mechanism is the re-parse, not the `printf` or the `read` inside it.
         And the class is genuinely out of reach rather than merely more work —
         re-parsing that string is the `eval` problem itself — which is the
         admission criterion stated above.
      2. a `declare -n`/`local -n` nameref whose write is a plain assignment to
         the alias — `declare -n _r=UBERDEV_ROOT_EDGE_ID; _r="$X"`, rc 0.
      3. indirect `eval` through a variable name — an `eval` whose payload is
         `$_n=$V` with the inner quoting escaped, rc 0.
      4. A VERB THAT IS NOT A LITERAL WORD, the re-parsed-payload entry above one
         step out (named by content, for the reason the scoping bullet gives):
         `$CMD -v UBERDEV_ROOT_EDGE_ID '%s' "$V"` and
         `"$(echo printf)" -v UBERDEV_ROOT_EDGE_ID …` are rc 0 each. The walk
         removes QUOTING from a command word, which changes nothing about what
         runs, but it does not EXPAND one — an expansion's value is not in the
         text, so guessing at it is the `eval` problem again.
      5. ANY BINDER THAT IS NOT `printf -v` OR `read`. Only those two verbs are
         modelled, so every other builtin that writes a name escapes, measured
         rc 0 each: `mapfile`/`readarray -t UBERDEV_ROOT_EDGE_ID`,
         `getopts ":a" UBERDEV_ROOT_EDGE_ID`, and a `for`/`select` loop variable
         (`for UBERDEV_ROOT_EDGE_ID in a b; do`). Each of the three can carry an
         arbitrary string, so each could hold a composed edge id.
      6. a binding split across a backslash continuation, since the scan is
         line-oriented — `printf -v` on one line and the target on the next,
         rc 0.
      7. THE CORPUS, not the rule: exactly one `--launcher` path is read, so the
         identical binding in any other file is unreachable. Measured: the
         launcher scan is rc 0 while `plugins/uberdev/lib/goal-state.sh` carries
         a live indeterminate `printf -v "$_prior_key"` this rule would flag if
         it were ever pointed at that file. Widening the corpus is #583.
      8. a heredoc body that is EXECUTED downstream rather than written out —
         `bash <<XEOF` … `printf -v UBERDEV_ROOT_EDGE_ID "%s" "$V"` … `XEOF`,
         measured rc 0. The body is data to this checker (see the scoping bullet
         above), so a binding composed there escapes L2b exactly as an `eval`
         payload does in the re-parsed-payload entry; a literal token in the same
         body is still
         caught, by L1 (`bash <<XEOF` with `UBERDEV_ROOT_EDGE_ID=solve.lead.$TIER`
         inside is rc 1, naming `solve.lead.$TIER`). The launcher's own heredocs
         are all `cat`, none of them a shell -- for how many that is, see the
         scoping bullet above, which is where the count lives -- so this is a
         residue with no live instance rather than a hole under one.
    "Declared" means the MECHANISM is invisible, not that the form always
    passes. The SIMPLE shapes of 1 and 2 are both caught today, by L1, because
    the composed value still leaves a literal token in the source:
    `eval UBERDEV_ROOT_EDGE_ID=solve.lead.$TIER` and
    `declare -n _r=UBERDEV_ROOT_EDGE_ID; _r="solve.lead.$TIER"` are each
    measured rc 1, naming `solve.lead.$TIER`.

INTERFACE.

    python3 -I -B tests/launcher_edge_ids.py --tree <path|-> --launcher <path|->

Exactly one of the two may be `-` and is then read from stdin; both `-` is a
usage error, because stdin has a single reader. That is what lets a caller
mutate either side in memory, with no temp file, in either direction.

OUTPUT. Findings go to stderr in two shapes. Line-anchored (L1, L2, L2b):
`<path-or-->:<line>: <reason>`. Whole-file (L3, which has no line to point at):
`<path-or-->: <reason>`. A clean run prints one summary line to stdout.

EXIT CODES.  0 = clean · 1 = one or more violations · 2 = usage, I/O, JSON or
precondition error.

PORTABLE. Standard library only. No temp file, no subprocess, no `git`, no
network, no digest. Both inputs are read as BYTES and decoded as UTF-8
explicitly — `shape-checks-windows` runs a cp1252-default interpreter — and
`str.splitlines()` then absorbs the CRLF of an `autocrlf=true` checkout. Emitted
findings are ASCII — the prose in this docstring is not what a cp1252 stderr has
to encode, but a finding is, so the dashes inside one are plain `--`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import NamedTuple

# Tail of a guarded token: the third segment of an edge id, plus the shell and
# placeholder characters that make a WRONG id look like a right one
# (`$TIER`, `${TIER}`, `<tier>`). `.` is excluded — see DECLARED LIMITS.
TOKEN_TAIL = r"[A-Za-z0-9_${}<>-]+"

# Namespaces that stay GUARDED after their last edge is gone (#607). L1's
# prefixes are otherwise DERIVED from `edges`, which made the guard's reach an
# accident of the manifest's contents; retiring the three orphan `solve.lead.*`
# edges would have taken the `solve.lead.` namespace out of scope entirely and
# let #536's own defect back in. An entry here is permanently unresolvable by
# construction — `edges` may hold no key under it, and `token_pattern` refuses
# outright if one appears — so a token under it is always a finding. Written as
# a tuple so `str.startswith` takes it whole. See the WHY THE DECLARED HALF
# EXISTS paragraph under L1.
RETIRED_PREFIXES = ("solve.lead.",)

# L2's assignment sites. The optional declaration keyword widens the plan's
# `^[ \t]*[A-Z0-9_]*EDGE_ID=` so that `export UBERDEV_ROOT_EDGE_ID="$X"` — the
# exact shape L1 cannot see — is caught rather than waved through.
ASSIGNMENT = re.compile(r"^[ \t]*(?:export|local|declare|readonly|typeset)?[ \t]*[A-Z0-9_]*EDGE_ID=(.*)$")

# A bare double-quoted literal: no expansion, no command substitution, no
# escape. A trailing shell comment is tolerated; nothing else is.
BARE_LITERAL = re.compile(r'^"([^"$`\\]*)"(?:[ \t]+#.*)?$')

# --- L2b -------------------------------------------------------------------
# Where a command may START: after one of these characters, or at the start of
# the line.
BOUNDARY_CHARS = ";&|(){"

# `while`/`until`/`if`/`elif` are here alongside `then`/`else`/`do` because
# `while IFS= read -r NAME; do` is THE idiomatic binding loop head, and it is
# reachable from none of the others. They count as keywords only WHERE A COMMAND
# WORD MAY STAND, which is the shell's own rule: `echo if read -r VAR` runs
# `echo`, and the `if` in it is an argument that opens nothing.
COMMAND_KEYWORDS = frozenset(("then", "else", "do", "while", "until", "if", "elif"))

# Words that may sit between the boundary and the verb WITHOUT changing what the
# verb binds, so none of them may be a way past this rule:
#   `!`                  negation — sets the exit status, binds nothing itself,
#                        and `if ! read -r VAR; then` is the idiomatic loop head
#                        of the `while IFS= read` form one `!` away;
#   `command`/`builtin`  lookup prefixes — they suppress FUNCTION lookup, but the
#                        builtin still runs in the CURRENT shell and still binds;
#   `time`               a keyword whose pipeline likewise runs in this shell;
#   `eval`               re-parses the words it is given and runs the result in
#                        the CURRENT shell, so `eval read -r VAR` binds VAR
#                        exactly as `command read -r VAR` does (executed under
#                        both shells). Only the BARE-WORD payload is reached this
#                        way: in `eval "printf -v VAR …"` the payload is ONE word
#                        whose literal text is not a verb, so the walk stops
#                        there and that `eval` stays residue -- the
#                        re-parsed-payload entry of the register above, which
#                        `trap` is on for the same reason. `trap` itself is NOT
#                        transparent: it takes a payload, never a command word.
TRANSPARENT_WORDS = frozenset(("!", "command", "builtin", "time", "eval"))

# Every one of those prefixes except `!` parses OPTIONS OF ITS OWN before the
# command word, and a walk that did not model them shut the command position ONE
# WORD BEFORE the verb -- so the option spelling of each was a way past this rule
# (rc 0 apiece, measured). The grammars below are taken from bash by EXECUTION,
# reading the bound variable back afterwards, not from a man page:
#   command -p read     BINDS   command -- read       BINDS
#   command -p -p read  BINDS   command -p -- read    BINDS
#   command -- -p read  no      command -v read       no (`-v` PRINTS it)
#   time -p read        BINDS   time -- read          BINDS
#   time -p -p read     no      time -p -- read       BINDS
#   builtin -- read     BINDS   builtin -p read       no (invalid option)
#   eval -- read        BINDS   eval -p read          no (invalid option)
#   ! -- read           no (`!` takes none, so `--` is the command word itself)
# Two rules fall out and both are PER PREFIX rather than one shared list: `--`
# ends the option list wherever it is taken, which is why every `no` above with a
# word after a `--` is a `command not found`; and `command` is the only prefix
# that may be given its `-p` more than once.
OPTION_END = "--"
PREFIX_OPTIONS = {
    "command": frozenset(("-p", OPTION_END)),
    "builtin": frozenset((OPTION_END,)),
    "time": frozenset(("-p", OPTION_END)),
    "eval": frozenset((OPTION_END,)),
}
PREFIX_REPEATS = frozenset(("command",))

# That repeat has a SECOND SPELLING, one character cheaper than the spaced one and
# for one round modelled by nothing: bash parses `command`'s options with getopts,
# so `-pp` is ONE WORD carrying two `-p` flags. Measured the same way, by
# execution:
#   command -pp read     BINDS   command -ppp read     BINDS
#   command -pp -p read  BINDS   command -pp -- read   BINDS
#   command -pv read     no (`-v` PRINTS it)   command -vp read   no
#   command -pV read     no                    command -pd read   no (invalid opt)
#   command - read       no (a lone `-` is a command word, not an option)
#   command -- -pp read  no (`--` ends the list, so `-pp` is the command word)
#   time -pp read        no (the keyword's `-p` does not cluster: `-pp: command
#                            not found`)
# So clustering is PER PREFIX as well, and it is a set of LETTERS rather than of
# words: a dash-word carrying two or more letters is an option of the open prefix
# iff EVERY letter after the `-` is in that prefix's set. That is what keeps
# `-pv`, `-vp`, `-pV` and `-pd` shutting the command position rather than being
# swallowed whole because they begin with a `p`.
#
# The ONE-letter spelling is deliberately not modelled here — it stays with
# `PREFIX_OPTIONS` above, so each spelling has exactly one home and dropping
# either is a distinct loss with a row of its own (E62 for the spaced repeat,
# E69 for the attached one) instead of one silently standing in for the other.
# `time`, `builtin` and `eval` cluster nothing and are therefore ABSENT rather
# than present with an empty set: an empty entry and no entry are the same fact,
# and a member no row could notice being deleted is the shape this file polices.
PREFIX_CLUSTERS = {"command": frozenset("p")}

# `NAME=value` inline environment assignments (`IFS= read …`) are transparent for
# the same reason: they bind nothing that outlives the command, so they are
# skipped rather than classified. Tested against the RAW word, which the word
# scanner has already taken whole, quotes included (`IFS=' '` is one word).
INLINE_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# A REDIRECTION may stand between the boundary and the verb as well:
# `>/dev/null read -r VAR` binds in the current shell for precisely the reason
# `command read -r VAR` does, so leaving it out would be a way past this rule.
# Optional leading digits are a file descriptor (`2>&1`); `<<<` and `<<` come
# first in the alternation so the longer operator wins over its own prefix.
REDIRECTION = re.compile(r"[0-9]*(?:<<<|<<-?|<[&>]?|>>|>&?)")

# Characters after which a `#` opens a word, and therefore a comment. `{` is
# deliberately absent: it would make `${#ARR[@]}` look like one.
COMMENT_LEAD = " \t;&|()"

# Word scanning stops at these; a redirection (`<<<"$V"`) ends the target list
# just as a terminator does. `{`/`}` are deliberately absent — they appear
# inside `${NAME}` and would split a word in half.
WORD_BREAK = " \t"
WORD_STOP = ";|&<>()"

# A heredoc redirection and its delimiter word: `<<WORD`, `<<-WORD`, `<<'WORD'`,
# `<<"WORD"`, `<<\WORD`, and any of those with blanks after the operator. `<<<`
# is a HERESTRING and is excluded by the caller before this is tried.
HEREDOC_START = re.compile(
    r"<<(?P<dash>-?)[ \t]*"
    r"(?:'(?P<sq>[A-Za-z_][A-Za-z0-9_]*)'"
    r"|\"(?P<dq>[A-Za-z_][A-Za-z0-9_]*)\""
    r"|\\?(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"
)

# `read`'s option grammar, modelled from bash's own: these letters take an
# argument, whether attached (`-n1`) or as the next word (`-n 1`).
READ_VALUE_OPTS = frozenset("dinNptu")
# `-a NAME` is the one option whose argument is itself a BOUND NAME.
READ_NAME_OPTS = frozenset("a")

# A bound name that is an edge-id variable. It is matched against the name the
# SHELL would bind — the word's literal text with quoting removed — never against
# the source spelling, so `\UBERDEV_ROOT_EDGE_ID` and `UBERDEV_ROOT_EDGE"_ID"`
# are the same target as a bare one. A name the text cannot decide is not a
# pattern but a POSITION: see `Word.expands`.
#
# The class is `[A-Za-z0-9_]`, DELIBERATELY one letter-range wider than the
# `[A-Z0-9_]` in `ASSIGNMENT` (named, not cited by line: the referent is in this
# same file, and a line number is the one thing here already known to rot). The
# two are not one house form spelled twice. `ASSIGNMENT` matches a whole SOURCE
# LINE, where an anchored uppercase class is most of what keeps it off ordinary
# prose; this one matches a name the walk has ALREADY proved to stand in binding
# position, where the only question left is whether that name is an edge id --
# and a shell name is case-sensitive, so a lowercase letter in one says nothing
# about what it holds. Measured, rather than argued: `read -r my_EDGE_ID` is
# rc 1 here while `my_EDGE_ID=x` is rc 0 there. The divergence therefore runs in
# the safe direction, and narrowing this class to match the other would open a
# hole rather than close a duplication.
#
# And the measurement is a ROW, not a sentence. For one round this paragraph was
# the only thing standing between the target class and an editor "aligning the
# two house forms": narrowed to `[A-Z0-9_]`, `read -r my_EDGE_ID` went rc 1 ->
# rc 0 and every row in tests/solve-run-tree.test.sh stayed green, which is the
# silent-miss direction on the one position this whole rule exists to recognise.
# That file now carries the lowercase target as a row of its own, so the
# narrowing reds there instead of being argued about here.
EDGE_TARGET = re.compile(r"^[A-Za-z0-9_]*EDGE_ID$")

PROG = "launcher-edge-ids"


class Fatal(Exception):
    """A precondition the checker cannot run without — exit 2, never a verdict."""


def read_source(label: str) -> str:
    """Read a path (or stdin for `-`) as bytes and decode it as UTF-8."""
    try:
        if label == "-":
            data = sys.stdin.buffer.read()
        else:
            with open(label, "rb") as handle:
                data = handle.read()
    except OSError as error:
        raise Fatal(f"cannot read {label}: {error}") from error
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Fatal(f"{label}: not valid UTF-8: {error}") from error


def load_tree(label: str) -> tuple[set[str], str]:
    """Return (edge ids, root edge id) from the run-tree manifest."""
    try:
        tree = json.loads(read_source(label))
    except ValueError as error:
        raise Fatal(f"{label}: invalid JSON: {error}") from error
    if not isinstance(tree, dict):
        raise Fatal(f"{label}: manifest must be a JSON object")
    edges = tree.get("edges")
    if not isinstance(edges, dict) or not edges:
        raise Fatal(f"{label}: 'edges' must be a non-empty object")
    root = tree.get("root_edge_id")
    if not isinstance(root, str) or not root:
        raise Fatal(f"{label}: 'root_edge_id' must be a non-empty string")
    # Deliberately NOT asserted: root in edges. See DECLARED LIMITS.
    return set(edges), root


def retired_prefix(token: str) -> str:
    """The declared-retired prefix `token` sits under, or `""` if it sits under none."""
    for prefix in RETIRED_PREFIXES:
        if token.startswith(prefix):
            return prefix
    return ""


def token_pattern(label: str, edge_ids: set[str], root: str) -> re.Pattern[str]:
    """Compile the guarded-token extractor: the tree's vocabulary plus the retired one."""
    derived = set()
    for edge in edge_ids:
        segments = edge.split(".")
        if len(segments) >= 3 and segments[0] == "solve":
            derived.add(f"{segments[0]}.{segments[1]}.")
    # The anti-vacuity floor reads the DERIVED half alone. RETIRED_PREFIXES is
    # never empty, so folding it in first would make this check unfailable and
    # a manifest that had lost every live `solve.<area>.<name>` edge would go on
    # reporting a clean run against a vocabulary of retired names only.
    if not derived:
        raise Fatal(
            f"{label}: no 'solve.<area>.<name>' edge in the manifest -- there is no "
            "vocabulary left to guard, so a green run would mean nothing"
        )
    # A prefix cannot be retired and live at once. Refusing here (exit 2) rather
    # than rendering a verdict is the E10 rule applied to the declaration: with
    # the two halves in contradiction, nothing this file could say about the
    # launcher would mean anything.
    collision = sorted(edge for edge in edge_ids if retired_prefix(edge))
    if collision:
        raise Fatal(
            f"{label}: {len(collision)} edge(s) sit under a prefix declared retired in "
            f"RETIRED_PREFIXES -- {', '.join(collision)}. A retired namespace resolves to "
            "nothing by construction, so either the edge is real (drop the prefix from "
            "RETIRED_PREFIXES) or it is not (drop the edge)"
        )
    prefixes = derived | set(RETIRED_PREFIXES)
    pattern = re.compile("(?:%s)%s" % ("|".join(re.escape(p) for p in sorted(prefixes)), TOKEN_TAIL))
    if not pattern.fullmatch(root):
        raise Fatal(
            f"{label}: root_edge_id '{root}' is not shaped like a guarded token "
            f"(prefixes: {', '.join(sorted(prefixes))}) -- the L3 floor could never be met"
        )
    return pattern


def word_end(text: str, start: int) -> int:
    """The index just past the word beginning at `start`, quotes consumed whole.

    A quoted run is part of the word it sits in rather than a word of its own —
    `rea"d"`, `read` and `"read"` are one word each — so the scan crosses a quote
    without stopping and resumes after its close. An unterminated quote runs to
    the end of the line, since the scan is line-oriented and the string really
    does continue onto the next one.
    """
    index, size = start, len(text)
    while index < size:
        char = text[index]
        if char in WORD_BREAK or char in WORD_STOP:
            break
        if char == "'":
            close = text.find("'", index + 1)
            index = size if close < 0 else close + 1
            continue
        if char == '"':
            close = index + 1
            while close < size and text[close] != '"':
                close += 2 if text[close] == "\\" else 1
            index = size if close >= size else close + 1
            continue
        index += 2 if char == "\\" else 1
    return index


class Word(NamedTuple):
    """One command word reduced to what the SHELL would make of it.

    `text` is the word with quoting removed the way the shell removes it, and
    `expands` holds the index — in `text` — of every `$` or backtick that still
    INTRODUCES AN EXPANSION, meaning one that stood unquoted or inside double
    quotes. Splitting the two apart is what lets one representation serve both
    halves of L2b: a VERB cares only about `text` (`rea"d"` is `read`), while a
    TARGET needs both, because `"$_name"` is a name the text cannot decide while
    `'$_name'` is the literal name `$_name` — which bash and zsh alike refuse as
    an identifier, so it binds nothing at all.

    For one round the target was matched against its SOURCE SPELLING instead, and
    the whole rule was one character from silent: `\\UBERDEV_ROOT_EDGE_ID`,
    `UBERDEV_ROOT_EDGE"_ID"` and `""UBERDEV_ROOT_EDGE_ID""` each bind the root
    edge id in both shells (executed) and each measured rc 0.
    """

    text: str
    expands: frozenset[int]

    def tail(self, start: int) -> "Word":
        """The word from character `start` on, expansion marks carried across.

        `printf -vNAME` writes its option and its target as ONE word, so the
        target is a SLICE of a literal rather than a word of its own — and a
        slice that dropped the marks would read `-v"$_name"` as decidable.
        """
        return Word(self.text[start:], frozenset(i - start for i in self.expands if i >= start))


def literal_word(word: str) -> Word:
    """Remove quoting from a word the way the shell removes it, marking expansions.

    Quoting a COMMAND WORD removes nothing but alias expansion: `"read"`,
    `'read'`, `rea"d"` and `\\read` are all the `read` builtin, and all four bind
    in the current shell. The same is true one word later, of the NAME the
    builtin binds. So both are read from this literal text rather than from the
    source spelling — and the removal is per character rather than a strip of a
    surrounding pair, because `rea"d"` is quoted in the middle and nowhere else.

    What the spelling does still decide is whether an expansion SURVIVES, and
    that is recorded rather than thrown away: inside single quotes a `$` is a
    literal character, everywhere else it introduces a value this checker cannot
    read. A backslash escape is literal in both, except that inside double quotes
    a backslash escapes only `$`, a backtick, `"` and itself — `"\\read"` is the
    five-character word `\\read` and not the `read` builtin. That exception is a
    row rather than a remark: `"\\$NAME"` is the literal name `$NAME`, which the
    shell refuses as an identifier, so it binds nothing and must stay rc 0 —
    delete the escape and the `$` keeps its expansion mark, the target turns
    undecidable, and a want-0 row in tests/solve-run-tree.test.sh goes red. The
    `\\U` in `"\\UBERDEV_ROOT_EDGE_ID"` cannot pin it, because `U` is not in the
    escape set and never reaches this branch.
    """
    out: list[str] = []  # ONE character per element, so `len(out)` is the index
    expands: set[int] = set()
    index, size = 0, len(word)
    while index < size:
        char = word[index]
        if char == "\\":
            if index + 1 < size:
                out.append(word[index + 1])
            index += 2
            continue
        if char == "'":
            close = word.find("'", index + 1)
            if close < 0:
                out.extend(word[index + 1:])
                break
            out.extend(word[index + 1:close])
            index = close + 1
            continue
        if char == '"':
            index += 1
            while index < size and word[index] != '"':
                if word[index] == "\\" and index + 1 < size and word[index + 1] in '$`"\\':
                    out.append(word[index + 1])
                    index += 2
                    continue
                if word[index] in "$`":
                    expands.add(len(out))
                out.append(word[index])
                index += 1
            index += 1
            continue
        if char in "$`":
            expands.add(len(out))
        out.append(char)
        index += 1
    return Word("".join(out), frozenset(expands))


def clustered_option(literal: str, prefix: str) -> bool:
    """Is `literal` one dash-word carrying only option letters `prefix` clusters?

    The ATTACHED spelling of a transparent prefix's option, which is a separate
    grammar from the spaced one and not a convenience: `command -pp read -r VAR`
    binds under bash (executed, read back) while `command -pv read -r VAR` does
    not, so a rule that accepted any dash-word behind a prefix would read a
    `command -v` probe's argument as a command.

    TWO OR MORE LETTERS, and the bound is a DISJOINTNESS boundary rather than a
    behaviour — it is stated that way because measuring it says so. Admitting
    `-p` here as well changes no verdict while `PREFIX_OPTIONS` still carries it
    (measured: the whole of tests/solve-run-tree.test.sh stays rc 0), so no row
    can see the bound on its own. What it buys is that each spelling has exactly
    one home: relax it AND drop `-p` from `command`'s option words — the very
    mutation E62's comment claims takes E62 from rc 1 to rc 0 — and E62 goes
    GREEN with a model member gone (measured). The bound is what keeps that
    claim, and E62's independence from E69, true.

    Clustering and repeating are the same fact for the grammar bash actually has:
    `-pp` IS `-p -p` written in one word, so the only prefix with a cluster set is
    also the only one in `PREFIX_REPEATS`, and the option-consumption in
    `binding_sites` never has to take a letter out of a word.
    """
    letters = PREFIX_CLUSTERS.get(prefix, frozenset())
    if not letters or len(literal) < 3 or not literal.startswith("-"):
        return False
    return all(char in letters for char in literal[1:])


def binding_sites(line: str) -> list[tuple[str, int]]:
    """Every `printf`/`read` the line RUNS, as (verb, index just past the verb).

    L2b finds a command by looking for a verb, and that only means anything WHERE
    THE SHELL WOULD ALSO LOOK. So the line is walked the way the shell reads it,
    carrying one bit of state — may a command word stand here — instead of being
    pattern-matched as text. That bit is what separates the two halves of
    the rule, and each half was a measured defect before it was written down:

      * TEXT THAT RUNS NOTHING must not yield a verb. A COMMENT does not:
        `# Inconclusive (read blip or comment not yet indexed)` — a real line of
        the launcher — would otherwise parse as a `read` whose targets are the
        following six English words, and one `$VAR` anywhere in such a sentence
        would turn an unrelated comment edit into a red on this guard. Neither
        does an ARGUMENT: in `echo "if read fails we fall back to $DEFAULT"` the
        quoted run is one argument to `echo`, and no `;` or verb inside it is
        syntax at all. Both fall out of the walk rather than being special-cased,
        because after `echo` no command word may stand until a boundary.
      * A COMMAND THAT RUNS must yield one however it is SPELLED. Quoting a
        command word removes only alias expansion, and a redirection may precede
        it, so `"read" -r VAR`, `\\read -r VAR` and `>/dev/null read -r VAR` all
        bind exactly as a bare `read` does — the same argument that puts `!`,
        `command`, `builtin`, `time` and inline `NAME=` in the transparent set.
        It reaches one word further than the prefix itself, too: four of those
        five parse OPTIONS before their command word, so `command -p read -r VAR`,
        `command -pp read -r VAR` and `builtin -- read -r VAR` bind exactly as the
        bare prefix does and the walk must step over the option rather than stop
        on it — see `PREFIX_OPTIONS` for the option WORDS and `PREFIX_CLUSTERS`
        for the attached spelling of the same option, both measured per prefix
        because the option that keeps the command running (`-p`) and the one that
        suppresses it (`-v`) differ by a letter.

    The returned index is where the ARGUMENT LIST begins in the ORIGINAL line, so
    a quoted argument reaches the tokeniser intact: `read -p "Enter a name: " X`
    must keep its prompt whole. That is `word_end`'s double-quote branch, and it
    needs a prompt with a SPACE in it to be exercised at all — which is why the
    row that pins `read`'s value-taking options carries a realistic prompt rather
    than the `-p "$P"` it started with.
    """
    sites: list[tuple[str, int]] = []
    index, size = 0, len(line)
    at_command = True
    # The option words still available to the transparent prefix just accepted,
    # and which prefix that was. Empty means no prefix is open, so a dash-word
    # standing here is a command of its own and shuts the position.
    pending: frozenset[str] = frozenset()
    prefix = ""
    while index < size:
        char = line[index]
        if char in WORD_BREAK:
            index += 1
            continue
        # A `#` that STARTS a word opens a comment, and the rest of the line runs
        # nothing. `${#A[@]}` keeps its `#` because `{` is not a COMMENT_LEAD.
        if char == "#" and (index == 0 or line[index - 1] in COMMENT_LEAD):
            break
        if char in BOUNDARY_CHARS:
            at_command = True
            pending, prefix = frozenset(), ""
            index += 1
            continue
        redirect = REDIRECTION.match(line, index)
        if redirect is not None:
            # The operator and its target word, consumed together. `at_command`
            # is deliberately untouched: a redirection neither opens a command
            # nor ends one.
            index = redirect.end()
            while index < size and line[index] in WORD_BREAK:
                index += 1
            index = word_end(line, index)
            continue
        end = word_end(line, index)
        if end == index:
            # Unreachable today: `word_end` stops only on WORD_STOP, and every
            # one of those characters is consumed by a branch above. It is a
            # PROGRESS guard, not a case — without it, widening WORD_STOP without
            # widening the branches would hang CI instead of failing it.
            index += 1
            continue
        word = line[index:end]
        index = end
        if not at_command:
            continue
        literal = literal_word(word).text
        if literal in ("printf", "read"):
            sites.append((literal, index))
            at_command = False
            pending, prefix = frozenset(), ""
            continue
        if literal in COMMAND_KEYWORDS or literal in TRANSPARENT_WORDS or INLINE_ASSIGN.match(word):
            pending = PREFIX_OPTIONS.get(literal, frozenset())
            prefix = literal if pending else ""
            continue  # a command word may still stand after this one
        if literal in pending or clustered_option(literal, prefix):
            # An option word of the prefix just accepted — `time -p read -r VAR`,
            # `command -p read -r VAR`, `builtin -- read -r VAR`, and the
            # ATTACHED spelling of the same option, `command -pp read -r VAR`.
            # The option belongs to the PREFIX, not to a command of its own, so
            # the command word is still behind it and it binds exactly as the
            # bare prefix does. Accepted only where that prefix actually put it,
            # which is what stops a bare `-p` or `--` from opening a command
            # position anywhere: `command -- -p read` runs `-p` and binds
            # nothing, as does `! -- read`, whose `!` has no options at all.
            if literal == OPTION_END:
                pending, prefix = frozenset(), ""  # options end; the verb is next
            elif prefix not in PREFIX_REPEATS:
                pending = pending - {literal}  # `time -p -p read` binds nothing
            continue
        at_command = False
        pending, prefix = frozenset(), ""
    return sites


def heredoc_delimiters(line: str) -> list[tuple[str, bool]]:
    """Every heredoc this line OPENS, as (delimiter, strip-leading-tabs), in order.

    A line may open more than one (`cat <<A <<B`), and the bodies then arrive in
    that same order, which is why this returns a list rather than a flag.

    The scan skips a comment and a single-quoted string, but deliberately looks
    INSIDE a double-quoted one: the launcher's own `CLAIM_BODY="$(cat <<EOF` opens
    a real heredoc from a position a line-oriented quote tracker reads as quoted,
    because the `"` closes three lines later. The cost of that choice is a literal
    `<<WORD` inside a double-quoted string being read as an opener, and it is paid
    for by `heredoc_body_lines` requiring the delimiter to actually arrive.
    """
    found: list[tuple[str, bool]] = []
    index, size = 0, len(line)
    while index < size:
        char = line[index]
        if char == "\\":
            index += 2
            continue
        if char == "'":
            close = line.find("'", index + 1)
            index = size if close < 0 else close + 1
            continue
        if char == "#" and (index == 0 or line[index - 1] in COMMENT_LEAD):
            break
        if char == "<" and line.startswith("<<", index):
            if line.startswith("<<<", index):
                index += 3  # a herestring: its operand is a word, not a body
                continue
            match = HEREDOC_START.match(line, index)
            if match is None:
                index += 2
                continue
            word = match.group("sq") or match.group("dq") or match.group("bare")
            found.append((word, match.group("dash") == "-"))
            index = match.end()
            continue
        index += 1
    return found


def heredoc_body_lines(lines: list[str]) -> set[int]:
    """The 1-based line numbers that are heredoc BODY (or delimiter) lines.

    L2b looks for a verb only where the shell would look for one, and a heredoc
    body is not such a place: nothing it contains can bind a variable in the
    CURRENT shell. An unquoted body is expanded, but every expansion that could
    run a command (`$( … )`, a backtick) runs it in a SUBSHELL, so a `printf -v`
    reached that way binds nothing that outlives it. What the body does contain is
    prose -- the launcher's bodies are user-facing English with `$VAR` throughout
    -- and parsing prose as a command is what turns a wording edit into a red on
    this guard. HOW MANY of them there are is deliberately not restated here: it
    is measured and cited once, in the scoping bullet of this module's docstring.
    This docstring carried its own copy for one round and the copy was wrong
    (`three`, left over from before the four agent prompts and the claim JSON were
    counted), and no reader of either number was in a position to notice, because
    a count restated in a second place is a count with nothing to compare it to.

    An opener whose delimiter never arrives is treated as NOT an opener. A real
    heredoc that is never closed is a shell syntax error, so the far likelier
    reading is that the `<<WORD` was literal text; failing that way keeps a
    mis-read from silently blanking the rest of the file, which would turn L2b off
    while every row still passed.
    """
    body: set[int] = set()
    index, total = 0, len(lines)
    while index < total:
        pending = heredoc_delimiters(lines[index])
        if not pending:
            index += 1
            continue
        cursor = index + 1
        span: list[int] = []
        while pending and cursor < total:
            span.append(cursor + 1)
            text = lines[cursor]
            cursor += 1
            if (text.lstrip("\t") if pending[0][1] else text) == pending[0][0]:
                pending.pop(0)
        if pending:  # unterminated: not a heredoc after all, so nothing is body
            index += 1
            continue
        body.update(span)
        index = cursor
    return body


def command_words(text: str) -> list[Word]:
    """Split a command's argument list into words, the way the shell would.

    Stops at the first unquoted terminator or COMMENT, so `read -r X; echo` yields
    the target list `["-r", "X"]` and `read -r X  # holds $y` yields the same
    rather than six more words of English of which one contains a `$`. Quotes are
    consumed whole, which is what keeps `read -p "Enter a name: " X` from
    splitting the prompt into three words and reporting `name:` as a bound
    variable.

    A REDIRECTION does NOT stop the list — it is consumed, operator and target
    word together, and the scan carries on. A redirection may stand anywhere in a
    simple command, so the words BEHIND one are still targets:
    `read -r <<<"$V" UBERDEV_ROOT_EDGE_ID` binds the root edge id (executed), and
    a scan that merely stopped at the first `<` lost it. The consumption is what
    keeps the herestring's own operand out of the list in the ordinary spelling
    `read -r X <<<"$V"`, and it is the same treatment `binding_sites` gives a
    redirection in front of the verb (E39).

    Each word is returned as its SHELL literal plus the positions where an
    expansion survives; the raw spelling is not needed downstream and keeping it
    was how a target came to be classified by how it was written.
    """
    words: list[Word] = []
    index, size = 0, len(text)
    while index < size:
        if text[index] in WORD_BREAK:
            index += 1
            continue
        redirect = REDIRECTION.match(text, index)
        if redirect is not None:
            index = redirect.end()
            while index < size and text[index] in WORD_BREAK:
                index += 1
            index = word_end(text, index)
            continue
        if text[index] in WORD_STOP:
            break
        # A `#` that STARTS a word opens a comment, and a comment is not an
        # argument. Reaching this test means the character begins a word, which
        # is the shell's own rule -- and the reason `#` is not in WORD_STOP,
        # where it would also break mid-word and split `${#ARR[@]}` in half.
        if text[index] == "#":
            break
        start = index
        index = word_end(text, index)
        words.append(literal_word(text[start:index]))
    return words


def printf_bound_names(words: list[Word]) -> list[Word]:
    """The single name `printf -v NAME` binds, or nothing when there is no -v.

    The option is recognised by its LITERAL text, so `printf "-v" NAME` is the
    same command as `printf -v NAME` (executed: it binds) rather than a `printf`
    whose first word happens not to look like an option.
    """
    for position, word in enumerate(words):
        if word.text == "--":
            return []
        if word.text == "-v":
            return words[position + 1:position + 2]
        if word.text.startswith("-v") and len(word.text) > 2:
            return [word.tail(2)]
        if not word.text.startswith("-"):
            return []  # the format string: this `printf` binds nothing
    return []


def read_bound_names(words: list[Word]) -> list[Word]:
    """Every name a `read` binds, options resolved against bash's own grammar.

    An option letter that takes a VALUE consumes its argument so the argument is
    not mistaken for a target; an option letter that takes a NAME (`-a`) yields
    one. Everything from the first non-option word onwards is a target — `read`
    binds all of them, not just the first. Options are read from each word's
    LITERAL text for the reason `printf_bound_names` reads its `-v` there.
    """
    names: list[Word] = []
    index, size = 0, len(words)
    while index < size:
        word = words[index]
        if word.text == "--":
            index += 1
            break
        if len(word.text) > 1 and word.text.startswith("-"):
            cursor = 1
            while cursor < len(word.text):
                letter = word.text[cursor]
                if letter in READ_VALUE_OPTS or letter in READ_NAME_OPTS:
                    attached = word.text[cursor + 1:]
                    if attached:
                        if letter in READ_NAME_OPTS:
                            names.append(word.tail(cursor + 1))
                    else:
                        index += 1
                        if letter in READ_NAME_OPTS and index < size:
                            names.append(words[index])
                    break
                cursor += 1
            index += 1
            continue
        break
    names.extend(words[index:])
    return names


def classify_binding(word: Word) -> str | None:
    """'edge', 'indeterminate', or None when the bound name is nobody's concern.

    The verdict is taken from the name the SHELL would bind, never from how that
    name was written: quoting is already gone by the time a `Word` gets here, so
    `printf -v "UBERDEV_ROOT_EDGE_ID"`, `printf -v \\UBERDEV_ROOT_EDGE_ID` and
    `read -r UBERDEV_ROOT_EDGE"_ID"` are one target with three spellings.

    A trailing SUBSCRIPT names an element of an array, and the array is the
    variable: `read -r NAME[0]` leaves `$NAME` holding what was read (executed
    under bash), so the name that decides is the BASE and `[…]` may not be a way
    past the rule. An expansion INSIDE the subscript is therefore not what makes
    the target undecidable — only one in the base is.
    """
    subscript = word.text.find("[")
    base = word.text if subscript < 0 else word.text[:subscript]
    if any(position < len(base) for position in word.expands):
        return "indeterminate"
    if EDGE_TARGET.match(base):
        return "edge"
    return None


def binding_findings(line: str) -> list[str]:
    """L2b's verdicts for one line, in the order the bindings appear."""
    reasons: list[str] = []
    # Sites are LOCATED by walking the line as the shell reads it, and their
    # arguments TOKENISED from the same line at the offset the walk stopped at,
    # so a quoted argument survives intact.
    for verb, start in binding_sites(line):
        words = command_words(line[start:])
        if verb == "printf":
            label, names = "printf -v", printf_bound_names(words)
        else:
            label, names = "read", read_bound_names(words)
        for name in names:
            verdict = classify_binding(name)  # the SHELL's name, not its spelling
            if verdict == "edge":
                reasons.append(
                    f"edge id bound by {label} -- edge ids are a closed literal "
                    "vocabulary and may not be composed at runtime"
                )
            elif verdict == "indeterminate":
                reasons.append(
                    f"{label} binds an indeterminate target -- the target must be a "
                    "literal name (or the helper belongs in lib/, outside this corpus)"
                )
    return reasons


def scan(text: str, edge_ids: set[str], root: str, pattern: re.Pattern[str]) -> tuple[list[tuple[int | None, str]], list[str]]:
    """Apply L1, L2, L2b and L3 to the launcher text. Returns (findings, matched tokens)."""
    findings: list[tuple[int | None, str]] = []
    matched: list[str] = []

    lines = text.splitlines()
    # L2b only. L1 and L2 stay text-oriented on purpose (DECLARED LIMITS): a
    # `solve.lead.*` token is a finding wherever it is written, heredoc included.
    heredoc = heredoc_body_lines(lines)

    for number, line in enumerate(lines, 1):
        for match in pattern.finditer(line):
            token = match.group(0)
            matched.append(token)
            if token not in edge_ids:
                # A retired namespace is reported as such, never as a typo: the
                # cause is different, the fix is different, and E4/E5 pin the
                # attribution so the two paths cannot silently merge.
                retired = retired_prefix(token)
                if retired:
                    findings.append((number, (
                        f"retired edge id '{token}' -- the '{retired}' namespace is "
                        "declared retired in RETIRED_PREFIXES and resolves to nothing"
                    )))
                else:
                    findings.append((number, f"unresolvable edge id '{token}' (not a key of edges)"))
        if number not in heredoc:
            for reason in binding_findings(line):
                findings.append((number, reason))
        assignment = ASSIGNMENT.match(line)
        if assignment is None:
            continue
        rhs = assignment.group(1).strip()
        literal = BARE_LITERAL.match(rhs)
        if literal is None:
            findings.append((number, f"EDGE_ID assignment RHS is not a bare double-quoted literal: {rhs}"))
        elif literal.group(1) not in edge_ids:
            findings.append((number, f"EDGE_ID assignment names an unresolvable edge id: '{literal.group(1)}'"))

    # L3 — both conditions reported, never short-circuited: losing every token
    # and losing the root edge are different regressions with the same symptom.
    if not matched:
        findings.append((None, "launcher names no tree edge at all -- the extractor matched nothing"))
    if root not in matched:
        findings.append((None, f"launcher never names the tree root edge id '{root}'"))
    return findings, matched


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Check that every run-tree edge id named by the solve launcher resolves to a real edge.",
    )
    parser.add_argument("--tree", required=True, metavar="PATH", help="run-tree manifest JSON ('-' reads stdin)")
    parser.add_argument("--launcher", required=True, metavar="PATH", help="launcher shell source ('-' reads stdin)")
    args = parser.parse_args(argv)
    if args.tree == "-" and args.launcher == "-":
        # argparse's own error path exits 2 — the same code every other
        # precondition failure uses.
        parser.error("only one of --tree/--launcher may be '-': stdin has a single reader")

    try:
        edge_ids, root = load_tree(args.tree)
        pattern = token_pattern(args.tree, edge_ids, root)
        text = read_source(args.launcher)
    except Fatal as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return 2

    findings, matched = scan(text, edge_ids, root, pattern)
    for line, reason in findings:
        anchor = args.launcher if line is None else f"{args.launcher}:{line}"
        print(f"{anchor}: {reason}", file=sys.stderr)
    if findings:
        print(f"{PROG}: {len(findings)} violation(s) in {args.launcher}", file=sys.stderr)
        return 1
    print(f"{PROG}: {len(matched)} edge id token(s) in {args.launcher} resolved against {len(edge_ids)} manifest edges")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
# tests/leaf-worker-contract.test.sh — issue #530, Item A.
#
# THE CLASS. UberDev already states the leaf-worker rule on the surfaces that
# DISPATCH a worker (plugins/uberdev/agents/implementation-worker.md, and the
# wire clause plugins/uberdev/lib/child-dispatch.sh emits). It did not state it
# in the prompt TEMPLATES that are pasted into those dispatches, and nothing
# compared the two — "one contract, N uncompared copies" (#370). A worker that
# reads only its rendered prompt therefore never saw the rule, and every
# reviewer such a worker spawned duplicated the review the controller dispatches
# anyway: a full extra review seat per task.
#
# WHAT THIS GUARD ASSERTS.
#
#   L0  the worker-facing REGION of each template resolves, and a reshaped
#       template REDS rather than silently falling back to whole-file.
#   L1  the enumeration is taken from DISK, not from a hand-written list, so a
#       fifth template added to either component directory is covered the day
#       it lands. Anti-vacuity floor: non-empty, >= 4 entries, both directories
#       contribute, and the four known templates are all in it.
#   L2  each enumerated template carries a `## You Do Not Dispatch Subagents`
#       section INSIDE its worker-facing region, with a body that says
#       something (>= 3 non-blank lines).
#   L3  the section states BOTH halves — the prohibition and the redirect — as
#       two independent assertions, so one sentence cannot satisfy both by
#       accident.
#   L4  no worker-facing region tells a worker to spawn or dispatch a reviewer,
#       an agent or an implementer of its own. Scoped as the UNION of the two
#       exemptions, because each one alone leaks (see the NEGATOR_RE comment):
#       every byte OUTSIDE the section body is scanned RAW, with no exemption at
#       all, and only the section body — which has to quote the forbidden
#       phrasing in order to forbid it — keeps an exemption, and only for a
#       negator that GOVERNS the verb rather than one that merely shares the
#       sentence with it. Scope and predicate are both load-bearing: an
#       instruction appended to the end of the body sits inside the exemption's
#       scope, and only the predicate catches it. L4.C and L4.N are the
#       anti-vacuity controls, one per scan: on every run each classifier is
#       shown to separate violations — hard-wrapped ones, and ones carrying an
#       incidental negator, included — from the phrasings that scan must
#       tolerate.
#   L5  the controller's own scoping survives: SKILL.md still names
#       `sdd_launch_prepared_batch` and still carries the dispatch-before-wait
#       sentence, and no worker-facing section body countermands the wave
#       contract with `in parallel`.
#
# WHY THE REGION RULE. Every one of these templates carries CONTROLLER-facing
# prose outside the prompt it renders ("Use this template when dispatching a
# … subagent"). A section added to that prose is bytes the worker never reads,
# so "the file contains the section" is the wrong predicate. The region is the
# body of the first BARE fence (``` with no info string) after the LAST
# `uberdev_create_child_handoff` mention; a file with no such preamble is
# worker-facing in whole. That same asymmetry is why L4 is region-scoped: the
# controller-facing prose legitimately says "dispatching a … reviewer subagent".
#
# Repo convention: `set -u` + `set -o pipefail` + manual PASS/FAIL counters
# (NOT `set -e`; see tests/install.test.sh header for the rationale).
# Portable: bash + a Python 3 interpreter, and ALL parsing happens in python
# reading utf-8 and stripping CR — grep under Git Bash cannot see a CR at all,
# and .gitattributes is scoped to hooks/** only, so these files are not
# LF-pinned on a Windows checkout. Wired into BOTH shape-check jobs.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Windows Git Bash ships `python`, not `python3`; ubuntu-latest ships both.
# Mirrors the portable interpreter resolver used across the suite.
if PY="$(command -v python3 2>/dev/null)" && [ -n "$PY" ]; then
  :
elif PY="$(command -v python 2>/dev/null)" && [ -n "$PY" ]; then
  :
else
  echo "FATAL: no python3/python interpreter on PATH" >&2
  exit 2
fi

for required in \
  "$REPO_ROOT/plugins/uberdev/skills/subagent-driven-dev" \
  "$REPO_ROOT/plugins/uberdev/skills/requesting-code-review"
do
  if [ ! -d "$required" ]; then
    echo "FATAL: component directory missing: $required" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
note_fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "## leaf-worker-contract — the no-subagents rule on every worker-facing prompt (#530 Item A)"

# The python guard prints one row per assertion as `<PASS|FAIL><TAB><id> <text>`
# and exits non-zero only on an INTERNAL error, which is a FATAL here: a guard
# that produced no rows must never be mistaken for a clean run.
ROWS="$TMP/rows.tsv"
"$PY" -I -B - "$REPO_ROOT" > "$ROWS" 2> "$TMP/err.txt" <<'PY'
import os
import re
import sys

REPO = sys.argv[1]

# The two vendored components whose *.md files are pasted into dispatches.
# Repo-relative, forward-slash: these strings are what the rows print, and a
# failure must read the same on the ubuntu job and the windows one.
COMPONENT_DIRS = (
    "plugins/uberdev/skills/subagent-driven-dev",
    "plugins/uberdev/skills/requesting-code-review",
)


def absolute(relative):
    return os.path.join(REPO, *relative.split("/"))

# SKILL.md is the CONTROLLER surface of each component: it is what dispatches
# workers, so telling it "you do not dispatch subagents" would be false. It is
# excluded BY NAME rather than by listing the templates positively, so a fifth
# template added to either directory is enumerated the day it lands (that
# fifth-file case is exactly what a hand-written allowlist misses).
CONTROLLER_FILES = {"SKILL.md"}

# Not the enumeration — the anti-vacuity floor under it. If discovery silently
# returned a shorter list, every per-file row below would vacuously pass.
KNOWN_TEMPLATES = {
    "implementer-prompt.md",
    "spec-reviewer-prompt.md",
    "code-quality-reviewer-prompt.md",
    "code-reviewer.md",
}

HANDOFF = "uberdev_create_child_handoff"
SECTION_RE = re.compile(r"^\s*##\s+You Do Not Dispatch Subagents\s*$")
ANY_HEADING_RE = re.compile(r"^\s*##\s")
# A worker being told to create a review/implementation seat of its own. The
# controller-facing framing ("dispatching a spec compliance reviewer subagent",
# "dispatch the task review") does not match: it has no first-person article
# from this set, which is why the article group is closed.
DELEGATION_RE = re.compile(
    r"\b(spawn|dispatch|launch)\s+"
    r"(a|an|another|your own|a second|a fresh)\s+"
    r"(\w+\s+){0,2}"
    r"(reviewer|subagent|agent|implementer)\b",
    re.IGNORECASE,
)
# The section under test necessarily QUOTES the forbidden phrasing in order to
# forbid it ("never spawn a reviewer to check your work"), so L4 has to exempt
# something. Each exemption ALONE leaks, in opposite directions:
#
#   BY POSITION (region minus the section body) measured vacuous — in
#   code-quality-reviewer-prompt.md the section body runs to the end of the
#   region (nothing follows it to close the body), so the whole tail became
#   unscannable, and in code-reviewer.md a violation appended right after the
#   section sailed through.
#
#   BY NEGATION applied to a whole SENTENCE is clause-blind: asking only whether
#   a negator appears earlier in the sentence never asks whether it GOVERNS the
#   delegation verb, so a plain instruction that merely contains one ("If you
#   are not sure, spawn a second reviewer") disarms the row for the rest of the
#   sentence.
#
# L4 closes both, because each hole survives the other's fix. It takes the UNION
# of the two scopes — outside the section body DELEGATION_RE runs RAW, since
# nothing out there has any reason to quote the forbidden phrasing — AND it
# tightens the exemption's predicate to GOVERNMENT, so that the one scope which
# does keep an exemption is not disarmed by an incidental negator. Scope alone
# is not enough: the same clause-blind sentence would still sail through if it
# were appended to the end of the section body, which is exactly where a drifting
# edit lands it.
NEGATOR_RE = re.compile(r"\b(never|not|no|nor|cannot|don't|without)\b", re.IGNORECASE)
# A negator governs the verb only when nothing separates them but a word or two.
# Anything from this set opens a NEW clause, so a negator on its far side governs
# something else: "If you are not sure, spawn …" negates `sure`, not `spawn`.
# A single newline is not a break (this prose is hard-wrapped, so "never\n
# spawn" is one clause); a blank line is. Deliberately tight — to state the
# prohibition, put the negator next to the verb ("never spawn a reviewer"), not
# behind an intensifier clause ("never, under any circumstances, spawn one").
CLAUSE_BREAK_RE = re.compile(r"[,;:.!?()\[\]—–]|\n[ \t]*\n")
GOVERNING_GAP_WORDS = 3

rows = []


def row(ok, ident, text):
    rows.append("%s\t%s %s" % ("PASS" if ok else "FAIL", ident, text))


def read_lines(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    # rstrip("\r") per line, not a global replace: a CRLF checkout must parse
    # identically to an LF one, and grep cannot do this at all under Git Bash.
    return [line.rstrip("\r") for line in text.split("\n")]


def resolve_region(lines):
    """(start, end, err) — inclusive 0-based bounds of the worker-facing region.

    The region is the body of the first BARE fence after the LAST mention of
    the handoff helper. Info-string fences (```yaml) are skipped whole, so a
    yaml block's own closing ``` can never be mistaken for the opening bare
    fence. A file with no handoff preamble is worker-facing in whole.
    """
    last = -1
    for index, line in enumerate(lines):
        if HANDOFF in line:
            last = index
    if last < 0:
        return 0, len(lines) - 1, None

    index = last + 1
    open_at = -1
    while index < len(lines):
        stripped = lines[index].strip()
        if stripped.startswith("```"):
            if stripped[3:].strip() == "":
                open_at = index
                break
            close = index + 1
            while close < len(lines) and not lines[close].strip().startswith("```"):
                close += 1
            if close >= len(lines):
                return None, None, "an info-string fence after %s never closes" % HANDOFF
            index = close + 1
            continue
        index += 1
    if open_at < 0:
        return None, None, (
            "carries a %s preamble but no following bare fence — the worker-facing "
            "region cannot be resolved" % HANDOFF
        )

    close_at = -1
    for index in range(open_at + 1, len(lines)):
        if lines[index].strip().startswith("```"):
            close_at = index
            break
    if close_at < 0:
        return None, None, "the worker prompt fence after %s never closes" % HANDOFF
    return open_at + 1, close_at - 1, None


def negator_governs(text, verb_start):
    """True when a negator actually negates the delegation verb at verb_start.

    Government, not co-occurrence: the negator must reach the verb without
    crossing a clause break and with at most GOVERNING_GAP_WORDS words in
    between. "never spawn a reviewer" is a prohibition; "If you are not sure,
    spawn a second reviewer" is an instruction that happens to contain `not`,
    and only this predicate tells them apart.
    """
    head = text[:verb_start]
    for negator in NEGATOR_RE.finditer(head):
        gap = head[negator.end():]
        if CLAUSE_BREAK_RE.search(gap):
            continue
        if len(gap.split()) <= GOVERNING_GAP_WORDS:
            return True
    return False


def delegation_offenders(text, negation_exempt):
    """[(char_offset, phrase)] — every instruction to create a seat.

    Run over the text FLATTENED to one string, never line by line: this prose
    is hard-wrapped, so "never spawn a\\n    reviewer" is invisible to any
    per-line regex — the first half has no object and the second half has no
    verb.

    `negation_exempt` selects the scan. False is the RAW scan used outside the
    section body: every match is an offender. True is the in-section scan, where
    a match is exempt only when a negator GOVERNS it — see negator_governs.
    """
    offenders = []
    for match in DELEGATION_RE.finditer(text):
        if negation_exempt and negator_governs(text, match.start()):
            continue
        offenders.append((match.start(), " ".join(match.group(0).split())))
    return offenders


def find_section_span(lines, start, end):
    """(body_start, body_end) inclusive, or None when the region has no section.

    The SPAN, not just the lines: L4 needs the bounds in order to scan the rest
    of the region under the other exemption. The body runs to the next `##`
    heading, or to the end of the region when the section is the last thing in
    it (code-quality-reviewer-prompt.md's prompt body carries no other heading
    at all). A heading with nothing under it yields an empty span
    (body_start > body_end), which L2 reds on.
    """
    for index in range(start, end + 1):
        if SECTION_RE.match(lines[index]):
            body_end = end
            for scan in range(index + 1, end + 1):
                if ANY_HEADING_RE.match(lines[scan]):
                    body_end = scan - 1
                    break
            return index + 1, body_end
    return None


# --- L1: the enumeration is real ------------------------------------------
enumerated = []
per_dir = {}
for component in COMPONENT_DIRS:
    directory = absolute(component)
    names = sorted(
        name
        for name in os.listdir(directory)
        if name.endswith(".md")
        and name not in CONTROLLER_FILES
        and os.path.isfile(os.path.join(directory, name))
    )
    per_dir[component] = names
    enumerated.extend("%s/%s" % (component, name) for name in names)

basenames = set(path.rsplit("/", 1)[-1] for path in enumerated)
empty_dirs = [component for component, names in per_dir.items() if not names]
missing_known = sorted(KNOWN_TEMPLATES - basenames)
if not enumerated:
    row(False, "L1", "disk enumeration produced no prompt templates at all")
elif len(enumerated) < len(KNOWN_TEMPLATES):
    row(False, "L1", "disk enumeration found %d template(s), fewer than the %d known"
        % (len(enumerated), len(KNOWN_TEMPLATES)))
elif empty_dirs:
    row(False, "L1", "these component directories contributed no template: %s"
        % ", ".join(sorted(empty_dirs)))
elif missing_known:
    row(False, "L1", "disk enumeration is missing known template(s): %s"
        % ", ".join(missing_known))
else:
    row(True, "L1", "disk enumeration covers %d template(s) across both components"
        % len(enumerated))

# --- L0/L2/L3/L4: one row per enumerated template --------------------------
section_bodies = {}
for relative in enumerated:
    lines = read_lines(absolute(relative))
    start, end, err = resolve_region(lines)

    # L0 is the only row that can abort a file: without a region there is
    # nothing for L2/L3/L4 to be scoped to. Every later row still reports on
    # its own file, so a missing section reds L2/L3 rather than silencing them.
    if err is not None:
        row(False, "L0", "%s %s" % (relative, err))
        continue
    if start > end or not any(line.strip() for line in lines[start:end + 1]):
        row(False, "L0", "%s resolves an EMPTY worker-facing region" % relative)
        continue
    row(True, "L0", "%s worker-facing region resolves (lines %d-%d)"
        % (relative, start + 1, end + 1))

    span = find_section_span(lines, start, end)
    if span is None:
        body = []
        # No section to exempt: the ENTIRE region is scanned raw.
        segments = [(start, end, False)]
        row(False, "L2", "%s has no `## You Do Not Dispatch Subagents` section inside "
                         "its worker-facing region (lines %d-%d)" % (relative, start + 1, end + 1))
    else:
        body_start, body_end = span
        body = lines[body_start:body_end + 1]
        # The union scoping. Each segment is flattened and scanned on its own —
        # never concatenated — so excising the body cannot splice two distant
        # lines into a phrase neither of them contains. The heading line itself
        # (body_start - 1) stays in the raw segment.
        segments = []
        if body_start > start:
            segments.append((start, body_start - 1, False))
        if body_start <= body_end:
            segments.append((body_start, body_end, True))
        if body_end < end:
            segments.append((body_end + 1, end, False))

        non_blank = [line for line in body if line.strip()]
        if len(non_blank) < 3:
            row(False, "L2", "%s section body has %d non-blank line(s), fewer than 3"
                % (relative, len(non_blank)))
        else:
            row(True, "L2", "%s states the section inside its worker-facing region" % relative)

    body_text = "\n".join(body)
    if body_text.strip():
        section_bodies[relative] = body_text

    if re.search(r"never\s+spawn", body_text, re.IGNORECASE) and re.search(
        r"reviewer", body_text, re.IGNORECASE
    ):
        row(True, "L3a", "%s states the prohibition (never spawn … reviewer)" % relative)
    else:
        row(False, "L3a", "%s section states no prohibition naming a reviewer" % relative)

    redirects = [
        needle
        for needle in ("report", "passes yourself", "controller")
        if re.search(re.escape(needle), body_text, re.IGNORECASE)
    ]
    if redirects:
        row(True, "L3b", "%s states the redirect (%s)" % (relative, ", ".join(redirects)))
    else:
        row(False, "L3b", "%s section prohibits without saying what to do instead" % relative)

    # L4 — the union scan: every segment of the region, each flattened, raw
    # outside the section body and negation-exempt inside it.
    found = []
    for seg_start, seg_end, negation_exempt in segments:
        seg_text = "\n".join(lines[seg_start:seg_end + 1])
        for offset, phrase in delegation_offenders(seg_text, negation_exempt):
            found.append((seg_start + 1 + seg_text.count("\n", 0, offset), phrase))
    offenders = [
        "line %d: %s" % (line_no, phrase) for line_no, phrase in sorted(found)
    ]
    if offenders:
        row(False, "L4", "%s tells the worker to create its own seat — %s"
            % (relative, "; ".join(offenders)))
    else:
        row(True, "L4", "%s worker-facing region never tells the worker to delegate" % relative)

# --- L4.C / L4.N: neither scan is vacuous, and each boundary is asserted -----
# One control row per scan, both directions on every run. A classifier that
# stopped matching anything — or one that fired on prose its scan has to
# tolerate — would otherwise report L4 green over four regions and mean nothing
# by it. The two sets are NOT interchangeable: an entry belongs to the set for
# the scan that actually sees that text on a real region.

# L4.C — the RAW scan, which is what runs everywhere outside the section body.
OUTSIDE_VIOLATIONS = (
    "dispatch a reviewer to double-check your work",
    "spawn a second reviewer for another opinion",
    "launch your own implementer subagent for the boring half",
    # hard-wrapped, exactly as this prose is stored on disk
    "If the diff is large, dispatch a\n    reviewer to double-check your work.",
    # a violation appended immediately after the section: the shape a
    # position-only L4 lets through
    "never spawn a reviewer to check your work.\n\n    If it is a big diff, spawn a second agent to help.",
    # plain delegation instructions that merely CONTAIN a negator: the shape a
    # region-wide negation exemption lets through, because NEGATOR_RE never
    # asks whether the negator governs the verb. These reds are the whole
    # reason the raw scan exists — a regression to region-wide negation
    # exemption fails here.
    "If you are not sure, spawn a second reviewer for another opinion.",
    "You don't have to do this alone: spawn a reviewer to check your work.",
    "If no reviewer is available, spawn a reviewer yourself.",
)
OUTSIDE_BENIGN = (
    "Use this template when dispatching a spec compliance reviewer subagent.",
    "Review arrives from the controller after you report.",
    "**Only dispatch after spec compliance review passes.**",
)

# L4.N — the negation-exempt scan, which runs over the section body ALONE. The
# body is the one place a drifting edit can append an instruction and still be
# read as part of the prohibition, so the government boundary is asserted here.
INSIDE_VIOLATIONS = (
    "dispatch a reviewer to double-check your work",
    "If the diff is large, dispatch a\n    reviewer to double-check your work.",
    "never spawn a reviewer to check your work.\n\n    If it is a big diff, spawn a second agent to help.",
    # a negator in the same sentence that governs something else entirely: the
    # shape a sentence-scoped exemption lets through even inside the body
    "If you are not sure, spawn a second reviewer for another opinion.",
    "You don't have to do this alone: spawn a reviewer to check your work.",
    "If no reviewer is available, spawn a reviewer yourself.",
    "There is no need to rush; spawn another agent to help.",
    "Do not do this alone — spawn a second reviewer.",
)
INSIDE_BENIGN = (
    # the section's own phrasing: the prohibition it has to quote to forbid it
    "You are a leaf worker: never spawn a subagent to implement part of the\n    task, and never spawn a reviewer to check your work.",
    "Never spawn a second reviewer for another opinion.",
    # hard-wrapped between the negator and the verb: one clause, still exempt
    "You must never\n    spawn a reviewer to check your work.",
)


def control_row(ident, scan_name, violations, benign, negation_exempt):
    missed = [t for t in violations if not delegation_offenders(t, negation_exempt)]
    tripped = [t for t in benign if delegation_offenders(t, negation_exempt)]
    if missed:
        row(False, ident, "the %s does not match: %s" % (scan_name, "; ".join(missed)))
    elif tripped:
        row(False, ident, "the %s fires on prose it must tolerate: %s"
            % (scan_name, "; ".join(tripped)))
    else:
        row(True, ident, "the %s separates %d violation(s) from %d control(s)"
            % (scan_name, len(violations), len(benign)))


control_row("L4.C", "raw outside-the-section classifier",
            OUTSIDE_VIOLATIONS, OUTSIDE_BENIGN, False)
control_row("L4.N", "negation-exempt in-section classifier",
            INSIDE_VIOLATIONS, INSIDE_BENIGN, True)

# --- L5: controller scoping preserved --------------------------------------
SKILL = "plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
skill_text = "\n".join(read_lines(absolute(SKILL)))
WAVE_SENTENCE = "Prepare every handoff, preflight the complete wave, then dispatch before waiting."
lost = []
if "sdd_launch_prepared_batch" not in skill_text:
    lost.append("sdd_launch_prepared_batch")
if WAVE_SENTENCE not in skill_text:
    lost.append("the dispatch-before-wait sentence")
if lost:
    row(False, "L5a", "%s no longer carries %s — the worker-facing contract must not "
                      "narrow the controller's wave dispatch" % (SKILL, " or ".join(lost)))
else:
    row(True, "L5a", "%s still names sdd_launch_prepared_batch and the dispatch-before-wait "
                     "sentence" % SKILL)

countermanding = sorted(
    relative for relative, body in section_bodies.items()
    if re.search(r"in\s+parallel", body, re.IGNORECASE)
)
if countermanding:
    row(False, "L5b", "worker-facing section(s) countermand the parallel-wave contract: %s"
        % ", ".join(countermanding))
else:
    row(True, "L5b", "no worker-facing section countermands the parallel-wave contract")

sys.stdout.write("\n".join(rows) + "\n")
PY
PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then
  echo "FATAL: the leaf-worker guard crashed (rc=$PY_RC)" >&2
  cat "$TMP/err.txt" >&2
  exit 2
fi

TAB="$(printf '\t')"
ROW_COUNT=0
while IFS="$TAB" read -r verdict text; do
  [ -n "${verdict:-}" ] || continue
  ROW_COUNT=$((ROW_COUNT + 1))
  if [ "$verdict" = "PASS" ]; then
    pass "$text"
  else
    note_fail "$text"
  fi
done < "$ROWS"

# Anti-vacuity floor on the harness itself: every row id must have reported.
# A guard whose python half produced a short or empty list would otherwise
# print "0 failed" and exit 0.
if [ "$ROW_COUNT" -eq 0 ]; then
  echo "FATAL: the leaf-worker guard produced no rows" >&2
  exit 2
fi
for ident in L0 L1 L2 L3a L3b L4 L4.C L4.N L5a L5b; do
  if ! grep -qF -- "$TAB$ident " "$ROWS"; then
    echo "FATAL: the leaf-worker guard reported no $ident row" >&2
    exit 2
  fi
done

echo
echo "leaf-worker-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

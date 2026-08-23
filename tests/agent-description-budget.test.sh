#!/usr/bin/env bash
# tests/agent-description-budget.test.sh — issues #746 and #744.
#
# TWO INVARIANTS LIVE HERE, and the file name only names the second. A1/A5 are
# the STRICT-PARSE gate over every frontmatter surface the plugin ships (#744);
# A0/A2/A3/A4 are the always-resident agent `description` budget (#746). They
# share a file because A1 is the budget's enabling assert — a description that
# does not parse cannot be measured — and because the strict parse needs PyYAML,
# which this fixture is already declared Unix-only for.
#
# An agent's `description` frontmatter is the ONE part of the agent that is
# resident in the system prompt of every session, whether or not the agent ever
# runs: it is how the model decides when to delegate, so it can never be
# lazy-loaded. Everything else in the file is paid for only on dispatch. That
# makes description bytes categorically more expensive than body bytes, and it
# is the whole reason this fixture exists.
#
# Before #746 the register carried 23,871 resolved description chars (~5,967 est
# tokens, every session and every subagent), of which ~10k was `<example>`
# dispatch-demo blocks in 8 files. Anthropic's own reference `code-reviewer`
# description is ~150 chars; ours was 1,984. "The new rules of context
# engineering for Claude 5 generation models" (2026-07-24) names Examples ->
# Interface Design as one of six shifts, on the grounds that examples constrain
# the model to a certain exploration space — a one-line specialty statement
# routes at least as well on a Claude 5 model.
#
# SIX SUBJECTS, in the order a regression would arrive:
#
#   A1  every SHIPPED frontmatter block parses under a STRICT YAML loader —
#       agents/*.md, skills/*/SKILL.md AND commands/*.md.
#       This is the enabling assert, not a nicety: 8 of 47 agents at the #746
#       baseline did NOT parse (the `<example>` blocks embed `Context: ` /
#       `user: ` / `assistant: ` — bare colon-space inside a plain scalar — and
#       `ci-code-fixer` embedded `fix(ci): `). A strict consumer drops the whole
#       mapping, taking `name`, `model` and `description` with it. A2-A4 cannot
#       measure a description they cannot parse, so this row runs first.
#
#       #744 WIDENED THE CORPUS FROM AGENTS TO EVERY FRONTMATTER SURFACE. The
#       #746 row named the skill half as "the same class" and then scoped
#       itself to agents, so the class stayed live one directory over:
#       `skills/ubersimplify-pipeline/SKILL.md` shipped a `description:` plain
#       scalar carrying a second `": "` (`… as one refactor: commit per area
#       …`) at line 3 column 330, and PyYAML refused the whole mapping with
#       `mapping values are not allowed here`. The visible consequence was that
#       its `model: inherit` never applied. Nothing warned: a SKILL.md with
#       unparseable frontmatter still loads, the name silently falls back to
#       the directory name and the description to the first line of the body,
#       so a dropped field is indistinguishable from a working skill by eye.
#       That is precisely why the guard has to EXECUTE a parser rather than
#       grep for the field — `grep '^model: inherit'` matched the whole time.
#
#       Commands are swept for the same reason and at no extra cost: they are
#       the third frontmatter surface the plugin ships, and #744's own sweep is
#       only meaningful if it covers every place the defect can hide.
#
#       This is also why this fixture, and not tests/skill-size.test.sh, owns
#       the skill half. skill-size is the skills-corpus shape gate, but it is
#       deliberately `bash + find + wc + sort` and runs on BOTH the ubuntu and
#       the windows jobs; a strict parse needs PyYAML, which is not importable
#       on windows-latest, so hosting it there would have cost the size ratchet
#       its Windows coverage. This file is already declared Unix-only for that
#       exact dependency, so the row lands here for free.
#
#   A1b every parsed block still CARRIES the fields its surface cannot work
#       without. A1 proves the mapping survived; it does not prove anything is
#       in it. Both halves are needed because both fail OPEN in the same way —
#       a consumer substitutes a fallback (the directory name for `name`, the
#       first body line for `description`) and warns about neither, so a file
#       missing a field is indistinguishable by eye from one that has it.
#       Required set is per-surface and encoded honestly: commands are keyed by
#       FILENAME and none of the 18 carry a `name:`, so demanding one there
#       would red 18 files for following the format correctly.
#
#   A2  no `description` may carry an `<example>` block. This is the exact
#       regression #746 removed. It is a WRONGNESS predicate, not a taste one:
#       a block either is or is not there, so this row can never drift into an
#       unbounded "is the description good enough" review.
#
#   A3  no single `description` exceeds MAX_ONE resolved chars.
#
#   A4  the SUM over all agents stays at or under MAX_TOTAL. A3 alone is
#       defeated by growth spread thinly across 47 files — each staying under
#       the per-agent cap while the resident total climbs right back. A4 is the
#       ratchet that actually holds the line, and like the version locks in
#       tests/goal.test.sh it is a HARDCODED literal: raising it is a diff a
#       human approves, not something a fix loop can do to itself.
#
#   A5  ANTI-VACUITY FOR THE RULE, not just for the corpus. A1 is a loop whose
#       failure population is zero by design once the tree is clean, so a
#       loader that stopped refusing anything would print a green A1 forever.
#       A5 drives the SAME `parse_frontmatter` A1 uses against synthetic
#       blocks — including the exact #744 shape — and requires it to refuse
#       the bad ones and to resolve `model` on the good one. Executed, never
#       transcribed: a probe that re-implements the rule it checks is
#       permanently green no matter what the shipped rule does.
#
# ANTI-VACUITY FOR THE CORPUS. Every row above is a for-loop over a glob, and a
# glob that matches nothing passes trivially. A0 pins the agent corpus size and
# floors the skill and command corpora, so a moved directory or a renamed
# extension fails loudly instead of reporting a clean sweep over zero files.
#
# The agent count is an EXACT pin because MAX_TOTAL is calibrated against it;
# the skill and command counts are FLOORS because no ratchet depends on them and
# an exact pin would red CI on every routine skill addition. Same reasoning, and
# the same shape, as the `MEASURED -ge 20` floor in tests/skill-size.test.sh.

set -euo pipefail

# ci-wiring: UBUNTU-ONLY, and in the test.yml `ci-wiring windows-skip-list`
# marker block. The shell half is genuinely cross-platform — pure file reads,
# no path separators, nothing that differs on Windows — but the probe below
# does `import yaml`, and PyYAML is NOT importable on windows-latest. That is
# the same dependency that already makes ubersimplify-aggregate.test.sh and the
# four testers-* fixtures Unix-only (#520).
#
# It is skipped there by the JOB, never by the fixture: run anywhere without
# PyYAML this file REFUSES with a distinct message and rc=2 rather than
# reporting a budget violation it never measured. See the exit-code contract in
# the probe below.
#
# And the declaration is a TWO-WAY RUNTIME CONTRACT, not a name on a list.
# tests/ci-wiring.test.sh W9.1 requires every fixture the marker block names to
# carry the refusal guard below as its FIRST executable statement, and W9.2
# requires the enforcing set and the declared set to be equal in BOTH
# directions. So the guard here and the test.yml entry are one atomic edit:
# either alone reds ci-wiring on both jobs.
#
# The guard's rc=2 is the SAME code the wrapper at the bottom of this file uses
# for "the probe could not run", and deliberately so — a Git Bash invocation is
# exactly that case reached one step earlier. Nothing has been measured, and no
# agent description has been shown to exceed the budget.
# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/uberdev"
AGENT_DIR="$PLUGIN_ROOT/agents"
SKILL_DIR="$PLUGIN_ROOT/skills"
COMMAND_DIR="$PLUGIN_ROOT/commands"

# Refuse rather than sweep a directory that is not there. A missing corpus is an
# environment fault, and A1 reporting "all 0 blocks parse" over it would be the
# vacuous-green shape the A0 floors exist to prevent.
for _dir in "$AGENT_DIR" "$SKILL_DIR" "$COMMAND_DIR"; do
  [ -d "$_dir" ] || { echo "FATAL: frontmatter corpus directory missing: $_dir" >&2; exit 2; }
done

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
note_fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# --- The pinned budget ------------------------------------------------------
#
# EXPECT_AGENTS is the live count of plugins/uberdev/agents/*.md.
#
# MAX_ONE is 500. Anthropic's reference description is ~150 chars, so 500 is
# already 3x generous; the longest surviving UberDev description is 474
# (finding-verifier), which carries a real dispatch contract rather than
# scaffolding. Set it any looser and it stops being a cap.
#
# MAX_TOTAL is the post-#746 measured total plus a deliberate ~7% of headroom,
# so adding a normal-sized agent does not red CI on the day it lands, while a
# second `<example>`-scale regression (thousands of chars) does. Measured
# post-#746 total: 11,720.
#
# MIN_SKILLS / MIN_COMMANDS are floors for the two corpora A1 gained in #744.
# Deliberately well below the live counts (30 skills, 18 commands) so a routine
# addition never has to touch this file, while a glob that stopped matching —
# a moved directory, a renamed extension — still fails loudly.
EXPECT_AGENTS=47
MAX_ONE=500
MAX_TOTAL=12500
MIN_SKILLS=20
MIN_COMMANDS=10

echo "## frontmatter parse (#744) + agent description budget (#746)"

# `python3 -B` without `-I`: PyYAML lives in the user site-packages on a
# developer machine, and `-I` implies `-s`, which drops exactly that path. The
# four other PyYAML fixtures in this suite (testers-agent-contract,
# testers-pipeline, cluster-pipeline, ubersimplify-aggregate) call plain
# `python3` for the same reason.
#
# `|| probe_rc=$?` rather than `if python3 …; then`: the two non-zero states
# below carry different meanings and must not be flattened into one `else`.
probe_rc=0
PYTHONDONTWRITEBYTECODE=1 python3 -B - \
     "$AGENT_DIR" "$EXPECT_AGENTS" "$MAX_ONE" "$MAX_TOTAL" \
     "$SKILL_DIR" "$MIN_SKILLS" "$COMMAND_DIR" "$MIN_COMMANDS" <<'PY' || probe_rc=$?
import pathlib
import re
import sys
import traceback

# EXIT-CODE CONTRACT — read by the bash wrapper below. Two non-zero states,
# deliberately distinct, because they send an operator to opposite places:
#
#   0  every row passed.
#   1  a row FAILED. The A0-A5 rows printed above name which, and the fix is in
#      the shipped frontmatter (A1) or the agent files (A2-A4). A genuine
#      content violation.
#   3  THE PROBE COULD NOT RUN — PyYAML missing, an unreadable corpus, a bad
#      argv, any unexpected crash. NOTHING has been parsed and NOTHING has been
#      measured about any agent description; the fix is in the environment.
#
# rc=1 is reachable ONLY from the single explicit `SystemExit(1)` at the very
# bottom. That is what the `main()` + catch-all exist for: python exits 1 on an
# uncaught traceback too, so a bare `import yaml` at module scope would hand the
# wrapper the exact status of a real budget violation on a machine that simply
# has no PyYAML — and the wrapper would print "a description exceeded the
# budget" over zero printed rows, sending someone hunting a defect in the agent
# files that does not exist.
PROBE_ERROR = 3

try:
    import yaml
except ImportError as exc:
    print("FATAL: the A0-A5 probe requires PyYAML and could not import it (%s). "
          "No frontmatter block has been parsed and no agent description has "
          "been measured." % exc, file=sys.stderr)
    raise SystemExit(PROBE_ERROR)

FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.S)

# A1b — the fields each surface cannot work without, keyed by surface.
#
# `commands` requires only `description`: a command's identity IS its filename
# and none of the 18 shipped command files carry a `name:` key. Encoding that
# asymmetry rather than smoothing it over is the point — demanding `name` here
# would red 18 files for following the format correctly, and dropping the
# commands row entirely would stop guarding the one field they do need.
REQUIRED_FIELDS = {
    "agents": ("name", "description"),
    "skills": ("name", "description"),
    "commands": ("description",),
}


def parse_frontmatter(text):
    """(mapping, None) on a strict parse, or (None, reason) on a refusal.

    THE single source of truth for the A1 sweep and the A5 mutant probes. A5
    exists to prove this function still refuses, so it must be the very code A1
    runs — a probe driving a transcribed copy would stay green while the
    shipped row rotted, which is the failure mode #744 shipped through in the
    first place (`grep '^model: inherit'` matched the entire time the field was
    being dropped).
    """
    match = FRONTMATTER.match(text)
    if not match:
        return None, "no --- frontmatter block"
    try:
        data = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        # Report the parser's own message: it names the offending line and
        # column, which is what makes a failure actionable rather than just red.
        return None, str(exc).replace("\n", " ")[:200]
    if not isinstance(data, dict):
        return None, "frontmatter is %s, not a mapping" % type(data).__name__
    return data, None


# A5 — mutant probes for `parse_frontmatter`. Columns:
#   (what the row stands for, frontmatter text, must_refuse, expected `model`)
# `must_refuse` is asserted as "a reason came back", never as an exact PyYAML
# message: the message wording is a library detail and pinning it would make a
# PyYAML upgrade look like a defect in the corpus.
MUTANTS = (
    ("#744: a plain scalar carrying a second ': ' is refused",
     '---\nname: x\ndescription: does a thing: and then another\nmodel: inherit\n---\n',
     True, None),
    ("#744 fixed: the same description double-quoted parses, and `model` resolves",
     '---\nname: x\ndescription: "does a thing: and then another"\nmodel: inherit\n---\n',
     False, "inherit"),
    ("#746: an <example> block's `user: ` line is refused",
     '---\nname: x\ndescription: routes work. <example>\nuser: do the thing\n'
     '</example>\nmodel: inherit\n---\n',
     True, None),
    ("a frontmatter block that is a bare scalar, not a mapping, is refused",
     '---\njust a string\n---\n',
     True, None),
    ("a file with no frontmatter at all is refused",
     '# Heading\n\nbody text\n',
     True, None),
)


def run_mutants():
    """Rows for A5. Returns a list of failure strings (empty when discriminating)."""
    bad = []
    for label, text, must_refuse, want_model in MUTANTS:
        data, reason = parse_frontmatter(text)
        if must_refuse:
            if reason is None:
                bad.append("%s — parse_frontmatter ACCEPTED it (%r)" % (label, data))
        elif reason is not None:
            bad.append("%s — parse_frontmatter refused it (%s)" % (label, reason))
        elif data.get("model") != want_model:
            bad.append("%s — `model` resolved to %r, expected %r"
                       % (label, data.get("model"), want_model))
    return bad


def main():
    agent_dir, expect_agents, max_one, max_total = (
        pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
        int(sys.argv[4]))
    skill_dir, min_skills, command_dir, min_commands = (
        pathlib.Path(sys.argv[5]), int(sys.argv[6]), pathlib.Path(sys.argv[7]),
        int(sys.argv[8]))

    paths = sorted(agent_dir.glob("*.md"))
    # Every frontmatter surface the plugin ships. Labelled by the path relative
    # to the plugin root, not by `path.name`: 30 skills all name their file
    # SKILL.md, so a bare filename would make a failure unattributable.
    skill_paths = sorted(skill_dir.glob("*/SKILL.md"))
    command_paths = sorted(command_dir.glob("*.md"))
    corpus = (
        [("agents", "agents/%s" % p.name, p) for p in paths]
        + [("skills", "skills/%s/SKILL.md" % p.parent.name, p) for p in skill_paths]
        + [("commands", "commands/%s" % p.name, p) for p in command_paths])
    failures = []

    # A0 — anti-vacuity. A0 is not a style check: A1-A4 are all for-loops, and
    # a glob that matched nothing would report four clean sweeps.
    if len(paths) != expect_agents:
        failures.append(
            "A0 corpus size is %d, expected %d — the glob moved, or an agent "
            "was added/removed without re-pinning EXPECT_AGENTS and MAX_TOTAL"
            % (len(paths), expect_agents))
    else:
        print("  PASS  A0 the corpus is %d agent files (non-vacuous)" % len(paths))

    # A0 floors for the two corpora A1 gained in #744. Floors, not pins: nothing
    # here is calibrated against the counts, so an exact pin would only add
    # churn — but a glob that stopped matching must still fail loudly.
    for label, found, floor, knob in (
            ("skill", len(skill_paths), min_skills, "MIN_SKILLS"),
            ("command", len(command_paths), min_commands, "MIN_COMMANDS")):
        if found < floor:
            failures.append(
                "A0 the %s corpus is %d file(s), below the floor of %d — the "
                "glob moved or the directory was renamed; A1 would otherwise "
                "report a clean sweep over nothing. Fix the glob, or lower %s "
                "in a diff a human approves."
                % (label, found, floor, knob))
        else:
            print("  PASS  A0 the corpus is %d %s file(s), at or above the floor of %d"
                  % (found, label, floor))

    unparseable, missing_fields, oversize, with_examples = [], [], [], []
    total = 0
    longest = ("", 0)
    fields_checked = 0

    # A1 + A1b — the enabling asserts, over EVERY shipped frontmatter surface
    # (#744). The agents' parsed mappings are kept as they go by, because A2-A4
    # need them and re-reading the same 47 files to re-run the same parse would
    # be two chances for the two loops to disagree about what a file says.
    agent_data = []
    for surface, label, path in corpus:
        data, reason = parse_frontmatter(path.read_text(encoding="utf-8"))
        if reason is not None:
            unparseable.append("%s: %s" % (label, reason))
            continue  # A1b cannot ask what is in a mapping that does not exist
        for field in REQUIRED_FIELDS[surface]:
            fields_checked += 1
            value = data.get(field)
            if not isinstance(value, str) or not value.strip():
                missing_fields.append("%s: no usable `%s` after a strict parse "
                                      "(got %r)" % (label, field, value))
        if surface == "agents":
            agent_data.append((path, data))

    # A2-A4 measure agent descriptions only. An agent A1 could not parse is not
    # in agent_data at all, and one A1b found no `description` on is skipped
    # here — both are already reported above, and there is nothing left to
    # measure about either.
    for path, data in agent_data:
        description = data.get("description")
        if not isinstance(description, str) or not description.strip():
            continue

        size = len(description)
        total += size
        if size > longest[1]:
            longest = (path.stem, size)
        if "<example>" in description:
            with_examples.append("%s (%d chars)" % (path.name, size))
        if size > max_one:
            oversize.append("%s: %d chars" % (path.name, size))

    if unparseable:
        failures.append(
            "A1 %d shipped frontmatter block(s) do not strictly parse. A "
            "consumer drops the WHOLE mapping — `name`, `model` and "
            "`description` with it — and warns about none of it:\n        %s"
            % (len(unparseable), "\n        ".join(unparseable)))
    else:
        print("  PASS  A1 all %d shipped frontmatter blocks parse under a strict "
              "YAML loader (%d agents, %d skills, %d commands)"
              % (len(corpus), len(paths), len(skill_paths), len(command_paths)))

    # A1b — presence, not just parseability. A dropped field fails OPEN.
    if missing_fields:
        failures.append(
            "A1b %d required frontmatter field(s) are missing. A consumer "
            "substitutes a fallback — the directory name for `name`, the first "
            "body line for `description` — and warns about neither:\n        %s"
            % (len(missing_fields), "\n        ".join(missing_fields)))
    elif unparseable:
        # Honest under-report rather than a green over an unmeasured corpus:
        # every file A1 refused was skipped above, so this row did not see them.
        failures.append(
            "A1b did not run over %d file(s) A1 could not parse — fix A1 first; "
            "nothing has been asserted about their required fields"
            % len(unparseable))
    else:
        print("  PASS  A1b all %d required frontmatter field(s) are present "
              "across %d files" % (fields_checked, len(corpus)))

    # A2 — the #746 regression itself.
    if with_examples:
        failures.append(
            "A2 %d description(s) carry an <example> block — dispatch demos "
            "belong in the agent BODY (paid on dispatch), never in the "
            "always-resident description:\n        %s"
            % (len(with_examples), "\n        ".join(with_examples)))
    else:
        print("  PASS  A2 no description carries an <example> block")

    # A3 — per-agent cap.
    if oversize:
        failures.append("A3 %d description(s) exceed the %d-char cap:\n        %s"
                        % (len(oversize), max_one, "\n        ".join(oversize)))
    else:
        print("  PASS  A3 every description is within the %d-char cap (longest: %s at %d)"
              % (max_one, longest[0], longest[1]))

    # A4 — the ratchet.
    if total > max_total:
        failures.append(
            "A4 the resident description total is %d chars (~%d est tokens), "
            "over the pinned budget of %d. Trim a description, or raise "
            "MAX_TOTAL in a diff a human approves."
            % (total, total // 4, max_total))
    else:
        print("  PASS  A4 resident description total is %d/%d chars (~%d est tokens)"
              % (total, max_total, total // 4))

    # A5 — anti-vacuity for the RULE. A1's failure population is zero by design
    # on a clean tree, so without this a loader that stopped refusing anything
    # would print a green A1 forever.
    mutant_failures = run_mutants()
    if mutant_failures:
        failures.append(
            "A5 the frontmatter parser is not discriminating — A1 above is only "
            "as strong as this row, so fix the parser, not the corpus:\n        %s"
            % "\n        ".join(mutant_failures))
    else:
        print("  PASS  A5 parse_frontmatter separates all %d mutant row(s) "
              "(#744 and #746 shapes included)" % len(MUTANTS))

    if failures:
        print()
        for failure in failures:
            print("  FAIL  " + failure)
        return 1
    return 0


# `except Exception` and not `except BaseException`: SystemExit and
# KeyboardInterrupt are BaseException, so the PyYAML refusal above still exits 3
# and a Ctrl-C still reads as an interrupt rather than as a crashed probe.
try:
    rc = main()
except Exception:
    traceback.print_exc()
    print("FATAL: the A0-A5 probe crashed before reaching a verdict (traceback "
          "above). No frontmatter block has been parsed and no agent "
          "description has been measured.", file=sys.stderr)
    rc = PROBE_ERROR
raise SystemExit(rc)
PY

# THREE states, three messages, three exit codes. `python3` absent is rc=127
# from the shell and PyYAML absent is rc=3 from the probe; both land in the
# last arm, which is the whole point — an environment that could not run the
# probe must never be reported as "a description exceeded the budget", because
# there would be no rows above it and the operator would go looking for a
# defect in the agent files that was never measured, let alone found.
if [ "$probe_rc" -eq 0 ]; then
  pass "A0-A5 frontmatter parses and the agent description budget holds"
elif [ "$probe_rc" -eq 1 ]; then
  note_fail "A0-A5 a frontmatter block does not parse, or the agent description budget is violated (see rows above)"
else
  echo "FATAL: the A0-A5 probe could not run (exit $probe_rc) — python3 or PyYAML" >&2
  echo "       is unavailable, or the probe crashed before reaching a verdict." >&2
  echo "       This is an ENVIRONMENT failure, not a finding: no frontmatter block" >&2
  echo "       has been parsed and no agent description has been measured. Nothing" >&2
  echo "       above this line is a finding." >&2
  exit 2
fi

echo
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

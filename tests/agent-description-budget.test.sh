#!/usr/bin/env bash
# tests/agent-description-budget.test.sh — issue #746.
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
# FOUR SUBJECTS, in the order a regression would arrive:
#
#   A1  every agent's frontmatter parses under a STRICT YAML loader.
#       This is the enabling assert, not a nicety: 8 of 47 agents at the #746
#       baseline did NOT parse (the `<example>` blocks embed `Context: ` /
#       `user: ` / `assistant: ` — bare colon-space inside a plain scalar — and
#       `ci-code-fixer` embedded `fix(ci): `). A strict consumer drops the whole
#       mapping, taking `name`, `model` and `description` with it. It is the
#       same class as #744, and A2-A4 cannot measure a description they cannot
#       parse, so this row runs first.
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
# ANTI-VACUITY. Every row above is a for-loop over a glob, and a glob that
# matches nothing passes all four trivially. A0 pins the corpus size, so a moved
# directory or a renamed extension fails loudly instead of reporting a clean
# sweep over zero files.

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
AGENT_DIR="$ROOT/plugins/uberdev/agents"

[ -d "$AGENT_DIR" ] || { echo "FATAL: agent directory missing: $AGENT_DIR" >&2; exit 2; }

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
EXPECT_AGENTS=47
MAX_ONE=500
MAX_TOTAL=12500

echo "## agent description budget (#746)"

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
     "$AGENT_DIR" "$EXPECT_AGENTS" "$MAX_ONE" "$MAX_TOTAL" <<'PY' || probe_rc=$?
import pathlib
import re
import sys
import traceback

# EXIT-CODE CONTRACT — read by the bash wrapper below. Two non-zero states,
# deliberately distinct, because they send an operator to opposite places:
#
#   0  every row passed.
#   1  a row FAILED. The A0-A4 rows printed above name which, and the fix is in
#      the agent files. A genuine content violation.
#   3  THE PROBE COULD NOT RUN — PyYAML missing, an unreadable corpus, a bad
#      argv, any unexpected crash. NOTHING has been measured about any agent
#      description; the fix is in the environment.
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
    print("FATAL: the A0-A4 probe requires PyYAML and could not import it (%s). "
          "No agent description has been measured." % exc, file=sys.stderr)
    raise SystemExit(PROBE_ERROR)

FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.S)


def main():
    agent_dir, expect_agents, max_one, max_total = (
        pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
        int(sys.argv[4]))

    paths = sorted(agent_dir.glob("*.md"))
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

    unparseable, oversize, with_examples = [], [], []
    total = 0
    longest = ("", 0)

    for path in paths:
        text = path.read_text(encoding="utf-8")
        match = FRONTMATTER.match(text)
        if not match:
            unparseable.append("%s: no --- frontmatter block" % path.name)
            continue
        try:
            data = yaml.safe_load(match.group(1))
        except yaml.YAMLError as exc:
            # Report the parser's own message: it names the offending column,
            # which is what makes this row actionable rather than just red.
            detail = str(exc).replace("\n", " ")
            unparseable.append("%s: %s" % (path.name, detail[:200]))
            continue
        if not isinstance(data, dict):
            unparseable.append("%s: frontmatter is %s, not a mapping"
                               % (path.name, type(data).__name__))
            continue
        description = data.get("description")
        if not isinstance(description, str) or not description.strip():
            unparseable.append("%s: no usable `description` after a strict parse"
                               % path.name)
            continue

        size = len(description)
        total += size
        if size > longest[1]:
            longest = (path.stem, size)
        if "<example>" in description:
            with_examples.append("%s (%d chars)" % (path.name, size))
        if size > max_one:
            oversize.append("%s: %d chars" % (path.name, size))

    # A1 — the enabling assert.
    if unparseable:
        failures.append("A1 %d agent frontmatter block(s) do not strictly parse:\n        %s"
                        % (len(unparseable), "\n        ".join(unparseable)))
    else:
        print("  PASS  A1 all %d agent frontmatter blocks parse under a strict YAML loader"
              % len(paths))

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
    print("FATAL: the A0-A4 probe crashed before reaching a verdict (traceback "
          "above). No agent description has been measured.", file=sys.stderr)
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
  pass "A0-A4 agent description budget holds"
elif [ "$probe_rc" -eq 1 ]; then
  note_fail "A0-A4 agent description budget violated (see rows above)"
else
  echo "FATAL: the A0-A4 probe could not run (exit $probe_rc) — python3 or PyYAML" >&2
  echo "       is unavailable, or the probe crashed before reaching a verdict." >&2
  echo "       This is an ENVIRONMENT failure, not a budget violation: no agent" >&2
  echo "       description has been measured. Nothing above this line is a finding." >&2
  exit 2
fi

echo
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

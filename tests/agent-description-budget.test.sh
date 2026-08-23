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

# ci-wiring: cross-platform. Pure file reads plus a YAML parse — no shell
# builtins, no path separators, nothing that differs on Windows. Deliberately
# NOT in the test.yml windows-skip-list.

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
if PYTHONDONTWRITEBYTECODE=1 python3 -B - \
     "$AGENT_DIR" "$EXPECT_AGENTS" "$MAX_ONE" "$MAX_TOTAL" <<'PY'
import pathlib
import re
import sys

import yaml

agent_dir, expect_agents, max_one, max_total = (
    pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))

FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.S)

paths = sorted(agent_dir.glob("*.md"))
failures = []

# A0 — anti-vacuity. A0 is not a style check: A1-A4 are all for-loops, and a
# glob that matched nothing would report four clean sweeps.
if len(paths) != expect_agents:
    failures.append(
        "A0 corpus size is %d, expected %d — the glob moved, or an agent was "
        "added/removed without re-pinning EXPECT_AGENTS and MAX_TOTAL"
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
        # Report the parser's own message: it names the offending column, which
        # is what makes this row actionable rather than just red.
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
        "A2 %d description(s) carry an <example> block — dispatch demos belong "
        "in the agent BODY (paid on dispatch), never in the always-resident "
        "description:\n        %s"
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
        "A4 the resident description total is %d chars (~%d est tokens), over "
        "the pinned budget of %d. Trim a description, or raise MAX_TOTAL in a "
        "diff a human approves." % (total, total // 4, max_total))
else:
    print("  PASS  A4 resident description total is %d/%d chars (~%d est tokens)"
          % (total, max_total, total // 4))

if failures:
    print()
    for failure in failures:
        print("  FAIL  " + failure)
    raise SystemExit(1)
PY
then
  pass "A0-A4 agent description budget holds"
else
  note_fail "A0-A4 agent description budget violated (see rows above)"
fi

echo
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

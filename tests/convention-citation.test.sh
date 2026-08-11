#!/usr/bin/env bash
# tests/convention-citation.test.sh — issue #433.
#
# The `review_pr.review.convention` lens is the one Phase 1 reviewer whose
# finding is a claim ABOUT A DOCUMENT ("the project's rules say X"). That shape
# reads as authoritative and is trivially hallucinable, so the lens ships with
# its own filter and is admissible only because of it. This fixture is that
# filter's proof.
#
# Two subjects, both deterministic:
#
#   D1–D7   `uberdev_review_rule_sources` — the rule-source ALLOWLIST discovery
#           in plugins/uberdev/lib/review-fleet-args.sh. Prune correctness is
#           load-bearing: a checkout with sibling worktrees carries a full second
#           copy of every AGENTS.md, and a citation scoped to another branch's
#           rule file would read as verified.
#
#   CC1–CC9, CC15
#           `classify_convention_citation` in plugins/uberdev/lib/
#           code_fixer_contract.py — the pure predicate that decides whether one
#           finding's citation is real. Driven through its CLI verb, which is
#           also the proof the verb is reachable.
#
# Every fixture builds its own tree under `mktemp -d`. Running the discovery
# rows against the live repo would make them VACUOUS — this checkout happens to
# carry both AGENTS.md and CLAUDE.md at its root, so "the allowlist is
# non-empty" would pass no matter what the prune list did.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_ARGS="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
CONTRACT="$REPO_ROOT/plugins/uberdev/lib/code_fixer_contract.py"

for required in "$FLEET_ARGS" "$CONTRACT"; do
  if [ ! -r "$required" ]; then
    echo "FATAL: required file missing or unreadable: $required" >&2
    exit 2
  fi
done

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
note_fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# shellcheck disable=SC1090
. "$FLEET_ARGS" || { echo "FATAL: could not source $FLEET_ARGS" >&2; exit 2; }

echo "== D: rule-source allowlist discovery (uberdev_review_rule_sources) =="

# assert_sources FIXTURE_DIR EXPECTED_LINES DESC — EXPECTED_LINES is the exact
# newline-joined stdout, so an extra or missing row fails. Not a substring check:
# "contains AGENTS.md" would pass on a prune regression that also emitted six
# worktree copies of it.
assert_sources() {
  local fixture="$1" expected="$2" desc="$3" actual rc
  actual="$(uberdev_review_rule_sources "$fixture")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    note_fail "$desc (helper exited $rc)"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    note_fail "$desc"
    echo "        expected: $(printf '%s' "$expected" | tr '\n' '|')"
    echo "        actual:   $(printf '%s' "$actual" | tr '\n' '|')"
  fi
}

D1="$TMP_ROOT/d1"; mkdir -p "$D1"; : >"$D1/AGENTS.md"
assert_sources "$D1" 'AGENTS.md' "D1 — a lone root AGENTS.md is the whole allowlist"

D2="$TMP_ROOT/d2"; mkdir -p "$D2"; : >"$D2/AGENTS.md"; : >"$D2/CLAUDE.md"
assert_sources "$D2" 'AGENTS.md
CLAUDE.md' "D2 — root AGENTS.md + CLAUDE.md, in LC_ALL=C order"

D3="$TMP_ROOT/d3"; mkdir -p "$D3/plugins/x"; : >"$D3/plugins/x/AGENTS.md"
assert_sources "$D3" 'plugins/x/AGENTS.md' \
  "D3 — a nested rule file is reported as a POSIX repo-relative path"

D4="$TMP_ROOT/d4"
mkdir -p "$D4/.worktrees/w1" "$D4/.claude/worktrees/w2"
: >"$D4/AGENTS.md"
: >"$D4/.worktrees/w1/AGENTS.md"
: >"$D4/.claude/worktrees/w2/AGENTS.md"
assert_sources "$D4" 'AGENTS.md' \
  "D4 — sibling-worktree rule copies are pruned (.worktrees and .claude/worktrees)"

D5="$TMP_ROOT/d5"; mkdir -p "$D5/node_modules/pkg"
: >"$D5/AGENTS.md"; : >"$D5/node_modules/pkg/.editorconfig"
assert_sources "$D5" 'AGENTS.md' "D5 — node_modules is pruned"

D6="$TMP_ROOT/d6"; mkdir -p "$D6/src"; : >"$D6/src/main.py"
assert_sources "$D6" '' \
  "D6 — a tree with no rule sources yields an empty allowlist, not an error"

D7="$TMP_ROOT/d7"; mkdir -p "$D7"
D7_INDEX=1
while [ "$D7_INDEX" -le 250 ]; do
  mkdir -p "$D7/pkg$D7_INDEX"
  : >"$D7/pkg$D7_INDEX/AGENTS.md"
  D7_INDEX=$((D7_INDEX + 1))
done
D7_COUNT="$(uberdev_review_rule_sources "$D7" | grep -c '')"
if [ "$D7_COUNT" = "$UBERDEV_REVIEW_RULE_SOURCE_LIMIT" ]; then
  pass "D7 — 250 rule files are capped at $UBERDEV_REVIEW_RULE_SOURCE_LIMIT rows"
else
  note_fail "D7 — expected $UBERDEV_REVIEW_RULE_SOURCE_LIMIT capped rows, got $D7_COUNT"
fi

echo
echo "== CC: the citation gate (classify_convention_citation, via its CLI verb) =="

REQUESTS="$TMP_ROOT/requests"
mkdir -p "$REQUESTS"

# The fixture rule corpus and every request document, built in one place so the
# quotes below are copied from the same bytes the gate reads.
if ! python3 -I -B - "$REQUESTS" <<'PY'
import json, os, sys

out = sys.argv[1]

root_rules = [
    "# Fixture project rules",
    "",
    "## Process",
    "",
    "Red, green, refactor. Test first, then implement.",
    "",
    "- Conventional commits only.",
    "- Reference the issue in the branch name.",
    "",
    "## Quality bar",
    "",
    "Never commit with failing tests.",
    "",
    "- No swallowed errors anywhere in the tree.",
    "",
    "## Errors",
    "",
    "Every catch must handle, wrap, or",
    "rethrow the error. An empty catch block is",
    "never acceptable in shipped code.",
]
# Pad well past the cited lines so CC4 can cite a line 40 rows away from the
# quote and still be inside the file.
root_rules += ["Filler prose line number %d." % n for n in range(len(root_rules) + 1, 90)]

nested_rules = [
    "# Plugin-scoped rules",
    "",
    "Shell fences run under zsh; avoid every bashism in this subtree.",
]

def write(name, payload):
    with open(os.path.join(out, name), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(payload))

ROOT = "AGENTS.md"
NESTED = "plugins/uberdev/AGENTS.md"
ALLOWLIST = [ROOT, NESTED]

def request(detail, location_path, rule_lines, changed_paths=None,
            allowlist=None):
    return {
        "detail": detail,
        "location_path": location_path,
        "allowlist": ALLOWLIST if allowlist is None else allowlist,
        "changed_paths": [] if changed_paths is None else changed_paths,
        "rule_lines": rule_lines,
    }

# Line 12 (1-indexed) is "Never commit with failing tests."
verbatim = root_rules[11]
assert verbatim == "Never commit with failing tests.", verbatim
write("cc1.json", request(
    "confidence: 90 — rule %s:12 — the change deletes a failing assert — quote: %s"
    % (ROOT, verbatim), "tests/thing.test.sh", root_rules))

write("cc2.json", request(
    "confidence: 90 — rule %s:12 — the change deletes a failing assert — quote: %s"
    % (ROOT, "Never commit with failing testz."), "tests/thing.test.sh", root_rules))

# Lines 18-20 wrap one rule across three physical lines.
wrapped = " ".join(root_rules[17:20])
write("cc3.json", request(
    "confidence: 80 — rule %s:18 — the new catch is empty — quote: %s"
    % (ROOT, wrapped), "lib/thing.sh", root_rules))

write("cc4.json", request(
    "confidence: 90 — rule %s:60 — cited 48 lines from where the text lives — quote: %s"
    % (ROOT, verbatim), "tests/thing.test.sh", root_rules))

nested_quote = nested_rules[2]
write("cc5.json", request(
    "confidence: 70 — rule %s:3 — a bashism in a tools script — quote: %s"
    % (NESTED, nested_quote), "tools/x.sh", nested_rules))

write("cc6.json", request(
    "confidence: 70 — rule %s:3 — a bashism inside the governed subtree — quote: %s"
    % (NESTED, nested_quote), "plugins/uberdev/lib/y.sh", nested_rules))

write("cc7.json", request(
    "confidence: 70 — rule docs/notes.md:3 — cites a file nobody allowlisted — quote: %s"
    % nested_quote, "plugins/uberdev/lib/y.sh", nested_rules))

write("cc8.json", request(
    "This clearly violates the project conventions around error handling.",
    "lib/thing.sh", root_rules))

# Assembled at runtime: a contiguous AWS example key in these bytes would
# hard-stop finish-branch's pre-push secret scan on the diff that adds them.
secret_quote = "Rotate the key " + "AKIA" + "IOSFODNN7EXAMPLE" + " immediately."
secret_rules = list(root_rules)
secret_rules[11] = secret_quote
write("cc9.json", request(
    "confidence: 60 — rule %s:12 — the diff hardcodes the same key — quote: %s"
    % (ROOT, secret_quote), "lib/thing.sh", secret_rules))

short_quote = "Test first"          # 10 normalised characters
assert len(short_quote) < 12, short_quote
short_rules = list(root_rules)
short_rules[11] = short_quote
write("cc15-short.json", request(
    "confidence: 90 — rule %s:12 — too short to cite anything — quote: %s"
    % (ROOT, short_quote), "lib/thing.sh", short_rules))

long_quote = ("Keep every rule short enough to quote and long enough to mean "
              "something at all, because a citation that runs on forever is a "
              "rule document being republished into a pull request body rather "
              "than a rule being cited by a reviewer today, and the carve-out "
              "that permits rule text in a finding stops well before that. ")
long_quote = long_quote[:301]
assert len(long_quote) == 301, len(long_quote)
long_rules = list(root_rules)
long_rules[11] = long_quote
write("cc15-long.json", request(
    "confidence: 90 — rule %s:12 — too long to be a citation — quote: %s"
    % (ROOT, long_quote), "lib/thing.sh", long_rules))

# Self-introduced: the PR under review edited the rule file it cites.
write("cc11.json", request(
    "confidence: 90 — rule %s:12 — cites a rule this very PR wrote — quote: %s"
    % (ROOT, verbatim), "tests/thing.test.sh", root_rules,
    changed_paths=[ROOT, "tests/thing.test.sh"]))
PY
then
  echo "FATAL: could not build the citation request fixtures" >&2
  exit 2
fi

# classify_fields REQUEST -> "<outcome> <reason>". Two full-consumption readers,
# never an early-exiting one: this file runs under `set -o pipefail`.
classify_fields() {
  python3 -I -B "$CONTRACT" classify-convention-citation <"$1" \
    | python3 -I -B -c 'import json,sys; v=json.load(sys.stdin); print(v["outcome"], v["reason"])'
}

# expect_citation asserts the EXACT verdict pair. An assertion that only checked
# "not accepted" would pass on a gate that culled everything, which is the one
# regression CC14 (in the writer rows) and CC1/CC6 exist to catch.
expect_citation() {
  local request="$1" want="$2" desc="$3" got
  got="$(classify_fields "$REQUESTS/$request")" || got="<verb-failed>"
  if [ "$got" = "$want" ]; then
    pass "$desc"
  else
    note_fail "$desc (wanted '$want', got '$got')"
  fi
}

expect_citation cc1.json 'accept citation-verified' \
  "CC1 — a byte-exact quote at the cited line is accepted"
expect_citation cc2.json 'cull citation-not-verbatim' \
  "CC2 — one altered character is culled, not downweighted"
expect_citation cc3.json 'accept citation-verified' \
  "CC3 — a rule wrapped across markdown lines verifies against its one-line form"
expect_citation cc4.json 'cull citation-not-verbatim' \
  "CC4 — text that exists in the file but not near the cited line is culled"
expect_citation cc5.json 'cull citation-out-of-scope' \
  "CC5 — a plugins/uberdev rule does not govern tools/"
expect_citation cc6.json 'accept citation-verified' \
  "CC6 — the same rule does govern its own subtree"
expect_citation cc7.json 'cull citation-not-in-allowlist' \
  "CC7 — a file outside the controller-supplied allowlist is never opened"
expect_citation cc8.json 'cull citation-unparsable' \
  "CC8 — plain prose with no citation grammar is culled"
expect_citation cc9.json 'cull citation-secret-shaped' \
  "CC9 — the rule-text carve-out never covers a secret-shaped value"
expect_citation cc15-short.json 'cull citation-not-verbatim' \
  "CC15 — a quote below the minimum length cites nothing"
expect_citation cc15-long.json 'cull citation-not-verbatim' \
  "CC15 — a quote above the 300-character carve-out ceiling is refused"
expect_citation cc11.json 'demote citation-self-introduced' \
  "CC11 — a rule this PR itself wrote demotes the finding instead of culling it"

echo
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

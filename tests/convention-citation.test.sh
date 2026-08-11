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
#   CC1–CC9, CC15, CC17–CC31, CC34–CC36
#           `classify_convention_citation` in plugins/uberdev/lib/
#           code_fixer_contract.py — the pure predicate that decides whether one
#           finding's citation is real. Driven through its CLI verb, which is
#           also the proof the verb is reachable. CC17–CC31 and CC34–CC36 are
#           the redaction guard specifically, one row per guard in BOTH
#           directions plus the order the guard runs in, because that guard is
#           the only part of the predicate whose failure mode is invisible: a
#           refusal is logged and never surfaced, so an over-firing guard reads
#           exactly like a clean review. CC32–CC33 run the same two directions
#           through the shipped writer.
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

# D8 — an unreadable root is a REFUSAL, never an empty allowlist. The two answers
# are byte-identical downstream ("no rules found"), and only one of them means
# "this repo wrote no conventions down"; reporting a broken walk as the other is
# how this lens would silently enforce nothing.
if uberdev_review_rule_sources "$TMP_ROOT/does-not-exist" >/dev/null 2>&1; then
  note_fail "D8 — an unreadable repository root was reported as an empty allowlist"
else
  pass "D8 — an unreadable repository root refuses instead of reporting no rules"
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

# ---- CC17-CC31 + CC34-CC36: the redaction guard ------------------------
#
# Every credential below is assembled from fragments at runtime, exactly like
# cc9 above: a contiguous secret-shaped literal in these source bytes would
# hard-stop finish-branch's pre-push secret scan on the diff that adds them (the
# scan reads the diff, so the token never has to reach a commit to abort one).
# tests/finish-branch.test.sh carries the same idiom.
#
# Each token is also chosen so that exactly ONE guard can carry its row, which
# is what makes the row a test of that guard rather than of the gate in general:
#   - the Slack, Stripe and base32 values are the three concrete strings the
#     statistical rule scores as identifiers, so only their NAMED tuple entry
#     can refuse them;
#   - the GitHub tail is deliberately blocky and the JWT segments are both under
#     the statistical minimum of 32, for the same isolation;
#   - the hex digest sits below the 4.0-bit base64 floor, so only the hex scan
#     reaches it, and the base64 blob has no issuer prefix at all, so only the
#     statistical rule does.
SLACK_BOT = "xox" + "b-52601815908-3016613186091-8oOOL8dKLzdocJ2isAjIhKtJ"
SLACK_USER = "xox" + "p-30460913671-2183094671553-4820163905-KpQ2vR7mTwXzB1nLcYsH"
STRIPE_LIVE = "sk" + "_live_" + "Jr4i0B3JrTAwR4y9ojfljoQo"
TOTP_SEED = "KHVDGAJGXBENYJQWX6HH" + "7566TFJGVQ6K"
GITHUB_SERVER = "gh" + "s_" + "aaaaBBBBccccDDDDeeeeFFFFggggHHHHiiii"
JWT = ("eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIn0"
       + "." + "dBjftJeZ4CVPmB92K27uhbUJU1p1r")
HEX_DIGEST = "da39a3ee5e6b4b0d" + "3255bfef95601890afd80709"
B64_BLOB = "Q7wz9LmXr4Kv8Nb6" + "YcHa5Jd0PfSgT2Ui1Ao3Ep7Rq9Zx"


def redaction_case(name, quote, line=12):
    """One request whose cited line holds `quote` verbatim, and nothing else.

    Every check before the redaction guard therefore PASSES, so the verdict the
    row asserts can only have come from the guard itself.
    """
    body = list(root_rules)
    body[line - 1] = quote
    write(name, request(
        "confidence: 80 — rule %s:%d — the rule text carries a live value — quote: %s"
        % (ROOT, line, quote), "lib/thing.sh", body))


for case_name, case_quote in (
    ("cc17", "Rotate the workspace bot token " + SLACK_BOT + " before merging."),
    ("cc18", "The user token " + SLACK_USER + " must never reach a diff."),
    ("cc19", "Never hardcode the billing key " + STRIPE_LIVE + " in a fixture."),
    ("cc20", "The shared seed " + TOTP_SEED + " lives in the vault only."),
    ("cc21", "Server tokens such as " + GITHUB_SERVER + " expire but still leak."),
    ("cc22", "Strip the session assertion " + JWT + " out of every log line."),
    ("cc23", "The signing digest " + HEX_DIGEST + " is not a checksum to publish."),
    ("cc24", "Our archived deploy key " + B64_BLOB + " was rotated in March."),
):
    redaction_case(case_name + ".json", case_quote)

# The other half of the guard, and the half a statistical rule gets wrong: rule
# documents are FULL of long identifiers, and every one of these quotes is
# ordinary rule prose. A gate that refuses them deletes a true finding and says
# so only in a log nobody reads. CC26 spells four fragments that occur in this
# checkout today (see `git grep -hIoE "sk-[A-Za-z0-9]{8,}"`), which is what
# makes the loose `sk-` bound a live defect rather than a hypothetical one.
for case_name, case_quote in (
    ("cc25", "Every helper name must start with a risk-mismatch guard."),
    ("cc26", "A task-manifest, disk-recovery or kiosk-frontend change needs a "
             "run-risk-mismatch note."),
    ("cc27", "Call uberdev_command_workspace_prepare before "
             "REVIEW_FLEET_CI_CONFLICT_TOTAL_CAP applies."),
    ("cc28", "Register monkeyJsonSerializerFactoryRegistry in the adapter table."),
    ("cc29", "Read plugins/uberdev/lib/review-fleet-args.sh before editing it."),
    # The issuer prefixes are word TAILS in English, so an entry that is not
    # anchored reads a key out of the middle of an identifier. Measured, not
    # hypothetical: without the boundary the Stripe entry refuses this quote,
    # and the statistical rule does not (churn 0.171, far under the floor), so
    # nothing else in the gate would notice.
    ("cc34", "Name it task_live_DispatchConfigurationBuilder in the registry."),
    # The base32 scan carries TWO floors, and each one alone is what keeps this
    # row out of the cull: cc35 clears the entropy floor at 3.644 bits and is
    # saved only by the class floor (glued uppercase words carry no digits,
    # where a drawn seed does), cc36 carries both classes and is saved only by
    # the entropy floor (every [A-Z2-7]{32,} run in this checkout is a padding
    # fixture exactly like it). Neither floor is provable from the other.
    ("cc35", "Replace REPLACEWITHYOURACTUALSECRETVALUE before shipping."),
    ("cc36", "The fixture digest AAAAAAAAAAAAAAAA2222222222222222 is not a key."),
):
    redaction_case(case_name + ".json", case_quote)

# CC30 — a quote that fails BOTH the length ceiling and the redaction guard must
# report the LENGTH. The first failing check names the reason, and a reader of
# the citation log has to be told the quote was never a citation at all; naming
# the redaction guard there would report a leak that never existed.
ordering_long = "Rotate " + SLACK_BOT + " because "
ordering_long += "x" * (301 - len(ordering_long))     # one over the ceiling
assert len(ordering_long) == 301, len(ordering_long)
redaction_case("cc30.json", ordering_long)

# CC31 — the same ordering one check earlier: a secret-shaped quote that is not
# in the cited file at all is `citation-not-verbatim`. Line 12 still holds the
# fixture rule, so the ONLY reason this quote can fail on is the window read.
write("cc31.json", request(
    "confidence: 80 — rule %s:12 — quotes a line that is not there — quote: %s"
    % (ROOT, "Rotate " + SLACK_BOT + " immediately."),
    "lib/thing.sh", root_rules))
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
echo "== CC17-CC31 + CC34-CC36: the redaction guard, and its order =="
# CC9 above only ever reaches the AWS entry of the named tuple, so every other
# guard in `_convention_quote_is_secret_shaped` is invisible to it. These rows
# are one per guard, in both directions.
#
# The refuse half. Each token here is unreachable by every guard except the one
# the row names (see the fixture comment), so deleting that guard reds THIS row
# and not merely some row.
expect_citation cc17.json 'cull citation-secret-shaped' \
  "CC17 — a Slack bot token is refused, though its digit blocks read as an identifier"
expect_citation cc18.json 'cull citation-secret-shaped' \
  "CC18 — a Slack user token is refused for the same reason"
expect_citation cc19.json 'cull citation-secret-shaped' \
  "CC19 — a Stripe live key is refused, though its core is one character too short to score"
expect_citation cc20.json 'cull citation-secret-shaped' \
  "CC20 — a base32 TOTP seed is refused, though one letter case barely changes class"
expect_citation cc21.json 'cull citation-secret-shaped' \
  "CC21 — every GitHub token prefix is refused, not only ghp_"
expect_citation cc22.json 'cull citation-secret-shaped' \
  "CC22 — a JWT is refused although both its segments are under the statistical minimum"
expect_citation cc23.json 'cull citation-secret-shaped' \
  "CC23 — a hex digest is refused on the hex floor, which base64 entropy never reaches"
expect_citation cc24.json 'cull citation-secret-shaped' \
  "CC24 — a prefixless random blob is refused by the statistical rule alone"

# The accept half — the direction that cost this gate real findings. Without
# these rows every refuse row above still passes on a guard that refuses
# everything, which is a silent no-op nobody can see: the cull is only logged,
# and the lens then recomputes to APPROVE with nothing left in it.
expect_citation cc25.json 'accept citation-verified' \
  "CC25 — ordinary hyphenated English (risk-mismatch) is not a secret"
expect_citation cc26.json 'accept citation-verified' \
  "CC26 — four sk- fragments that occur in this checkout today all survive"
expect_citation cc27.json 'accept citation-verified' \
  "CC27 — long snake_case and SCREAMING_SNAKE identifiers survive"
expect_citation cc28.json 'accept citation-verified' \
  "CC28 — an identifier spelling eyJ mid-word is not a JWT"
expect_citation cc29.json 'accept citation-verified' \
  "CC29 — a repo-relative path is not a base64 blob"
expect_citation cc34.json 'accept citation-verified' \
  "CC34 — an issuer prefix buried mid-identifier (task_live_...) is not a key"
expect_citation cc35.json 'accept citation-verified' \
  "CC35 — a run of glued uppercase words is not a base32 seed (class floor)"
expect_citation cc36.json 'accept citation-verified' \
  "CC36 — a two-class padding fixture is not a base32 seed (entropy floor)"

# The ordering half: the FIRST failing check names the reason.
expect_citation cc30.json 'cull citation-not-verbatim' \
  "CC30 — a quote failing both the length ceiling and the guard reports the LENGTH"
expect_citation cc31.json 'cull citation-not-verbatim' \
  "CC31 — a secret-shaped quote that is not in the file reports the WINDOW, not a leak"

echo
echo "== R: the cull-reason vocabulary is actually closed =="
# CONVENTION_CULL_REASONS calls itself closed. A comment that says "closed" while
# nothing compares it to the code is the completeness-guard-with-a-disjoint-
# predicate class: a new refusal path could drop a finding under a reason no
# caller knows about, and the cull log would name something the register never
# declared. This row makes the claim testable in BOTH directions.
if python3 -I -B - "$CONTRACT" "$REPO_ROOT/plugins/uberdev/lib/review-aggregate.sh" <<'PY'
import importlib.util, inspect, pathlib, re, sys

contract_path, aggregate_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("uberdev_contract_closure", contract_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

declared = set(module.CONVENTION_CULL_REASONS)
source = inspect.getsource(module.classify_convention_citation)
emitted = set(re.findall(r'refuse\("([a-z-]+)"\)', source))
emitted |= set(re.findall(r'"reason": "([a-z-]+)"', source))
emitted.discard("citation-verified")
emitted.discard(module.CONVENTION_DEMOTE_REASON)

problems = []
for reason in sorted(emitted - declared):
    problems.append("predicate refuses with an UNDECLARED reason: " + reason)

# The writer-level classes are the other half of the register: they never come
# out of the predicate, so nothing else would notice them going missing.
writer = pathlib.Path(aggregate_path).read_text(encoding="utf-8")
for reason in sorted(declared - emitted):
    if ("'" + reason + "'") not in writer:
        problems.append(
            "declared reason is emitted by neither the predicate nor the writer: " + reason)

if problems:
    print("\n".join(problems))
    raise SystemExit(1)
PY
then
  pass "R1 - every cull reason the gate can emit is declared, and every declared reason is emitted"
else
  note_fail "R1 - CONVENTION_CULL_REASONS and the code that refuses have drifted"
fi

echo
echo "== G: the citation grammar is spelled identically on every surface =="
# ONE contract, FOUR copies: the predicate that parses it
# (lib/code_fixer_contract.py), the prompt that asks for it
# (skills/review-fleet/workflow.js), the agent file that documents it, and the
# shared output contract carrying the redaction carve-out for it. The separator
# is an EM DASH, and a surface that drifts to a hyphen -- or to different spacing
# -- makes every finding from that dispatch `citation-unparsable` while every
# other shape test still passes.
GRAMMAR_MARKER=' — quote: '
for grammar_surface in \
  "plugins/uberdev/lib/code_fixer_contract.py" \
  "plugins/uberdev/skills/review-fleet/workflow.js" \
  "plugins/uberdev/agents/convention-compliance.md" \
  "plugins/uberdev/shared/phase1-reviewer-output-v1.md"
do
  if grep -Fq -- "$GRAMMAR_MARKER" "$REPO_ROOT/$grammar_surface"; then
    pass "G1 - $grammar_surface spells the quote separator identically"
  else
    note_fail "G1 - $grammar_surface has drifted from the quote separator"
  fi
done
# The full skeleton reaches the two surfaces a reviewer actually reads.
GRAMMAR_SKELETON='confidence: <0-100> — rule <allowlisted-path>:<line> — '
for grammar_surface in \
  "plugins/uberdev/skills/review-fleet/workflow.js" \
  "plugins/uberdev/agents/convention-compliance.md"
do
  if grep -Fq -- "$GRAMMAR_SKELETON" "$REPO_ROOT/$grammar_surface"; then
    pass "G2 - $grammar_surface states the full detail grammar the gate parses"
  else
    note_fail "G2 - $grammar_surface does not state the full detail grammar"
  fi
done

echo
echo "== CC10-CC16: the gate INSIDE the real aggregate writer =="
# These rows drive post_review_write_aggregate_v2 as shipped, over a full
# seven-row captured input. They are the difference between "the predicate is
# correct" and "the predicate is wired into the artifact anybody reads".

AGG_LIB="$REPO_ROOT/plugins/uberdev/lib/review-aggregate.sh"
# shellcheck disable=SC1090
. "$AGG_LIB" || { echo "FATAL: could not source $AGG_LIB" >&2; exit 2; }
UBERDEV_REVIEW_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

# w_case NAME CONVENTION_DETAIL CONVENTION_SEVERITY -> builds a fixture tree in
# $TMP_ROOT/w/<name> and prints its directory. The tree carries its own
# AGENTS.md (and nothing else), so CC14's "a real citation survives" row is not
# vacuous the way it would be against this checkout, which happens to have both
# AGENTS.md and CLAUDE.md.
w_build() {
  local name="$1" detail="$2" severity="$3" changed="$4" rules="$5"
  python3 -I -B - "$TMP_ROOT/w/$name" "$detail" "$severity" "$changed" "$rules" <<'PY'
import hashlib, json, os, sys

case_dir, detail, severity, changed_paths_json, rules = sys.argv[1:]
os.makedirs(os.path.join(case_dir, "root"), exist_ok=True)

edges = [
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
    "review_pr.review.convention",
]

# The rule document the convention finding cites. Line 3 is the rule.
with open(os.path.join(case_dir, "root", "AGENTS.md"), "w", encoding="utf-8") as handle:
    handle.write(rules)

with open(os.path.join(case_dir, "rule-sources.txt"), "w", encoding="utf-8") as handle:
    handle.write("AGENTS.md\n")
with open(os.path.join(case_dir, "changed-paths.json"), "w", encoding="utf-8") as handle:
    handle.write(changed_paths_json)


def content(rows):
    verdict = "REVISIONS_REQUIRED" if any(r[0] == "blocker" for r in rows) else "APPROVE"
    lines = ["```yaml", "verdict: " + verdict]
    if rows:
        lines.append("findings:")
        for sev, location, summary, det in rows:
            lines.extend([
                "  - severity: " + sev,
                "    location: " + location,
                "    summary: " + summary,
                "    detail: " + json.dumps(det),
            ])
    else:
        lines.append("findings: []")
    lines.extend(["confidence: high", "```"])
    return "\n".join(lines)


# One non-convention finding, so every row also proves the gate leaves other
# lenses alone.
rows_by_edge = [
    [("suggestion", "src/log.ts:17", "Consider structured logger",
      "A structured logger would improve diagnostics.")],
    [], [], [], [], [],
    [(severity, "lib/thing.sh:4", "Breaks a written project rule", detail)],
]
captured = {"ledger_sha256": "a" * 64, "rows": [], "schema_version": 1}
for index, (edge, rows) in enumerate(zip(edges, rows_by_edge), 1):
    body = content(rows)
    captured["rows"].append({
        "content": body, "edge": edge, "index": index,
        "instance": "fixture-%d" % index,
        "sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
    })
with open(os.path.join(case_dir, "input.json"), "w", encoding="utf-8") as handle:
    handle.write(json.dumps(captured, sort_keys=True, separators=(",", ":")))
PY
}

W_RULES='# Fixture rules

Never commit with failing tests.
'
W_QUOTE='Never commit with failing tests.'
W_GOOD="confidence: 90 — rule AGENTS.md:3 — the change deletes a failing assert — quote: $W_QUOTE"
W_FAKE='confidence: 90 — rule AGENTS.md:3 — the project forbids this — quote: All handlers must be idempotent.'

mkdir -p "$TMP_ROOT/w"

# w_run NAME -> runs the shipped writer over case NAME; echoes rc.
w_run() {
  local case_dir="$TMP_ROOT/w/$1" rc
  post_review_write_aggregate_v2 "$(cat "$case_dir/input.json")" "$case_dir/aggregate.md" \
    "$case_dir/rule-sources.txt" "$case_dir/root" "$case_dir/changed-paths.json" \
    "$case_dir/citations.md" 2>"$case_dir/stderr.txt"
  rc=$?
  printf '%s' "$rc"
}

# w_field CASE JQ_PATH -> a value out of the published aggregate's JSON body.
w_field() {
  python3 -I -B - "$TMP_ROOT/w/$1/aggregate.md" "$2" <<'PY'
import json, sys
payload = open(sys.argv[1], encoding="utf-8").read()
body = payload.split("\n", 1)[1].rsplit("\n</external-untrusted-input>", 1)[0]
value = json.loads(body)
kind = sys.argv[2]
if kind == "convention-verdict":
    print(next(c["verdict"] for c in value["contributors"]
               if c["id"] == "review_pr.review.convention"))
elif kind == "finding-count":
    print(len(value["findings"]))
elif kind == "convention-findings":
    print(len([f for f in value["findings"]
               if "review_pr.review.convention" in f["source_edges"]]))
elif kind == "convention-severity":
    print(next(f["severity"] for f in value["findings"]
               if "review_pr.review.convention" in f["source_edges"]))
else:
    raise SystemExit("unknown field " + kind)
PY
}

# --- CC10: a culled blocker leaves the contributor APPROVE and the finding gone
w_build cc10 "$W_FAKE" blocker '[]' "$W_RULES"
if [ "$(w_run cc10)" = 0 ] \
   && [ "$(w_field cc10 convention-verdict)" = APPROVE ] \
   && [ "$(w_field cc10 convention-findings)" = 0 ] \
   && [ "$(w_field cc10 finding-count)" = 1 ]; then
  pass "CC10 — a fabricated blocker is culled, its contributor recomputes to APPROVE, other lenses survive"
else
  note_fail "CC10 — the writer did not cull the fabricated blocker or corrupted the other lens"
fi
if grep -q 'citation-not-verbatim' "$TMP_ROOT/w/cc10/citations.md"; then
  pass "CC10 — the cull is recorded in the citation log, never swallowed"
else
  note_fail "CC10 — the cull log does not name the reason"
fi

# --- CC11 (writer half): a rule this PR wrote demotes rather than culls
w_build cc11w "$W_GOOD" blocker '["AGENTS.md"]' "$W_RULES"
if [ "$(w_run cc11w)" = 0 ] \
   && [ "$(w_field cc11w convention-findings)" = 1 ] \
   && [ "$(w_field cc11w convention-severity)" = suggestion ] \
   && [ "$(w_field cc11w convention-verdict)" = APPROVE ]; then
  pass "CC11 — a self-introduced rule survives as a suggestion, not a blocker"
else
  note_fail "CC11 — the self-introduced demotion did not reach the aggregate"
fi
if grep -q 'citation-self-introduced' "$TMP_ROOT/w/cc11w/citations.md"; then
  pass "CC11 — the demotion is recorded alongside the culls"
else
  note_fail "CC11 — the demotion is not in the citation log"
fi

# --- CC12: no allowlist is a REFUSED write, not a clean zero-finding aggregate
w_build cc12 "$W_GOOD" blocker '[]' "$W_RULES"
rm -f "$TMP_ROOT/w/cc12/rule-sources.txt"
CC12_RC="$(w_run cc12)"
if [ "$CC12_RC" != 0 ] && [ ! -e "$TMP_ROOT/w/cc12/aggregate.md" ] \
   && grep -q 'rule-sources-unavailable' "$TMP_ROOT/w/cc12/stderr.txt"; then
  pass "CC12 — a missing allowlist fails the writer closed and names rule-sources-unavailable"
else
  note_fail "CC12 — a missing allowlist did not fail closed (rc=$CC12_RC)"
fi

# --- CC13: an allowlist that EXISTS and is empty is legitimate
w_build cc13 "$W_GOOD" blocker '[]' "$W_RULES"
: >"$TMP_ROOT/w/cc13/rule-sources.txt"
if [ "$(w_run cc13)" = 0 ] \
   && [ "$(w_field cc13 convention-findings)" = 0 ] \
   && [ "$(w_field cc13 finding-count)" = 1 ] \
   && grep -q 'Rule sources: none' "$TMP_ROOT/w/cc13/citations.md"; then
  pass "CC13 — an empty allowlist publishes, records 'none', and leaves other lenses untouched"
else
  note_fail "CC13 — the empty-allowlist case did not publish cleanly"
fi

# --- CC14: THE regression guard. A true citation must SURVIVE.
# Without this row every other row above still passes on a gate that culls
# everything — a 100 % silent no-op in every worktree and in CI.
w_build cc14 "$W_GOOD" blocker '[]' "$W_RULES"
if [ "$(w_run cc14)" = 0 ] \
   && [ "$(w_field cc14 convention-findings)" = 1 ] \
   && [ "$(w_field cc14 convention-severity)" = blocker ] \
   && [ "$(w_field cc14 convention-verdict)" = REVISIONS_REQUIRED ]; then
  pass "CC14 — a verifiable citation survives the gate with its severity intact"
else
  note_fail "CC14 — the gate culled a TRUE citation; the lens is a silent no-op"
fi

# --- CC16: the gate never rewrites what it read
# Child result.md snapshots are sha256-pinned in the trusted ledger and read back
# through secure_capture_published. Filtering the AGGREGATE is the whole design;
# mutating a child's bytes would break the tamper-evidence chain.
CC16_BEFORE="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$TMP_ROOT/w/cc14/input.json")"
w_run cc14 >/dev/null
CC16_AFTER="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$TMP_ROOT/w/cc14/input.json")"
if [ "$CC16_BEFORE" = "$CC16_AFTER" ]; then
  pass "CC16 — the captured reviewer bytes are unchanged by the gate"
else
  note_fail "CC16 — the gate mutated its own input"
fi

# --- CC32/CC33: the redaction guard, end to end through the shipped writer
# CC17-CC31 above drive the predicate. These two drive the ARTIFACT, in both
# directions, because that is the surface the harm was measured on: a blocker
# citing an ordinary hyphenated rule came out of the writer as APPROVE with zero
# findings, and nothing but the citation log said why.
#
# The token is assembled at runtime for the same reason cc9 is: finish-branch's
# pre-push scan reads the DIFF, so a contiguous Slack token on a new line here
# would abort the push that adds it. tests/finish-branch.test.sh:78 does the
# same with the AWS example key.
W_IDENT_QUOTE='Every helper name must start with a risk-mismatch guard.'
W_IDENT_RULES="# Fixture rules

$W_IDENT_QUOTE
"
W_IDENT="confidence: 90 — rule AGENTS.md:3 — the new helper has no guard — quote: $W_IDENT_QUOTE"

W_SLACK_TOKEN="xox""b-52601815908-3016613186091-8oOOL8dKLzdocJ2isAjIhKtJ"
W_SECRET_QUOTE="Rotate the workspace bot token $W_SLACK_TOKEN before merging."
W_SECRET_RULES="# Fixture rules

$W_SECRET_QUOTE
"
W_SECRET="confidence: 90 — rule AGENTS.md:3 — the diff hardcodes it — quote: $W_SECRET_QUOTE"

w_build cc32 "$W_IDENT" blocker '[]' "$W_IDENT_RULES"
if [ "$(w_run cc32)" = 0 ] \
   && [ "$(w_field cc32 convention-findings)" = 1 ] \
   && [ "$(w_field cc32 convention-severity)" = blocker ] \
   && [ "$(w_field cc32 convention-verdict)" = REVISIONS_REQUIRED ]; then
  pass "CC32 — a blocker quoting a hyphenated rule reaches the aggregate intact"
else
  note_fail "CC32 — the redaction guard silently deleted a true finding end to end"
fi

w_build cc33 "$W_SECRET" blocker '[]' "$W_SECRET_RULES"
if [ "$(w_run cc33)" = 0 ] \
   && [ "$(w_field cc33 convention-findings)" = 0 ] \
   && [ "$(w_field cc33 convention-verdict)" = APPROVE ] \
   && grep -q 'citation-secret-shaped' "$TMP_ROOT/w/cc33/citations.md"; then
  pass "CC33 — a live credential in a real rule line is culled and the cull is logged"
else
  note_fail "CC33 — a credential rode out of the writer inside a citation"
fi

echo
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

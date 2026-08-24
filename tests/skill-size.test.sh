#!/usr/bin/env bash
# tests/skill-size.test.sh — the SKILL.md size ratchet (#747).
#
# Anthropic's skills documentation states the ceiling plainly: "Keep SKILL.md
# under 500 lines. Move detailed reference material to separate files." The cost
# is recurring, not one-off — once a skill loads, its body stays in context
# across turns — and auto-compaction re-attaches an invoked skill at only its
# first 5,000 tokens, inside a 25,000-token budget shared with every other skill
# invoked in the same session. So an oversize body is not merely expensive: it is
# the part of a long pipeline that silently stops being in context on exactly the
# runs that need it most. That is why this file exists as a CI gate rather than a
# style note.
#
# Rows:
#   S1  every SKILL.md on disk is at or under LIMIT, unless it carries a waiver
#   S2  every WAIVED skill is at or under its own pinned ceiling
#   S3  every waiver names a skill that exists (no rot)
#   S4  anti-vacuity: the sweep actually found skills to measure
#   S5  anti-vacuity for the RULE: the shipped classifier is executed against
#       synthetic rows, so a gate that stopped refusing reds here
#
# THE WAIVER LIST IS THE RATCHET, AND IT ONLY EVER SHRINKS.
#
# Each ceiling is the measured line count at the moment the waiver was written,
# NOT a round number and NOT headroom. Three things follow, and all three are
# enforced below rather than left as a convention:
#
#   * A waived skill that GROWS past its pin reds. Adding to an oversize body is
#     the thing this gate exists to stop, and a waiver is not a licence.
#   * A waived skill that shrinks BELOW LIMIT also reds — with a message saying
#     to delete its row. A waiver that has been earned out but stays on the list
#     is a ceiling nobody is holding, and it would let the skill grow back to its
#     pin unnoticed.
#   * A waiver for a skill that no longer exists reds. A dead row makes the list
#     look longer than the debt actually is.
#
# To lower a ceiling: split prose out into `references/*.md`, re-measure with
# `wc -l`, and pin the NEW number. Never raise one.
#
# Portable by construction: bash + find + wc + sort only. No python, no mktemp,
# no git — so it runs unchanged on both the ubuntu and the windows CI jobs.
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_ROOT="$REPO_ROOT/plugins/uberdev/skills"

if [ ! -d "$SKILLS_ROOT" ]; then
  echo "FATAL: skills root missing or unreadable: $SKILLS_ROOT" >&2
  exit 2
fi

LIMIT=500

# name<TAB>ceiling<TAB>why this row is still over LIMIT. Measured, never rounded.
# See the ratchet note above.
#
# No single excuse covers all nine rows, so each row carries its own, and every
# number in them came from `wc -l` and a fence count rather than from assertion.
# Six of the nine are bodies where more than half the lines sit inside fenced
# blocks — shipped code, several of those fences extracted and executed by other
# tests in this suite — so taking those under LIMIT means relocating executable
# code, which is a different change with a different blast radius. The other
# three are mostly contract prose, where the split is open work rather than an
# impossibility, and the row says so.
#
# One constraint applies to every row, and it is why a split can be WRONG rather
# than merely unfinished. Only SKILL.md is loaded eagerly when a skill fires; a
# `references/*.md` is read only if the model decides to open it. So text the
# pipeline itself acts on at runtime cannot live behind a reference file —
# extracting it there does not shrink the debt, it deletes a rule. Reference
# extraction is right for material a reader consults on demand, and wrong for
# material the runtime obeys.
WAIVERS="$(cat <<'EOF'
premerge-pipeline	2732	~53% fenced (1447/2732) on the counter the merge-pipeline row below specifies; rose 2486->2664->2709 for #716, then 2709->2732 for the trail-emit hardening — the first raise added the two `uberdev-executable` fences the orchestrator env-prefixes and RUNS, one to decide the premerge trust trail and one to publish it; the second hardened that publication fence in place (numeric guard on `combined_pr` before the first write, `git reset --soft` unwind arms on the two pre-push refusals, a `half_emitted` state (`label_unprovisioned` / `label_unapplied`) on the two post-push `gh` arms, plus the `### 5b` summary row that transcribes it); the third makes `PREMERGE_TRAIL_HEAD` a REQUIRED `:?` input on the emit fence, transcribed from the `HEAD=` token the gate fence printed and bound PAST the emit guard on purpose — three of the gate's four skip lines print no `HEAD=` for a skipped call site to pass — then refuses before the anchor commit unless it equals `git rev-parse HEAD`, so a tree no gate read can never be trailered; plus the corrected `### 5-trail` ordering prose, which records that 5-trail runs BEFORE `### 5a` and that the release-anchor helper repaired in the same stack now makes that ordering resolve. Executable-fence code with its inline rationale, and the phase ordering the orchestrator obeys — both acted on at runtime, so neither can move to references/, which already carries 599 lines across 3 files
merge-pipeline	1951	~48% fenced (938/1951), no references/ yet — prose extraction is open work. The ~28% (546/1919) recorded here two rounds ago was a MEASUREMENT ERROR, not shrinkage since: this file gained 32 lines this round, so no amount of growth reaches 938 from 546. Re-measured with the CommonMark rule — lines strictly between the fence markers, opener indent <=3 so a fence nested under a numbered-list item still counts — validated on the seven never-raised rows FIRST, where it reproduces review-fleet's exact 13/800 and each other row's stated percentage. The likely mechanism of the old figure is a column-0-only counter, which reads this file as ~25% (482/1951) because it drops every 3-space-indented fence, and that is exactly where the three largest bash blocks live (208, 143 and 71 inner lines; the first of them is `merge-base-identity-fence-v1` itself). Rose 1778->1835->1919 for #716's generalisation of Phase 1.4 PATH_2 over the trust instrument, then 1919->1951 — sub-condition (a) resolving LABEL_INSTRUMENTS as a SET plus the (b)/(b.5) bindings that read it, then the (b.5) fence gaining the `REVIEW_PR_DEFERRED_CRITICAL` classifier that holds the `review-pr` YELLOW tier to a commit-body token (`review-pr-verdict.json` sits under gitignored `.uberdev/`, so off the producing checkout the tier is otherwise unreadable and `--accept-critical-deferred` is never consulted), and the PATH_2 terminal line deriving `data.trust_anchor` from `$TRUST_INSTRUMENT` rather than hardcoding `uberdev_review_trail`, which mislabelled every premerge landing. All of it is the gate's own decision procedure, read and acted on at runtime, so it cannot move to references/
subagent-driven-dev	1019	~64% fenced — one ~450-line bash block plus dispatch examples
orchestrator	1012	~53% fenced, 26 executable blocks; 2 reference files already split out
cluster-pipeline	1012	~90% fenced — almost entirely shipped bash
finish-branch	984	~75% fenced; 1 reference file already split out
review-fleet	800	13 fenced lines of 800 — all contract prose, no references/ yet
post-impl-review	797	~71% fenced; 1 reference file already split out
writing-skills	744	~19% fenced, no references/ yet — prose extraction is open work
EOF
)"

PASS=0
FAIL=0

# The whole decision, in one place, so §S5 below can EXECUTE it against synthetic
# inputs rather than transcribing a copy of it. A probe that re-implements the
# rule it is checking is permanently green no matter what the shipped rule does.
classify() {  # <lines> <ceiling-or-empty> -> verdict token on stdout
  local lines="$1" ceiling="$2"
  if [ -z "$ceiling" ]; then
    if [ "$lines" -le "$LIMIT" ]; then printf 'ok'; else printf 'over-limit'; fi
    return 0
  fi
  case "$ceiling" in
    ''|*[!0-9]*) printf 'bad-ceiling'; return 0 ;;
  esac
  if   [ "$lines" -le "$LIMIT" ];   then printf 'waiver-earned'
  elif [ "$lines" -le "$ceiling" ]; then printf 'waived'
  else                                   printf 'over-ceiling'
  fi
}

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

waiver_for() {  # <skill-name> -> ceiling on stdout, empty when unwaived
  # `reason` is read into its own variable deliberately: with only two variables
  # the LAST one absorbs the rest of the line, so the trailing reason field would
  # arrive glued to the number and every waived skill would classify as
  # `bad-ceiling`. Same shape as the S5 probe table's trailing description.
  local want="$1" name ceiling reason
  while IFS="$(printf '\t')" read -r name ceiling reason; do
    [ -n "$name" ] || continue
    if [ "$name" = "$want" ]; then
      printf '%s' "$ceiling"
      return 0
    fi
  done <<EOF
$WAIVERS
EOF
  return 0
}

echo "== S1/S2: every SKILL.md is at or under 500 lines, or under its pinned waiver =="

MEASURED=0
# Sorted so the report order is stable across filesystems — an unstable row order
# makes a CI diff unreadable and hides which skill actually moved.
SKILL_FILES="$(find "$SKILLS_ROOT" -name SKILL.md | sort)"

while IFS= read -r skill_file; do
  [ -n "$skill_file" ] || continue
  # `wc -l < file` (redirect, not argument) so the count arrives bare: passing the
  # path makes wc print "<count> <path>", and on a checkout whose path contains a
  # space — this project's own does — a later `[ "$n" -gt ... ]` on that string is
  # a shell ERROR, which `if` swallows. A guard that errors instead of failing is
  # a guard that passes.
  lines="$(wc -l < "$skill_file" | tr -d '[:space:]')"
  case "$lines" in
    ''|*[!0-9]*)
      fail "S1 $skill_file: line count is unreadable ('$lines') — refusing to read that as compliant"
      continue
      ;;
  esac
  MEASURED=$((MEASURED + 1))

  skill_dir="$(dirname "$skill_file")"
  name="$(basename "$skill_dir")"
  ceiling="$(waiver_for "$name")"

  case "$(classify "$lines" "$ceiling")" in
    ok)             pass "S1 $name: $lines lines (limit $LIMIT)" ;;
    over-limit)     fail "S1 $name: $lines lines exceeds the $LIMIT-line limit — move reference material into $name/references/*.md and point at it by path, or add a measured waiver row explaining why it cannot split" ;;
    waived)         pass "S2 $name: $lines lines (waived at $ceiling, still over the $LIMIT-line limit)" ;;
    waiver-earned)  fail "S2 $name: $lines lines is now within the $LIMIT-line limit — DELETE its waiver row so the ceiling cannot drift back up to $ceiling" ;;
    over-ceiling)   fail "S2 $name: $lines lines exceeds its pinned ceiling of $ceiling — a waiver is not a licence to grow. Move the addition into $name/references/*.md, or lower the body somewhere else first" ;;
    bad-ceiling)    fail "S2 $name: waiver ceiling is not a number ('$ceiling')" ;;
    *)              fail "S2 $name: classify returned no verdict for lines=$lines ceiling=$ceiling" ;;
  esac
done <<EOF
$SKILL_FILES
EOF

echo "== S3: every waiver names a skill that exists =="
while IFS="$(printf '\t')" read -r name ceiling reason; do
  [ -n "$name" ] || continue
  if [ -r "$SKILLS_ROOT/$name/SKILL.md" ]; then
    pass "S3 waiver '$name' names a live skill"
  else
    fail "S3 waiver '$name' (ceiling $ceiling) names no skill on disk — delete the row; a dead waiver overstates the remaining debt"
  fi
done <<EOF
$WAIVERS
EOF

echo "== S4: anti-vacuity =="
# Without this, a find that matched nothing — a moved skills root, a typo in
# SKILLS_ROOT — would print no rows and exit 0, reporting a clean sweep over an
# empty set. The floor is deliberately well below today's count so it does not
# have to be edited every time a skill is added or retired.
if [ "$MEASURED" -ge 20 ]; then
  pass "S4 measured $MEASURED SKILL.md file(s)"
else
  fail "S4 measured only $MEASURED SKILL.md file(s) — the sweep found nothing to check, which is not a clean result"
fi

echo "== S5: the gate actually fires (mutant probes against the shipped classifier) =="
# Anti-vacuity for the RULE, not just for the sweep. Every row below drives the
# same `classify` the sweep above uses, so a rule that stopped refusing would red
# here on the commit that broke it. Without these, a classifier that returned
# `ok` unconditionally would print 40 green rows and prove nothing.
#
# Columns: <lines> <ceiling|-> <expected verdict> <what it stands for>
while read -r probe_lines probe_ceiling probe_want probe_desc; do
  [ -n "$probe_lines" ] || continue
  [ "$probe_ceiling" = "-" ] && probe_ceiling=""
  probe_got="$(classify "$probe_lines" "$probe_ceiling")"
  if [ "$probe_got" = "$probe_want" ]; then
    pass "S5 $probe_desc -> $probe_got"
  else
    fail "S5 $probe_desc -> got '$probe_got', want '$probe_want'"
  fi
done <<'EOF'
499 - ok an unwaived skill just under the limit
500 - ok an unwaived skill exactly at the limit
501 - over-limit an unwaived skill one line over the limit
900 800 over-ceiling a waived skill that grew past its pin
800 800 waived a waived skill exactly at its pin
799 800 waived a waived skill that shrank inside its pin
500 800 waiver-earned a waived skill that reached the limit, so its row must go
120 800 waiver-earned a waived skill far under the limit
900 x bad-ceiling a non-numeric ceiling is refused, never read as a pass
EOF

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]

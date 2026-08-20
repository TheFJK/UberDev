#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac

# Issue #650 — the "one contract, N uncompared copies" class (#370 / #371).
#
# Two shipped implementations of "do these paths collide" exist:
#   skills/subagent-driven-dev/SKILL.md  sdd_assert_wave_disjoint  (session lane)
#   lib/turbox-fleet.sh                  wave-disjoint             (turbox lane)
# and the loop caps are declared on sixteen surfaces. Each was pinned only by
# its own local test, so the copies could drift apart while every test stayed
# green. This file is the producer that makes a drift visible.
#
# tests/contract_markers.py CANNOT retire this file. It compares closed TOKEN
# SETS (the set-difference report around :1496-1512) over
# SCAN_ROOTS = ("plugins/uberdev",) (:489) with MIN_MEMBERS = 2 (:496). What is
# duplicated here is a PREDICATE and a set of VALUES, not a vocabulary — a
# marker would compare the cap NAMES and stay green straight through a value
# drift. RFC 0016 says so directly in its "what a marker cannot express" list.
#
# skills/solve-fleet/workflow.js legitimately has NO collision predicate. It
# dispatches exactly one worktree-isolated implementer per issue (#508,
# RFC 0015 §4.1), so it is sequential per task and has no wave to make
# disjoint. That asymmetry is CORRECT, is recorded in vendor.json's
# permanent-divergence note and in RFC 0012 §3.6's "AMENDED by #508" banner,
# and must not be "fixed" by adding a third copy.
#
# The shape mirrored here is tests/review-pr-phase3-ci.test.sh S10.14c: one
# corpus, both implementations, byte-equal verdicts required, with an explicit
# anti-vacuity floor. Do not invent a new shape.
#
# Everything compared below is EXTRACTED from the shipped files at run time.
# A hand-copied twin would pass while the shipped one was broken — which is
# the disjoint-predicate failure this suite exists to avoid
# (tests/turbox-fleet-runtime.test.sh:271-275).
#
# House rules this file is written under:
#   * No pipe into an early-exiting reader (`grep -q`, `grep -m N`, `grep -l`,
#     `head`, `read`) anywhere. Capture first, match against the capture with a
#     herestring — tests/epipe-guard.test.sh:5-38, exemplar at
#     tests/docs-accuracy.test.sh:1211-1213. The inverted-polarity form is the
#     worse half: it reports a real defect as a PASS, which would be a vacuity
#     mechanism inside a vacuity fix.
#   * No register entry is keyed on a LINE NUMBER. Line numbers rot, and a
#     sibling PR editing skills/solve-fleet/SKILL.md shifts them. Every entry is
#     keyed by an extraction regex or an executable invocation, and every path
#     key is ROOT-RELATIVE so §C6 can re-run the whole comparison against a
#     scratch copy tree.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

SDD_SKILL_REL='plugins/uberdev/skills/subagent-driven-dev/SKILL.md'
TBX_LIB_REL='plugins/uberdev/lib/turbox-fleet.sh'

for _required in "$ROOT/$SDD_SKILL_REL" "$ROOT/$TBX_LIB_REL"; do
  [ -r "$_required" ] || { echo "FATAL: required file missing or unreadable: $_required" >&2; exit 2; }
done

ROWS=0
# Set from this file's first green run — the EXACT count, never a `-ge 1` floor
# (plugins/uberdev/docs/testing.md convention 6). Bump it in the same commit
# that adds or removes a row. The structural floor at the bottom of this file is
# what stops a hand-typed number here from certifying a shrunken run.
EXPECTED_ROWS=77
# The §W2 corpus size, declared once. Asserted against the rendered corpus
# before any comparison runs, and a term of REGISTER_FLOOR at the bottom.
W2_ROWS=14

fail()  { printf 'sdd-wave-contract: FAIL %s\n' "$*" >&2; exit 1; }
fatal() { printf 'sdd-wave-contract: FATAL %s\n' "$*" >&2; exit 2; }
row()   { ROWS=$((ROWS + 1)); printf '  PASS  %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Shared extraction + invocation glue. Every helper below reads or execs the
# SHIPPED bytes; none of them carries a copy of what it is checking.
# ---------------------------------------------------------------------------

extract_fence() {   # <SKILL.md> <out.sh>
  python3 -I -B - "$1" "$2" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pat = re.compile(r"```bash\n(sdd_validate_instance_dimensions\(\).*?\n)```", re.DOTALL)
hits = pat.findall(text)
if len(hits) != 1:
    raise SystemExit(
        "SDD runtime fence matched %d time(s) in %s, expected exactly 1" % (len(hits), sys.argv[1])
    )
Path(sys.argv[2]).write_text(hits[0], encoding="utf-8")
PY
}

# The two runners exist so a non-zero rc from the SHIPPED function is a value
# this file can read instead of a `set -e` abort. Both source or exec the
# extracted bytes; neither restates them.
cat >"$TMP/sdd-wave.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$1"
shift
SDD_PREPARED_IMPLEMENT_PATHS=("$@")
sdd_assert_wave_disjoint
SH

cat >"$TMP/sdd-cap.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$1"
sdd_loop_cap "$2"
SH

# Normalise either lane onto the one wire line `<rc>\t<token>\t<path>`.
# `task_a=` / `task_b=` / `task=` identifiers are dropped (rendering rule R-a):
# SDD prints a 1-based argv index and turbox the plan `id`, which is not a
# drift. The `path=` field IS compared (Decision 17).
wire() {   # <rc> <stderr-text>
  local rc="$1" text="$2" token='-' cpath='-'
  if [ -n "$text" ]; then
    token="$(sed -n 's/^uberdev [a-z]*: \([A-Za-z_]*\).*$/\1/p' <<<"$text")"
    [ -n "$token" ] || token='?'
    case "$text" in
      *path=*) cpath="${text##*path=}" ;;
    esac
  fi
  printf '%s\t%s\t%s' "$rc" "$token" "$cpath"
}

run_sdd_wave() {   # <file with one prepared-implement JSON per line>
  local entries=() line rc=0 err
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entries+=("$line")
  done <"$1"
  err="$(bash "$TMP/sdd-wave.sh" "$TMP/runtime.sh" "${entries[@]}" 2>&1 >/dev/null)" || rc=$?
  wire "$rc" "$err"
}

# R-b, the `--wave` filter trap, load-bearing. turbox filters `tasks` by
# `--wave` BEFORE comparing and before its `len(tasks) < 2` short-circuit, while
# the SDD fence receives only the current wave's entries and has no wave
# concept. A renderer that emitted varying `wave` values and passed `--wave`
# would turn every overlap row into a green rc-0/rc-0 agreement — the
# comparator would pass while proving nothing. The chosen rule: this file NEVER
# passes `--wave`, and no rendered task carries a `wave` key at all.
run_tbx_wave() {   # <root> <tasks-json file>
  local rc=0 err json
  json="$(cat "$2")"
  err="$(bash "$1/$TBX_LIB_REL" wave-disjoint --tasks "$json" 2>&1 >/dev/null)" || rc=$?
  wire "$rc" "$err"
}

# The §C5 predicate, reproduced exactly as the spec states it, then filtered to
# hits whose line text carries a digit. Parameterised by root so §C6 can run it
# against a scratch copy tree.
sweep_hits() {   # <root>
  local out
  out="$(cd "$1" && grep -rn -E '(fix_rounds|retest_rounds|context_rounds|FIX_ROUNDS|RETEST_ROUNDS|CONTEXT_ROUNDS)' plugins/uberdev docs/rfc || true)"
  awk -F: '{ line=$0; sub(/^[^:]*:[0-9]+:/, "", line); if (line ~ /[0-9]/) print }' <<<"$out"
}

echo "== sdd-wave-contract: cross-lane wave + cap comparator =="

# ---------------------------------------------------------------------------
# §W0 — extract both under() bodies, fail CLOSED.
# ---------------------------------------------------------------------------

extract_fence "$ROOT/$SDD_SKILL_REL" "$TMP/runtime.sh" \
  || fatal "§W0 could not extract the SDD runtime fence from $SDD_SKILL_REL"

python3 -I -B - "$ROOT/$SDD_SKILL_REL" "$ROOT/$TBX_LIB_REL" \
                "$TMP/under_sdd.py" "$TMP/under_tbx.py" <<'PY' || fatal "§W0 under() extraction failed — see the message above; never fall back to a transcribed copy"
import re
import sys
from pathlib import Path

# The indent class is [ \t]*, NOT \s*: \s matches newlines, and in
# lib/turbox-fleet.sh `def under(a, b):` sits at column 0 preceded by blank
# lines, so \s* would capture "\n\n" and the dedent would eat two characters
# off every body line. The `\s*` INSIDE the signature stays — the two shipped
# spellings genuinely differ by a space after the comma.
pat = re.compile(r"^([ \t]*)def under\(a,\s*b\):\n(.*?)(?=\n\1\S|\n[ \t]*\n)", re.M | re.S)

for src_idx, out_idx, label in ((1, 3, "sdd"), (2, 4, "turbox")):
    text = Path(sys.argv[src_idx]).read_text(encoding="utf-8")
    hits = pat.findall(text)
    if len(hits) != 1:
        raise SystemExit(
            "under() extraction for %s matched %d, expected exactly 1 (%s)"
            % (label, len(hits), sys.argv[src_idx])
        )
    indent, body = hits[0]
    lines = ["def under(a, b):"] + [line[len(indent):] for line in body.split("\n")]
    Path(sys.argv[out_idx]).write_text("import os\n" + "\n".join(lines) + "\n", encoding="utf-8")
PY

for _side in sdd tbx; do
  _body="$TMP/under_${_side}.py"
  [ -s "$_body" ] || fatal "§W0 the extracted ${_side} under() body is empty"
  _text="$(cat "$_body")"
  case "$_text" in
    *rstrip*) ;;
    *) fatal "§W0 the extracted ${_side} under() body carries no rstrip — the extraction caught the wrong region" ;;
  esac
  row "§W0 ${_side} under() body extracted from shipped bytes, non-empty, carries rstrip"
done

# ---------------------------------------------------------------------------
# §W1 — predicate-level equality over one path-pair corpus.
# §W3 — mutation anti-vacuity over the SAME corpus.
#
# Executed discrimination matrix (this is why the two backslash-stem pairs are
# mandatory rather than decorative):
#
#   | a            | b          | live  | M1    | M2    |
#   |--------------|------------|-------|-------|-------|
#   | lib/x.sh     | lib/x.sh   | True  | False | True  |
#   | lib\x.sh     | lib        | False | False | False |
#   | lib\x.sh     | lib\       | False | False | False |
#   | lib/x.sh     | lib\       | True  | True  | False |
#   | lib/x.sh     | lib\\      | True  | True  | False |
#
# With b = "lib\", live rstrip('/\\') yields stem `lib` and matches the
# forward-slash child; M2's rstrip('/') leaves stem `lib\`, and `lib\` + '/'
# matches nothing. A row whose `a` ALSO uses a backslash separator returns
# False under both, because a.startswith(stem + os.sep) is
# a.startswith(stem + '/') on POSIX.
# ---------------------------------------------------------------------------

python3 -I -B - "$TMP/under_sdd.py" "$TMP/under_tbx.py" "$TMP/w1.tsv" "$TMP/w3.tsv" <<'PY' || fatal "§W1/§W3 could not exec the extracted under() bodies"
import re
import sys
from pathlib import Path

sdd_src = Path(sys.argv[1]).read_text(encoding="utf-8")
tbx_src = Path(sys.argv[2]).read_text(encoding="utf-8")

CORPUS = [
    ("lib/x.sh", "lib/x.sh"),          # 1  the a == b arm, file form
    ("lib", "lib"),                    # 2  the a == b arm, directory form
    ("lib/x.sh", "lib"),               # 3  directory containment
    ("lib", "lib/x.sh"),               # 4  containment, reverse direction
    ("lib/x.sh", "lib/"),              # 5  trailing slash on the stem
    ("lib/", "lib/x.sh"),              # 6  reverse of 5
    ("lib/x.sh", "lib//"),             # 7  multi-slash stem, exercises rstrip
    ("lib/a.sh", "lib/ab.sh"),         # 8  shared-prefix negative control
    ("lib/ab.sh", "lib/a.sh"),         # 9  reverse of 8
    ("libx", "lib"),                   # 10 prefix-but-not-child
    ("lib", "libx"),                   # 11 reverse of 10
    ("lib/a/b.sh", "lib/a"),           # 12 nested containment
    ("lib/a", "lib/a/b.sh"),           # 13 reverse of 12
    ("lib\\x.sh", "lib"),              # 14 backslash-separator family
    ("lib\\x.sh", "lib\\"),            # 15 backslash-separator family
    ("lib/x.sh", "lib\\"),             # 16 MANDATORY — the only shape where
    ("lib/x.sh", "lib\\\\"),           # 17 MANDATORY — rstrip('/\\') and
                                       #    rstrip('/') disagree; M2 is a
                                       #    phantom without 16 and 17
    ("/abs/lib/x.sh", "/abs/lib"),     # 18 absolute containment
    ("/abs/lib", "/abs/lib/x.sh"),     # 19 reverse of 18
    ("/abs/lib/a.sh", "/abs/lib/ab.sh"),  # 20 absolute negative control
    ("docs/rfc/x.md", "docs"),         # 21 two-level containment
    ("docs", "docs/rfc/x.md"),         # 22 reverse of 21
    ("a.sh", "b.sh"),                  # 23 unrelated leaves, negative
    ("lib/x.sh", "tests/x.sh"),        # 24 same basename, different tree
]


def load(src, label):
    namespace = {}
    try:
        exec(compile(src, "<%s>" % label, "exec"), namespace)
    except SyntaxError as exc:
        raise SystemExit("the %s under() body does not compile: %s" % (label, exc))
    fn = namespace.get("under")
    if not callable(fn):
        raise SystemExit("no callable under() after exec of the %s body" % label)
    return fn


live_sdd = load(sdd_src, "sdd")
live_tbx = load(tbx_src, "turbox")

with open(sys.argv[3], "w", encoding="utf-8") as fh:
    for idx, (a, b) in enumerate(CORPUS, 1):
        fh.write("%d\t%s\t%s\t%s\t%s\n" % (idx, a, b, live_sdd(a, b), live_tbx(a, b)))

def build(label, pattern, replacement):
    """Mutate the EXTRACTED sdd body. A lost anchor is reported as a row, not
    raised: §W1's own verdict must reach the caller first, because a live
    predicate that changed shape is a §W1 finding and only then a §W3 one."""
    src, count = re.subn(pattern, replacement, sdd_src)
    if count != 1:
        return label, None, "%s anchor matched %d site(s) in the extracted body, expected 1" % (label, count)
    return label, src, ""


MUTANTS = (
    # M1 — delete the `if a == b: return True` arm.
    build("M1", r"(?m)^[ \t]*if a\s*==\s*b:.*\n", ""),
    # M2 — narrow rstrip('/\\') to rstrip('/').
    # NOT a valid mutant on POSIX: stem+os.sep -> stem+'/'. os.sep == '/' there,
    # so that mutation is a no-op and would report a phantom pass. M2 is its
    # replacement — and M2 is itself a phantom without the two mandatory
    # ("lib/x.sh", "lib\") corpus rows above.
    build("M2", r"rstrip\((['\"])/\\\\\1\)", "rstrip('/')"),
)

with open(sys.argv[4], "w", encoding="utf-8") as fh:
    for label, src, err in MUTANTS:
        if err:
            fh.write("ERROR\t0\t%s\n" % err)
            continue
        try:
            mutant = load(src, label)
        except SystemExit as exc:
            fh.write("ERROR\t0\t%s\n" % exc)
            continue
        differing = [
            str(idx) for idx, (a, b) in enumerate(CORPUS, 1) if mutant(a, b) != live_tbx(a, b)
        ]
        fh.write("%s\t%d\t%s\n" % (label, len(differing), ",".join(differing) or "-"))
PY

w1_seen=0
while IFS=$'\t' read -r w1_idx w1_a w1_b w1_sdd w1_tbx; do
  [ -n "$w1_idx" ] || continue
  [ "$w1_sdd" = "$w1_tbx" ] \
    || fail "§W1 pair $w1_idx under($w1_a, $w1_b): sdd=$w1_sdd turbox=$w1_tbx — the two shipped under() bodies disagree"
  w1_seen=$((w1_seen + 1))
  row "§W1 pair $w1_idx  under($w1_a, $w1_b) = $w1_sdd on both lanes"
done <"$TMP/w1.tsv"

[ "$w1_seen" -eq 24 ] \
  || fail "§W1 compared $w1_seen pairs but the corpus declares exactly 24 — a corpus that silently shrank proves nothing"
row "§W1 pair count is exactly 24, its declared floor"

w3_seen=0
while IFS=$'\t' read -r w3_label w3_n w3_pairs; do
  [ -n "$w3_label" ] || continue
  case "$w3_label" in
    ERROR) fatal "§W3 could not build a mutant of the extracted SDD body: $w3_pairs" ;;
  esac
  [ "$w3_n" -ge 1 ] \
    || fail "§W3 mutant $w3_label agrees with the live turbox body on all 24 pairs — the corpus is too weak to discriminate it"
  w3_seen=$((w3_seen + 1))
  row "§W3 mutant $w3_label disagrees with the live turbox body on $w3_n pair(s): $w3_pairs"
done <"$TMP/w3.tsv"

[ "$w3_seen" -eq 2 ] || fail "§W3 ran $w3_seen mutants, expected exactly 2"

# ---------------------------------------------------------------------------
# §W2 — end-to-end verdict equality across the two real dispatch chokepoints.
#
# Corpus rules, one per declared divergence, so the shared corpus stays inside
# the intersection of the two lanes' behaviour:
#   D1  every path is normpath-FIXED — asserted executably below, not by the
#       prose proxy "no . or .. segments" (`lib/` and `lib//` carry neither and
#       are still normpath-rewritten). W2 never passes --root.
#   D2  no intra-task duplicate paths.
#   D3  every row carries >= 2 tasks, all with valid ownership.
#   D4  no whitespace-only path.
#   D5  no leading or trailing whitespace on any path.
#   D6  the corpus is well-formed throughout, so only the SHARED token domain
#       {wave_paths_overlap, wave_paths_missing, -} is reachable.
# Trailing-slash and multi-separator shapes live in §W1 ONLY, where under() is
# called directly and normpath never runs — and they are mandatory there.
# ---------------------------------------------------------------------------

python3 -I -B - "$TMP/w2" <<'PY' || fatal "§W2 corpus rendering failed"
import json
import os
import sys
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

W2 = [
    ("w2-01", [["lib/a.sh"], ["lib/b.sh"]]),
    ("w2-02", [["lib/x.sh"], ["lib"]]),
    ("w2-03", [["lib"], ["lib/x.sh"]]),
    ("w2-04", [["lib/a.sh"], ["lib/ab.sh"]]),
    ("w2-05", [["libx"], ["lib"]]),
    ("w2-06", [["lib/a/b.sh"], ["lib/a"]]),
    ("w2-07", [["docs/rfc/x.md"], ["docs"]]),
    ("w2-08", [["a.sh"], ["b.sh"]]),
    ("w2-09", [["lib/x.sh"], ["tests/x.sh"]]),
    ("w2-10", [["/abs/lib/x.sh"], ["/abs/lib"]]),
    ("w2-11", [["lib/a.sh", "lib/b.sh"], ["lib/c.sh", "lib/a.sh"]]),
    ("w2-12", [["lib/a.sh"], ["lib/b.sh"], ["lib/c.sh"]]),
    ("w2-13", [["lib/a.sh"], ["lib/b.sh"], ["lib/a.sh"]]),
    ("w2-14", [["lib\\x.sh"], ["lib"]]),
]

checked = 0
for row_id, tasks in W2:
    if len(tasks) < 2:
        raise SystemExit("%s carries %d task(s); D3's corpus rule requires >= 2" % (row_id, len(tasks)))
    for paths in tasks:
        if not paths or len(set(paths)) != len(paths):
            raise SystemExit("%s breaks D2's corpus rule (empty or duplicated ownership)" % row_id)
        for p in paths:
            if p != p.strip() or not p.strip():
                raise SystemExit("%s breaks D4/D5's corpus rule on %r" % (row_id, p))
            if os.path.normpath(p) != p:
                raise SystemExit(
                    "%s breaks D1's corpus rule: normpath(%r) == %r, so turbox would "
                    "compare a different string than the SDD fence does"
                    % (row_id, p, os.path.normpath(p))
                )
            checked += 1
    (out / (row_id + ".sdd")).write_text(
        "".join(json.dumps({"allowed_paths": paths}) + "\n" for paths in tasks), encoding="utf-8"
    )
    # No `wave` key is emitted and no --wave is ever passed — rendering rule R-b.
    (out / (row_id + ".tbx")).write_text(
        json.dumps({"tasks": [{"id": i, "owns": paths} for i, paths in enumerate(tasks, 1)]}),
        encoding="utf-8",
    )

(out / "rows").write_text("".join(row_id + "\n" for row_id, _ in W2), encoding="utf-8")
(out / "normpath.count").write_text("%d\n" % checked, encoding="utf-8")
PY

w2_normpath="$(cat "$TMP/w2/normpath.count")"
[ "$w2_normpath" -ge "$W2_ROWS" ] \
  || fail "§W2 the normpath precondition checked only $w2_normpath path(s) — Decision 17's path= comparison rests on it"
row "§W2 D1 precondition: all $w2_normpath corpus paths are normpath-fixed, so path= is comparable"

w2_seen=0
w2_rc3=0
w2_rc0=0
w2_bad_token=''
while IFS= read -r w2_id; do
  [ -n "$w2_id" ] || continue
  w2_sdd="$(run_sdd_wave "$TMP/w2/$w2_id.sdd")"
  w2_tbx="$(run_tbx_wave "$ROOT" "$TMP/w2/$w2_id.tbx")"
  [ "$w2_sdd" = "$w2_tbx" ] \
    || fail "§W2 $w2_id: sdd wire [$(printf '%s' "$w2_sdd" | tr '\t' ' ')] != turbox wire [$(printf '%s' "$w2_tbx" | tr '\t' ' ')] — the two shipped chokepoints returned different verdicts"
  IFS=$'\t' read -r w2_rc w2_token w2_path <<<"$w2_sdd"
  case "$w2_token" in
    wave_paths_overlap|wave_paths_missing|-) ;;
    *) w2_bad_token="${w2_bad_token}${w2_bad_token:+ }$w2_id:$w2_token" ;;
  esac
  [ "$w2_rc" != "3" ] || w2_rc3=$((w2_rc3 + 1))
  [ "$w2_rc" != "0" ] || w2_rc0=$((w2_rc0 + 1))
  w2_seen=$((w2_seen + 1))
  row "§W2 $w2_id  both lanes: rc=$w2_rc token=$w2_token path=$w2_path"
done <"$TMP/w2/rows"

[ "$w2_seen" -eq "$W2_ROWS" ] \
  || fail "§W2 compared $w2_seen rows but W2_ROWS declares exactly $W2_ROWS"
row "§W2 row count is exactly $W2_ROWS, its declared floor"

[ -z "$w2_bad_token" ] \
  || fail "§W2 a lane-exclusive token escaped the shared domain ($w2_bad_token) — the corpus rendering broke (R-b, or a malformed row); never absorb a rendering bug as an agreement"
row "§W2 every row stayed inside the shared token domain {wave_paths_overlap, wave_paths_missing, -}"

if [ "$w2_rc3" -lt 3 ] || [ "$w2_rc0" -lt 3 ]; then
  fail "§W2 VACUOUS: observed $w2_rc3 row(s) at rc 3 and $w2_rc0 at rc 0, floor is 3 and 3 — a corpus refused wholesale, or accepted wholesale, proves nothing"
fi
row "§W2 anti-vacuity floor: $w2_rc3 row(s) refused at rc 3 and $w2_rc0 accepted at rc 0 by the live copies"

# ---------------------------------------------------------------------------
# §W2 — the six DECLARED divergences, one row each.
#
# Each is a real behavioural difference between the two shipped chokepoints,
# excluded from the shared corpus by the rule named above and locked here — so
# a divergence DISAPPEARING reds this file and forces the record to be updated
# rather than silently widening what the comparator claims.
# ---------------------------------------------------------------------------

python3 -I -B - "$TMP/dv" <<'PY' || fatal "§W2 divergence-probe rendering failed"
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

PROBES = {
    "D1": ([{"allowed_paths": ["lib/./x.sh"]}, {"allowed_paths": ["lib/x.sh"]}],
           {"tasks": [{"id": 1, "owns": ["lib/./x.sh"]}, {"id": 2, "owns": ["lib/x.sh"]}]}),
    "D2": ([{"allowed_paths": ["lib/a.sh", "lib/a.sh"]}, {"allowed_paths": ["lib/b.sh"]}],
           {"tasks": [{"id": 1, "owns": ["lib/a.sh", "lib/a.sh"]}, {"id": 2, "owns": ["lib/b.sh"]}]}),
    "D3": ([{"stage": "implement"}],
           {"tasks": [{"id": 1}]}),
    "D4": ([{"allowed_paths": ["  "]}, {"allowed_paths": ["lib/b.sh"]}],
           {"tasks": [{"id": 1, "owns": ["  "]}, {"id": 2, "owns": ["lib/b.sh"]}]}),
    "D5": ([{"allowed_paths": [" lib/x.sh"]}, {"allowed_paths": ["lib/x.sh"]}],
           {"tasks": [{"id": 1, "owns": [" lib/x.sh"]}, {"id": 2, "owns": ["lib/x.sh"]}]}),
    "D6": (["notadict", {"allowed_paths": ["lib/b.sh"]}],
           {"tasks": ["notadict", {"id": 2, "owns": ["lib/b.sh"]}]}),
}

for probe_id, (sdd_entries, tbx_tasks) in PROBES.items():
    (out / (probe_id + ".sdd")).write_text(
        "".join(json.dumps(entry) + "\n" for entry in sdd_entries), encoding="utf-8"
    )
    (out / (probe_id + ".tbx")).write_text(json.dumps(tbx_tasks), encoding="utf-8")
PY

# id | expected SDD wire | expected turbox wire | what the divergence is
DIVERGENCES='D1|0 - -|3 wave_paths_overlap lib/x.sh|path normalisation: turbox applies os.path.normpath, SDD compares as declared because sdd_canonicalize_owned_paths already ran
D2|0 - -|2 wave_paths_duplicated -|intra-task duplicate paths: turbox refuses the task, SDD only compares ACROSS tasks
D3|2 wave_paths_missing -|0 - -|ownership-validation ORDER: turbox short-circuits waves of < 2 tasks BEFORE the ownership loop, SDD validates every entry first
D4|0 - -|2 wave_paths_missing -|whitespace-only paths: turbox rejects on not p.strip(), SDD only on not p
D5|0 - -|3 wave_paths_overlap lib/x.sh|whitespace PADDING on an otherwise-valid path: turbox strips before comparing, SDD does not
D6|2 wave_paths_missing -|2 wave_task_malformed -|malformed-input token domains are disjoint: neither lane can emit the other lane exclusive tokens'

dv_seen=0
while IFS='|' read -r dv_id dv_exp_sdd dv_exp_tbx dv_why; do
  [ -n "$dv_id" ] || continue
  dv_sdd="$(run_sdd_wave "$TMP/dv/$dv_id.sdd")"
  dv_tbx="$(run_tbx_wave "$ROOT" "$TMP/dv/$dv_id.tbx")"
  IFS=' ' read -r dv_a dv_b dv_c <<<"$dv_exp_sdd"
  dv_want_sdd="$(printf '%s\t%s\t%s' "$dv_a" "$dv_b" "$dv_c")"
  IFS=' ' read -r dv_a dv_b dv_c <<<"$dv_exp_tbx"
  dv_want_tbx="$(printf '%s\t%s\t%s' "$dv_a" "$dv_b" "$dv_c")"
  [ "$dv_sdd" != "$dv_tbx" ] \
    || fail "§W2 divergence $dv_id STOPPED DIVERGING — both lanes now return [$(printf '%s' "$dv_sdd" | tr '\t' ' ')]. Update the divergence record and the corpus rule; do not widen the shared corpus silently. ($dv_why)"
  [ "$dv_sdd" = "$dv_want_sdd" ] \
    || fail "§W2 divergence $dv_id: SDD returned [$(printf '%s' "$dv_sdd" | tr '\t' ' ')], the record declares [$dv_exp_sdd] ($dv_why)"
  [ "$dv_tbx" = "$dv_want_tbx" ] \
    || fail "§W2 divergence $dv_id: turbox returned [$(printf '%s' "$dv_tbx" | tr '\t' ' ')], the record declares [$dv_exp_tbx] ($dv_why)"
  dv_seen=$((dv_seen + 1))
  row "§W2 divergence $dv_id still diverges: sdd [$dv_exp_sdd] vs turbox [$dv_exp_tbx]"
done <<EOF_DIVERGENCES
$DIVERGENCES
EOF_DIVERGENCES

[ "$dv_seen" -eq 6 ] || fail "§W2 locked $dv_seen divergences, the record declares exactly 6"

# ---------------------------------------------------------------------------
# §C — the cap comparator, factored over a ROOT PATH so §C6 can re-run the
# whole of C1-C5 against a scratch copy tree with one surface drifted.
#
# Every register key below is ROOT-RELATIVE. An absolute key would make every
# scratch hit read as unregistered, and §C6 would "disagree" for the wrong
# reason while still satisfying a bare disagreement check.
# ---------------------------------------------------------------------------

cat >"$TMP/cap-report.py" <<'PY'
"""Register-driven cap comparison over one root. Prints a tab-separated report.

Argv: <root> <owner fix_rounds> <owner retest_rounds> <owner context_rounds>
      <filtered sweep-hits file>

Every entry is keyed by an extraction regex and a ROOT-RELATIVE path — never a
line number, which rots the moment a sibling PR edits the file above it.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
OWNER = {"fix_rounds": sys.argv[2], "retest_rounds": sys.argv[3], "context_rounds": sys.argv[4]}
sweep_path = Path(sys.argv[5])

SDD = "plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
TBX_LIB = "plugins/uberdev/lib/turbox-fleet.sh"
TBX_SKILL = "plugins/uberdev/skills/turbox-fleet/SKILL.md"
FLEET_JS = "plugins/uberdev/skills/solve-fleet/workflow.js"
FLEET_SKILL = "plugins/uberdev/skills/solve-fleet/SKILL.md"
RFC20 = "docs/rfc/0020-turbox-standard-mode-fleet.md"
RFC12 = "docs/rfc/0012-ultracode-workflow-orchestration.md"

# (cap_name, regex, expected_match_count, which_occurrence)
# `cap_name` None means the site is FROZEN: presence is asserted, the value is
# deliberately not bound to the owner.
# `cap_name` "" means the pattern exists only to disposition a sweep line —
# the site's VALUE is read by EXECUTING it (sites 1 and 2), never by regex, so
# those two sites are declared with kind "executed" and their SITE row is
# emitted by the caller that ran them, not here.
REGISTER = [
    # --- executable: a running program reads the number ----------------------
    (1, "executed", SDD, [
        ("", r"^[ \t]*fix_rounds\) printf '%s' [0-9]+ ;;", 1, 0),
        ("", r"^[ \t]*retest_rounds\) printf '%s' [0-9]+ ;;", 1, 0),
        ("", r"^[ \t]*context_rounds\) printf '%s' [0-9]+ ;;", 1, 0),
    ]),
    (2, "executed", TBX_LIB, [
        ("", r"^TURBOX_FIX_ROUNDS=[0-9]+$", 1, 0),
        ("", r"^TURBOX_RETEST_ROUNDS=[0-9]+$", 1, 0),
        ("", r"^TURBOX_CONTEXT_ROUNDS=[0-9]+$", 1, 0),
    ]),
    (3, "executable", FLEET_JS, [
        ("fix_rounds", r"const FIX_ROUNDS = ([0-9]+);", 1, 0),
    ]),
    # --- bound prose: documentation quoting the numbers -----------------------
    (4, "prose", SDD, [
        ("fix_rounds", r"\*\*`fix_rounds` = ([0-9]+)\*\*", 1, 0),
        ("retest_rounds", r"\*\*`retest_rounds` = ([0-9]+)\*\*", 1, 0),
        ("context_rounds", r"\*\*`context_rounds` = ([0-9]+)\*\*", 1, 0),
    ]),
    (5, "prose", SDD, [("retest_rounds", r"capped at `retest_rounds` \(([0-9]+)\)", 1, 0)]),
    (6, "prose", SDD, [("fix_rounds", r"capped at `fix_rounds` \(([0-9]+)\) iterations per task", 1, 0)]),
    (7, "prose", SDD, [("fix_rounds", r"Same `fix_rounds` \(([0-9]+)\) cap per task", 1, 0)]),
    (8, "prose", SDD, [("context_rounds", r"at most `context_rounds` \(([0-9]+)\) answer-and-re-dispatch cycles", 1, 0)]),
    # Sites 9 and 10 are byte-identical text on two lines. One regex, TWO
    # declared occurrences, one site per occurrence — asserted separately so the
    # extraction cannot collapse them into a single check.
    (9, "prose", SDD, [("fix_rounds", r"max fix_rounds=([0-9]+) per task", 2, 0)]),
    (10, "prose", SDD, [("fix_rounds", r"max fix_rounds=([0-9]+) per task", 2, 1)]),
    (11, "prose", SDD, [("fix_rounds", r"the task's `fix_rounds` cap \(([0-9]+)\)", 1, 0)]),
    (12, "prose", TBX_SKILL, [
        ("fix_rounds", r"\(`fix_rounds` ([0-9]+), `retest_rounds` [0-9]+, `context_rounds` [0-9]+\)", 1, 0),
        ("retest_rounds", r"\(`fix_rounds` [0-9]+, `retest_rounds` ([0-9]+), `context_rounds` [0-9]+\)", 1, 0),
        ("context_rounds", r"\(`fix_rounds` [0-9]+, `retest_rounds` [0-9]+, `context_rounds` ([0-9]+)\)", 1, 0),
    ]),
    (13, "prose", RFC20, [
        ("fix_rounds", r"`fix_rounds` = ([0-9]+) per task per review stage", 1, 0),
        ("retest_rounds", r"`retest_rounds` = ([0-9]+) per wave", 1, 0),
        ("context_rounds", r"`context_rounds` = ([0-9]+) per task", 1, 0),
    ]),
    # Site 14 lives mid-way through a very long routing-table row that also
    # carries `3-lens` and a bare `4`. The backticks and the ` = ` are what make
    # the anchor unambiguous, and it is position-independent within the line and
    # within the file — that file is READ-ONLY here and a sibling PR is editing
    # it, so no positional dependence is allowed.
    (14, "prose", FLEET_SKILL, [("fix_rounds", r"`FIX_ROUNDS` = ([0-9]+)", 1, 0)]),
    # --- frozen: historical record, deliberately NOT bound --------------------
    (15, "frozen", RFC12, [(None, r"\(`fix_rounds` = [0-9]+\) come from `sdd_loop_cap`", 1, 0)]),
    (16, "frozen", RFC12, [
        (None, r"caps:\{fix_rounds:[0-9]+, retest_rounds:[0-9]+, context_rounds:[0-9]+\}", 1, 0),
    ]),
]

# The reasoned ignore-list. The sweep predicate needs a cap NAME and a DIGIT on
# the same line, so a name-only mention never trips it. Exactly nine lines do.
# Every key is (root-relative path, value-agnostic regex) — value-agnostic so a
# §C6 scratch mutation cannot turn a registered line into an unregistered one
# and make the mutant "disagree" for the wrong reason.
IGNORED = [
    # the digit is a sys.argv slice index
    ("plugins/uberdev/lib/solve-launcher.sh", r"fix_rounds\) = sys\.argv\["),
    # the digit is the ${UBERDEV_TURBOX_MAX_AGENTS:-600} default; the loop-cap
    # call on the same line is the DERIVATION call, not a declaration
    ("plugins/uberdev/lib/solve-launcher.sh", r"UBERDEV_TURBOX_MAX_AGENTS:-[0-9]+"),
    # _tbx_die exit code in the unknown-loop arm
    (TBX_LIB, r'_tbx_die "loop-cap: unknown loop'),
    # _tbx_die exit code in the usage arm
    (TBX_LIB, r"usage: \$TURBOX_SELF loop-cap"),
    # agent-budget arithmetic DERIVED from the cap, not a restatement of it.
    # A 3->4 drift makes this comment wrong; fix the comment, do not delete the
    # row.
    (FLEET_JS, r"Worst case per task is [0-9]+ implementer"),
    (FLEET_JS, r"reviewers = [0-9]+ agents"),
    # an rc that coincidentally equals the fix_rounds value; not a cap value
    (TBX_SKILL, r"cap exhausted: audit"),
    # rc 0 / rc 3 from sdd_round_permitted plus "rounds 1..N" — return codes
    (SDD, r"rounds 1\.\.N instead of re-deriving"),
    # a rule id and a line-range citation, on a line naming all three caps with
    # no value
    (RFC12, r"Unconditional do-first, retained permanently"),
]

# Deliberately excluded, and STRUCTURALLY unreachable by the sweep predicate:
# TURBOX_ISSUE_CAP and the `issue_cap` argument of _tbx_loop_cap. Neither token
# contains fix_rounds, retest_rounds or context_rounds, so the Decision-8
# exclusion cannot rot into an accidental inclusion.

out = []
frozen_sites = 0

for site_id, kind, rel, checks in REGISTER:
    text = (root / rel).read_text(encoding="utf-8")
    detail = []
    verdict = "frozen" if kind == "frozen" else "ok"
    for cap, pattern, want, index in checks:
        found = re.findall(pattern, text, re.M)
        if len(found) != want:
            out.append("MISSING\t%d\t%s\t%s\t%d\t%d" % (site_id, rel, pattern, len(found), want))
            verdict = "missing"
            continue
        if cap in (None, ""):
            detail.append("present")
            continue
        value = found[index] if isinstance(found[index], str) else found[index][0]
        detail.append("%s=%s" % (cap, value))
        if value != OWNER[cap]:
            out.append("DRIFT\t%s\t%s\t%s\t%s\t%d" % (rel, cap, value, OWNER[cap], site_id))
            verdict = "drift"
    if kind == "frozen":
        frozen_sites += 1
    if kind == "executed":
        # Sites 1 and 2 are bound by EXECUTION, and their SITE row is emitted by
        # the caller that executed them. Their patterns live here only so §C5 can
        # disposition their sweep lines and so a moved declaration reds MISSING.
        continue
    out.append("SITE\t%d\t%s\t%s\t%s\t%s" % (site_id, kind, rel, " ".join(detail) or "-", verdict))

out.append("FROZEN\t%d" % frozen_sites)

# --- C5: every sweep hit must be dispositioned exactly once -------------------
register_patterns = {}
for site_id, kind, rel, checks in REGISTER:
    for _cap, pattern, _want, _index in checks:
        register_patterns.setdefault(rel, []).append((site_id, re.compile(pattern)))

ignore_patterns = {}
for rel, pattern in IGNORED:
    ignore_patterns.setdefault(rel, []).append(re.compile(pattern))

total = registered = ignored = 0
for raw in sweep_path.read_text(encoding="utf-8").splitlines():
    if not raw.strip():
        continue
    head, _, text = raw.partition(":")
    lineno, _, text = text.partition(":")
    total += 1
    is_reg = any(rx.search(text) for _sid, rx in register_patterns.get(head, ()))
    is_ign = any(rx.search(text) for rx in ignore_patterns.get(head, ()))
    if is_reg and is_ign:
        out.append("DOUBLE\t%s:%s\t%s" % (head, lineno, text))
    elif is_reg:
        registered += 1
    elif is_ign:
        ignored += 1
    else:
        out.append("UNREG\t%s:%s\t%s" % (head, lineno, text))

out.append("SWEEP\t%d\t%d\t%d" % (total, registered, ignored))
print("\n".join(out))
PY

cap_compare() {   # <root> <workdir> ; prints the report on stdout
  local croot="$1" cwork="$2"
  local ofix oret octx tfix tret tctx v2=ok v
  mkdir -p "$cwork"
  extract_fence "$croot/$SDD_SKILL_REL" "$cwork/runtime.sh" \
    || fatal "§C1 could not extract the SDD runtime fence from $croot/$SDD_SKILL_REL"
  ofix="$(bash "$TMP/sdd-cap.sh" "$cwork/runtime.sh" fix_rounds)" \
    || fatal "§C1 sdd_loop_cap fix_rounds refused in $croot — never default a cap"
  oret="$(bash "$TMP/sdd-cap.sh" "$cwork/runtime.sh" retest_rounds)" \
    || fatal "§C1 sdd_loop_cap retest_rounds refused in $croot — never default a cap"
  octx="$(bash "$TMP/sdd-cap.sh" "$cwork/runtime.sh" context_rounds)" \
    || fatal "§C1 sdd_loop_cap context_rounds refused in $croot — never default a cap"
  for v in "$ofix" "$oret" "$octx"; do
    case "$v" in
      ''|*[!0-9]*) fatal "§C1 the owner returned a non-numeric cap value '$v' — never default a cap" ;;
    esac
  done
  printf 'SITE\t1\texecutable\t%s\towner fix=%s retest=%s context=%s\tok\n' \
    "$SDD_SKILL_REL" "$ofix" "$oret" "$octx"

  # C2 — the turbox copy, read by EXECUTING its real CLI.
  # _tbx_loop_cap also accepts issue_cap. It is the parallel-ISSUE ceiling
  # (RFC 0020 §3.3), a different contract with no SDD counterpart, and is
  # deliberately NOT compared here.
  tfix="$(bash "$croot/$TBX_LIB_REL" loop-cap fix_rounds)" || fatal "§C2 turbox loop-cap fix_rounds refused in $croot"
  tret="$(bash "$croot/$TBX_LIB_REL" loop-cap retest_rounds)" || fatal "§C2 turbox loop-cap retest_rounds refused in $croot"
  tctx="$(bash "$croot/$TBX_LIB_REL" loop-cap context_rounds)" || fatal "§C2 turbox loop-cap context_rounds refused in $croot"
  [ "$tfix" = "$ofix" ] || { printf 'DRIFT\t%s\tfix_rounds\t%s\t%s\t2\n' "$TBX_LIB_REL" "$tfix" "$ofix"; v2=drift; }
  [ "$tret" = "$oret" ] || { printf 'DRIFT\t%s\tretest_rounds\t%s\t%s\t2\n' "$TBX_LIB_REL" "$tret" "$oret"; v2=drift; }
  [ "$tctx" = "$octx" ] || { printf 'DRIFT\t%s\tcontext_rounds\t%s\t%s\t2\n' "$TBX_LIB_REL" "$tctx" "$octx"; v2=drift; }
  printf 'SITE\t2\texecutable\t%s\tfix=%s retest=%s context=%s\t%s\n' \
    "$TBX_LIB_REL" "$tfix" "$tret" "$tctx" "$v2"

  sweep_hits "$croot" >"$cwork/sweep.txt"
  python3 -I -B "$TMP/cap-report.py" "$croot" "$ofix" "$oret" "$octx" "$cwork/sweep.txt" \
    || fatal "§C the register-driven comparison could not run against $croot"
}

# Report parsing goes through awk with a REAL tab as the field separator, not a
# sed address carrying a `\t` escape: that escape is an extension rather than a
# POSIX guarantee, and a sed that stopped honouring it would make every
# emptiness check below pass vacuously — the exact failure mode this file exists
# to refuse.
report_rows() {    # <tag> <report text> -> the row remainder, one indented line each
  awk -F$'\t' -v want="$1" '
    $1 == want { out = $2; for (i = 3; i <= NF; i++) out = out " " $i; print "  " out }
  ' <<<"$2"
}

report_field() {   # <tag> <1-based field index> <report text>
  awk -F$'\t' -v want="$1" -v idx="$2" '$1 == want { print $idx }' <<<"$3"
}

REPORT="$(cap_compare "$ROOT" "$TMP/real")" || fatal "§C the cap comparison could not run against the real tree"

c_missing="$(report_rows MISSING "$REPORT")"
[ -z "$c_missing" ] \
  || fail "§C a register extraction no longer matches its declared occurrence count — the register rotted, re-key it on the live text:
$c_missing"

c_drift="$(report_rows DRIFT "$REPORT")"
[ -z "$c_drift" ] \
  || fail "§C cap values have DRIFTED from the owner (sdd_loop_cap in $SDD_SKILL_REL):
$c_drift"

c_sites=0
while IFS=$'\t' read -r c_kind c_id c_class c_path c_detail c_verdict; do
  [ "$c_kind" = "SITE" ] || continue
  case "$c_verdict" in
    ok|frozen) ;;
    *) fail "§C site $c_id ($c_path) verdict=$c_verdict — $c_detail" ;;
  esac
  c_sites=$((c_sites + 1))
  row "§C site $c_id [$c_class] $c_path — $c_detail ($c_verdict)"
done <<<"$REPORT"

[ "$c_sites" -eq 16 ] \
  || fail "§C the register bound $c_sites site(s), it declares exactly 16 (3 executable + 11 bound prose + 2 frozen)"

c_frozen="$(report_field FROZEN 2 "$REPORT")"
[ "$c_frozen" = "2" ] \
  || fail "§C the frozen list holds ${c_frozen:-<none>} entr(ies), it must hold exactly 2 — it cannot be quietly extended to dodge binding a live site"
row "§C the frozen list holds exactly 2 entries and cannot absorb a live site"

# --- §C5 — the completeness sweep -------------------------------------------
c_unreg="$(report_rows UNREG "$REPORT")"
[ -z "$c_unreg" ] \
  || fail "§C5 sweep hit(s) that are neither registered, frozen nor on the reasoned ignore-list — a new cap restatement reds on the commit that adds it:
$c_unreg"

c_double="$(report_rows DOUBLE "$REPORT")"
[ -z "$c_double" ] \
  || fail "§C5 sweep hit(s) claimed by BOTH the register and the ignore-list — a line must be dispositioned exactly once:
$c_double"

c5_total="$(report_field SWEEP 2 "$REPORT")"
c5_registered="$(report_field SWEEP 3 "$REPORT")"
c5_ignored="$(report_field SWEEP 4 "$REPORT")"
for _v in "$c5_total" "$c5_registered" "$c5_ignored"; do
  case "$_v" in
    ''|*[!0-9]*) fatal "§C5 the sweep tally is unreadable (total='$c5_total' registered='$c5_registered' ignored='$c5_ignored') — an unparsed tally must never read as a clean sweep" ;;
  esac
done

[ "${c5_total:-0}" -eq 31 ] \
  || fail "§C5 VACUOUS or drifted: the sweep harvested ${c5_total:-0} hit line(s), the register dispositions exactly 31"
row "§C5 the sweep harvested exactly 31 cap-name-plus-digit lines"

[ "$c5_registered" -eq 22 ] \
  || fail "§C5 $c5_registered hit line(s) were dispositioned by a register site, the register declares 22"
row "§C5 22 hit lines dispositioned by a register site"

[ "$c5_ignored" -eq 9 ] \
  || fail "§C5 $c5_ignored hit line(s) were dispositioned by the ignore-list, it declares 9"
row "§C5 9 hit lines dispositioned by the reasoned ignore-list"

[ "$((c5_registered + c5_ignored))" -eq "$c5_total" ] \
  || fail "§C5 partition broken: $c5_registered + $c5_ignored != $c5_total"
row "§C5 the partition closes: 22 + 9 == 31, every hit dispositioned exactly once"

# ---------------------------------------------------------------------------
# §C6 — mutation anti-vacuity over scratch copy trees.
#
# The real worktree is NEVER mutated. Scratch trees are shell `mktemp -d`
# (python tempfile.TemporaryDirectory is banned by testing.md convention 7,
# enforced by tests/test-harness-source-guards.test.sh A4), and no narrow PATH
# is ever prepended (testing.md 10 / A6).
# ---------------------------------------------------------------------------

row "§C6 baseline: the whole C1-C5 comparison agrees against the real tree, 0 drift lines"

mutate_file() {   # <file> <anchor> <replacement>
  python3 -I -B - "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor, replacement = sys.argv[2], sys.argv[3]
if text.count(anchor) != 1:
    raise SystemExit("mutation anchor %r occurs %d time(s), expected exactly 1" % (anchor, text.count(anchor)))
path.write_text(text.replace(anchor, replacement), encoding="utf-8")
PY
}

make_scratch() {   # <dest>
  mkdir -p "$1/plugins" "$1/docs"
  cp -R "$ROOT/plugins/uberdev" "$1/plugins/uberdev"
  cp -R "$ROOT/docs/rfc" "$1/docs/rfc"
}

c6_probe() {   # <label> <relpath> <anchor> <replacement>
  local label="$1" rel="$2" anchor="$3" replacement="$4"
  local scratch report drift_paths drift_detail
  scratch="$(mktemp -d "$TMP/c6-XXXXXX")"
  make_scratch "$scratch"
  mutate_file "$scratch/$rel" "$anchor" "$replacement" \
    || fatal "§C6 could not drift $rel in the scratch tree"
  report="$(cap_compare "$scratch" "$scratch/.work")" \
    || fatal "§C6 the comparison could not run against the $label scratch tree"
  drift_paths="$(report_field DRIFT 2 "$report")"
  drift_detail="$(report_rows DRIFT "$report")"
  [ -n "$drift_paths" ] \
    || fail "§C6 $label: drifting $rel produced NO disagreement — the comparator is vacuous for that surface"
  # Padded haystack, so a path that is a prefix of another cannot match by
  # accident and a multi-line drift list is searched whole.
  case "
$drift_paths
" in
    *"
$rel
"*) ;;
    *) fail "§C6 $label: the disagreement does not NAME the drifted surface $rel — it reported:
$drift_detail" ;;
  esac
  rm -rf "$scratch"
  row "§C6 $label mutant: drifting $rel is caught and the failure names that surface"
}

c6_probe "executable" "$TBX_LIB_REL" 'TURBOX_FIX_ROUNDS=3' 'TURBOX_FIX_ROUNDS=4'
c6_probe "prose" 'plugins/uberdev/skills/turbox-fleet/SKILL.md' '(`fix_rounds` 3,' '(`fix_rounds` 4,'

# ---------------------------------------------------------------------------
# Executed-row floor. The floor reads $ROWS, not $EXPECTED_ROWS: comparing two
# authoring-time constants is a check that can never fire, which is the very
# vacuity class this file exists to close.
#
# Derived from the row counts each section declares, so neither a hand-typed
# EXPECTED_ROWS nor a silently-dropped block can clear it:
#     2 W0 extraction
#  + 24 W1 pairs + 1 W1 pair-count floor
#  +  1 W2 normpath precondition + W2_ROWS W2 rows
#  +  3 W2 floors (row count, token domain, rc-3/rc-0 vacuity)
#  +  6 W2 divergence locks
#  +  2 W3 mutants
#  + 17 C1-C4 (16 register sites + the frozen count floor)
#  +  4 C5 sweep
#  +  3 C6 (baseline + 2 mutants)
# Change any section's row count and change its term here in the same commit.
# ---------------------------------------------------------------------------
REGISTER_FLOOR=$(( 2 + 24 + 1 + 1 + W2_ROWS + 3 + 6 + 2 + 17 + 4 + 3 ))
[ "$ROWS" -ge "$REGISTER_FLOOR" ] \
  || fatal "executed $ROWS rows, below the structural floor $REGISTER_FLOOR — a block of assertions did not run"
[ "$ROWS" -eq "$EXPECTED_ROWS" ] \
  || fail "executed $ROWS rows but EXPECTED_ROWS=$EXPECTED_ROWS — this file asserted less than it claims"

echo
echo "== Summary =="
echo "  rows executed: $ROWS (expected $EXPECTED_ROWS, structural floor $REGISTER_FLOOR)"
echo "  failed: 0"

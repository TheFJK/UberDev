#!/usr/bin/env bash
# tests/vendor-provenance.test.sh — the VENDORED-PROVENANCE RATCHET (#434).
#
# THE CLASS. UberDev vendors 20 third-party components (14 superpowers-derived
# skill directories + 6 reviewer/simplifier agents). Their provenance used to be
# spelled three incompatible ways — in-file `Vendored from …@<sha>` headers on 20
# files across 3 directories, a README table that named upstreams but no commits
# and had drifted, and three licence texts with no versions. Nothing compared any
# spelling to any other, or to disk. The result was undeclared drift: upstream
# v6.2.0 fixed `find-polluter.sh` and UberDev shipped the broken copy for months
# (#430).
#
# `plugins/uberdev/vendor.json` is now the single register, and
# `tools/vendor/vendor-check.py` is its offline guard. This suite proves the
# guard is FALSIFIABLE: every mutation row copies the shipped tree into a
# throwaway directory, breaks exactly one invariant, and asserts the checker goes
# red AND names the specific check id it went red for. "Red for the wrong reason"
# does not count as coverage.
#
# ANTI-VACUITY (the trap this suite was designed around). A *missing* checker
# also exits non-zero, so every mutation row would pass vacuously before the
# checker existed — precisely the string-presence class #434 exists to kill. The
# preflight below therefore ABORTs unless the checker exists AND is green on the
# pristine tree. A red pristine tree makes the whole suite meaningless, so it is
# a hard stop rather than a failed row.
#
# The suite NEVER calls `vendor-check.py --refresh`. The producer must never be
# its own oracle (the P1–P4 discipline of tests/prkit-publish.test.sh).
#
# Unix-only, declared in the test.yml windows-skip marker block: C-FILES digests
# sha256 over exact source bytes and no `.gitattributes` rule covers the vendored
# component paths — the repo's only rule (#461) is scoped to
# `plugins/uberdev/hooks/**` — so a Windows checkout with the default
# `core.autocrlf=true` rewrites LF->CRLF and every digest would differ. That is a
# property of the checkout, not of the register — same reason as
# tests/prkit-publish.test.sh.
#
# Deliberately does NOT source tests/_lib_assert_structural.sh (so
# tests/test-harness-source-guards.test.sh needs no fail-loud guard here), and
# uses herestrings rather than `printf | grep -q` so tests/epipe-guard.test.sh
# stays green over this file.
set -u
set -o pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTER="$REPO_ROOT/plugins/uberdev/vendor.json"
CHECK="$REPO_ROOT/tools/vendor/vendor-check.py"
README="$REPO_ROOT/README.md"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "## vendored-provenance ratchet (#434)"

command -v python3 >/dev/null 2>&1 || { echo "  ABORT — python3 required"; exit 99; }
[ -r "$REGISTER" ] || { echo "FATAL: vendor.json missing: $REGISTER" >&2; exit 2; }
[ -r "$CHECK" ]    || { echo "FATAL: vendor-check.py missing: $CHECK" >&2; exit 2; }
[ -r "$README" ]   || { echo "FATAL: README.md missing: $README" >&2; exit 2; }
if ! python3 "$CHECK" --repo-root "$REPO_ROOT" >/dev/null 2>&1; then
  echo "FATAL: vendor-check.py is not green on the pristine tree; every mutation" >&2
  echo "       row below would pass vacuously. Run it directly and fix the tree." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Mutation harness. Copies ONLY the two surfaces the checker reads into a
# throwaway root, so a mutation can never touch the working tree.
# ---------------------------------------------------------------------------
# ONE parent temp dir, removed wholesale on exit. `make_sandbox` is called from
# a command substitution, so anything it assigns dies with that subshell — an
# accumulating SANDBOXES list would silently leak a full plugin-tree copy per
# mutation row (measured: 27 leaked directories before this shape).
SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vendor-prov.XXXXXX")" || {
  echo "  ABORT — cannot create a sandbox root"; exit 99; }
cleanup() {
  case "$SANDBOX_ROOT" in
    /*/vendor-prov.*) rm -rf "$SANDBOX_ROOT" ;;
  esac
}
trap cleanup EXIT

make_sandbox() {
  local d
  d="$(mktemp -d "$SANDBOX_ROOT/sb.XXXXXX")" || return 1
  mkdir -p "$d/plugins"
  cp -R "$REPO_ROOT/plugins/uberdev" "$d/plugins/uberdev" || return 1
  cp "$README" "$d/README.md" || return 1
  printf '%s\n' "$d"
}

# run_check <root> -> writes combined output to $CHECK_OUT, returns checker rc.
CHECK_OUT=""
run_check() {
  CHECK_OUT="$(python3 "$CHECK" --repo-root "$1" 2>&1)"
}

# assert_red <sandbox> <expected-check-id> <description>
assert_red() {
  local root="$1" want="$2" desc="$3" rc=0
  run_check "$root" || rc=$?
  if [ "$rc" -eq 0 ]; then
    no "$desc — checker stayed GREEN on a mutated tree"
    return
  fi
  if grep -q -- "$want" <<<"$CHECK_OUT"; then
    ok "$desc (red, named $want)"
  else
    no "$desc — checker went red but never named $want"
    echo "        output: $(head -c 400 <<<"$CHECK_OUT")"
  fi
}

echo
echo "== V1-V9: the committed register, driven directly (never --refresh) =="

# V1 — register shape asserted in Python, NOT through the checker, so a checker
# that mis-parses the file cannot make this row lie.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["schema"] == "uberdev-vendor-v1", "wrong schema literal: %r" % d.get("schema")
ids = [c["id"] for c in d["components"]]
assert len(ids) == len(set(ids)), "duplicate component ids"
assert len(ids) > 0, "register declares no components"
paths = [c["path"] for c in d["components"]]
assert len(paths) == len(set(paths)), "duplicate component paths"
PY
then ok "V1 vendor.json parses, declares uberdev-vendor-v1, ids and paths unique"
else no "V1 vendor.json failed direct structural validation"
fi

# V2 — the checker is green on the real tree (already proven by the preflight;
# recorded as a row so the suite's summary states it).
if python3 "$CHECK" --repo-root "$REPO_ROOT" >/dev/null 2>&1; then
  ok "V2 vendor-check.py exits 0 on the shipped tree"
else
  no "V2 vendor-check.py is red on the shipped tree"
fi

# V3 — C-COVER, asserted directly and two-way. Both on-disk sets must be
# non-empty FIRST: a misrooted scan that finds nothing would otherwise make the
# equality trivially true.
if python3 - "$REGISTER" "$REPO_ROOT" <<'PY'
import json, os, sys
reg, root = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
plugin = os.path.join(root, "plugins", "uberdev")
skills = {"skills/%s" % n for n in os.listdir(os.path.join(plugin, "skills"))
          if os.path.isdir(os.path.join(plugin, "skills", n))}
agents = {"agents/%s" % n for n in os.listdir(os.path.join(plugin, "agents"))
          if os.path.isfile(os.path.join(plugin, "agents", n))}
assert len(skills) > 0, "no skill directories found — scan is misrooted"
assert len(agents) > 0, "no agent files found — scan is misrooted"
declared = {c["path"] for c in d["components"]}
disk = skills | agents
assert disk == declared, "coverage mismatch: on-disk-only=%s declared-only=%s" % (
    sorted(disk - declared), sorted(declared - disk))
PY
then ok "V3 C-COVER: on-disk skill dirs + agent files == declared component paths, both ways"
else no "V3 C-COVER coverage is not two-way complete"
fi

# V4 — C-STANCE: every third-party component decided, no UberDev original
# carrying a stance, no "undecided" anywhere.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
third = [c for c in d["components"] if c.get("origin") == "third-party"]
assert third, "no third-party components declared"
for c in third:
    assert c.get("stance") in ("track", "fork"), "%s stance=%r" % (c["id"], c.get("stance"))
    assert c.get("stance_reason", "").strip(), "%s has an empty stance_reason" % c["id"]
for c in d["components"]:
    if c.get("origin") == "uberdev":
        assert "stance" not in c, "%s is an UberDev original but carries a stance" % c["id"]
assert not any(c.get("stance") == "undecided" for c in d["components"])
stances = {c["stance"] for c in third}
assert "track" in stances and "fork" in stances, \
    "the register collapsed to a single stance — V13/V14 would be vacuous"
PY
then ok "V4 C-STANCE: every third-party stance decided with a reason; both stances in use"
else no "V4 C-STANCE is incomplete or collapsed to one stance"
fi

# V5 — C-HEADER: the count of header-carrying files is knowable TODAY, so it is
# asserted exactly. A `>= 1` bound decays into a tautology as files are added.
HEADER_COUNT="$(grep -rlE 'Vendored from [^@[:space:]]+@[0-9a-f]{40}' "$REPO_ROOT/plugins/uberdev" | wc -l | tr -d '[:space:]')"
if [ "$HEADER_COUNT" = "38" ]; then
  ok "V5 C-HEADER: exactly 38 files carry an in-file provenance header"
else
  no "V5 C-HEADER: expected 38 header-carrying files, found $HEADER_COUNT"
fi
if python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-HEADER >/dev/null 2>&1; then
  ok "V5b C-HEADER: every on-disk header agrees with its component's register entry"
else
  no "V5b C-HEADER: an on-disk header disagrees with the register"
fi

# V6 — C-README: symmetric difference of README third-party slugs and register
# third-party slugs is empty, and the using-uberdev correction is in place.
if python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-README >/dev/null 2>&1; then
  ok "V6 C-README: README Bundled table and register agree, both ways"
else
  no "V6 C-README: README Bundled table and register disagree"
fi
SUPERPOWERS_ROW="$(grep -n 'superpowers' "$README" || true)"
if grep -q 'using-uberdev' <<<"$SUPERPOWERS_ROW"; then
  ok "V6b using-uberdev is attributed to the superpowers row, not to UberDev originals"
else
  no "V6b using-uberdev is still mis-attributed in the README Bundled table"
fi

# V7 — C-LICENSE, two-way against plugins/uberdev/licenses/.
if python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-LICENSE >/dev/null 2>&1; then
  ok "V7 C-LICENSE: every declared licence file exists and every shipped one is referenced"
else
  no "V7 C-LICENSE: licence reconciliation is not two-way"
fi

# V8 — C-WATERMARK: a 40-hex watermark and an ISO review date on every
# third-party component. Without these the weekly drift job has no `from`.
if python3 - "$REGISTER" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
hex40 = re.compile(r"^[0-9a-f]{40}$")
iso = re.compile(r"^\d{4}-\d{2}-\d{2}$")
for c in d["components"]:
    if c.get("origin") != "third-party":
        continue
    assert hex40.match(c["last_reviewed_upstream_commit"] or ""), \
        "%s watermark is not 40-hex" % c["id"]
    assert iso.match(c["last_reviewed_on"] or ""), "%s last_reviewed_on is not ISO" % c["id"]
    v = c["vendored_at_commit"]
    assert v == "unknown" or hex40.match(v), "%s vendored_at_commit is neither 40-hex nor 'unknown'" % c["id"]
PY
then ok "V8 C-WATERMARK: 40-hex watermark + ISO review date on every third-party component"
else no "V8 C-WATERMARK: a third-party component has no usable diff watermark"
fi

# V9 — the five never-reconcile divergences are declared as permanent.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
want = {
    "namespace-rebrand",
    "parallel-hypothesis-testing",
    "brainstorm-no-approval-gates",
    "review-pr-parallel-by-default",
    "no-co-authored-by",
}
perm = {p["id"] for p in d["permanent_divergences"] if p.get("permanent") is True}
missing = want - perm
assert not missing, "permanent divergences missing: %s" % sorted(missing)
for p in d["permanent_divergences"]:
    assert p.get("note", "").strip(), "%s has an empty note" % p["id"]
    assert p.get("scope", "").strip(), "%s has an empty scope" % p["id"]
PY
then ok "V9 the five never-reconcile divergences are declared with permanent: true"
else no "V9 a never-reconcile divergence is missing or undocumented"
fi

echo
echo "== V10-V32: falsifiability — mutate one site, demand the NAMED check id =="

# V10 — an undeclared new file inside a declared component.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
: > "$SB/plugins/uberdev/skills/systematic-debugging/NEWFILE.md"
assert_red "$SB" "C-FILES" "V10 an undeclared file inside a vendored component"

# V11 — a whole new skill directory nobody declared.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
mkdir -p "$SB/plugins/uberdev/skills/vendored-thing"
: > "$SB/plugins/uberdev/skills/vendored-thing/SKILL.md"
assert_red "$SB" "C-COVER" "V11 a new skill directory with no register entry"

# V12 — a declared component removed from the register while still on disk.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["components"] = [c for c in d["components"] if c["path"] != "skills/writing-skills"]
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_red "$SB" "C-COVER" "V12 a component entry deleted while the directory stays on disk"

# V13 — one byte changed in a `track` component: the digest lock must catch it.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
TRACK_FILE="$(python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["components"]:
    if c.get("stance") == "track" and c.get("files"):
        print("%s/%s" % (c["path"], c["files"][0]["path"]))
        break
PY
)"
[ -n "$TRACK_FILE" ] || { echo "  ABORT — no track component with files[] found"; exit 99; }
echo "" >> "$SB/plugins/uberdev/$TRACK_FILE"
assert_red "$SB" "C-FILES" "V13 one byte changed in a track-stance file ($TRACK_FILE)"

# V14 — the same edit inside an UNPINNED `fork` component must stay GREEN. This
# is the row that proves the stance distinction is real and not decorative:
# without it, `stance` could be a comment and every other row would still pass.
#
# The selector demands `vendored_at_commit == "unknown"` because #503 widened the
# digest lock from "stance is track" to "stance is track OR the component records
# a base" (RFC 0019 §2.3, as amended). A PINNED fork is digest-locked on purpose —
# that is V30's row — so picking one here would red this row for the widening
# rather than for a broken stance. Choosing by stance alone was ambiguous the
# moment any fork got pinned; naming the second condition is what keeps V14 and
# V30 disjoint.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
# The precondition is CONSTRUCTED, not hunted for. #503 widened the lock to every
# pinned component and #504/#505 then pinned the last unpinned ones, so the
# shipped register no longer holds an unpinned fork for this row to select — and
# a row that aborts (or skips) the moment the register is fully pinned goes quiet
# exactly when the lock is widest. What is under test is the CHECKER's rule —
# "an unpinned fork is not digest-locked" — which is stateable whatever the
# shipped register happens to contain, so the sandbox un-pins one fork itself.
FORK_FILE="$(python3 - "$SB/plugins/uberdev/vendor.json" "$SB/plugins/uberdev" <<'PY'
import json, os, re, sys
reg, plugin_dir = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
header = re.compile(r"^.*Vendored from [^@\s]+@[0-9a-f]{40}.*$\n?", re.M)
for c in d["components"]:
    if (c.get("origin") == "third-party" and c.get("stance") == "fork"
            and c.get("files") and c["path"].startswith("skills/")):
        c["vendored_at_commit"] = "unknown"
        c.pop("base_evidence", None)
        names = [e["path"] if isinstance(e, dict) else e for e in c["files"]]
        c["files"] = names
        # The pin's in-file witness goes with the pin, or C-HEADER would red on a
        # header restating a base the register no longer claims (that is V15).
        for n in names:
            p = os.path.join(plugin_dir, c["path"], n)
            b = open(p, encoding="utf-8").read()
            open(p, "w", encoding="utf-8").write(header.sub("", b))
        json.dump(d, open(reg, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
        print("%s/%s" % (c["path"], names[0]))
        break
PY
)"
[ -n "$FORK_FILE" ] || { echo "  ABORT — no fork skill component to un-pin"; exit 99; }
# The un-pinned sandbox must be green BEFORE the edit, or "still green after the
# edit" would be measuring the un-pinning rather than the lock.
if ! python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  no "V14 un-pinning a fork component redded the checker before the edit — the row cannot isolate the lock"
elif echo "" >> "$SB/plugins/uberdev/$FORK_FILE" && python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  ok "V14 one byte changed in an unpinned fork-stance file stays green ($FORK_FILE)"
else
  no "V14 an unpinned fork-stance edit redded the checker — stance is not operational"
fi

# V15 — an on-disk provenance header whose SHA disagrees with the register.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
HDR="$SB/plugins/uberdev/skills/systematic-debugging/find-polluter.sh"
python3 - "$HDR" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"(Vendored from [^@\s]+@)[0-9a-f]{40}", r"\g<1>" + "0" * 40, s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY
assert_red "$SB" "C-HEADER" "V15 an in-file header SHA that disagrees with the register"

# V16 — the README slug set drifts away from the register.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/README.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines(True)
out = []
for ln in lines:
    if "superpowers" in ln and "`using-uberdev`" in ln:
        ln = ln.replace("`using-uberdev`, ", "").replace(", `using-uberdev`", "")
    out.append(ln)
open(p, "w", encoding="utf-8").write("".join(out))
PY
assert_red "$SB" "C-README" "V16 a third-party slug dropped from the README Bundled table"

# V17 — a stance field deleted: the decision must be mandatory, not optional.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("origin") == "third-party":
        c.pop("stance", None)
        break
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_red "$SB" "C-STANCE" "V17 a third-party component with its stance removed"

# V18 — an empty component list. The whole tree is then undeclared, so this must
# be loudly red rather than vacuously green on an empty loop.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["components"] = []
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_red "$SB" "C-COVER" "V18 an empty components list is red, not vacuously green"

# V19 — a register entry with no `id`. Asserting rc alone would be worthless
# here: a checker that dies on a KeyError also exits 1. What separates broken
# from fixed is the DIAGNOSIS. Every check that names a component used to
# subscript `component["id"]` directly, so one malformed entry killed the run
# with a traceback before C-FILES or C-STANCE could report anything — defeating
# both the per-check-id contract and the collector's whole reason for existing.
# The same entry is therefore given a real C-STANCE defect and a real C-FILES
# defect: the row goes red if the checks queued behind C-SCHEMA are SUPPRESSED,
# not merely quiet.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
IDLESS="$(python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("origin") == "third-party" and c["path"].startswith("skills/"):
        c.pop("id", None)      # the KeyError trigger
        c.pop("stance", None)  # a real C-STANCE defect on the same entry
        print(c["path"])
        break
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
)"
[ -n "$IDLESS" ] || { echo "  ABORT — no third-party skill component found"; exit 99; }
: > "$SB/plugins/uberdev/$IDLESS/UNDECLARED.md"
assert_red "$SB" "C-STANCE" "V19 an id-less register entry is still reported by C-STANCE"
if grep -q 'C-FILES' <<<"$CHECK_OUT" && ! grep -q 'Traceback' <<<"$CHECK_OUT"; then
  ok "V19b the checks queued behind it still ran — C-FILES named, no traceback"
else
  no "V19b an id-less entry suppressed the checks behind it"
  echo "        output: $(head -c 400 <<<"$CHECK_OUT")"
fi

# ---------------------------------------------------------------------------
# V20-V23 — C-BASE: a recorded base commit must be WITNESSED in the shipped
# bytes (#462).
#
# THE DEFECT. C-HEADER validates the headers that exist; nothing validated a
# component that CLAIMS a base. Measured on the pre-#462 tree (62afcc5), where
# 17 components read "unknown": setting all 17 to a 40-hex literal (`deadbeef`
# x5) left the checker at rc 0 with every one of the eight checks then defined
# green. A fabricated provenance claim was therefore a single, invisible,
# one-field edit per component. C-BASE is the converse of
# C-HEADER: for every component that records a base, at least one of the
# component's own files must restate that exact `owner/repo@sha` in a
# provenance header.
#
# Every mutation row below is applied through an `if python3 …; then assert_red`
# gate. A mutation that silently no-ops would leave the sandbox pristine, the
# checker green, and the row red for a reason that has nothing to do with
# C-BASE; the gate makes "the probe could not break anything" say so in its own
# words instead of dressing it up as a checker verdict.
# ---------------------------------------------------------------------------

# V20 — C-BASE exists and is dispatched, and is green on the shipped tree.
#
# NOT the `--only` vacuity trap: `--only` with an id that is not in ALL_CHECKS
# goes through `die_usage` and exits 2, so a row demanding exit 0 goes red when
# the check is missing. It also goes red if the check is registered but red on
# the shipped tree. What it can NOT see on its own is a check registered but
# never wired into the `main()` dispatch — an arm that is never called leaves
# `failures` empty exactly like a passing one — which is why V21/V22/V23 below
# carry the behavioural weight.
if python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-BASE >/dev/null 2>&1; then
  ok "V20 C-BASE is a registered, dispatched check and is green on the shipped tree"
else
  no "V20 C-BASE is missing, unregistered, or red on the shipped tree"
fi

# V21 — a fabricated pin on a component that carries no header anywhere. This is
# the exact defect C-BASE was built for: C-SCHEMA accepts any 40-hex and C-HEADER
# has no header to disagree with, so C-BASE is the only check that can see it.
#
# THE PRECONDITION IS MANUFACTURED, NOT FOUND. This row used to *find* an unpinned,
# headerless component (`skills/brainstorm`) and fabricate a base on it. That shape
# dies the moment the component is pinned (#504) and dies permanently once the
# remaining unpinned components are pinned too (#503, #505) — the headerless pool
# empties and the row can only `SystemExit`. So the sandbox is instead put INTO the
# headerless-and-pinned state on purpose: fabricate the base AND strip every
# provenance header under the component. `skills/brainstorm` stays the subject
# because it is `stance: fork` — no C-FILES digest lock fires on its bytes, so the
# mutation reds C-BASE ALONE, which is the whole meaning of the row.
#
# Every mutation below is applied through an `if python3 …; then assert_red`
# gate. A mutation that silently no-ops would leave the sandbox pristine, the
# checker green, and the row red for a reason that has nothing to do with
# C-BASE; the gate makes "the probe could not break anything" say so in its own
# words instead. Both refusal arms below report through that gate.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, os, sys
p = sys.argv[1]
plugin = os.path.dirname(p)
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("path") == "skills/brainstorm":
        if c.get("stance") != "fork":
            raise SystemExit("skills/brainstorm is no longer `fork` — a digest lock would "
                             "red C-FILES too and this row would stop isolating C-BASE")
        c["vendored_at_commit"] = "deadbeef" * 5
        break
else:
    raise SystemExit("skills/brainstorm is no longer in the register")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
stripped = 0
for dirpath, _dirs, files in os.walk(os.path.join(plugin, "skills", "brainstorm")):
    for name in files:
        f = os.path.join(dirpath, name)
        try:
            text = open(f, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        lines = text.splitlines(True)
        kept = [ln for ln in lines if "Vendored from" not in ln]
        if len(kept) != len(lines):
            stripped += len(lines) - len(kept)
            open(f, "w", encoding="utf-8").write("".join(kept))
if stripped == 0:
    raise SystemExit("no provenance header under skills/brainstorm to strip — the fabricated "
                     "base would be unwitnessed for the wrong reason and the row proves nothing")
PY
then
  assert_red "$SB" "C-BASE" "V21 a fabricated 40-hex base on a component with no in-file header"
else
  no "V21 could not manufacture the headerless-and-pinned state on skills/brainstorm — the probe mutated nothing"
fi

# V22 — the witness removed while the register stays pinned. The inverse of
# V15: V15 mutates the header and keeps the register, this mutates the file so
# the header is GONE and the register's claim is left unwitnessed. C-FILES also
# reds here (the tracked digest moves) — which does not weaken the row, because
# `assert_red` demands C-BASE *by name*.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/skills/dispatching-parallel-agents/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines(True)
kept = [ln for ln in lines if "Vendored from" not in ln]
if len(kept) == len(lines):
    raise SystemExit("nothing to delete: %s carries no provenance header" % p)
open(p, "w", encoding="utf-8").write("".join(kept))
PY
then
  assert_red "$SB" "C-BASE" "V22 a pinned component whose only in-file witness was deleted"
else
  no "V22 skills/dispatching-parallel-agents carries no provenance header to delete"
fi

# V23 — anti-vacuity. If every third-party component drops back to "unknown",
# C-BASE's loop body never runs and a naive implementation would report success
# over an empty set — the same "the scan is vacuous" trap C-HEADER, C-COVER,
# C-README and C-STANCE each carry their own guard for. C-HEADER also reds here,
# once per header-carrying file (V5 is what pins that count — restating it in
# this comment would just be a second copy of it, free to drift); the row demands
# C-BASE by name, so C-HEADER's noise cannot satisfy it.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
pinned = 0
for c in d["components"]:
    if c.get("origin") == "third-party":
        if c.get("vendored_at_commit") != "unknown":
            pinned += 1
        c["vendored_at_commit"] = "unknown"
if not pinned:
    raise SystemExit("no third-party component was pinned — unpinning them all "
                     "changes nothing and the row would prove nothing")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-BASE" "V23 every base dropped to 'unknown' is red, not vacuously green"
else
  no "V23 could not unpin the register — no component recorded a base to remove"
fi

echo
echo "== V24-V25 and V30-V32: derived-count, digest-lock and declared-claim ratchets =="

# V24 — RFC 0019 §2.2's counts are DERIVED from the register, not typed once and
# left to rot.
#
# THE CLASS: policy prose that lies while CI stays green. §2.2 states how many
# components are unpinned; the register is the only thing that knows. Nothing
# compared them, so the first real backfill (#462) would have left the RFC
# asserting a number that is now false — and the RFC is what a reviewer reads to
# decide whether a `vendored_at_commit` is trustworthy.
#
# Pure Python over the committed register and the committed RFC: no checker in
# the loop, so a mis-parsing checker cannot make this row lie (the V1/V4/V8/V9
# idiom). §1's counts at :24-26 are deliberately OUT of reach — that paragraph
# opens "Until this RFC, the provenance ... was recorded in three places", so it
# describes the state before the register existed and must not track it.
if python3 - "$REGISTER" "$REPO_ROOT/docs/rfc/0019-vendored-upstream-policy.md" <<'PY'
import json, sys
reg, rfc_path = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
third = [c for c in d["components"] if c.get("origin") == "third-party"]
assert third, "no third-party components declared"
n_skills_unknown = len([c for c in third
                        if c["path"].startswith("skills/")
                        and c.get("vendored_at_commit") == "unknown"])
n_unknown_total = len([c for c in third
                       if c.get("vendored_at_commit") == "unknown"])
rfc = open(rfc_path, encoding="utf-8").read()
if n_unknown_total:
    wants = ("the %d unpinned skill directories" % n_skills_unknown,
             "honest value for %d of the 20" % n_unknown_total)
else:
    # TERMINAL STATE: every third-party component is pinned. The two count
    # literals above have no honest grammatical form at zero ("the 0 unpinned
    # skill directories"), and contorting the prose to satisfy a matcher is how
    # a row stops meaning anything. So the RFC must state the fully-pinned fact
    # in words instead — and it must STATE it, because a branch that asserted
    # nothing would go quiet exactly when the register reached the state this
    # whole RFC is driving toward.
    wants = ('no component reads `"unknown"`',)
for want in wants:
    assert want in rfc, "RFC 0019 does not say %r — the register has moved on" % want
PY
then ok "V24 RFC 0019 §2.2's unpinned counts still match the register"
else no "V24 RFC 0019 §2.2 states an unpinned count the register contradicts"
fi

# V24b — the SAME class one section up. §2.1 states how many components exist and
# how they split by origin. V24 covers only §2.2's unpinned counts, so §2.1 was
# free to rot beside it and did: it said 73 / 20 / 53 while the register held
# 75 / 20 / 55, and every check stayed green. Two numbers wrong out of three, in
# the paragraph a reader reaches FIRST when deciding whether the register is
# maintained.
#
# Whitespace is collapsed before the search because the RFC hard-wraps its
# prose: an assertion that only matched the current line breaks would red on a
# reflow that changed no fact, and a row that reds for cosmetic reasons gets
# relaxed until it means nothing.
RFC_COUNTS_PY="$SANDBOX_ROOT/rfc-origin-counts.py"
cat > "$RFC_COUNTS_PY" <<'PY'
import json, re, sys

register = json.load(open(sys.argv[1], encoding="utf-8"))
rfc = open(sys.argv[2], encoding="utf-8").read()
components = register["components"]
total = len(components)
third = len([c for c in components if c.get("origin") == "third-party"])
own = len([c for c in components if c.get("origin") == "uberdev"])
assert total, "the register declares no components — the row would be vacuous"
assert third and own, "one origin is empty; the three-way split would be trivial"
want = "There are **%d** of them: %d third-party and %d" % (total, third, own)
flat = re.sub(r"\s+", " ", rfc)
assert want in flat, "RFC 0019 §2.1 does not say %r — the register has moved on" % want
PY
if python3 "$RFC_COUNTS_PY" "$REGISTER" "$REPO_ROOT/docs/rfc/0019-vendored-upstream-policy.md"; then
  V24B_WHY=""
  MUTATED_COUNTS="$SANDBOX_ROOT/mutated-counts.json"
  if python3 - "$REGISTER" "$MUTATED_COUNTS" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding="utf-8"))
before = len(d["components"])
d["components"].append({"id": "agents/v24b-probe.md",
                        "path": "agents/v24b-probe.md",
                        "origin": "uberdev"})
assert len(d["components"]) == before + 1, "the probe component was not appended"
json.dump(d, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
  then
    if python3 "$RFC_COUNTS_PY" "$MUTATED_COUNTS" "$REPO_ROOT/docs/rfc/0019-vendored-upstream-policy.md" >/dev/null 2>&1; then
      V24B_WHY="the assertion stayed green after a component was added"
    fi
  else
    V24B_WHY="could not append a probe component — the mutation changed nothing"
  fi
  if [ -z "$V24B_WHY" ]; then
    ok "V24b RFC 0019 §2.1's component counts are derived from the register, and move with it"
  else
    no "V24b $V24B_WHY"
  fi
else
  no "V24b RFC 0019 §2.1 states a component count the register contradicts"
fi

# V25 — no DIGEST-LOCKED component excuses a file from the digest lock.
#
# `divergences[]` entries with a non-null `file` are C-FILES' declared-change
# escape hatch (vendor-check.py check_files: `excused` is consulted before the
# sha256 mismatch is reported). On an unlocked component that is the whole point.
# On a locked one it silently disarms the digest for that file — and V13's own
# mutation target is chosen as the first `track` component carrying files[], so
# one such entry would make V13 pass on a mutated tracked file: the ratchet would
# go quiet rather than red.
#
# The locked set is `stance == track` OR `vendored_at_commit` is a real base
# (#503 / RFC 0019 §2.3 as amended) — the same predicate the checker uses, so
# widening the lock cannot leave a class of components outside this row. A
# component-scoped ref (`"file": null`) is still allowed and is the shape every
# locked component uses: `tools/vendor/vendor-drift.py`'s `declared_files`
# resolves the ref back to `permanent_divergences[].file`, so upstream drift is
# still labelled DECLARED while the local digest stays armed.
#
# RFC 0019 §2.3 names the escape hatch deliberately, so deleting it from the
# checker would be an RFC amendment. Pinning it here instead makes it costly to
# adopt on purpose and impossible to adopt by accident.
if python3 - "$REGISTER" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
hex40 = re.compile(r"^[0-9a-f]{40}$")
locked = [c for c in d["components"]
          if c.get("stance") == "track"
          or hex40.match(c.get("vendored_at_commit") or "")]
assert locked, "no digest-locked components — the row would be vacuous"
assert any(c.get("stance") == "fork" for c in locked), \
    "no PINNED FORK is digest-locked — the widened arm of this row is vacuous"
offenders = [(c["id"], v["file"]) for c in locked
             for v in c.get("divergences", []) if v.get("file")]
assert not offenders, \
    "digest-locked components carrying a file-scoped digest excuse: %s" % offenders
PY
then ok "V25 no digest-locked component excuses a file from the C-FILES digest lock"
else no "V25 a digest-locked component carries a file-scoped divergence — the lock is disarmed"
fi

# V30 — the widened digest lock, proved falsifiable on a PINNED FORK.
#
# THE DEFECT #503 FOUND. C-FILES enforced sha256 only when `stance == "track"`.
# So the moment a component was honestly re-adjudicated to `fork` — which is what
# declaring a real local divergence obliges under RFC 0019 §4.1 — its digest lock
# vanished. Provenance got *better* (a real `vendored_at_commit` plus an in-file
# header) and byte evidence got *worse* at the same instant, and the pin was then
# a claim nothing held to the bytes: edit the file, the header still names the
# base, every check stays green. Measured on the pre-#503 tree, appending a byte
# to any fork-stance file left the checker at exit 0.
#
# The fix ties the lock to the PIN rather than to the stance: a component that
# records a base must carry `{path, sha256}` entries whatever its stance. This
# row is that rule's falsifiability proof, and V14 above is its counter-case —
# an UNPINNED fork edit must still stay green, so the widening cannot creep into
# "every fork is locked".
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
PINNED_FORK_FILE="$(python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
hex40 = re.compile(r"^[0-9a-f]{40}$")
# The target must be a file the lock actually holds: a file named by a
# divergences[].file entry is EXCUSED from the sha256 comparison, so mutating
# one would leave the checker green for a legitimate reason and read as a
# missing lock.
target = None
for c in d["components"]:
    if (c.get("stance") == "fork" and c.get("files")
            and c["path"].startswith("skills/")
            and hex40.match(c.get("vendored_at_commit") or "")):
        excused = {v["file"] for v in c.get("divergences", []) if v.get("file")}
        for entry in c["files"]:
            rel = entry.get("path") if isinstance(entry, dict) else entry
            if rel not in excused:
                target = "%s/%s" % (c["path"], rel)
                break
    if target:
        break
print(target or "")
PY
)"
[ -n "$PINNED_FORK_FILE" ] || { echo "  ABORT — no pinned fork component with an unexcused file"; exit 99; }
echo "" >> "$SB/plugins/uberdev/$PINNED_FORK_FILE"
assert_red "$SB" "C-FILES" "V30 one byte changed in a PINNED fork-stance file ($PINNED_FORK_FILE)"

# V31 — the register actually carries digests everywhere the widened rule
# demands them, asserted in Python against the committed file (the V1/V4/V8/V9
# idiom) so a checker that stopped enforcing the rule cannot make the row lie.
# Without it, "pinned components are digest-locked" would be a property of the
# checker's source with no statement about the shipped register: a `files[]` that
# quietly reverted to bare paths would red only V30's sandbox, and only for as
# long as V30's selector happened to pick that component.
if python3 - "$REGISTER" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
hex40 = re.compile(r"^[0-9a-f]{40}$")
sha256 = re.compile(r"^[0-9a-f]{64}$")
locked = [c for c in d["components"]
          if c.get("origin") == "third-party"
          and (c.get("stance") == "track"
               or hex40.match(c.get("vendored_at_commit") or ""))]
assert locked, "no digest-locked components — the row would be vacuous"
assert any(c.get("stance") == "fork" for c in locked), \
    "no PINNED FORK in the locked set — the widened arm of this row is vacuous"
bare = [(c["id"], e) for c in locked for e in c.get("files", [])
        if not isinstance(e, dict) or not sha256.match(e.get("sha256") or "")]
assert not bare, "digest-locked components carrying a file with no sha256: %s" % bare
PY
then ok "V31 every digest-locked component records a sha256 for every declared file"
else no "V31 a digest-locked component declares a file with no sha256"
fi

# V32 — a `namespace-rebrand` reference on a PINNED component must be witnessed
# in that component's own bytes.
#
# THE CLASS, twice now. `skills/dispatching-parallel-agents` claimed its delta
# was "the namespace rebrand" for a file containing neither `superpowers:` nor
# `uberdev:` — #462 corrected the prose but left the machine-readable ref behind.
# Measuring the five #503 components against their base found the identical lie
# in two more: `receiving-code-review` and `verification-before-completion` each
# carry ONE appended local section and no rebrand token at all. A divergence ref
# is the register's structured claim about why bytes differ; an unwitnessed one
# is drift wearing a declaration's clothes, and it is what
# `tools/vendor/vendor-drift.py` subtracts from the weekly report.
#
# Scoped to PINNED components deliberately. An unpinned component has no proven
# base, so "these bytes differ from upstream because of the rebrand" is not yet a
# checkable statement — the six agents are #505's, not this row's. Pinning a
# component brings it into scope, which is the ratchet.
if python3 - "$REGISTER" "$REPO_ROOT" <<'PY'
import json, os, re, sys
reg, root = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
plugin = os.path.join(root, "plugins", "uberdev")
hex40 = re.compile(r"^[0-9a-f]{40}$")


def rebrand_tokens(component):
    """Occurrences of the UberDev brand outside provenance-header lines.

    Header lines are excluded because every one of them cites
    `plugins/uberdev/licenses/...`, which would witness the claim on every
    pinned file and make this row vacuous.
    """
    cdir = os.path.join(plugin, component["path"])
    n = 0
    for entry in component.get("files", []):
        rel = entry.get("path") if isinstance(entry, dict) else entry
        src = os.path.join(cdir, rel) if os.path.isdir(cdir) else cdir
        try:
            text = open(src, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        n += sum(ln.count("uberdev") for ln in text.splitlines()
                 if "Vendored from" not in ln)
    return n


pinned = [c for c in d["components"]
          if c.get("origin") == "third-party"
          and hex40.match(c.get("vendored_at_commit") or "")]
assert pinned, "no pinned third-party component — the row would be vacuous"
claimed = [c for c in pinned
           if any(v.get("ref") == "namespace-rebrand" for v in c.get("divergences", []))]
assert claimed, "no pinned component references namespace-rebrand — the row is vacuous"
unwitnessed = [c["id"] for c in claimed if rebrand_tokens(c) == 0]
assert not unwitnessed, (
    "pinned components claim the namespace rebrand with no rebrand token in their "
    "bytes: %s" % unwitnessed)
PY
then ok "V32 every pinned component claiming the namespace rebrand is witnessed by its own bytes"
else no "V32 a pinned component claims the namespace rebrand its bytes do not carry"
fi

echo
echo "== V41-V43c: the RFC/register reconciliation, the SDD adjudication record and C-DIVREF =="

# V31 — RFC 0019 §6 and `permanent_divergences[]` are ONE list spelled twice.
#
# THE CLASS, again (#509). §6 is what a reviewer reads to decide whether a local
# divergence was DECIDED or merely happened; the register is what the tooling
# reads. Nothing compared them, so a divergence could be registered and never
# adjudicated in the RFC, or adjudicated and never registered — and the second
# shape is exactly how #509's SDD parallel-implementer inversion stayed
# invisible. Measured on the tree that motivated this row: 7 register ids
# against 6 RFC rows, with `find-polluter-fail-loud` present only in the
# register.
#
# Pure Python over the two COMMITTED files, no checker in the loop (the
# V1/V4/V8/V9/V24 idiom), and deliberately NOT through `make_sandbox`: that
# harness copies only `plugins/uberdev/` and `README.md`, so the RFC is not in a
# sandbox at all.
if python3 - "$REGISTER" "$REPO_ROOT/docs/rfc/0019-vendored-upstream-policy.md" <<'PY'
import json, re, sys
reg, rfc_path = sys.argv[1], sys.argv[2]
text = open(rfc_path, encoding="utf-8").read()
section = re.search(r"^## 6\..*?$(.*?)^## ", text, re.S | re.M)
assert section, "RFC 0019 has no '## 6.' section — the parse is broken, not the tree clean"
rows = []
for line in section.group(1).splitlines():
    if not line.startswith("|"):
        continue
    cell = line.split("|")[1].strip()
    # Only a backticked id is a row: this skips the `| Id | Scope | ... |`
    # header and the `| --- |` separator without pinning either one's wording.
    match = re.fullmatch(r"`([^`]+)`", cell)
    if match:
        rows.append(match.group(1))
# ANTI-VACUITY FIRST. A parse that stopped matching would compare empty against
# empty and report agreement forever — the permanent false green V28's
# `seen >= 3` guard exists for. Assert the corpus BEFORE comparing it.
assert len(rows) >= 5, \
    "only %d id row(s) parsed out of RFC 0019 §6 — the parse is broken" % len(rows)
perm = {p["id"] for p in json.load(open(reg, encoding="utf-8"))["permanent_divergences"]}
only_rfc = sorted(set(rows) - perm)
only_register = sorted(perm - set(rows))
assert not only_rfc and not only_register, \
    "only-in-rfc: %s only-in-register: %s" % (only_rfc, only_register)
PY
then ok "V41 RFC 0019 §6's table and permanent_divergences[] name the same ids, both ways"
else no "V41 RFC 0019 §6 and the register disagree about which divergences exist"
fi

# V32 — the #509 adjudication record: SDD's parallel-implementer inversion is
# REGISTERED, not merely lived with.
#
# Upstream `subagent-driven-development/SKILL.md` forbids dispatching multiple
# implementation subagents in parallel; UberDev's fork makes exactly that its
# stated core principle. That is a deliberate policy divergence of the same
# shape as `review-pr-parallel-by-default`, and until #509 the register declared
# only `namespace-rebrand` for the component.
#
# Shaped on tests/finish-branch.test.sh F14 but scoped to this component. It
# deliberately does NOT grep the note's wording: pinning the policy paragraph's
# text is the string-presence counterfeit RFC 0019 §7 adopted
# `writing-good-tests.md` to kill (#457). What is asserted is that the record
# EXISTS, is structured, and is wired to the component from both directions.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
target = "sdd-parallel-implementer-waves"
problems = []
entry = next((e for e in d.get("permanent_divergences", [])
              if e.get("id") == target), None)
if entry is None:
    problems.append("no-permanent-divergence-entry")
else:
    if entry.get("permanent") is not True:
        problems.append("entry-not-permanent")
    if entry.get("kind") != "policy-divergence":
        problems.append("entry-kind-wrong:%r" % entry.get("kind"))
    if entry.get("scope") != "skills/subagent-driven-dev":
        problems.append("entry-scope-wrong:%r" % entry.get("scope"))
    if entry.get("file") != "SKILL.md":
        problems.append("entry-file-wrong:%r" % entry.get("file"))
    if not str(entry.get("note", "")).strip():
        problems.append("entry-note-empty")
component = next((c for c in d.get("components", [])
                  if c.get("id") == "skills/subagent-driven-dev"), None)
if component is None:
    problems.append("no-sdd-component")
else:
    refs = [x.get("ref") for x in component.get("divergences", [])]
    if target not in refs:
        problems.append("component-does-not-reference-entry")
    # The pre-existing declaration must SURVIVE the addition: an entry that
    # replaced `namespace-rebrand` rather than joining it would satisfy every
    # other assertion here while quietly dropping a declared divergence.
    if "namespace-rebrand" not in refs:
        problems.append("namespace-rebrand-ref-lost")
    if component.get("stance") != "fork":
        problems.append("stance-not-fork:%r" % component.get("stance"))
assert not problems, " ".join(problems)
PY
then ok "V42 the SDD parallel-implementer divergence is a registered, component-linked record"
else no "V42 the SDD parallel-implementer divergence is unregistered or unlinked"
fi

# ---------------------------------------------------------------------------
# V26-V29: C-REFS — a skill that points at a sibling file which is not there.
#
# THE CHANNEL (#457). Every check above reconciles the register against disk, or
# a header against the register. None of them reads what a shipped document
# SAYS. So a SKILL.md could keep instructing agents to read a reference that a
# vendor swap deleted, and all eight checks stayed green — the reference is not
# a register field, and `stance: fork` means C-FILES never digests the file that
# carries it. That is exactly the surface this component's own swap moved.
#
# Each row below breaks the reference and NOTHING else: the register is kept
# consistent with disk by hand, so C-FILES, C-COVER and C-HEADER have nothing to
# say and C-REFS is the only check that CAN go red.
#
# Deliberately driven through `assert_red`, which calls the FULL checker. Using
# `--only C-REFS` here would be a vacuity trap: before the check existed,
# `die_usage` printed `unknown check id(s): ['C-REFS'] (known: …)` — a non-zero
# rc whose text CONTAINS the wanted id, so the row would report PASS against a
# checker that has no such check.
# ---------------------------------------------------------------------------

# V26 — the reference target is deleted and the register is updated to match, so
# register and disk still agree. This is #457's own failure mode: a vendor swap
# that retires a file and leaves the referring document behind.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
REF_TARGET="$SB/plugins/uberdev/skills/test-driven-development/writing-good-tests.md"
[ -e "$REF_TARGET" ] || { echo "  ABORT — V26's target is already absent; the mutation would be a no-op"; exit 99; }
rm -f "$REF_TARGET"
python3 - "$SB/plugins/uberdev/vendor.json" <<'PY' || { echo "  ABORT — V26 register edit failed"; exit 99; }
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("path") != "skills/test-driven-development":
        continue
    before = len(c["files"])
    c["files"] = [f for f in c["files"]
                  if (f.get("path") if isinstance(f, dict) else f) != "writing-good-tests.md"]
    assert len(c["files"]) == before - 1, "writing-good-tests.md was not declared; V26 proves nothing"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_red "$SB" "C-REFS" "V26 a skill reference whose target was removed with the register kept consistent"

# V27 — the target file stays; the reference is misspelled. File set, register,
# headers and counts are all untouched, so C-REFS is the only check that can
# possibly notice.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/plugins/uberdev/skills/test-driven-development/SKILL.md" <<'PY' || { echo "  ABORT — V27 mutation failed"; exit 99; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n = s.count("](writing-good-tests.md)")
assert n == 1, "expected exactly one markdown link to writing-good-tests.md, found %d" % n
open(p, "w", encoding="utf-8").write(
    s.replace("](writing-good-tests.md)", "](writing-good-tests-typo.md)"))
PY
assert_red "$SB" "C-REFS" "V27 a sibling reference pointing at a name that is not on disk"

# V28 — anti-vacuity, asserted in Python rather than through the checker (same
# design as V1/V3/V4): a checker whose regexes silently match nothing would make
# every row above pass while protecting nothing. The independent scan states the
# corpus is non-empty and fully resolving; the two checker calls then state that
# `C-REFS` is a REGISTERED id, not an `if` arm nobody reaches.
V28_WHY=""
if ! python3 - "$REGISTER" "$REPO_ROOT" <<'PY'
import json, os, re, sys

FENCE = re.compile(r"^\s*(?:```|~~~)")
CODESPAN = re.compile(r"`[^`]*`")
AT_REF = re.compile(r"(?<![A-Za-z0-9._-])@([A-Za-z0-9._][A-Za-z0-9._/-]*\.[A-Za-z0-9]+)")
MD_LINK = re.compile(r"\]\(([^)\s]+)")


def refs(text):
    body, in_fence = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            # skills/writing-skills teaches the `@`-ref convention by quoting a
            # BAD example in backticks; a scan that read it would report a
            # dangling reference against a file describing what NOT to write.
            body.append(CODESPAN.sub(" ", line))
    joined = "\n".join(body)
    out = set()
    for t in set(AT_REF.findall(joined)) | set(MD_LINK.findall(joined)):
        if "://" in t or t.startswith(("/", "#", "mailto:")):
            continue
        out.add(t)
    return sorted(out)


reg, root = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
plugin = os.path.join(root, "plugins", "uberdev")
seen, dangling = 0, []
for c in d["components"]:
    if c.get("origin") != "third-party":
        continue
    cdir = os.path.join(plugin, c["path"])
    for entry in c.get("files", []):
        rel = entry.get("path") if isinstance(entry, dict) else entry
        if not isinstance(rel, str) or not rel.endswith(".md"):
            continue
        src = os.path.join(cdir, rel) if os.path.isdir(cdir) else cdir
        text = open(src, encoding="utf-8").read()
        for ref in refs(text):
            seen += 1
            if not os.path.exists(os.path.join(os.path.dirname(src), ref)):
                dangling.append("%s/%s -> %s" % (c["path"], rel, ref))
assert seen >= 3, "only %d sibling reference(s) found — the C-REFS corpus is too thin to protect anything" % seen
assert not dangling, "shipped tree carries dangling references: %s" % dangling
PY
then V28_WHY="V28 the independent scan found fewer than 3 sibling references, or an unresolved one"
elif ! python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-REFS >/dev/null 2>&1; then
  V28_WHY="V28 vendor-check.py --only C-REFS is not green on the shipped tree"
else
  BOGUS_RC=0
  BOGUS_OUT="$(python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-BOGUS 2>&1)" || BOGUS_RC=$?
  if [ "$BOGUS_RC" -eq 0 ]; then
    V28_WHY="V28 --only C-BOGUS was accepted; the known-id list is not enforced"
  elif ! grep -q 'C-REFS' <<<"$BOGUS_OUT"; then
    V28_WHY="V28 C-REFS is not in ALL_CHECKS — --only C-BOGUS never listed it among the known ids"
  fi
fi
if [ -z "$V28_WHY" ]; then
  ok "V28 C-REFS: >= 3 resolving sibling references on the shipped tree, and the id is registered"
else
  no "$V28_WHY"
fi

# V28b — the vacuity arm actually fires. Without this row, "a checker that finds
# zero references must fail loud" is prose with no test: the same class as
# check_header's `found == 0` guard, which exists precisely because a scan that
# sees nothing otherwise reports agreement. Every declared third-party markdown
# file is rewritten so no reference SHAPE survives; provenance headers are left
# byte-exact and `track` digests are re-recorded against the mutated bytes, so
# C-HEADER and C-FILES have nothing to say and C-REFS is again the only check
# that can go red.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB" <<'PY' || { echo "  ABORT — V28b mutation failed"; exit 99; }
import hashlib, json, os, re, sys

AT_LEADER = re.compile(r"@(?=[A-Za-z0-9._][A-Za-z0-9._/-]*\.[A-Za-z0-9])")
root = sys.argv[1]
plugin = os.path.join(root, "plugins", "uberdev")
regp = os.path.join(plugin, "vendor.json")
d = json.load(open(regp, encoding="utf-8"))
touched = 0
for c in d["components"]:
    if c.get("origin") != "third-party":
        continue
    cdir = os.path.join(plugin, c["path"])
    for entry in c.get("files", []):
        rel = entry.get("path") if isinstance(entry, dict) else entry
        if not isinstance(rel, str) or not rel.endswith(".md"):
            continue
        src = os.path.join(cdir, rel) if os.path.isdir(cdir) else cdir
        text = open(src, encoding="utf-8").read()
        out = []
        for ln in text.splitlines(True):
            if "Vendored from" not in ln:
                ln = AT_LEADER.sub("at ", ln.replace("](", "] ("))
            out.append(ln)
        new = "".join(out)
        if new != text:
            open(src, "w", encoding="utf-8").write(new)
            touched += 1
        if isinstance(entry, dict):
            entry["sha256"] = hashlib.sha256(open(src, "rb").read()).hexdigest()
json.dump(d, open(regp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
assert touched > 0, "no declared markdown file changed — the mutation is a no-op"
PY
assert_red "$SB" "C-REFS" "V28b a tree with no sibling reference at all is red, not vacuously green"

# V29 — the must-STAY-GREEN row, in the same spirit as V14. An `@` that carries a
# local part is an address or a version pin, never a sibling file: an email, an
# npm-style `pkg@1.2.3`, and a `repo@v6.2.0` tag all contain a dotted token that
# a naive `@`-scan reads as a filename (`x@y.com` -> `y.com`), reporting a
# dangling reference against a document that references nothing at all. Drop the
# lookbehind from AT_REF_RE and this row goes red.
#
# The append re-records the file's digest in the sandbox register, the same way
# V28b does. Its target is a PINNED component, so since #503 widened the digest
# lock from `stance: track` to "track or pinned" the edit moves a locked sha256 —
# and a C-FILES failure would red this row for a reason that has nothing to do
# with address parsing. Re-recording keeps C-REFS the only check in play, and it
# keeps that true for any component this row's target may be swapped to later,
# which choosing an unlocked file today would not.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
ADDR_FILE="$SB/plugins/uberdev/skills/test-driven-development/SKILL.md"
python3 - "$ADDR_FILE" "$SB/plugins/uberdev/vendor.json" <<'PY' || { echo "  ABORT — V29 mutation failed"; exit 99; }
import hashlib, json, sys
p, regp = sys.argv[1], sys.argv[2]
with open(p, "a", encoding="utf-8") as fh:
    fh.write("\nReport problems to maintainer.person@example.com, pin deps as "
             "left-pad@1.2.3, and cite upstream as obra/superpowers@v6.2.0.\n")
digest = hashlib.sha256(open(p, "rb").read()).hexdigest()
d = json.load(open(regp, encoding="utf-8"))
rerecorded = 0
for c in d["components"]:
    if c.get("path") != "skills/test-driven-development":
        continue
    for entry in c.get("files", []):
        if isinstance(entry, dict) and entry.get("path") == "SKILL.md":
            entry["sha256"] = digest
            rerecorded += 1
assert rerecorded == 1, "expected exactly one recorded digest for the target, found %d" % rerecorded
json.dump(d, open(regp, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
if python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  ok "V29 an email, a package pin and a tag pin are not read as sibling references"
else
  no "V29 an address-shaped @-token was read as a sibling file — C-REFS false-positives"
  run_check "$SB" || true
  echo "        output: $(head -c 400 <<<"$CHECK_OUT")"
fi

# ---------------------------------------------------------------------------
# V30a-V30b: C-DIVREF — a `divergences[].ref` that resolves to nothing.
#
# THE CHANNEL (#509). `check_files()` short-circuits every component whose
# stance is not `track`, so a `fork`'s `divergences[]` is never read at all; and
# before this change NO check anywhere resolved a `divergences[].ref` against a
# `permanent_divergences[].id`. The only such resolution in the repo was
# `tests/finish-branch.test.sh` F14, scoped to one component. So a component
# could reference a divergence record that does not exist — or a record could be
# deleted out from under a live reference — and all ten checks stayed green.
# Measured on the tree before this row: zero dangling refs across 26 refs / 75
# components, and a checker that exits 0 on a tree where one is fabricated.
#
# Each mutation touches the REGISTER ONLY, leaving disk untouched, so no other
# check has anything to say and C-DIVREF is the only one that CAN go red. Each
# is applied through the V21/V26 `if python3 …; then assert_red` gate so a
# mutation that silently no-ops says so in its own words instead of dressing
# itself up as a checker verdict.
#
# Deliberately driven through `assert_red`, which runs the FULL checker.
# `--only C-DIVREF` would be the vacuity trap V28 documents: before the check
# exists, `die_usage` prints `unknown check id(s): ['C-DIVREF'] (known: …)` — a
# non-zero rc whose text CONTAINS the wanted id, so the row would report PASS
# against a checker that has no such check.
# ---------------------------------------------------------------------------

# V30a — a live reference misspelled. The record still exists; nothing resolves
# the pointer at it.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
target = "sdd-parallel-implementer-waves"
component = next((c for c in d["components"]
                  if c.get("id") == "skills/subagent-driven-dev"), None)
if component is None:
    raise SystemExit("skills/subagent-driven-dev is no longer in the register")
hit = next((x for x in component.get("divergences", []) if x.get("ref") == target), None)
if hit is None:
    raise SystemExit("the component does not reference %s; the typo would be a no-op" % target)
hit["ref"] = target + "-typo"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-DIVREF" "V43a a divergences[].ref misspelled while the record stays"
else
  no "V43a could not misspell the SDD divergence ref — the probe mutated nothing"
fi

# V30b — the converse: the record deleted while a live reference still points at
# it. This is the shape a future "tidy up the register" edit produces.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
target = "sdd-parallel-implementer-waves"
before = len(d["permanent_divergences"])
d["permanent_divergences"] = [e for e in d["permanent_divergences"]
                              if e.get("id") != target]
if len(d["permanent_divergences"]) != before - 1:
    raise SystemExit("%s was not a permanent divergence; V30b proves nothing" % target)
referring = [c.get("id") for c in d["components"]
             for x in c.get("divergences", []) if x.get("ref") == target]
if not referring:
    raise SystemExit("no component references %s; the deletion dangles nothing" % target)
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-DIVREF" "V43b a permanent_divergences[] record deleted under a live reference"
else
  no "V43b could not delete the SDD divergence record — the probe mutated nothing"
fi

# V30c — the third arm: an entry that declares a `file` and no pointer at all.
# RFC 0019 §2.4's "plus any component-local entries" could be read as licensing
# this, and `vendor-drift.py` `declared_files()` would happily subtract it from
# raw drift — an undeclared divergence excusing itself. C-DIVREF requires the
# pointer, so the amendment's tightening is falsifiable rather than prose.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
component = next((c for c in d["components"]
                  if c.get("id") == "skills/subagent-driven-dev"), None)
if component is None:
    raise SystemExit("skills/subagent-driven-dev is no longer in the register")
hit = next((x for x in component.get("divergences", [])
            if x.get("ref") == "sdd-parallel-implementer-waves"), None)
if hit is None:
    raise SystemExit("the component does not carry the entry this row strips")
hit.pop("ref")
# The shipped entry is component-scoped (`file: null`), because #503's digest
# lock forbids a file-scoped excuse on a pinned component and this component is
# pinned. This row is about the missing REF, not about the scope, so it SETS the
# file it needs instead of requiring the register to ship one — otherwise the two
# rules could not both hold and this row would abort on a perfectly good tree.
hit["file"] = "SKILL.md"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-DIVREF" "V43c a divergences[] entry with a file and no ref at all"
else
  no "V43c could not strip the SDD divergence ref — the probe mutated nothing"
fi

echo
echo "== V35-V36b: a recorded base is EVIDENCED, not merely restated (#505) =="

# ---------------------------------------------------------------------------
# THE GAP C-BASE LEAVES OPEN. C-BASE (V20-V23) makes a `vendored_at_commit` cost
# two coordinated lies instead of one: the register's claim must be restated in
# an in-file header. Both halves are still writable by hand, and the RFC says so
# in its own words — "it does not, and offline cannot, prove a copy really
# happened at that SHA". For the ten unpinned skill directories that was
# tolerable; for the six agents it is not, because there is no local clone of
# `anthropics/claude-plugins-official` at all, so nothing in the tree could even
# be compared against upstream by hand.
#
# `base_evidence` closes it with a MEASUREMENT rather than a stronger assertion:
# per component, the blob oid each declared file had at `vendored_ref` — a
# commit in THIS repository. Recovery proved that oid equal to upstream's blob
# at `vendored_at_commit`, so the recorded pin is re-derivable from two
# independent trees instead of asserted in two places in one tree.
#
# The two halves are split by what they cost. THIS suite owns the offline half
# (does the oid match what git says here?) and never touches the network;
# `vendor-drift.py --verify-bases` owns the upstream half. Merging them would
# make a network outage look like fabricated provenance, which is the same
# category error `vendor-check.py` stays offline to avoid.
# ---------------------------------------------------------------------------

# Both oracles are written to disk ONCE and driven twice — over the shipped
# register (V35/V36) and over a deliberately-broken copy (V36b). A second inline
# copy of either would be free to drift from the one the shipped tree is
# actually checked against, which is the "one contract, N uncompared copies"
# class this whole register exists to kill.
BASE_ROWS_PY="$SANDBOX_ROOT/base-evidence-rows.py"
cat > "$BASE_ROWS_PY" <<'PY'
"""Emit one `component-id \t vendored_ref \t git-path \t blob-oid` row per
declared file of every component carrying base_evidence.

The git-path join mirrors vendor-check.py's `component_files_on_disk`: a
component whose path is a FILE (an agent) *is* that file, so its `files[]` entry
is a basename rather than a sub-path; a directory component owns paths relative
to its own root. Deciding it from disk rather than from the id shape is what
makes this generalise to the multi-file skill components #503/#504 will pin.
"""
import json, os, sys

register_path, repo_root = sys.argv[1], sys.argv[2]
register = json.load(open(register_path, encoding="utf-8"))
plugin_rel = register.get("root") or "plugins/uberdev"
for component in register.get("components", []):
    evidence = component.get("base_evidence")
    if not isinstance(evidence, dict):
        continue
    ref = evidence.get("vendored_ref") or ""
    blobs = evidence.get("blobs")
    if not isinstance(blobs, dict):
        continue
    path = component.get("path") or ""
    on_disk = os.path.join(repo_root, plugin_rel, path)
    for rel, oid in sorted(blobs.items()):
        git_path = ("%s/%s" % (plugin_rel, path) if os.path.isfile(on_disk)
                    else "%s/%s/%s" % (plugin_rel, path, rel))
        print("\t".join((component.get("id") or "<no id>", ref, git_path,
                         oid if isinstance(oid, str) else repr(oid))))
PY

BASE_RATCHET_PY="$SANDBOX_ROOT/base-evidence-ratchet.py"
cat > "$BASE_RATCHET_PY" <<'PY'
"""The coverage ratchet: what #505 pinned must stay pinned and stay evidenced.

Deliberately NOT inside vendor-check.py's `C-EVIDENCE`. That check validates
every `base_evidence` object that is DECLARED and refuses over an empty set;
demanding universal coverage there would instantly red every `obra/superpowers`
component — all of them pinned at e7a2d16 and none carrying an evidence record,
because their base was established by local diff rather than by blob identity.
That backfill is a separate change (RFC 0019 §7). Register-derived assertions live here,
where V1/V4/V8/V9/V24 already put them.
"""
import json, re, sys

HEX40 = re.compile(r"^[0-9a-f]{40}$")
register = json.load(open(sys.argv[1], encoding="utf-8"))
third = [c for c in register.get("components", [])
         if c.get("origin") == "third-party"]
assert third, "no third-party components declared"

carriers = [c for c in third if isinstance(c.get("base_evidence"), dict)]
assert carriers, ("no component carries base_evidence — V35 would re-derive "
                  "nothing and report agreement over an empty set")

agents = [c for c in third if (c.get("path") or "").startswith("agents/")]
assert agents, "no third-party agent component — the ratchet would be vacuous"

unpinned = sorted(c.get("id") or "<no id>" for c in agents
                  if c.get("vendored_at_commit") == "unknown")
assert not unpinned, ("agent components record an unknown base after #505: %s"
                      % unpinned)

unevidenced = sorted(
    c.get("id") or "<no id>" for c in agents
    if HEX40.match(c.get("vendored_at_commit") or "")
    and not isinstance(c.get("base_evidence"), dict))
assert not unevidenced, ("pinned agent components carry no base_evidence — the "
                         "pin is an assertion again: %s" % unevidenced)
PY

# blob_identity <register-path> — prints a diagnosis and returns 1 on failure.
#
# NEVER SKIPS on a shallow clone. `vendored_ref` is a real commit of this
# repository, so a `--depth=1` checkout cannot resolve it; a row that quietly
# skipped there would leave CI carrying a vacuous copy of this proof, which is
# exactly the string-presence class this suite exists to kill. It fails and says
# `fetch-depth: 0` instead.
blob_identity() {
  local register="$1" rows ref cid git_path want got checked=0
  rows="$(python3 "$BASE_ROWS_PY" "$register" "$REPO_ROOT")" || {
    echo "could not derive base_evidence rows from $register"; return 1; }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if ! git -C "$REPO_ROOT" cat-file -e "$ref^{commit}" 2>/dev/null; then
      echo "vendoring commit $ref is not in this clone — CI needs fetch-depth: 0"
      return 1
    fi
  done <<<"$(cut -f2 <<<"$rows" | sort -u)"
  # Split on TAB explicitly. `for x in $rows` would run once over the whole
  # string under zsh (the recurring EFFORT_FLAG class) and would split on spaces
  # under bash.
  while IFS=$'\t' read -r cid ref git_path want; do
    [ -n "$cid" ] || continue
    checked=$((checked + 1))
    got="$(git -C "$REPO_ROOT" rev-parse "$ref:$git_path" 2>/dev/null || true)"
    if [ "$got" != "$want" ]; then
      echo "$cid: $ref:$git_path resolves to ${got:-<unresolvable>}, base_evidence records $want"
      return 1
    fi
  done <<<"$rows"
  if [ "$checked" -eq 0 ]; then
    echo "no component carries base_evidence — the blob-identity proof asserted nothing"
    return 1
  fi
  echo "$checked"
  return 0
}

# V35 — every recorded blob oid re-derives from git at its vendored_ref.
V35_OUT=""
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  no "V35 $REPO_ROOT is not a git checkout — the blob-identity proof cannot run here"
elif V35_OUT="$(blob_identity "$REGISTER")"; then
  ok "V35 every recorded base blob re-derives from git at its vendored_ref ($V35_OUT file(s))"
else
  no "V35 a recorded base blob does not re-derive: $V35_OUT"
fi

# V36 — the coverage ratchet (see the docstring in $BASE_RATCHET_PY).
if python3 "$BASE_RATCHET_PY" "$REGISTER"; then
  ok "V36 every agent component is pinned, and every pin carries base_evidence"
else
  no "V36 an agent component is unpinned, or a pin has no base_evidence behind it"
fi

# V36b — falsifiability for BOTH rows above, through the `if python3 …; then`
# gate V21/V22/V23 use: a mutation that silently no-ops would leave the copy
# pristine, both oracles green, and the row red for a reason that has nothing to
# do with provenance. Two independent defects are injected into one copy so
# neither oracle can be satisfied by the other's noise.
MUTATED_REGISTER="$SANDBOX_ROOT/mutated-vendor.json"
if python3 - "$REGISTER" "$MUTATED_REGISTER" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding="utf-8"))
agents = [c for c in d.get("components", [])
          if c.get("origin") == "third-party"
          and (c.get("path") or "").startswith("agents/")]
pinned = [c for c in agents if c.get("vendored_at_commit") not in (None, "unknown")]
if not pinned:
    raise SystemExit("no agent component is pinned — unpinning one changes "
                     "nothing and the row would prove nothing")
pinned[0]["vendored_at_commit"] = "unknown"

carriers = [c for c in agents if isinstance(c.get("base_evidence"), dict)
            and isinstance(c["base_evidence"].get("blobs"), dict)
            and c["base_evidence"]["blobs"]]
# Deliberately the LAST carrier, so the flipped oid cannot land on the same
# component as the unpin above and let one defect stand in for two.
if len(carriers) < 2:
    raise SystemExit("fewer than two agent components carry base_evidence blobs "
                     "— the two defects would collide on one entry")
blobs = carriers[-1]["base_evidence"]["blobs"]
key = sorted(blobs)[0]
oid = blobs[key]
if not isinstance(oid, str) or len(oid) != 40:
    raise SystemExit("recorded blob %r for %s is not a 40-hex oid" % (oid, key))
blobs[key] = oid[:-1] + ("0" if oid[-1] != "0" else "1")

json.dump(d, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  V31B_WHY=""
  if blob_identity "$MUTATED_REGISTER" >/dev/null 2>&1; then
    V31B_WHY="the blob-identity proof stayed green over a flipped blob oid"
  fi
  if python3 "$BASE_RATCHET_PY" "$MUTATED_REGISTER" >/dev/null 2>&1; then
    V31B_WHY="${V31B_WHY}${V31B_WHY:+; }the coverage ratchet stayed green over an unpinned agent"
  fi
  if [ -z "$V31B_WHY" ]; then
    ok "V36b a flipped blob oid and an unpinned agent are each refused by name"
  else
    no "V36b $V31B_WHY"
  fi
else
  no "V36b could not mutate the register copy — the probe changed nothing"
fi

echo
echo "== V37-V39: C-EVIDENCE — a declared base_evidence object is well-formed =="

# ---------------------------------------------------------------------------
# WHAT C-EVIDENCE IS FOR, and what it deliberately is NOT.
#
# V35 above re-derives the recorded oids from git. It can only do that for
# evidence that is SHAPED right: a `blobs` map keyed by something other than the
# component's own `files[]`, a `vendored_ref` that is not a commit-ish, or a
# truncated oid all make the row assert less than it appears to while staying
# green — the emitter simply produces fewer rows, or none. `C-EVIDENCE` is the
# offline shape guard that stops that, and it is the checker's job rather than
# this suite's because the checker is what CI runs on every push.
#
# SCOPE, stated because getting it wrong is the obvious mistake: it validates
# every `base_evidence` object that is DECLARED, and refuses over an empty set.
# It does NOT demand that every pinned component carry one. Demanding that would
# instantly red every `obra/superpowers` component pinned at `e7a2d16`, whose
# evidence backfill RFC 0019 §7 assigns to #503/#504 — a check that reds on work
# somebody else owns gets suppressed, and a suppressed check is not a check. The
# coverage ratchet for what #505 itself pinned lives in V36.
#
# It stays PURELY OFFLINE: no `git`, no subprocess, no network. That is what
# makes RFC 0019 §2.3's offline guarantee structural rather than a convention,
# and it is why re-deriving the oids is split out into V35 and into
# `vendor-drift.py --verify-bases`.
# ---------------------------------------------------------------------------

# V37 — C-EVIDENCE exists, is dispatched, and is green on the shipped tree.
# NOT the `--only` vacuity trap (see the V26-V29 header): an id outside
# ALL_CHECKS goes through `die_usage` and exits 2, so a row demanding exit 0 goes
# red while the check does not exist. V38/V39 carry the behavioural weight.
if python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-EVIDENCE >/dev/null 2>&1; then
  ok "V37 C-EVIDENCE is a registered, dispatched check and is green on the shipped tree"
else
  no "V37 C-EVIDENCE is missing, unregistered, or red on the shipped tree"
fi

# V38 — evidence that records no blobs at all. The register still SAYS the base
# was measured; nothing is left to measure it against, so V35 would iterate an
# empty map and report agreement.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    ev = c.get("base_evidence")
    if isinstance(ev, dict) and ev.pop("blobs", None) is not None:
        break
else:
    raise SystemExit("no component carries a base_evidence.blobs map to remove")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-EVIDENCE" "V38 base_evidence with its blobs map removed"
else
  no "V38 could not remove a blobs map — the probe mutated nothing"
fi

# V39 — anti-vacuity. With no `base_evidence` anywhere the loop body never runs,
# and a naive implementation reports success over an empty set — the same trap
# C-BASE, C-HEADER, C-COVER, C-README, C-STANCE and C-REFS each carry a guard
# for. C-BASE stays GREEN here (the pins and their headers are untouched), which
# is what makes this row specific to C-EVIDENCE rather than a second copy of V23.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
stripped = 0
for c in d["components"]:
    if c.pop("base_evidence", None) is not None:
        stripped += 1
if not stripped:
    raise SystemExit("no component carried base_evidence — stripping them all "
                     "changes nothing and the row would prove nothing")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-EVIDENCE" "V39 every base_evidence stripped is red, not vacuously green"
else
  no "V39 could not strip base_evidence — the register declares none"
fi

echo "== V40: the witness-file convention =="

# V40 — a pinned `skills/*` component must be witnessed on its OWN SKILL.md.
#
# THE BLIND SPOT. C-BASE accepts a witness on ANY file of the component, so a pin
# restated only on a locally-added file — one that does not exist upstream at the
# recorded base — passes every check while being uncheckable against upstream by
# anyone. #504 hit this concretely: `skills/using-uberdev/references/configuration.md`
# returns 404 at `e7a2d16`, so a header placed there would pin a base against a
# file upstream never had. Measured on this tree: moving `skills/brainstorm`'s
# header from SKILL.md onto `visual-companion.md` leaves vendor-check.py at rc 0
# with all ten checks green.
#
# SKILL.md is the one file every vendored skill provably shares with upstream, so
# "the witness is on SKILL.md" is the only OFFLINE-checkable proxy for "the
# witness is on a file upstream actually had" — and offline is this guard's whole
# policy (comparing against upstream is vendor-drift.py's job).
#
# Scoped to `skills/*` on purpose. An `agents/*.md` component IS a single file, so
# there is no placement choice to constrain and no SKILL.md to demand — the six
# agents (#505) are covered by C-BASE alone, correctly.
#
# Pure Python over the committed tree, no checker in the loop (the V1/V4/V8/V9
# idiom): a checker that mis-parses the register cannot make this row lie. Written
# to a file once so V40 and V40b run the SAME code — a second transcription is a
# second thing to drift.
V30_PY="$SANDBOX_ROOT/v30.py"
cat > "$V30_PY" <<'PY'
import json, os, re, sys
HEADER = re.compile(r"Vendored from ([^@\s]+)@([0-9a-f]{40})")
plugin = os.path.join(sys.argv[1], "plugins", "uberdev")
d = json.load(open(os.path.join(plugin, "vendor.json"), encoding="utf-8"))
ups = d.get("upstreams", {})
checked, offenders = 0, []
for c in d["components"]:
    if c.get("origin") != "third-party":
        continue
    base = c.get("vendored_at_commit")
    if not base or base == "unknown" or not c["path"].startswith("skills/"):
        continue
    checked += 1
    repo = ups.get(c.get("upstream"), {}).get("repo")
    skill = os.path.join(plugin, c["path"], "SKILL.md")
    try:
        text = open(skill, encoding="utf-8").read()
    except OSError:
        offenders.append("%s: no SKILL.md on disk" % c["id"])
        continue
    m = HEADER.search(text)
    if not (m and m.group(1) == repo and m.group(2) == base):
        offenders.append("%s: SKILL.md does not restate %s@%s"
                         % (c["id"], repo, str(base)[:12]))
assert checked >= 1, "no pinned skills/* component — the row would be vacuous"
assert not offenders, \
    "pinned skill components not witnessed on their own SKILL.md: %s" % offenders
PY
V30_OUT="$(python3 "$V30_PY" "$REPO_ROOT" 2>&1)" && V30_RC=0 || V30_RC=$?
if [ "$V30_RC" -eq 0 ]; then
  ok "V40 every pinned skills/* component is witnessed on its own SKILL.md"
else
  no "V40 a pinned skill component's base is witnessed only off its SKILL.md"
  echo "        output: $(tail -n 1 <<<"$V30_OUT")"
fi

# V40b — the falsifiability arm. Without it V40 is a row that has never been seen
# to fail: `checked >= 1` stops it going vacuously green on a tree with no pinned
# skills, but nothing would show the PLACEMENT half can fail at all. The header is
# MOVED, not deleted, so the component keeps a witness and C-BASE stays green —
# the row must go red on placement alone.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/skills/brainstorm" <<'PY'
import os, sys
comp = sys.argv[1]
skill = os.path.join(comp, "SKILL.md")
lines = open(skill, encoding="utf-8").read().splitlines(True)
moved = [ln for ln in lines if "Vendored from" in ln]
if len(moved) != 1:
    raise SystemExit("expected exactly one header on skills/brainstorm/SKILL.md, "
                     "found %d — the probe would prove nothing" % len(moved))
open(skill, "w", encoding="utf-8").write(
    "".join(ln for ln in lines if "Vendored from" not in ln))
with open(os.path.join(comp, "visual-companion.md"), "a", encoding="utf-8") as fh:
    fh.write(moved[0])
PY
then
  if python3 "$V30_PY" "$SB" >/dev/null 2>&1; then
    no "V40b a witness moved off SKILL.md was accepted — the convention is not enforced"
  else
    ok "V40b a pinned skill witnessed only on a sibling file is rejected"
  fi
else
  no "V40b could not move skills/brainstorm's header — the probe mutated nothing"
fi

echo
echo "== V30-V33: the review point, reconciled against RFC 0019 =="
# Emitted as its own section header because the V10-V29 header above announces
# "falsifiability — mutate one site, demand the NAMED check id" and is never
# closed. These four rows are register/RFC assertions, not checker mutations, so
# without this line the suite's own section labelling would misdescribe them.
#
# All four are pure Python over the committed register and the committed RFC —
# no checker in the loop, no make_sandbox (each sandbox copies the whole plugin
# tree, and nothing here needs one).

VENDOR_RFC_DOC="$REPO_ROOT/docs/rfc/0019-vendored-upstream-policy.md"
[ -r "$VENDOR_RFC_DOC" ] || { echo "FATAL: RFC 0019 missing: $VENDOR_RFC_DOC" >&2; exit 2; }

# V30 — watermark cohesion per upstream.
#
# THE CLASS: a partial re-baseline. A walk advances some of an upstream's
# components and misses others, leaving one upstream described by two different
# review points. Nothing else notices: C-WATERMARK only proves each value is
# 40 hex and an ISO date, and vendor-drift.test.sh's git stub returns a single
# SHA for every repo, so its D1 row never compares components to each other.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ups = d["upstreams"]
by_up = {}
for c in d["components"]:
    u = c.get("upstream")
    if u:
        by_up.setdefault(u, []).append(c)
# Anti-vacuity: an emptied or renamed register must red here, not sail through.
declared = {u: cs for u, cs in by_up.items() if "last_reviewed_commit" in ups.get(u, {})}
assert len(declared) >= 2, (
    "expected >= 2 upstreams carrying last_reviewed_commit, found %d" % len(declared))
for u, cs in sorted(declared.items()):
    assert cs, "upstream %s is declared by no component" % u
    want = ups[u]["last_reviewed_commit"]
    for c in cs:
        got = c.get("last_reviewed_upstream_commit")
        assert got == want, (
            "component %s carries watermark %s but upstream %s was reviewed at %s"
            % (c["id"], got, u, want))
PY
then ok "V30 every component's watermark equals its own upstream's review point"
else no "V30 a component's watermark disagrees with its upstream's review point"
fi

# V31 — the review point is reconciled against RFC 0019 (the V24 idiom).
#
# THE CLASS: the register advances and the policy prose does not, so the RFC a
# reviewer reads to decide whether a watermark is trustworthy describes a review
# that no longer exists. This row is what makes the next delta cheap to catch:
# at v6.4.0 the register moves and the RFC must move with it or this reds.
if python3 - "$REGISTER" "$VENDOR_RFC_DOC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rfc = open(sys.argv[2], encoding="utf-8").read()
labelled = {u: m for u, m in d["upstreams"].items() if m.get("last_reviewed_release")}
# Anti-vacuity: zero release labels is a failure, not a pass. Without this arm,
# deleting every last_reviewed_release would make the loop below iterate over
# nothing and report success.
assert labelled, "no upstream carries last_reviewed_release — nothing to reconcile"
for u, meta in sorted(labelled.items()):
    rel = meta["last_reviewed_release"]
    assert rel in rfc, (
        "RFC 0019 never names %s, the release %s was reviewed at" % (rel, u))
    sha = meta.get("last_reviewed_commit", "")
    assert len(sha) == 40, "upstream %s: last_reviewed_commit is not 40 hex" % u
    assert sha[:12] in rfc, (
        "RFC 0019 never names %s, the commit %s was reviewed at" % (sha[:12], u))
PY
then ok "V31 every labelled upstream review point is named by RFC 0019"
else no "V31 an upstream review point is not reconciled against RFC 0019"
fi

# V32 — every verdict row in an RFC adjudication table carries exactly one
# verdict token, and every ADOPT cites an issue.
#
# THE CLASS: a walk that advances the watermark while quietly dropping a path
# out of its own table, or an ADOPT with no filed issue behind it — the two ways
# "adjudicated, not inherited" degrades into "inherited, with a table".
if python3 - "$VENDOR_RFC_DOC" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
TOKENS = ("ADOPT", "SKIP", "DECLINED", "DEFERRED")

def cells(line):
    # Split on UNESCAPED pipes only. RFC 0019 legitimately carries `\|` inside
    # backticked commands in a reasoning cell (the `git worktree list \| grep`
    # row in the 6.1.0->6.2.0 table). A naive line.split("|") sees an extra
    # field there, so any parser that gates a row on "cell count == header cell
    # count" would silently drop that row — and it is the single most
    # consequential row in that table.
    parts = re.split(r'(?<!\\)\|', line)
    if parts and not parts[0].strip():
        parts = parts[1:]
    if parts and not parts[-1].strip():
        parts = parts[:-1]
    return [p.strip() for p in parts]

runs, cur = [], []
for line in lines:
    if line.lstrip().startswith("|"):
        cur.append(line)
    else:
        if cur:
            runs.append(cur)
        cur = []
if cur:
    runs.append(cur)

checked_tables = 0
checked_rows = 0
for run in runs:
    header = cells(run[0])
    if "Verdict" not in header:
        continue
    idx = header.index("Verdict")
    checked_tables += 1
    for line in run[1:]:
        row = cells(line)
        if all(re.fullmatch(r':?-{3,}:?', c or '-') for c in row):
            continue  # delimiter row
        assert idx < len(row), "row has no Verdict cell: %s" % line[:90]
        # Scan the VERDICT CELL ONLY. Reasoning cells legitimately contain
        # lowercase prose like "skipped as already covered" and "not declined".
        cell = row[idx]
        hits = [t for t in TOKENS if re.search(r'\b%s\b' % t, cell)]
        assert len(hits) == 1, (
            "expected exactly one verdict token, found %s in cell %r" % (hits, cell))
        if hits[0] == "ADOPT":
            assert re.search(r'#\d+', cell), (
                "ADOPT with no filed issue cited: %r" % cell)
        checked_rows += 1

# Anti-vacuity, mirroring C-REFS' own vacuity arm: finding no qualifying table,
# or a qualifying table with no data rows, is a failure. Otherwise renaming the
# "Verdict" header would turn this row into a permanent green that checks
# nothing.
assert checked_tables >= 1, "no RFC table has a Verdict column — nothing adjudicated"
assert checked_rows >= 1, "a Verdict table was found but it has no data rows"
print("V32 corpus: %d table(s), %d verdict row(s)" % (checked_tables, checked_rows))
PY
then ok "V32 every RFC verdict row carries one token, and every ADOPT cites an issue"
else no "V32 an RFC verdict row is missing a token, is ambiguous, or is an uncited ADOPT"
fi

# V33 — review-date floor.
#
# THE CLASS: "advanced the SHA, forgot the date". A component sitting at its
# upstream's current review point must have been reviewed no earlier than that
# point. A component reviewed AHEAD of it is legal and stays legal — a single
# component can be re-reviewed early, out of band, before the next whole-upstream
# walk moves everything else — so this is a floor, not an equality.
if python3 - "$REGISTER" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ups = d["upstreams"]
ISO = re.compile(r'^\d{4}-\d{2}-\d{2}$')
compared = 0
for c in d["components"]:
    u = c.get("upstream")
    if not u or "last_reviewed_commit" not in ups.get(u, {}):
        continue
    if c.get("last_reviewed_upstream_commit") != ups[u]["last_reviewed_commit"]:
        continue
    floor = ups[u].get("last_reviewed_on", "")
    got = c.get("last_reviewed_on", "")
    # Validate the shape before comparing: ISO strings compare lexicographically
    # ONLY while they are well-formed, and a malformed date would otherwise
    # compare as "greater" and pass.
    assert ISO.match(floor), "upstream %s: last_reviewed_on %r is not ISO" % (u, floor)
    assert ISO.match(got), "component %s: last_reviewed_on %r is not ISO" % (c["id"], got)
    assert got >= floor, (
        "component %s was reviewed %s but sits at %s's %s review point"
        % (c["id"], got, u, floor))
    compared += 1
# Anti-vacuity: if no component sits at its upstream's review point, this row
# asserted nothing.
assert compared >= 1, "no component sits at its upstream's review point — nothing compared"
PY
then ok "V33 no component sits at its upstream's review point with an older review date"
else no "V33 a component carries a review date older than the review point it sits at"
fi

echo
echo "== V44-V46: every measurement records the basis it was taken under (#534) =="

# ---------------------------------------------------------------------------
# THE CLASS (#534). `measured_diff_lines` was a BARE INTEGER. A diff count has
# two operands — an upstream revision and a set of local bytes — and the register
# recorded neither, so the number could not say whether it disagreed with the
# copy in RFC 0019 §4.2/§4.3 because one of them was stale or because the two
# were honest measurements taken at different points. Two components had already
# drifted that way. `measured_diff_basis` is now a required record naming both
# operands, and `C-MEASURE` is its offline shape guard.
#
# The basis is only half the fix. A recorded basis nobody reads still leaves the
# two copies free to drift, so the rows split three ways:
#
#   V44/V44b — the COMPARATOR. Register and RFC must agree wherever they
#              measured the same revision, and the comparator must be
#              falsifiable.
#   V45      — the checker (shape): `C-MEASURE` reds for an unbased measurement.
#   V46      — git: the local operand really resolves in this history.
#
# Re-deriving a count from scratch needs the upstream bytes, which is
# `vendor-drift.py`'s network job — no row here claims it.
# ---------------------------------------------------------------------------

# V44 — THE COMPARATOR. The register and RFC 0019 must agree wherever they
# measured the same revision.
#
# THE CLASS: one measurement, N uncompared copies. `measured_diff_lines` lives
# in the register and again in every `Diff lines` table of RFC 0019. Nothing
# compared them, so `skills/systematic-debugging` (195 vs 83) and
# `skills/test-driven-development` (64 vs 72) drifted apart with the whole suite
# green — and a reader could not tell a stale copy from two honest measurements
# taken at different points.
#
# WHAT THIS ROW PINS, AND WHAT IT CANNOT. It pins AGREEMENT BETWEEN TWO ON-DISK
# COPIES, not the truth of either: re-deriving a diff count needs the upstream
# bytes, which is `vendor-drift.py`'s networked job (RFC 0019 § "The weekly
# drift job"), and no amount of internal agreement makes a wrong number right.
# Two copies that agree are still falsifiable by one command; two copies that
# disagree silently are not.
#
# A ROW WHOSE REVISION NOTHING IS BASED AT IS VALUE-UNCHECKED, BY DESIGN.
# §4.2's 14 cells are exactly that today: no register component sits at
# `v6.2.0` any more, so their integers are settled by the #534 amendment's
# re-measurement rather than by comparison. What still binds them is that their
# row ids must resolve, and that the components they name must reconcile
# against SOME row that names them — the anti-escape-hatch arm below, which is
# what stops "record a different basis" from being a way out of the comparison.
#
# THE REGISTER->RFC DIRECTION IS DELIBERATELY ABSENT. Asserting
# `set(register measurements) == union(RFC row ids)` holds only at today's
# 20-for-20 and welds a LIVE register to two FROZEN dated tables: vendoring a
# new component would red a guard that then gets suppressed, even though a new
# component legitimately has no row in a table dated before it existed. The
# direction that IS asserted — every frozen RFC row resolves to a measured
# register component — is the one that catches a silent deletion, and it carries
# a reviewed allow-list for the only legitimate exception (retirement).
MEASURE_RECONCILE_PY="$SANDBOX_ROOT/measure-reconcile.py"
cat > "$MEASURE_RECONCILE_PY" <<'PY'
"""Reconcile `measured_diff_lines` against every `Diff lines` table in RFC 0019.

argv: <vendor.json> <rfc-0019.md>.  Exit 0 = the two copies agree.

Written to a file rather than inlined so V44 and all eight V44b mutations drive
the IDENTICAL predicate — a mutation that reds a re-typed near-copy proves
nothing about the row that guards the real tree (V24b's shape).
"""
import json, re, sys

# Frozen RFC rows whose component the register no longer carries. STARTS EMPTY,
# and is the only sanctioned way a row may resolve to nothing: retiring a
# vendored component then costs one reviewed line here, instead of producing a
# mystery red on unrelated work — which is how a guard gets relaxed until it
# means nothing.
RETIRED_ROWS = set()

# The row floor is a RATCHET over the frozen tables: 14 rows in §4.2, 6 in §4.3
# and 14 in the #534 amendment's re-measurement table. Deliberately a floor and
# not an equality, so vendoring a component, retiring one, or appending a future
# amendment table can never red it; a DELETED row is what it exists to catch.
ROW_FLOOR = 34

# One grammar, three call sites (§4.2, §4.3, the #534 amendment). `rev` is None
# exactly when the table declares its revision per-row instead, in a `Base`
# column — §4.3 does, because that upstream ships no release vocabulary and
# inventing a tag for it would be the fabrication this register exists to stop.
LABEL_RE = re.compile(
    r'^\*\*Measured:\*\* `(?P<upstream>[^`]+)` at '
    r'(?:`(?P<rev>[^`]+)`|the per-row `Base` column), '
    r'on (?P<on>\d{4}-\d{2}-\d{2}), '
    r'counting (?P<rule>[^.]+)\.$')
HEADING_RE = re.compile(r'^#{1,6} ')
HEX_RE = re.compile(r'^[0-9a-f]{7,40}$')
DELIM_RE = re.compile(r':?-{3,}:?')


def cells(line):
    # Copied VERBATIM from V32's table parser (the "every verdict row carries
    # one token" row) — a DECLARED duplication, because the two rows must never
    # disagree about what a cell is. Split on UNESCAPED pipes only: RFC 0019
    # legitimately carries `\|` inside backticked commands in a reasoning cell,
    # and a naive split sees an extra field there.
    parts = re.split(r'(?<!\\)\|', line)
    if parts and not parts[0].strip():
        parts = parts[1:]
    if parts and not parts[-1].strip():
        parts = parts[:-1]
    return [p.strip() for p in parts]


def unbacktick(cell):
    m = re.fullmatch(r'`([^`]+)`', cell)
    return m.group(1) if m else None


def same_basis(row_rev, reg_rev):
    """Two revisions name the same point.

    Exact for a `vX.Y.Z` tag. For hex, an RFC cell may abbreviate what the
    register spells in full (§4.3's `Base` column reads `4ca561f`), so a prefix
    match is allowed — with a 7-character floor, below which a prefix stops
    identifying a commit at all.
    """
    if row_rev == reg_rev:
        return True
    if HEX_RE.match(row_rev) and HEX_RE.match(reg_rev):
        return reg_rev.startswith(row_rev) or row_rev.startswith(reg_rev)
    return False


register = json.load(open(sys.argv[1], encoding="utf-8"))
lines = open(sys.argv[2], encoding="utf-8").read().splitlines()

by_id = {c["id"]: c for c in register.get("components", []) if c.get("id")}

# Pipe-table runs, each carrying the line index it starts at (the label scan
# needs to walk upward from exactly there).
runs, cur, start = [], [], 0
for i, line in enumerate(lines):
    if line.lstrip().startswith("|"):
        if not cur:
            start = i
        cur.append(line)
    else:
        if cur:
            runs.append((start, cur))
        cur = []
if cur:
    runs.append((start, cur))


def label_for(table_start):
    """The table's own `**Measured:**` line, BOUNDED TO ITS OWN SECTION.

    Walks upward from the table and stops at the first heading. An unbounded
    scan is the one mutation that goes silently wrong: delete §4.3's label and
    the walk would run on into §4.2 and adopt `v6.2.0` as §4.3's basis — a table
    would then be reconciled against a revision it was never measured at, with
    nothing red. So a `Diff lines` table with no label inside its own section is
    a HARD FAILURE, never an inherited one.

    TWO labels in one section is a hard failure for the same reason and not an
    oversight: the pair does not say which one this table was measured under.
    An amendment wanting a second labelled `Diff lines` table gives it its own
    heading — as the #534 one does — rather than relaxing this to "the nearest".
    """
    window = []
    j = table_start - 1
    while j >= 0 and not HEADING_RE.match(lines[j]):
        window.append(lines[j].strip())
        j -= 1
    found = [w for w in window if w.startswith("**Measured:**")]
    if len(found) != 1:
        return None, ("%d `**Measured:**` label(s) in its own section, expected 1"
                      % len(found))
    m = LABEL_RE.match(found[0])
    if not m:
        return None, "its `**Measured:**` label does not parse: %r" % found[0][:110]
    return m, ""


problems = []
tables = rows = compared = allowed = 0
# Component id -> every revision a frozen row names it at, and the ids that
# actually reconciled against one of them. The anti-escape-hatch arm below is
# the difference between these two sets.
named_at = {}
reconciled = set()

for table_start, run in runs:
    header = cells(run[0])
    if "Diff lines" not in header:
        continue
    tables += 1
    where = "the `Diff lines` table at line %d" % (table_start + 1)
    # Resolve the column BY HEADER NAME, never by index: `Diff lines` is column
    # 2 in §4.2, 3 in §4.3 and 3 in the amendment's table, so a hardcoded index
    # would silently read §4.3's `Base` column and compare a commit to an int.
    if header.count("Diff lines") != 1:
        problems.append("%s declares %d `Diff lines` columns"
                        % (where, header.count("Diff lines")))
        continue
    idx = header.index("Diff lines")
    base_idx = None
    if "Base" in header:
        if header.count("Base") != 1:
            problems.append("%s declares %d `Base` columns" % (where, header.count("Base")))
            continue
        base_idx = header.index("Base")

    label, why = label_for(table_start)
    if label is None:
        problems.append("%s carries no usable basis: %s" % (where, why))
        continue
    table_rev = label.group("rev")
    if table_rev is None and base_idx is None:
        problems.append("%s declares its revision per-row but has no `Base` column" % where)
        continue

    for line in run[1:]:
        row = cells(line)
        if row and all(DELIM_RE.fullmatch(c or '-') for c in row):
            continue  # delimiter row
        rows += 1
        rid = unbacktick(row[0]) if row else None
        if rid is None:
            problems.append("%s: row %r does not open with a backticked component id"
                            % (where, line[:70]))
            continue
        row_rev = table_rev
        if base_idx is not None:
            if base_idx >= len(row):
                problems.append("%s: row `%s` has no `Base` cell" % (where, rid))
                continue
            row_rev = unbacktick(row[base_idx]) or row[base_idx]
        if not row_rev:
            problems.append("%s: row `%s` names no revision" % (where, rid))
            continue
        if idx >= len(row) or not re.fullmatch(r'\d+', row[idx]):
            problems.append("%s: row `%s` has no integer `Diff lines` cell" % (where, rid))
            continue
        value = int(row[idx])

        component = by_id.get(rid)
        recorded = component.get("measured_diff_lines") if component else None
        # `isinstance(True, int)` is True in Python, so a `true` slipped into the
        # count would otherwise read as a measurement of 1 and compare cleanly
        # against nothing. C-MEASURE rejects it too; neither guard is the other's
        # excuse for reading a bool as a number.
        if not isinstance(recorded, int) or isinstance(recorded, bool):
            if rid in RETIRED_ROWS:
                allowed += 1
            else:
                problems.append(
                    "%s: row `%s` resolves to no measured component in the register "
                    "(retire it in RETIRED_ROWS if that is deliberate)" % (where, rid))
            continue
        basis = component.get("measured_diff_basis")
        if not isinstance(basis, dict) or not isinstance(basis.get("upstream_rev"), str):
            problems.append("register component `%s` records a measurement with no "
                            "`measured_diff_basis.upstream_rev` to reconcile against" % rid)
            continue
        named_at.setdefault(rid, set()).add(row_rev)
        if not same_basis(row_rev, basis["upstream_rev"]):
            continue  # different bases, both labelled — correctly not compared
        reconciled.add(rid)
        compared += 1
        if value != recorded:
            problems.append("`%s` at %s: the RFC says %d and the register says %d"
                            % (rid, row_rev, value, recorded))

# THE BASIS IS A RECONCILIATION RULE, NOT AN ESCAPE HATCH. The `continue` above
# is a legitimate "different bases, correctly not compared" — and it is also the
# only door out of the comparison. Re-base a register measurement onto a
# revision no frozen row declares, or re-rev a table's own `**Measured:**` line,
# and every row naming that component silently stops being checked while
# `compared >= 1` stays satisfied by the rows either side of it: a fabricated
# `measured_diff_lines` then ships green. So a component the frozen tables NAME,
# and which carries a measurement, must reconcile against AT LEAST ONE of the
# rows that name it.
#
# This is not the register->RFC welding rejected above: a newly vendored
# component that no frozen table names is untouched. Only a component the RFC
# already froze is held to it, and re-measuring one legitimately arrives with an
# amendment table — the #534 table under §4.2 is exactly that — which is the row
# that satisfies this arm. Re-measuring WITHOUT amending the RFC is the case it
# exists to red, and that case is the defect this whole row was written for.
for rid in sorted(named_at):
    if rid in reconciled:
        continue
    problems.append(
        "register component `%s` is measured at `%s`, a revision none of the "
        "frozen rows naming it declare (%s) — a basis matching no RFC copy "
        "removes the component from reconciliation instead of disagreeing with it"
        % (rid, by_id[rid]["measured_diff_basis"]["upstream_rev"],
           ", ".join("`%s`" % r for r in sorted(named_at[rid]))))

if problems:
    raise SystemExit("measurement reconciliation failed:\n  - " + "\n  - ".join(problems))

# ANTI-VACUITY. Every arm below is the difference between "checked" and "found
# nothing to check": renaming a header, deleting a table, deleting a row or
# re-basing every measurement would each empty the loop above and report success.
if tables < 2:
    raise SystemExit("found %d `Diff lines` table(s) in the RFC, expected at least 2 "
                     "(§4.2 and §4.3) — the corpus has been renamed away" % tables)
if rows < ROW_FLOOR:
    raise SystemExit("found %d `Diff lines` row(s), below the floor of %d — a frozen "
                     "measurement row has been deleted" % (rows, ROW_FLOOR))
if compared < 1:
    raise SystemExit("no RFC row shares a revision with the register measurement it "
                     "names — nothing was reconciled")

print("V44 corpus: %d table(s), %d row(s), %d compared, %d allow-listed"
      % (tables, rows, compared, allowed))
PY

if python3 "$MEASURE_RECONCILE_PY" "$REGISTER" "$VENDOR_RFC_DOC"; then
  ok "V44 register and RFC 0019 agree wherever they measured the same revision"
else
  no "V44 a measurement disagrees with its RFC copy, or a copy lost its basis"
fi

# V44b — THE COMPARATOR IS FALSIFIABLE. V44 alone would pass just as happily if
# it parsed nothing, so the same predicate is driven against eight mutated copies
# and each one MUST red. Staying green after a mutation is reported as a `no`
# naming which mutation, because a comparator that cannot fail is the uncompared
# state with extra output.
V44B_MUTATE_PY="$SANDBOX_ROOT/measure-mutate.py"
cat > "$V44B_MUTATE_PY" <<'PY'
"""Emit the eight V44b mutated copies. argv: <vendor.json> <rfc.md> <outdir>.

Each mutation asserts it actually changed something: a probe that mutates
nothing makes the row below assert nothing, which is the failure mode this
whole suite exists to kill.
"""
import json, os, re, sys

reg_path, rfc_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
rfc_lines = open(rfc_path, encoding="utf-8").read().splitlines(True)


def load_register():
    return json.load(open(reg_path, encoding="utf-8"))


def find_component(register, cid):
    for c in register["components"]:
        if c.get("id") == cid:
            return c
    raise SystemExit("mutation target %s is not in the register" % cid)


def write_register(register, name):
    json.dump(register, open(os.path.join(out, name), "w", encoding="utf-8"),
              indent=2, ensure_ascii=False)


def write_rfc(lines, name):
    open(os.path.join(out, name), "w", encoding="utf-8").write("".join(lines))


def only_match(pattern, what):
    hits = [i for i, l in enumerate(rfc_lines) if re.search(pattern, l)]
    if len(hits) != 1:
        raise SystemExit("expected exactly 1 line matching %s (%s), found %d"
                         % (pattern, what, len(hits)))
    return hits[0]


def bump_measurement(cid, name):
    register = load_register()
    component = find_component(register, cid)
    before = component.get("measured_diff_lines")
    if not isinstance(before, int):
        raise SystemExit("%s records no measured_diff_lines to bump" % cid)
    component["measured_diff_lines"] = before + 1
    write_register(register, name)


def rebase_measurement(cid, rev, name):
    """Relabel a measurement's basis WITHOUT touching the number it recorded."""
    register = load_register()
    component = find_component(register, cid)
    basis = component.get("measured_diff_basis")
    if not isinstance(basis, dict) or "upstream_rev" not in basis:
        raise SystemExit("%s records no basis to re-base" % cid)
    if basis["upstream_rev"] == rev:
        raise SystemExit("%s is already based at %s — the mutation would change "
                         "nothing" % (cid, rev))
    basis["upstream_rev"] = rev
    write_register(register, name)


# A well-formed 40-hex revision that is deliberately NOT a commit and, asserted
# below, appears nowhere in the RFC — so nothing can reconcile against it from
# either side. Mutations 7 and 8 need exactly that: an orphan basis. The V44b
# driver greps for its prefix, so changing this literal moves that one too.
ORPHAN_REV = "decafbad" * 5
if ORPHAN_REV in "".join(rfc_lines):
    raise SystemExit("ORPHAN_REV %s is declared in the RFC — mutations 7 and 8 "
                     "would not be orphans" % ORPHAN_REV)


# 1 + 2 — the VALUE arm, once per direction of the corpus. The agent bites on
# §4.3 (which keys on its per-row `Base` column) and the skill on the #534
# amendment's table, so both halves of the comparison are proved live: the new
# numbers really are a checked copy, not a third uncompared one.
bump_measurement("agents/code-reviewer.md", "reg-agent-value.json")
bump_measurement("skills/brainstorm", "reg-skill-value.json")

# 3 — a deleted frozen row. Nothing else notices: the remaining rows still agree
# and still resolve, so only the monotone row floor can catch it. Pinned by its
# upstream-path cell — the id alone also matches the base-recovery table in the
# 2026-08-13 (#503) amendment, which is not a `Diff lines` table at all.
i = only_match(r'^\| `agents/code-simplifier\.md` \| `plugins/code-simplifier/',
               "§4.3's code-simplifier row")
write_rfc(rfc_lines[:i] + rfc_lines[i + 1:], "rfc-row-deleted.md")

# 4 — §4.3's label deleted: THE BOUNDED-SCAN ROW. An unbounded upward scan walks
# out of §4.3, finds §4.2's `v6.2.0` label and reconciles §4.3's rows against a
# revision they were never measured at. Verified both ways while writing this:
# under an unbounded scan the mutated copy stays GREEN at 20 compared (§4.3's
# rows key on their own `Base` column, so they keep matching), and only the
# bounded scan's "no label in its own section" failure catches it.
i = only_match(r'^\*\*Measured:\*\* `claude-plugins-official` at the per-row',
               "§4.3's label")
write_rfc(rfc_lines[:i] + rfc_lines[i + 1:], "rfc-label-deleted.md")

# 5 — a frozen row pointed at a component the register does not carry. Proves
# the resolution arm bites AND that RETIRED_ROWS is empty: were it pre-loaded,
# this would be allow-listed into silence. The §4.2 row is pinned by its
# upstream-path cell, which no other table carries.
i = only_match(r'^\| `skills/write-plan` \| `skills/writing-plans` \|',
               "§4.2's write-plan row")
write_rfc(rfc_lines[:i]
          + [rfc_lines[i].replace("`skills/write-plan`", "`skills/write-plan-retired`", 1)]
          + rfc_lines[i + 1:], "rfc-unknown-id.md")

# 6 + 7 + 8 — the basis key is a RECONCILIATION RULE, NOT AN ESCAPE HATCH, and
# it takes all three to say so. "Record a different basis" has two outcomes and
# only one of them was ever driven:
#
#   6 re-bases onto a revision an RFC table DOES declare (brainstorm's 2358
#     relabelled `v6.2.0`, where §4.2 froze 2255) — the row lands on the
#     conflicting cell and the value arm reds;
#   7 re-bases onto a revision NO table declares. The row lands on nothing:
#     before the anti-escape-hatch arm existed this was green, and a wholly
#     fabricated `measured_diff_lines` rode out with it;
#   8 does the same damage from the RFC side, re-revving the #534 amendment's
#     own label so all 14 re-measured skills stop matching at once. `compared`
#     falls 20 -> 6 and, again, nothing red before the arm existed.
#
# 7 and 8 are the same arm from the two sides that can reach it, exactly as 1
# and 2 drive the value arm once per direction of the corpus.
rebase_measurement("skills/brainstorm", "v6.2.0", "reg-rebased.json")
rebase_measurement("skills/brainstorm", ORPHAN_REV, "reg-orphan-basis.json")

i = only_match(r'^\*\*Measured:\*\* `superpowers` at `[0-9a-f]{40}`',
               "the #534 amendment's label")
write_rfc(rfc_lines[:i]
          + [re.sub(r'`[0-9a-f]{40}`', '`%s`' % ORPHAN_REV, rfc_lines[i], count=1)]
          + rfc_lines[i + 1:], "rfc-orphan-label.md")
PY

V44B_OUT="$SANDBOX_ROOT/v44b"
if V44B_ERR="$(python3 "$V44B_MUTATE_PY" "$REGISTER" "$VENDOR_RFC_DOC" "$V44B_OUT" 2>&1)"; then
  V44B_BAD=""
  V44B_DRIVEN=0
  # $1 what the mutation is, $2 the text the failure MUST carry, $3 register,
  # $4 RFC. Each mutation is bound to the arm it exists to exercise, exactly as
  # `assert_red` binds a checker mutation to a named check id: eight mutations
  # that all red through the same arm would look like eightfold coverage and be
  # one. Herestring, never `printf | grep -q` — see tests/epipe-guard.test.sh.
  v44b_expect_red() {
    local out rc=0
    V44B_DRIVEN=$((V44B_DRIVEN + 1))
    out="$(python3 "$MEASURE_RECONCILE_PY" "$3" "$4" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      V44B_BAD="${V44B_BAD}${V44B_BAD:+; }$1 (stayed GREEN)"
    elif ! grep -qF -- "$2" <<<"$out"; then
      V44B_BAD="${V44B_BAD}${V44B_BAD:+; }$1 (red, but never through: $2)"
    fi
  }
  # Two of the expectations name the REVISION the mutation must bite at, because
  # that is the half being proved. `b36e0829…` appears only in the #534
  # amendment's table, so a failure quoting it is what shows the newly recorded
  # numbers really are a checked copy; `v6.2.0` appears only in §4.2, so a
  # failure quoting THAT is what shows re-basing cannot be used to make a
  # disagreement vanish. Re-measuring either component moves these literals —
  # deliberately, since the rows they pin would need re-reading anyway.
  v44b_expect_red "an agent's recorded count bumped by one" \
    '`agents/code-reviewer.md` at 4ca561f' \
    "$V44B_OUT/reg-agent-value.json" "$VENDOR_RFC_DOC"
  v44b_expect_red "a skill's recorded count bumped by one" \
    '`skills/brainstorm` at b36e0829' \
    "$V44B_OUT/reg-skill-value.json" "$VENDOR_RFC_DOC"
  v44b_expect_red "a frozen RFC measurement row deleted" \
    'below the floor of' \
    "$REGISTER" "$V44B_OUT/rfc-row-deleted.md"
  v44b_expect_red "section 4.3's basis label deleted" \
    'carries no usable basis' \
    "$REGISTER" "$V44B_OUT/rfc-label-deleted.md"
  v44b_expect_red "an RFC row pointed at a component the register does not carry" \
    '`skills/write-plan-retired` resolves to no measured component' \
    "$REGISTER" "$V44B_OUT/rfc-unknown-id.md"
  v44b_expect_red "a measurement re-based onto a revision the RFC declares" \
    '`skills/brainstorm` at v6.2.0' \
    "$V44B_OUT/reg-rebased.json" "$VENDOR_RFC_DOC"
  # 7 and 8 pin the revision that must be REPORTED AS ORPHANED, which is the
  # half being proved: the register's own basis in 7 (`decafbad…`, matching no
  # row) and the untouched `b36e0829…` in 8 (whose only labelled table just
  # stopped declaring it). Quoting the arm's text alone would pass on either.
  v44b_expect_red "a measurement re-based onto a revision no RFC row declares" \
    '`skills/brainstorm` is measured at `decafbad' \
    "$V44B_OUT/reg-orphan-basis.json" "$VENDOR_RFC_DOC"
  v44b_expect_red "the amendment table re-revved out from under its own rows" \
    '`skills/brainstorm` is measured at `b36e0829' \
    "$REGISTER" "$V44B_OUT/rfc-orphan-label.md"
  if [ -n "$V44B_BAD" ]; then
    no "V44b a mutation did not red through its own arm: $V44B_BAD"
  elif [ "$V44B_DRIVEN" -ne 8 ]; then
    no "V44b drove $V44B_DRIVEN mutation(s), expected 8"
  else
    ok "V44b the comparator reds for all $V44B_DRIVEN mutations (value, deleted row, deleted label, unknown id, re-base onto a declared and an undeclared revision, re-revved label)"
  fi
else
  no "V44b could not build the mutated copies — the probes changed nothing: $V44B_ERR"
fi

# V45 — C-MEASURE reds for an unbased measurement, and NAMES ITSELF. Five
# mutations through `assert_red`, which drives the FULL checker: each row
# therefore proves the tree went red *for this check* and not for some other one
# that happens to trip on the same edit.

# V45a — the biconditional. A recorded number whose basis has been deleted is
# the exact pre-#534 state: a claim with no operands behind it.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("id") == "skills/systematic-debugging":
        if "measured_diff_lines" not in c:
            raise SystemExit("skills/systematic-debugging records no measurement")
        if c.pop("measured_diff_basis", None) is None:
            raise SystemExit("skills/systematic-debugging carries no basis to remove")
        break
else:
    raise SystemExit("skills/systematic-debugging is not in the register")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-MEASURE" "V45a a measurement whose basis was deleted"
else
  no "V45a could not delete a measured_diff_basis — the probe mutated nothing"
fi

# V45b — a required member of the record. `upstream_rev` is the operand the
# whole reconciliation turns on: without it the number cannot be compared to any
# other copy of itself, which is how the two live mismatches survived.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("id") == "agents/code-reviewer.md":
        basis = c.get("measured_diff_basis")
        if not isinstance(basis, dict):
            raise SystemExit("agents/code-reviewer.md carries no basis record")
        if basis.pop("upstream_rev", None) is None:
            raise SystemExit("agents/code-reviewer.md's basis records no upstream_rev")
        break
else:
    raise SystemExit("agents/code-reviewer.md is not in the register")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-MEASURE" "V45b a basis missing its upstream_rev"
else
  no "V45b could not remove an upstream_rev — the probe mutated nothing"
fi

# V45c — `upstream_tree` is REQUIRED, not decorative. It names the concrete
# artifact that was diffed, which for the 14 skills is a `claude-plugins-official`
# repackaging rather than `obra/superpowers` itself; `upstream_rev` names only the
# revision that artifact is corroborated to repackage. Drop this member and the
# record silently claims the stronger provenance.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if not (c.get("path") or "").startswith("skills/"):
        continue
    basis = c.get("measured_diff_basis")
    if isinstance(basis, dict) and basis.pop("upstream_tree", None) is not None:
        break
else:
    raise SystemExit("no skill component's basis records an upstream_tree")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-MEASURE" "V45c a basis missing its upstream_tree"
else
  no "V45c could not remove an upstream_tree — the probe mutated nothing"
fi

# V45d — the CLOSED sub-key set, one level down from C-SCHEMA's COMPONENT_KEYS
# and for the same reason: a misspelt member is indistinguishable from an omitted
# one. `mesured_on` sits beside the real key, so every required member is still
# present and only the closed set can catch it.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    basis = c.get("measured_diff_basis")
    if isinstance(basis, dict) and "measured_on" in basis:
        basis["mesured_on"] = basis["measured_on"]
        break
else:
    raise SystemExit("no component's basis records a measured_on to misspell")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-MEASURE" "V45d a misspelt member alongside the real one"
else
  no "V45d could not add a misspelt basis member — the probe mutated nothing"
fi

# V45e — ANTI-VACUITY. Deleting the corpus is the cheapest way to make a
# per-measurement check permanently green, so an empty measured set is a failure
# rather than a pass (C-EVIDENCE's own rule). BOTH keys are stripped on purpose:
# stripping only `measured_diff_lines` would leave 20 orphaned basis records and
# fire the biconditional instead, so the row would go red without ever exercising
# the arm it exists to prove.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
stripped = 0
for c in d["components"]:
    if c.pop("measured_diff_lines", None) is not None:
        stripped += 1
    c.pop("measured_diff_basis", None)
if not stripped:
    raise SystemExit("no component records measured_diff_lines — stripping them "
                     "all changes nothing and the row would prove nothing")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-MEASURE" "V45e every measurement stripped is red, not vacuously green"
else
  no "V45e could not strip the measurements — the register records none"
fi

# V46 — every measurement names UberDev bytes that EXIST IN THIS HISTORY.
#
# `upstream_rev` is checkable only against the network (`vendor-drift.py`), but
# the other operand is ours: `uberdev_rev` must be a commit of this repository
# reachable from HEAD, so `git show <uberdev_rev>:<path>` re-derives the exact
# bytes that were counted. A rev that resolves to nothing records a measurement
# of bytes nobody can produce.
#
# NEVER A SKIP. CI checks out with `fetch-depth: 0` (.github/workflows/test.yml,
# the `checkout` step), so an unresolvable rev is a defect in the register and
# not an artefact of the clone. Converting this row to a skip when git is absent
# or the object is missing would leave CI carrying a green that checks nothing —
# the vacuous-green class this whole suite exists to kill.
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  no "V46 $REPO_ROOT is not a git checkout — the recorded uberdev_rev values cannot be resolved"
else
  V46_ROWS="$(python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d.get("components", []):
    basis = c.get("measured_diff_basis")
    if isinstance(basis, dict) and isinstance(basis.get("uberdev_rev"), str):
        print("%s\t%s" % (c.get("id") or "<no id>", basis["uberdev_rev"]))
PY
)" || V46_ROWS="__ERROR__"
  if [ "$V46_ROWS" = "__ERROR__" ]; then
    no "V46 could not read measured_diff_basis.uberdev_rev out of the register"
  else
    V46_CHECKED=0
    V46_BAD=""
    # Split on TAB explicitly, and never `for x in $V46_ROWS`: zsh runs that loop
    # once over the whole string and bash splits it on spaces.
    while IFS=$'\t' read -r V46_ID V46_REV; do
      [ -n "$V46_ID" ] || continue
      V46_CHECKED=$((V46_CHECKED + 1))
      if ! git -C "$REPO_ROOT" cat-file -e "$V46_REV^{commit}" 2>/dev/null; then
        V46_BAD="$V46_ID: $V46_REV is not a commit of this repository"
        break
      fi
      if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$V46_REV" HEAD 2>/dev/null; then
        V46_BAD="$V46_ID: $V46_REV is not reachable from HEAD — the bytes it claims were measured are not in this history"
        break
      fi
    done <<<"$V46_ROWS"
    if [ -n "$V46_BAD" ]; then
      no "V46 a recorded uberdev_rev does not resolve: $V46_BAD"
    elif [ "$V46_CHECKED" -eq 0 ]; then
      no "V46 no component records measured_diff_basis.uberdev_rev — the row asserted nothing"
    else
      ok "V46 every recorded uberdev_rev is a commit of this repository reachable from HEAD ($V46_CHECKED component(s))"
    fi
  fi
fi

# V47 — the HEAD-only decision is reconciled against RFC 0019 (the V31 idiom,
# mirrored onto the other half of the biconditional).
#
# THE CLASS: V31 reconciles the upstreams that carry a `last_reviewed_release`.
# Every other used upstream now declares `head_only: true` instead (#604 defect
# 3 — the decision used to live in the ABSENCE of a key, where a deletion and a
# policy choice look identical). Nothing made the RFC name those upstreams, so
# an upstream could be flipped to HEAD-only in the register with no adjudication
# behind it at all: a review point that exists only as a JSON key.
#
# SCOPING TO THE AMENDMENT SLICE IS LOAD-BEARING. Both ids already appear
# elsewhere in this document — §4.3's stance table names them — so an unscoped
# "is the id in the RFC" check passes today, before the amendment exists, and
# would keep passing if it were deleted.
if python3 - "$REGISTER" "$VENDOR_RFC_DOC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rfc = open(sys.argv[2], encoding="utf-8").read()
# `is True`, not truthiness: `head_only: "yes"` and `head_only: 1` are register
# defects `validate_release_metadata` (tools/vendor/vendor-drift.py) exits 2 for
# — NOT vendor-check.py, which reads neither release key — and this row must not
# launder them into a pass.
head_only = sorted(u for u, m in d["upstreams"].items() if m.get("head_only") is True)
# Anti-vacuity: zero HEAD-only upstreams is a failure, not a pass. Without this
# arm, stripping the key from the register would make the loop below iterate
# over nothing and report success.
assert head_only, "no upstream declares `head_only: true` — nothing to reconcile"
HEADING = "## Amendment (2026-08-18, #604)"
start = rfc.find(HEADING)
assert start != -1, "RFC 0019 carries no %r heading" % HEADING
rest = rfc[start + len(HEADING):]
end = rest.find("\n## ")
amendment = rest if end == -1 else rest[:end]
# Anti-vacuity: an EMPTY slice makes every membership test below meaningless in
# the one direction they cannot report — the loop would red, but on the wrong
# claim. It goes empty if the heading ever ends the file, or if the `\n## ` cut
# fires on the block's first byte.
#
# There is deliberately no upper bound here. `amendment` is carved out of `rfc`
# at a non-zero offset, so ANY `len(amendment) < len(rfc)` guard holds by
# construction: it would read as a runaway-cut check while being incapable of
# failing. Nor is one needed. The cut is derived from the document — the next
# `## ` heading, whatever it turns out to be — not from a hardcoded end, so the
# slice cannot swallow a later block: it runs to EOF exactly when there is no
# later block to swallow, which is the case today because #604 is the last
# amendment in the file. Append one and the cut tightens on its own.
assert len(amendment) > 0, (
    "the #604 amendment slice is empty (0 of %d bytes)" % len(rfc))
assert "head_only" in amendment, (
    "the #604 amendment never names the `head_only` register key its own "
    "subject is recorded as")
for u in head_only:
    assert u in amendment, (
        "the #604 amendment never names %s, which the register declares "
        "`head_only: true`" % u)
PY
then ok "V47 every head_only upstream is adjudicated inside RFC 0019's #604 amendment"
else no "V47 a head_only upstream is not reconciled against RFC 0019"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

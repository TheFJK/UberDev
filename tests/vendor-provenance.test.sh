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
# sha256 over exact source bytes and no `.gitattributes` exists, so a Windows
# checkout with the default `core.autocrlf=true` rewrites LF->CRLF and every
# digest would differ. That is a property of the checkout, not of the register —
# same reason as tests/prkit-publish.test.sh.
#
# Deliberately does NOT source tests/_lib_assert_structural.sh (so
# tests/test-harness-source-guards.test.sh needs no fail-loud guard here), and
# uses herestrings rather than `printf | grep -q` so tests/epipe-guard.test.sh
# stays green over this file.
set -u
set -o pipefail

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
if [ "$HEADER_COUNT" = "20" ]; then
  ok "V5 C-HEADER: exactly 20 files carry an in-file provenance header"
else
  no "V5 C-HEADER: expected 20 header-carrying files, found $HEADER_COUNT"
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
echo "== V10-V18: falsifiability — mutate one site, demand the NAMED check id =="

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

# V14 — the same edit inside a `fork` component must stay GREEN. This is the row
# that proves the stance distinction is real and not decorative: without it,
# `stance` could be a comment and every other row would still pass.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
FORK_FILE="$(python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["components"]:
    if c.get("stance") == "fork" and c.get("files") and c["path"].startswith("skills/"):
        print("%s/%s" % (c["path"], c["files"][0]))
        break
PY
)"
[ -n "$FORK_FILE" ] || { echo "  ABORT — no fork component with files[] found"; exit 99; }
echo "" >> "$SB/plugins/uberdev/$FORK_FILE"
if python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  ok "V14 one byte changed in a fork-stance file stays green ($FORK_FILE)"
else
  no "V14 a fork-stance edit redded the checker — stance is not operational"
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

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

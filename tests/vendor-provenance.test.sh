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
echo "== V10-V22: falsifiability — mutate one site, demand the NAMED check id =="

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

# ---------------------------------------------------------------------------
# V20-V22: C-REFS — a skill that points at a sibling file which is not there.
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

# V20 — the reference target is deleted and the register is updated to match, so
# register and disk still agree. This is #457's own failure mode: a vendor swap
# that retires a file and leaves the referring document behind.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
REF_TARGET="$SB/plugins/uberdev/skills/test-driven-development/writing-good-tests.md"
[ -e "$REF_TARGET" ] || { echo "  ABORT — V20's target is already absent; the mutation would be a no-op"; exit 99; }
rm -f "$REF_TARGET"
python3 - "$SB/plugins/uberdev/vendor.json" <<'PY' || { echo "  ABORT — V20 register edit failed"; exit 99; }
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("path") != "skills/test-driven-development":
        continue
    before = len(c["files"])
    c["files"] = [f for f in c["files"]
                  if (f.get("path") if isinstance(f, dict) else f) != "writing-good-tests.md"]
    assert len(c["files"]) == before - 1, "writing-good-tests.md was not declared; V20 proves nothing"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_red "$SB" "C-REFS" "V20 a skill reference whose target was removed with the register kept consistent"

# V21 — the target file stays; the reference is misspelled. File set, register,
# headers and counts are all untouched, so C-REFS is the only check that can
# possibly notice.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB/plugins/uberdev/skills/test-driven-development/SKILL.md" <<'PY' || { echo "  ABORT — V21 mutation failed"; exit 99; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n = s.count("](writing-good-tests.md)")
assert n == 1, "expected exactly one markdown link to writing-good-tests.md, found %d" % n
open(p, "w", encoding="utf-8").write(
    s.replace("](writing-good-tests.md)", "](writing-good-tests-typo.md)"))
PY
assert_red "$SB" "C-REFS" "V21 a sibling reference pointing at a name that is not on disk"

# V22 — anti-vacuity, asserted in Python rather than through the checker (same
# design as V1/V3/V4): a checker whose regexes silently match nothing would make
# every row above pass while protecting nothing. The independent scan states the
# corpus is non-empty and fully resolving; the two checker calls then state that
# `C-REFS` is a REGISTERED id, not an `if` arm nobody reaches.
V22_WHY=""
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
then V22_WHY="V22 the independent scan found fewer than 3 sibling references, or an unresolved one"
elif ! python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-REFS >/dev/null 2>&1; then
  V22_WHY="V22 vendor-check.py --only C-REFS is not green on the shipped tree"
else
  BOGUS_RC=0
  BOGUS_OUT="$(python3 "$CHECK" --repo-root "$REPO_ROOT" --only C-BOGUS 2>&1)" || BOGUS_RC=$?
  if [ "$BOGUS_RC" -eq 0 ]; then
    V22_WHY="V22 --only C-BOGUS was accepted; the known-id list is not enforced"
  elif ! grep -q 'C-REFS' <<<"$BOGUS_OUT"; then
    V22_WHY="V22 C-REFS is not in ALL_CHECKS — --only C-BOGUS never listed it among the known ids"
  fi
fi
if [ -z "$V22_WHY" ]; then
  ok "V22 C-REFS: >= 3 resolving sibling references on the shipped tree, and the id is registered"
else
  no "$V22_WHY"
fi

# V22b — the vacuity arm actually fires. Without this row, "a checker that finds
# zero references must fail loud" is prose with no test: the same class as
# check_header's `found == 0` guard, which exists precisely because a scan that
# sees nothing otherwise reports agreement. Every declared third-party markdown
# file is rewritten so no reference SHAPE survives; provenance headers are left
# byte-exact and `track` digests are re-recorded against the mutated bytes, so
# C-HEADER and C-FILES have nothing to say and C-REFS is again the only check
# that can go red.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
python3 - "$SB" <<'PY' || { echo "  ABORT — V22b mutation failed"; exit 99; }
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
assert_red "$SB" "C-REFS" "V22b a tree with no sibling reference at all is red, not vacuously green"

# V23 — the must-STAY-GREEN row, in the same spirit as V14. An `@` that carries a
# local part is an address or a version pin, never a sibling file: an email, an
# npm-style `pkg@1.2.3`, and a `repo@v6.2.0` tag all contain a dotted token that
# a naive `@`-scan reads as a filename (`x@y.com` -> `y.com`), reporting a
# dangling reference against a document that references nothing at all. Appended
# to a fork-stance file so no digest moves and C-REFS is the only check in play;
# drop the lookbehind from AT_REF_RE and this row goes red.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
ADDR_FILE="$SB/plugins/uberdev/skills/test-driven-development/SKILL.md"
python3 - "$ADDR_FILE" <<'PY' || { echo "  ABORT — V23 mutation failed"; exit 99; }
import sys
p = sys.argv[1]
with open(p, "a", encoding="utf-8") as fh:
    fh.write("\nReport problems to maintainer.person@example.com, pin deps as "
             "left-pad@1.2.3, and cite upstream as obra/superpowers@v6.2.0.\n")
PY
if python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  ok "V23 an email, a package pin and a tag pin are not read as sibling references"
else
  no "V23 an address-shaped @-token was read as a sibling file — C-REFS false-positives"
  run_check "$SB" || true
  echo "        output: $(head -c 400 <<<"$CHECK_OUT")"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

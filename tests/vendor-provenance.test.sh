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
if [ "$HEADER_COUNT" = "21" ]; then
  ok "V5 C-HEADER: exactly 21 files carry an in-file provenance header"
else
  no "V5 C-HEADER: expected 21 header-carrying files, found $HEADER_COUNT"
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
echo "== V10-V29: falsifiability — mutate one site, demand the NAMED check id =="

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

# V21 — a fabricated pin on a component that carries no header anywhere.
# `skills/brainstorm` records "unknown" today and no file under it carries a
# provenance header, so a 40-hex literal here is a pure fabrication. THIS EXACT
# PROBE IS GREEN ON main — that is the defect. C-SCHEMA accepts any 40-hex and
# C-HEADER has no header to disagree with, so C-BASE is the only check that can
# see it.
#
# Every mutation below is applied through an `if python3 …; then assert_red`
# gate. A mutation that silently no-ops would leave the sandbox pristine, the
# checker green, and the row red for a reason that has nothing to do with
# C-BASE; the gate makes "the probe could not break anything" say so in its own
# words instead.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
if python3 - "$SB/plugins/uberdev/vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for c in d["components"]:
    if c.get("path") == "skills/brainstorm":
        if c.get("vendored_at_commit") != "unknown":
            raise SystemExit("skills/brainstorm is already pinned — pick another "
                             "headerless component for this row")
        c["vendored_at_commit"] = "deadbeef" * 5
        break
else:
    raise SystemExit("skills/brainstorm is no longer in the register")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
then
  assert_red "$SB" "C-BASE" "V21 a fabricated 40-hex base on a component with no in-file header"
else
  no "V21 could not fabricate a base on skills/brainstorm — the probe mutated nothing"
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
echo "== V24-V25: derived-count and escape-hatch ratchets =="

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
for want in ("the %d unpinned skill directories" % n_skills_unknown,
             "honest value for %d of the 20" % n_unknown_total):
    assert want in rfc, "RFC 0019 does not say %r — the register has moved on" % want
PY
then ok "V24 RFC 0019 §2.2's unpinned counts still match the register"
else no "V24 RFC 0019 §2.2 states an unpinned count the register contradicts"
fi

# V25 — no `track` component excuses a file from the digest lock.
#
# `divergences[]` entries with a non-null `file` are C-FILES' declared-change
# escape hatch (vendor-check.py check_files: `excused` is consulted before the
# sha256 mismatch is reported). On a `fork` component that is the whole point.
# On a `track` component it silently disarms the digest for that file — and
# V13's own mutation target is chosen as the first `track` component carrying
# files[], which is exactly the component this change pins, so one such entry
# would make V13 pass on a mutated tracked file: the ratchet would go quiet
# rather than red.
#
# RFC 0019 §2.3 names the escape hatch deliberately, so deleting it from the
# checker would be an RFC amendment. Pinning it here instead makes it costly to
# adopt on purpose and impossible to adopt by accident. Green today for all
# seven `track` components.
if python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
track = [c for c in d["components"] if c.get("stance") == "track"]
assert track, "no track components — the row would be vacuous"
offenders = [(c["id"], v["file"]) for c in track
             for v in c.get("divergences", []) if v.get("file")]
assert not offenders, \
    "track components carrying a file-scoped digest excuse: %s" % offenders
PY
then ok "V25 no track component excuses a file from the C-FILES digest lock"
else no "V25 a track component carries a file-scoped divergence — the digest lock is disarmed"
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
# dangling reference against a document that references nothing at all. Appended
# to a fork-stance file so no digest moves and C-REFS is the only check in play;
# drop the lookbehind from AT_REF_RE and this row goes red.
SB="$(make_sandbox)" || { echo "  ABORT — sandbox creation failed"; exit 99; }
ADDR_FILE="$SB/plugins/uberdev/skills/test-driven-development/SKILL.md"
python3 - "$ADDR_FILE" <<'PY' || { echo "  ABORT — V29 mutation failed"; exit 99; }
import sys
p = sys.argv[1]
with open(p, "a", encoding="utf-8") as fh:
    fh.write("\nReport problems to maintainer.person@example.com, pin deps as "
             "left-pad@1.2.3, and cite upstream as obra/superpowers@v6.2.0.\n")
PY
if python3 "$CHECK" --repo-root "$SB" >/dev/null 2>&1; then
  ok "V29 an email, a package pin and a tag pin are not read as sibling references"
else
  no "V29 an address-shaped @-token was read as a sibling file — C-REFS false-positives"
  run_check "$SB" || true
  echo "        output: $(head -c 400 <<<"$CHECK_OUT")"
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
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

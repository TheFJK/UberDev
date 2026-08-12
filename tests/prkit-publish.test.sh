#!/usr/bin/env bash
# tests/prkit-publish.test.sh — the prkit PUBLICATION CURRENCY REGISTER.
#
# THE CLASS (#410). `tools/prkit/manifest.txt` names 38 files that are copied
# into a SECOND REPOSITORY, `TheFJK/prkit`. Nothing in this repo recorded what
# the published artifact was actually built from, so every gate here certified
# the SOURCE while the shipped copy drifted arbitrarily far behind it. The
# measured damage at the time this suite was written: the published prkit still
# carried the `trap … RETURN` bug #401 fixed here (dead trap, three leaked temp
# files and three `undefined signal: RETURN` lines per `/merge` discovery call),
# was five files short of the manifest (33 of 38), and still tracked a 54-file
# `codex/` tree that #381 retired. Three separate divergences, none of them
# visible to any test, because "is the downstream copy current?" was not a
# question anything could ask.
#
# `tools/prkit/published.json` answers it: the prkit version last published, the
# sha256 of every copy-set source file as of that publication, and an explicit
# `pending` list of paths knowingly ahead of the published artifact.
# `tools/prkit/published-check.py` compares the record against the live tree.
# P4 below is the row that would have redded #401 the moment the fix landed.
#
# Unix-only, declared in the test.yml windows-skip marker: no `.gitattributes`
# exists in this repo, so the Windows runner's default `core.autocrlf=true`
# rewrites LF→CRLF on checkout and EVERY digest would differ. That is a property
# of the checkout, not of the register.
#
# Deliberately does NOT source tests/_lib_assert_structural.sh — the three
# sibling prkit suites do not either, and tests/test-harness-source-guards.test.sh
# requires a fail-loud guard on any suite that does.
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$REPO_ROOT/tools/prkit/published-check.py"
RECORD="$REPO_ROOT/tools/prkit/published.json"
MANIFEST="$REPO_ROOT/tools/prkit/manifest.txt"
SRC="$REPO_ROOT/plugins/uberdev"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
skip(){ echo "  SKIP  $1"; }

echo "## prkit publication currency register (#410)"

command -v python3 >/dev/null 2>&1 || { echo "  ABORT — python3 required"; exit 99; }
[ -r "$CHECK" ]    || { echo "  ABORT — checker missing: $CHECK"; exit 99; }
[ -r "$RECORD" ]   || { echo "  ABORT — record missing: $RECORD"; exit 99; }
[ -r "$MANIFEST" ] || { echo "  ABORT — manifest missing: $MANIFEST"; exit 99; }

# ---------------------------------------------------------------------------
# P1–P4 drive the REAL committed record. They never call `--refresh`, so the
# checker's own producer can never be both the thing under test and its oracle.
# ---------------------------------------------------------------------------

# P1 — record shape, asserted DIRECTLY rather than through the checker.
if python3 - "$RECORD" <<'PY'
import json, re, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(rec, dict), "record is not an object"
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", rec.get("prkit_version", "")), \
    "prkit_version is not SemVer"
cs = rec.get("copyset")
assert isinstance(cs, list) and cs, "copyset is not a non-empty list"
for e in cs:
    assert isinstance(e, dict) and set(e) == {"path", "sha256"}, f"bad entry: {e!r}"
    assert isinstance(e["path"], str) and e["path"], "empty path"
    assert re.fullmatch(r"[0-9a-f]{64}", e["sha256"]), f"bad digest for {e['path']}"
pend = rec.get("pending")
assert isinstance(pend, list) and all(isinstance(p, str) for p in pend), \
    "pending is not a list of strings"
PY
then ok "P1 published.json has the declared record shape"
else no "P1 published.json shape is wrong (see the assertion above)"
fi

# P2 — the recorded copy set is EXACTLY the manifest, both directions, and the
# count is the same 39 that prkit-manifest.test.sh M2 and prkit-generate.test.sh
# G3 lock. One direction alone would let a manifest entry drop silently out of
# enforcement (or a record key survive a manifest deletion).
if python3 - "$RECORD" "$MANIFEST" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
recorded = {e["path"] for e in rec["copyset"]}
manifest = set()
with open(sys.argv[2], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n").rstrip("\r").strip()
        if line and not line.startswith("#"):
            manifest.add(line)
missing = sorted(manifest - recorded)
extra = sorted(recorded - manifest)
assert not missing, f"in manifest, absent from record: {missing}"
assert not extra, f"in record, absent from manifest: {extra}"
assert len(recorded) == 43, f"copyset has {len(recorded)} paths (expected 43)"
PY
then ok "P2 the record's copy set is exactly the 43-entry manifest, both directions"
else no "P2 record and manifest disagree about the copy set"
fi

# P3 — every recorded path still resolves to a readable regular file. A rename
# that updated the manifest but not the record would otherwise drop a file out
# of digest enforcement while every other row stayed green.
P3_BAD=""
while IFS= read -r p3_path; do
  [ -n "$p3_path" ] || continue
  [ -f "$SRC/$p3_path" ] && [ -r "$SRC/$p3_path" ] \
    || P3_BAD="$P3_BAD $p3_path"
done <<EOF_P3
$(python3 -c 'import json,sys;[print(e["path"]) for e in json.load(open(sys.argv[1],encoding="utf-8"))["copyset"]]' "$RECORD")
EOF_P3
if [ -z "$P3_BAD" ]; then
  ok "P3 every recorded path resolves to a readable file under plugins/uberdev/"
else
  no "P3 recorded paths do not resolve:$P3_BAD"
fi

# P4 — THE GATE. The committed tree must agree with the committed record, or a
# path must be declared pending. This is the row that reds when an UberDev fix
# lands in a copy-set file and prkit has not been regenerated — exactly the #401
# situation this issue is about.
P4_OUT=""
if P4_OUT="$(python3 "$CHECK" 2>&1)"; then
  ok "P4 the committed tree matches the committed publication record"
else
  no "P4 the publication record is stale — regenerate prkit or declare pending:"
  printf '        %s\n' "$P4_OUT"
fi

# ---------------------------------------------------------------------------
# P5–P10 drive a FIXTURE: a 3-entry mini copy set with its own manifest and its
# own record, seeded by `--refresh`. `lib/secret-scan.sh` is in the fixture on
# purpose — it is the manifest entry whose name plus a 64-hex digest is what
# gitleaks scores as `generic-api-key` (see P10/P11).
# ---------------------------------------------------------------------------
FIXP="$(mktemp -d)"
trap 'rm -rf "$FIXP"' EXIT
FIX_SRC="$FIXP/src"
FIX_MANIFEST="$FIXP/manifest.txt"
FIX_RECORD="$FIXP/published.json"
FIX_ENTRIES="commands/merge.md
skills/merge-pipeline/lib/discover.sh
lib/secret-scan.sh"

FIX_READY=1
while IFS= read -r fx_rel; do
  [ -n "$fx_rel" ] || continue
  mkdir -p "$FIX_SRC/$(dirname "$fx_rel")"
  cp "$SRC/$fx_rel" "$FIX_SRC/$fx_rel" || FIX_READY=0
done <<EOF_FIX
$FIX_ENTRIES
EOF_FIX
printf '# fixture copy set\n%s\n' "$FIX_ENTRIES" > "$FIX_MANIFEST"

fix_refresh(){
  python3 "$CHECK" --source-root "$FIX_SRC" --manifest "$FIX_MANIFEST" \
    --record "$FIX_RECORD" --refresh --prkit-version 0.1.3 >/dev/null 2>&1
}
fix_check(){
  python3 "$CHECK" --source-root "$FIX_SRC" --manifest "$FIX_MANIFEST" \
    --record "$FIX_RECORD" 2>&1
}
# Rewrite the fixture record's `pending` array to the given JSON list literal.
fix_set_pending(){
  python3 - "$FIX_RECORD" "$1" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
rec["pending"] = json.loads(sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rec, indent=2) + "\n")
PY
}

if [ "$FIX_READY" -ne 1 ] || ! fix_refresh; then
  no "P5-P10 fixture could not be seeded (--refresh failed)"
else
  # P5 — ANTI-VACUITY for P4: prove the comparator really detects a changed
  # file, and names the exact path. Without this, P4 passing proves nothing.
  printf '\n# divergence probe\n' >> "$FIX_SRC/commands/merge.md"
  P5_OUT="$(fix_check)"; P5_RC=$?
  if [ "$P5_RC" -ne 0 ] \
     && grep -qF 'undeclared divergence: commands/merge.md' <<<"$P5_OUT"; then
    ok "P5 the comparator detects a changed source file and names it"
  else
    no "P5 comparator missed a changed file (rc=$P5_RC): $P5_OUT"
  fi

  # P6 — growth: a divergence with an empty `pending` must fail. (Same fixture
  # state as P5; asserted separately because P5 owns "detects", P6 owns
  # "refuses to certify".)
  fix_set_pending '[]'
  P6_OUT="$(fix_check)"; P6_RC=$?
  if [ "$P6_RC" -ne 0 ] && grep -qF 'undeclared divergence' <<<"$P6_OUT"; then
    ok "P6 an undeclared divergence fails the register"
  else
    no "P6 undeclared divergence was certified (rc=$P6_RC): $P6_OUT"
  fi

  # P7 — shrinkage, the other direction: a `pending` entry naming a path that
  # does NOT diverge is a stale declaration, and must red too. A one-directional
  # check would let `pending` accumulate forever and silently exempt real drift
  # (the both-directions inventory discipline from crossplatform-shell-wrappers).
  fix_refresh
  fix_set_pending '["lib/secret-scan.sh"]'
  P7_OUT="$(fix_check)"; P7_RC=$?
  if [ "$P7_RC" -ne 0 ] \
     && grep -qF 'stale declaration, path does not diverge: lib/secret-scan.sh' <<<"$P7_OUT"; then
    ok "P7 a stale pending declaration fails the register"
  else
    no "P7 stale declaration was accepted (rc=$P7_RC): $P7_OUT"
  fi

  # P8 — the register must be USABLE, not merely strict: a divergence that is
  # declared passes, and the summary says how many.
  fix_refresh
  printf '\n# declared divergence probe\n' >> "$FIX_SRC/lib/secret-scan.sh"
  fix_set_pending '["lib/secret-scan.sh"]'
  P8_OUT="$(fix_check)"; P8_RC=$?
  if [ "$P8_RC" -eq 0 ] && grep -qF '1 declared divergence' <<<"$P8_OUT"; then
    ok "P8 a declared divergence passes and is reported"
  else
    no "P8 declared divergence rejected (rc=$P8_RC): $P8_OUT"
  fi

  # P9 — NON-VACUITY, verify.sh's own discipline: nothing may be "certified
  # clean" off an empty scan. Both the empty-copyset and empty-manifest shapes
  # must refuse rather than report success over zero files.
  fix_refresh
  python3 - "$FIX_RECORD" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
rec["copyset"] = []
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rec, indent=2) + "\n")
PY
  P9A_OUT="$(fix_check)"; P9A_RC=$?
  FIX_MANIFEST_SAVED="$FIXP/manifest.saved"
  cp "$FIX_MANIFEST" "$FIX_MANIFEST_SAVED"
  fix_refresh
  printf '# only comments\n' > "$FIX_MANIFEST"
  P9B_OUT="$(fix_check)"; P9B_RC=$?
  cp "$FIX_MANIFEST_SAVED" "$FIX_MANIFEST"
  if [ "$P9A_RC" -ne 0 ] && grep -qF 'refusing to certify' <<<"$P9A_OUT" \
     && [ "$P9B_RC" -ne 0 ] && grep -qF 'refusing to certify' <<<"$P9B_OUT"; then
    ok "P9 an empty copy set or empty manifest refuses to certify"
  else
    no "P9 vacuous scan certified (copyset rc=$P9A_RC, manifest rc=$P9B_RC): $P9A_OUT | $P9B_OUT"
  fi

  # P10 — THE LAYOUT IS ENFORCED, not accidental. Measured: with `copyset` as a
  # MAP, `"lib/secret-scan.sh": "<64 hex>"` puts the keyword `secret` and a
  # high-entropy hex run on ONE line, which gitleaks scores `generic-api-key`.
  # finish-branch's pre-push scan then HARD-STOPS the push with no --turbo
  # override, so the record could never be pushed at all. The list-of-objects
  # form splits path and digest across lines, and this row keeps a future
  # "simplification" from silently re-arming that trap.
  fix_refresh
  python3 - "$FIX_RECORD" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
rec["copyset"] = {e["path"]: e["sha256"] for e in rec["copyset"]}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(rec, indent=2) + "\n")
PY
  P10_OUT="$(fix_check)"; P10_RC=$?
  P10_REAL_OUT="$(python3 "$CHECK" 2>&1)"; P10_REAL_RC=$?
  if [ "$P10_RC" -ne 0 ] && grep -qF 'digest and path share a line' <<<"$P10_OUT" \
     && [ "$P10_REAL_RC" -eq 0 ]; then
    ok "P10 the digest layout is enforced, and the real record satisfies it"
  else
    no "P10 layout check wrong (fixture rc=$P10_RC, real rc=$P10_REAL_RC): $P10_OUT"
  fi
  fix_refresh
fi

# P11 — GROUND TRUTH for P10: the real record survives the repo's own pre-push
# scanner. SKIPs where gitleaks is absent (CI ubuntu has no gitleaks binary), so
# P10's structural check is the portable half and this is the live half.
if command -v gitleaks >/dev/null 2>&1; then
  P11_OUT=""
  if P11_OUT="$(
       . "$REPO_ROOT/plugins/uberdev/lib/secret-scan.sh" \
         && uberdev_run_secret_scan_stdin < "$RECORD" 2>&1
     )"; then
    ok "P11 published.json passes the live pre-push secret scan"
  else
    no "P11 published.json trips the pre-push secret scan — it cannot be pushed: $P11_OUT"
  fi
else
  skip "P11 live pre-push secret scan (gitleaks not installed on this host)"
fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

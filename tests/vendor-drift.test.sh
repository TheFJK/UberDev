#!/usr/bin/env bash
# tests/vendor-drift.test.sh — the WEEKLY UPSTREAM-DRIFT REPORTER (#434).
#
# THE CLASS. Vendoring forfeits upstream's fixes-for-free. RFC 0019 accepts that
# trade and pays for it with one compensating control: a weekly job that diffs
# each component's recorded watermark against upstream HEAD and keeps ONE issue
# up to date. The control is only worth anything if two properties hold, and
# both of them are the kind that rot silently:
#
#   1. An unreachable upstream must FAIL LOUDLY. If `git ls-remote` errors, or
#      prints nothing, or prints something that is not a 40-hex ref, the job must
#      exit non-zero and mutate nothing. Mapping "unreachable" to "no drift" puts
#      the exact silent-green failure this whole feature exists to kill INSIDE
#      the detector.
#   2. It must file EXACTLY ONE issue. A weekly job that opens a fresh issue per
#      run is indistinguishable from spam, and gets muted — which is the same as
#      not running.
#
# Everything below runs offline against PATH-stubbed `git` and `gh` that log
# every invocation, so "no gh mutation" is asserted from the stub's own ledger
# rather than from reading the source.
#
# ANTI-VACUITY. Rows D6/D7/D8 assert the script exits non-zero. A *missing*
# script also exits non-zero, so they would all pass against nothing at all. The
# preflight therefore hard-stops (exit 2) unless the script exists AND its
# happy path is green — the same guard tests/vendor-provenance.test.sh uses.
#
# Unix-only, declared in the test.yml windows-skip marker block: PATH-stubbed
# executables plus `mktemp -d` paths, the same class as
# tests/merge-discovery-resilience.test.sh.
#
# Deliberately does NOT source tests/_lib_assert_structural.sh, and uses
# herestrings rather than `printf | grep -q` so tests/epipe-guard.test.sh stays
# green over this file.
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIFT="$REPO_ROOT/tools/vendor/vendor-drift.py"
REGISTER="$REPO_ROOT/plugins/uberdev/vendor.json"

PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "## vendored upstream drift reporter (#434)"

command -v python3 >/dev/null 2>&1 || { echo "  ABORT — python3 required"; exit 99; }
[ -r "$REGISTER" ] || { echo "FATAL: vendor.json missing: $REGISTER" >&2; exit 2; }
[ -r "$DRIFT" ]    || { echo "FATAL: vendor-drift.py missing: $DRIFT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vendor-drift.XXXXXX")" || exit 99
cleanup() {
  case "$WORK" in
    /*/vendor-drift.*) rm -rf "$WORK" ;;
  esac
}
trap cleanup EXIT

STUBS="$WORK/bin"
mkdir -p "$STUBS"

# --- git stub -------------------------------------------------------------
# Behaviour is driven entirely by environment, so one stub serves every row.
#   STUB_LSREMOTE_MODE : ok | rc1 | empty | garbage
#   STUB_HEAD_SHA      : the 40-hex HEAD ls-remote reports (mode=ok)
#   STUB_DIFF_FILES    : newline-separated paths `git diff --name-only` returns
#   STUB_LSTREE_MODE   : ok | missing  (does the declared upstream_path exist?)
# Every invocation is appended to $STUB_LOG so mutations can be counted.
cat > "$STUBS/git" <<'GITSTUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *ls-remote*)
    case "${STUB_LSREMOTE_MODE:-ok}" in
      rc1)     echo "fatal: could not read from remote repository" >&2; exit 1 ;;
      empty)   exit 0 ;;
      garbage) printf 'not-a-sha\tHEAD\n'; exit 0 ;;
      *)       printf '%s\tHEAD\n' "${STUB_HEAD_SHA:?STUB_HEAD_SHA unset}"; exit 0 ;;
    esac
    ;;
  *ls-tree*)
    # `missing` models a declared upstream_path that upstream renamed away:
    # an empty tree listing, exactly what git prints for an absent path.
    [ "${STUB_LSTREE_MODE:-ok}" = "missing" ] && exit 0
    for last in "$@"; do :; done
    printf '%s\n' "$last"
    exit 0
    ;;
  *" diff "*|diff*)
    [ -n "${STUB_DIFF_FILES:-}" ] && printf '%s\n' "$STUB_DIFF_FILES"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GITSTUB
chmod +x "$STUBS/git"

# --- gh stub --------------------------------------------------------------
#   STUB_OPEN_ISSUES : JSON array returned by `gh issue list --json ...`
cat > "$STUBS/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *"issue list"*)
    printf '%s\n' "${STUB_OPEN_ISSUES:-[]}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://example.invalid/issues/1234"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GHSTUB
chmod +x "$STUBS/gh"

WATERMARK="$(python3 - "$REGISTER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["components"]:
    if c.get("origin") == "third-party" and c.get("upstream") == "superpowers":
        print(c["last_reviewed_upstream_commit"])
        break
PY
)"
[ -n "$WATERMARK" ] || { echo "  ABORT — no superpowers watermark in the register"; exit 99; }
MOVED_HEAD="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

# run_drift <log-file> <mode> <head> <difffiles> <openissues> [extra args...]
DRIFT_OUT=""
DRIFT_RC=0
run_drift() {
  local log="$1" mode="$2" head="$3" files="$4" issues="$5"
  shift 5
  : > "$log"
  DRIFT_RC=0
  DRIFT_OUT="$(
    PATH="$STUBS:$PATH" \
    STUB_LOG="$log" \
    STUB_LSREMOTE_MODE="$mode" \
    STUB_HEAD_SHA="$head" \
    STUB_DIFF_FILES="$files" \
    STUB_OPEN_ISSUES="$issues" \
    STUB_LSTREE_MODE="${LSTREE_MODE:-ok}" \
    python3 "$DRIFT" --repo-root "$REPO_ROOT" "$@" 2>&1
  )" || DRIFT_RC=$?
}
LSTREE_MODE=ok

# gh_mutations <log> -> count of create/edit/comment invocations
gh_mutations() {
  grep -cE '^gh issue (create|edit|comment)' "$1" || true
}

# --- anti-vacuity preflight ------------------------------------------------
run_drift "$WORK/preflight.log" ok "$WATERMARK" "" "[]" --dry-run
if [ "$DRIFT_RC" -ne 0 ]; then
  echo "FATAL: vendor-drift.py is not green on its happy path (rc=$DRIFT_RC);" >&2
  echo "       every non-zero-exit row below would pass vacuously." >&2
  echo "$DRIFT_OUT" >&2
  exit 2
fi

echo
echo "== D1-D5: reporting and issue idempotency =="

# D1 — upstream HEAD equals every watermark: no drift, exit 0, nothing created.
run_drift "$WORK/d1.log" ok "$WATERMARK" "" "[]"
if [ "$DRIFT_RC" -eq 0 ] && grep -qi 'no drift' <<<"$DRIFT_OUT" \
   && [ "$(gh_mutations "$WORK/d1.log")" = "0" ]; then
  ok "D1 HEAD == every watermark reports no drift and creates no issue"
else
  no "D1 clean upstream did not stay quiet (rc=$DRIFT_RC, mutations=$(gh_mutations "$WORK/d1.log"))"
fi

# D2 — a real drift report names the component, the changed path, and the
# watermark -> HEAD transition. A report that says only "something changed" is
# not actionable, and an unactionable weekly issue gets muted.
run_drift "$WORK/d2.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]" --dry-run
if grep -q 'skills/writing-skills' <<<"$DRIFT_OUT" \
   && grep -q "${WATERMARK:0:12}" <<<"$DRIFT_OUT" \
   && grep -q "${MOVED_HEAD:0:12}" <<<"$DRIFT_OUT"; then
  ok "D2 the report names the component, its changed paths and watermark -> HEAD"
else
  no "D2 the drift report is not actionable"
fi

# D3 — an open issue already carries the marker: EDIT it, never create a second.
OPEN_ONE='[{"number":901,"body":"stale body\n<!-- uberdev-vendor-drift-v1 -->\ndrift-fingerprint: 0000000000000000"}]'
run_drift "$WORK/d3.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "$OPEN_ONE"
if grep -qE '^gh issue edit 901' "$WORK/d3.log" \
   && ! grep -qE '^gh issue create' "$WORK/d3.log"; then
  ok "D3 an open marker-carrying issue is edited, not duplicated"
else
  no "D3 the reporter did not edit the existing tracking issue"
fi

# D4 — no open marker issue: create exactly one.
run_drift "$WORK/d4.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
CREATES="$(grep -cE '^gh issue create' "$WORK/d4.log" || true)"
if [ "$CREATES" = "1" ]; then
  ok "D4 with no open tracking issue, exactly one is created"
else
  no "D4 expected exactly 1 gh issue create, saw $CREATES"
fi

# D5 — two drifting upstreams still produce ONE issue, not one per upstream.
# Two passes: --dry-run proves BOTH upstreams reach the same report body (the
# live run writes the body to a temp file, so stdout cannot prove content), and
# the live run proves the issue count.
TWO_UPSTREAMS="skills/writing-skills/SKILL.md
plugins/pr-review-toolkit/agents/code-reviewer.md"
run_drift "$WORK/d5-dry.log" ok "$MOVED_HEAD" "$TWO_UPSTREAMS" "[]" --dry-run
D5_BODY="$DRIFT_OUT"
run_drift "$WORK/d5.log" ok "$MOVED_HEAD" "$TWO_UPSTREAMS" "[]"
CREATES="$(grep -cE '^gh issue create' "$WORK/d5.log" || true)"
if [ "$CREATES" = "1" ] && grep -q 'skills/writing-skills' <<<"$D5_BODY" \
   && grep -q 'agents/code-reviewer' <<<"$D5_BODY"; then
  ok "D5 drift across two upstreams is reported in one issue"
else
  no "D5 expected 1 issue covering both upstreams, saw $CREATES create(s)"
fi

echo
echo "== D6-D8: an unreachable upstream fails loudly and mutates nothing =="

for spec in "D6 rc1 ls-remote exits non-zero" \
            "D7 empty ls-remote prints nothing" \
            "D8 garbage ls-remote prints a non-40-hex ref"; do
  row="${spec%% *}"; rest="${spec#* }"; mode="${rest%% *}"; desc="${rest#* }"
  run_drift "$WORK/$row.log" "$mode" "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
  muts="$(gh_mutations "$WORK/$row.log")"
  if [ "$DRIFT_RC" -ne 0 ] && [ "$muts" = "0" ] \
     && grep -qiE 'ls-remote|upstream' <<<"$DRIFT_OUT"; then
    ok "$row $desc => non-zero exit, diagnostic, zero gh mutations"
  else
    no "$row $desc => rc=$DRIFT_RC mutations=$muts (must be non-zero / 0)"
  fi
done

echo
echo "== D9-D11: fingerprint, dry-run, and declared divergences =="

# D9 — the fingerprint is unchanged: the body is refreshed, but no new comment
# is posted. Otherwise a stable drift set generates a weekly comment forever.
run_drift "$WORK/fp.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]" --dry-run
FP="$(python3 - <<'PY' "$DRIFT_OUT"
import re, sys
m = re.search(r"drift-fingerprint:\s*([0-9a-f]+)", sys.argv[1])
print(m.group(1) if m else "")
PY
)"
if [ -n "$FP" ]; then
  SAME='[{"number":902,"body":"<!-- uberdev-vendor-drift-v1 -->\ndrift-fingerprint: '"$FP"'"}]'
  run_drift "$WORK/d9.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "$SAME"
  if grep -qE '^gh issue edit 902' "$WORK/d9.log" \
     && ! grep -qE '^gh issue comment' "$WORK/d9.log"; then
    ok "D9 an unchanged fingerprint refreshes the body without a new comment"
  else
    no "D9 an unchanged fingerprint still produced a comment"
  fi
else
  no "D9 the report carries no drift-fingerprint line to compare against"
fi

# D10 — --dry-run never touches GitHub at all, not even a read.
run_drift "$WORK/d10.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]" --dry-run
GH_CALLS="$(grep -cE '^gh ' "$WORK/d10.log" || true)"
if [ "$DRIFT_RC" -eq 0 ] && [ "$GH_CALLS" = "0" ]; then
  ok "D10 --dry-run renders the report with zero gh invocations"
else
  no "D10 --dry-run made $GH_CALLS gh invocation(s)"
fi

# D11 — a changed file covered by a declared divergence is reported as DECLARED,
# not as raw drift. This is the noise control that makes the weekly issue
# readable: without it, the five permanent divergences would resurface forever.
run_drift "$WORK/d11.log" ok "$MOVED_HEAD" "skills/systematic-debugging/SKILL.md" "[]" --dry-run
if grep -q 'Changed only inside declared divergences' <<<"$DRIFT_OUT" \
   && grep -q 'systematic-debugging' <<<"$DRIFT_OUT" \
   && ! grep -q 'changed upstream files' <<<"$DRIFT_OUT"; then
  ok "D11 a file covered by a declared divergence is labelled declared, not raw drift"
else
  no "D11 a declared divergence was reported as undifferentiated drift"
fi

# D12 — the register declares an upstream_path that no longer exists upstream.
# This row exists because a REAL dry-run against upstream exposed the hole: a
# prefix that matches nothing produces an empty changed-file list, which renders
# as a confident "no drift" forever. A typo'd or upstream-renamed path is NEWS,
# not silence, so it must fail loudly like an unreachable remote does.
LSTREE_MODE=missing
run_drift "$WORK/d12.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
LSTREE_MODE=ok
muts="$(gh_mutations "$WORK/d12.log")"
if [ "$DRIFT_RC" -ne 0 ] && [ "$muts" = "0" ] \
   && grep -q 'upstream_path' <<<"$DRIFT_OUT"; then
  ok "D12 an upstream_path missing from the upstream tree fails loudly, not silently clean"
else
  no "D12 a vanished upstream_path was reported as 'no drift' (rc=$DRIFT_RC mutations=$muts)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

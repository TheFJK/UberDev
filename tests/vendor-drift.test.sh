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

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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
#   STUB_REVPARSE_MODE : ok | mismatch | fail   (`git rev-parse <sha>:<path>`)
#   STUB_REVPARSE_MAP  : path<TAB>oid table answering mode=ok, so ONE stub can
#                        serve components whose recorded oids all differ
#   STUB_FETCH_MODE    : ok | fail
#   STUB_TAGS_MODE     : ok | rc1 | garbage | noref | badref
#                        (`git ls-remote --tags`)
#   STUB_TAGS_TABLE    : slug<TAB>sha<TAB>ref table answering mode=ok, so one
#                        stub can give each upstream its OWN published tag set
#
# The two tag knobs are deliberately INDEPENDENT of STUB_LSREMOTE_MODE. That one
# variable drives every ls-remote the stub sees, so reusing it would make "HEAD
# resolves but the tag query fails" unmodellable — and would silently change what
# D6-D8 assert, since their `mode` argument would start failing two queries.
# Every invocation is appended to $STUB_LOG so mutations can be counted.
#
# The `rev-parse` and `fetch` arms are not decoration. Before they existed both
# fell through to `*) exit 0` with EMPTY stdout, so a base-verification row would
# have passed against a stub that answered nothing at all — the vacuous-green
# class this whole suite is built to refuse.
cat > "$STUBS/git" <<'GITSTUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *rev-parse*)
    case "${STUB_REVPARSE_MODE:-ok}" in
      # A different, still well-formed 40-hex: this exercises the "recorded oid
      # disagrees" arm rather than the "answer is not an object id" arm.
      mismatch) printf '%s\n' "0000000000000000000000000000000000000000"; exit 0 ;;
      fail)     echo "fatal: path does not exist in the given revision" >&2; exit 128 ;;
      *)
        # The last argument is `<sha>:<path>`; answer from the row's own table.
        for spec in "$@"; do :; done
        want="${spec#*:}"
        while IFS=$'\t' read -r mapped oid; do
          [ "$mapped" = "$want" ] || continue
          printf '%s\n' "$oid"
          exit 0
        done < "${STUB_REVPARSE_MAP:?STUB_REVPARSE_MAP unset}"
        echo "fatal: stub has no mapping for $want" >&2
        exit 128
        ;;
    esac
    ;;
  *fetch*)
    if [ "${STUB_FETCH_MODE:-ok}" = "fail" ]; then
      echo "fatal: could not read from remote repository" >&2
      exit 1
    fi
    exit 0
    ;;
  # ARM ORDER IS LOAD-BEARING. The HEAD invocation carries no `--tags`, so the
  # two patterns never overlap — but `*ls-remote*)` reached FIRST would swallow
  # the tag query and answer it with a single `<sha>\tHEAD` line, which is the
  # vacuous green this row set exists to refuse. Keep this arm above it.
  *ls-remote*--tags*)
    case "${STUB_TAGS_MODE:-ok}" in
      rc1)     echo "fatal: could not read from remote repository" >&2; exit 1 ;;
      garbage) printf 'not-a-sha\trefs/tags/v9.9.9\n'; exit 0 ;;
      # A single-token line — well-formed object id, no ref field. Real
      # `ls-remote` cannot emit one, which is exactly why the parser's own
      # arity guard needs a row: without it that line is an IndexError
      # traceback, not the named diagnostic every other bad answer gets.
      noref)   printf '%s\n' "1111111111111111111111111111111111111111"; exit 0 ;;
      # A well-formed line whose ref is not under `refs/tags`. The twin of
      # `noref`: both fields parse, so the only thing standing between this and
      # `match.group(1)` on None is the tool's own refs/tags guard — and an
      # AttributeError is a loud exit that names no upstream, which is the same
      # loss `noref` guards against.
      badref)  printf '%s\trefs/heads/main\n' \
                 "2222222222222222222222222222222222222222"; exit 0 ;;
      *)
        # The last argument is the clone url; its last two path components are
        # the slug the table is keyed by.
        for u in "$@"; do :; done
        slug="${u#*://}"; slug="${slug#*/}"
        while IFS=$'\t' read -r rslug sha ref; do
          [ "$rslug" = "$slug" ] || continue
          printf '%s\t%s\n' "$sha" "$ref"
        done < "${STUB_TAGS_TABLE:?STUB_TAGS_TABLE unset}"
        exit 0
        ;;
    esac
    ;;
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

# --- the published-tag fixture (#535) --------------------------------------
# The table the stub answers `ls-remote --tags` from, plus every label and sha
# the D-REL rows compare against, DERIVED from the committed register. A literal
# `v6.3.0` here would prove the stub agrees with the test rather than that the
# tool reads the register, and it would go stale the first time a review point
# is advanced.
#
# Built BEFORE the anti-vacuity preflight below, unlike REVPARSE_MAP: the
# preflight itself calls run_drift, and a table that does not exist yet makes the
# stub's `${STUB_TAGS_TABLE:?}` abort, hard-stopping the whole suite at rc 2.
#
# The labelled upstream gets an ANNOTATED-tag pair — the tag object's own oid,
# then the `^{}` peel line carrying the register's recorded commit — so the
# peel-wins rule is exercised on the happy path rather than only in a row of its
# own. Slugs with no labelled upstream get NO rows at all, which is what the
# monorepo really publishes today.
TAGS_DEFAULT="$WORK/tags-default.tbl"
TAGS_UNVERSIONED="$WORK/tags-unversioned.tbl"
TAGS_ENV="$WORK/tags.env"
TAGFREE_SLUGS_FILE="$WORK/tagfree-slugs.txt"
ALL_SLUGS_FILE="$WORK/all-slugs.txt"
python3 - "$REGISTER" "$TAGS_DEFAULT" "$TAGS_ENV" "$TAGFREE_SLUGS_FILE" \
         "$ALL_SLUGS_FILE" "$TAGS_UNVERSIONED" <<'PY' || { echo "  ABORT — could not derive the tag fixture"; exit 99; }
import hashlib, json, re, shlex, sys

reg, table, envfile, tagfree_file, allslugs_file, unversioned_table = sys.argv[1:7]
d = json.load(open(reg, encoding="utf-8"))
ups = d.get("upstreams", {})
used = sorted({c["upstream"] for c in d.get("components", [])
               if c.get("origin") == "third-party"})

labelled = [u for u in used if ups.get(u, {}).get("last_reviewed_release")]
unlabelled = [u for u in used if not ups.get(u, {}).get("last_reviewed_release")]
# Both arms are required. Without (a) every release row below asserts nothing;
# without (b) the HEAD-only upstream the rows contrast against has vanished, and
# "a missing label is not an error" would be untested.
if not labelled:
    raise SystemExit("no used upstream declares last_reviewed_release — every "
                     "release row would be vacuous")
if not unlabelled:
    raise SystemExit("every used upstream declares last_reviewed_release — the "
                     "label-free upstream these rows contrast against is gone")


# A tag that names NO version — the moving pointer (`latest`, `stable`,
# `nightly`) that upstreams routinely publish alongside their releases. It is
# spelled out rather than derived because the register records only VERSIONED
# labels, so there is nothing in it to derive a version-free name from; what
# makes it trustworthy is the assertion below, not the spelling. The property
# the tool's `release_key` filter turns on is "parses to no version", and a name
# carrying no digit anywhere has that property whichever way `release_key`
# partitions it — the same check also proves this name can never collide with a
# generated label, since every one of those is renumbered from a digit-bearing
# recorded release.
UNVERSIONED = "latest"
if re.search(r"\d", UNVERSIONED):
    raise SystemExit("the unversioned tag label %r carries a digit, so "
                     "release_key would rank it as a version and the rows "
                     "that turn on it would assert nothing" % UNVERSIONED)


def synthetic(*parts):
    """A derived 40-hex object id. Never a literal: a typed sha stops proving
    anything the moment the register records a different one."""
    # Not a security primitive — a deterministic id derived from the register.
    return hashlib.sha1("|".join(parts).encode("utf-8"),
                        usedforsecurity=False).hexdigest()


def renumber(label, nums):
    it = iter(nums)
    return re.sub(r"\d+", lambda m: str(next(it)), label)


def step_down(nums):
    """The next strictly-lower version tuple: decrement the rightmost non-zero
    component. Generic on purpose — a hardcoded "decrement the minor" aborts the
    suite the day upstream cuts an X.0.0."""
    out = list(nums)
    for i in range(len(out) - 1, -1, -1):
        if out[i] > 0:
            out[i] -= 1
            return out
    return None


def step_up(nums):
    """Increment the SECOND numeric component and zero every later one; with
    fewer than two components, increment the last."""
    out = list(nums)
    idx = 1 if len(out) > 1 else len(out) - 1
    out[idx] += 1
    for i in range(idx + 1, len(out)):
        out[i] = 0
    return out


rows = []
for upstream_id in labelled:
    meta = ups[upstream_id]
    slug, label = meta["repo"], meta["last_reviewed_release"]
    commit = meta["last_reviewed_commit"]
    nums = [int(n) for n in re.findall(r"\d+", label)]
    if not nums:
        raise SystemExit("recorded release %r carries no digits" % label)
    rows.append((slug, synthetic(slug, label, "tag-object"),
                 "refs/tags/%s" % label))
    rows.append((slug, commit, "refs/tags/%s^{}" % label))
    lower = nums
    for _ in range(2):
        lower = step_down(lower)
        if lower is None:
            raise SystemExit("recorded release %r has no room below it" % label)
        older = renumber(label, lower)
        rows.append((slug, synthetic(slug, older), "refs/tags/%s" % older))
    # ...and one tag that names no version at all, on the HAPPY path. Without it
    # every tag in this suite parses to a version, `release_key` never returns
    # None, and the filter that keeps such a tag out of `max()` filters nothing —
    # so deleting the filter stays green here while an upstream publishing a
    # single moving pointer takes the weekly job down with a TypeError.
    rows.append((slug, synthetic(slug, UNVERSIONED),
                 "refs/tags/%s" % UNVERSIONED))

lead = labelled[0]
lead_meta = ups[lead]
lead_slug, lead_label = lead_meta["repo"], lead_meta["last_reviewed_release"]
lead_nums = [int(n) for n in re.findall(r"\d+", lead_label)]
newer_label = renumber(lead_label, step_up(lead_nums))
# The lexical trap: `ls-remote` sorts refnames, so `<label>.2` prints AFTER
# `<label>.10` and a tool that took the last line would call it the newest.
# Appending a component keeps both strictly above the recorded label and
# strictly below the incremented one, whatever shape the recorded label has.
lex_high, lex_low = "%s.10" % lead_label, "%s.2" % lead_label

all_slugs = sorted({ups[u]["repo"] for u in used})
tagfree = sorted(set(all_slugs) - {ups[u]["repo"] for u in labelled})
# Third anti-vacuity arm. Every row that walks TAGFREE_SLUGS_FILE asserts inside
# the loop, so an empty file makes those loops assert NOTHING while still
# reporting a pass — the vacuous green this suite exists to refuse. An unlabelled
# upstream is not enough on its own: it could share its repo slug with a labelled
# one, and the tag query is answered per SLUG.
if not tagfree:
    raise SystemExit("every distinct slug carries a labelled upstream — the "
                     "tag-free slug D-REL1 and D-REL1b assert over is gone, and "
                     "both would pass without asserting anything")


def tag_name(ref):
    name = ref.split("refs/tags/", 1)[1]
    return name[:-3] if name.endswith("^{}") else name


lead_tag_count = len({tag_name(r[2]) for r in rows if r[0] == lead_slug})

# The second table: every default row, PLUS the version-free tag for each
# tag-free slug. This is the only shape that reaches the tool's "publishes tags,
# none of them names a version" branch — in the default table those slugs publish
# nothing at all, which renders as the DIFFERENT `no published tags` string.
unversioned_rows = [(slug, synthetic(slug, UNVERSIONED, "tagfree"),
                     "refs/tags/%s" % UNVERSIONED) for slug in tagfree]
tagfree_tag_count = len({tag_name(r[2]) for r in unversioned_rows
                         if r[0] == tagfree[0]})

open(table, "w", encoding="utf-8").write(
    "".join("%s\t%s\t%s\n" % r for r in rows))
open(unversioned_table, "w", encoding="utf-8").write(
    "".join("%s\t%s\t%s\n" % r for r in rows + unversioned_rows))
open(tagfree_file, "w", encoding="utf-8").write("".join(s + "\n" for s in tagfree))
open(allslugs_file, "w", encoding="utf-8").write("".join(s + "\n" for s in all_slugs))
env = {
    "LEAD_SLUG": lead_slug,
    "LEAD_LABEL": lead_label,
    "LEAD_PEEL12": lead_meta["last_reviewed_commit"][:12],
    "LEAD_TAG_COUNT": str(lead_tag_count),
    "SLUG_COUNT": str(len(all_slugs)),
    "UNVERSIONED_LABEL": UNVERSIONED,
    "TAGFREE_TAG_COUNT": str(tagfree_tag_count),
    "NEWER_LABEL": newer_label,
    "NEWER_SHA": synthetic(lead_slug, newer_label),
    "RC_LABEL": "%s-rc1" % newer_label,
    "RC_SHA": synthetic(lead_slug, newer_label, "rc1"),
    "LEX_HIGH_LABEL": lex_high,
    "LEX_HIGH_SHA": synthetic(lead_slug, lex_high),
    "LEX_LOW_LABEL": lex_low,
    "LEX_LOW_SHA": synthetic(lead_slug, lex_low),
}
open(envfile, "w", encoding="utf-8").write(
    "".join("%s=%s\n" % (k, shlex.quote(v)) for k, v in sorted(env.items())))
PY
. "$TAGS_ENV"

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
    STUB_REVPARSE_MODE="${REVPARSE_MODE:-ok}" \
    STUB_REVPARSE_MAP="${REVPARSE_MAP:-/dev/null}" \
    STUB_FETCH_MODE="${FETCH_MODE:-ok}" \
    STUB_TAGS_MODE="${TAGS_MODE:-ok}" \
    STUB_TAGS_TABLE="${TAGS_TABLE:-$TAGS_DEFAULT}" \
    python3 "$DRIFT" --repo-root "${DRIFT_ROOT:-$REPO_ROOT}" "$@" 2>&1
  )" || DRIFT_RC=$?
}
LSTREE_MODE=ok
REVPARSE_MODE=ok
REVPARSE_MAP=/dev/null
FETCH_MODE=ok
TAGS_MODE=ok
TAGS_TABLE=""
DRIFT_ROOT="$REPO_ROOT"

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
echo "== D13: a malformed register is not an outage =="

# D13 — every field the diff loop subscripts unconditionally. An uncaught
# KeyError exits 1, which is precisely `fail()`'s documented "an upstream could
# not be resolved" — so a register somebody broke used to be indistinguishable
# from GitHub being down, and a weekly alarm that cries outage is one that gets
# muted. Asserting rc != 0 would therefore pass against the buggy script and
# prove nothing. This row asserts the DIAGNOSIS instead: rc 2 (unreadable
# register), the offending field named, no traceback, and — because validation
# runs before the first clone — zero git and zero gh invocations.
BAD_ROOT="$WORK/bad-register"
mkdir -p "$BAD_ROOT/plugins/uberdev"
D13_FAILED=0
D13_RC=0
for field in id upstream upstream_path stance last_reviewed_upstream_commit; do
  python3 - "$REGISTER" "$BAD_ROOT/plugins/uberdev/vendor.json" "$field" <<'PY'
import json, sys
src, dst, field = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src, encoding="utf-8"))
for c in d["components"]:
    if c.get("origin") == "third-party":
        c.pop(field, None)
        break
json.dump(d, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
  : > "$WORK/d13.log"
  D13_RC=0
  D13_OUT="$(
    PATH="$STUBS:$PATH" \
    STUB_LOG="$WORK/d13.log" \
    STUB_LSREMOTE_MODE=ok \
    STUB_HEAD_SHA="$MOVED_HEAD" \
    STUB_DIFF_FILES="" \
    STUB_OPEN_ISSUES="[]" \
    STUB_LSTREE_MODE=ok \
    STUB_TAGS_MODE=ok \
    STUB_TAGS_TABLE="$TAGS_DEFAULT" \
    python3 "$DRIFT" --repo-root "$BAD_ROOT" 2>&1
  )" || D13_RC=$?
  calls="$(grep -cE '^(git|gh) ' "$WORK/d13.log" || true)"
  if [ "$D13_RC" -eq 2 ] && grep -q "declares no $field" <<<"$D13_OUT" \
     && ! grep -q 'Traceback' <<<"$D13_OUT" && [ "$calls" = "0" ]; then
    continue
  fi
  D13_FAILED=1
  no "D13 a component missing '$field' => rc=$D13_RC subprocess-calls=$calls (want rc 2, field named, no traceback, no subprocess)"
  echo "        output: $(head -c 300 <<<"$D13_OUT")"
done
if [ "$D13_FAILED" -eq 0 ]; then
  ok "D13 every register field the diff loop subscripts fails as rc 2, named, before any clone"
fi

# D13b — the two failure modes must stay on separate exit codes. If either ever
# drifts onto the other's, the weekly job can no longer tell "GitHub is down"
# from "somebody broke vendor.json", and D6-D8 stop meaning what they say.
run_drift "$WORK/d13b.log" rc1 "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
if [ "$DRIFT_RC" -eq 1 ] && [ "$D13_RC" -eq 2 ]; then
  ok "D13b unreachable upstream (rc 1) and malformed register (rc 2) stay distinguishable"
else
  no "D13b the two failure modes collide: unreachable=$DRIFT_RC malformed=$D13_RC"
fi

echo
echo "== D-VB1-D-VB5: --verify-bases, the upstream half of the base proof (#505) =="

# ---------------------------------------------------------------------------
# WHY THIS MODE EXISTS. `vendor-check.py`'s C-BASE makes a recorded
# `vendored_at_commit` cost two coordinated lies instead of one — the register's
# claim must be restated in an in-file header — and RFC 0019 §2.2 is explicit
# that offline it can do no better. For the six `claude-plugins-official` agents
# that ceiling was the whole problem: no clone of that upstream exists in this
# repo, so no reviewer could compare the bytes even by hand.
#
# `base_evidence` records the blob oid each file had at `vendored_ref`, a commit
# of THIS repository. That half is re-derivable offline and is asserted in
# tests/vendor-provenance.test.sh V30. THIS mode owns the other half: that the
# same oid is what UPSTREAM's tree holds at `vendored_at_commit`. It is a
# network operation, so it lives here rather than in the offline guard — mixing
# them would make an outage render as fabricated provenance.
#
# Every row below drives PATH-stubbed `git`, so the assertions are about the
# MODE's behaviour, never about upstream being reachable today. The live proof
# is one real `--verify-bases` run, recorded in the change that adds it.
# ---------------------------------------------------------------------------

# The oid table the stub answers `rev-parse` from, derived from the committed
# register rather than typed: a literal here would go stale the moment a base is
# re-recorded, and would then prove the stub agrees with the test rather than
# that the mode reads the register.
REVPARSE_MAP="$WORK/revparse.map"
python3 - "$REGISTER" "$REVPARSE_MAP" > /dev/null <<'PY' || { echo "  ABORT — could not derive the rev-parse map"; exit 99; }
import json, os, sys
reg, out = sys.argv[1], sys.argv[2]
d = json.load(open(reg, encoding="utf-8"))
rows = []
for c in d.get("components", []):
    ev = c.get("base_evidence")
    if not isinstance(ev, dict) or not isinstance(ev.get("blobs"), dict):
        continue
    upath = c.get("upstream_path") or ""
    # `files[]` is a bare path list on an unpinned component and a list of
    # {path, sha256} on a digest-locked one (#503 tied the lock to the pin, not
    # to the stance). Read the paths out of BOTH shapes: comparing raw entries
    # silently stopped matching the moment these components were pinned, and the
    # stub then answered a path the mode never asks for — a rc=1 that looks like
    # a mode bug and is really a shape assumption.
    declared = [e.get("path") if isinstance(e, dict) else e
                for e in (c.get("files") or [])]
    single = len(ev["blobs"]) == 1 and list(ev["blobs"]) == declared
    for name, oid in sorted(ev["blobs"].items()):
        rows.append("%s\t%s" % (upath if single else "%s/%s" % (upath, name), oid))
if not rows:
    raise SystemExit("the register declares no base_evidence — D-VB1 would be vacuous")
open(out, "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY

# D-VB1 — happy path. Asserts the LEDGER, not just the exit code: a mode that
# returned 0 without fetching or resolving anything would look identical here.
run_drift "$WORK/dvb1.log" ok "$WATERMARK" "" "[]" --verify-bases
DVB1_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DVB1_FAILS="rc=$DRIFT_RC"
[ "$(gh_mutations "$WORK/dvb1.log")" = "0" ] \
  || DVB1_FAILS="${DVB1_FAILS}${DVB1_FAILS:+; }it touched GitHub"
grep -qE '^git fetch' "$WORK/dvb1.log" \
  || DVB1_FAILS="${DVB1_FAILS}${DVB1_FAILS:+; }no upstream fetch was made"
grep -qE '^git rev-parse' "$WORK/dvb1.log" \
  || DVB1_FAILS="${DVB1_FAILS}${DVB1_FAILS:+; }no blob was resolved"
# HEAD is irrelevant to a base check, so the mode must return before resolving
# it. Asserting the absence keeps the mode cheap and its failure modes narrow.
#
# Since #535 this one assertion forbids TWO query shapes — `ls-remote <url> HEAD`
# and `ls-remote --tags <url>` — because both ledger lines begin `git ls-remote`.
# Do NOT "fix" it into `ls-remote.*HEAD`: that would let the tag pass leak into a
# mode that has no use for it, unnoticed. The stub's own `${STUB_TAGS_TABLE:?}`
# is NOT a second guard here — run_drift builds its environment with
# `${VAR:-default}`, so the variable is ALWAYS set and the `:?` can never fire
# from this suite. This grep is the whole oracle.
! grep -qE '^git ls-remote' "$WORK/dvb1.log" \
  || DVB1_FAILS="${DVB1_FAILS}${DVB1_FAILS:+; }it resolved upstream HEAD, which a base check does not need"
if [ -z "$DVB1_FAILS" ]; then
  ok "D-VB1 --verify-bases fetches, resolves every recorded blob, and exits 0"
else
  no "D-VB1 --verify-bases happy path: $DVB1_FAILS"
fi

# D-VB2 — upstream's blob is a DIFFERENT object. This is the finding the mode
# exists for: the recorded base is not where those bytes came from.
REVPARSE_MODE=mismatch
run_drift "$WORK/dvb2.log" ok "$WATERMARK" "" "[]" --verify-bases
REVPARSE_MODE=ok
DVB2_MUTS="$(gh_mutations "$WORK/dvb2.log")"
if [ "$DRIFT_RC" -ne 0 ] && [ "$DVB2_MUTS" = "0" ] \
   && grep -q 'agents/' <<<"$DRIFT_OUT" \
   && grep -q '0000000000000000000000000000000000000000' <<<"$DRIFT_OUT"; then
  ok "D-VB2 a blob that disagrees with the register fails loudly, naming both oids"
else
  no "D-VB2 a mismatched blob was not reported (rc=$DRIFT_RC mutations=$DVB2_MUTS)"
fi

# D-VB3 — the declared upstream_path does not resolve at the recorded base. The
# same class D12 covers for the drift path: unresolvable is a finding, never a
# quiet pass.
REVPARSE_MODE=fail
run_drift "$WORK/dvb3.log" ok "$WATERMARK" "" "[]" --verify-bases
REVPARSE_MODE=ok
if [ "$DRIFT_RC" -ne 0 ] && grep -q 'upstream_path' <<<"$DRIFT_OUT"; then
  ok "D-VB3 an unresolvable upstream_path at the recorded base is a refusal, not a pass"
else
  no "D-VB3 an unresolvable upstream_path did not fail loudly (rc=$DRIFT_RC)"
fi

# D-VB4 — the remote is unreachable. Mirrors D6-D8: an outage must never render
# as "the bases check out".
FETCH_MODE=fail
run_drift "$WORK/dvb4.log" ok "$WATERMARK" "" "[]" --verify-bases
FETCH_MODE=ok
DVB4_RC="$DRIFT_RC"
if [ "$DVB4_RC" -eq 1 ] && grep -qiE 'fetch|upstream' <<<"$DRIFT_OUT"; then
  ok "D-VB4 an unreachable upstream exits 1 with a diagnostic, never a clean verdict"
else
  no "D-VB4 an unreachable upstream did not fail as rc 1 (rc=$DVB4_RC)"
fi

# D-VB5 — nothing to verify. A register with no `base_evidence` anywhere makes
# the loop body unreachable, and a naive implementation would print "verified 0
# components" and exit 0 — certifying an empty set, which is the exact class
# C-EVIDENCE's own anti-vacuity arm refuses offline. rc 2 keeps D13b's
# "malformed register (2) vs unreachable upstream (1)" separation intact, and
# the row asserts that separation rather than assuming it.
NO_EVIDENCE_ROOT="$WORK/no-evidence"
mkdir -p "$NO_EVIDENCE_ROOT/plugins/uberdev"
python3 - "$REGISTER" "$NO_EVIDENCE_ROOT/plugins/uberdev/vendor.json" <<'PY' || { echo "  ABORT — could not build the evidence-free register"; exit 99; }
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding="utf-8"))
stripped = sum(1 for c in d["components"] if c.pop("base_evidence", None) is not None)
if not stripped:
    raise SystemExit("the register declares no base_evidence — D-VB5 proves nothing")
json.dump(d, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
DRIFT_ROOT="$NO_EVIDENCE_ROOT"
run_drift "$WORK/dvb5.log" ok "$WATERMARK" "" "[]" --verify-bases
DRIFT_ROOT="$REPO_ROOT"
DVB5_CALLS="$(grep -cE '^(git|gh) ' "$WORK/dvb5.log" || true)"
if [ "$DRIFT_RC" -eq 2 ] && [ "$DVB5_CALLS" = "0" ] && [ "$DVB4_RC" -eq 1 ]; then
  ok "D-VB5 nothing to verify exits 2 before any clone, and stays distinct from an outage's rc 1"
else
  no "D-VB5 an empty evidence set => rc=$DRIFT_RC subprocess-calls=$DVB5_CALLS (want rc 2, 0 calls, and rc 1 for D-VB4)"
fi

echo
echo "== D-REL1-D-REL4: the published-tag observable (#535) =="

# ---------------------------------------------------------------------------
# WHY THESE ROWS EXIST. RFC 0019 §8 makes this job the compensating control for
# vendoring, and §7 adjudicates RELEASES — but the job only ever resolved HEAD,
# so it could not say "upstream cut a release you have not adjudicated". The
# 6.3.0 walk was triggered by a human noticing a new directory in the plugin
# cache, not by this control. HEAD drift and release drift disagree in BOTH
# directions: the day a release lands they can coincide (reported as no drift at
# all), and between releases unreleased commits render as drift the register has
# no obligation to chase — which trains the reader to mute the issue.
#
# Rows below assert the SECOND observable exists and is read correctly. Three
# falsifiability checks were RUN, not assumed, and each must keep failing:
#
#   * delete the `*ls-remote*--tags*` stub arm — the tag query then falls through
#     to the HEAD arm, which answers `<sha>\tHEAD`; the tool refuses a ref outside
#     refs/tags, so the ANTI-VACUITY PREFLIGHT itself hard-stops the suite at
#     rc 2 and no row below can report a pass at all;
#   * stop letting an annotated tag's `^{}` peel line win — D-REL1 reds, because
#     the reported commit becomes the tag object's oid, which the register has
#     never seen;
#   * key the ordering on the digit runs alone, or on refname order — D-REL2 reds
#     on `<newer>-rc1` and on the `.2`-after-`.10` pair respectively;
#   * drop the filter that keeps a version-free tag out of `max()` — the DEFAULT
#     table carries such a tag, so the happy path itself dies comparing None
#     against a tuple, and the anti-vacuity preflight hard-stops the suite at
#     rc 2 before any row below it runs;
#   * disable the `none of them names a version` render arm — D-REL1b reds,
#     because `max()` over an empty filtered set raises instead of reporting;
#   * drop the `len(fields) < 2` ref-arity guard — D-REL4b reds;
#   * drop the "not under refs/tags" guard — D-REL4c reds.
#
# The version-free filter and the render arm are why every table carries a tag
# that names NO version. A suite in which every tag parses to a version cannot
# see that filter at all: it never filters anything, and deleting it stays green
# — which is exactly what happened before these two rows existed.
#
# The last two guards refuse answers real `ls-remote --tags` cannot produce, so
# what their rows protect is not the ANSWER but the DIAGNOSTIC: without them the
# tool still exits non-zero, by IndexError and AttributeError respectively,
# naming neither the upstream nor the line — the anonymous failure D6-D8 refuse
# for HEAD.
# ---------------------------------------------------------------------------

# names_an_upstream <output> — true when the diagnostic names some upstream the
# register actually declares, rather than failing anonymously. Derived from the
# register so a renamed slug cannot leave this asserting a literal that is gone.
names_an_upstream() {
  local out="$1" slug found=1
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if grep -qF -e "$slug" <<<"$out"; then found=0; fi
  done < "$ALL_SLUGS_FILE"
  return "$found"
}

# D-REL1 — the happy path asserts the LEDGER and the BODY. The ledger proves one
# `ls-remote --tags` per distinct upstream SLUG (never one per component, and
# never none at all); the body proves the tool read the annotated tag's `^{}`
# PEEL line, because the recorded review point is the only commit that line
# carries — the tag object's own oid is a different, equally well-formed sha.
run_drift "$WORK/drel1.log" ok "$WATERMARK" "" "[]" --dry-run
DREL1_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL1_FAILS="rc=$DRIFT_RC"
TAG_QUERIES="$(grep -cE '^git ls-remote --tags' "$WORK/drel1.log" || true)"
[ "$TAG_QUERIES" = "$SLUG_COUNT" ] \
  || DREL1_FAILS="${DREL1_FAILS}${DREL1_FAILS:+; }tag queries=$TAG_QUERIES want $SLUG_COUNT"
grep -qF -e "Upstream tags resolved this run:" <<<"$DRIFT_OUT" \
  || DREL1_FAILS="${DREL1_FAILS}${DREL1_FAILS:+; }the body carries no tag block"
LEAD_LINE="- \`$LEAD_SLUG\`: $LEAD_TAG_COUNT published tag(s); newest \`$LEAD_LABEL\` (\`$LEAD_PEEL12\`)"
grep -qF -e "$LEAD_LINE" <<<"$DRIFT_OUT" \
  || DREL1_FAILS="${DREL1_FAILS}${DREL1_FAILS:+; }missing line: $LEAD_LINE"
while IFS= read -r tagfree_slug; do
  [ -n "$tagfree_slug" ] || continue
  grep -qF -e "- \`$tagfree_slug\`: no published tags" <<<"$DRIFT_OUT" \
    || DREL1_FAILS="${DREL1_FAILS}${DREL1_FAILS:+; }$tagfree_slug not reported as publishing no tags"
done < "$TAGFREE_SLUGS_FILE"
# The lead's table includes a version-free tag, so the count above already
# counts it while `newest` must still name the recorded release. Pinning the
# negative as well keeps the version-free tag OUT of the answer under any future
# key — one that ranked it last rather than excluding it would satisfy the line
# above by accident.
if grep -qF -e "newest \`$UNVERSIONED_LABEL\`" <<<"$DRIFT_OUT"; then
  DREL1_FAILS="${DREL1_FAILS}${DREL1_FAILS:+; }a tag naming no version was reported as newest"
fi
if [ -z "$DREL1_FAILS" ]; then
  ok "D-REL1 one tag query per upstream slug, and the peeled annotated tag is what gets reported"
else
  no "D-REL1 published tags are not resolved as declared: $DREL1_FAILS"
fi

# D-REL1b — a slug that publishes tags of which NONE names a version. This is
# the branch between "reports an observation" and "the weekly job dies with an
# uncaught TypeError", for an upstream doing something entirely normal: shipping
# one moving pointer and no releases yet. It is a distinct shape from D-REL1's
# tag-free slug, and must render as a distinct line — reporting "no published
# tags" for a remote that published some is a false observation.
TAGS_TABLE="$TAGS_UNVERSIONED"
run_drift "$WORK/drel1b.log" ok "$WATERMARK" "" "[]" --dry-run
TAGS_TABLE=""
DREL1B_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL1B_FAILS="rc=$DRIFT_RC"
while IFS= read -r tagfree_slug; do
  [ -n "$tagfree_slug" ] || continue
  UNNAMED_LINE="- \`$tagfree_slug\`: $TAGFREE_TAG_COUNT published tag(s); none of them names a version"
  grep -qF -e "$UNNAMED_LINE" <<<"$DRIFT_OUT" \
    || DREL1B_FAILS="${DREL1B_FAILS}${DREL1B_FAILS:+; }missing line: $UNNAMED_LINE"
  if grep -qF -e "- \`$tagfree_slug\`: no published tags" <<<"$DRIFT_OUT"; then
    DREL1B_FAILS="${DREL1B_FAILS}${DREL1B_FAILS:+; }$tagfree_slug published tags but was reported as publishing none"
  fi
done < "$TAGFREE_SLUGS_FILE"
# ...and the labelled slug is untouched by the other slug's answer.
grep -qF -e "$LEAD_LINE" <<<"$DRIFT_OUT" \
  || DREL1B_FAILS="${DREL1B_FAILS}${DREL1B_FAILS:+; }missing line: $LEAD_LINE"
if [ -z "$DREL1B_FAILS" ]; then
  ok "D-REL1b tags that name no version are reported as an observation, not a crash"
else
  no "D-REL1b a version-free tag set is misreported: $DREL1B_FAILS"
fi

# D-REL2 — ordering is COMPUTED, never taken from `ls-remote`'s output order.
# Three traps in one table: a pre-release must not outrank its own final release
# (keying on the digit runs alone puts `X-rc1` above `X`); `<label>.2` prints
# after `<label>.10` in lexical refname order, so "the last line" is not "the
# newest"; and neither may displace the genuinely-newest label.
DREL2_TABLE="$WORK/tags-rel2.tbl"
cp "$TAGS_DEFAULT" "$DREL2_TABLE"
{
  printf '%s\t%s\trefs/tags/%s\n' "$LEAD_SLUG" "$NEWER_SHA" "$NEWER_LABEL"
  printf '%s\t%s\trefs/tags/%s\n' "$LEAD_SLUG" "$RC_SHA" "$RC_LABEL"
  printf '%s\t%s\trefs/tags/%s\n' "$LEAD_SLUG" "$LEX_HIGH_SHA" "$LEX_HIGH_LABEL"
  printf '%s\t%s\trefs/tags/%s\n' "$LEAD_SLUG" "$LEX_LOW_SHA" "$LEX_LOW_LABEL"
} >> "$DREL2_TABLE"
TAGS_TABLE="$DREL2_TABLE"
run_drift "$WORK/drel2.log" ok "$WATERMARK" "" "[]" --dry-run
TAGS_TABLE=""
if [ "$DRIFT_RC" -eq 0 ] \
   && grep -qF -e "newest \`$NEWER_LABEL\` (\`${NEWER_SHA:0:12}\`)" <<<"$DRIFT_OUT" \
   && ! grep -qF -e "newest \`$RC_LABEL\`" <<<"$DRIFT_OUT" \
   && ! grep -qF -e "newest \`$LEX_LOW_LABEL\`" <<<"$DRIFT_OUT" \
   && ! grep -qF -e "newest \`$LEX_HIGH_LABEL\`" <<<"$DRIFT_OUT"; then
  ok "D-REL2 the newest tag is decided by version order, not by refname order or digit runs"
else
  no "D-REL2 expected newest '$NEWER_LABEL' (not '$RC_LABEL', not '$LEX_LOW_LABEL'); rc=$DRIFT_RC"
fi

# D-REL3 — the tag query itself fails while HEAD still resolves. Holding
# STUB_LSREMOTE_MODE at `ok` is the whole point: it proves the TAG arm is what
# failed. An upstream that cannot answer is the same class as D6-D8 — rc 1, a
# diagnostic naming the upstream and the query shape, and nothing mutated.
TAGS_MODE=rc1
run_drift "$WORK/drel3.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
TAGS_MODE=ok
DREL3_RC="$DRIFT_RC"
DREL3_MUTS="$(gh_mutations "$WORK/drel3.log")"
if [ "$DREL3_RC" -eq 1 ] && [ "$DREL3_MUTS" = "0" ] \
   && grep -qF -e '--tags' <<<"$DRIFT_OUT" && names_an_upstream "$DRIFT_OUT"; then
  ok "D-REL3 an unanswerable tag query exits 1 with a diagnostic, mutating nothing"
else
  no "D-REL3 a failed tag query => rc=$DREL3_RC mutations=$DREL3_MUTS (want rc 1, 0, named)"
fi

# D-REL4 — the remote answers, but with something that is not an object id. The
# same refusal D8 makes for HEAD: an unparseable answer must never be read as
# "this upstream publishes tag v9.9.9 at <garbage>".
TAGS_MODE=garbage
run_drift "$WORK/drel4.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
TAGS_MODE=ok
DREL4_MUTS="$(gh_mutations "$WORK/drel4.log")"
if [ "$DRIFT_RC" -eq 1 ] && [ "$DREL4_MUTS" = "0" ] \
   && names_an_upstream "$DRIFT_OUT"; then
  ok "D-REL4 a non-40-hex tag line fails loudly, naming the upstream"
else
  no "D-REL4 a garbage tag line => rc=$DRIFT_RC mutations=$DREL4_MUTS (want rc 1, 0, named)"
fi

# D-REL4b — the answer is a well-formed object id with no ref beside it. D-REL4
# lands on the "not an object id" arm, so without this row the ARITY guard is
# unexercised and deleting it stays green; what it costs is not a wrong answer
# but the loud diagnostic itself — an unguarded `fields[1]` is an IndexError
# traceback naming no upstream at all.
#
# Numbered `4b`, not `5`: this row is a second shape of D-REL4's "the remote
# answered with something unreadable" case, and `D-REL5` is spoken for by the
# register-validation loop that exits 2 — two rows reporting under one id, one
# asserting rc 1 and one rc 2, would break the only plan-row → test-row mapping
# this drive has.
TAGS_MODE=noref
run_drift "$WORK/drel4b.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
TAGS_MODE=ok
DREL4B_MUTS="$(gh_mutations "$WORK/drel4b.log")"
if [ "$DRIFT_RC" -eq 1 ] && [ "$DREL4B_MUTS" = "0" ] \
   && grep -qF -e 'no ref' <<<"$DRIFT_OUT" && names_an_upstream "$DRIFT_OUT" \
   && ! grep -qF -e 'Traceback' <<<"$DRIFT_OUT"; then
  ok "D-REL4b a ref-less tag line fails loudly by name, not by traceback"
else
  no "D-REL4b a ref-less tag line => rc=$DRIFT_RC mutations=$DREL4B_MUTS (want rc 1, 0, named, no traceback)"
fi

# D-REL4c — both fields parse, but the ref is not under `refs/tags`. The exact
# twin of D-REL4b: the answer is to a question this script never asked, and
# without the guard `match.group(1)` on a None match is an AttributeError —
# still a non-zero exit, but an anonymous one that names neither the upstream
# nor the ref. Guarding one arm and not the other is how a diagnostic contract
# rots into "it exits non-zero somehow".
TAGS_MODE=badref
run_drift "$WORK/drel4c.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]"
TAGS_MODE=ok
DREL4C_MUTS="$(gh_mutations "$WORK/drel4c.log")"
if [ "$DRIFT_RC" -eq 1 ] && [ "$DREL4C_MUTS" = "0" ] \
   && grep -qF -e 'not under refs/tags' <<<"$DRIFT_OUT" \
   && names_an_upstream "$DRIFT_OUT" \
   && ! grep -qF -e 'Traceback' <<<"$DRIFT_OUT"; then
  ok "D-REL4c a ref outside refs/tags is refused by name, not by traceback"
else
  no "D-REL4c a non-tag ref => rc=$DRIFT_RC mutations=$DREL4C_MUTS (want rc 1, 0, named, no traceback)"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

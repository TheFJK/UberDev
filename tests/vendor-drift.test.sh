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

# fingerprint_of <body> -> the drift-fingerprint the body carries, or empty.
# Read out of the RENDERED body rather than recomputed here: a second
# implementation of the payload would agree with itself while drifting from the
# one whose stability D9 and D-REL12 are about.
fingerprint_of() {
  python3 - "$1" <<'PY'
import re, sys
m = re.search(r"drift-fingerprint:\s*([0-9a-f]+)", sys.argv[1])
print(m.group(1) if m else "")
PY
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
FP="$(fingerprint_of "$DRIFT_OUT")"
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
echo "== D-REL5: a broken release review point is a malformed register, not an outage =="

# ---------------------------------------------------------------------------
# WHY THIS ROW EXISTS. #535 gives the register a SECOND kind of review point —
# a release label beside the recorded commit — and the tool orders that label
# against what upstream publishes. Every way of breaking it has the same shape
# as D13's missing component field and must land on the same verdict: rc 2, the
# offending upstream id and field named, before the first subprocess.
#
# Three of the six sub-cases are not hypothetical. A label that is not a string,
# or one that names no version, would pass any presence-only check, survive the
# whole tag resolution, and only THEN reach the ordering comparison — where
# `release_key` has returned None and `None` is not orderable against another
# key's tuple. That is an uncaught TypeError: rc 1, mid-run, after the network
# cost, wearing the exit code `fail()` reserves for "an upstream could not be
# resolved". D13b exists to keep those two codes apart; this row is what keeps
# them apart for the new field. Asserting rc != 0 would pass against exactly
# that bug, so every sub-case asserts the DIAGNOSIS: the code, the id, the
# offending field, a fragment of the CLAUSE that must have fired, no traceback,
# and a stub ledger with zero git and zero gh lines.
#
# The clause fragment is not belt-and-braces. Both diagnostics name
# `last_reviewed_release` — the half-review-point message quotes the label it
# found — so a `field`-only assertion passes while the WRONG clause fires, and
# the sub-cases stop distinguishing anything. Same reason the id is pinned as
# `upstream <id>`: the bare id is a substring of the slug that carries it.
#
# Every sub-case runs in BOTH modes. The guard sits on the same side of the
# `--verify-bases` return as the component-key loop precisely so the two modes
# cannot disagree about whether the register is readable — and only a
# `--verify-bases` assertion can hold it there. Moved just past that return the
# guard still precedes the drift path's first subprocess, so every drift-mode
# assertion below stays green while `--verify-bases` goes on to reach the
# network with a register it has already been told is broken.
# ---------------------------------------------------------------------------
REL_ROOT="$WORK/bad-release-register"
mkdir -p "$REL_ROOT/plugins/uberdev"
DREL5_FAILED=0
# Every DISTINCT exit code the sub-cases produced, so the separation asserted at
# the bottom covers all of them rather than whichever one happened to run last.
DREL5_CODES=""

# One invocation shape, so the two modes differ by their flags and nothing else.
# `"$@"` with no arguments is safe under `set -u` on every bash we run on.
run_drel5() {
  PATH="$STUBS:$PATH" \
  STUB_LOG="$WORK/drel5.log" \
  STUB_LSREMOTE_MODE=ok \
  STUB_HEAD_SHA="$MOVED_HEAD" \
  STUB_DIFF_FILES="" \
  STUB_OPEN_ISSUES="[]" \
  STUB_LSTREE_MODE=ok \
  STUB_TAGS_MODE=ok \
  STUB_TAGS_TABLE="$TAGS_DEFAULT" \
  python3 "$DRIFT" --repo-root "$REL_ROOT" "$@" 2>&1
}

for spec in "empty|last_reviewed_release|names a version this tool can order|a present-but-empty label" \
            "nonstring|last_reviewed_release|names a version this tool can order|a JSON number where a label belongs" \
            "unversioned|last_reviewed_release|names a version this tool can order|a label that names no version" \
            "buildmeta|last_reviewed_release|names a version this tool can order|a label whose only digits are build metadata" \
            "halfpoint|last_reviewed_commit|no 40-hex last_reviewed_commit|a label with no commit beside it" \
            "shortsha|last_reviewed_commit|no 40-hex last_reviewed_commit|a label beside a short sha"; do
  IFS='|' read -r mutation field clause desc <<<"$spec"
  # The mutated upstream id is DERIVED and echoed back, so the assertion below
  # pins the id the tool names against the id the fixture actually broke — a
  # typed literal would only prove this file agrees with itself.
  TARGET_ID="$(python3 - "$REGISTER" "$REL_ROOT/plugins/uberdev/vendor.json" "$mutation" "$DRIFT" <<'PY'
import importlib.util, json, re, sys

src, dst, mutation, drift = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# The `buildmeta` sub-case has to know what `release_key` actually keys, and a
# local re-implementation of that would be the very second-source-of-truth the
# fix removes: the fixture would keep agreeing with itself while the tool and
# the fixture drifted apart. Importing is side-effect free — the module guards
# `main()` behind `if __name__ == "__main__"`.
modspec = importlib.util.spec_from_file_location("vendor_drift", drift)
vendor_drift = importlib.util.module_from_spec(modspec)
modspec.loader.exec_module(vendor_drift)
release_key = vendor_drift.release_key

d = json.load(open(src, encoding="utf-8"))
ups = d.get("upstreams", {})
used = sorted({c["upstream"] for c in d.get("components", [])
               if c.get("origin") == "third-party"})
labelled = [u for u in used if ups.get(u, {}).get("last_reviewed_release")]
# Anti-vacuity. Mutating an upstream no component uses would exercise nothing —
# validation walks the USED set — and a register recording no release label at
# all has nothing here to break.
if not labelled:
    raise SystemExit("no USED upstream declares last_reviewed_release — every "
                     "sub-case would mutate a field the tool never reads")
target = labelled[0]
meta = ups[target]
label = meta["last_reviewed_release"]

if mutation == "empty":
    meta["last_reviewed_release"] = ""
elif mutation == "nonstring":
    # Derived from the recorded label rather than typed. An unquoted hand-edit
    # is what leaves a JSON number here, and the number still CARRIES digits —
    # so a digit check alone never sees it, only the type check does.
    nums = re.findall(r"\d+", label)
    if not nums:
        raise SystemExit("recorded release %r carries no digits to derive a "
                         "number from" % label)
    meta["last_reviewed_release"] = (float(".".join(nums[:2])) if len(nums) > 1
                                     else int(nums[0]))
elif mutation == "unversioned":
    # A non-empty string naming no version — the moving pointer (`latest`,
    # `stable`) an upstream publishes beside its releases, mis-recorded as a
    # review point. `release_key` returns None for it, which is the sub-case
    # that would otherwise surface as a TypeError at rc 1.
    moving = "latest"
    if re.search(r"\d", moving):
        raise SystemExit("%r carries a digit, so release_key would rank it as a "
                         "version and this sub-case would assert nothing"
                         % moving)
    meta["last_reviewed_release"] = moving
elif mutation == "buildmeta":
    # The label that separates "carries a digit" from "names a version".
    # SemVer §10 puts build metadata outside the version, and `release_key`
    # strips it BEFORE it looks for one — so digits living only after the `+`
    # satisfy a digit-counting predicate and still key to None. Without this
    # sub-case the guard can be weakened back to a re-implementation of
    # `release_key`'s parsing and the residual TypeError path reopens silently.
    nums = re.findall(r"\d+", label)
    if not nums:
        raise SystemExit("recorded release %r carries no digits to move behind "
                         "the build-metadata separator" % label)
    moving = "stable+" + ".".join(nums)
    if not re.search(r"\d", moving):
        raise SystemExit("%r carries no digit, so a digit-counting predicate "
                         "would already reject it and this sub-case would prove "
                         "nothing the 'unversioned' one does not" % moving)
    if release_key(moving) is not None:
        raise SystemExit("release_key(%r) is %r, not None — build metadata is no "
                         "longer stripped before the version is read, so this "
                         "sub-case no longer names an unorderable label"
                         % (moving, release_key(moving)))
    meta["last_reviewed_release"] = moving
elif mutation == "halfpoint":
    if meta.pop("last_reviewed_commit", None) is None:
        raise SystemExit("the labelled upstream carries no last_reviewed_commit "
                         "to remove — this sub-case would assert nothing")
elif mutation == "shortsha":
    # PRESENT but malformed, which `halfpoint` cannot reach: the 12-hex prefix
    # `git log --oneline` hands you is the realistic hand-edit, and it is
    # answered by the 40-hex half of the clause alone. Removing that half must
    # red something, or it is a clause no test can red.
    commit = meta.get("last_reviewed_commit")
    if not isinstance(commit, str) or not re.match(r"^[0-9a-f]{40}$", commit):
        raise SystemExit("the labelled upstream carries no 40-hex "
                         "last_reviewed_commit to truncate — this sub-case would "
                         "assert nothing")
    meta["last_reviewed_commit"] = commit[:12]
    if not meta["last_reviewed_commit"]:
        raise SystemExit("a truncated commit must still be a non-empty string, "
                         "else the type half of the clause answers this "
                         "sub-case and the 40-hex half stays untested")
else:
    raise SystemExit("unknown mutation %r" % mutation)

json.dump(d, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print(target)
PY
)" || { echo "  ABORT — could not build the '$mutation' release-register mutation"; exit 99; }
  for mode in drift verify-bases; do
    : > "$WORK/drel5.log"
    DREL5_RC=0
    if [ "$mode" = "verify-bases" ]; then
      DREL5_OUT="$(run_drel5 --verify-bases)" || DREL5_RC=$?
    else
      DREL5_OUT="$(run_drel5)" || DREL5_RC=$?
    fi
    case " $DREL5_CODES " in
      *" $DREL5_RC "*) ;;
      *) DREL5_CODES="$DREL5_CODES $DREL5_RC" ;;
    esac
    calls="$(grep -cE '^(git|gh) ' "$WORK/drel5.log" || true)"
    if [ "$DREL5_RC" -eq 2 ] && grep -qF -e "upstream $TARGET_ID" <<<"$DREL5_OUT" \
       && grep -qF -e "$field" <<<"$DREL5_OUT" \
       && grep -qF -e "$clause" <<<"$DREL5_OUT" \
       && ! grep -qF -e 'Traceback' <<<"$DREL5_OUT" && [ "$calls" = "0" ]; then
      continue
    fi
    DREL5_FAILED=1
    no "D-REL5 [$mode] $desc => rc=$DREL5_RC subprocess-calls=$calls (want rc 2, 'upstream $TARGET_ID', '$field' and '$clause' named, no traceback, no subprocess)"
    echo "        output: $(head -c 300 <<<"$DREL5_OUT")"
  done
done
# The separation, asserted rather than assumed, exactly as D13b does it for the
# component fields: a broken release review point (2) must stay distinguishable
# from a tag query upstream could not answer (1). D-REL3's code is reused here
# rather than re-run, so the two verdicts compared are the ones the suite
# actually observed — and the D-REL5 side is the SET of codes every sub-case in
# both modes produced, so one stray rc cannot hide behind the last one.
DREL5_CODES="${DREL5_CODES# }"
if [ "$DREL5_FAILED" -ne 0 ]; then
  :
elif [ "$DREL5_CODES" = "2" ] && [ "$DREL3_RC" -eq 1 ]; then
  ok "D-REL5 every broken release review point exits 2 in BOTH modes, named, before any subprocess, and stays distinct from an unanswerable tag query's rc 1"
else
  no "D-REL5 the two failure modes collide: broken release metadata={$DREL5_CODES}, unanswerable tag query=$DREL3_RC"
fi

echo
echo "== D-REL6-D-REL12: release verdicts, adjudication, and actionability (#535) =="

# ---------------------------------------------------------------------------
# WHY THESE ROWS EXIST. Resolving tags (D-REL1-D-REL4) only gives the job a
# second OBSERVABLE. #535 is about the second VERDICT: RFC 0019 §7 adjudicates
# releases, so "upstream cut a release you have not adjudicated" has to be a
# finding in its own right, actionable on its own, and distinguishable from raw
# HEAD drift in both directions.
#
# D-REL6 is the falsifiability anchor: it reproduces the 6.3.0 miss by
# construction — a freshly cut release, every watermark level, not one changed
# file — and demands an issue. Against a job that only reads HEAD that scenario
# is the quietest possible "no drift", so the row CANNOT pass without the
# verdict layer. Two more failure shapes it pins are one layer down and easy to
# ship half of:
#
#   * `build_report`'s third return value is what `main()` gates issue creation
#     on. A release finding rendered into a body that still reports "not
#     drifting" opens nothing at all — #535's failure moved one level deeper,
#     which is why D-REL6 asserts the LIVE run's `gh issue create` and not just
#     the body;
#   * the fingerprint decides whether an already-open issue gets a comment. A
#     payload that ignores release state fingerprints a new release identically
#     to last week, so the body is refreshed silently and nobody is told
#     (D-REL12).
#
# The rows deliberately cover all four verdicts that can disagree with the
# register — newer, vanished, moved, and the pre-release policy — because each
# is one line of the same lookup, and a half-shipped lookup is a control that is
# right about the case its author had in mind and silently wrong about the rest.
# ---------------------------------------------------------------------------

# The fixture set for these rows, all derived from $TAGS_DEFAULT and the
# committed register so no label, sha or id is ever typed. Kept separate from
# the D-REL1 builder above: these tables are MUTATIONS of the default one, and
# deriving them from it is what keeps them describing the same register.
REL_ENV="$WORK/tags-rel.env"
TAGS_NEWER="$WORK/tags-newer.tbl"
TAGS_VANISHED="$WORK/tags-vanished.tbl"
TAGS_NONE="$WORK/tags-none.tbl"
TAGS_MOVED="$WORK/tags-moved.tbl"
TAGS_RC_ONLY="$WORK/tags-rc-only.tbl"
TAGS_RC_RECORDED="$WORK/tags-rc-recorded.tbl"
TAGS_RC_PRE_ONLY="$WORK/tags-rc-pre-only.tbl"
TAGS_BUILDMETA="$WORK/tags-buildmeta.tbl"
TAGS_WORDSEP="$WORK/tags-wordsep.tbl"
TAGS_MOVED_NEWER="$WORK/tags-moved-newer.tbl"
TAGS_MOVED_NEWER2="$WORK/tags-moved-newer2.tbl"
RC_ROOT="$WORK/rc-review-point"
mkdir -p "$RC_ROOT/plugins/uberdev"
python3 - "$REGISTER" "$TAGS_DEFAULT" "$REL_ENV" "$TAGS_NEWER" "$TAGS_VANISHED" \
         "$TAGS_NONE" "$TAGS_MOVED" "$TAGS_RC_ONLY" "$TAGS_RC_RECORDED" \
         "$TAGS_RC_PRE_ONLY" "$TAGS_BUILDMETA" "$TAGS_WORDSEP" \
         "$TAGS_MOVED_NEWER" "$TAGS_MOVED_NEWER2" \
         "$RC_ROOT/plugins/uberdev/vendor.json" \
         "$LEAD_SLUG" "$LEAD_LABEL" "$NEWER_LABEL" "$NEWER_SHA" "$RC_LABEL" \
         "$RC_SHA" "$DRIFT" \
         <<'PY' || { echo "  ABORT — could not derive the release-verdict fixtures"; exit 99; }
import hashlib, importlib.util, json, re, shlex, sys

(reg, default_tbl, envfile, newer_tbl, vanished_tbl, none_tbl, moved_tbl,
 rc_only_tbl, rc_recorded_tbl, rc_pre_only_tbl, buildmeta_tbl, wordsep_tbl,
 moved_newer_tbl, moved_newer2_tbl, rc_register,
 lead_slug, lead_label, newer_label, newer_sha, rc_label,
 rc_sha, drift) = sys.argv[1:23]

# The ordering claims below are checked against the TOOL's own key, not against
# a local re-implementation of it: a fixture that keys versions itself would
# keep agreeing with itself while the two drifted apart, and every row here
# turns on which of two labels is newer. Importing is side-effect free — the
# module guards `main()` behind `if __name__ == "__main__"`.
modspec = importlib.util.spec_from_file_location("vendor_drift", drift)
vendor_drift = importlib.util.module_from_spec(modspec)
modspec.loader.exec_module(vendor_drift)
release_key = vendor_drift.release_key

d = json.load(open(reg, encoding="utf-8"))
ups = d.get("upstreams", {})
used = sorted({c["upstream"] for c in d.get("components", [])
               if c.get("origin") == "third-party"})
labelled = [u for u in used if ups.get(u, {}).get("last_reviewed_release")]
labelfree = [u for u in used if not ups.get(u, {}).get("last_reviewed_release")]
if not labelled:
    raise SystemExit("no used upstream declares last_reviewed_release — every "
                     "verdict row below would be vacuous")
if not labelfree:
    raise SystemExit("every used upstream declares last_reviewed_release — the "
                     "HEAD-only upstream D-REL10 contrasts against is gone")

lead = labelled[0]
meta = ups[lead]
# The two builders must agree about WHICH upstream leads, or the tables below
# would describe one upstream while the rows assert against another.
if meta["repo"] != lead_slug or meta["last_reviewed_release"] != lead_label:
    raise SystemExit("fixture builders disagree on the lead upstream: register "
                     "says %s/%s, the shell passed %s/%s"
                     % (meta["repo"], meta["last_reviewed_release"],
                        lead_slug, lead_label))
recorded_commit = meta["last_reviewed_commit"]

rows = [line.rstrip("\n").split("\t")
        for line in open(default_tbl, encoding="utf-8") if line.strip()]


def tag_name(ref):
    name = ref.split("refs/tags/", 1)[1]
    return name[:-3] if name.endswith("^{}") else name


def is_peel(ref):
    return ref.endswith("^{}")


def write(path, table):
    open(path, "w", encoding="utf-8").write(
        "".join("%s\t%s\t%s\n" % tuple(r) for r in table))


recorded_rows = [r for r in rows
                 if r[0] == lead_slug and tag_name(r[2]) == lead_label]
if len(recorded_rows) != 2:
    raise SystemExit("the default table carries %d row(s) for the recorded "
                     "label, not the annotated-tag pair these mutations are "
                     "derived from" % len(recorded_rows))

# The ordering every row below depends on, asserted with the tool's own key.
if not release_key(lead_label) < release_key(newer_label):
    raise SystemExit("%r does not rank above the recorded %r, so D-REL6 would "
                     "assert a 'newer release' that is not newer"
                     % (newer_label, lead_label))
if not release_key(lead_label) < release_key(rc_label) < release_key(newer_label):
    raise SystemExit("%r does not sit strictly between the recorded label and "
                     "%r, so D-REL11a would pass for the wrong reason: the "
                     "pre-release has to be ABOVE the review point for the "
                     "policy that excludes it to be what keeps it quiet"
                     % (rc_label, newer_label))

# D-REL6 / D-REL12: a release strictly newer than the recorded review point,
# with every watermark level. The 6.3.0 miss, by construction.
write(newer_tbl, rows + [[lead_slug, newer_sha, "refs/tags/%s" % newer_label]])

# D-REL8(a): the recorded label is gone while the remote still publishes other
# numbered releases — what a deleted or renamed release actually looks like.
kept = [r for r in rows
        if not (r[0] == lead_slug and tag_name(r[2]) == lead_label)]
if not [r for r in kept
        if r[0] == lead_slug and release_key(tag_name(r[2])) is not None]:
    raise SystemExit("removing the recorded label left the lead slug with no "
                     "numbered tag at all, which is D-REL8(b)'s case — (a) "
                     "would stop being a distinct shape")
write(vanished_tbl, kept)

# D-REL8(b): the remote publishes nothing whatsoever for that slug. The empty
# set has to reach the same verdict as (a) — `recorded not in published` — and
# not fall down a "no tags, nothing to compare" hole.
write(none_tbl, [r for r in rows if r[0] != lead_slug])

# D-REL9: the recorded label IS published, at a different commit. Only the PEEL
# line moves: the tag object's own oid is not what the register records, so
# rewriting that instead would prove nothing about the comparison.
moved_sha = hashlib.sha1(
    ("moved|%s|%s" % (lead_slug, lead_label)).encode("utf-8"),
    usedforsecurity=False).hexdigest()
# D-REL12's re-tag comparison needs a SECOND publishing commit for the same
# label, derived the same way.
moved_sha2 = hashlib.sha1(
    ("moved-again|%s|%s" % (lead_slug, lead_label)).encode("utf-8"),
    usedforsecurity=False).hexdigest()
if len({moved_sha[:12], moved_sha2[:12], recorded_commit[:12]}) != 3:
    raise SystemExit("the derived 'published elsewhere' commits collide with "
                     "each other or with the recorded one IN THE FIRST 12 HEX "
                     "— the report renders `published_commit[:12]` "
                     "(vendor-drift.py's `moved` finding), so full-40 "
                     "distinctness is not enough: D-REL9 would assert no "
                     "disagreement because both of the commits it names would "
                     "render as one token, and D-REL12's re-tag pair would "
                     "render one `upstream publishes ... at ...` line for "
                     "both runs — the only datum that moves between them — "
                     "so its re-tag comparison would be comparing a body "
                     "with itself")


def retagged(peel_sha):
    """The default table with the recorded label's peel line re-pointed."""
    return [[r[0],
             peel_sha if (r[0] == lead_slug
                          and tag_name(r[2]) == lead_label
                          and is_peel(r[2])) else r[1],
             r[2]] for r in rows]


write(moved_tbl, retagged(moved_sha))

# D-REL12's third comparison: the SAME `moved` verdict at two different
# published commits, with a release above the review point in both. That is the
# state in which `newest_commit` stops covering a re-tag — it names
# `<newer>`'s commit in both runs — so the only datum left that moves is the
# one the `moved` finding renders as `upstream publishes ... at ...`. It is
# also exactly the state in which a re-tag is most worth telling someone about.
newer_row = [lead_slug, newer_sha, "refs/tags/%s" % newer_label]
moved_newer_rows = retagged(moved_sha) + [newer_row]
moved_newer2_rows = retagged(moved_sha2) + [newer_row]
if len(moved_newer_rows) != len(moved_newer2_rows) or sum(
        1 for a, b in zip(moved_newer_rows, moved_newer2_rows) if a != b) != 1:
    raise SystemExit("the two re-tag tables differ in %d row(s), not exactly "
                     "one — a fingerprint difference between them would no "
                     "longer be attributable to the re-tag alone"
                     % sum(1 for a, b in zip(moved_newer_rows,
                                             moved_newer2_rows) if a != b))
write(moved_newer_tbl, moved_newer_rows)
write(moved_newer2_tbl, moved_newer2_rows)

# D-REL11(a): the only thing published above the recorded review point is a
# PRE-release. `<newer>` itself is deliberately absent from this table.
write(rc_only_tbl, rows + [[lead_slug, rc_sha, "refs/tags/%s" % rc_label]])

# D-REL11(b): the recorded review point is ITSELF a pre-release, published at
# the recorded commit, with a final release above it. The symmetric case: an
# upstream whose vocabulary is pre-release-shaped does owe adjudication.
rc_recorded_label = "%s-rc1" % lead_label
if rc_recorded_label == lead_label:
    raise SystemExit("the pre-release review point is identical to the "
                     "recorded label — this sub-case would model nothing")
if not release_key(rc_recorded_label) < release_key(newer_label):
    raise SystemExit("%r does not rank below %r, so D-REL11b's 'newer' verdict "
                     "would not be newer" % (rc_recorded_label, newer_label))
write(rc_recorded_tbl,
      rows + [[lead_slug, recorded_commit,
               "refs/tags/%s" % rc_recorded_label],
              [lead_slug, newer_sha, "refs/tags/%s" % newer_label]])
rc_reg = json.load(open(reg, encoding="utf-8"))
rc_reg["upstreams"][lead]["last_reviewed_release"] = rc_recorded_label
json.dump(rc_reg, open(rc_register, "w", encoding="utf-8"), indent=2,
          ensure_ascii=False)

# D-REL11(d): the same pre-release review point, with the ONLY name above it
# another PRE-release. This is the half of the policy `allow_pre` alone decides,
# and the half (b) cannot reach: (b) publishes a FINAL above the review point,
# which a candidate set with every pre-release stripped still reports as newer —
# so (b) reaches the same verdict, names the same release and passes whether the
# clause exists or not. Here `<newer>` itself is deliberately WITHHELD, so
# without the clause the newest candidate collapses to the plain recorded stem
# and the finding names a different release.
if not vendor_drift.is_prerelease(rc_label):
    raise SystemExit("%r is not a pre-release by the tool's own key, so this "
                     "sub-case would assert nothing about the clause that "
                     "admits one" % rc_label)
if not release_key(rc_recorded_label) < release_key(rc_label):
    raise SystemExit("%r does not rank above the pre-release review point %r, "
                     "so no 'newer release' verdict is owed for it"
                     % (rc_label, rc_recorded_label))
# ...and it must outrank the plain recorded stem too, which is the label the
# candidate set falls back to once pre-releases are excluded. Without this the
# two spellings would report the same name and the row would pin nothing.
if not release_key(lead_label) < release_key(rc_label):
    raise SystemExit("%r does not rank above %r, so excluding pre-releases "
                     "would report the same newest release and this sub-case "
                     "would be vacuous" % (rc_label, lead_label))
if [r for r in rows if tag_name(r[2]) == newer_label]:
    raise SystemExit("the default table already publishes the final %r, which "
                     "this sub-case must withhold" % newer_label)
write(rc_pre_only_tbl,
      rows + [[lead_slug, recorded_commit,
               "refs/tags/%s" % rc_recorded_label],
              [lead_slug, rc_sha, "refs/tags/%s" % rc_label]])

# D-REL11(c): two release names that CARRY the punctuation a pre-release
# carries, and are not pre-releases. SemVer §10 puts build metadata outside the
# version, and the `-` in `release-1.2.3` is a word separator — so both of these
# ARE releases above the review point, while the obvious way to spell the
# pre-release filter (a substring test for `-` or `+`) silently drops both. That
# is a miss of exactly the class #535 exists to close, and without this row the
# clause that prevents it is one no test can red.
newer_nums = re.findall(r"\d+", newer_label)
if not newer_nums:
    raise SystemExit("%r carries no digits to build a release name from"
                     % newer_label)
buildmeta_label = "%s+build.1" % newer_label
wordsep_label = "release-%s" % ".".join(newer_nums)
buildmeta_sha = hashlib.sha1(("buildmeta|%s" % buildmeta_label).encode("utf-8"),
                             usedforsecurity=False).hexdigest()
wordsep_sha = hashlib.sha1(("wordsep|%s" % wordsep_label).encode("utf-8"),
                           usedforsecurity=False).hexdigest()
for label, punctuation in ((buildmeta_label, "+"), (wordsep_label, "-")):
    # The row proves nothing unless the name really does carry the character a
    # substring test would trip on...
    if punctuation not in label:
        raise SystemExit("%r carries no %r, so a substring-based pre-release "
                         "filter would keep it and this sub-case would assert "
                         "nothing" % (label, punctuation))
    # ...and unless the tool's own key agrees it outranks the review point.
    if not release_key(lead_label) < release_key(label):
        raise SystemExit("%r does not rank above the recorded %r, so no "
                         "'newer release' verdict is owed for it"
                         % (label, lead_label))
write(buildmeta_tbl,
      rows + [[lead_slug, buildmeta_sha, "refs/tags/%s" % buildmeta_label]])
write(wordsep_tbl,
      rows + [[lead_slug, wordsep_sha, "refs/tags/%s" % wordsep_label]])

env = {
    "LEAD_ID": lead,
    "LEAD_COMMIT12": recorded_commit[:12],
    "MOVED_TAG_SHA12": moved_sha[:12],
    "RC_RECORDED_LABEL": rc_recorded_label,
    "BUILDMETA_LABEL": buildmeta_label,
    "WORDSEP_LABEL": wordsep_label,
}
open(envfile, "w", encoding="utf-8").write(
    "".join("%s=%s\n" % (k, shlex.quote(v)) for k, v in sorted(env.items())))
PY
. "$REL_ENV"

ADJUDICATION_HEADING='## Releases awaiting adjudication'
COMPONENT_HEADING='## Components with upstream changes since their watermark'

# D-REL6 — THE FALSIFIABILITY ANCHOR. Upstream cut a release the register has
# not adjudicated; HEAD has not moved, so not one file has changed. Against a
# HEAD-only job this is the quietest possible report, which is exactly how the
# 6.3.0 walk came to be triggered by a human noticing a directory in the plugin
# cache. The LIVE run is asserted too: a finding rendered into a body that
# `main()` still reads as "not drifting" opens no issue at all.
TAGS_TABLE="$TAGS_NEWER"
run_drift "$WORK/drel6-dry.log" ok "$WATERMARK" "" "[]" --dry-run
DREL6_RC="$DRIFT_RC"
DREL6_BODY="$DRIFT_OUT"
run_drift "$WORK/drel6.log" ok "$WATERMARK" "" "[]"
TAGS_TABLE=""
DREL6_FAILS=''
[ "$DREL6_RC" -eq 0 ] || DREL6_FAILS="dry-run rc=$DREL6_RC"
grep -qF -e "$ADJUDICATION_HEADING" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }no '$ADJUDICATION_HEADING' section"
grep -qF -e "### \`$LEAD_ID\`" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the finding does not name upstream $LEAD_ID"
# Body-wide presence, and deliberately NOT a claim about the finding: every one
# of these tokens is also printed by the neutral HEADs and tags blocks above, so
# a bare-token match here proves only that the run resolved what it was given.
# The lines the FINDING owns are asserted whole, further down.
for token in "$LEAD_LABEL" "$NEWER_LABEL" "${NEWER_SHA:0:12}"; do
  grep -qF -e "$token" <<<"$DREL6_BODY" \
    || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the report never names $token"
done
# The release finding must be its OWN section, not smuggled into the component
# diff — nothing has changed upstream, so that section must not exist here.
if grep -qF -e "$COMPONENT_HEADING" <<<"$DREL6_BODY"; then
  DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the release finding was rendered as component drift"
fi
if grep -qF -e '**No drift.**' <<<"$DREL6_BODY"; then
  DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the body claims no drift while carrying a release finding"
fi
# The per-id standing block is the OTHER half of that same summary, and it is
# just as free to contradict the section below it: every token asserted above
# also appears in the neutral `Upstream tags resolved this run:` block, so none
# of them reads the standing line. Assert the whole line — the id-and-slug
# keying together with the state-specific clause — or the standing may render
# `level` three lines above "upstream published a newer release".
DREL6_STANDING="- \`$LEAD_ID\` (\`$LEAD_SLUG\`): recorded \`$LEAD_LABEL\`; upstream has since published \`$NEWER_LABEL\`"
grep -qF -e "$DREL6_STANDING" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the standing block does not state the newer standing; want '$DREL6_STANDING'"
# A finding with no remedy is one no reader can clear. The remedy has to name
# the EDIT — both register fields, on THIS upstream. Asserting `RFC 0019 §7`
# alone would assert nothing: the section preamble already carries it.
DREL6_REMEDY="advance \`last_reviewed_release\` and \`last_reviewed_commit\` on \`upstreams.$LEAD_ID\`"
grep -qF -e "$DREL6_REMEDY" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the finding states no remedy; want '$DREL6_REMEDY'"
# ...and every finding names the remote it is about. The component section is
# absent here (asserted directly above), so its own differently-shaped
# `- upstream:` line cannot be what satisfies this.
grep -qF -e "- upstream: \`$LEAD_SLUG\`" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the finding does not name the upstream remote $LEAD_SLUG"
# The finding's two DATA lines, asserted whole for the same reason the standing
# line is: their tokens all leak from the blocks above, so nothing else in this
# row reads them. Both are load-bearing. Without the review point the reader is
# never told WHICH adjudication this delta is measured from — an upstream
# records more than one label over time. Without the newest release's commit
# there is no object id to review the delta AGAINST: a finding that names the
# release but not what it points at cannot be worked from.
DREL6_REVIEW_POINT="- recorded review point: \`$LEAD_LABEL\` (\`$LEAD_COMMIT12\`)"
grep -qF -e "$DREL6_REVIEW_POINT" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the finding does not state the recorded review point; want '$DREL6_REVIEW_POINT'"
DREL6_NEWEST="- newest published release: \`$NEWER_LABEL\` (\`${NEWER_SHA:0:12}\`)"
grep -qF -e "$DREL6_NEWEST" <<<"$DREL6_BODY" \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }the finding does not name the newest release and its commit; want '$DREL6_NEWEST'"
DREL6_CREATES="$(grep -cE '^gh issue create' "$WORK/drel6.log" || true)"
[ "$DREL6_CREATES" = "1" ] \
  || DREL6_FAILS="${DREL6_FAILS}${DREL6_FAILS:+; }gh issue create ran $DREL6_CREATES time(s), want 1"
if [ -z "$DREL6_FAILS" ]; then
  ok "D-REL6 a release newer than the recorded review point is a finding, and opens the issue on its own"
else
  no "D-REL6 an unadjudicated release was not reported: $DREL6_FAILS"
fi

# D-REL7 — the converse, and the noise control. HEAD has moved and files have
# changed, but upstream has published nothing above the recorded review point.
# Unreleased commits stay HEAD drift: rendering them as a release obligation is
# what teaches the reader to mute the issue.
run_drift "$WORK/drel7.log" ok "$MOVED_HEAD" "skills/writing-skills/SKILL.md" "[]" --dry-run
DREL7_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL7_FAILS="rc=$DRIFT_RC"
grep -qF -e "$COMPONENT_HEADING" <<<"$DRIFT_OUT" \
  || DREL7_FAILS="${DREL7_FAILS}${DREL7_FAILS:+; }the component drift section is gone"
if grep -qF -e "$ADJUDICATION_HEADING" <<<"$DRIFT_OUT"; then
  DREL7_FAILS="${DREL7_FAILS}${DREL7_FAILS:+; }unreleased commits were reported as a release obligation"
fi
if [ -z "$DREL7_FAILS" ]; then
  ok "D-REL7 HEAD drift with no new release stays HEAD drift, with no adjudication section"
else
  no "D-REL7 HEAD drift and release drift were conflated: $DREL7_FAILS"
fi

# D-REL8 — the recorded review point is not published upstream, in both shapes:
# other numbered releases still exist, and the remote publishes nothing at all.
# rc 0 is the load-bearing half. A published set that DISAGREES with the
# register is a finding, and exiting 1 would abort before `gh issue edit` and
# suppress the very thing it found — the discriminator is "could the query be
# answered?", not "did the answer please us".
DREL8_FAILED=0
for spec in "still-published|$TAGS_VANISHED" "publishes-nothing|$TAGS_NONE"; do
  IFS='|' read -r shape table <<<"$spec"
  TAGS_TABLE="$table"
  run_drift "$WORK/drel8-$shape-dry.log" ok "$WATERMARK" "" "[]" --dry-run
  DREL8_RC="$DRIFT_RC"
  DREL8_BODY="$DRIFT_OUT"
  run_drift "$WORK/drel8-$shape.log" ok "$WATERMARK" "" "[]"
  TAGS_TABLE=""
  DREL8_CREATES="$(grep -cE '^gh issue create' "$WORK/drel8-$shape.log" || true)"
  DREL8_FAILS=''
  [ "$DREL8_RC" -eq 0 ] || DREL8_FAILS="rc=$DREL8_RC, want 0"
  [ "$DREL8_CREATES" = "1" ] \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }gh issue create ran $DREL8_CREATES time(s), want 1"
  grep -qF -e 'is not published upstream' <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }no finding heading says the review point is not published upstream"
  grep -qF -e "$LEAD_LABEL" <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the report never names $LEAD_LABEL"
  grep -qF -e "### \`$LEAD_ID\`" <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the finding does not name upstream $LEAD_ID"
  # The standing block has to agree with the finding. Its clause is a DIFFERENT
  # string from the `###` heading asserted above, so this is not a duplicate:
  # the heading reads "...review point is not published upstream", the standing
  # line "...; not published upstream at all". Left unasserted, the standing may
  # report this upstream as level with a release it does not publish.
  DREL8_STANDING="- \`$LEAD_ID\` (\`$LEAD_SLUG\`): recorded \`$LEAD_LABEL\`; not published upstream at all"
  grep -qF -e "$DREL8_STANDING" <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the standing block does not state the vanished standing; want '$DREL8_STANDING'"
  # A heading and a review point are not a finding: without the diagnosis the
  # reader is never told what is wrong, and without the remedy there is no edit
  # that clears it. Both are prose no other assertion reads.
  grep -qF -e 'upstream publishes no tag by that name' <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the finding never diagnoses what disagrees"
  DREL8_REMEDY="reconcile \`upstreams.$LEAD_ID.last_reviewed_release\`"
  grep -qF -e "$DREL8_REMEDY" <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the finding states no remedy; want '$DREL8_REMEDY'"
  # ...and it has to say WHICH review point vanished. The bare `$LEAD_LABEL`
  # check above cannot: that token is also in the tags block and in the standing
  # line asserted just above, so the finding itself may state no review point at
  # all. On an upstream that has recorded more than one label over time, a
  # finding that names none of them is one no reader can act on.
  DREL8_REVIEW_POINT="- recorded review point: \`$LEAD_LABEL\` (\`$LEAD_COMMIT12\`)"
  grep -qF -e "$DREL8_REVIEW_POINT" <<<"$DREL8_BODY" \
    || DREL8_FAILS="${DREL8_FAILS}${DREL8_FAILS:+; }the finding does not state which review point vanished; want '$DREL8_REVIEW_POINT'"
  if [ -n "$DREL8_FAILS" ]; then
    DREL8_FAILED=1
    no "D-REL8 [$shape] a review point upstream does not publish: $DREL8_FAILS"
  fi
done
if [ "$DREL8_FAILED" -eq 0 ]; then
  ok "D-REL8 a review point upstream no longer publishes is reported at rc 0, in both shapes"
fi

# D-REL9 — the recorded label is published, at a commit the register has never
# seen: a release re-tagged in place, which is the one shape a sha comparison
# catches and a name comparison alone cannot. The finding has to name BOTH
# commits, or the reader cannot tell which side moved.
TAGS_TABLE="$TAGS_MOVED"
run_drift "$WORK/drel9-dry.log" ok "$WATERMARK" "" "[]" --dry-run
DREL9_RC="$DRIFT_RC"
DREL9_BODY="$DRIFT_OUT"
run_drift "$WORK/drel9.log" ok "$WATERMARK" "" "[]"
TAGS_TABLE=""
DREL9_CREATES="$(grep -cE '^gh issue create' "$WORK/drel9.log" || true)"
DREL9_FAILS=''
[ "$DREL9_RC" -eq 0 ] || DREL9_FAILS="rc=$DREL9_RC, want 0"
[ "$DREL9_CREATES" = "1" ] \
  || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }gh issue create ran $DREL9_CREATES time(s), want 1"
for token in "$LEAD_COMMIT12" "$MOVED_TAG_SHA12" "### \`$LEAD_ID\`"; do
  grep -qF -e "$token" <<<"$DREL9_BODY" \
    || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }the report never names $token"
done
# Neither sha above is a claim about the FINDING, and both leak in opposite
# directions: `$LEAD_COMMIT12` is a prefix of the 40-hex HEAD line (this
# fixture's watermark IS the recorded commit) and `$MOVED_TAG_SHA12` is what
# the neutral tags block prints as the newest tag's peel, since the re-tagged
# review point is still the newest name published here. So the row whose name
# is "naming both commits" needs both of the finding's own lines asserted
# WHOLE — otherwise the `moved` finding can ship as heading, slug and remedy,
# naming neither side of the disagreement it reports.
DREL9_REVIEW_POINT="- recorded review point: \`$LEAD_LABEL\` (\`$LEAD_COMMIT12\`)"
grep -qF -e "$DREL9_REVIEW_POINT" <<<"$DREL9_BODY" \
  || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }the finding does not state the recorded review point; want '$DREL9_REVIEW_POINT'"
DREL9_PUBLISHED="- upstream publishes \`$LEAD_LABEL\` at \`$MOVED_TAG_SHA12\`"
grep -qF -e "$DREL9_PUBLISHED" <<<"$DREL9_BODY" \
  || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }the finding does not name the commit upstream publishes; want '$DREL9_PUBLISHED'"
# Both shas above come from the finding block, so the standing block is again
# unread — and a standing that reports this upstream as level would contradict
# the re-tag finding directly beneath it.
DREL9_STANDING="- \`$LEAD_ID\` (\`$LEAD_SLUG\`): recorded \`$LEAD_LABEL\`; published upstream at a different commit"
grep -qF -e "$DREL9_STANDING" <<<"$DREL9_BODY" \
  || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }the standing block does not state the moved standing; want '$DREL9_STANDING'"
# The two shas are the diagnosis; this is the remedy, and it is a distinct
# string from the section preamble's own mention of the RFC.
DREL9_REMEDY='Re-adjudicate it under RFC 0019 §7'
grep -qF -e "$DREL9_REMEDY" <<<"$DREL9_BODY" \
  || DREL9_FAILS="${DREL9_FAILS}${DREL9_FAILS:+; }the finding states no remedy; want '$DREL9_REMEDY'"
if [ -z "$DREL9_FAILS" ]; then
  ok "D-REL9 a review point published at a different commit is reported, naming both commits"
else
  no "D-REL9 a re-tagged review point was mishandled: $DREL9_FAILS"
fi

# D-REL10 — the standing of EVERY used upstream is stated, keyed by upstream id
# and never by slug. Two ids can name two plugins inside one monorepo: they
# share a slug and therefore a tag list, so a slug-keyed report would attach
# that repo's releases to an upstream the register deliberately refuses to
# invent a label for. The assertion is a python3 pass over the body rather than
# a regex hairball, because the interesting claim is a NEGATIVE one about which
# tokens share a line.
run_drift "$WORK/drel10.log" ok "$WATERMARK" "" "[]" --dry-run
printf '%s\n' "$DRIFT_OUT" > "$WORK/drel10.body"
DREL10_MSG="$(python3 - "$REGISTER" "$WORK/drel10.body" "$LEAD_LABEL" <<'PY'
import json, sys

reg, body_path, recorded = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(reg, encoding="utf-8"))
ups = d.get("upstreams", {})
used = sorted({c["upstream"] for c in d.get("components", [])
               if c.get("origin") == "third-party"})
labelfree = [u for u in used if not ups.get(u, {}).get("last_reviewed_release")]
lines = open(body_path, encoding="utf-8").read().splitlines()

problems = []
if not labelfree:
    problems.append("no used upstream is label-free, so the negative assertion "
                    "below covers nothing")
if not any(ln.startswith("Recorded release review points:") for ln in lines):
    problems.append("the body carries no per-upstream release block")
for uid in used:
    if not [ln for ln in lines if ln.startswith("- ") and "`%s`" % uid in ln]:
        problems.append("upstream %s has no line of its own" % uid)
for uid in labelfree:
    naming = [ln for ln in lines if "`%s`" % uid in ln]
    if not any("HEAD-only" in ln for ln in naming):
        problems.append("%s is not described as a HEAD-only upstream" % uid)
    for ln in naming:
        if recorded in ln:
            problems.append("%s carries another upstream's recorded release "
                            "%s on one line: %s" % (uid, recorded, ln.strip()))
print("; ".join(problems))
PY
)"
# ...and the happy-path standing itself, asserted whole. This is the line the
# weekly report actually prints in the common case — every other row here drives
# a state that DISAGREES with the register — and the python pass above only
# checks that each id has a line, never what that line claims. Left unasserted,
# the `level` branch is free to report a vanished or re-tagged review point with
# no finding anywhere in the body to contradict it.
DREL10_STANDING="- \`$LEAD_ID\` (\`$LEAD_SLUG\`): recorded \`$LEAD_LABEL\`; level with the newest published release"
DREL10_LEVEL=''
grep -qF -e "$DREL10_STANDING" "$WORK/drel10.body" \
  || DREL10_LEVEL="the settled standing is not stated; want '$DREL10_STANDING'"
# ...and a standing the renderer does not know must be LOUD, never blank. The
# obvious alternative spelling is a dict lookup with an empty default, which
# renders an upstream with no standing at all — an omission in a report whose
# whole job is to say what has not been looked at. Driven by direct call
# because `release_verdict` is the only producer, so no fixture can reach it.
DREL10_LOUD="$(python3 - "$DRIFT" <<'PY'
import importlib.util, sys

modspec = importlib.util.spec_from_file_location("vendor_drift", sys.argv[1])
vendor_drift = importlib.util.module_from_spec(modspec)
modspec.loader.exec_module(vendor_drift)

bogus = {"id": "an-upstream", "slug": "org/repo", "recorded": "v1.0.0",
         "recorded_commit": "0" * 40, "published_commit": None,
         "newest": None, "newest_commit": None, "actionable": True,
         "state": "a-standing-nobody-taught-the-renderer"}
problems = []
for render in (vendor_drift.release_summary, vendor_drift.release_finding_lines):
    try:
        rendered = render(bogus)
    except ValueError:
        continue
    except Exception as exc:                     # noqa: BLE001 - reported, not swallowed
        problems.append("%s raised %r rather than a named ValueError"
                        % (render.__name__, exc))
        continue
    problems.append("%s rendered %r for an unknown standing instead of "
                    "refusing" % (render.__name__, rendered))
print("; ".join(problems))
PY
)"
# Accumulated the way every other row here accumulates, so the report names the
# check that failed: three separate probes behind one `${MSG:-default}` would
# report "no block at all" for a body whose block is perfectly well formed and
# whose standing line is merely wrong.
DREL10_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL10_FAILS="dry-run rc=$DRIFT_RC"
[ -z "$DREL10_MSG" ] \
  || DREL10_FAILS="${DREL10_FAILS}${DREL10_FAILS:+; }$DREL10_MSG"
[ -z "$DREL10_LEVEL" ] \
  || DREL10_FAILS="${DREL10_FAILS}${DREL10_FAILS:+; }$DREL10_LEVEL"
[ -z "$DREL10_LOUD" ] \
  || DREL10_FAILS="${DREL10_FAILS}${DREL10_FAILS:+; }$DREL10_LOUD"
if [ -z "$DREL10_FAILS" ]; then
  ok "D-REL10 every used upstream's release standing is reported by id, a settled one says so, a label-free one is HEAD-only, and an unknown standing is loud"
else
  no "D-REL10 the per-upstream release block is wrong: $DREL10_FAILS"
fi

# D-REL11 — the pre-release policy, asserted in BOTH directions. (a) a
# pre-release above the review point is not an obligation: an upstream that has
# published `<newer>-rc1` has not cut a release anyone must adjudicate, and a
# weekly finding that only clears when the final lands is noise that trains the
# reader to mute the control. (b) an upstream whose recorded review point is
# ITSELF a pre-release has a pre-release-shaped vocabulary, so the comparison
# must work there rather than reporting the recorded label as vanished — and
# (d) is what pins the CLAUSE that decides it, because (b) reaches its verdict
# off a final release and so passes with that clause deleted.
#
# (a) also pins the seam between the two blocks: the neutral tag OBSERVATION
# reports the rc as the newest published tag, while the release VERDICT stays
# level. Those two lines look contradictory read quickly, so the row asserts
# both — a later "fix" that made them agree would silently pick one of the two
# policies for both questions.
TAGS_TABLE="$TAGS_RC_ONLY"
run_drift "$WORK/drel11a.log" ok "$WATERMARK" "" "[]" --dry-run
TAGS_TABLE=""
DREL11A_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL11A_FAILS="rc=$DRIFT_RC"
if grep -qF -e "$ADJUDICATION_HEADING" <<<"$DRIFT_OUT"; then
  DREL11A_FAILS="${DREL11A_FAILS}${DREL11A_FAILS:+; }a pre-release was reported as a release awaiting adjudication"
fi
grep -qF -e "newest \`$RC_LABEL\`" <<<"$DRIFT_OUT" \
  || DREL11A_FAILS="${DREL11A_FAILS}${DREL11A_FAILS:+; }the tag observation stopped reporting the newest published tag"
if [ -z "$DREL11A_FAILS" ]; then
  ok "D-REL11a a pre-release above the review point is observed, but is not an adjudication finding"
else
  no "D-REL11a the pre-release policy is wrong: $DREL11A_FAILS"
fi

TAGS_TABLE="$TAGS_RC_RECORDED"
DRIFT_ROOT="$RC_ROOT"
run_drift "$WORK/drel11b.log" ok "$WATERMARK" "" "[]" --dry-run
DRIFT_ROOT="$REPO_ROOT"
TAGS_TABLE=""
DREL11B_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL11B_FAILS="rc=$DRIFT_RC"
grep -qF -e "$ADJUDICATION_HEADING" <<<"$DRIFT_OUT" \
  || DREL11B_FAILS="${DREL11B_FAILS}${DREL11B_FAILS:+; }no finding for a release above a pre-release review point"
grep -qF -e "$NEWER_LABEL" <<<"$DRIFT_OUT" \
  || DREL11B_FAILS="${DREL11B_FAILS}${DREL11B_FAILS:+; }the newer release is not named"
# The pre-release review point itself, quoted back. This is also what proves the
# run read the register COPY rather than the committed one, which records the
# plain label and would reach the same verdict for a different reason.
grep -qF -e "recorded review point: \`$RC_RECORDED_LABEL\`" <<<"$DRIFT_OUT" \
  || DREL11B_FAILS="${DREL11B_FAILS}${DREL11B_FAILS:+; }the finding does not quote the recorded pre-release review point"
if grep -qF -e 'is not published upstream' <<<"$DRIFT_OUT"; then
  DREL11B_FAILS="${DREL11B_FAILS}${DREL11B_FAILS:+; }the pre-release review point was read as vanished"
fi
if [ -z "$DREL11B_FAILS" ]; then
  ok "D-REL11b a pre-release review point is found by name, and a release above it is a finding"
else
  no "D-REL11b a pre-release review point is mishandled: $DREL11B_FAILS"
fi

# D-REL11c — the pre-release filter must be the tool's own PARSE, never a
# substring test. Both names below carry the punctuation a pre-release carries
# and are not pre-releases: SemVer §10 puts build metadata outside the version,
# and the `-` in `release-1.2.3` is a word separator, which `release_key`
# already handles because the stem carries no digit. Spelling the filter as
# `"-" in n or "+" in n` passes every other row in this suite and silently drops
# both of these — an upstream whose newest release is invisible to the control
# that exists to notice it, which is #535 again one level down.
DREL11C_FAILED=0
for spec in "build-metadata|$TAGS_BUILDMETA|$BUILDMETA_LABEL" \
            "word-separator|$TAGS_WORDSEP|$WORDSEP_LABEL"; do
  IFS='|' read -r shape table label <<<"$spec"
  TAGS_TABLE="$table"
  run_drift "$WORK/drel11c-$shape.log" ok "$WATERMARK" "" "[]" --dry-run
  TAGS_TABLE=""
  if [ "$DRIFT_RC" -eq 0 ] \
     && grep -qF -e "$ADJUDICATION_HEADING" <<<"$DRIFT_OUT" \
     && grep -qF -e "newest published release: \`$label\`" <<<"$DRIFT_OUT"; then
    continue
  fi
  DREL11C_FAILED=1
  no "D-REL11c [$shape] '$label' is a release above the review point, but no finding names it (rc=$DRIFT_RC)"
done
if [ "$DREL11C_FAILED" -eq 0 ]; then
  ok "D-REL11c a release name carrying pre-release punctuation is still a release, by the tool's own key"
fi

# D-REL11d — the OTHER half of the same policy, and the half (b) cannot reach.
# (b) publishes a final release above the pre-release review point, and a
# candidate set with every pre-release stripped still reports that final as
# newer — so (b) names the same release, reaches the same verdict, and passes
# whether "a pre-release counts when the review point is itself one" exists or
# not. Here the only name above the review point IS a pre-release: with the
# clause gone the newest candidate collapses back to the plain recorded stem,
# and the finding names a release the register adjudicated long ago. Same
# register copy as (b) — only the published set differs.
TAGS_TABLE="$TAGS_RC_PRE_ONLY"
DRIFT_ROOT="$RC_ROOT"
run_drift "$WORK/drel11d.log" ok "$WATERMARK" "" "[]" --dry-run
DRIFT_ROOT="$REPO_ROOT"
TAGS_TABLE=""
DREL11D_FAILS=''
[ "$DRIFT_RC" -eq 0 ] || DREL11D_FAILS="rc=$DRIFT_RC"
grep -qF -e "$ADJUDICATION_HEADING" <<<"$DRIFT_OUT" \
  || DREL11D_FAILS="${DREL11D_FAILS}${DREL11D_FAILS:+; }no finding for a pre-release above a pre-release review point"
grep -qF -e "recorded review point: \`$RC_RECORDED_LABEL\`" <<<"$DRIFT_OUT" \
  || DREL11D_FAILS="${DREL11D_FAILS}${DREL11D_FAILS:+; }the finding does not quote the recorded pre-release review point"
grep -qF -e "newest published release: \`$RC_LABEL\`" <<<"$DRIFT_OUT" \
  || DREL11D_FAILS="${DREL11D_FAILS}${DREL11D_FAILS:+; }the newest release named is not the pre-release the vocabulary admits"
if [ -z "$DREL11D_FAILS" ]; then
  ok "D-REL11d where the review point is a pre-release, a pre-release above it is the release owed adjudication"
else
  no "D-REL11d a pre-release-shaped vocabulary is not honoured: $DREL11D_FAILS"
fi

# D-REL12 — the fingerprint is what decides whether an ALREADY-OPEN issue gets
# a comment. Without release state in the payload, a freshly cut release with an
# unchanged file set fingerprints identically to last week: the body is
# refreshed, the comparison matches, no comment is posted, and the news lands
# where nobody is looking. Three runs, identical in every input except the
# published tag set, so the only thing that can move the fingerprint is the
# release state itself.
#
# These runs carry component drift as well, which the two-section ORDER is
# asserted on: this is the only scenario in the suite where both sections
# exist, and RFC 0019 §7 adjudicates releases, so they come first.
DREL12_FILES="skills/writing-skills/SKILL.md"
run_drift "$WORK/drel12a.log" ok "$MOVED_HEAD" "$DREL12_FILES" "[]" --dry-run
FP_A="$(fingerprint_of "$DRIFT_OUT")"
TAGS_TABLE="$TAGS_NEWER"
run_drift "$WORK/drel12b.log" ok "$MOVED_HEAD" "$DREL12_FILES" "[]" --dry-run
TAGS_TABLE=""
FP_B="$(fingerprint_of "$DRIFT_OUT")"
DREL12_BODY="$DRIFT_OUT"
run_drift "$WORK/drel12c.log" ok "$MOVED_HEAD" "$DREL12_FILES" "[]" --dry-run
FP_C="$(fingerprint_of "$DRIFT_OUT")"
DREL12_FAILS=''
[ -n "$FP_A" ] && [ -n "$FP_B" ] && [ -n "$FP_C" ] \
  || DREL12_FAILS="a run rendered no fingerprint at all"
[ "$FP_A" != "$FP_B" ] \
  || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }a new release did not move the fingerprint"
[ "$FP_A" = "$FP_C" ] \
  || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }two identical runs fingerprinted differently"
# ...and the same verdict at two different published commits. `newest_commit`
# covers a re-tag only while the recorded label IS the newest candidate; put a
# release above it and the re-tag is invisible to every other datum the payload
# carries, while the `moved` finding's `upstream publishes ... at ...` line
# changes underneath it. That is the state in which a re-tag matters most, so a
# silent refresh there is the same failure D-REL12 exists to close. The two
# tables differ in one peel sha and nothing else.
TAGS_TABLE="$TAGS_MOVED_NEWER"
run_drift "$WORK/drel12-retag1.log" ok "$WATERMARK" "" "[]" --dry-run
FP_RETAG1="$(fingerprint_of "$DRIFT_OUT")"
DREL12_RETAG_BODY="$DRIFT_OUT"
TAGS_TABLE="$TAGS_MOVED_NEWER2"
run_drift "$WORK/drel12-retag2.log" ok "$WATERMARK" "" "[]" --dry-run
FP_RETAG2="$(fingerprint_of "$DRIFT_OUT")"
TAGS_TABLE=""
# Both anti-vacuity arms: the verdict has to be `moved` (not `newer`), and the
# newest published release has to be a name OTHER than the re-tagged review
# point — otherwise `newest_commit` alone would move the fingerprint and the
# comparison would pin nothing.
grep -qF -e 'published at a different commit' <<<"$DREL12_RETAG_BODY" \
  || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }the re-tag runs do not report a moved review point"
grep -qF -e "newest \`$NEWER_LABEL\`" <<<"$DREL12_RETAG_BODY" \
  || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }the re-tag runs publish no release above the review point, so newest_commit would cover the re-tag"
[ -n "$FP_RETAG1" ] && [ -n "$FP_RETAG2" ] && [ "$FP_RETAG1" != "$FP_RETAG2" ] \
  || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }a review point re-tagged under a newer release did not move the fingerprint"
REL_AT="$(grep -nF -e "$ADJUDICATION_HEADING" <<<"$DREL12_BODY" || true)"
REL_AT="${REL_AT%%:*}"
COMP_AT="$(grep -nF -e "$COMPONENT_HEADING" <<<"$DREL12_BODY" || true)"
COMP_AT="${COMP_AT%%:*}"
if [ -n "$REL_AT" ] && [ -n "$COMP_AT" ]; then
  [ "$REL_AT" -lt "$COMP_AT" ] \
    || DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }the component diff is rendered above the release findings"
else
  DREL12_FAILS="${DREL12_FAILS}${DREL12_FAILS:+; }release drift and component drift do not both render (rel=${REL_AT:-none} comp=${COMP_AT:-none})"
fi
if [ -z "$DREL12_FAILS" ]; then
  ok "D-REL12 release state moves the fingerprint, is stable across identical runs, and is reported first"
else
  no "D-REL12 the fingerprint does not cover release state: $DREL12_FAILS"
fi

echo
echo "== D-REL13: the prose that explains the pre-release rule =="

# D-REL13 — the release rule is explained in three prose sites (`release_key`'s
# docstring, `is_prerelease`'s docstring, and the `#` comment run above
# `PRERELEASE_RANK`), and every one of them was making a claim the module does
# not implement. Prose that contradicts the code is worse than no prose: the
# next reader "simplifies" the function to match the comment, and the inversion
# this whole block exists to prevent comes back. So each claim is turned into a
# predicate and executed here.
#
# Six arms, each scoped to the claim ITS site makes — deliberately not one
# blanket rule, because the two docstrings cite different KINDS of example and
# one predicate cannot be right for both. `is_prerelease.__doc__` cites
# OVER-REPORT examples (names where a `-` substring test and `is_prerelease`
# disagree); the `PRERELEASE_RANK` comment cites a RANKING pair (`v6.4.0-rc1`
# under `v6.4.0`) where the two AGREE. Applying arm (a)'s predicate to the
# comment's pair would red on `v6.4.0-rc1` — a correct claim failing a
# mis-scoped test.
#
# Arms (c) and (d) exist because the third site is a COMMENT, and `ast` cannot
# see comments: a docstring-only predicate would leave it exactly as unguarded
# as it was. They read the `tokenize.COMMENT` stream instead.
#
#   (a) *pre-fix RED* — the docstring cited `v6.4.0+build`, which carries no
#       `-` at all, so it is not an example of the two answers disagreeing.
#   (b) *pre-fix RED* — the docstring cited a `0 if sep else 1` field that no
#       function body contains.
#   (c) DECLARED REGRESSION GUARD — green on both trees. Falsified by editing
#       the comment's example pair to two names that do not rank that way.
#   (d) DECLARED REGRESSION GUARD — green on both trees. Falsified by replacing
#       `is_prerelease`'s body with `return "-" in name`: the witness arm
#       empties and the row reds.
#   (e) DECLARED REGRESSION GUARD — green on both trees. Falsified two ways,
#       and the second is the one that matters: pinning `allow_pre = False` in
#       `release_candidates` reds the allow_pre-ON direction, and DELETING the
#       substring test itself (`substring_mod.is_prerelease =
#       vendor_drift.is_prerelease`) reds BOTH directions — which is the
#       property that says this arm is about the substring test rather than
#       about whatever the correct rule happens to do.
#   (f) DECLARED REGRESSION GUARD — green on both trees. Falsified by pointing
#       `release_candidates.__doc__`'s "no version at all" list at a label that
#       DOES key (`nightly` -> `v6.4.0`): the arm reds naming it. The
#       code-side mutations (dropping `release_key`'s `if not nums: return
#       None`, or its `name.split("+", 1)[0]`) were tried first and are NOT
#       usable as the declared mutation: both kill the `buildmeta`
#       release-register fixture builder, which surfaces as the suite-wide
#       `ABORT … exit 99` long before this row runs and so cannot be read as
#       "this arm reds". The `+` half was falsified out-of-suite instead —
#       against `core = name` it names `stable+2026`, clean on HEAD.
#
# Arms (a)-(d) execute what the prose says the RULE is; (e) executes what it
# says the CONSEQUENCE of getting it wrong is, (f) the DOMAIN the rule is
# stated over, and (g) the prose's citations of this row itself. An unexecuted
# consequence is how this row's own drafts shipped two false sentences in a
# row: first that an invented pre-release is "silently dropped" (true only
# while the recorded review point carries no hyphen), then that the invented
# name is the one KEPT and winning `max()` — which is what the CORRECT rule
# does with it, since an invented pre-release is a final release. Both were
# written as prose and believed; (e) is where such a sentence now has to
# survive being run against the real rule's answer.
#
# The (b) rule is NARROW on purpose — a backticked token carrying both ` if `
# and ` else `, i.e. a quoted conditional EXPRESSION. The obvious wider rule
# ("any backticked token with whitespace and a Python keyword") was executed
# against this tree and reds a CORRECT one: it also collects `recorded in
# candidates` and `recorded in published` from `release_verdict.__doc__`, which
# are English statements about a relation, not quotations of source, and appear
# in no body. Narrower and true beats wider and false.
#
# The stripper the (b) rule compares against deletes docstring LINE SPANS and
# comment TAIL SPANS. It deliberately does NOT round-trip the source through
# `tokenize.untokenize()` and then `str.replace(docstring, "")`: the round-trip
# reformats the source, the replace silently misses, the docstring survives, and
# the arm answers "the citation is present" on a tree where it is absent — a
# vacuous green inside the row whose whole job is to catch vacuous prose.
# Arm (g) reads this file, so it needs this file's own path — resolved here,
# absolutely, rather than left as whatever `$0` was spelled as on the command
# line, so the arm cannot be turned vacuous by the invocation.
DREL13_SELF="$(cd "$(dirname "$0")" && pwd)/${0##*/}"
DREL13_OUT="$(python3 - "$DRIFT" "$REGISTER" "$DREL13_SELF" <<'PY'
import ast
import importlib.util
import json
import re
import sys
import tokenize

drift, register, testfile = sys.argv[1], sys.argv[2], sys.argv[3]

modspec = importlib.util.spec_from_file_location("vendor_drift", drift)
vendor_drift = importlib.util.module_from_spec(modspec)
modspec.loader.exec_module(vendor_drift)

with open(drift, encoding="utf-8") as fh:
    source = fh.read()
# `split("\n")`, never `splitlines()`: this list is indexed by `tokenize` row
# numbers, and `tokenize` counts `\n` alone while `splitlines()` also breaks on
# `\f`, `\x0b`, `\x1c`-`\x1e` and `\x85`. One of those anywhere in the module
# desyncs the two numberings, and the stripper below then truncates the WRONG
# line — a vacuous green inside the arm whose job is catching vacuous prose.
srclines = source.split("\n")
tree = ast.parse(source)
with open(drift, "rb") as fh:
    comments = [t for t in tokenize.tokenize(fh.readline)
                if t.type == tokenize.COMMENT]

CITED = re.compile(r"`([^`\n]+)`")
VERSIONISH = re.compile(r"^v?\d+(\.\d+)*(-[0-9A-Za-z.]+)?$")
SCOPES = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
problems = []


def stripped_source():
    """The module with every docstring and comment removed, code intact.

    Line spans for docstrings (an `Expr` holding a `Constant` string is alone on
    its lines), tail spans for comments (a trailing `#` shares its line with the
    code the arm is looking for). Never `untokenize` + `str.replace`.
    """
    kept = list(srclines)
    for tok in comments:
        row, col = tok.start
        kept[row - 1] = kept[row - 1][:col]
    drop = set()
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(node, SCOPES) or not body:
            continue
        head = body[0]
        if (isinstance(head, ast.Expr)
                and isinstance(getattr(head, "value", None), ast.Constant)
                and isinstance(head.value.value, str)):
            drop.update(range(head.lineno, head.end_lineno + 1))
    return "\n".join(t for i, t in enumerate(kept, 1) if i not in drop)


def over_reports(name):
    """True when a `-` substring test and `is_prerelease` disagree about `name`.

    The one-directional claim itself, in one predicate, so arms (d) and (e)
    cannot drift apart about what "an invented pre-release" means.
    """
    return "-" in name and not vendor_drift.is_prerelease(name)


def prose():
    """Every docstring plus every comment — the module's whole claim surface."""
    out = []
    for node in ast.walk(tree):
        if isinstance(node, SCOPES):
            doc = ast.get_docstring(node, clean=False)
            if doc:
                out.append(doc)
    out.extend(t.string for t in comments)
    return "\n".join(out)


# (a) the over-report claim, scoped to `is_prerelease.__doc__`.
doc = vendor_drift.is_prerelease.__doc__ or ""
cited = [t for t in CITED.findall(doc) if "-" in t or "+" in t]
if len(cited) < 2:
    problems.append("(a) is_prerelease.__doc__ cites %d token(s) carrying `-` or "
                    "`+`, want >=2: %r" % (len(cited), cited))
if not any("+" in t for t in cited):
    problems.append("(a) no cited token carries build metadata (`+`), so SemVer "
                    "10 is claimed and never shown: %r" % (cited,))
# The count alone is a soft floor: the docstring also mentions the bare `-` it
# is talking ABOUT, which keys to None and so satisfies the over-report
# predicate trivially, without being an example of anything. Require two cited
# tokens that actually NAME a version, so the arm cannot be satisfied by
# incidental punctuation.
versioned_cited = [t for t in cited if vendor_drift.release_key(t) is not None]
if len(versioned_cited) < 2:
    problems.append("(a) only %d cited token(s) name a version, want >=2 — the "
                    "rest are incidental mentions, not examples: %r"
                    % (len(versioned_cited), cited))
for tok in cited:
    if not ("-" in tok and not vendor_drift.is_prerelease(tok)):
        problems.append("(a) cited token %r is not an over-report example "
                        "('-' in it: %s, is_prerelease: %s)"
                        % (tok, "-" in tok, vendor_drift.is_prerelease(tok)))

# (b) every cited conditional expression is really in the module's EXECUTABLE
# source. The haystack is the whole module with docstrings and comments removed
# — not function bodies alone — because a module-level constant is quotable
# source too, and the claim under test is "this prose quotes something that
# exists", not "…something inside a def".
conditionals = sorted({t for t in CITED.findall(prose())
                       if " if " in t and " else " in t})
if not conditionals:
    problems.append("(b) no conditional expression is cited anywhere in the "
                    "module's docstrings or comments, so this arm asserts "
                    "nothing")
body_source = stripped_source()
for tok in conditionals:
    if tok not in body_source:
        problems.append("(b) the cited conditional expression %r occurs nowhere "
                        "in the module's executable source" % (tok,))

# (c) the ranking claim the `PRERELEASE_RANK` comment run makes, over its own
# cited pair. `release_precedence` is what will own precedence once it exists;
# until then the same answer comes off `release_key`, so this arm is stable
# across that refactor rather than pinned to it.
assign_row = None
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "PRERELEASE_RANK":
                assign_row = node.lineno
whole_line = {t.start[0]: t.string for t in comments
              if srclines[t.start[0] - 1].lstrip().startswith("#")}
run = []
if assign_row is None:
    problems.append("(c) no module-level `PRERELEASE_RANK` assignment to anchor "
                    "the comment run on")
else:
    row = assign_row - 1
    while row in whole_line:
        run.append(whole_line[row])
        row -= 1
    run.reverse()
versioned = [t for t in CITED.findall("\n".join(run)) if VERSIONISH.match(t)]
precedence = getattr(vendor_drift, "release_precedence", vendor_drift.release_key)
if len(versioned) != 2:
    problems.append("(c) the comment run above PRERELEASE_RANK cites %d "
                    "version-shaped token(s), want exactly 2: %r"
                    % (len(versioned), versioned))
else:
    pre = [t for t in versioned if vendor_drift.is_prerelease(t)]
    final = [t for t in versioned if not vendor_drift.is_prerelease(t)]
    if len(pre) != 1:
        problems.append("(c) the comment's cited pair is not one pre-release and "
                        "one final: pre=%r final=%r" % (pre, final))
    else:
        pre_key, final_key = precedence(pre[0]), precedence(final[0])
        if pre_key is None or final_key is None:
            problems.append("(c) %s answers None for the comment's own pair "
                            "(%r -> %r, %r -> %r)"
                            % (precedence.__name__, pre[0], pre_key,
                               final[0], final_key))
        elif not pre_key < final_key:
            problems.append("(c) the comment's own example does not rank: %r does "
                            "not sort below %r" % (pre[0], final[0]))

# (d) the one-directional property itself, module-wide. The corpus is the
# shipped register's own labels plus a pinned adversarial list — pinned rather
# than generated because a generator built from `release_key` would agree with
# whatever `release_key` does.
with open(register, encoding="utf-8") as fh:
    registered = json.load(fh)
corpus = [meta.get("last_reviewed_release")
          for _, meta in sorted(registered.get("upstreams", {}).items())]
corpus = [n for n in corpus if isinstance(n, str) and n]
registered_labels = list(corpus)
corpus += ["v6.4.0-rc1", "release-1.2.3", "release-1.2.3-rc1",
           "pr-review-toolkit-v1.2.0", "pr-review-toolkit-v1.3.0-rc1",
           "v6.4.0+build", "v6.4.0+build-7", "latest", "stable+2026",
           "stable-nightly", "6.3.0", "v6.4.0+build1", ""]
under = [n for n in corpus if vendor_drift.is_prerelease(n) and "-" not in n]
witness = [n for n in corpus if over_reports(n)]
if under:
    problems.append("(d) is_prerelease answers True for a name carrying no `-`, "
                    "so the substring test UNDER-reports after all and the prose "
                    "is wrong again: %r" % (under,))
if not witness:
    problems.append("(d) no name in the corpus over-reports, so the claim all "
                    "three prose sites make is asserted over nothing")

# (e) the CONSEQUENCE clause the two prose sites state, in both of its
# directions. The clause needs its own arm because the obvious one-line version
# of it ("an invented pre-release is silently dropped from the candidate set")
# is only half the story, and the missing half is the dangerous one.
#
# WHERE the misread name lands is what decides which way the answer goes wrong,
# and the two landings are different failures, not one failure twice:
#
#   * as a CANDIDATE — the substring test invents a pre-release out of a
#     genuinely FINAL release, `allow_pre` is off because the recorded label
#     carries no hyphen, and the invention is filtered out of a candidate set it
#     belongs in. The newest release goes unreported;
#   * as the RECORDED review point — a final label whose hyphen is a word
#     separator is read as a pre-release, so `allow_pre`, which is computed by
#     the very test being hypothesised about, turns ON. The GENUINE
#     pre-releases that flag exists to exclude are then admitted, and one wins
#     `max()`: the `v6.4.0-rc1` > `v6.4.0` inversion itself.
#
# Both are executed against a SECOND module instance whose `is_prerelease` is
# the substring test, so arms (a)-(d) keep reading the real one and nothing
# here leaks into them — and both halves assert the DIFFERENTIAL, i.e. that the
# real rule answers something else. Asserting only the substring instance's
# answer is what an earlier draft of this arm did, and it guarded nothing:
# "a final release is kept in the candidate set" is what the CORRECT rule does
# too, so the half passed unchanged with the substring test deleted outright.
#
# The pairs are DERIVED from the same corpus, never typed. The candidate-side
# name is one the real classifier calls final while the substring test calls it
# a pre-release; the recorded-side name in the ON direction is the same kind of
# over-report, and what it wrongly admits is read off `is_prerelease` itself —
# so both track any change to what counts as a pre-release instead of silently
# changing meaning under it.
substrspec = importlib.util.spec_from_file_location("vendor_drift_substring", drift)
substring_mod = importlib.util.module_from_spec(substrspec)
substrspec.loader.exec_module(substring_mod)
substring_mod.is_prerelease = lambda name: "-" in name

# Two distinct synthetic 40-hex commits: the pair only has to differ and to
# satisfy SHA40_RE, so that `release_verdict` reaches the ranking branch rather
# than reporting `moved`.
SHA_RECORDED, SHA_OTHER = "a" * 40, "b" * 40
keyed = sorted({n for n in corpus if vendor_drift.release_key(n) is not None})
over_report = [n for n in keyed if over_reports(n)]
hyphen_free = [n for n in keyed if "-" not in n]
genuine_pre = [n for n in keyed if vendor_drift.is_prerelease(n)]


def outranking_pair(lows, highs):
    """The first (low, high) drawn from these pools that really ranks that way."""
    for high in highs:
        for low in lows:
            if low == high:
                continue
            low_key, high_key = precedence(low), precedence(high)
            if low_key is not None and high_key is not None and low_key < high_key:
                return low, high
    return None, None


def readings(recorded, other):
    """Both classifiers on the same two-tag upstream: (candidates, verdict) each.

    Returned substring-first, real-second — the arm compares the two, because
    an assertion about the substring instance ALONE is satisfied by whatever
    the correct rule already does.
    """
    published = {recorded: SHA_RECORDED, other: SHA_OTHER}
    meta = {"last_reviewed_release": recorded,
            "last_reviewed_commit": SHA_RECORDED}
    return [(mod.release_candidates(published, recorded),
             mod.release_verdict("d-rel13e", meta, published))
            for mod in (substring_mod, vendor_drift)]


# (e1) the misread name lands on a CANDIDATE. `allow_pre` is off on both sides,
# so the only difference is the invention itself.
plain_recorded, invented = outranking_pair(hyphen_free, over_report)
if plain_recorded is None:
    problems.append("(e) the corpus offers no pair with a hyphen-free recorded "
                    "label outranked by an over-reported name, so the DROPPED "
                    "direction asserts nothing")
else:
    (sub_cands, sub_verdict), (real_cands, real_verdict) = \
        readings(plain_recorded, invented)
    if invented in sub_cands:
        problems.append("(e) with recorded %r carrying no hyphen the substring "
                        "test should drop %r from the candidate set, but kept "
                        "it: %r" % (plain_recorded, invented,
                                    sorted(sub_cands)))
    elif sub_verdict["actionable"]:
        problems.append("(e) dropping %r still left an actionable verdict (%r), "
                        "so the prose's 'invisible to the control that exists to "
                        "notice it' is not what happens"
                        % (invented, sub_verdict["state"]))
    elif invented not in real_cands or not real_verdict["actionable"]:
        problems.append("(e) dropping %r is no differential: the REAL rule also "
                        "fails to report it (candidates %r, state %r, actionable "
                        "%s), so this direction indicts nothing"
                        % (invented, sorted(real_cands), real_verdict["state"],
                           real_verdict["actionable"]))

# (e2) the misread name lands on the RECORDED review point, so `allow_pre`
# turns on and admits a GENUINE pre-release the real rule filters out. Note the
# admitted name is NOT the over-report: an over-report is a final release, and
# keeping a final release is exactly what the correct rule does — which is why
# this half has to be selected off `is_prerelease` instead.
hyphen_recorded, admitted = outranking_pair(over_report, genuine_pre)
if hyphen_recorded is None:
    problems.append("(e) the corpus offers no over-reported recorded label "
                    "outranked by a genuine pre-release, so the allow_pre-ON "
                    "direction asserts nothing")
else:
    (sub_cands, sub_verdict), (real_cands, real_verdict) = \
        readings(hyphen_recorded, admitted)
    if admitted in real_cands:
        problems.append("(e) the REAL rule already admits %r for recorded %r "
                        "(candidates %r), so allow_pre is not off and this "
                        "direction indicts nothing"
                        % (admitted, hyphen_recorded, sorted(real_cands)))
    elif real_verdict["actionable"]:
        problems.append("(e) with %r excluded the REAL rule already calls this "
                        "upstream actionable (%r), so the substring test's "
                        "finding is not a false one to begin with"
                        % (admitted, real_verdict["state"]))
    elif admitted not in sub_cands:
        problems.append("(e) the substring test reads recorded %r as a "
                        "pre-release, so it must turn allow_pre ON and admit "
                        "%r; the candidate set is %r"
                        % (hyphen_recorded, admitted, sorted(sub_cands)))
    elif sub_verdict["newest"] != admitted:
        problems.append("(e) admitted %r did not win max(): newest is %r"
                        % (admitted, sub_verdict["newest"]))
    elif sub_verdict["state"] != "newer":
        problems.append("(e) %r was reported as newest without the `newer` "
                        "verdict the prose names: state is %r"
                        % (admitted, sub_verdict["state"]))

# (f) the ordering DOMAIN the three prose sites rest on. Two more claims the
# module states in prose and nothing executed, plus the one the register itself
# stands on:
#   * `release_candidates.__doc__` names the labels that "name no version at
#     all" — they must key to None, or the first filter it describes is fiction;
#   * `release_key`'s SemVer 10 comment says build metadata is stripped before
#     comparison, so what follows a `+` cannot decide whether a name IS a
#     version at all;
#   * `validate_release_metadata` refuses any recorded label `release_key`
#     cannot order, so every label the shipped register declares must key.
# The label list is read out of the docstring rather than typed, so the arm
# tracks the prose it is executing. The register half is empty-tolerant on
# purpose: RFC 0019's #511 amendment lets a monorepo plugin declare no release
# label at all, and this row must not pressure the register into inventing one.
unversioned = []
scoped = re.search(r"names no version at all \(([^)]*)\)",
                   vendor_drift.release_candidates.__doc__ or "")
if scoped is None:
    problems.append("(f) release_candidates.__doc__ no longer names the labels "
                    "it calls no version at all, so this arm asserts nothing")
else:
    unversioned = CITED.findall(scoped.group(1))
    if len(unversioned) < 2:
        problems.append("(f) release_candidates.__doc__ cites %d unorderable "
                        "label(s), want >=2: %r"
                        % (len(unversioned), unversioned))
for name in unversioned:
    if vendor_drift.release_key(name) is not None:
        problems.append("(f) release_candidates.__doc__ calls %r no version at "
                        "all, but release_key orders it as %r"
                        % (name, vendor_drift.release_key(name)))
metadata_bearing = [n for n in corpus if "+" in n]
if not metadata_bearing:
    problems.append("(f) no name in the corpus carries build metadata, so "
                    "SemVer 10 is asserted over nothing")
elif not any(vendor_drift.release_key(n) is not None for n in metadata_bearing):
    # The equivalence below is symmetric, so a corpus where every `+`-bearing
    # name keys to None on BOTH sides satisfies it while proving the opposite of
    # what SemVer 10 says. One positive witness is what makes it a claim.
    problems.append("(f) no name carrying build metadata names a version at "
                    "all, so SemVer 10 holds here only vacuously: %r"
                    % (sorted(metadata_bearing),))
for name in metadata_bearing:
    core = name.split("+", 1)[0]
    if (vendor_drift.release_key(name) is None) \
            != (vendor_drift.release_key(core) is None):
        problems.append("(f) build metadata decides whether %r names a version "
                        "at all (core %r keys %s, the full name keys %s), but "
                        "SemVer 10 puts it outside the version"
                        % (name, core,
                           vendor_drift.release_key(core) is not None,
                           vendor_drift.release_key(name) is not None))
for label in registered_labels:
    if vendor_drift.release_key(label) is None:
        problems.append("(f) the register declares %r, which release_key cannot "
                        "order — validate_release_metadata promises it refuses "
                        "exactly that label" % (label,))

# (g) the prose's citations OF THIS ROW. Two sites now end "D-REL13(e) executes
# both directions", which is itself an unexecuted claim — and it rots the same
# way every claim arms (a)-(f) execute rots: rename the row or drop the arm and
# the sentence quietly points at nothing. Reintroducing the defect one level up
# from where it was fixed is not a trade this row gets to make, so the citation
# is executed too: every `D-REL<n>(<arm>)` the module's prose names must be a
# row this file declares and an arm it really implements.
with open(testfile, encoding="utf-8") as fh:
    test_source = fh.read()
ROW_CITE = re.compile(r"\bD-REL(\d+)\(([a-z])\)")
cited_rows = sorted(set(ROW_CITE.findall(prose())))
if not cited_rows:
    problems.append("(g) the module's prose cites no test row of this file, so "
                    "this arm asserts nothing")
for row, arm in cited_rows:
    if ("== D-REL%s:" % row) not in test_source:
        problems.append("(g) the module's prose cites row D-REL%s(%s), but %s "
                        "declares no such row" % (row, arm, testfile))
    elif ("\n# (%s) " % arm) not in test_source:
        problems.append("(g) the module's prose cites arm (%s) of D-REL%s, but "
                        "%s implements no arm by that letter" % (arm, row, testfile))

print("; ".join(problems) if problems else "D-REL13-OK")
PY
)"
DREL13_RC=$?
DREL13_FAILS=''
[ "$DREL13_RC" -eq 0 ] \
  || DREL13_FAILS="the probe itself exited rc=$DREL13_RC — a traceback is not a pass"
# A silent probe is read as a FAILURE, never as "no problems": an empty capture
# is what a killed interpreter and a clean tree look like alike, so the clean
# tree has to say so out loud.
case "$DREL13_OUT" in
  D-REL13-OK) ;;
  '') DREL13_FAILS="${DREL13_FAILS}${DREL13_FAILS:+; }the probe printed nothing at all" ;;
  *)  DREL13_FAILS="${DREL13_FAILS}${DREL13_FAILS:+; }$DREL13_OUT" ;;
esac
if [ -z "$DREL13_FAILS" ]; then
  ok "D-REL13 every claim the module's prose makes about release names is executable and true"
else
  no "D-REL13 the module's prose claims something it does not do: $DREL13_FAILS"
fi

echo
echo "== D-REL16: the argv separator =="

# D-REL16 — an upstream's clone url is REGISTER-SUPPLIED (`upstreams.<id>.url`,
# or the default host plus its `repo` slug), and `run()` hands it to git as bare
# argv. A url beginning with `-` is then not a repository but an OPTION: git's
# own `--upload-pack=<cmd>` is executed on the spot, so editing one string in
# `vendor.json` becomes code execution on whoever runs the weekly job — and the
# job runs in CI, unattended, with a token. `--` before the url is what makes
# that unreachable, and it has to be there in BOTH queries. `resolve_head` and
# `resolve_tags` each hand the same register string to a separate `run()` call,
# so a separator on one of them leaves the whole path reachable through the
# other.
#
# Asserted from the stub's own LEDGER rather than by grepping the source: a
# third ls-remote call site added later is caught by this row whether or not
# whoever adds it remembers the row exists, which is not true of a grep for two
# known line numbers. Nothing here is typed — the url each invocation carried is
# matched back to the register's own derived slug list.
run_drift "$WORK/drel16.log" ok "$WATERMARK" "" "[]" --dry-run
DREL16_FAILS=''
[ "$DRIFT_RC" -eq 0 ] \
  || DREL16_FAILS="the happy-path run whose ledger this row reads exited rc=$DRIFT_RC"
DREL16_HEADQ=0
DREL16_TAGSQ=0
DREL16_BARE=''
DREL16_UNKNOWN=''
DREL16_NOURL=''
while IFS= read -r DREL16_LINE; do
  case "$DREL16_LINE" in
    "git ls-remote "*) ;;
    *) continue ;;
  esac
  # Walk past the flags git itself owns. The first token that is neither a flag
  # nor the separator is the url, and whatever sits immediately in front of it
  # is the token under test. Reading the POSITION rather than grepping for a
  # `--` anywhere on the line is deliberate: `--tags` also contains `--`, and a
  # separator landing after the url protects nothing.
  #
  # Walked with parameter expansion rather than `read -r -a`: this file has no
  # other array, and an array walk is the one shape here that would silently
  # mean something else under zsh (`read -a` is not zsh's array flag, and zsh
  # indexes from 1), so it would read as green while testing nothing. A token
  # that comes out empty — the only way doubled spaces could reach this — falls
  # to the `*` arm and is reported as "no url token", which is loud.
  DREL16_REST="${DREL16_LINE#git ls-remote}"
  DREL16_PREV=''
  DREL16_URL=''
  DREL16_TAGQ=0
  while [ -n "$DREL16_REST" ]; do
    DREL16_REST="${DREL16_REST# }"
    DREL16_TOK="${DREL16_REST%% *}"
    case "$DREL16_TOK" in
      --tags) DREL16_TAGQ=1; DREL16_PREV="$DREL16_TOK" ;;
      --)     DREL16_PREV="$DREL16_TOK" ;;
      *)      DREL16_URL="$DREL16_TOK"; break ;;
    esac
    case "$DREL16_REST" in
      *" "*) DREL16_REST="${DREL16_REST#* }" ;;
      *)     DREL16_REST='' ;;
    esac
  done
  if [ "$DREL16_TAGQ" -eq 1 ]; then
    DREL16_TAGSQ=$((DREL16_TAGSQ + 1))
  else
    DREL16_HEADQ=$((DREL16_HEADQ + 1))
  fi
  if [ -z "$DREL16_URL" ]; then
    [ -n "$DREL16_NOURL" ] || DREL16_NOURL="$DREL16_LINE"
    continue
  fi
  # Anti-vacuity on the token itself. Whatever the walk just decided was the url
  # has to name a registered upstream, or "the token after `--`" could be any
  # string at all and this row would report a pass over a line it never
  # understood. Same derivation the stub uses to answer the tag query: strip the
  # scheme, then the host, and what is left is the `repo` slug.
  DREL16_SLUG="${DREL16_URL#*://}"
  DREL16_SLUG="${DREL16_SLUG#*/}"
  grep -qxF -e "$DREL16_SLUG" "$ALL_SLUGS_FILE" \
    || { [ -n "$DREL16_UNKNOWN" ] || DREL16_UNKNOWN="$DREL16_LINE"; }
  [ "$DREL16_PREV" = "--" ] \
    || { [ -n "$DREL16_BARE" ] || DREL16_BARE="$DREL16_LINE"; }
done < "$WORK/drel16.log"
[ -z "$DREL16_NOURL" ] \
  || DREL16_FAILS="${DREL16_FAILS}${DREL16_FAILS:+; }an ls-remote invocation carries no url token at all: $DREL16_NOURL"
[ -z "$DREL16_UNKNOWN" ] \
  || DREL16_FAILS="${DREL16_FAILS}${DREL16_FAILS:+; }the token read as the url names no registered upstream: $DREL16_UNKNOWN"
[ -z "$DREL16_BARE" ] \
  || DREL16_FAILS="${DREL16_FAILS}${DREL16_FAILS:+; }a register-supplied url reaches git as a bare argument: $DREL16_BARE"
# ...and the ledger has to carry BOTH shapes. A `--`-carrying HEAD query proves
# nothing about the tag query, and an empty ledger would let every assertion in
# the loop above never run at all.
[ "$DREL16_HEADQ" -gt 0 ] \
  || DREL16_FAILS="${DREL16_FAILS}${DREL16_FAILS:+; }the ledger logs no HEAD ls-remote at all"
[ "$DREL16_TAGSQ" -gt 0 ] \
  || DREL16_FAILS="${DREL16_FAILS}${DREL16_FAILS:+; }the ledger logs no \`--tags\` ls-remote at all"
if [ -z "$DREL16_FAILS" ]; then
  ok "D-REL16 both ls-remote queries pass \`--\` before the register-supplied url"
else
  no "D-REL16 a register-supplied url is not separated from git's own options: $DREL16_FAILS"
fi

echo
echo "== Summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

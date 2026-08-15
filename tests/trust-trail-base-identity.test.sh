#!/usr/bin/env bash
# tests/trust-trail-base-identity.test.sh — issue #440.
#
# The /review-pr trust trail records WHAT was reviewed and at WHICH HEAD, but
# never against WHICH BASE. A GREEN verdict therefore survives a deliberate
# `gh pr edit <N> --base <other-branch>`: every trust artifact stays
# byte-identical, trust-trail-evaluator returns PASS, and /merge maps that to
# gate_pass while an entirely unreviewed delta rides in.
#
# Four layers, deliberately:
#
#   Layer C (carrier)  — EXECUTES the review_fleet_write_review_base /
#                        review_fleet_read_review_base pair. BASE_SHA is bound
#                        in one review-pr.md fence and consumed ~4000 lines and
#                        48 fences later; the #418/#419 class is exactly a value
#                        that "survives" only in the author's head. A round-trip
#                        test is the only thing that proves the carrier exists,
#                        and the refusal rows prove absence is typed rather than
#                        defaulted.
#
#   Layer D (delta)    — EXECUTES merge_resolve_base_delta_equivalence against a
#                        real git fixture. The naive predicate ("recomputed
#                        merge-base != recorded BASE_SHA => STALE") false-STALEs
#                        every child PR whose parent was squash-merged, which is
#                        UberDev's own default strategy. S1/S2/S3 and S6-S9 are
#                        the automatic post-merge retarget and MUST NOT be STALE;
#                        only the deliberate S4/S5/S10 may be. S6-S9 move the base
#                        inside a file the PR ALSO touches, which is what a
#                        diff-TEXT comparator gets wrong and what the original
#                        add-a-brand-new-file fixture could not express.
#
#   Layer E (fence)    — EXTRACTS the (b.5) fence from merge-pipeline/SKILL.md and
#                        EXECUTES it under both bash and zsh. Layer D certifies a
#                        LIB; production reaches it through a fence, and the two
#                        defects that shipped green here — a dereference of a name
#                        no fence binds, and a ref-NAME-only trigger that skips the
#                        probe entirely — are invisible to Layer D and to grep, and
#                        both fail in the direction that LOOKS like fail-closed
#                        correctness. Seed only what the fence may assume.
#
#   Layer S (shape)    — structural locks on the producer (review-pr.md), the
#                        consumer contract (trust-trail-evaluator.md,
#                        merge-pipeline/SKILL.md) and the security boundary that
#                        must NOT be widened while fixing this.
#
# Bash 3.2 compatible. No associative arrays, no `printf | grep -q` (that shape
# reds tests/epipe-guard.test.sh on both CI jobs) — herestrings throughout.

set -u
set -o pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"

REVIEW_PR_MD="$REPO_ROOT/plugins/uberdev/commands/review-pr.md"
AGENT_MD="$REPO_ROOT/plugins/uberdev/agents/trust-trail-evaluator.md"
MERGE_SKILL="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/SKILL.md"
FLEET_ARGS="$REPO_ROOT/plugins/uberdev/lib/review-fleet-args.sh"
BASE_IDENTITY_LIB="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/lib/base-identity.sh"
DISCOVER_LIB="$REPO_ROOT/plugins/uberdev/skills/merge-pipeline/lib/discover.sh"

for f in "$REVIEW_PR_MD" "$AGENT_MD" "$MERGE_SKILL" "$FLEET_ARGS"; do
  if [ ! -r "$f" ]; then
    echo "FATAL: required file missing or unreadable: $f" >&2
    exit 2
  fi
done

PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); shift; while [ "$#" -gt 0 ]; do echo "        $1"; shift; done; }

# assert_grep <desc> <file> <ERE>
assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -e "$pattern" "$file"; then ok "$desc"; else bad "$desc" "missing: $pattern" "in: $file"; fi
}

# assert_grep_fixed <desc> <file> <literal>
assert_grep_fixed() {
  local desc="$1" file="$2" literal="$3"
  if grep -qF -e "$literal" "$file"; then ok "$desc"; else bad "$desc" "missing literal: $literal" "in: $file"; fi
}

# assert_no_grep <desc> <file> <ERE>
assert_no_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -e "$pattern" "$file"; then bad "$desc" "unexpectedly present: $pattern" "in: $file"; else ok "$desc"; fi
}

# assert_all_in_section <file> <start ERE> <end ERE> <desc> <pattern>...
# Section-scoped and multi-token; an EMPTY range is its own loud failure so an
# anchor typo can never be mistaken for a satisfied contract.
assert_all_in_section() {
  local file="$1" start="$2" end="$3" desc="$4"
  shift 4
  local section missing="" pattern
  section="$(awk "/$start/,/$end/" "$file")"
  if [ -z "$section" ]; then
    bad "$desc" "section $start..$end is EMPTY — refusing a vacuous verdict"
    return
  fi
  for pattern in "$@"; do
    if ! grep -qE -e "$pattern" <<<"$section"; then
      missing="$missing
        missing: $pattern"
    fi
  done
  if [ -z "$missing" ]; then ok "$desc"; else
    echo "  FAIL  $desc"; echo "$missing"; FAIL=$((FAIL + 1))
  fi
}

echo "== TB-C: run-dir carrier for the reviewed base identity =="

CARRIER_TMP="$(mktemp -d)"
trap 'rm -rf "$CARRIER_TMP"' EXIT

SHA_A="1111111111111111111111111111111111111111"

# The carrier helpers are sourced, not grepped: #418 and #419 both shipped
# because a value that "obviously" reached the next fence did not.
# shellcheck disable=SC1090
if . "$FLEET_ARGS" 2>/dev/null; then
  :
else
  bad "TB-C.source: lib/review-fleet-args.sh sources cleanly" "source failed"
fi

if command -v review_fleet_write_review_base >/dev/null 2>&1; then
  ok "TB-C.1: review_fleet_write_review_base is defined"
else
  bad "TB-C.1: review_fleet_write_review_base is defined" "no such function in $FLEET_ARGS"
fi
if command -v review_fleet_read_review_base >/dev/null 2>&1; then
  ok "TB-C.2: review_fleet_read_review_base is defined"
else
  bad "TB-C.2: review_fleet_read_review_base is defined" "no such function in $FLEET_ARGS"
fi

_carrier_roundtrip() {
  local target="$CARRIER_TMP/roundtrip.tsv" got want
  rm -f "$target"
  if ! review_fleet_write_review_base "$target" "$SHA_A" "main" 2>/dev/null; then
    bad "TB-C.3: base identity round-trips through the carrier" "write refused a valid record"
    return
  fi
  got="$(review_fleet_read_review_base "$target" 2>/dev/null)" || {
    bad "TB-C.3: base identity round-trips through the carrier" "read refused the record it just wrote"
    return
  }
  want="$(printf '%s\t%s' "$SHA_A" "main")"
  if [ "$got" = "$want" ]; then ok "TB-C.3: base identity round-trips through the carrier"
  else bad "TB-C.3: base identity round-trips through the carrier" "want: $want" "got:  $got"; fi
}
command -v review_fleet_write_review_base >/dev/null 2>&1 && _carrier_roundtrip

_carrier_refuses() {
  local label="$1"; shift
  local target="$CARRIER_TMP/refuse.tsv"
  rm -f "$target"
  if review_fleet_write_review_base "$target" "$@" 2>/dev/null; then
    bad "TB-C.4.$label: writer refuses $label" "write accepted an invalid record"
  else
    ok "TB-C.4.$label: writer refuses $label"
  fi
}
if command -v review_fleet_write_review_base >/dev/null 2>&1; then
  _carrier_refuses short-sha "aaaa" "main"
  _carrier_refuses uppercase-sha "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "main"
  _carrier_refuses empty-ref "$SHA_A" ""
  _carrier_refuses tab-in-ref "$SHA_A" "$(printf 'ma\tin')"
  _carrier_refuses newline-in-ref "$SHA_A" "$(printf 'ma\nin')"
fi

_carrier_reader_refuses() {
  local label="$1" bytes="$2"
  local target="$CARRIER_TMP/reader.tsv" got
  rm -f "$target"
  printf '%s\n' "$bytes" >"$target"
  if got="$(review_fleet_read_review_base "$target" 2>/dev/null)"; then
    bad "TB-C.5.$label: reader refuses $label" "read returned: $got"
  else
    ok "TB-C.5.$label: reader refuses $label"
  fi
}
if command -v review_fleet_read_review_base >/dev/null 2>&1; then
  _carrier_reader_refuses empty ""
  _carrier_reader_refuses sha-only "$SHA_A"
  _carrier_reader_refuses bad-sha "$(printf 'nothex\tmain')"
  _carrier_reader_refuses third-field "$(printf '%s\tmain\textra' "$SHA_A")"
  # "the file is not there" and "the file says nothing" are the same answer:
  # cannot tell. Neither may be spelled as a default.
  rm -f "$CARRIER_TMP/absent.tsv"
  if review_fleet_read_review_base "$CARRIER_TMP/absent.tsv" >/dev/null 2>&1; then
    bad "TB-C.5.absent: reader refuses a missing carrier" "read succeeded on a missing file"
  else
    ok "TB-C.5.absent: reader refuses a missing carrier"
  fi
fi

echo "== TB-D: landed-delta equivalence across the five base-move scenarios =="

if [ ! -r "$BASE_IDENTITY_LIB" ]; then
  bad "TB-D.lib: merge-pipeline/lib/base-identity.sh exists" "missing: $BASE_IDENTITY_LIB"
else
  ok "TB-D.lib: merge-pipeline/lib/base-identity.sh exists"
fi

# Rewrite line N (1-indexed) of a 40-line shared file, portably and without
# python3: `sed -i` differs between GNU and BSD, so go through a temp file.
_set_line() {
  local file="$1" lineno="$2" text="$3"
  awk -v n="$lineno" -v t="$text" 'NR==n{print t; next}{print}' "$file" >"$file.tmp" \
    && mv "$file.tmp" "$file"
}
# Insert a NEW line before line N — the shape that shifts every later `@@`
# header and that no amount of `-U0` / `^index` stripping can normalise away.
_insert_line() {
  local file="$1" lineno="$2" text="$3"
  awk -v n="$lineno" -v t="$text" 'NR==n{print t}{print}' "$file" >"$file.tmp" \
    && mv "$file.tmp" "$file"
}

_build_matrix_fixture() {
  local root="$1" i
  git -C "$root" init -q -b main .            >/dev/null 2>&1 || return 1
  git -C "$root" config user.email t@example  >/dev/null 2>&1 || return 1
  git -C "$root" config user.name  Fixture    >/dev/null 2>&1 || return 1
  git -C "$root" config commit.gpgsign false  >/dev/null 2>&1 || return 1

  printf 'root\n' >"$root/base.txt"
  # A HOT SHARED FILE. The original fixture only ever moved the base by adding a
  # brand-new file, so every "the base advanced" row was vacuous with respect to
  # the reviewed delta — which is exactly how a diff-text comparator passed a
  # matrix that called itself the contract. In this repo children are routinely
  # retargeted to main while main accumulates PRs touching the same hot files, so
  # the shared-file rows below are the common path, not an edge.
  : >"$root/shared.txt"
  i=1
  while [ "$i" -le 40 ]; do printf 'l%d\n' "$i" >>"$root/shared.txt"; i=$((i + 1)); done
  git -C "$root" add base.txt shared.txt      >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm root              >/dev/null 2>&1 || return 1
  ROOT_SHA="$(git -C "$root" rev-parse HEAD)"

  # feat/A — the PR the child was stacked on.
  git -C "$root" checkout -q -b feat/A        >/dev/null 2>&1 || return 1
  printf '// A\n' >"$root/a.txt"
  _set_line "$root/shared.txt" 5 'l5-BY-A'    >/dev/null 2>&1 || return 1
  git -C "$root" add a.txt shared.txt         >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm A                 >/dev/null 2>&1 || return 1
  A_TIP="$(git -C "$root" rev-parse HEAD)"

  # feat/B — the reviewed PR. Reviewed delta is b.txt plus line 30 of shared.txt.
  git -C "$root" checkout -q -b feat/B        >/dev/null 2>&1 || return 1
  printf '// B\n' >"$root/b.txt"
  _set_line "$root/shared.txt" 30 'l30-BY-B'  >/dev/null 2>&1 || return 1
  git -C "$root" add b.txt shared.txt         >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm B                 >/dev/null 2>&1 || return 1
  B_TIP="$(git -C "$root" rev-parse HEAD)"

  REVIEWED_BASE="$(git -C "$root" merge-base "$B_TIP" "$A_TIP")"

  # S1 — automatic retarget after a MERGE-COMMIT landing of feat/A.
  git -C "$root" checkout -q -B s1-main "$ROOT_SHA" >/dev/null 2>&1 || return 1
  git -C "$root" merge -q --no-ff -m "merge A" "$A_TIP" >/dev/null 2>&1 || return 1
  S1_BASE="$(git -C "$root" rev-parse HEAD)"

  # S2 — automatic retarget after a SQUASH landing of feat/A (UberDev default).
  git -C "$root" checkout -q -B s2-main "$ROOT_SHA" >/dev/null 2>&1 || return 1
  git -C "$root" merge -q --squash "$A_TIP"   >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "squash A"        >/dev/null 2>&1 || return 1
  S2_BASE="$(git -C "$root" rev-parse HEAD)"

  # S3 — squash landing PLUS unrelated forward motion on main.
  git -C "$root" checkout -q -B s3-main "$S2_BASE" >/dev/null 2>&1 || return 1
  printf '// C\n' >"$root/c.txt"
  git -C "$root" add c.txt                    >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm C                 >/dev/null 2>&1 || return 1
  S3_BASE="$(git -C "$root" rev-parse HEAD)"

  # S4 — DELIBERATE retarget to the root branch: a.txt was never reviewed
  # against this base and now rides in.
  S4_BASE="$ROOT_SHA"

  # S5 — DELIBERATE retarget onto a branch that conflicts with the reviewed
  # delta. A conflicting merge is by definition not the reviewed delta.
  git -C "$root" checkout -q -B s5-main "$ROOT_SHA" >/dev/null 2>&1 || return 1
  printf '// NOT B\n' >"$root/b.txt"
  git -C "$root" add b.txt                    >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "conflicting b"   >/dev/null 2>&1 || return 1
  S5_BASE="$(git -C "$root" rev-parse HEAD)"

  # ---- The shared-file automatic-retarget rows. All three are the AUTOMATIC
  # post-merge retarget and all three MUST be `match`. Each one false-mismatched
  # under a diff-TEXT comparator, for a different reason.

  # S6 — base advanced in a file the PR also modifies, far from the PR's hunk.
  # Breaks on the `index <old-blob>..<new-blob>` header alone.
  git -C "$root" checkout -q -B s6-main "$S2_BASE" >/dev/null 2>&1 || return 1
  _set_line "$root/shared.txt" 15 'l15-BY-OTHER' >/dev/null 2>&1 || return 1
  git -C "$root" add shared.txt               >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "other edits l15" >/dev/null 2>&1 || return 1
  S6_BASE="$(git -C "$root" rev-parse HEAD)"

  # S7 — base edits a line INSIDE the reviewed hunk's 3-line context window.
  # Survives `^index` stripping; needs `-U0` or a tree comparison.
  git -C "$root" checkout -q -B s7-main "$S2_BASE" >/dev/null 2>&1 || return 1
  _set_line "$root/shared.txt" 28 'l28-BY-OTHER' >/dev/null 2>&1 || return 1
  git -C "$root" add shared.txt               >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "other edits l28" >/dev/null 2>&1 || return 1
  S7_BASE="$(git -C "$root" rev-parse HEAD)"

  # S8 — base INSERTS a line earlier in the shared file, shifting every later
  # `@@` header. Survives BOTH `^index` stripping and `-U0`; only a tree
  # comparison is immune. This is the row that says "normalise the text harder"
  # is not a fix.
  git -C "$root" checkout -q -B s8-main "$S2_BASE" >/dev/null 2>&1 || return 1
  _insert_line "$root/shared.txt" 10 'INSERTED-BY-OTHER' >/dev/null 2>&1 || return 1
  git -C "$root" add shared.txt               >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "other inserts"   >/dev/null 2>&1 || return 1
  S8_BASE="$(git -C "$root" rev-parse HEAD)"

  # S9 — the ordinary MID-STACK shape: the parent branch gained another commit
  # after the child branched off it, and then squash-landed. The recorded base is
  # where the child actually branched, which is no longer any commit on main.
  git -C "$root" checkout -q -B feat/A2 "$A_TIP" >/dev/null 2>&1 || return 1
  _set_line "$root/shared.txt" 2 'l2-BY-A2'   >/dev/null 2>&1 || return 1
  git -C "$root" add shared.txt               >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm A2                >/dev/null 2>&1 || return 1
  A2_TIP="$(git -C "$root" rev-parse HEAD)"
  git -C "$root" checkout -q -B s9-main "$ROOT_SHA" >/dev/null 2>&1 || return 1
  git -C "$root" merge -q --squash "$A2_TIP"  >/dev/null 2>&1 || return 1
  git -C "$root" commit -qm "squash A+A2"     >/dev/null 2>&1 || return 1
  S9_BASE="$(git -C "$root" rev-parse HEAD)"

  git -C "$root" checkout -q feat/B           >/dev/null 2>&1 || return 1
  return 0
}

MATRIX_ROOT="$CARRIER_TMP/matrix"
mkdir -p "$MATRIX_ROOT"
ROOT_SHA=; A_TIP=; B_TIP=; REVIEWED_BASE=; A2_TIP=
S1_BASE=; S2_BASE=; S3_BASE=; S4_BASE=; S5_BASE=
S6_BASE=; S7_BASE=; S8_BASE=; S9_BASE=

if ! _build_matrix_fixture "$MATRIX_ROOT"; then
  bad "TB-D.fixture: five-scenario git fixture builds" "git fixture construction failed"
elif [ ! -r "$BASE_IDENTITY_LIB" ]; then
  bad "TB-D.matrix: matrix cannot run without $BASE_IDENTITY_LIB" "library missing"
else
  ok "TB-D.fixture: five-scenario git fixture builds"
  # shellcheck disable=SC1090
  . "$BASE_IDENTITY_LIB" 2>/dev/null || true
  if ! command -v merge_resolve_base_delta_equivalence >/dev/null 2>&1; then
    bad "TB-D.fn: merge_resolve_base_delta_equivalence is defined" "no such function in $BASE_IDENTITY_LIB"
  else
    ok "TB-D.fn: merge_resolve_base_delta_equivalence is defined"
    _matrix_row() {
      local label="$1" current_base="$2" want="$3" got
      got="$(merge_resolve_base_delta_equivalence \
               "$MATRIX_ROOT" "$REVIEWED_BASE" "$B_TIP" "$current_base" "$B_TIP" 2>/dev/null)"
      if [ "$got" = "$want" ]; then ok "TB-D.$label (want $want)"
      else bad "TB-D.$label" "want: $want" "got:  ${got:-<empty>}"; fi
    }
    # Base never moved.
    _matrix_row "S0.unchanged-base"                "$REVIEWED_BASE" match
    # THE MANDATORY ROWS: the automatic post-merge retarget in all three shapes
    # lands exactly the reviewed bytes, so it MUST NOT be STALE. A false STALE
    # on every ordinary post-merge retarget trains the operator to ignore STALE,
    # which is worse than the bug being fixed.
    _matrix_row "S1.automatic-merge-commit"        "$S1_BASE"       match
    _matrix_row "S2.automatic-squash"              "$S2_BASE"       match
    _matrix_row "S3.automatic-squash-main-advanced" "$S3_BASE"      match
    # ...and the same automatic retarget where the base advanced in a file the
    # PR ALSO modifies. Every one of these false-mismatched under a diff-TEXT
    # comparator; S8 also defeats `-U0` + `^index` stripping, which is why the
    # predicate compares trees instead of normalising text harder.
    _matrix_row "S6.automatic-shared-file-advance"  "$S6_BASE"      match
    _matrix_row "S7.automatic-shared-file-in-context" "$S7_BASE"    match
    _matrix_row "S8.automatic-shared-file-insertion" "$S8_BASE"     match
    _matrix_row "S9.automatic-parent-advanced-mid-stack" "$S9_BASE" match
    # The real exploit.
    _matrix_row "S4.deliberate-retarget"           "$S4_BASE"       mismatch
    _matrix_row "S5.deliberate-retarget-conflicting" "$S5_BASE"     mismatch
    # A base REWOUND (or force-pushed, or delete-and-recreated) keeps its ref
    # NAME. The lib is right about it; the caller's trigger condition is what has
    # to actually reach the lib — Layer E below is where that is proven.
    _matrix_row "S10.base-rewound-same-name"       "$ROOT_SHA"      mismatch
    # Cannot tell is never match.
    _unavailable_row() {
      local label="$1" got; shift
      got="$(merge_resolve_base_delta_equivalence "$@" 2>/dev/null)"
      if [ "$got" = "unavailable" ]; then ok "TB-D.$label (want unavailable)"
      else bad "TB-D.$label" "want: unavailable" "got:  ${got:-<empty>}"; fi
    }
    _unavailable_row "U1.unknown-object" "$MATRIX_ROOT" "$REVIEWED_BASE" "$B_TIP" \
      "0000000000000000000000000000000000000001" "$B_TIP"
    _unavailable_row "U2.malformed-sha" "$MATRIX_ROOT" "$REVIEWED_BASE" "$B_TIP" "nope" "$B_TIP"
    _unavailable_row "U3.not-a-worktree" "$CARRIER_TMP/no-such-dir" "$REVIEWED_BASE" "$B_TIP" \
      "$S1_BASE" "$B_TIP"
  fi
fi

echo "== TB-E: the SHIPPED (b.5) fence is EXTRACTED and EXECUTED =="
# Layer D executes the LIB with hand-built arguments. That certifies a function
# production may never reach with those arguments — and it is exactly how a
# dereference of `$TRAILER_SHA`, a name no fence in the repo binds, shipped with
# the suite green: the expansion was empty, the helper's 40-hex domain check
# returned `unavailable`, and the evaluator mapped that to STALE. Every
# retargeted PR failed closed while looking like correct fail-closed behaviour.
# Layer S is grep-only and cannot see it. So: lift the real fence out of the
# Markdown and RUN it, seeding ONLY what the fence is allowed to assume. Never
# re-declare here a variable the fence is supposed to bind itself — that is the
# mistake being tested for.

E_FENCE="$CARRIER_TMP/b5-fence.sh"
awk '/^[[:space:]]*# BEGIN merge-base-identity-fence-v1$/,/^[[:space:]]*# END merge-base-identity-fence-v1$/' \
  "$MERGE_SKILL" | sed 's/^   //' > "$E_FENCE"
if [ -s "$E_FENCE" ] \
   && grep -q '^# BEGIN merge-base-identity-fence-v1$' "$E_FENCE" \
   && grep -q '^# END merge-base-identity-fence-v1$' "$E_FENCE"; then
  ok "TB-E.extract: the (b.5) fence is delimited and extractable"
else
  bad "TB-E.extract: the (b.5) fence is delimited and extractable" \
    "merge-pipeline/SKILL.md MUST delimit the b.5 bash with # BEGIN/# END merge-base-identity-fence-v1"
fi

E_READY=no
if [ ! -s "$E_FENCE" ]; then
  echo "  SKIP  TB-E.exec — no fence body was extracted"
elif ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  TB-E.exec — jq is required to execute the fence"
elif [ -z "$B_TIP" ]; then
  echo "  SKIP  TB-E.exec — the git fixture did not build"
else
  E_READY=yes
fi

if [ "$E_READY" = yes ]; then
  # An anchor commit exactly as /review-pr emits one: empty, carrying BOTH
  # trailers. TRUST_HEAD is this commit; TRAILER_SHA must be recovered from it.
  E_ANCHOR_MSG="$(printf 'chore(review-pr): trust trail anchor for #440\n\nReviewed-by: uberdev/review-pr@%s\nReviewed-base: uberdev/review-pr@%s ref=feat/A' \
                    "$B_TIP" "$REVIEWED_BASE")"
  git -C "$MATRIX_ROOT" checkout -q feat/B >/dev/null 2>&1
  git -C "$MATRIX_ROOT" commit -q --allow-empty --cleanup=verbatim -m "$E_ANCHOR_MSG" >/dev/null 2>&1
  E_TRUST_HEAD="$(git -C "$MATRIX_ROOT" rev-parse HEAD)"
  # A legacy anchor: Reviewed-by only, no Reviewed-base.
  git -C "$MATRIX_ROOT" commit -q --allow-empty --cleanup=verbatim \
    -m "$(printf 'chore(review-pr): trust trail anchor for #440\n\nReviewed-by: uberdev/review-pr@%s' "$B_TIP")" >/dev/null 2>&1
  E_LEGACY_HEAD="$(git -C "$MATRIX_ROOT" rev-parse HEAD)"
  # An anchor with NO Reviewed-by trailer at all.
  git -C "$MATRIX_ROOT" commit -q --allow-empty -m "no trailers here" >/dev/null 2>&1
  E_NOTRAILER_HEAD="$(git -C "$MATRIX_ROOT" rev-parse HEAD)"
  # A YELLOW anchor. review-pr.md appends TRAILER_SUFFIX
  # (` severity=critical-deferred count=N`, RFC 0002 §3.4) to the Reviewed-by
  # line, so a `$`-anchored 40-hex regex matches NOTHING on a deferred-critical
  # PR and the fence would refuse a trailer the producer really did write.
  git -C "$MATRIX_ROOT" commit -q --allow-empty --cleanup=verbatim \
    -m "$(printf 'chore(review-pr): trust trail anchor for #440\n\nReviewed-by: uberdev/review-pr@%s severity=critical-deferred count=2\nReviewed-base: uberdev/review-pr@%s ref=feat/A' \
            "$B_TIP" "$REVIEWED_BASE")" >/dev/null 2>&1
  E_YELLOW_HEAD="$(git -C "$MATRIX_ROOT" rev-parse HEAD)"

  E_RUNNER="$CARRIER_TMP/b5-runner.sh"
  cat >"$E_RUNNER" <<'E_RUNNER_EOF'
set -eu -o pipefail
# `-e -o pipefail` as well as `-u`: a no-match `grep` in the trailer extraction
# exits 1, and without `|| true` that would abort the fence before it could
# classify the very absence it exists to classify. The no-trailer rows below run
# under these flags precisely so that stays impossible.
# `set -u` is the point: any name the fence dereferences without binding is a
# hard error here rather than an empty string that degrades to `unavailable`.
# The fence may assume ONLY CLAUDE_PLUGIN_ROOT, TRUST_HEAD, PR_JSON and the cwd.
. "$UBERDEV_FENCE_BODY"
printf 'TRAILER_SHA=%s\n'             "${TRAILER_SHA-<unset>}"
printf 'REVIEWED_BASE_SHA=%s\n'       "${REVIEWED_BASE_SHA-<unset>}"
printf 'REVIEWED_BASE_REF=%s\n'       "${REVIEWED_BASE_REF-<unset>}"
printf 'CURRENT_BASE_REF=%s\n'        "${CURRENT_BASE_REF-<unset>}"
printf 'CURRENT_BASE_OID=%s\n'        "${CURRENT_BASE_OID-<unset>}"
printf 'BASE_DELTA_EQUIVALENCE=%s\n'  "${BASE_DELTA_EQUIVALENCE-<unset>}"
printf 'BASE_IDENTITY_REFUSAL=%s\n'   "${BASE_IDENTITY_REFUSAL-<unset>}"
E_RUNNER_EOF

  # e_field <output> <KEY>
  e_field() {
    awk -v k="$2" -F= 'index($0, k "=") == 1 { sub("^" k "=", ""); print; exit }' <<<"$1"
  }

  # _fence_row <label> <shell> <trust_head> <baseRefName> <baseRefOid> <KEY> <want>
  _fence_row() {
    local label="$1" shell="$2" head="$3" bref="$4" boid="$5" key="$6" want="$7"
    local out got
    out="$(cd "$MATRIX_ROOT" && \
           CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev" \
           UBERDEV_FENCE_BODY="$E_FENCE" \
           TRUST_HEAD="$head" \
           PR_JSON="$(printf '{"baseRefName":"%s","baseRefOid":"%s"}' "$bref" "$boid")" \
           "$shell" "$E_RUNNER" 2>/dev/null)"
    got="$(e_field "$out" "$key")"
    if [ "$got" = "$want" ]; then ok "TB-E.$label ($key=$want)"
    else bad "TB-E.$label" "want $key=$want" "got  $key=${got:-<empty>}" "full: $(tr '\n' ' ' <<<"$out")"; fi
  }

  for E_SHELL in bash zsh; do
    if ! command -v "$E_SHELL" >/dev/null 2>&1; then
      echo "  SKIP  TB-E.$E_SHELL — shell not installed"
      continue
    fi
    # THE BINDING ROW. With `$TRAILER_SHA` unbound this is `unavailable`, and the
    # whole automatic-retarget path silently STALEs.
    _fence_row "$E_SHELL.trailer-bound" "$E_SHELL" "$E_TRUST_HEAD" main "$S2_BASE" \
      TRAILER_SHA "$B_TIP"
    _fence_row "$E_SHELL.S2-automatic-squash" "$E_SHELL" "$E_TRUST_HEAD" main "$S2_BASE" \
      BASE_DELTA_EQUIVALENCE match
    _fence_row "$E_SHELL.S6-automatic-shared-file" "$E_SHELL" "$E_TRUST_HEAD" main "$S6_BASE" \
      BASE_DELTA_EQUIVALENCE match
    _fence_row "$E_SHELL.S8-automatic-insertion" "$E_SHELL" "$E_TRUST_HEAD" main "$S8_BASE" \
      BASE_DELTA_EQUIVALENCE match
    # Base genuinely unchanged — both endpoints equal — is the only licence for
    # the fast path.
    _fence_row "$E_SHELL.S0-unchanged-both-endpoints" "$E_SHELL" "$E_TRUST_HEAD" feat/A "$REVIEWED_BASE" \
      BASE_DELTA_EQUIVALENCE not_evaluated
    # THE TRIGGER ROW. Same ref NAME, different commit: a rewound / force-pushed /
    # recreated base. A name-only trigger reports `not_evaluated`, which asserts
    # "the base never moved" — a claim the caller has not established.
    _fence_row "$E_SHELL.S10-rewound-same-name" "$E_SHELL" "$E_TRUST_HEAD" feat/A "$ROOT_SHA" \
      BASE_DELTA_EQUIVALENCE mismatch
    _fence_row "$E_SHELL.S4-deliberate-retarget" "$E_SHELL" "$E_TRUST_HEAD" main "$ROOT_SHA" \
      BASE_DELTA_EQUIVALENCE mismatch
    # Legacy trail: no Reviewed-base line -> null, and the evaluator STALEs it.
    _fence_row "$E_SHELL.legacy-no-base-trailer" "$E_SHELL" "$E_LEGACY_HEAD" main "$S2_BASE" \
      REVIEWED_BASE_SHA null
    # No Reviewed-by trailer at all: refuse, never degrade.
    _fence_row "$E_SHELL.no-trailer-refuses" "$E_SHELL" "$E_NOTRAILER_HEAD" main "$S2_BASE" \
      BASE_IDENTITY_REFUSAL trust_trail_trailer_missing
    _fence_row "$E_SHELL.no-trailer-unavailable" "$E_SHELL" "$E_NOTRAILER_HEAD" main "$S2_BASE" \
      BASE_DELTA_EQUIVALENCE unavailable
    # YELLOW trail: the SHA must survive the trailer suffix, and the probe must
    # still run. A `$`-anchored regex turns every deferred-critical PR into a
    # refusal.
    _fence_row "$E_SHELL.yellow-suffix-sha" "$E_SHELL" "$E_YELLOW_HEAD" main "$S2_BASE" \
      TRAILER_SHA "$B_TIP"
    _fence_row "$E_SHELL.yellow-suffix-no-refusal" "$E_SHELL" "$E_YELLOW_HEAD" main "$S2_BASE" \
      BASE_IDENTITY_REFUSAL ""
    _fence_row "$E_SHELL.yellow-suffix-probe-runs" "$E_SHELL" "$E_YELLOW_HEAD" main "$S2_BASE" \
      BASE_DELTA_EQUIVALENCE match
  done
fi

echo "== TB-S1: producer — review-pr.md carries the base it reviewed against =="

assert_grep_fixed "TB-S1.1: the fence that BINDS BASE_SHA also resolves the base ref name" \
  "$REVIEW_PR_MD" 'BASE_REF_NAME='

assert_grep_fixed "TB-S1.2: the binding fence writes the base identity to a run-dir carrier" \
  "$REVIEW_PR_MD" 'review_fleet_write_review_base'

assert_grep_fixed "TB-S1.3: consumers read the base identity back off disk" \
  "$REVIEW_PR_MD" 'review_fleet_read_review_base'

assert_grep_fixed "TB-S1.4: the carrier has one canonical basename" \
  "$REVIEW_PR_MD" 'review-base-identity.tsv'

# The bind site must precede every read site; a reader above the writer is the
# #418/#419 shape wearing a carrier.
#
# One `awk` process, not `grep -n | head -1 | cut`: `head` exits after one line
# and EPIPEs its producer, and this file runs under `set -o pipefail` (and hosts
# a `set -e` runner below), so the pipeline shape is exactly the EPIPE class
# tests/epipe-guard.test.sh exists to keep out. `exit` after the first match
# needs no downstream reader at all.
_first_line_matching() {
  awk -v needle="$2" 'index($0, needle) { print NR; exit }' "$1"
}
_bind_line="$(_first_line_matching "$REVIEW_PR_MD" 'review_fleet_write_review_base')"
_first_read_line="$(_first_line_matching "$REVIEW_PR_MD" 'review_fleet_read_review_base')"
if [ -n "$_bind_line" ] && [ -n "$_first_read_line" ] && [ "$_bind_line" -lt "$_first_read_line" ]; then
  ok "TB-S1.5: the carrier writer precedes every carrier reader"
else
  bad "TB-S1.5: the carrier writer precedes every carrier reader" \
    "writer line: ${_bind_line:-<none>}" "first reader line: ${_first_read_line:-<none>}"
fi

# Both Phase-2 scope-refresh fences read a base they were already dereferencing
# across a shell boundary (the pre-existing half of this bug).
_refresh_count="$(grep -cF 'review_refresh_phase1_scope "$BASE_SHA"' "$REVIEW_PR_MD")"
_read_count="$(grep -cF 'review_fleet_read_review_base' "$REVIEW_PR_MD")"
if [ "$_read_count" -ge "$_refresh_count" ]; then
  ok "TB-S1.6: every review_refresh_phase1_scope site has a carrier read to feed it ($_read_count reads / $_refresh_count refreshes)"
else
  bad "TB-S1.6: every review_refresh_phase1_scope site has a carrier read to feed it" \
    "carrier reads: $_read_count" "scope refreshes: $_refresh_count"
fi

# Never a soft default: `${BASE_SHA:-...}` would turn "this fence cannot tell"
# into a silent answer.
assert_no_grep "TB-S1.7: BASE_SHA is never resolved through a :- default" \
  "$REVIEW_PR_MD" '\$\{BASE_SHA:-'
assert_no_grep "TB-S1.8: the reviewed base ref is never resolved through a :- default" \
  "$REVIEW_PR_MD" '\$\{BASE_REF_NAME:-|\$\{REVIEWED_BASE_SHA:-|\$\{REVIEWED_BASE_REF:-'

assert_grep "TB-S1.9: an unreadable base identity is a TYPED halt, not a default" \
  "$REVIEW_PR_MD" 'review_base_unreadable'
assert_grep "TB-S1.10: a base identity that cannot be persisted is typed at the writer" \
  "$REVIEW_PR_MD" 'review_base_uncarried'

echo "== TB-S2: producer — the anchor commit and audit JSON name the base =="

assert_grep_fixed "TB-S2.1: the anchor message carries a Reviewed-base trailer" \
  "$REVIEW_PR_MD" 'Reviewed-base: uberdev/review-pr@'
assert_grep "TB-S2.2: the Reviewed-base trailer names the base ref as well as its SHA" \
  "$REVIEW_PR_MD" 'Reviewed-base: uberdev/review-pr@%s ref=%s'
assert_grep_fixed "TB-S2.3: the existing Reviewed-by trailer is unchanged" \
  "$REVIEW_PR_MD" 'Reviewed-by: uberdev/review-pr@'

assert_grep "TB-S2.4: the audit JSON gains a top-level base member" \
  "$REVIEW_PR_MD" '"base":[[:space:]]*\{'
assert_grep "TB-S2.5: the audit JSON base member carries the reviewed base sha" \
  "$REVIEW_PR_MD" '"base":[[:space:]]*\{"sha":[[:space:]]*"\$\{REVIEWED_BASE_SHA\}"'
assert_grep "TB-S2.6: the audit JSON base member carries the reviewed base ref" \
  "$REVIEW_PR_MD" '"ref":[[:space:]]*"\$\{REVIEWED_BASE_REF\}"'

# Constraint 2: reuse the established legacy/STALE migration convention rather
# than inventing a second one. Section-scoped so the tokens have to appear in
# the paragraph that actually governs the member, not anywhere in a 6000-line
# file.
assert_all_in_section "$REVIEW_PR_MD" '^\*\*`base` member' '^\*\*`trust_trail_state` field' \
  "TB-S2.7: base-less audit JSON reuses the established legacy/STALE migration precedent" \
  '[Ll]egacy audit JSON without a `base` member' \
  'STALE' \
  '`legacy` audit state' \
  'malformed'

echo "== TB-S3: consumer — evaluator contract gains base identity, keeps its boundary =="

assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  "TB-S3.1: the four base-identity dispatch inputs are declared in ## Inputs" \
  'reviewed_base_sha' 'reviewed_base_ref' 'current_base_ref' 'base_delta_equivalence'

assert_all_in_section "$AGENT_MD" '^## Inputs' '^## Tools authorised' \
  "TB-S3.2: base_delta_equivalence declares its closed vocabulary" \
  'match' 'mismatch' 'unavailable' 'not_evaluated'

assert_all_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  "TB-S3.3: a base gate runs BEFORE the structural primitives" \
  'base identity gate|Base identity gate' 'STALE'

assert_all_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  "TB-S3.4: the gate STALEs a mismatch and falls through on match" \
  'base_delta_equivalence == "mismatch"' 'base_delta_equivalence == "match"'

assert_all_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  "TB-S3.5: unreadable base identity fails closed to STALE, never PASS" \
  'base_delta_equivalence == "unavailable"'

assert_all_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  "TB-S3.6: a trail with no recorded base is STALE per the legacy precedent" \
  'reviewed_base_sha` is `null`|reviewed_base_sha == "null"'

# The automatic path must be explicitly documented as NOT stale, so a future
# edit cannot "simplify" the gate into the naive merge-base comparison.
assert_all_in_section "$AGENT_MD" '^## Process' '^## Refusal triggers' \
  "TB-S3.7: the automatic post-merge retarget is documented as NOT stale" \
  'automatic post-merge retarget'

# CONSTRAINT 1 — the allowlist is a deliberate security boundary.
assert_all_in_section "$AGENT_MD" '^## Tools authorised' '^## Process' \
  "TB-S3.8: the tool allowlist was NOT widened (still no gh, still the same four primitives)" \
  'git merge-base' 'No `gh`'
# Section-scoped negative: the Inputs section legitimately NAMES merge-tree in
# order to say the agent does not have it. The allowlist itself must not.
_tools_section="$(awk '/^## Tools authorised/,/^## Process/' "$AGENT_MD")"
if [ -z "$_tools_section" ]; then
  bad "TB-S3.9: the evaluator's allowlist never gained merge-tree" "## Tools authorised section is EMPTY"
elif grep -qE -e 'merge-tree' <<<"$_tools_section"; then
  bad "TB-S3.9: the evaluator's allowlist never gained merge-tree" \
    "merge-tree appears inside ## Tools authorised — the boundary was widened"
else
  ok "TB-S3.9: the evaluator's allowlist never gained merge-tree"
fi
# ...and the negation in Inputs must actually be a negation, not a grant.
assert_all_in_section "$AGENT_MD" '^### Base-identity inputs' '^\*\*You MUST NOT re-fetch' \
  "TB-S3.10: the base inputs are declared caller-computed, not agent-probed" \
  'caller-computed' 'no `git merge-tree`'

echo "== TB-S4: caller — /merge threads the base identity it alone can see =="

assert_grep_fixed "TB-S4.1: the cached PR projection now includes baseRefOid" \
  "$MERGE_SKILL" 'baseRefOid'
assert_grep_fixed "TB-S4.2: the lib projection asks gh for baseRefOid" \
  "$DISCOVER_LIB" 'baseRefOid'
assert_grep_fixed "TB-S4.3: the caller extracts the Reviewed-base trailer" \
  "$MERGE_SKILL" 'Reviewed-base: uberdev/review-pr@'
assert_grep_fixed "TB-S4.4: the caller computes base delta equivalence itself" \
  "$MERGE_SKILL" 'merge_resolve_base_delta_equivalence'
assert_grep "TB-S4.5: the four base inputs are threaded into the dispatch prompt" \
  "$MERGE_SKILL" 'reviewed_base_sha='
assert_grep "TB-S4.6: current_base_ref is threaded into the dispatch prompt" \
  "$MERGE_SKILL" 'current_base_ref='
assert_grep "TB-S4.6b: current_base_oid is threaded too — a ref NAME is not base identity" \
  "$MERGE_SKILL" 'current_base_oid='
assert_grep "TB-S4.7: base_delta_equivalence is threaded into the dispatch prompt" \
  "$MERGE_SKILL" 'base_delta_equivalence='
assert_grep "TB-S4.8: the fast path avoids the probe when the base ref never moved" \
  "$MERGE_SKILL" 'not_evaluated'

# Constants rows: a helper nobody can find is a helper the next edit re-inlines.
assert_grep "TB-S4.9: the base trailer prefix is a declared constant" \
  "$MERGE_SKILL" '`REVIEW_PR_BASE_TRAILER_PREFIX`'
assert_grep "TB-S4.10: the delta-equivalence helper is a declared constant" \
  "$MERGE_SKILL" '`BASE_IDENTITY_HELPER`'
assert_grep "TB-S4.11: the equivalence vocabulary is a declared constant" \
  "$MERGE_SKILL" '`BASE_DELTA_EQUIVALENCE_ENUM`'
# The naive predicate must stay explicitly forbidden at the call site, not just
# implicitly avoided: it is the reading the issue title invites.
assert_grep "TB-S4.12: the naive merge-base predicate is explicitly forbidden" \
  "$MERGE_SKILL" 'NEVER "the merge-base moved"'
# The fast path must require BOTH endpoints. A ref-name-only trigger reports
# `not_evaluated`, which ASSERTS "the base never moved" — so the caller would be
# claiming, on no evidence, exactly what the gate exists to check.
assert_grep_fixed "TB-S4.13: the fast path also requires the base OID to be unchanged" \
  "$MERGE_SKILL" '[ "$REVIEWED_BASE_SHA" != "$CURRENT_BASE_OID" ]'
# The probe must be reachable with a trailer SHA THIS fence bound.
assert_grep_fixed "TB-S4.14: the b.5 fence binds TRAILER_SHA itself" \
  "$MERGE_SKILL" 'TRAILER_SHA="${TRUST_TRAILER_LINE#Reviewed-by: uberdev/review-pr@}"'
assert_grep_fixed "TB-S4.15: a missing/short trailer REFUSES rather than degrading" \
  "$MERGE_SKILL" 'BASE_IDENTITY_REFUSAL=trust_trail_trailer_missing'
# The gate's own scenario is the one where the clone is most likely stale, and
# /merge does not fetch until Phase 3.
assert_grep_fixed "TB-S4.16: an unavailable probe gets ONE bounded fetch and re-probe" \
  "$MERGE_SKILL" 'git fetch --prune --quiet origin "$CURRENT_BASE_REF"'
# Trees, not diff text — the normalisation dead end must stay closed.
assert_grep_fixed "TB-S4.17: the probe compares trees, not two git diff texts" \
  "$MERGE_SKILL" '--merge-base=<REVIEWED_BASE_SHA>'
assert_no_grep "TB-S4.18: the lib never compares rendered diff text" \
  "$BASE_IDENTITY_LIB" 'reviewed_delta|landed_delta'
assert_grep_fixed "TB-S4.19: the lib pins the reviewed delta with an explicit merge base" \
  "$BASE_IDENTITY_LIB" '--merge-base="$reviewed_base"'

echo
echo "trust-trail-base-identity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

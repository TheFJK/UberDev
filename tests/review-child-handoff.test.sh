#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW="$ROOT/plugins/uberdev/commands/review-pr.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

sed -n '/BEGIN review-child-builder-v1/,/END review-child-builder-v1/p' "$REVIEW" \
  | sed '/BEGIN review-child-builder-v1/d;/END review-child-builder-v1/d;/^```/d' >"$TMP/builder.sh"
[ -s "$TMP/builder.sh" ]

cat >"$TMP/run.sh" <<'SH'
set -euo pipefail
. "$1"
LOG="$2"; RUN="$3"; mkdir -p "$RUN"
uberdev_create_child_handoff() {
  local edge="$1" instance="$2"
  printf 'create %s %s %s %s\n' "$@" >>"$LOG"
  UBERDEV_CHILD_HANDOFF="$RUN/$instance.handoff"
  UBERDEV_CHILD_RESULT="$RUN/$instance.result"
  UBERDEV_CHILD_STATUS="$RUN/$instance.status"
  : >"$UBERDEV_CHILD_HANDOFF"
  export UBERDEV_CHILD_HANDOFF UBERDEV_CHILD_RESULT UBERDEV_CHILD_STATUS
}
uberdev_dispatch_child() {
  printf 'dispatch %s %s %s %s\n' "$@" >>"$LOG"
  [ "$1" != "${FAIL_EDGE:-}" ] || return 9
  printf 'receipt-%s' "$1"
}
uberdev_wait_child() { printf 'wait %s %s %s\n' "$@" >>"$LOG"; return 0; }

review_child_start one.edge one-iter01-attempt01 '{"role":"code-reviewer"}' '[]' "$RUN/one.tsv"
review_child_start two.edge two-iter01-attempt01 '{"role":"code-reviewer"}' '[]' "$RUN/two.tsv"
[ "$(cut -f3 "$RUN/one.tsv")" != "$(cut -f3 "$RUN/two.tsv")" ]

cat >"$RUN/records" <<EOF
ok.edge|ok-iter01-attempt01|{"role":"code-reviewer"}|[]
bad.edge|bad-iter01-attempt01|{"role":"code-reviewer"}|[]
EOF
FAIL_EDGE=bad.edge
export FAIL_EDGE
if review_child_fanout "$RUN/records" "$RUN/descriptors" 7; then exit 20; fi
grep -q "wait $RUN/ok-iter01-attempt01.status $RUN/ok-iter01-attempt01.result 0" "$LOG"
SH
bash "$TMP/run.sh" "$TMP/builder.sh" "$TMP/log" "$TMP/run"

grep -q 'phase=phase1' "$REVIEW"
grep -q 'commit_type_prefix=fix:' "$REVIEW"
grep -q 'phase=phase2' "$REVIEW"
grep -q 'commit_type_prefix=refactor:' "$REVIEW"

for file in \
  plugins/uberdev/commands/review-pr.md \
  plugins/uberdev/commands/simplify.md \
  plugins/uberdev/skills/post-impl-review/SKILL.md; do
  grep -q 'uberdev_create_child_handoff' "$ROOT/$file"
done

echo 'review-child-handoff: PASS'

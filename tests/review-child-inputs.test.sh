#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POST="$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
REVIEW="$ROOT/plugins/uberdev/commands/review-pr.md"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"

python3 -I -B - "$POST" "$REVIEW" <<'PY'
import re
import sys
from pathlib import Path

post = Path(sys.argv[1]).read_text(encoding="utf-8")
review = Path(sys.argv[2]).read_text(encoding="utf-8")

post_edges = (
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
)
review_edges = (
    "review_pr.fix.phase1",
    "review_pr.simplify.reuse",
    "review_pr.simplify.quality",
    "review_pr.simplify.efficiency",
    "review_pr.fix.phase2",
    "review_pr.defer.findings",
    "review_pr.ci.classify",
    "review_pr.ci.fix_code",
    "review_pr.ci.rebase",
    "review_pr.ci.defer_refusal",
    "review_pr.ci.resolve_conflict",
)

for edge in post_edges:
    if edge not in post:
        raise SystemExit(f"RED: missing post-review edge roster member: {edge}")
if 'uberdev_child_inputs_build "$EDGE_ID"' not in post:
    raise SystemExit("RED: post-review roster does not use the production input builder")
if 'inputs="$(uberdev_child_inputs_validate "$edge" "$inputs")" || return 2' not in post:
    raise SystemExit("RED: post-review record boundary does not revalidate inputs")
if 'uberdev_child_inputs_format_retry "$FAILED_REVIEW_EDGE" "$FAILED_REVIEW_INPUTS" "$FORMAT_EXAMPLE_PATH"' not in post:
    raise SystemExit("RED: post-review format retry does not use the production helper")

for edge in review_edges:
    fixed = rf"uberdev_child_inputs_build\s+{re.escape(edge)}(?:\s|\\)"
    dynamic_simplify = edge.startswith("review_pr.simplify.") and 'uberdev_child_inputs_build "$EDGE_ID"' in review
    dynamic_conflict = edge == "review_pr.ci.resolve_conflict" and 'uberdev_child_inputs_build review_pr.ci.resolve_conflict' in review
    if not re.search(fixed, review) and not dynamic_simplify and not dynamic_conflict:
        raise SystemExit(f"RED: review edge does not use production input builder: {edge}")
if 'inputs="$(uberdev_child_inputs_validate "$edge" "$inputs")" || return 2' not in review:
    raise SystemExit("RED: review record boundary does not revalidate inputs")

for source, label in ((post, "post-review"), (review, "review-pr")):
    if re.search(r'INPUTS(?:_JSON)?="\$\(jq -cn ', source):
        raise SystemExit(f"RED: {label} still constructs routed inputs inline with jq")
PY

. "$LIB"
json_string() {
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "$1"
}

HOSTILE=$'/tmp/review dir\nwith "quotes" and \\slashes/*?[x]'
PATH_JSON="$(json_string "$HOSTILE")"
STRING_JSON="$(json_string $'focus "quoted"\n\\glob*')"
PATHS_JSON="$(python3 -I -B -c 'import json,sys; print(json.dumps([sys.argv[1]],separators=(",",":")),end="")' "$HOSTILE")"
STRINGS_JSON="$(python3 -I -B -c 'import json,sys; print(json.dumps([sys.argv[1]],separators=(",",":")),end="")' $'tests\n"errors"')"

for edge in correctness silent_failures types comments tests; do
  base="$(uberdev_child_inputs_build "review_pr.review.$edge" changed_paths "$PATHS_JSON" diff_path "$PATH_JSON" criteria_path "$PATH_JSON" emphasis "$STRINGS_JSON")"
  uberdev_child_inputs_format_retry "review_pr.review.$edge" "$base" "$HOSTILE" >/dev/null
done
base="$(uberdev_child_inputs_build review_pr.review.general changed_paths "$PATHS_JSON" diff_path "$PATH_JSON" criteria_path "$PATH_JSON" emphasis "$STRINGS_JSON" lens '"general"')"
uberdev_child_inputs_format_retry review_pr.review.general "$base" "$HOSTILE" >/dev/null

for edge in review_pr.fix.phase1 review_pr.fix.phase2; do
  uberdev_child_inputs_build "$edge" findings_path "$PATH_JSON" commit_range_path "$PATH_JSON" working_dir "$PATH_JSON" pr_number 73 disposition_path "$PATH_JSON" >/dev/null
done
for lens in reuse quality efficiency; do
  uberdev_child_inputs_build "review_pr.simplify.$lens" diff_path "$PATH_JSON" lens "$(json_string "$lens")" focus "$STRING_JSON" >/dev/null
done
uberdev_child_inputs_build review_pr.defer.findings phase1_path "$PATH_JSON" phase2_path "$PATH_JSON" phase1_disposition_path "$PATH_JSON" phase2_disposition_path "$PATH_JSON" working_dir "$PATH_JSON" pr_number 73 >/dev/null
uberdev_child_inputs_build review_pr.ci.classify pr_number 73 run_id "$STRING_JSON" log_path "$PATH_JSON" >/dev/null
uberdev_child_inputs_build review_pr.ci.fix_code classification_path "$PATH_JSON" log_path "$PATH_JSON" working_dir "$PATH_JSON" pr_number 73 >/dev/null
uberdev_child_inputs_build review_pr.ci.rebase working_dir "$PATH_JSON" pr_number 73 head_sha "$STRING_JSON" base_sha "$STRING_JSON" >/dev/null
uberdev_child_inputs_build review_pr.ci.defer_refusal phase1_path "$PATH_JSON" working_dir "$PATH_JSON" pr_number 73 >/dev/null
uberdev_child_inputs_build review_pr.ci.resolve_conflict file_path "$PATH_JSON" working_dir "$PATH_JSON" pr_branch "$STRING_JSON" integration_branch "$STRING_JSON" base_sha "$STRING_JSON" >/dev/null

printf 'review-child-inputs: PASS (17 governed edges, retry, hostile-safe JSON)\n'

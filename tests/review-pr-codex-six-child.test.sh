#!/usr/bin/env bash
# Issue #335 end-to-end regression: a generated Codex review entrypoint creates
# one immutable Codex carrier and supervises the six Phase 1 reviewer children
# without touching Claude, colliding worktrees, or leaking capacity leases.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$SKILL" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
result=''
argv="$*"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ] && [ "$#" -ge 2 ]; then result="$2"; shift 2; continue; fi
  shift
done
test -n "$result"
printf '%s\t%s\t%s\n' "${UBERDEV_AGENT_INSTANCE_ID:-missing}" "$PWD" "$argv" >>"$CODEX_STUB_LOG"
sleep 0.4
printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' '```' >"$result"
if [ -n "${CODEX_STUB_FAIL_INSTANCE:-}" ] \
  && [ "${UBERDEV_AGENT_INSTANCE_ID:-}" = "$CODEX_STUB_FAIL_INSTANCE" ]; then
  exit 42
fi
exit 0
SH
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_STUB_LOG"
exit 97
SH
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"

cat >"$TMP/run-case.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case_name="$1"
repo="$2"
setup="$3"
fail_instance="${4-}"
cd "$repo"
. "$setup"

# These are immutable command-owned artifacts consumed by all six reviewer
# handoffs. changed_paths deliberately remains repository-relative, including
# at the provider boundary.
printf 'diff fixture\n' >"$DIFF_ARTIFACT_PATH"
printf 'review criteria\n' >"$CRITERIA_PATH"

edges=(correctness silent_failures types comments tests general)
handoffs=()
results=()
statuses=()
instances=()
for lens in "${edges[@]}"; do
  edge="review_pr.review.$lens"
  instance="review-pr-e2e-${case_name}-${lens}-iter1-attempt01"
  instances+=("$instance")
  if [ "$lens" = general ]; then
    inputs="$(uberdev_child_inputs_build "$edge" \
      changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" \
      emphasis '[]' lens '"general"')"
  else
    inputs="$(uberdev_child_inputs_build "$edge" \
      changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" \
      emphasis '[]')"
  fi
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" '[]' >/dev/null
  handoffs+=("$UBERDEV_CHILD_HANDOFF")
  results+=("$UBERDEV_CHILD_RESULT")
  statuses+=("$UBERDEV_CHILD_STATUS")
done

uberdev_preflight_child_batch "${handoffs[@]}"
for i in "${!edges[@]}"; do
  uberdev_dispatch_child "review_pr.review.${edges[$i]}" \
    "${handoffs[$i]}" "${results[$i]}" "${statuses[$i]}" >/dev/null
done

for i in "${!edges[@]}"; do
  if [ -n "$fail_instance" ] && [ "${instances[$i]}" = "$fail_instance" ]; then
    if uberdev_wait_child "${statuses[$i]}" "${results[$i]}" 20; then
      echo "expected failed child to return non-zero: $fail_instance" >&2
      exit 1
    fi
  else
    uberdev_wait_child "${statuses[$i]}" "${results[$i]}" 20
  fi
done

python3 -I -B - "$UBERDEV_CARRIER_RUN_DIR" "$repo" "$CODEX_STUB_LOG" \
  "$CLAUDE_STUB_LOG" "$fail_instance" "${instances[@]}" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

run_dir = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
codex_log = pathlib.Path(sys.argv[3])
claude_log = pathlib.Path(sys.argv[4])
failed = sys.argv[5]
instances = sys.argv[6:]
assert len(instances) == len(set(instances)) == 6, instances

lines = codex_log.read_text().splitlines()
assert len(lines) == 6, lines
launches = [line.split("\t", 2) for line in lines]
assert {row[0] for row in launches} == set(instances), launches
assert len({row[1] for row in launches}) == 6, launches
assert all("--ask-for-approval never" in row[2] for row in launches), launches
assert all("permission-mode" not in row[2] and "dangerously-skip-permissions" not in row[2] for row in launches)
assert not claude_log.exists() or not claude_log.read_text(), claude_log.read_text()

statuses = []
worktrees = set()
branches = set()
for instance in instances:
    child = run_dir / "children" / instance
    handoff = json.loads((run_dir / "handoffs" / f"{instance}.json").read_text())
    assert handoff["instance_id"] == instance
    assert handoff["inputs"]["changed_paths"] == ["README.md"]
    status = json.loads((child / "status.json").read_text())
    statuses.append(status["state"])
    assert status["backend"] == "codex", status
    worktrees.add(status["worktree"])
    branches.add(status["branch"])
    worktree = pathlib.Path(status["worktree"])
    if not worktree.is_absolute():
        worktree = repo / worktree
    assert not worktree.exists(), worktree
    branch = status["branch"]
    probe = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        check=False,
    )
    assert probe.returncode != 0, branch

assert len(worktrees) == len(branches) == 6, (worktrees, branches)
if failed:
    assert statuses.count("failed") == 1 and statuses.count("completed") == 5, statuses
else:
    assert statuses == ["completed"] * 6, statuses

state = run_dir / f".agent-state-{os.geteuid()}"
leases = list((state / "semaphore-v1").rglob("*.lease"))
assert not leases, leases
events = [json.loads(line) for line in (state / "agent-lifecycle.jsonl").read_text().splitlines() if line]
terminals = [row for row in events if row.get("event") in {"completed", "failed", "timed_out", "cancelled", "abandoned"}]
assert len(terminals) == 6, terminals
assert {row["run_id"] for row in terminals} == set(instances), terminals
PY
SH
chmod +x "$TMP/run-case.sh"

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'fixture\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
}

run_case() {
  local name="$1" fail_instance="${2-}" repo runtime codex_log claude_log
  repo="$TMP/repo-$name"; runtime="$TMP/runtime-$name"
  codex_log="$TMP/codex-$name.log"; claude_log="$TMP/claude-$name.log"
  make_repo "$repo"
  mkdir -p "$runtime"
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$repo" \
    UBERDEV_TMPDIR="$runtime" CODEX_STUB_LOG="$codex_log" CLAUDE_STUB_LOG="$claude_log" \
    CODEX_STUB_FAIL_INSTANCE="$fail_instance" RUN_ID="20260716-00000${name}-abcdef0" \
    PR_NUMBER=335 ARGUMENTS='' SOLVE_TIMEOUT=20 UBERDEV_AGENT_CAPACITY=6 \
    bash "$TMP/run-case.sh" "$name" "$repo" "$TMP/setup.sh" "$fail_instance"
}

run_case 1
run_case 2 review-pr-e2e-2-types-iter1-attempt01

echo "review-pr Codex six-child integration tests passed"

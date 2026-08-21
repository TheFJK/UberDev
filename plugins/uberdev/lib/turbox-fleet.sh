#!/usr/bin/env bash
# lib/turbox-fleet.sh — controller-side helpers for the /turbox standard-mode
# solver fleet (RFC 0020).
#
# INVOCATION CONTRACT — this file is an EXECUTABLE, never a sourced library:
#
#   bash "$CLAUDE_PLUGIN_ROOT/lib/turbox-fleet.sh" <subcommand> [options]
#
# Sourcing it from a skill's bash fence would run the body under the Bash
# tool's /bin/zsh, where this project has repeatedly been bitten: `for x in
# $SCALAR` iterates once over the whole string, `local status=` collides with
# zsh's tied parameter, `type -t` does not exist, and `BASH_REMATCH` is unset.
# Running it through the shebang makes the interpreter a property of the file
# instead of a property of the caller. Every subcommand therefore takes its
# whole input on argv or from a file, and returns its whole output on stdout.
#
# Shell floor: macOS /bin/bash 3.2 — no `declare -A`, no `wait -n`, no
# `${var^^}`. Anything needing a map goes through python3.
#
# Exit codes are part of the contract and tests assert on them:
#   0  success
#   2  caller error (bad arguments, missing input, unreadable file)
#   3  a guard REFUSED (wave overlap, loop cap exhausted, projection over cap)
#  64  unknown subcommand

set -u

TURBOX_SELF="${0##*/}"

_tbx_die() { echo "uberdev turbox: $1" >&2; exit "${2:-2}"; }

# --- Loop caps (RFC 0020 §3.7 TB4) -----------------------------------------
# A DERIVED COPY. The canonical owner is `sdd_loop_cap` in
# skills/subagent-driven-dev/SKILL.md — RFC 0020 TB4 records that this lane
# "inherited names and defaults from subagent-driven-dev", and workflow.js
# says the same of its own copy. These constants restate the owner's values so
# this executable never has to source a markdown fence; they are NOT the
# source. Agreement is asserted numerically by tests/sdd-wave-contract.test.sh
# §C, which executes `loop-cap <name>` here and the owner's helper there and
# compares the integers. A comment is not a producer (RFC 0016:60) — the
# promise now lives in that test, not in this block.
TURBOX_FIX_ROUNDS=3
TURBOX_RETEST_ROUNDS=2
TURBOX_CONTEXT_ROUNDS=2

# The parallel-issue ceiling (RFC 0020 §3.3). A HARD ceiling: config may lower
# it, never raise it. Kept beside the caps so a reader finds every ceiling in
# one place.
TURBOX_ISSUE_CAP=3

_tbx_loop_cap() {
  case "$1" in
    fix_rounds)     echo "$TURBOX_FIX_ROUNDS" ;;
    retest_rounds)  echo "$TURBOX_RETEST_ROUNDS" ;;
    context_rounds) echo "$TURBOX_CONTEXT_ROUNDS" ;;
    issue_cap)      echo "$TURBOX_ISSUE_CAP" ;;
    *) _tbx_die "loop-cap: unknown loop '$1' (expected fix_rounds|retest_rounds|context_rounds|issue_cap)" 2 ;;
  esac
}

_tbx_require_int() {
  case "${2:-}" in
    ''|*[!0-9]*) _tbx_die "$1: '${2:-}' is not a non-negative integer" 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# loop-cap <name>
#   Print the numeric cap for <name>, as DERIVED from the owner helper in
#   skills/subagent-driven-dev/SKILL.md. The never-restate-in-prose rule
#   stands, now with teeth: never restate a cap without adding a register
#   entry to tests/sdd-wave-contract.test.sh §C. Its completeness sweep reds
#   on any unregistered restatement, on the commit that adds it.
# ---------------------------------------------------------------------------
_tbx_cmd_loop_cap() {
  [ "$#" -eq 1 ] || _tbx_die "usage: $TURBOX_SELF loop-cap <fix_rounds|retest_rounds|context_rounds|issue_cap>" 2
  _tbx_loop_cap "$1"
}

# ---------------------------------------------------------------------------
# round-permitted --loop <name> --round <n>
#   rc 0 proceed · rc 3 cap exhausted (route BLOCKED) · rc 2 called wrong.
#   The guard every fix-shaped loop calls BEFORE dispatching the next round,
#   so "capped at 3" is an executed predicate rather than a remembered one.
# ---------------------------------------------------------------------------
_tbx_cmd_round_permitted() {
  local loop="" round="" cap
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --loop)  loop="${2:-}"; shift 2 || _tbx_die "round-permitted: --loop needs a value" 2 ;;
      --round) round="${2:-}"; shift 2 || _tbx_die "round-permitted: --round needs a value" 2 ;;
      *) _tbx_die "round-permitted: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$loop" ] || _tbx_die "round-permitted: --loop is required" 2
  _tbx_require_int "round-permitted --round" "$round"
  [ "$round" -ge 1 ] || _tbx_die "round-permitted: --round must be >= 1 (rounds are 1-based)" 2
  cap="$(_tbx_loop_cap "$loop")" || exit 2
  if [ "$round" -gt "$cap" ]; then
    echo "uberdev turbox: ${loop}_exhausted round=$round cap=$cap" >&2
    exit 3
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# issue-concurrency [--configured <n>]
#   Resolve the parallel-issue wave size. Default TURBOX_ISSUE_CAP; a
#   configured value is clamped UP to 1 and DOWN to the cap, and a clamp is
#   announced on stderr. Prints the resolved integer.
# ---------------------------------------------------------------------------
_tbx_cmd_issue_concurrency() {
  local configured=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --configured) configured="${2:-}"; shift 2 || _tbx_die "issue-concurrency: --configured needs a value" 2 ;;
      *) _tbx_die "issue-concurrency: unknown option '$1'" 2 ;;
    esac
  done
  if [ -z "$configured" ]; then echo "$TURBOX_ISSUE_CAP"; exit 0; fi
  _tbx_require_int "issue-concurrency --configured" "$configured"
  if [ "$configured" -lt 1 ]; then
    echo "warning: fanout_concurrency.turbox = $configured is below 1; using 1" >&2
    echo 1; exit 0
  fi
  if [ "$configured" -gt "$TURBOX_ISSUE_CAP" ]; then
    echo "warning: fanout_concurrency.turbox = $configured exceeds the /turbox parallel-issue cap of $TURBOX_ISSUE_CAP (RFC 0020 §3.3); clamping to $TURBOX_ISSUE_CAP" >&2
    echo "$TURBOX_ISSUE_CAP"; exit 0
  fi
  echo "$configured"
}

# ---------------------------------------------------------------------------
# project-agents --small <n> --design <n> [--implement-budget <n>] [--max <n>]
#   TB1. Prints the projection; rc 3 when it exceeds --max, so the run aborts
#   BEFORE any dispatch rather than discovering the ceiling mid-wave.
#
#   projected = small + (3 + implementBudget) x design
#     3 = risk-gated security lens + design-planner + plan-reviewer
#   Pessimistic on the one conditional rung (the risk-gated security lens):
#   it is not knowable at projection time, and a projection that guesses low
#   is a ceiling that does not hold.
# ---------------------------------------------------------------------------
TURBOX_DESIGN_RUNGS=3

_tbx_cmd_project_agents() {
  local small="" design="" budget=24 max=600 projected
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --small)            small="${2:-}";  shift 2 || _tbx_die "project-agents: --small needs a value" 2 ;;
      --design)           design="${2:-}"; shift 2 || _tbx_die "project-agents: --design needs a value" 2 ;;
      --implement-budget) budget="${2:-}"; shift 2 || _tbx_die "project-agents: --implement-budget needs a value" 2 ;;
      --max)              max="${2:-}";    shift 2 || _tbx_die "project-agents: --max needs a value" 2 ;;
      *) _tbx_die "project-agents: unknown option '$1'" 2 ;;
    esac
  done
  _tbx_require_int "project-agents --small" "$small"
  _tbx_require_int "project-agents --design" "$design"
  _tbx_require_int "project-agents --implement-budget" "$budget"
  _tbx_require_int "project-agents --max" "$max"
  projected=$(( small + ( TURBOX_DESIGN_RUNGS + budget ) * design ))
  echo "$projected"
  if [ "$projected" -gt "$max" ]; then
    echo "uberdev turbox: TB1 projected_agents=$projected exceeds max_agents=$max — aborting before dispatch" >&2
    exit 3
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# budget-spend --run-dir <d> --issue <n> --count <k> [--limit <n>]
#   TB2. A LIVE counter, not a projection: appends k to this issue's
#   implementation-phase tally and prints the new total. rc 3 once the tally
#   reaches the limit — the caller then records the remaining tasks SKIPPED,
#   audits implement_budget_exhausted, and STILL runs delivery on what is
#   already committed. Reviewed commits must never strand in a worktree.
#
#   The tally lives on disk because the controller is a session: a compact or a
#   context boundary must not reset a ceiling.
# ---------------------------------------------------------------------------
_tbx_cmd_budget_spend() {
  local run_dir="" issue="" count="" limit=24 file total
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || _tbx_die "budget-spend: --run-dir needs a value" 2 ;;
      --issue)   issue="${2:-}";   shift 2 || _tbx_die "budget-spend: --issue needs a value" 2 ;;
      --count)   count="${2:-}";   shift 2 || _tbx_die "budget-spend: --count needs a value" 2 ;;
      --limit)   limit="${2:-}";   shift 2 || _tbx_die "budget-spend: --limit needs a value" 2 ;;
      *) _tbx_die "budget-spend: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$run_dir" ] || _tbx_die "budget-spend: --run-dir is required" 2
  _tbx_require_int "budget-spend --issue" "$issue"
  _tbx_require_int "budget-spend --count" "$count"
  _tbx_require_int "budget-spend --limit" "$limit"
  [ -d "$run_dir" ] || _tbx_die "budget-spend: run dir '$run_dir' does not exist" 2
  mkdir -p "$run_dir/budget" || _tbx_die "budget-spend: cannot create $run_dir/budget" 2
  file="$run_dir/budget/issue-$issue.count"
  total=0
  if [ -r "$file" ]; then
    total="$(cat "$file" 2>/dev/null || echo 0)"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
  fi
  total=$(( total + count ))
  printf '%s\n' "$total" > "$file" || _tbx_die "budget-spend: cannot write $file" 2
  chmod 600 "$file" 2>/dev/null || true
  echo "$total"
  if [ "$total" -ge "$limit" ]; then
    echo "uberdev turbox: TB2 implement_budget_exhausted issue=$issue spent=$total limit=$limit" >&2
    exit 3
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# plan-tasks --plan <plan.md>
#   Parse a plan-writer plan into the ONLY thing the controller needs from it:
#   [{id, wave, owns[]}]. Reading the plan body into the controller's context
#   is what RFC 0020 §4.1 forbids; this reads it in a subprocess and returns
#   the task table.
#
#   Recognised shape (agents/plan-writer.md):
#     ### Task 3: Some component
#     **Wave:** wave-2 — tasks in the same wave dispatch in parallel
#     **Owns (file allowlist):** lib/a.sh, tests/a.test.sh
#
#   `Owns` has TWO emission forms and this is the single source for which ones
#   parse — agents/plan-writer.md enumerates the same two, and
#   tests/turbox-fleet-runtime.test.sh R6c runs the card's own blocks through
#   here so the two surfaces cannot drift apart again (#653). The second form
#   puts the allowlist on the lines that follow the label:
#     **Owns (file allowlist):**
#     - `lib/a.sh`
#     - `tests/a.test.sh`
#   A label with neither an inline value nor a following list declares nothing,
#   and the task is reported `unowned` exactly as if the label were absent.
# ---------------------------------------------------------------------------
_tbx_cmd_plan_tasks() {
  local plan=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) plan="${2:-}"; shift 2 || _tbx_die "plan-tasks: --plan needs a value" 2 ;;
      *) _tbx_die "plan-tasks: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$plan" ] || _tbx_die "plan-tasks: --plan is required" 2
  [ -r "$plan" ] || _tbx_die "plan-tasks: plan '$plan' is missing or unreadable" 2
  python3 -I -B - "$plan" <<'PY'
import json, re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()

TASK_RE = re.compile(r'^###\s+Task\s+(\d+)\s*:\s*(.*)$')
WAVE_RE = re.compile(r'^\*\*Wave:?\*\*\s*:?\s*\[?\s*wave[-\s]?(\d+)', re.I)
OWNS_RE = re.compile(r'^\*\*Owns[^*]*\*\*\s*:?\s*(.*)$', re.I)
BULLET_RE = re.compile(r'^[-*+]\s+(.*)$')
CHECKBOX_RE = re.compile(r'^\[[ xX]\]')

tasks, current = [], None


def flush():
    if current is not None:
        tasks.append(current)


def split_paths(raw):
    # The template shows the value in square brackets; a plan that keeps
    # them is describing the same list, not a different one.
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    parts = [p.strip().strip('`"\'') for p in re.split(r'[,\n]', raw)]
    return [p for p in parts if p and not p.startswith("#")]


def read_bullet_list(lines, j):
    """Read the allowlist a plan puts BELOW its `Owns` label, not beside it.

    Blank lines are allowed before the list opens; once it has opened, the
    first line that is not a bullet closes it. That boundary is what keeps the
    `**Files:**` block and the `- [ ] **Step N**` checkboxes that follow every
    task header out of the allowlist — reading a second form must not become
    harvesting every bullet on the page.
    """
    items = []
    while j < len(lines):
        stripped = lines[j].strip()
        if not stripped:
            if items:
                break
            j += 1
            continue
        bullet = BULLET_RE.match(stripped)
        if not bullet:
            break
        body = bullet.group(1).strip()
        if CHECKBOX_RE.match(body):
            break
        items.extend(split_paths(body))
        j += 1
    return items, j


lines = text.splitlines()
i = 0
while i < len(lines):
    stripped = lines[i].strip()
    i += 1
    m = TASK_RE.match(stripped)
    if m:
        flush()
        current = {"id": int(m.group(1)), "title": m.group(2).strip(), "wave": 0, "owns": []}
        continue
    if current is None:
        continue
    m = WAVE_RE.match(stripped)
    if m:
        current["wave"] = int(m.group(1))
        continue
    m = OWNS_RE.match(stripped)
    if m:
        owns = split_paths(m.group(1).strip())
        if not owns:
            owns, i = read_bullet_list(lines, i)
        # A label that declared nothing never clears one that did.
        if owns:
            current["owns"] = owns
flush()

# A task with no wave is not defaulted to wave 1: a plan that never said which
# wave a task belongs to has not proven anything about what it may run beside.
unwaved = [t["id"] for t in tasks if t["wave"] < 1]
unowned = [t["id"] for t in tasks if not t["owns"]]
print(json.dumps({
    "tasks": sorted(tasks, key=lambda t: (t["wave"], t["id"])),
    "task_count": len(tasks),
    "waves": sorted({t["wave"] for t in tasks if t["wave"] >= 1}),
    "unwaved": unwaved,
    "unowned": unowned,
}, sort_keys=True, separators=(",", ":")))
PY
}

# ---------------------------------------------------------------------------
# wave-disjoint --tasks <json> [--root <dir>]
#   TB3 — the chokepoint (RFC 0020 §3.6).
#
#   --tasks is a JSON array of {id, owns[]} (the `tasks` array from plan-tasks,
#   filtered to ONE wave) or the object plan-tasks prints plus --wave.
#
#   rc 0 disjoint · rc 2 ownership missing/unreadable · rc 3 OVERLAP.
#
#   Overlap means equality OR directory containment: a task owning `lib/` and a
#   sibling owning `lib/x.sh` race exactly as if they shared a path, and a
#   plain set intersection calls them disjoint. The containment predicate is
#   deliberately the same one sdd_assert_wave_disjoint uses — two
#   implementations of "do these paths collide" is one too many, and until it
#   is one, tests/sdd-wave-contract.test.sh §W feeds ONE corpus to BOTH and
#   requires byte-equal verdicts. Six lane divergences are declared and locked
#   there; the promise is executed in that file, not made here.
# ---------------------------------------------------------------------------
_tbx_cmd_wave_disjoint() {
  local tasks="" wave="" root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tasks)      tasks="${2:-}"; shift 2 || _tbx_die "wave-disjoint: --tasks needs a value" 2 ;;
      --tasks-file) tasks="$(cat "${2:-}" 2>/dev/null)" || _tbx_die "wave-disjoint: cannot read ${2:-}" 2; shift 2 ;;
      --wave)       wave="${2:-}"; shift 2 || _tbx_die "wave-disjoint: --wave needs a value" 2 ;;
      --root)       root="${2:-}"; shift 2 || _tbx_die "wave-disjoint: --root needs a value" 2 ;;
      *) _tbx_die "wave-disjoint: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$tasks" ] || _tbx_die "wave-disjoint: --tasks or --tasks-file is required" 2
  [ -z "$wave" ] || _tbx_require_int "wave-disjoint --wave" "$wave"
  python3 -I -B - "$tasks" "${wave:-}" "${root:-}" <<'PY'
import json, os, sys

raw, wave, root = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    value = json.loads(raw)
except ValueError:
    print("uberdev turbox: wave_tasks_unreadable", file=sys.stderr)
    raise SystemExit(2)

tasks = value.get("tasks") if isinstance(value, dict) else value
if not isinstance(tasks, list):
    print("uberdev turbox: wave_tasks_not_a_list", file=sys.stderr)
    raise SystemExit(2)

if wave:
    tasks = [t for t in tasks if isinstance(t, dict) and t.get("wave") == int(wave)]

# One task cannot collide with itself, and zero tasks cannot collide at all.
if len(tasks) < 2:
    raise SystemExit(0)

owned = []
for task in tasks:
    if not isinstance(task, dict):
        print("uberdev turbox: wave_task_malformed", file=sys.stderr)
        raise SystemExit(2)
    tid = task.get("id", "?")
    paths = task.get("owns")
    if not isinstance(paths, list) or not paths or any(
        not isinstance(p, str) or not p.strip() for p in paths
    ):
        print("uberdev turbox: wave_paths_missing task=%s" % tid, file=sys.stderr)
        raise SystemExit(2)
    norm = []
    for p in paths:
        p = p.strip()
        # Normalise to a comparable form. With --root the paths are resolved
        # and confined; without it they are compared as declared, which is
        # still the right comparison for two lists written by one plan.
        if root:
            resolved = os.path.realpath(os.path.join(root, p))
            if os.path.commonpath((os.path.realpath(root), resolved)) != os.path.realpath(root):
                print("uberdev turbox: wave_path_escapes_root task=%s path=%s" % (tid, p), file=sys.stderr)
                raise SystemExit(2)
            norm.append(resolved)
        else:
            norm.append(os.path.normpath(p))
    if len(norm) != len(set(norm)):
        print("uberdev turbox: wave_paths_duplicated task=%s" % tid, file=sys.stderr)
        raise SystemExit(2)
    owned.append((tid, norm))


def under(a, b):
    """True when a IS b, or a lives inside directory b."""
    if a == b:
        return True
    stem = b.rstrip("/\\")
    return a.startswith(stem + "/") or a.startswith(stem + os.sep)


for i in range(len(owned)):
    for j in range(i + 1, len(owned)):
        for a in owned[i][1]:
            for b in owned[j][1]:
                if under(a, b) or under(b, a):
                    collision = a if under(a, b) else b
                    print(
                        "uberdev turbox: wave_paths_overlap task_a=%s task_b=%s path=%s"
                        % (owned[i][0], owned[j][0], collision),
                        file=sys.stderr,
                    )
                    raise SystemExit(3)
raise SystemExit(0)
PY
}

# ---------------------------------------------------------------------------
# stage-commit --worktree <d> --message <m> (--paths-file <f> | --path <p> ...)
#   Controller-only git (RFC 0020 §3.5). Stages EXACTLY the given paths and
#   commits them.
#
#   Refuses the stage-everything forms outright: `-A`, `--all`, and a bare `.`
#   pathspec. That refusal is the boundary, not a style preference — an
#   implementer that reported four paths must not be able to sweep a fifth into
#   the commit, and a dirty tree must not leak into a task commit.
# ---------------------------------------------------------------------------
_tbx_cmd_stage_commit() {
  local worktree="" message="" paths_file="" allow_empty=0
  local paths_count=0
  set -- "$@"
  local PATHS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)   worktree="${2:-}"; shift 2 || _tbx_die "stage-commit: --worktree needs a value" 2 ;;
      --message)    message="${2:-}";  shift 2 || _tbx_die "stage-commit: --message needs a value" 2 ;;
      --paths-file) paths_file="${2:-}"; shift 2 || _tbx_die "stage-commit: --paths-file needs a value" 2 ;;
      --path)       PATHS[${#PATHS[@]}]="${2:-}"; shift 2 || _tbx_die "stage-commit: --path needs a value" 2 ;;
      --allow-empty) allow_empty=1; shift ;;
      *) _tbx_die "stage-commit: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$worktree" ] || _tbx_die "stage-commit: --worktree is required" 2
  [ -n "$message" ]  || _tbx_die "stage-commit: --message is required" 2
  [ -d "$worktree" ] || _tbx_die "stage-commit: worktree '$worktree' does not exist" 2

  if [ -n "$paths_file" ]; then
    [ -r "$paths_file" ] || _tbx_die "stage-commit: --paths-file '$paths_file' is unreadable" 2
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      PATHS[${#PATHS[@]}]="$line"
    done < "$paths_file"
  fi

  paths_count=${#PATHS[@]}
  [ "$paths_count" -gt 0 ] || _tbx_die "stage-commit: no paths given — refusing to commit a file list nobody reported" 2

  # The refusal. Checked BEFORE the repository is touched.
  local p
  for p in "${PATHS[@]}"; do
    case "$p" in
      -A|--all|-a|.|./|:/|:|'*')
        echo "uberdev turbox: stage_everything_refused path='$p' — stage explicit paths only (RFC 0020 §3.5)" >&2
        exit 3
        ;;
      -*)
        echo "uberdev turbox: stage_option_refused path='$p' — a path that parses as a git option is not a path" >&2
        exit 3
        ;;
    esac
    case "$p" in
      /*) echo "uberdev turbox: stage_absolute_path_refused path='$p' — report paths relative to the worktree" >&2; exit 3 ;;
      ../*|*/../*) echo "uberdev turbox: stage_path_escapes_worktree path='$p'" >&2; exit 3 ;;
    esac
  done

  git -C "$worktree" add -- "${PATHS[@]}" || _tbx_die "stage-commit: git add failed" 2
  if [ "$allow_empty" -eq 0 ] && git -C "$worktree" diff --cached --quiet; then
    echo "uberdev turbox: nothing_staged — the reported paths hold no change" >&2
    exit 3
  fi
  git -C "$worktree" commit -m "$message" || _tbx_die "stage-commit: git commit failed" 2
  git -C "$worktree" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# worktree-add --root <d> --issue <n> --branch <b> [--base <ref>]
#   Cut the per-issue worktree at a path the CONTROLLER chose, and print it.
#
#   Why not isolation:"worktree" on the Agent call: that hands out an anonymous
#   checkout the caller never learns the path of, and a second agent gets a
#   different one. A chain of agents — implementer, reviewer, fixer, delivery —
#   must address ONE shared checkout by path, which anonymous isolation
#   structurally cannot provide.
# ---------------------------------------------------------------------------
_tbx_cmd_worktree_add() {
  local root="" issue="" branch="" base="" wt_dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)   root="${2:-}";   shift 2 || _tbx_die "worktree-add: --root needs a value" 2 ;;
      --issue)  issue="${2:-}";  shift 2 || _tbx_die "worktree-add: --issue needs a value" 2 ;;
      --branch) branch="${2:-}"; shift 2 || _tbx_die "worktree-add: --branch needs a value" 2 ;;
      --base)   base="${2:-}";   shift 2 || _tbx_die "worktree-add: --base needs a value" 2 ;;
      *) _tbx_die "worktree-add: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$root" ]   || _tbx_die "worktree-add: --root is required" 2
  [ -n "$branch" ] || _tbx_die "worktree-add: --branch is required" 2
  _tbx_require_int "worktree-add --issue" "$issue"
  wt_dir="$root/issue-$issue"
  if [ -d "$wt_dir" ]; then
    # Re-entry (a resumed run) is not a failure: report the existing checkout
    # rather than cutting a second one beside it.
    echo "$wt_dir"; exit 0
  fi
  mkdir -p "$root" || _tbx_die "worktree-add: cannot create $root" 2
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$wt_dir" "$branch" >&2 || _tbx_die "worktree-add: git worktree add failed for existing branch $branch" 2
  elif [ -n "$base" ]; then
    git worktree add "$wt_dir" -b "$branch" "$base" >&2 || _tbx_die "worktree-add: git worktree add failed off $base" 2
  else
    git worktree add "$wt_dir" -b "$branch" >&2 || _tbx_die "worktree-add: git worktree add failed" 2
  fi
  echo "$wt_dir"
}

# ---------------------------------------------------------------------------
# audit --run-dir <d> --event <name> [--data <json>]
#   One JSONL line per event into <run-dir>/turbox-audit.jsonl. Degradation is
#   recorded, never silent: a skipped task, an exhausted cap and a refused wave
#   each leave a line behind, because the controller's own memory of the run is
#   a context that can be compacted away.
# ---------------------------------------------------------------------------
_tbx_cmd_audit() {
  local run_dir="" event="" data="{}" file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || _tbx_die "audit: --run-dir needs a value" 2 ;;
      --event)   event="${2:-}";   shift 2 || _tbx_die "audit: --event needs a value" 2 ;;
      --data)    data="${2:-}";    shift 2 || _tbx_die "audit: --data needs a value" 2 ;;
      *) _tbx_die "audit: unknown option '$1'" 2 ;;
    esac
  done
  [ -n "$run_dir" ] || _tbx_die "audit: --run-dir is required" 2
  [ -n "$event" ]   || _tbx_die "audit: --event is required" 2
  [ -d "$run_dir" ] || mkdir -p "$run_dir" || _tbx_die "audit: cannot create $run_dir" 2
  file="$run_dir/turbox-audit.jsonl"
  python3 -I -B - "$file" "$event" "$data" <<'PY'
import json, sys
path, event, data = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    payload = json.loads(data) if data else {}
except ValueError:
    payload = {"raw": data}
if not isinstance(payload, dict):
    payload = {"value": payload}
payload["event"] = event
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
  chmod 600 "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
[ "$#" -ge 1 ] || _tbx_die "usage: $TURBOX_SELF <loop-cap|round-permitted|issue-concurrency|project-agents|budget-spend|plan-tasks|wave-disjoint|stage-commit|worktree-add|audit> [options]" 64

TURBOX_SUBCOMMAND="$1"; shift
case "$TURBOX_SUBCOMMAND" in
  loop-cap)          _tbx_cmd_loop_cap "$@" ;;
  round-permitted)   _tbx_cmd_round_permitted "$@" ;;
  issue-concurrency) _tbx_cmd_issue_concurrency "$@" ;;
  project-agents)    _tbx_cmd_project_agents "$@" ;;
  budget-spend)      _tbx_cmd_budget_spend "$@" ;;
  plan-tasks)        _tbx_cmd_plan_tasks "$@" ;;
  wave-disjoint)     _tbx_cmd_wave_disjoint "$@" ;;
  stage-commit)      _tbx_cmd_stage_commit "$@" ;;
  worktree-add)      _tbx_cmd_worktree_add "$@" ;;
  audit)             _tbx_cmd_audit "$@" ;;
  *) _tbx_die "unknown subcommand '$TURBOX_SUBCOMMAND'" 64 ;;
esac

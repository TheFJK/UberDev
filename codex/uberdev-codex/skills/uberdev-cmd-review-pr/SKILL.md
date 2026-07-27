---
name: uberdev-cmd-review-pr
description: "Use when the user wants to comprehensive PR review using specialized agents. Invokable explicitly as $uberdev-cmd-review-pr. Original description: Comprehensive PR review using specialized agents"
---

# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/review-pr`). On Codex:

- **`$ARGUMENTS`** below = the user's free-text request (the words after the
  command name, or your whole task description if invoked implicitly).
- **`Task` tool** calls → use `spawn_agent`; collect results with `wait_agent`
  (see ~/.agents/skills/using-uberdev/references/codex-tools.md for the
  named-agent mapping).
- **`Skill` tool** invocations → skills load natively; just follow the named
  skill's instructions.
- **`Workflow` tool** (testers/uberscan/ubersimplify) → no Codex equivalent;
  follow the skill's `## No-Workflow fallback` section instead.
- **`MultiEdit`** → apply edits with your native file-edit tool.

Original argument hint: `[review-aspects] [--no-simplify] [--no-ci-fix] [--no-defer-issues] [--turbo]`

---



# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality.

**Review Aspects (optional):** "$ARGUMENTS"

`/uberdev:review-pr` is a true **two-phase** command. Both phases run by default — flow: **post-impl-review fanout (6 agents via `uberdev:post-impl-review` skill) → fix loop → simplify fanout (3 lenses) → final aggregation**.

## Routed child builder

<!-- BEGIN child-callsite-contracts-v1 -->
```json
{
  "review_pr.fix.phase1":{"inputs":["findings_path","commit_range_path","working_dir","pr_number","disposition_path"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.simplify.reuse":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.simplify.quality":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.simplify.efficiency":{"inputs":["diff_path","lens"],"optional_inputs":["focus"],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.fix.phase2":{"inputs":["findings_path","commit_range_path","working_dir","pr_number","disposition_path"],"optional_inputs":[],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.defer.findings":{"inputs":["phase1_path","phase2_path","phase1_disposition_path","phase2_disposition_path","working_dir","pr_number"],"optional_inputs":[],"allowed_workflows":["review-pr","simplify","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.classify":{"inputs":["pr_number","run_id","log_path"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"subtask","risk_argument":"subtask"},
  "review_pr.ci.fix_code":{"inputs":["classification_path","log_path","working_dir","pr_number"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.rebase":{"inputs":["working_dir","pr_number","head_sha","base_sha"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.defer_refusal":{"inputs":["phase1_path","working_dir","pr_number"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null},
  "review_pr.ci.resolve_conflict":{"inputs":["file_path","working_dir","pr_branch","integration_branch","base_sha"],"optional_inputs":[],"allowed_workflows":["review-pr","solve","turbo"],"risk_scope":"run","risk_argument":null}
}
```
<!-- END child-callsite-contracts-v1 -->

All provider calls in this command use the runtime-owned carrier and handoff builder; native agent-dispatch shortcuts are forbidden. A chained solve run inherits `UBERDEV_RUN_CARRIER_JSON`; when it is absent, a standalone run calls `uberdev_prepare_run_carrier review-pr "$PR_NUMBER" medium "$RISK_JSON"`, which validates repository/PR identity and exports the prepared request plus the same carrier without pretending to be `/solve`.

### Executable setup (run before any builder or child edge)

```bash uberdev-executable setup=review-pr
set -u
# This entrypoint is executing inside Codex. Preserve that provider provenance
# through standalone carrier preparation unless the operator already selected one.
UBERDEV_DISPATCH_BACKEND_REQUESTED="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-codex}"
export UBERDEV_DISPATCH_BACKEND_REQUESTED
UBERDEV_REVIEW_PLUGIN_ROOT="${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}"
. "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/child-dispatch.sh"
PR_NUMBER="${PR_NUMBER:-$(gh pr view --json number -q .number)}"
RISK_JSON="${UBERDEV_AGENT_RISK_SIGNALS_JSON:-[]}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)}"
uberdev_command_workspace_prepare review-pr "$PR_NUMBER" medium "$RISK_JSON" "$RUN_ID" "${WORKTREE_ROOT:-}" >/dev/null || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
uberdev_dispatch_preflight_backend "$UBERDEV_CARRIER_BACKEND" review-pr || {
  rc=$?; return "$rc" 2>/dev/null || exit "$rc"
}
REVIEW_ITERATION="${REVIEW_ITERATION:-1}"
REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT:-600}"
CI_FIX_LOOP_ITER="${CI_FIX_LOOP_ITER:-1}"
CI_RUN_ID="${CI_RUN_ID:-0}"
FOCUS="${FOCUS:-${ARGUMENTS:-}}"
review_json_string() {
  python3 -I -B -c 'import json,sys; print(json.dumps(sys.argv[1],separators=(",",":")),end="")' "$1"
}
```

<!-- BEGIN review-child-builder-v1 -->
```bash
review_child_record() {
  local edge="$1" instance="$2" inputs="$3" risks="$4" path="$5"
  if command -v uberdev_child_inputs_validate >/dev/null 2>&1; then
    inputs="$(uberdev_child_inputs_validate "$edge" "$inputs")" || return 2
  fi
  python3 -I -B - "$edge" "$instance" "$inputs" "$risks" "$path" <<'PY'
import json,sys
edge,instance,inputs,risks,path=sys.argv[1:]
with open(path,'a') as f: f.write(json.dumps({'edge':edge,'instance':instance,'inputs':json.loads(inputs),'risks':json.loads(risks)},sort_keys=True,separators=(',',':'))+'\n')
PY
}
review_child_fanout() {
  local records="$1" descriptors="$2" launched="$3" timeout_s="$4" row edge instance inputs risks handoff result status receipt dispatch_rc ledger_rc cleanup_rc
  local handoffs=()
  : >"$descriptors"; : >"$launched"
  while IFS= read -r row; do
    edge="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["edge"])' "$row")"
    instance="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["instance"])' "$row")"
    inputs="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["inputs"],separators=(",",":")))' "$row")"
    risks="$(python3 -I -B -c 'import json,sys;print(json.dumps(json.loads(sys.argv[1])["risks"],separators=(",",":")))' "$row")"
    uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks" >/dev/null || return $?
    python3 -I -B - "$edge" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_RESULT" "$UBERDEV_CHILD_STATUS" "$descriptors" <<'PY'
import json,sys
edge,handoff,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'handoff':handoff,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    handoffs+=("$UBERDEV_CHILD_HANDOFF")
  done <"$records"
  uberdev_preflight_child_batch "${handoffs[@]}" || return $?
  while IFS= read -r row; do
    edge="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["edge"])' "$row")"
    handoff="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["handoff"])' "$row")"
    result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
    status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
    if receipt="$(uberdev_dispatch_child "$edge" "$handoff" "$result" "$status")"; then
      :
    else
      dispatch_rc=$?; cleanup_rc=0
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: prior child cleanup failed after dispatch edge=$edge" >&2
      return "$dispatch_rc"
    fi
    if python3 -I -B - "$edge" "$receipt" "$result" "$status" "$launched" <<'PY'
import json,sys
edge,receipt,result,status,path=sys.argv[1:]
with open(path,'a') as f:f.write(json.dumps({'edge':edge,'receipt':receipt,'result':result,'status':status},sort_keys=True,separators=(',',':'))+'\n')
PY
    then
      :
    else
      ledger_rc=$?; cleanup_rc=0
      uberdev_unwind_child "$status" "$result" "$timeout_s" || cleanup_rc=1
      while IFS= read -r row; do
        result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
        status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
        uberdev_unwind_child "$status" "$result" "$timeout_s" || cleanup_rc=1
      done <"$launched"
      [ "$cleanup_rc" -eq 0 ] || echo "error: current child cleanup failed after receipt ledger write edge=$edge" >&2
      return "$ledger_rc"
    fi
  done <"$descriptors"
}
review_child_wait_all() {
  local launched="$1" timeout_s="$2" row result status wait_rc first_rc=0 cleanup_rc=0
  while IFS= read -r row; do
    result="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["result"])' "$row")"
    status="$(python3 -I -B -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$row")"
    if uberdev_wait_child "$status" "$result" "$timeout_s"; then
      continue
    else
      wait_rc=$?
    fi
    [ "$first_rc" -ne 0 ] || first_rc="$wait_rc"
    uberdev_unwind_child "$status" "$result" "$timeout_s" || cleanup_rc=1
  done <"$launched"
  if [ "$first_rc" -ne 0 ]; then
    [ "$cleanup_rc" -eq 0 ] || echo "error: cleanup failed after child wait" >&2
    return "$first_rc"
  fi
  return 0
}
review_child_result_path() {
  local launched="$1" edge="$2"
  python3 -I -B - "$launched" "$edge" <<'PY'
import json,os,stat,sys
ledger,edge=sys.argv[1:]
def fail(reason):
    print(reason,end='')
    raise SystemExit(2)
try:
    ledger_entry=os.lstat(ledger)
except FileNotFoundError:
    fail('classification_ledger_missing')
except OSError:
    fail('classification_ledger_unreadable')
uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
if (stat.S_ISLNK(ledger_entry.st_mode) or not stat.S_ISREG(ledger_entry.st_mode)
        or ledger_entry.st_nlink!=1 or (uid is not None and ledger_entry.st_uid!=uid)
        or ledger_entry.st_size<1 or ledger_entry.st_size>1048576):
    fail('classification_ledger_unsafe')
try:
    rows=[json.loads(line) for line in open(ledger,encoding='utf-8') if line.strip()]
except (OSError,UnicodeError,json.JSONDecodeError):
    fail('classification_ledger_malformed')
if any(not isinstance(row,dict) for row in rows):
    fail('classification_ledger_malformed')
matches=[row for row in rows if row.get('edge')==edge]
if not matches:
    fail('classification_ledger_edge_missing')
if len(matches)>1:
    fail('classification_ledger_duplicate')
path=matches[0].get('result')
status=matches[0].get('status')
if (not isinstance(path,str) or not os.path.isabs(path)
        or os.path.basename(path)!='result.md'
        or os.path.basename(os.path.dirname(os.path.dirname(path)))!='children'):
    fail('classification_result_path_invalid')
if (not isinstance(status,str) or not os.path.isabs(status)
        or os.path.basename(status)!='status.json'
        or os.path.dirname(status)!=os.path.dirname(path)):
    fail('classification_status_path_invalid')
try:
    status_entry=os.lstat(status)
    if (stat.S_ISLNK(status_entry.st_mode) or not stat.S_ISREG(status_entry.st_mode)
            or status_entry.st_nlink!=1 or (uid is not None and status_entry.st_uid!=uid)
            or status_entry.st_size<1 or status_entry.st_size>65536):
        fail('classification_status_unsafe')
    status_value=json.loads(open(status,encoding='utf-8').read())
except (OSError,UnicodeError,json.JSONDecodeError):
    fail('classification_status_unreadable')
if (not isinstance(status_value,dict) or status_value.get('state')!='completed'
        or type(status_value.get('exit_code')) is not int or status_value['exit_code']!=0):
    fail('classification_child_not_completed_zero')
try:
    entry=os.lstat(path)
except FileNotFoundError:
    fail('classification_artifact_missing')
except OSError:
    fail('classification_artifact_unreadable')
if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode) or entry.st_nlink!=1
        or (uid is not None and entry.st_uid!=uid)):
    fail('classification_artifact_unsafe')
if entry.st_size<1 or entry.st_size>16777216:
    fail('classification_artifact_size_invalid')
print(os.path.realpath(path),end='')
PY
}
review_child_single() {
  local edge="$1" instance="$2" inputs="$3" risks="$4" prefix="$5" timeout_s="$6"
  : >"$prefix.records"
  review_child_record "$edge" "$instance" "$inputs" "$risks" "$prefix.records"
  review_child_fanout "$prefix.records" "$prefix.descriptors" "$prefix.launched" "$timeout_s" || return $?
  review_child_wait_all "$prefix.launched" "$timeout_s"
}
```
<!-- END review-child-builder-v1 -->

- **Phase 1 — Review + Fix loop**: invoke `Skill(uberdev:post-impl-review)` to run the 6 reviewer agents in one or more cap-controlled waves, with every child in each wave dispatched before its first wait; read the resulting findings aggregate from `.uberdev/research/<RUN_ID>/post-impl-review-final.md`, then dispatch a fresh `code-fixer` subagent to auto-apply fixes from the findings.
- **Phase 2 — Simplify pass**: parallel fanout of the three simplify lenses (reuse / quality / efficiency) defined in `/uberdev:simplify`, with auto-applied edits committed separately. Single-message dispatch per the `uberdev:post-impl-review` contract.

Pass `--no-simplify` (anywhere in the arguments) to skip Phase 2 and preserve the legacy single-pass behavior. Cost trade-off: Phase 2 adds three extra agent invocations per run; opt out for fast feedback loops on iterative review (e.g. when you've already run `/uberdev:simplify` separately).

Pass `--turbo` (anywhere in the arguments) to acknowledge invocation from `finish-branch`'s turbo-mode auto-chain. `/review-pr` accepts `--turbo` for forwarder-compatibility and parses it without error, but its presence does NOT alter Phase 1 or Phase 2. **Phase 3 halt classes (`billing_quota`, `platform_outage`) suppress the AskUserQuestion prompt under `--turbo` and exit 1 without emitting a trust signal** — under `--turbo`, neither halt class can prompt because the queue would block silently. Phases 1 and 2 still produce an identical Phase 2 simplify commit, identical trailer payload, identical artifact triplet (label + trailer + JSON). Single code path → deterministic SHA binding for the `Reviewed-by:` trailer. The flag is documented here so the producer-defines-its-API contract is explicit (no LLM interpretation latitude).

## Review Workflow:

1. **Determine Review Scope**
   - Check git status to identify changed files
   - Parse arguments to see if user requested specific review aspects
   - Detect `--no-simplify` token in `$ARGUMENTS` and strip it from the aspect list — sets `SIMPLIFY_PHASE=0`, otherwise `SIMPLIFY_PHASE=1` (default).
   - Detect `--turbo` token in `$ARGUMENTS` AND/OR inherited env var `${UBERDEV_TURBO:-0} == "1"` (#97 — hybrid OR detector). Strip the `--turbo` token from the aspect list. Set `TURBO=1` if either source signals turbo; else `TURBO=0`. The detection result feeds the Phase 3 halt-class carve-out (6c.6 HALT) — it does NOT mutate `SIMPLIFY_PHASE` or any other phase variable. Hybrid form (mirrors `orchestrator/SKILL.md`):
     ```bash
     TURBO=0
     if [[ "${ARGUMENTS:-}" == *"--turbo"* ]] || [[ "${UBERDEV_TURBO:-0}" == "1" ]]; then
       TURBO=1
     fi
     ```
     `${ARGUMENTS:-}` is defense-in-depth against `set -u` and mirrors the `${UBERDEV_TURBO:-0}` half of the OR for symmetry (#97 follow-up).
     Rationale: `merge-pipeline` invokes `Skill("uberdev:review-pr", args: "${PR} --turbo")` (out-of-scope for #97) — arg form must remain accepted. `finish-branch` chains via `Skill("uberdev:review-pr")` with no flag (env-var inheritance, #97) — env form must also be accepted. The hybrid OR detector closes both call sites.
   - Detect `--no-ci-fix` token in `$ARGUMENTS` and strip it from the aspect list — sets `CI_FIX_PHASE=0` (probe-only mode), otherwise `CI_FIX_PHASE=1` (default). Mirrors `--no-simplify` shape. When `CI_FIX_PHASE=0`, Phase 3 6c.1 PROBE + 6c.2 MONITOR + 6c.3 CLASSIFY still run for audit telemetry; 6c.4 ROUTE / 6c.5 POST-FIX / 6c.6 HALT are skipped. Outcome is forced to `green` if probe was green; otherwise `halted` (still gates trust signal).
   - Detect `--no-defer-issues` token in `$ARGUMENTS` and strip it from the aspect list — sets `DEFER_ISSUES_PHASE=0` (skip findings-to-issues sub-phase), otherwise `DEFER_ISSUES_PHASE=1` (default). Mirrors `--no-ci-fix` / `--no-simplify` shape. When `DEFER_ISSUES_PHASE=0`, the Phase 2.5 dispatch is skipped entirely and the Step 7 Final Aggregation "Issues filed" row shows `(skipped: --no-defer-issues)`.
   - Default: Run all applicable reviews + Phase 2 simplify pass
   - **Capture aspect tokens.** Tokenise the remaining arguments (after the `--no-simplify` and `--turbo` flags are stripped) into `ASPECT_LIST` (an array). Example: `/uberdev:review-pr tests errors` → `ASPECT_LIST=("tests" "errors")`. Empty arguments → `ASPECT_LIST=()`. The `all` token is treated as "no emphasis" (i.e., default behavior — every reviewer's brief receives no emphasis section).
   - **Detect `sequential` token.** If `$ARGUMENTS` contains the bare token `sequential` (anywhere; case-sensitive), strip it from `ASPECT_LIST` and set `SEQUENTIAL=1`. Otherwise `SEQUENTIAL=0`.
   - **If `SEQUENTIAL=1`,** emit the user-visible stderr notice and export the env var BEFORE the Step 4 `Skill()` invocation (kept here so the env var inherits into the skill's process):
     ```bash
     echo "notice: running post-impl-review sequentially via UBERDEV_FANOUT_POST_IMPL_REVIEW=1" >&2
     export UBERDEV_FANOUT_POST_IMPL_REVIEW=1
     ```
     The skill's Step 2 fanout cap reads `UBERDEV_FANOUT_POST_IMPL_REVIEW` via `uberdev_read_int_in_range`, so a value of `1` yields `ceil(6/1) = 6` sequential one-child waves. The dispatch-before-wait invariant is preserved within each wave.

   ### Argument Parsing Summary

   | Variable | Source | Default | Effect |
   |---|---|---|---|
   | `SIMPLIFY_PHASE` | `--no-simplify` token | `1` | `0` skips Phase 2 |
   | `SEQUENTIAL` | `sequential` token | `0` | `1` exports `UBERDEV_FANOUT_POST_IMPL_REVIEW=1` (stderr notice emitted) |
   | `CI_FIX_PHASE` | `--no-ci-fix` token | `1` | `0` runs PROBE+MONITOR+CLASSIFY (audit-only) but skips ROUTE+POST-FIX+HALT — outcome forced to `green` if probe was green, otherwise `halted` (still gates trust signal). |
   | `TURBO` | `--turbo` token OR `UBERDEV_TURBO=1` env (hybrid OR, #97) | `0` | `1` activates the Phase 3 halt-class carve-out (6c.6 HALT — no AskUserQuestion, exit 1, no trust signal). Phases 1+2 unchanged in either mode. |
   | `ASPECT_LIST` | remaining tokens | `()` | passed as `aspect_emphasis` input to `Skill(uberdev:post-impl-review)` Step 4 |
   | `DEFER_ISSUES_PHASE` | `--no-defer-issues` token | `1` | `0` skips Phase 2.5 (findings-to-issues sub-phase); the effective enable is AND-of-flag-and-config — `defer_issues_enabled=false` in `.codex/uberdev.local.md` (falling back to `.claude/uberdev.local.md`) short-circuits identically. |

2. **Available Review Aspects:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable reviews (default)

   Note: aspect filters are captured into `ASPECT_LIST` in Step 1 and passed to `Skill(uberdev:post-impl-review)` as the `aspect_emphasis` input (Step 4). The skill appends a `## Emphasis` section to every reviewer's brief, listing the requested aspects verbatim. The 6 agents always run; cap-controlled wave membership is independent of emphasis, so emphasis is advisory and never gates dispatch. `/uberdev:review-pr tests` produces a measurably different brief from `/uberdev:review-pr all` — the former includes `## Emphasis: tests`, the latter omits the section entirely.

3. **Identify Changed Files**
   - Run `git diff --name-only` to see modified files
   - Resolve the selected PR explicitly in the current repository; never rely
     on branch inference from a bare `gh pr view`.
   - Identify file types and what reviews apply

   ```bash uberdev-executable origin=review-pr
   review_assert_selected_pr_head() {
     local repo_slug="$1" pr_number="$2" expected_head="$3" worktree_root="$4"
     local live_head local_head
     [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
     [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 2
     [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || return 2
     live_head="$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq .headRefOid 2>/dev/null)" || return 2
     local_head="$(git -C "$worktree_root" rev-parse HEAD 2>/dev/null)" || return 2
     [ "$live_head" = "$expected_head" ] && [ "$local_head" = "$expected_head" ]
   }
   REVIEW_REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
   REVIEW_PR_METADATA="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" \
     --json number,baseRefOid,baseRefName,headRefOid)"
   REVIEWED_HEAD_SHA="$(printf '%s' "$REVIEW_PR_METADATA" | jq -er '.headRefOid')"
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" \
     "$REVIEWED_HEAD_SHA" "$WORKTREE_ROOT" || {
       echo "error: selected PR head does not equal local HEAD; refusing review dispatch" >&2
       OUTCOME=halted
       exit 2
     }
   ```

   This assertion runs before the first Phase 1 dispatch. On every Phase 1
   re-entry, re-read the live `headRefOid` with the same explicit repository and
   PR number, require it to equal local HEAD, then replace
   `REVIEWED_HEAD_SHA`. A mismatch halts before reviewer/fixer dispatch, push,
   or trust emission.

4. **Phase 1 — Dispatch `Skill(uberdev:post-impl-review)`**

   Generate a fresh `RUN_ID` for this `/review-pr` invocation:
   ```bash
   RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
   ```
   Validate against the regex `^[0-9]{8}-[0-9]{6}-[a-f0-9]+$` (see "Run-ID format" subsection below); on validation failure, exit 2 and surface the bug. Note: this `RUN_ID` is **decoupled** from any earlier `subagent-driven-dev` `RUN_ID` — `/review-pr` mints its own.

   **Locked-marker write (issue #220, AC ❶):** Before invoking the post-impl-review skill, write a sibling `.uberdev/runs/<RUN_ID>/locked` zero-byte marker + `pr-context.json` so a concurrent `/uberdev:goal` Phase 2b knows this PR's `/review-pr` is in-flight (avoids re-dispatching ours while the leaf solver's own is still running):

   ```bash
   # B3 (post-impl-review): the marker-write + EXIT-trap MUST live in ONE bash
   # fence. When split across fences each fence is its own subshell — MARKER_DIR
   # never propagates to the trap-install fence, the trap expands to literal
   # empty paths (`rm -f "/locked" "/pr-context.json"; rmdir ""`), and it fires
   # at the END of the trap-installer fence rather than at /review-pr exit. The
   # latent bug meant the marker was never cleaned up; B1's worktree-glob mirror
   # would then surface stale markers indefinitely.
   PR_NUM="$PR_NUMBER"
   ISSUE_NUM="$(gh pr view --json body -q .body 2>/dev/null | grep -oE 'Closes #[0-9]+' | head -n1 | grep -oE '[0-9]+')"
   if [ -n "$PR_NUM" ] && [ "$PR_NUM" -gt 0 ] 2>/dev/null; then
     MARKER_DIR="$(git rev-parse --show-toplevel)/.uberdev/runs/$RUN_ID"
     mkdir -p "$MARKER_DIR"
     : > "$MARKER_DIR/locked"  # creates .uberdev/runs/$RUN_ID/locked zero-byte sentinel
     jq -n --argjson pr "$PR_NUM" --arg issue "${ISSUE_NUM:-0}" --arg ts "$(date -u +%FT%TZ)" \
       '{pr: $pr, issue: ($issue|tonumber? // 0), started_at: $ts}' > "$MARKER_DIR/pr-context.json"
     # Trap-slot audit: no pre-existing EXIT trap found (issue #220 §3.2).
     # Install in the SAME fence so MARKER_DIR is in scope when the trap expands.
     trap 'rm -f "$MARKER_DIR/locked" "$MARKER_DIR/pr-context.json" 2>/dev/null; rmdir "$MARKER_DIR" 2>/dev/null || true' EXIT
   fi
   ```

   The locked marker is read by `/uberdev:goal` Phase 2b via `_uberdev_goal_locked_marker_for_pr_fresh "$pr_num" "$REVIEW_GRACE_SECS"` (lib/goal-state.sh). The contract is additive — `/review-pr` runs identically whether `/goal` is the caller or a human is. The trap fires on every exit path (success, failure, signal) so an orphaned marker is bounded by the natural EXIT signal — and even on SIGKILL the `/goal` reader's grace-window check (REVIEW_GRACE_SECS, default 3600s) bounds staleness without operator intervention. See RFC 0005 §9 D220b for the cross-component design rationale.

   Compute Phase 1 inputs from the PR:
   - `changed_paths` — normalized, non-empty POSIX repository-relative paths from the same fixed local `git diff <merge-base>..<head> --name-only` snapshot used for the Phase 1 diff artifact and commit range. The GitHub server-side path list is not authoritative on entry or re-entry. Preserve deleted or otherwise missing entries as path strings; absolute paths, traversal, dot components, backslashes, control characters, and unsafe names are rejected by the `repo_path_array` handoff contract before provider launch.
   - `commit_range` — `<merge-base>..<reviewed-head-sha>`, where `<merge-base>` is the computed merge-base commit between the PR base ref and the captured reviewed head. Never substitute moving `HEAD` after this snapshot is captured.
   - `tier` — passed through from `$ARGUMENTS` if present (forwarded by `finish-branch`'s chain), else default `medium`.

   Recompute the review scope from one fixed local base-to-HEAD snapshot on
   every Phase 1 entry, including CI-fix re-entry. This keeps the path list,
   diff artifact, and commit range bound to the same post-fix HEAD:

   ```bash
   review_resolve_phase1_base() {
     python3 -I -B - "$1" "$2" "$3" <<'PY'
import json,re,subprocess,sys
pr,root,repo=sys.argv[1:]
if re.fullmatch(r'[1-9][0-9]*',pr) is None: raise SystemExit(2)
metadata=json.loads(subprocess.check_output(
    ['gh','pr','view',pr,'--repo',repo,'--json','baseRefOid,baseRefName'],text=True))
base_oid=metadata.get('baseRefOid'); base_name=metadata.get('baseRefName')
if re.fullmatch(r'[0-9a-f]{40}',base_oid or '') is None or not isinstance(base_name,str) or not base_name:
    raise SystemExit(2)
try:
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
except subprocess.CalledProcessError:
    subprocess.run(['git','-C',root,'fetch','--no-tags','origin',base_name],check=True)
    subprocess.run(['git','-C',root,'cat-file','-e',base_oid+'^{commit}'],check=True,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
base=subprocess.check_output(['git','-C',root,'merge-base',head,base_oid],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
print(base,end='')
PY
   }
   review_refresh_phase1_scope() {
     local base="$1"
     CHANGED_PATHS_JSON="$(python3 -I -B - "$WORKTREE_ROOT" "$base" "$DIFF_ARTIFACT_PATH" "$COMMIT_RANGE_PATH" <<'PY'
import json,os,re,stat,subprocess,sys,tempfile
root,base,diff_path,range_path=sys.argv[1:]
MAX_DIFF_LINES=2000
MAX_DIFF_BYTES=8*1024*1024
MAX_WRAPPED_DIFF_BYTES=16*1024*1024
if re.fullmatch(r'[0-9a-f]{40}',base) is None: raise SystemExit(2)
head=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip()
if re.fullmatch(r'[0-9a-f]{40}',head) is None: raise SystemExit(2)
subprocess.run(['git','-C',root,'merge-base','--is-ancestor',base,head],check=True)
raw_paths=subprocess.check_output(['git','-C',root,'diff','--name-only','-z',f'{base}..{head}'])
paths=[item.decode('utf-8','strict') for item in raw_paths.split(b'\0') if item]
if not paths: raise SystemExit(2)
for path in paths:
    parts=path.split('/')
    if (path.startswith('/') or '\\' in path or any(part in ('','.','..') for part in parts)
            or any(ord(char)<32 or ord(char)==127 for char in path)):
        raise SystemExit(2)
def escape_untrusted_diff_payload(payload):
    return payload.replace(b'&',b'&amp;').replace(b'<',b'&lt;')
def wrap_untrusted_diff(payload):
    escaped=escape_untrusted_diff_payload(payload)
    opening=b'<external-untrusted-input source="pr-diff">'
    closing=b'</external-untrusted-input>'
    wrapped=opening+b'\n'+escaped+closing+b'\n'
    if wrapped.count(opening)!=1 or wrapped.count(closing)!=1: raise ValueError()
    return wrapped
def build_diff_summary():
    summary=['[diff summarized: full binary diff exceeded the 2000-line, 8-MiB raw, or 16-MiB wrapped review artifact limit]']
    summary_bytes=len((summary[0]+'\n').encode())
    summary_wrapped_bytes=len(wrap_untrusted_diff((summary[0]+'\n').encode()))
    omission_reserve=128
    stats=subprocess.Popen(['git','-C',root,'diff','--numstat','--no-renames',f'{base}..{head}'],
                           stdout=subprocess.PIPE,text=True,encoding='utf-8',errors='strict')
    omitted=0
    for line in stats.stdout:
        fields=line.rstrip('\n').split('\t',2)
        if len(fields)!=3: raise SystemExit(2)
        added,deleted,path=fields
        detail='binary change' if added==deleted=='-' else f'{added} additions, {deleted} deletions'
        row=f'{path} — {detail}'
        encoded=(row+'\n').encode()
        escaped_size=len(escape_untrusted_diff_payload(encoded))
        if (summary_bytes+len(encoded)>MAX_DIFF_BYTES
                or summary_wrapped_bytes+escaped_size+omission_reserve>MAX_WRAPPED_DIFF_BYTES):
            omitted+=1
            continue
        summary.append(row)
        summary_bytes+=len(encoded)
        summary_wrapped_bytes+=escaped_size
    if stats.wait()!=0: raise SystemExit(2)
    if omitted: summary.append(f'[{omitted} additional file summaries omitted to preserve the artifact limit]')
    return ('\n'.join(summary)+'\n').encode()
def select_bounded_wrapped_diff(payload, summary_factory):
    wrapped=wrap_untrusted_diff(payload)
    if len(wrapped)<=MAX_WRAPPED_DIFF_BYTES: return wrapped
    wrapped=wrap_untrusted_diff(summary_factory())
    if len(wrapped)>MAX_WRAPPED_DIFF_BYTES: raise ValueError()
    return wrapped
process=subprocess.Popen(['git','-C',root,'diff','--binary','--no-ext-diff',f'{base}..{head}'],stdout=subprocess.PIPE)
diff_buffer=bytearray(); diff_lines=0; summarized=False
while True:
    chunk=process.stdout.read(65536)
    if not chunk: break
    diff_buffer.extend(chunk); diff_lines+=chunk.count(b'\n')
    if len(diff_buffer)>MAX_DIFF_BYTES or diff_lines>MAX_DIFF_LINES:
        summarized=True; process.kill(); break
process.stdout.close(); process.wait()
if not summarized and process.returncode!=0: raise SystemExit(2)
diff=build_diff_summary() if summarized else bytes(diff_buffer)
wrapped_diff=select_bounded_wrapped_diff(diff,(lambda: diff) if summarized else build_diff_summary)
def replace_private(path,payload):
    parent=os.path.dirname(path) or '.'
    fd,tmp=tempfile.mkstemp(prefix='.review-scope.',dir=parent)
    try:
        if os.name!='nt': os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp,path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
replace_private(diff_path,wrapped_diff)
expected_range=f'{base}..{head}\n'.encode()
replace_private(range_path,expected_range)
if open(range_path,'rb').read()!=expected_range: raise SystemExit(2)
print(json.dumps(paths,separators=(',',':')),end='')
PY
)" || return 2
   }
   BASE_SHA="$(review_resolve_phase1_base "$PR_NUMBER" "$WORKTREE_ROOT" "$REVIEW_REPO_SLUG")" || return 2
   REENTRY_HEAD_SHA="$(gh pr view "$PR_NUMBER" --repo "$REVIEW_REPO_SLUG" --json headRefOid --jq .headRefOid)" || return 2
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" "$REENTRY_HEAD_SHA" "$WORKTREE_ROOT" || return 2
   REVIEWED_HEAD_SHA="$REENTRY_HEAD_SHA"
   VALIDATED_FIXER_HEAD_SHA="$REVIEWED_HEAD_SHA"
   review_refresh_phase1_scope "$BASE_SHA" || return 2
   ```

   Invoke the post-impl-review skill through the context-only run-tree edge
   `review_pr.post_impl_review` (skill handoff, never a provider dispatch):

   > Invoke `uberdev:post-impl-review` via the `Skill` tool with `changed_paths`, `commit_range`, `tier`, `RUN_ID`, and `aspect_emphasis=$ASPECT_LIST` (so the skill writes to the same `RUN_ID`-keyed directory `/review-pr` will read, and the brief includes the emphasis section when aspects were requested).

   The skill runs its 6 reviewer agents in one or more cap-controlled waves, with every child in each wave dispatched before its first wait — see `plugins/uberdev/skills/post-impl-review/SKILL.md` for the canonical agent list, cap, and YAML return contract. The skill is the single source of truth for which agents fan out; this prose deliberately does not enumerate them.

   **Sequential mode** (only when explicitly requested via the `sequential` argument): if `SEQUENTIAL=1` was set in Step 1, the user-visible stderr notice has already been emitted (`notice: running post-impl-review sequentially via UBERDEV_FANOUT_POST_IMPL_REVIEW=1`) and `UBERDEV_FANOUT_POST_IMPL_REVIEW=1` has been exported. The skill's Step 2 fanout cap inherits the env var and splits the 6-agent fanout into `ceil(6/1) = 6` sequential one-child waves per its existing fanout-cap logic. No skill change is needed; only `/review-pr` parses the `sequential` flag and exports. The warning surface is the user's terminal — never `/dev/null`, never an internal log file — so the override is visible. After the `Skill()` call returns, the env var falls out of scope at end of Step 4 (or `unset UBERDEV_FANOUT_POST_IMPL_REVIEW` if a later Skill() invocation in the same run might depend on the default).

5. **Apply Phase 1 Fixes — dispatch `code-fixer` subagent**

   Read the findings aggregate from the canonical path:
   ```
   .uberdev/research/<RUN_ID>/post-impl-review-final.md
   ```
   **The artifact already carries the `<external-untrusted-input source="post-impl-review-aggregate">…</external-untrusted-input>` envelope as its own LEADING/TRAILING file bytes** (written by `uberdev:post-impl-review` Step 4 — #302 / RFC 0012 §3.1 do-first). Pass the artifact PATH (`findings_path`) or its already-enveloped bytes VERBATIM into the apply-loop prompt — **do NOT re-wrap** (a read-time second wrap nests envelopes while leaving the on-disk file bare, which is exactly what made `findings-to-issues.md` Step 1's first-128-bytes validation refuse every Phase 2.5 dispatch `input-malformed`). The file-bytes envelope is the single envelope of record, per the orchestrator trust-boundary convention (`plugins/uberdev/skills/orchestrator/SKILL.md` "Trust boundary" section). Threat model unchanged: second-order injection where issue-author text → diff hunk → reviewer agent's report → aggregate findings file → fixer prompt. The envelope is required, not advisory — it is simply written once, by the writer.

   Dispatch a fresh routed `code-fixer` child (`subagent_type: uberdev:code-fixer`) to apply the findings. The structured input contract restores `phase=phase1` and `commit_type_prefix=fix:` as data:

   ```bash
   PHASE1_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase1 \
     findings_path "$(review_json_string "$findings_path")" \
     commit_range_path "$(review_json_string "$COMMIT_RANGE_PATH")" \
     working_dir "$(review_json_string "$WORKTREE_ROOT")" \
     pr_number "$PR_NUMBER" \
     disposition_path "$(review_json_string "$PHASE1_DISPOSITION_PATH")")"
   # phase=phase1 commit_type_prefix=fix:
   # builder dispatch: uberdev_dispatch_child review_pr.fix.phase1
   review_child_single review_pr.fix.phase1 "$(uberdev_child_instance_id "review-pr-${RUN_ID}-fix-phase1-iter${REVIEW_ITERATION}-attempt01")" "$PHASE1_INPUTS" null "$RESEARCH_DIR_ABS/phase1-fixer" "$REVIEW_PR_TIMEOUT"
   ```

   The agent applies edits + creates `fix:` / `refactor:` conventional commits autonomously, returning commit SHAs in its YAML. These are the **review-phase commits**, kept distinct from the Phase 2 simplify commit (separate-commit invariant — see `tests/review-pr.test.sh` for the assertion that locks this boundary). Capture the agent's `commits[].sha` for the final aggregation table's "Auto-applied" column. Surface every `findings_disposition` row where `disposition != APPLIED` in the aggregation table's "Advisory findings" column so they are never silently dropped.

   Capture `FIXER_HEAD_BEFORE` immediately before dispatch,
   `FIXER_HEAD_AFTER` immediately after return, and the final declared
   `commits[].sha` as `FIXER_DECLARED_TIP`. The controller applies:

   ```bash uberdev-executable origin=review-pr
   review_track_validated_fixer_head() {
     local status="$1" before="$2" after="$3" declared_tip="${4:-}"
     [[ "$before" =~ ^[0-9a-f]{40}$ && "$after" =~ ^[0-9a-f]{40}$ ]] || return 2
     [ "$before" = "${VALIDATED_FIXER_HEAD_SHA:-}" ] || return 76
     case "$status" in
       APPLIED)
         [ "$before" != "$after" ] || return 77
         [ "$declared_tip" = "$after" ] || return 77
         git -C "$WORKTREE_ROOT" merge-base --is-ancestor "$before" "$after" || return 78
         VALIDATED_FIXER_HEAD_SHA="$after"
         ;;
       NO_FIXES_NEEDED|REFUSED)
         [ -z "$declared_tip" ] && [ "$before" = "$after" ] || return 75
         ;;
       *) return 2 ;;
     esac
   }
   ```

   Initialize `VALIDATED_FIXER_HEAD_SHA="$REVIEWED_HEAD_SHA"` on every Phase 1
   entry, including mandatory CI-fix re-entry. Call
   `review_track_validated_fixer_head` after each Phase 1 and Phase 2 fixer
   return. Any status/head/declaration/ancestry mismatch is
   `MUTATED_BLOCKED`: stop before publication and re-enter Phase 1 only after
   the unexpected history is resolved. A CI fixer never advances this variable
   directly; its successful push must take the mandatory Phase 1 re-entry path,
   which rebinds both head variables from the live/local equality gate.

   A returned `REFUSED` is publishable only when HEAD is unchanged. If the
   defensive gate observes mutation, normalize the state to
   `MUTATED_BLOCKED`, retain the exact post-return SHA, halt ordinary refusal
   publication, and re-enter Phase 1 against that SHA. Never emit trust or a
   terminal refusal for unreviewed mutated history.

   **Fail-closed boundary:** if the artifact file is missing or empty (e.g., a reviewer remained `BLOCKED`, supervision failed, or the skill crashed), record a supervisory failure and terminate `/review-pr` immediately. Do NOT dispatch the fixer, enter Phase 2, defer findings, or emit trust. The ordinary aggregate is produced only after all six reviewer slots have valid evidence; a missing aggregate is therefore infrastructure failure, never a zero-finding review result.

   If `code-fixer` returns `status: REFUSED` and the mutation gate confirms
   HEAD is unchanged, log the rationale and continue to Phase 2 with zero
   auto-applied Phase 1 fixes. The aggregation table notes "Phase 1 fixer
   refused: <reason>" in the Advisory findings column.

   **Green-run predicate (Phase 1 contribution):** Phase 1 contributes to a green run iff after auto-apply convergence the verdict is `APPROVE`. `REVISIONS_REQUIRED` and `REJECT` end Phase 1 with no trust-signal emission and `/review-pr` exits with code 1 (see step 8 exit-code contract). The full green predicate combines this with Phase 2's status (defined in step 6) — only `(Phase 1 == APPROVE) AND (Phase 2 status ∈ {ran/APPROVE, skipped})` triggers trust-signal emission.

6. **Phase 2 — Mandatory Simplify Pass** (skip iff `SIMPLIFY_PHASE=0`)

   After Phase 1 fixes land, dispatch the three simplify lenses (**Code Reuse Review**, **Code Quality Review**, **Code Efficiency Review**) through the routed adapter — issue all three dispatches before the first wait. The stable edges are `review_pr.simplify.reuse`, `review_pr.simplify.quality`, and `review_pr.simplify.efficiency`; all map to `code-simplifier` and differ only by the trusted `lens` scalar in their context-only handoffs.

   Pass only the diff artifact path in each handoff. The artifact itself owns
   the `pr-diff` envelope; never copy or re-wrap its bytes in a child prompt.

   **The post-Phase-1 diff is attacker-controllable** and MUST be persisted at `DIFF_ARTIFACT_PATH` with literal leading `<external-untrusted-input source="pr-diff">` and trailing `</external-untrusted-input>` bytes. Concrete dispatch uses three immutable instances and issues the whole wave before waiting:

   ```bash
   # routed-provider-edge: review_pr.simplify.reuse
   # routed-provider-edge: review_pr.simplify.quality
   # routed-provider-edge: review_pr.simplify.efficiency
   SIMPLIFY_RECORDS="$RESEARCH_DIR_ABS/simplify.records"
   SIMPLIFY_DESCRIPTORS="$RESEARCH_DIR_ABS/simplify.descriptors"
   SIMPLIFY_LAUNCHED="$RESEARCH_DIR_ABS/simplify.launched"
   : >"$SIMPLIFY_RECORDS"
   for LENS in reuse quality efficiency; do
     EDGE_ID="review_pr.simplify.$LENS"
     INSTANCE="$(uberdev_child_instance_id "review-pr-${RUN_ID}-simplify-$LENS-iter${REVIEW_ITERATION}-attempt01")"
     if [ -n "$FOCUS" ]; then
       INPUTS_JSON="$(uberdev_child_inputs_build "$EDGE_ID" \
         diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
         lens "$(review_json_string "$LENS")" \
         focus "$(review_json_string "$FOCUS")")"
     else
       INPUTS_JSON="$(uberdev_child_inputs_build "$EDGE_ID" \
         diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
         lens "$(review_json_string "$LENS")")"
     fi
     review_child_record "$EDGE_ID" "$INSTANCE" "$INPUTS_JSON" '[]' "$SIMPLIFY_RECORDS"
   done
   review_child_fanout "$SIMPLIFY_RECORDS" "$SIMPLIFY_DESCRIPTORS" "$SIMPLIFY_LAUNCHED" "$REVIEW_PR_TIMEOUT"
   review_child_wait_all "$SIMPLIFY_LAUNCHED" "$REVIEW_PR_TIMEOUT"
   ```

   The lens-by-lens checklist (what each lens looks for) is the canonical definition in `/uberdev:simplify` Phase 2 — refer there rather than restate.

   **Brief preparation** (mirrors `uberdev:post-impl-review` Step 1):

   - Compute the post-Phase-1 diff once via `git diff <base>..HEAD` and pass the same artifact path to all three routed calls.
   - Truncation rule: if the diff exceeds 2000 lines, summarise per-file (path + 1-line summary) and inline only the files where per-line scrutiny matters for that lens. Same rule as `uberdev:post-impl-review` SKILL Step 1.

   Each lens preserves the iron rule from `/uberdev:simplify`: **behavior preservation is non-negotiable.**

   **Auto-apply simplify edits — Step 6b: dispatch `code-fixer` subagent.** After the three lenses return their advisory findings, aggregate them to `.uberdev/research/<RUN_ID>/simplify-final.md` — **written with `<external-untrusted-input source="simplify-aggregate">` as the file's LEADING bytes and `</external-untrusted-input>` as its TRAILING bytes** (envelope-as-file-bytes, #302 / RFC 0012 §3.1 do-first; first-128-bytes contract per `agents/findings-to-issues.md` Step 1; dedup + write recipe per `commands/simplify.md` Phase 3 — byte-shape oracle `tests/fixtures/findings-to-issues/simplify-final.sample.md`). Then dispatch the `code-fixer` agent with `phase: phase2` and `commit_type_prefix: refactor:`:

   ```bash
   PHASE2_INPUTS="$(uberdev_child_inputs_build review_pr.fix.phase2 \
     findings_path "$(review_json_string "$RESEARCH_DIR_ABS/simplify-final.md")" \
     commit_range_path "$(review_json_string "$COMMIT_RANGE_PATH")" \
     working_dir "$(review_json_string "$WORKTREE_ROOT")" \
     pr_number "$PR_NUMBER" \
     disposition_path "$(review_json_string "$PHASE2_DISPOSITION_PATH")")"
   # subagent_type: uberdev:code-fixer; phase=phase2 commit_type_prefix=refactor:
   # builder dispatch: uberdev_dispatch_child review_pr.fix.phase2
   review_child_single review_pr.fix.phase2 "$(uberdev_child_instance_id "review-pr-${RUN_ID}-fix-phase2-iter${REVIEW_ITERATION}-attempt01")" "$PHASE2_INPUTS" null "$RESEARCH_DIR_ABS/phase2-fixer" "$REVIEW_PR_TIMEOUT"
   ```

   `PHASE2_HANDOFF` passes the already-enveloped `simplify-final.md` path; its
   bytes are consumed verbatim and are never re-wrapped.

   The agent creates ONE `refactor:` commit (R8.6 separate-commit invariant locks Phase 2 to a single `refactor:` per run; the agent's contract enforces this on the apply side, the test enforces it on the prose side). Reviewers must be able to tell "review fixes" apart from "simplify pass" by commit boundary alone — this distinct commit boundary is mandatory, not stylistic. Capture the agent's `commits[0].sha` for the final aggregation table's "Auto-applied" column for the Phase 2 row.

   Capture the Phase 2 `FIXER_HEAD_BEFORE`, `FIXER_HEAD_AFTER`, and declared
   `commits[0].sha`, then pass them through
   `review_track_validated_fixer_head`. Phase 2 uses the same fail-closed
   mutation and ancestry rules as Phase 1; a refusal is non-mutating or blocked.

   If `code-fixer` returns `status: REFUSED` for Phase 2, log the rationale, continue to trust-signal evaluation (the Phase 2 row in the aggregation table reads `Auto-applied: ∅` and "Phase 2 fixer refused: <reason>" surfaces in Advisory findings). Phase 2 status is `blocked` if and only if the lens fanout itself failed (timeout / parse error / aggregator crash); a fixer refusal does NOT make Phase 2 `blocked` — the lenses' findings are advisory.

   **On green Phase 2 (status ∈ {ran/APPROVE, skipped}), defer trust-signal emission to the dedicated end-of-run step** (see "Trust-Signal Emission" below). Phase 2's simplify commit body itself does **NOT** carry the `Reviewed-by:` trailer — the trailer is emitted as a separate trust-trail-anchor empty commit at the very end of `/review-pr`. This guarantees the trailer's referenced SHA always anchors the actual end-of-run HEAD regardless of how many Phase 1 / Phase 2 commits land, sidestepping the parent-vs-self SHA-mismatch class of bugs that per-simplify-commit-trailer patterns produce when Phase 2 makes a real commit on top of Phase 1's last commit. The trailer payload format is unchanged — `Reviewed-by: uberdev/review-pr@<40-char-sha>` — only the carrier-commit choice changes (anchor commit, not simplify commit).

   **Advisory-only findings** (where a lens declines to edit because the change carries behavior risk, or the agent flags a concern outside the iron-rule envelope) are **never silently dropped** — they surface in the Phase 2 row of the final aggregation table (step 7) so the human reviewer sees them.

   **Non-blocking but exit-coded.** Phase 2 status governs the exit code (see step 8 exit-code contract):

   - `ran/APPROVE` or `skipped` → eligible for green; exit 0 if Phase 1 was APPROVE.
   - `blocked` (timeout, agent error, parse failure, aggregator crash) → exit 2. Phase 1 review-fix work is **not undone** — those commits land normally — but no trust-signal artifacts (label / trailer / JSON) are emitted, and the exit code surfaces the silent-failure mode that previously got swallowed. The Phase 2 row's Status is `blocked` (lowercase). Fix the aggregator before re-running.

   Phase 2 verdict ≠ Phase 2 status: an APPROVE verdict with `ran` status counts toward green; REVISIONS_REQUIRED or REJECT verdicts do NOT block trust-signal emission (they surface as advisory findings in the final aggregation table — see step 7). The trust-signal predicate is rooted in *status* (did the fanout complete cleanly?), not *verdict*.

6a. **Post-fixer push — publish fix commits before Phase 3 (#302, RFC 0012 §3.1 do-first)**

   After the LAST fixer returns — the Step 6b Phase-2 fixer, or the Step 5 Phase-1 fixer when `SIMPLIFY_PHASE=0` (`--no-simplify` skips Step 6 entirely, so Step 5's fixer is the last one) — push the accumulated Phase 1 + Phase 2 fix commits so the Phase 3 PROBE (6c.1) and MONITOR (6c.2) validate the **post-fix remote SHA**. Without this push the remote head stays pre-fix until the trust-trail anchor push at end-of-run, so Phase 3 probes CI that never ran on the fixed code and a GREEN trust signal can describe code CI never built. **Exactly ONE push per review cycle — after the last fixer, never one per fixer**: each push spawns a full duplicate CI check set while `test.yml` has no concurrency group (#309 — the CI-concurrency PR lands only after this one; see the 6c.1 benign-cancel dedupe it depends on).

   ```bash
   # Mirrors the trust-trail anchor push guard (Trust-Signal Emission artifact 1):
   # a silently-failed push here would let Phase 3 probe a stale remote SHA and
   # emit a trust signal for code CI never ran on. exit 2 = blocked-equivalent
   # per the artifact-emission-failure prose (trust-signal contract broken).
   POST_FIXER_HEAD_SHA="$(git rev-parse HEAD)" || exit 2
   if [ "$POST_FIXER_HEAD_SHA" != "${VALIDATED_FIXER_HEAD_SHA:-}" ]; then
     echo "error: HEAD changed outside the validated review fixers; refusing publication" >&2
     exit 2
   fi
   if ! git push origin HEAD; then
     echo "error: post-fixer push failed (git push origin HEAD exited non-zero) — Phase 3 would probe a stale remote SHA. Re-run /review-pr after resolving." >&2
     exit 2
   fi
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" \
     "$VALIDATED_FIXER_HEAD_SHA" "$WORKTREE_ROOT" || {
       echo "error: post-fixer publication did not produce exact remote/local head equality" >&2
       exit 2
     }
   REVIEWED_HEAD_SHA="$VALIDATED_FIXER_HEAD_SHA"
   ```

   Only after the guarded push and exact live/local equality assertion does the
   controller promote `REVIEWED_HEAD_SHA` to the validated fixer tip. When
   neither fixer produced a commit, the candidate remains the entry snapshot
   and the push is an `Everything up-to-date` no-op (exit 0). On Phase 1
   re-entry iterations (6c.5) this full tracking/publication sequence re-runs
   after the re-entered Step 5/6b fixers — still exactly one push per iteration.
   This step is NOT gated by `SIMPLIFY_PHASE`, `CI_FIX_PHASE`, or
   `DEFER_ISSUES_PHASE` — it runs on every path that reaches Phase 2.5/Phase 3.

6b. **Phase 2.5 — Findings-to-Issues sub-phase** (skip iff `DEFER_ISSUES_PHASE=0` OR `defer_issues_enabled=false`)

    Reads the run aggregate artifacts produced by Phase 1 (`post-impl-review-final.md`) and Phase 2 (`simplify-final.md`), filters all issue-eligible deferred rows (`severity ∈ {blocker, critical, important, major} AND disposition != APPLIED`), maps them to BLOCKER / CRITICAL / MAJOR tiers, and persists them as durable GitHub issues with HTML-comment fingerprint dedupe. Default-on. The parent halts only when at least one BLOCKER is deferred or when the `MAX_NEW` cap truncates a BLOCKER/CRITICAL row; major/important filings and non-overflow critical filings remain non-halting.

    **Effective-enabled gate:** the sub-phase runs only when BOTH the CLI flag AND the config key are ON. Either knob disables (CLI flag `DEFER_ISSUES_PHASE=1` AND config `DEFER_ISSUES_CONFIG=true`).

    ```bash
    # Read the config-level enum (default: "true" — always-on per Q3).
    source "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh"
    DEFER_ISSUES_CONFIG=$(uberdev_read_enum defer_issues_enabled UBERDEV_DEFER_ISSUES_ENABLED 'true|false' 'true')

    # Effective-enabled: AND of CLI flag and config key. Either knob disables.
    if [ "$DEFER_ISSUES_PHASE" = "1" ] && [ "$DEFER_ISSUES_CONFIG" = "true" ]; then
      DEFER_ISSUES_EFFECTIVE=1
    else
      DEFER_ISSUES_EFFECTIVE=0
    fi
    ```

    **Dispatch variable bindings.** Before the routed dispatch, bind the
    command-owned worktree and run paths. The child derives and validates
    repository identity itself:

    ```bash
    WORKING_DIR_ABS="$(git rev-parse --show-toplevel)"
    RESEARCH_DIR_ABS="$WORKING_DIR_ABS/.uberdev/research/$RUN_ID"
    ```

    **Dispatch one routed findings child:**

    ```bash
    DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.defer.findings \
      phase1_path "$(review_json_string "$RESEARCH_DIR_ABS/post-impl-review-final.md")" \
      phase2_path "$(review_json_string "$RESEARCH_DIR_ABS/simplify-final.md")" \
      phase1_disposition_path "$(review_json_string "$PHASE1_DISPOSITION_PATH")" \
      phase2_disposition_path "$(review_json_string "$PHASE2_DISPOSITION_PATH")" \
      working_dir "$(review_json_string "$WORKING_DIR_ABS")" \
      pr_number "$PR_NUMBER")"
    review_child_single review_pr.defer.findings "$(uberdev_child_instance_id "review-pr-${RUN_ID}-defer-findings-iter${REVIEW_ITERATION}-attempt01")" "$DEFER_INPUTS" null "$RESEARCH_DIR_ABS/defer" "$REVIEW_PR_TIMEOUT"
    ```

    **Capture the return YAML** into shell variables `CREATED_URLS_JSON`, `COMMENTED_URLS_JSON`, `SKIPPED_CLOSED_JSON`, `BLOCKED_BY_DEDUPE_JSON`, `OVERFLOW_COUNT`, `BY_SEVERITY_BLOCKER`, `BY_SEVERITY_CRITICAL`, `BY_SEVERITY_MAJOR`, `HALTED_DUE_TO_OVERFLOW`, `PHASE2_5_HALTED` for the Step 7 Final Aggregation table AND the new GREEN/YELLOW/RED predicate (Trust-Signal Emission section). Validate the YAML before treating absent arrays as zero issues.

    Publication/origin/parse failures are infrastructure failures, not a
    zero-finding result. The controller applies this executable status gate:

    ```bash uberdev-executable origin=review-pr
    review_apply_phase2_5_status() {
      local status="$1"
      case "$status" in
        DONE|DONE_WITH_CONCERNS) return 0 ;;
        REFUSED)
          PHASE2_5_STATUS=blocked
          PHASE2_5_HALTED=true
          PHASE2_5_INFRA_FAILURE=true
          OUTCOME=halted
          PHASE2_5_FAILURE_REASON=findings_to_issues_refused
          return 74
          ;;
        MALFORMED)
          PHASE2_5_STATUS=blocked
          PHASE2_5_HALTED=true
          PHASE2_5_INFRA_FAILURE=true
          OUTCOME=halted
          PHASE2_5_FAILURE_REASON=findings_to_issues_malformed
          return 74
          ;;
        *) return 2 ;;
      esac
    }
    ```

    A malformed return is normalized to `MALFORMED`. If
    `review_apply_phase2_5_status` returns non-zero, record the blocked Phase
    2.5 row and terminate with exit 2 before any trust-trail anchor, label, or
    audit approval artifact. `REFUSED` cannot be overridden interactively.
    Only a configured skip is non-halting and GREEN-eligible.

    ### 6b.1 Phase 2.5 halt handling (RFC 0002 §3.5)

    Immediately after capturing the agent return YAML, branch on `PHASE2_5_HALTED`:

    ```bash
    if [ "${PHASE2_5_HALTED:-false}" = "true" ]; then
      # Phase 2.5 filed at least one BLOCKER tier issue OR truncated a BLOCKER/CRITICAL.
      # Surface a user-visible halt block; the RED trust-trail emission downstream
      # will skip the label + trailer.
      :
    fi
    ```

    **User-visible halt prose** (rendered to stderr regardless of `TURBO`):

    ```
    /uberdev:review-pr — Phase 2.5 halt (RFC 0002)
      blocker filings:   $BY_SEVERITY_BLOCKER
      critical filings:  $BY_SEVERITY_CRITICAL
      overflow halt:     $HALTED_DUE_TO_OVERFLOW (truncated count: $OVERFLOW_COUNT)
      filed issues:      <render created_urls + commented_urls as bullet list with tier>
      trust trail:       RED — no Reviewed-by trailer, no uberdev-approved label
      /merge will:       INVALID until issues resolved OR --accept-blocker-deferred passed
    ```

    **Interactive (`TURBO=0` AND stdin is a TTY) — AskUserQuestion:**

    ```
    ToolSearch({ query: "select:AskUserQuestion" })   // mandatory deferred-tool load (same gate as 6c.6)
    AskUserQuestion({
      question: "Phase 2.5 filed $BY_SEVERITY_BLOCKER blocker issue(s). Trust trail will emit RED — /merge will block this PR until resolved. How to proceed?",
      options: [
        { label: "Print /solve suggestion + RED", description: "Render '/uberdev:solve <highest-priority issue URL>' suggestion to stderr; emit RED trail; exit 1. User runs /solve in a follow-up turn." },
        { label: "Skip — RED trail",              description: "Issues stay open, RED trail emitted, /merge blocked until resolved. Exit 1." },
        { label: "Override — emit GREEN",         description: "Log override_reason in audit JSON; /merge requires --i-know-what-im-doing flag to proceed" }
      ],
      multiSelect: false
    })
    ```

    **ToolSearch fail-fast.** When `ToolSearch` fails to load `AskUserQuestion`, `/review-pr` aborts with stderr error — **NEVER silently auto-pick** (mirrors `orchestrator/SKILL.md:190-193` and 6c.6 HALT). The deterministic shell:

    ```
    if ! ToolSearch("select:AskUserQuestion") >/dev/null 2>&1; then
      echo "error: AskUserQuestion tool unavailable — Phase 2.5 halt-choice cannot be presented; aborting" >&2
      audit halt_tool_unavailable data.tool="AskUserQuestion"
      exit 1
    fi
    ```

    Capture the choice into `PHASE2_5_HALT_CHOICE ∈ {solve_suggestion, skip, override}`.

    **Non-interactive (`TURBO=1` OR no TTY):** default to `solve_suggestion` (it preserves actionable information for the operator who later reads the run log) with the prose summary above. `override` is interactive-only by design — an unattended override poisons the trust trail with no human review.

    **`solve_suggestion` rendering** — emit one stderr line per filed BLOCKER URL: `next: /uberdev:solve <URL>`. The user runs the suggested command in a follow-up turn; `/review-pr` itself does not background-dispatch `/solve` (sub-process dispatch from inside a halted review run is out of scope per RFC 0002 §7.1 — defaults to hard-stop to avoid cascading agent loops).

    **`override` audit field:** if `PHASE2_5_HALT_CHOICE == "override"`, set `OVERRIDE_REASON="user-selected-emit-green-on-blocker-deferred"` for the audit JSON. Otherwise `OVERRIDE_REASON=null`. The override only suppresses the RED downgrade in the trust-trail emission step; it does NOT close the filed issues — `/merge` reads the override flag on the audit JSON and requires `--i-know-what-im-doing` to merge anyway.

    `PHASE2_5_HALTED=false` (the common path — no blocker, no critical/blocker overflow) skips this entire block; control falls through to Step 6c.

    **Skip-path behaviour** (when `DEFER_ISSUES_EFFECTIVE=0`):
    - Do NOT call `routed child (subagent_type: uberdev:findings-to-issues, …)`.
    - The Step 7 Final Aggregation "Issues filed" row shows `(skipped: --no-defer-issues)` when `DEFER_ISSUES_PHASE=0`, OR `(skipped: defer_issues_enabled=false)` when the config key is the cause. When both knobs disable, the message names both causes joined by " and " (e.g. `(skipped: --no-defer-issues and defer_issues_enabled=false)`).

6c. **Phase 3 — CI Health** (skip iff `CI_FIX_PHASE=0` is set AND mode is probe-only — see flag handling below)

    Phase 3 runs after Phase 2 and before trust-signal emission. It probes live CI on the post-Phase-2 HEAD, monitors pending runs, classifies red runs into one of six failure classes (`CI_FAILURE_CLASS_ENUM` defined in `plugins/uberdev/skills/merge-pipeline/SKILL.md` Constants), routes to specialized fixer agents for resolvable classes, and halts via `AskUserQuestion` (or audit-only under `--turbo`) for the two classes no code change can resolve. The trust-signal anchor commit (Step 7) is gated on Phase 3's outcome.

    Loop counter and cap defined in 6c.7 LOOP GUARD below (`CI_FIX_LOOP_CAP = 3`, declared in `merge-pipeline/SKILL.md` Constants). On cap exhaustion → `OUTCOME=loop_cap_exhausted`, exit 1. **The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge-pipeline/SKILL.md` "PARK is the terminal floor" prose is restated here.**

    ### 6c.1 PROBE — gh pr checks JSON probe

    **Pre-flight rate-limit check:** the floor `200` below is `CI_PROBE_RATE_LIMIT_FLOOR` (declared in `merge-pipeline/SKILL.md` Constants — kept numeric inline because bash does not dereference markdown constants).

    ```bash
    RATE_REMAINING="$(gh api rate_limit --jq .resources.core.remaining 2>/dev/null)"
    # Validate gh succeeded AND returned a non-empty integer before comparison —
    # a depleted/adversarial GH API budget MUST NOT silently downgrade to a
    # GREEN-eligible outcome. Empty string or non-numeric output triggers the
    # ci_probe_unreachable carve-out (omit phases.phase3 block; Step 7 proceeds
    # as if probe was unreachable, NOT as skipped_no_checks).
    if ! [[ "$RATE_REMAINING" =~ ^[0-9]+$ ]]; then
      audit ci_probe_unreachable subreason=rate_limit_query_failed
      # phases.phase3 block omitted entirely (carve-out); skip to Step 7
    elif [ "$RATE_REMAINING" -lt 200 ]; then
      audit ci_probe_unreachable subreason=rate_limit_low remaining=$RATE_REMAINING
      # Treat rate-limit-low as ci_probe_unreachable carve-out — NOT a
      # GREEN-eligible skipped_no_checks. A depleted GH API budget (potentially
      # adversarial in CI) silently passing trust-signal is the security
      # regression this guard prevents. phases.phase3 block omitted; Step 7
      # proceeds as if gh were unreachable.
      # skip remaining 6c sub-steps; jump to Step 7
    fi
    ```

    **Probe call:**

    **Field contract (gh ≥ 2.83.1):** `gh pr checks --json` exposes `name`, `state`, and `bucket` — there is **no** `status` and **no** `conclusion` field (those were removed upstream; reading them errors `unknown JSON field`). `bucket` is gh's own canonical categorization of `state` and is the field this probe keys off:

    | `bucket` | `state` values folded into it (gh `aggregateChecks`) | meaning here |
    |---|---|---|
    | `pass` | `SUCCESS` | green |
    | `skipping` | `SKIPPED`, `NEUTRAL` | green-eligible (skipped/neutral never block) |
    | `pending` | `EXPECTED`, `REQUESTED`, `WAITING`, `QUEUED`, `PENDING`, `IN_PROGRESS`, `STALE` | still running → MONITOR |
    | `fail` | `ERROR`, `FAILURE`, `TIMED_OUT`, `ACTION_REQUIRED` | red |
    | `cancel` | `CANCELLED` | red |

    ```bash
    PROBE_JSON="$(gh pr checks "$PR_NUMBER" --json name,state,bucket 2>&1)" || PROBE_RC=$?
    # Validate PROBE_JSON is parseable JSON BEFORE the terminal-mapping
    # branches below try to interpret it. On gh failure (non-zero exit),
    # PROBE_JSON contains stderr text; jq parsing would silently produce
    # null and the prose below would treat it as "no checks" instead of
    # "probe failed" — masking a real outage as a GREEN-eligible skip.
    if [ "${PROBE_RC:-0}" -ne 0 ] && ! jq empty <<<"$PROBE_JSON" 2>/dev/null; then
      audit ci_probe_unreachable subreason=gh_failed_${PROBE_RC}
      # phases.phase3 block omitted entirely; skip to Step 7
    fi
    # Classify off bucket (gh's canonical state→bucket fold). A single jq pass
    # collapses the array to one of: empty / green / pending / red. Never
    # line-grep the buckets — parse as JSON.
    #
    # Benign-cancel same-name dedupe (#302), NARROWED to its motivating scope:
    # test.yml fires on BOTH push and pull_request, so one head SHA carries two
    # same-name check runs per job. Once #309's concurrency group lands, every
    # superseded push run reports bucket=cancel NEXT TO the authoritative
    # completed run — counting that benign cancel as red would manufacture a
    # permanent RED for every superseded push (which is why #309 MUST land after
    # this dedupe). group_by the check name (always present per the --json field
    # contract above); within a name-group, DROP the `cancel` rows IFF a non-cancel
    # sibling exists — a cancel only survives when it is the ONLY state for that
    # name (a genuine cancellation, still red). Everything else is kept verbatim
    # and fed UNCHANGED through the red>pending>green fold. This is deliberately
    # NOT best-state-wins: best-state-wins would let a completed push `pass`
    # launder its still-running (`pending`) or failed (`fail`) pull_request sibling
    # into the GREEN fast-path that skips MONITOR/CLASSIFY — re-opening the
    # GREEN-describes-code-CI-never-validated window this bundle exists to close
    # (the pull_request / merge-commit run is the authoritative one; a passed push
    # run must never mask it). Only the benign `cancel` row is laundered; fail and
    # pending stay un-maskable. `red` still outranks `pending` across the surviving
    # rows, and an unknown/missing bucket folds to red (fail-safe — never silently
    # green) so a broken gh field contract cannot downgrade the trust gate.
    PROBE_VERDICT="$(jq -r '
      def known_good: .bucket == "pass" or .bucket == "skipping";
      if (type != "array") or (length == 0) then "empty"
      else
        [ group_by(.name)[]
          | (if any(.[]; .bucket != "cancel") then map(select(.bucket != "cancel")) else . end)
          | .[] ] as $kept
        | if   any($kept[]; .bucket == "fail" or .bucket == "cancel") then "red"
          elif any($kept[]; .bucket == "pending")                     then "pending"
          elif all($kept[]; known_good)                               then "green"
          else "red" end
      end
    ' <<<"$PROBE_JSON" 2>/dev/null)"
    ```

    **Settle window for empty-checks (#302).** A JUST-pushed head (the Step 6a post-fixer push, or any fresh PR push) reports "no checks" for the first ~10–30 s while GitHub fans the workflow runs out — mapping that window straight to `skipped_no_checks` makes a GREEN-eligible outcome out of CI that was about to start. When the probe resolves `empty` (the jq `empty` verdict OR gh's `no checks reported on the` stderr signature) AND the head commit is younger than the settle threshold, re-probe before accepting `skipped_no_checks`. Literals: `CI_SETTLE_AGE_SEC = 120` and `CI_SETTLE_REPROBES = 3` (declared HERE — `/review-pr`-owned settle constants, kept numeric inline like the other 6c literals); re-probe interval 30 s (mirrors `CI_WATCH_INTERVAL_SEC`).

    ```bash
    if [ "$PROBE_VERDICT" = "empty" ] || printf '%s' "$PROBE_JSON" | grep -q 'no checks reported on the'; then
      HEAD_AGE_SEC=$(( $(date +%s) - $(git show -s --format=%ct HEAD) ))
      SETTLE_REPROBES_USED=0
      # Re-probe while: still empty AND head younger than CI_SETTLE_AGE_SEC (120)
      # AND fewer than CI_SETTLE_REPROBES (3) re-probes used. Each pass sleeps 30s,
      # re-runs the PROBE call + PROBE_VERDICT classification above verbatim, and
      # audits the attempt. An old head (>= 120s) with no checks is genuinely
      # checks-unconfigured — fall through to skipped_no_checks immediately.
      while { [ "$PROBE_VERDICT" = "empty" ] || printf '%s' "$PROBE_JSON" | grep -q 'no checks reported on the'; } \
            && [ "$HEAD_AGE_SEC" -lt 120 ] \
            && [ "$SETTLE_REPROBES_USED" -lt 3 ]; do
        sleep 30
        SETTLE_REPROBES_USED=$((SETTLE_REPROBES_USED + 1))
        # Re-run the 6c.1 PROBE call and PROBE_VERDICT jq classification above
        # (same command, same jq program — re-binds PROBE_JSON + PROBE_VERDICT).
        audit ci_probe_started subreason=settle_reprobe attempt=$SETTLE_REPROBES_USED head_age_sec=$HEAD_AGE_SEC
        HEAD_AGE_SEC=$(( $(date +%s) - $(git show -s --format=%ct HEAD) ))
      done
      # Only an empty verdict that SURVIVED the settle window (window expired or
      # re-probes exhausted) maps to skipped_no_checks in the terminal table below;
      # carry settle_reprobes_used + head_age_sec in the ci_probe_skipped_no_checks
      # audit payload for post-mortem.
    fi
    ```

    Terminal mappings (parsed as JSON; never line-grepped; bucket conditions apply AFTER the same-name benign-cancel dedupe above — only cancel rows with a non-cancel sibling are dropped; fail/pending are never masked):

    | `PROBE_JSON` content | `PROBE_VERDICT` | OUTCOME | Audit event |
    |---|---|---|---|
    | stderr matches `no checks reported on the` (or empty `[]`) AND the settle window above is exhausted (head age ≥ 120 s, or 3 re-probes used) | `empty` | `skipped_no_checks` | `ci_probe_skipped_no_checks` (payload carries `settle_reprobes_used` + `head_age_sec`) |
    | all deduped names `bucket ∈ {pass, skipping}` | `green` | `green` | `ci_phase_outcome` (terminal, payload `outcome=green` — fast-path skip past MONITOR/CLASSIFY) |
    | any deduped name `bucket == pending` (and none `fail`/`cancel`) | `pending` | (proceed to MONITOR) | `ci_probe_started` |
    | any deduped name `bucket ∈ {fail, cancel}` | `red` | (proceed to MONITOR + classify if all settled) | `ci_probe_started` |
    | `gh` exit non-zero AND no usable JSON | — | (carve-out — `phases.phase3` block omitted from audit JSON; Step 7 proceeds as if `OUTCOME=skipped_no_checks`) | `ci_probe_unreachable` |

    The `gh pr checks` output MUST be parsed as JSON, never line-grepped.

    ### 6c.2 MONITOR — gh pr checks --watch

    The literals `1200` and `30` below are `CI_MONITOR_TIMEOUT_SEC` and `CI_WATCH_INTERVAL_SEC` respectively (declared in `merge-pipeline/SKILL.md` Constants — kept numeric inline because bash does not dereference markdown constants).

    ```bash
    timeout 1200 gh pr checks "$PR_NUMBER" --watch --interval 30
    ```

    **`--watch` takes NO `--json`:** gh refuses `--watch` together with `--json` (`cannot use --watch with --json flag`, verified live on gh 2.83.1) — that is why the field list is absent here even though 6c.1 PROBE reads `--json name,state,bucket`. MONITOR keys off the **exit code** (gh's documented `gh pr checks` contract), not parsed JSON, so it needs no field projection. Wall-clock cap: **20 minutes** (`timeout 1200` = `CI_MONITOR_TIMEOUT_SEC`). The watch terminates on its own once every check leaves the `pending` bucket. On exit code 0 → all green → `OUTCOME=green` → audit `ci_monitor_green`. Exit 8 (still pending after watch terminates — `gh pr checks` exit code 8 = "Checks pending", per `gh pr checks --help`) → `ci_monitor_timeout` audit; halt loop iteration with `OUTCOME=halted` (carry differentiation in audit `data.subreason=monitor_timeout`; `halted` is the canonical CI_OUTCOME_ENUM member, not a `halted_timeout` synthetic). Non-zero non-8 → at least one check failed → audit `ci_monitor_red`; proceed to CLASSIFY.

    `--fail-fast` is **NOT** used (the classifier needs the complete failure picture). The 30-second `--interval` floor (`CI_WATCH_INTERVAL_SEC`) is intentional (rate-limit guard).

    ### 6c.3 CLASSIFY — routed ci-failure-classifier

    Read the failed check's log via `gh run view <run-id> --log`. The log content MUST be wrapped in:

    ```
    <external-untrusted-input source="github-actions-log-pr-<N>-run-<id>">
    …log content (truncated to last 500 lines per check — `CI_LOG_TRUNCATE_LINES`)…
    </external-untrusted-input>
    ```

    Dispatch the classifier:

    ```bash
    CI_CLASSIFY_INPUTS="$(uberdev_child_inputs_build review_pr.ci.classify \
      pr_number "$PR_NUMBER" \
      run_id "$(review_json_string "$CI_RUN_ID")" \
      log_path "$(review_json_string "$CI_LOG_ARTIFACT_PATH")")"
    if review_child_single review_pr.ci.classify "$(uberdev_child_instance_id "review-pr-${RUN_ID}-ci-classify-iter${CI_FIX_LOOP_ITER:-1}-attempt01")" "$CI_CLASSIFY_INPUTS" '[]' "$RESEARCH_DIR_ABS/ci-classify" "$REVIEW_PR_TIMEOUT"; then
      :
    else
      CI_CLASSIFY_CHILD_RC=$?
      audit ci_classify_returned subreason=classifier_child_failed exit_code="$CI_CLASSIFY_CHILD_RC"
      OUTCOME=halted
      exit 1
    fi
    CI_CLASSIFICATION_PATH="$(review_child_result_path "$RESEARCH_DIR_ABS/ci-classify.launched" review_pr.ci.classify)" || {
      case "$CI_CLASSIFICATION_PATH" in
        classification_ledger_missing|classification_ledger_unreadable|classification_ledger_unsafe|classification_ledger_malformed|classification_ledger_edge_missing|classification_ledger_duplicate|classification_result_path_invalid|classification_status_path_invalid|classification_status_unsafe|classification_status_unreadable|classification_child_not_completed_zero|classification_artifact_missing|classification_artifact_unreadable|classification_artifact_unsafe|classification_artifact_size_invalid) ;;
        *) CI_CLASSIFICATION_PATH=classification_result_discovery_failed ;;
      esac
      audit ci_classify_returned subreason="$CI_CLASSIFICATION_PATH"
      OUTCOME=halted
      exit 1
    }
    ```

    Audit `ci_classify_dispatched` on dispatch; `ci_classify_returned` on return (with `data.failure_class ∈ CI_FAILURE_CLASS_ENUM`).

    The agent returns YAML — see `plugins/uberdev/agents/ci-failure-classifier.md` for the canonical contract. On `status: AMBIGUOUS` (no regex matched), caller falls back to treating it as `flaky` for routing purposes (re-run once, then halt). **Emit `ci_classify_ambiguous_routing_as_flaky` audit event when this fallback fires** — the original AMBIGUOUS state must surface in the post-mortem trail; conflating it with a known-transient `flaky` classification (without a distinct audit signal) loses root-cause context if the flaky re-run also fails.

    Before ROUTE, validate the parsed controller fields fail-closed as three explicit variants. `CLASSIFIED` requires one of the six `CI_FAILURE_CLASS_ENUM` values and a legal class/anchor pairing. `AMBIGUOUS` requires null class + null anchor and maps to flaky only after its dedicated audit event. `REFUSED` requires null class + null anchor plus a non-empty rationale and halts without being mislabeled `contract_invalid`. For `code_bug` / `env_drift`, the anchor must name an existing repository file; telemetry-only classes may use `gh-run-<id>:<line>`, where the run id is nonzero and the `signal_anchor` line is a positive integer. In particular, `:121`, `file:0`, absolute/traversal paths, blank anchors, unknown classes, and duplicate controller fields are contract violations. Never repair or reinterpret an invalid classifier result as `platform_outage` or `flaky`.

    ```bash
    review_validate_ci_classification() {
      python3 -I -B - "$1" "$2" <<'PY'
import json,pathlib,re,sys
path,root=sys.argv[1:]
raw=pathlib.Path(path).read_text(encoding='utf-8')
if len(raw.encode())>65536: raise SystemExit(2)
document=re.search(r'(?:^|\n)```yaml\r?\n(.*?)\r?\n```\r?\n?\Z',raw,re.DOTALL)
if document is None: raise SystemExit(2)
fields={}
for line in document.group(1).splitlines():
    match=re.fullmatch(r'([a-z_][a-z0-9_]*):[ \t]*(.*)',line)
    if not match: raise SystemExit(2)
    key,value=match.groups()
    if key in fields: raise SystemExit(2)
    fields[key]=value.strip()
required={'status','failure_class','signal_anchor','rationale','risks'}
if set(fields)!=required or fields['risks']!='[]': raise SystemExit(2)
def scalar(key):
    value=fields[key]
    if value=='null': return None
    try:
        if value.startswith('"'): parsed=json.loads(value)
        elif re.fullmatch(r"'(?:[^']|'')*'",value): parsed=value[1:-1].replace("''","'")
        elif re.fullmatch(r'[A-Za-z0-9_./:+ -]{1,256}',value): parsed=value
        else: raise ValueError()
    except (ValueError,json.JSONDecodeError):
        raise SystemExit(2)
    if not isinstance(parsed,str) or not parsed or len(parsed)>256 or any(ord(ch)<32 or ord(ch)==127 for ch in parsed):
        raise SystemExit(2)
    return parsed
status=scalar('status')
failure_class=scalar('failure_class')
anchor=scalar('signal_anchor')
rationale=scalar('rationale')
if status=='AMBIGUOUS':
    if failure_class is not None or anchor is not None: raise SystemExit(2)
    print('AMBIGUOUS\tflaky\t-\t-'); raise SystemExit(0)
if status=='REFUSED':
    if failure_class is not None or anchor is not None: raise SystemExit(2)
    print('REFUSED\t-\t-\t'+rationale); raise SystemExit(0)
classes={'code_bug','billing_quota','platform_outage','flaky','env_drift','stale_base'}
if status!='CLASSIFIED' or failure_class not in classes: raise SystemExit(2)
if anchor is None: raise SystemExit(2)
match=re.fullmatch(r'(.+):([1-9][0-9]*)',anchor)
if not match: raise SystemExit(2)
component=match.group(1)
is_run=bool(re.fullmatch(r'gh-run-[1-9][0-9]*',component))
def repository_file(value):
    if value.startswith('/') or '\\' in value: return False
    parts=value.split('/')
    if any(part in {'','.','..'} for part in parts): return False
    try:
        root_path=pathlib.Path(root).resolve(strict=True)
        target=(root_path/value).resolve(strict=True)
        return target.is_file() and (target.parent==root_path or root_path in target.parents)
    except (OSError,RuntimeError):
        return False
is_repo=repository_file(component)
if failure_class in {'code_bug','env_drift'}:
    if not is_repo: raise SystemExit(2)
elif not (is_run or is_repo):
    raise SystemExit(2)
print('CLASSIFIED\t'+failure_class+'\t'+anchor+'\t-')
PY
    }
    review_apply_ci_classification_status() {
      local status="$1" rationale="${2:-}"
      case "$status" in
        AMBIGUOUS)
          audit ci_classify_ambiguous_routing_as_flaky original_status=AMBIGUOUS
          return 0
          ;;
        REFUSED)
          audit ci_classify_returned subreason=classifier_refused rationale="$rationale"
          OUTCOME=halted
          return 78
          ;;
        CLASSIFIED) return 0 ;;
        *)
          audit ci_classify_returned subreason=contract_invalid
          OUTCOME=halted
          return 79
          ;;
      esac
    }
    IFS=$'\t' read -r classification_status failure_class signal_anchor classifier_rationale < <(review_validate_ci_classification "$CI_CLASSIFICATION_PATH" "$WORKTREE_ROOT") || {
      audit ci_classify_returned subreason=contract_invalid
      OUTCOME=halted
      exit 1
    }
    review_apply_ci_classification_status "$classification_status" "$classifier_rationale" || exit 1
    ```

    ### 6c.4 ROUTE — failure_class → downstream agent

    ```bash
    CI_FIX_INPUTS="$(uberdev_child_inputs_build review_pr.ci.fix_code \
      classification_path "$(review_json_string "$CI_CLASSIFICATION_PATH")" \
      log_path "$(review_json_string "$CI_LOG_ARTIFACT_PATH")" \
      working_dir "$(review_json_string "$WORKTREE_ROOT")" \
      pr_number "$PR_NUMBER")"
    CI_HEAD_SHA="$(git rev-parse HEAD)"
    CI_BASE_SHA="$(git merge-base HEAD "origin/${base_branch}")"
    CI_REBASE_INPUTS="$(uberdev_child_inputs_build review_pr.ci.rebase \
      working_dir "$(review_json_string "$WORKTREE_ROOT")" \
      pr_number "$PR_NUMBER" \
      head_sha "$(review_json_string "$CI_HEAD_SHA")" \
      base_sha "$(review_json_string "$CI_BASE_SHA")")"
    case $failure_class in
      code_bug | env_drift)        review_child_single review_pr.ci.fix_code "$(uberdev_child_instance_id "review-pr-${RUN_ID}-ci-fix-iter${CI_FIX_LOOP_ITER:-1}-attempt01")" "$CI_FIX_INPUTS" null "$RESEARCH_DIR_ABS/ci-fix" "$REVIEW_PR_TIMEOUT" ;;
      stale_base)                  review_child_single review_pr.ci.rebase "$(uberdev_child_instance_id "review-pr-${RUN_ID}-ci-rebase-iter${CI_FIX_LOOP_ITER:-1}-attempt01")" "$CI_REBASE_INPUTS" null "$RESEARCH_DIR_ABS/ci-rebase" "$REVIEW_PR_TIMEOUT" ;;
      flaky)                       if gh run rerun <run-id>; then
                                     audit ci_flaky_rerun_queued run_id=<run-id>
                                   else
                                     # gh run rerun can fail on auth/rate-limit/max-reruns;
                                     # silently dropping the exit code lets the loop hit
                                     # CI_FIX_LOOP_CAP with no actual fix attempts. Halt
                                     # cleanly so the user sees the rerun failure.
                                     audit ci_flaky_rerun_failed run_id=<run-id>
                                     OUTCOME=halted
                                     # carry data.subreason=flaky_rerun_failed in the
                                     # ci_phase_outcome event for post-mortem
                                   fi
                                   # max 1 retry per distinct check (RERUN_FLAKY_CAP=1)
                                   # does NOT increment CI_FIX_LOOP_ITER
                                   ;;
      billing_quota | platform_outage)  jump to 6c.6 HALT ;;
      *)                           # Default-case guard: defensive against future
                                   # CI_FAILURE_CLASS_ENUM extension landing without
                                   # a paired ROUTE arm. Silent fallthrough would
                                   # let the loop hit CI_FIX_LOOP_CAP with no fix
                                   # attempts; classifier-side, an unknown class is
                                   # already a contract violation (B8 pairing rule),
                                   # so audit + halt + exit 1 is the correct floor.
                                   audit ci_fix_dispatch_unknown_class reason=$failure_class
                                   OUTCOME=halted
                                   exit 1
                                   ;;
    esac
    ```

    Audit `ci_fix_dispatched` (with `data.by_agent ∈ {ci-code-fixer, ci-rebase-handler}`) on every dispatch. The `RERUN_FLAKY_CAP = 1` constant (declared in `merge-pipeline/SKILL.md`) bounds flake retries inside a single iteration; the loop counter is unaffected.

    ### 6c.5 POST-FIX — re-enter Phase 1 fanout

    **Branch on dispatched-fixer return status.** Before re-entry, condition on the dispatched fixer's return contract — only `ci-code-fixer` `status: APPLIED` and `ci-rebase-handler` `status: REBASED` produce a fix push that warrants Phase 1 re-entry. `ci-rebase-handler` `status: CONFLICT` triggers the CONFLICT-RESOLVE arm below; refusal statuses halt Phase 3:

    - `ci-code-fixer` `status: APPLIED` (commit SHA returned, no remote write per `agents/ci-code-fixer.md` Step 6) → caller pushes the agent's commit, treats it as a fix push, falls through to "Phase 1 re-entry" below.
    - `ci-code-fixer` `status: REFUSED` (RFC 0002 §3.2 — single-attempt halt; **do NOT retry**): the loop-counter cap from 6c.7 LOOP GUARD is bypassed for this terminal class because `REFUSED` is a deterministic decision (forbidden-pattern guard), not flake; retrying re-classifies the same red CI, re-dispatches the same fixer, and consumes 3 iterations of compute that the user could have spent reading the halt prose.

       Three actions in order:

       1. **File the failing test as a CRITICAL-tier GH issue via `findings-to-issues` dispatch.**

          This replaces the previous inline `gh issue create` with a `routed child (subagent_type: uberdev:findings-to-issues)` dispatch that funnels CI-REFUSED issue creation through the same agent that handles all other deferred-finding issue creation; eliminates the prose-drift risk between the two issue-creation sites.

          Construct a synthetic single-row aggregate wrapped in the `<external-untrusted-input source="ci-refused-synthetic">…</external-untrusted-input>` envelope (the receiving agent's Step 1 input validation recognises this source attribute — see `agents/findings-to-issues.md` Step 1 accepted-source allow-list). The aggregate carries one finding-row with `severity: critical`, `tier: CRITICAL`, `failure_class: <from-ci-code-fixer-return>`, `check_name: <from-ci-code-fixer-return>`, `signal_anchor: <from-ci-code-fixer-return>`, and `rationale: <from-ci-code-fixer-return>`. Title is built downstream by the agent using its existing CRITICAL-tier shape (`[finding] $file_path:$line — $summary`); labels and `--assignee` flag come from the agent's tier-aware bindings (`--label review-pr-finding`, `--assignee @<pr-author>`). The agent's return YAML's `created_urls[0].url` is captured into `CI_REFUSED_ISSUE_URL`.

          ```bash
          CI_REFUSED_AGGREGATE_PATH="$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md"
          if ! (umask 077; set -C; : >"$CI_REFUSED_AGGREGATE_PATH"); then
            audit ci_phase_outcome data.outcome=halted data.subreason=ci_refused_aggregate_create_failed
            exit 1
          fi
          python3 -I -B - "$CI_REFUSED_AGGREGATE_PATH" "${failure_class:-unknown}" \
            "${check_name:-unknown}" "${signal_anchor:-unknown:1}" "${rationale:-unspecified}" <<'PY'
import json,os,stat,sys
path,failure_class,check_name,signal_anchor,rationale=sys.argv[1:]
if any(len(value)>8192 or any(char in value for char in '\r\n\0') for value in (failure_class,check_name,signal_anchor,rationale)):
    raise SystemExit(2)
entry=os.lstat(path); uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode) or entry.st_nlink!=1
        or (uid is not None and entry.st_uid!=uid) or entry.st_size!=0
        or (os.name!='nt' and stat.S_IMODE(entry.st_mode)!=0o600)):
    raise SystemExit(2)
row={'severity':'critical','tier':'CRITICAL','agent_name':'ci-code-fixer',
     'failure_class':failure_class,'check_name':check_name,'location':signal_anchor,
     'summary':'CI fixer refused the classified failure','rationale':rationale,
     'disposition':'REFUSED'}
payload=('<external-untrusted-input source="ci-refused-synthetic">\n- '
         +json.dumps(row,sort_keys=True,separators=(',',':'))
         +'\n</external-untrusted-input>\n').encode('utf-8')
fd=os.open(path,os.O_WRONLY|getattr(os,'O_NOFOLLOW',0))
try:
    opened=os.fstat(fd); current=os.lstat(path)
    if (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino): raise SystemExit(2)
    if os.write(fd,payload)!=len(payload): raise SystemExit(2)
    os.fsync(fd)
finally:
    os.close(fd)
with open(path,'rb') as stream:
    if not stream.read(128).startswith(b'<external-untrusted-input source="ci-refused-synthetic">'):
        raise SystemExit(2)
PY
          if [ "$?" -ne 0 ]; then
            audit ci_phase_outcome data.outcome=halted data.subreason=ci_refused_aggregate_write_failed
            exit 1
          fi
          CI_DEFER_INPUTS="$(uberdev_child_inputs_build review_pr.ci.defer_refusal \
            phase1_path "$(review_json_string "$CI_REFUSED_AGGREGATE_PATH")" \
            working_dir "$(review_json_string "$WORKTREE_ROOT")" \
            pr_number "$PR_NUMBER")"
          review_child_single review_pr.ci.defer_refusal "$(uberdev_child_instance_id "review-pr-${RUN_ID}-ci-defer-refusal-iter${CI_FIX_LOOP_ITER:-1}-attempt01")" "$CI_DEFER_INPUTS" null "$RESEARCH_DIR_ABS/ci-defer" "$REVIEW_PR_TIMEOUT"
          ```

          `CI_REFUSED_AGGREGATE_PATH` is a fresh command-owned artifact at `$RESEARCH_DIR_ABS/ci-refused-synthetic-${CI_FIX_LOOP_ITER:-1}.md`, created with `umask 077` and noclobber before writing the envelope. It must remain beneath the canonical run research directory so the child handoff's `path` validation accepts it; do not use system `mktemp` or any path outside `$WORKTREE_ROOT`. Its first 128 bytes contain the literal envelope marker shown above (source attribute `ci-refused-synthetic`).

          After dispatch returns, the caller captures TWO fields from the agent's YAML return: `CI_REFUSED_ISSUE_URL` from `created_urls[0].url` (empty string if missing) AND `$rationale` from the top-level `rationale` field (empty string if missing).

          If the agent's return YAML contains `status: REFUSED`, the caller emits one explicit stderr line — parameterised on the agent's actual `rationale` so all four REFUSED classes (`input-malformed`, `rate-limit-probe-failed`, `rate-limit-budget-insufficient`, `secret-scan-lib-unavailable`) surface accurately — and proceeds to actions 2 + 3 with `CI_REFUSED_ISSUE_URL=""` (the halt prose still emits; the audit record still fires; the issue URL slot is just empty).

          The literal `warning:` text shape is the contract — the operator searches their run logs for the `warning: findings-to-issues dispatch REFUSED` prefix:

          ```
          warning: findings-to-issues dispatch REFUSED — rationale: $rationale; CI-REFUSED issue NOT filed (halt prose + audit will still emit)
          ```

       2. **Emit user-visible halt prose** (stderr, regardless of `TURBO` — mirrors the `billing_quota` / `platform_outage` 6c.6 HALT shape):

          ```
          /uberdev:review-pr — Phase 3 halt: ci-code-fixer REFUSED
            failure class:   $failure_class
            signal anchor:   $signal_anchor
            rationale:       $rationale (e.g. forbidden-pattern-no-verify)
            filed issue:     $CI_REFUSED_ISSUE_URL
            next step:       /uberdev:solve $CI_REFUSED_ISSUE_URL  (or fix manually)
          ```

       3. **Audit + exit** — emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=ci_fixer_refused_<rationale>` (lowercase, dashes-to-underscores normalised, e.g. `forbidden-pattern-no-verify` → `ci_fixer_refused_forbidden_pattern_no_verify`); record `CI_REFUSED_ISSUE_URL` in the audit JSON under `phases.phase3.ci_refused_issue_url`; exit 1.

       Under `TURBO=1`, the same three actions fire — the prose goes to stderr, the issue is still filed (no `AskUserQuestion` involved here; this is a deterministic halt, not a user-choice gate), and exit 1 surfaces to the orchestrator chain.
    - `ci-rebase-handler` `status: REBASED, new_head_sha: <40-hex>` → fall through to "Phase 1 re-entry" below (the agent already pushed; new HEAD is on remote).
    - `ci-rebase-handler` `status: CONFLICT, conflicted_files: [...]` → execute the **CONFLICT-RESOLVE arm** below BEFORE Phase 1 re-entry. Closes #80 — the arm was previously unwired in this command, defeating the autopilot for any `stale_base` PR with conflicts.
    - `ci-rebase-handler` `status: REFUSED, rationale: <reason>` (∈ {`pr-already-merged`, `head-moved-since-classify`, `lease-mismatch`}) → emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=ci_rebase_refused_<reason>` (lowercase, dashes-to-underscores normalised; e.g. `lease-mismatch` → `ci_rebase_refused_lease_mismatch`); exit 1.

    #### CONFLICT-RESOLVE arm (mirrors `merge-pipeline/SKILL.md` Phase 3.3.iii–iv)

    Trigger: `ci-rebase-handler` returned `status: CONFLICT, conflicted_files: [...]`. Per `agents/ci-rebase-handler.md` Step 6 the agent has already aborted the in-progress rebase, so the worktree is back to its pre-rebase state. The caller's main turn re-creates the conflict state in the current `/review-pr` checkout (`$REPO_ROOT`), fans out `conflict-resolver` per file in a SINGLE assistant turn, then continues the rebase under the original lease.

    **Variable bindings (caller binds before step 1).** The arm uses `$pr_head_branch`, `$base_branch`, and `$REPO_ROOT` in its bash recipes and routed child calls prompts. Bind them in the caller's main turn from the PR (mirrors `agents/ci-rebase-handler.md:19-21` Inputs). `$PR_NUMBER` was already bound at 6c.1 PROBE (line 195).

    ```bash
    # Single gh call returns both refs to avoid two API roundtrips (one core
    # bucket request, not two — matters under tight rate-limit budgets).
    read -r pr_head_branch base_branch <<< "$(gh pr view "$PR_NUMBER" --json headRefName,baseRefName --jq '"\(.headRefName) \(.baseRefName)"')"
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    ```

    1. **Re-create conflict state.** Re-fetch and re-rebase in the current `/review-pr` checkout (`$REPO_ROOT`) to surface conflict markers in `conflicted_files`:

       ```bash
       git fetch origin "$pr_head_branch" "$base_branch"
       # Captured BEFORE the second rebase — used as the resume-push lease so an
       # external push that lands during the resume window is detected. Mirrors
       # the EXPECTED_OLD_SHA capture in agents/ci-rebase-handler.md Step 4.
       EXPECTED_OLD_SHA="$(git rev-parse origin/$pr_head_branch)"
       BASE_SHA="$(git merge-base origin/$pr_head_branch origin/$base_branch)"
       git rebase "origin/$base_branch"   # exits non-zero with markers — that is expected
       ```

    2. **Resolve fanout cap.** Mirrors `merge-pipeline/SKILL.md` Phase 3.3.iii cap-resolve:

       ```bash
       if [ -r "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh" ]; then
         . "$UBERDEV_REVIEW_PLUGIN_ROOT/lib/config-read.sh"
         CONFLICT_RESOLVER_CAP="$(uberdev_read_int_in_range fanout_concurrency.conflict_resolver UBERDEV_FANOUT_CONFLICT_RESOLVER 1 50 10)"
       else
         CONFLICT_RESOLVER_CAP=10
       fi
       ```

       When `len(conflicted_files) > CONFLICT_RESOLVER_CAP`, split the per-file routed fanout into bounded waves; every slice dispatches fully before waiting.

    3. **Routed fanout per file (`subagent_type: uberdev:conflict-resolver`).** Build one unique instance per conflicted path and dispatch the entire cap slice before waiting:

       ```bash
       CONFLICT_RECORDS="$RESEARCH_DIR_ABS/conflicts.records"; CONFLICT_DESCRIPTORS="$RESEARCH_DIR_ABS/conflicts.descriptors"; CONFLICT_LAUNCHED="$RESEARCH_DIR_ABS/conflicts.launched"; : >"$CONFLICT_RECORDS"
       CONFLICT_INDEX=0
       for CONFLICT_PATH in "${conflicted_files[@]}"; do
         CONFLICT_INDEX=$((CONFLICT_INDEX + 1)); INSTANCE="$(uberdev_child_instance_id "review-pr-${RUN_ID}-conflict-${CONFLICT_INDEX}-iter${CI_FIX_LOOP_ITER:-01}-attempt01")"
         INPUTS_JSON="$(uberdev_child_inputs_build review_pr.ci.resolve_conflict \
           file_path "$(review_json_string "$CONFLICT_PATH")" \
           working_dir "$(review_json_string "$REPO_ROOT")" \
           pr_branch "$(review_json_string "$pr_head_branch")" \
           integration_branch "$(review_json_string "$base_branch")" \
           base_sha "$(review_json_string "$BASE_SHA")")"
         review_child_record review_pr.ci.resolve_conflict "$INSTANCE" "$INPUTS_JSON" null "$CONFLICT_RECORDS"
       done
       review_child_fanout "$CONFLICT_RECORDS" "$CONFLICT_DESCRIPTORS" "$CONFLICT_LAUNCHED" "$REVIEW_PR_TIMEOUT"
       review_child_wait_all "$CONFLICT_LAUNCHED" "$REVIEW_PR_TIMEOUT"
       ```

       Each routed child uses `agents/conflict-resolver.md` and returns `status: RESOLVED | AMBIGUOUS | REFUSED`.

    4. **Aggregate returns.** Three terminal cases:

       - **All `status: RESOLVED`:**

         ```bash
         git add "${conflicted_files[@]}"
         if ! git rebase --continue; then
           # `git rebase --continue` exited non-zero. Two sub-cases:
           #   (a) Multi-stage rebase: continuation surfaced a NEW conflict set.
           #       Re-bind `conflicted_files` from the live rebase state via
           #       `git status --porcelain | awk -v c2=2 '/^UU / {print $c2}'` and re-enter
           #       step 3 against the NEW list (NOT the agent's original list —
           #       conflict-resolver REFUSES paths outside its pre-computed set per
           #       `agents/conflict-resolver.md` Refusal triggers + Inputs). Bounded
           #       by CI_FIX_LOOP_CAP from 6c.7 LOOP GUARD — single-shot per dispatch,
           #       NOT a separate retry path (anti-pattern guard restated from
           #       merge-pipeline/SKILL.md "PARK is the terminal floor" prose).
           #   (b) Non-conflict failure (pre-commit hook rejection, GPG signing
           #       failure, etc): no UU entries → halt.
           # Use mapfile -t (NOT unquoted expansion) so paths with spaces survive.
           mapfile -t conflicted_files < <(git status --porcelain | awk -v c2=2 '/^UU / {print $c2}')
           if [ "${#conflicted_files[@]}" -gt 0 ]; then
             # Re-enter step 3 with the new list (single-shot per CI_FIX_LOOP_CAP).
             :
           else
             git rebase --abort
             audit ci_phase_outcome data.outcome=halted data.subreason=rebase_continue_failed
             exit 1
           fi
         fi
         NEW_HEAD_SHA="$(git rev-parse HEAD)"
         # Capture push stderr so the lease-mismatch branch is reachable.
         # An empty PUSH_STDERR with non-zero exit (extremely unlikely) is treated
         # as generic push-failure — strictly safer than mis-emitting a
         # rebase_lease_mismatch subreason on an unidentifiable failure.
         PUSH_STDERR="$(git push origin "$pr_head_branch" \
              --force-with-lease="$pr_head_branch":"$EXPECTED_OLD_SHA" \
              --force-if-includes 2>&1 1>/dev/null)" || PUSH_RC=$?
         if [ -n "${PUSH_RC:-}" ]; then
           # Distinguish lease-mismatch (race-with-external-push during the resume
           # window) from generic push failure (auth, pre-receive hook, rate-limit,
           # network). Lease-mismatch: server stderr matches `\[rejected\].*(stale
           # info|fetch first|non-fast-forward)` against the explicit-form lease.
           # Both halt; different data.subreason so audit consumers can route.
           git rebase --abort
           if printf '%s' "$PUSH_STDERR" | grep -qE '\[rejected\].*(stale info|fetch first|non-fast-forward)'; then
             audit ci_phase_outcome data.outcome=halted data.subreason=rebase_lease_mismatch
           else
             audit ci_phase_outcome data.outcome=halted data.subreason=rebase_push_failed
           fi
           exit 1
         fi
         ```

         - On push success: emit `ci_fix_pushed` with `data.commit_sha=$NEW_HEAD_SHA` and `data.by_agent="ci-rebase-handler+conflict-resolver"` (composite — rebase agent produced the conflict set, conflict-resolver fanout produced the resolutions). Treat as a fix push: increment `CI_FIX_LOOP_ITER`, fall through to "Phase 1 re-entry" below.
         - On push lease-mismatch (server rejects because origin/`$pr_head_branch` no longer matches `$EXPECTED_OLD_SHA`): the conditional above runs `git rebase --abort` and emits `ci_phase_outcome data.outcome=halted data.subreason=rebase_lease_mismatch`; exit 1. (External push during the resume window — the user re-issues `/review-pr` against the new HEAD.)
         - On push failure for any other reason (auth, pre-receive hook, rate-limit, network): `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_push_failed`; exit 1.
         - On `git rebase --continue` failure with no fresh conflict set (pre-commit hook reject / signing failure / etc): `git rebase --abort`; emit `ci_phase_outcome data.outcome=halted data.subreason=rebase_continue_failed`; exit 1.

       - **Any `status: AMBIGUOUS`:** `git rebase --abort`; emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=rebase_conflict_ambiguous`; exit 1. (Mirrors `merge-pipeline/SKILL.md` Phase 3.3.iv park-on-AMBIGUOUS, but for `/review-pr` the equivalent terminal action is run-halt — the trail records the unresolvable conflict; the user surfaces it via the Phase 3 halt prose. Per `agents/conflict-resolver.md` line 56, AMBIGUOUS carries `resolution_summary` + `risks[]` for handoff context.)

       - **Any `status: REFUSED`:** `git rebase --abort`; emit `ci_phase_outcome` with `data.outcome=halted` and `data.subreason=rebase_conflict_refused`; exit 1. (e.g. lockfile / secret-shaped / out-of-set request from conflict-resolver — full refusal trigger list at `agents/conflict-resolver.md` Refusal triggers.)

    5. **No additional retry path.** The arm is single-shot per `ci-rebase-handler` dispatch and bounded by `CI_FIX_LOOP_CAP` from 6c.7 LOOP GUARD. The "MUST NOT introduce any additional retry path" anti-pattern guard from `merge-pipeline/SKILL.md:523` (in "PARK is the terminal floor" prose) applies here.

    **Phase 1 re-entry** (after a fix push lands — covers `ci-code-fixer` `APPLIED`, `ci-rebase-handler` `REBASED`, AND `ci-rebase-handler` `CONFLICT → all RESOLVED → push-success`).

    After a fixer pushes a remediation commit, the new HEAD MUST re-enter the **per-push trust-trail flow** — i.e., Phase 1 (post-impl-review fanout) and Phase 2 (simplify fanout) re-run on the post-fix diff before Phase 3 re-probes. The trust-trail anchor commit is always the **absolute last** step. This guarantees the trailer's referenced SHA covers reviewed code only.

    Implementation: rather than a re-entrant skill call, the orchestrator decrements the loop counter and re-enters at Step 4 (Phase 1 dispatch). Step 1 argument parsing has already run, so `RUN_ID` is preserved. The `phases.phase1` and `phases.phase2` fields in audit JSON are **rewritten** on each iteration (not appended to) — only `phases.phase3.iterations` and `phases.phase3.fix_pushes` accumulate.

    Audit `ci_fix_pushed` (with `data.commit_sha` full 40-hex) when fixer push lands. On Phase 1 re-entry returning APPROVE → loop to 6c.1 (counts toward `CI_FIX_LOOP_CAP`). On Phase 1 re-entry rejecting → exit 1 with `OUTCOME=halted` (carry differentiation in audit `data.subreason=post_fix_review_rejected`).

    ### 6c.6 HALT — turbo-aware (billing_quota / platform_outage)

    Two failure classes (`billing_quota`, `platform_outage`) require human action no agent can take. The remediation prose surfaces a third human-readable cause — secret rotation — to the operator as guidance text only; classifier-side, secret/auth-token failures map to `billing_quota` (quota / token-store) or `platform_outage` (identity-provider transient) within the 6-class enum. Behaviour branches on `--turbo`:

    **Interactive (`--turbo` absent):**

    ```
    ToolSearch({ query: "select:AskUserQuestion" })  // mandatory deferred-tool load
    AskUserQuestion({
      question: "CI failure class <X> cannot be resolved by code change. Required action: <remediation — may include 'rotate stale secret/auth token' as human-readable guidance>. After fixing, re-run /review-pr. Proceed?",
      options: [
        {label: "Stop", description: "Exit /review-pr with code 1; no trust signal."},
        {label: "Skip Phase 3", description: "Continue to Step 7 with OUTCOME=halted; no trust signal emitted."}
      ]
    })
    ```

    If `ToolSearch` fails, `/review-pr` aborts with stderr error — **NEVER silently auto-pick** (mirrors `orchestrator/SKILL.md:190-193`). Either user choice ultimately ends in `OUTCOME=halted`, exit 1.

    **Turbo (`--turbo` present):**

    ```
    log "warning: Phase 3 halt class <X> in --turbo mode; cannot prompt; emitting halt audit + exit 1" >&2
    audit ci_phase_outcome data.outcome=halted data.class=<X>
    OUTCOME=halted; exit 1
    ```

    ### 6c.7 LOOP GUARD

    Counter `CI_FIX_LOOP_ITER` starts at `0` at Phase 3 entry. Each fix-and-push increments. Cap = `CI_FIX_LOOP_CAP` (declared in `merge-pipeline/SKILL.md` Constants — value `3`).

    - Iteration < 3, terminal outcome → emit `ci_phase_outcome` audit (with `data.outcome ∈ CI_OUTCOME_ENUM`), return to Step 7.
    - Iteration == 3, still red → audit `ci_loop_cap_reached`; `OUTCOME=loop_cap_exhausted`; exit 1; no anchor commit.
    - **MUST NOT introduce any additional retry path** (anti-pattern guard restated from `merge-pipeline/SKILL.md` "PARK is the terminal floor" prose).

    Each iteration increments only on a **distinct commit SHA change** (HEAD SHA changed since this iteration's start). Re-runs of the same SHA on `flaky` paths use `RERUN_FLAKY_CAP=1` per distinct check — they do NOT increment `CI_FIX_LOOP_ITER`.

    ### Phase 3 audit JSON shape

    Today's audit JSON (`.uberdev/runs/<run-id>/review-pr-verdict.json`) gains a `phases.phase3` block:

    ```json
    "phase3": {
      "status": "ran" | "skipped_no_checks" | "unreachable",
      "outcome": "green" | "green_after_fix" | "skipped_no_checks" | "halted" | "loop_cap_exhausted",
      "iterations": <int>,
      "failure_classes_seen": ["code_bug", "..."],
      "fix_pushes": [{"sha": "<40-hex>", "by_agent": "ci-code-fixer" | "ci-rebase-handler"}]
    }
    ```

    Note: `--no-ci-fix` mode (Step 1, `CI_FIX_PHASE=0`) keeps PROBE/MONITOR/CLASSIFY running for audit telemetry, so `phase3.status` resolves via the same PROBE-driven assignment (`ran` if probe ran end-to-end, `skipped_no_checks` if probe reported no checks, `unreachable` if `gh` failed). There is no `skipped_no_ci_fix` member because no path produces it — `--no-ci-fix` only skips ROUTE/POST-FIX/HALT and forces OUTCOME to `green`/`halted`, but the status field still records what PROBE saw.

    The `phases.phase3` block is **omitted entirely** when `gh` is unreachable (carve-out); a `ci_probe_unreachable` audit line is emitted to the JSONL audit log instead, and Step 7 trust-signal emission proceeds as if Phase 3 returned `skipped_no_checks`. Security trade-off: outage in `gh` MUST NOT block release; the trail still records the unreachability for `/merge`'s consumer to read out-of-band.

7. **Final Aggregation — distinguish review-phase vs simplify-phase findings**

   After Phase 1 fixes land and (if enabled) Phase 2 simplify edits land, summarize both phases in a single table that **distinguishes review-phase findings from simplify-phase findings**:

   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

8. **Provide Action Plan**

   Organize findings, with the review-phase vs simplify-phase distinction preserved in every row:

   ```markdown
   # PR Review Summary

   ## Phase outcomes
   | Phase | Status | Verdict | Auto-applied | Advisory findings |
   |---|---|---|---|---|
   | Phase 1 — Review + Fix | ran | APPROVE / REVISIONS_REQUIRED / REJECT | <commit shas> | <count> |
   | Phase 2 — Simplify     | ran / blocked / skipped | APPROVE / REVISIONS_REQUIRED / REJECT (omit if status≠ran) | <commit sha or ∅> | <count> |
   | Issues filed (Phase 2.5) | Rendered from the agent's return YAML, broken down by tier per RFC 0002 §3.4: `BLOCKER: <n>` / `CRITICAL: <n>` / `MAJOR: <n>` (each line omitted when count is 0). Sum line: `<total> created + <total> commented` followed by the trust-trail state implication — `(halt: trust trail RED)` when `halted=true`, `(critical-deferred: trust trail YELLOW)` when only `by_severity.critical > 0`, `(silent file: trust trail GREEN)` otherwise. `overflow_count` additional findings exceeded `MAX_NEW=10` cap; suffix `(BROKEN-FEATURE HALT)` when `halted_due_to_overflow=true`. `len(blocked_by_dedupe)` blocked by dedupe-lookup failure or fail-CLOSED branch. Full URL list with `(tier)` annotation in the "Issues filed (links)" block below. Skip path: `(skipped: --no-defer-issues)` when `DEFER_ISSUES_PHASE=0`, OR `(skipped: defer_issues_enabled=false)` when the config disables, OR both joined by " and " when both knobs are off. |

   **Issues filed (links):**

   Rendered from `created_urls[]` + `commented_urls[]` of the findings-to-issues agent return. Each line: `- [` + `file:line` + `](`URL`)` — e.g., `- [src/auth.ts:42](https://github.com/owner/repo/issues/123)`.

   `Verdict` reuses the canonical `uberdev:post-impl-review` reviewer enum (APPROVE | REVISIONS_REQUIRED | REJECT). `Status` is orthogonal: `ran` (the fanout completed), `blocked` (fanout failure — see "Non-blocking" above), `skipped` (`--no-simplify` was set).

   ## Critical Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Important Issues (X found)
   - [phase: review | simplify] [agent-name]: Issue description [file:line]

   ## Suggestions (X found)
   - [phase: review | simplify] [agent-name]: Suggestion [file:line]

   ## Strengths
   - What's well-done in this PR

   ## Recommended Action
   1. Fix critical issues first
   2. Address important issues
   3. Consider suggestions
   4. Re-run review after fixes
   ```

## Trust-Signal Emission (RFC 0002 — tiered GREEN / YELLOW / RED)

After the final aggregation table renders, evaluate the trust-trail predicate. RFC 0002 promotes the prior binary GREEN/non-GREEN model to a three-state model:

```
GREEN  := (Phase 1 verdict == "APPROVE")
        AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
        AND (Phase 2.5 by_severity.blocker == 0)                    [RFC 0002 §3.4]
        AND (Phase 2.5 by_severity.critical == 0)                   [RFC 0002 §3.4 — disambiguates against YELLOW]
        AND (Phase 2.5 halted == false)                             [RFC 0002 §3.4]
        AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})

YELLOW := (Phase 1 verdict == "APPROVE")
        AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
        AND (Phase 2.5 by_severity.blocker == 0)                    [no blocker; non-zero critical is the YELLOW signal]
        AND (Phase 2.5 halted == false)
        AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})
        AND (Phase 2.5 by_severity.critical > 0)                    [RFC 0002 §3.4 — required for YELLOW]

RED    := NOT GREEN AND NOT YELLOW

OVERRIDE_GREEN := PHASE2_5_HALT_CHOICE == "override"                [RFC 0002 §3.5 — interactive opt-in only]
                AND would_have_been_RED_due_to_phase2_5_only

# Concrete definition of `would_have_been_RED_due_to_phase2_5_only`:
#   (Phase 1 verdict == "APPROVE")
#   AND (Phase 2 status ∈ {"ran/APPROVE", "skipped"})
#   AND (Phase 3 outcome ∈ {"green", "green_after_fix", "skipped_no_checks"})
#   AND (Phase 2.5 halted == true OR Phase 2.5 by_severity.blocker > 0)
#
# Rationale: the override flag is allowed to suppress RED ONLY when phase2_5 is
# the SOLE cause — never when Phase 1/2/3 also fail. This is the
# "/merge will require --i-know-what-im-doing" trail.
```

The GREEN and YELLOW predicates are now syntactically mutually exclusive (GREEN explicitly requires `critical == 0`; YELLOW explicitly requires `critical > 0`). A run cannot satisfy both. The `case "$TRUST_TRAIL_STATE"` block in the State Assignment step above (artifact 1) deterministically picks one based on the cardinality of `BY_SEVERITY_CRITICAL`.

The Phase 2.5 conjuncts (`by_severity.blocker == 0` AND `halted == false`) are **predicate-level breaking** (CHANGELOG `### Changed` callout in v0.26.0). A previously-green `/review-pr` run that filed blocker issues via `findings-to-issues` (PR #112) now correctly gates the trust-trail anchor RED. The Phase 3 conjunct preserves the v0.21.0 break (red CI gates GREEN). The audit JSON gains `phases.phase2_5` (additive; legacy audit JSON without this block is treated as STALE by `trust-trail-evaluator` per RFC 0002 §3.6.4).

**Three-way branch on the predicate**:

- **GREEN (or OVERRIDE_GREEN)** → emit the GREEN artifact triplet (anchor commit with trailer + `uberdev-approved` label + audit JSON `verdict: "APPROVE"`). When OVERRIDE_GREEN was the cause, the audit JSON records `phases.phase2_5.override_reason="user-selected-emit-green-on-blocker-deferred"` so `/merge`'s trust-trail-evaluator can see the override and require `--i-know-what-im-doing` to proceed.

- **YELLOW** → emit the YELLOW artifact triplet (anchor commit with `severity=critical-deferred count=N` suffix on the trailer + `uberdev-approved-with-concerns` label + audit JSON `verdict: "APPROVE"` with `phases.phase2_5.by_severity.critical > 0`). `/merge` requires `--accept-critical-deferred` to proceed past a YELLOW trail.

- **RED** → emit no anchor commit, no label add, no `Reviewed-by:` trailer. Remove `uberdev-approved` and `uberdev-approved-with-concerns` labels from the PR if previously set (idempotent — `gh pr edit --remove-label` no-ops on absent labels). Write the audit JSON with `verdict` set to the failing verdict (Phase 1's verdict OR `"BLOCKED"` when Phase 2.5 is the cause); the JSON is still written so `/merge`'s trust-trail-evaluator has a fresh `phases.phase2_5` block to read. Exit 1.

The remainder of this section describes the GREEN/YELLOW emission shape (RED skips the entire artifact triplet — see exit-code contract):

1. **Trust-trail-anchor commit** — emit ONE empty commit at HEAD whose body carries the trailer pointing at its parent. The parent SHA — captured **before** the anchor commit — is the load-bearing trust artifact for `/merge` Phase 1.4 trust resolution (see `skills/merge-pipeline/SKILL.md` Constants `REVIEW_PR_TRAILER_PREFIX`):

   **State assignment (RFC 0002 §3.4 — must run BEFORE the three case statements below).** Compute `TRUST_TRAIL_STATE` from the predicate; the three downstream case statements in artifacts 1 and 2 read this single source-of-truth variable:

   ```bash
   # Final anti-race gate: the reviewed snapshot must still be both local HEAD
   # and the selected PR's live head before any anchor, label, or audit trust
   # artifact is emitted.
   review_assert_selected_pr_head "$REVIEW_REPO_SLUG" "$PR_NUMBER" \
     "$REVIEWED_HEAD_SHA" "$WORKTREE_ROOT" || {
       echo "error: PR head changed after review; suppressing trust emission" >&2
       OUTCOME=halted
       exit 2
     }

   # Evaluate the GREEN predicate first; YELLOW is a strict sub-case
   # ("all GREEN preconditions met AND critical>0"); RED is everything else.
   # OVERRIDE_GREEN flips RED→GREEN when PHASE2_5_HALT_CHOICE == "override"
   # AND phase2_5 was the SOLE cause of the otherwise-GREEN-preconditions failing.
   would_be_green_without_phase2_5=false
   if [ "$PHASE1_VERDICT" = "APPROVE" ] \
      && { [ "$PHASE2_STATUS" = "ran/APPROVE" ] || [ "$PHASE2_STATUS" = "skipped" ]; } \
      && { [ "$PHASE3_OUTCOME" = "green" ] || [ "$PHASE3_OUTCOME" = "green_after_fix" ] || [ "$PHASE3_OUTCOME" = "skipped_no_checks" ]; }; then
     would_be_green_without_phase2_5=true
   fi

   if   $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALTED:-false}" = "false" ] \
        && [ "${BY_SEVERITY_BLOCKER:-0}" = "0" ] \
        && [ "${BY_SEVERITY_CRITICAL:-0}" = "0" ]; then
     TRUST_TRAIL_STATE=GREEN
   elif $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALTED:-false}" = "false" ] \
        && [ "${BY_SEVERITY_BLOCKER:-0}" = "0" ] \
        && [ "${BY_SEVERITY_CRITICAL:-0}" -gt 0 ]; then
     TRUST_TRAIL_STATE=YELLOW
   elif $would_be_green_without_phase2_5 \
        && [ "${PHASE2_5_HALT_CHOICE:-}" = "override" ]; then
     # OVERRIDE_GREEN: operator selected emit-GREEN-on-blocker-deferred AND
     # phase2_5 was the sole cause of RED (all other phases satisfy GREEN).
     # `/merge` requires --i-know-what-im-doing to land this trail.
     TRUST_TRAIL_STATE=GREEN
     OVERRIDE_REASON="user-selected-emit-green-on-blocker-deferred"
   else
     TRUST_TRAIL_STATE=RED
   fi
   ```

   Audit-trail invariant: `OVERRIDE_REASON` is set ONLY by the OVERRIDE_GREEN branch above; all other branches leave it as `null` (the audit JSON `phases.phase2_5.override_reason` field defaults to `null`). This makes the override discoverable downstream by `/merge`'s `trust-trail-evaluator` per RFC 0002 §3.6.

   **Trailer suffix selection (RFC 0002 §3.4):**

   ```bash
   case "$TRUST_TRAIL_STATE" in
     GREEN)
       TRAILER_SUFFIX=""
       ;;
     YELLOW)
       TRAILER_SUFFIX=" severity=critical-deferred count=${BY_SEVERITY_CRITICAL}"
       ;;
     # RED skips this entire emission section — handled by the predicate branch above
   esac
   ```

   ```bash
   PARENT_SHA="$(git rev-parse HEAD)"   # full 40-char SHA — NOT --short; goes into the trailer payload
   git commit --allow-empty -m "chore(review-pr): trust trail anchor for #<PR>

   Reviewed-by: uberdev/review-pr@${PARENT_SHA}${TRAILER_SUFFIX}"
   if ! git push origin HEAD; then
     # Push failed (network, auth, rate limit, hook rejection, non-fast-forward, …).
     # Without this guard, ANCHOR_SHA below would capture a local-only HEAD; the audit
     # JSON would then be written with a SHA that does not exist on the remote, and
     # `/merge` Phase 1.4 would later fail with a cryptic `trust_trail_agent_invalid_input`
     # (subreason `trailer_sha_not_in_local_clone`). Per artifact-emission-failure prose
     # below, exit 2 — treat as `blocked`-equivalent so the trust-signal contract is
     # never silently broken. Re-run /review-pr after resolving the push failure.
     echo "error: trust-trail anchor push failed (git push origin HEAD exited non-zero). Re-run /review-pr after resolving." >&2
     exit 2
   fi
   ANCHOR_SHA="$(git rev-parse HEAD)"   # full 40-char SHA — captured AFTER the push (push-success guarded above); equals post-emission `headRefOid` (i.e., the anchor commit's own SHA, NOT the trailer's PARENT_SHA payload). Used in artifact 3's audit JSON `"sha"` field.
   ```

   Why an empty anchor commit (and not a per-simplify-commit trailer or `git commit --amend`):
   - **Empty diff by construction** (`--allow-empty`). `trust-trail-evaluator` PASSes via the empty-cumulative-diff path: `git merge-base --is-ancestor <PARENT_SHA> HEAD` → YES, `git diff <PARENT_SHA> HEAD` → empty → `PASS`. Independent of how many Phase 1 / Phase 2 commits landed.
   - **Always a fresh new commit on top.** `git commit --amend` is **NEVER** used, so push **never** requires `--force-with-lease`. Works identically whether Phase 1 / Phase 2 already pushed mid-run or batched their pushes.
   - **Self-pinning trailer.** The trailer references the anchor's parent — the actual end-of-run HEAD before the anchor — so the SHA is captured *deterministically* at the only moment it can be written without chicken-and-egg. No reliance on amend-recompute or sibling-equivalence heuristics on the agent side.

   The anchor commit goes through pre-commit hooks normally — never `--no-verify`. Author = current `git config user.email` / `user.name`; the trailer is procedural attribution to the `/review-pr` command. Per global CLAUDE.md, the anchor commit MUST NOT include a `Co-Authored-By: Claude` trailer or any `🤖 Generated with Claude Code` footer. The trailer payload (`Reviewed-by: uberdev/review-pr@<40-hex>`) is the only trailer in the body. Verify with `git log -1 --format=%B | grep -E '^Reviewed-by: uberdev/review-pr@[a-f0-9]{40}$'` before proceeding to artifact 2.

2. **Label** — tier-aware. GREEN runs add `uberdev-approved` (canonical literal — see `skills/merge-pipeline/SKILL.md` Constants `UBERDEV_APPROVED_LABEL`). YELLOW runs add `uberdev-approved-with-concerns` (RFC 0002 §3.4). Each label is **provisioned fail-loud via `gh label create --force` immediately before the add** (issue #170 — `gh pr edit --add-label` CANNOT auto-create a repo label and exits non-zero when the label is missing, which on a fresh repo aborts the whole trust-signal emission; same assume-label-exists class as #168). `--force` is idempotent: it updates an existing label's colour/description and never errors on "already exists", so a non-zero `gh label create` exit is always a genuine failure (auth / repo write-or-triage scope / API). Adding the label to the PR is itself idempotent — `gh` no-ops if the label is already on the PR.

   ```bash
   case "$TRUST_TRAIL_STATE" in
     GREEN)  TRUST_LABEL="uberdev-approved"
             TRUST_LABEL_COLOR="0E8A16"
             TRUST_LABEL_DESC="Trust trail: /uberdev:review-pr verified GREEN. Auto-managed — set by /review-pr, read by /merge." ;;
     YELLOW) TRUST_LABEL="uberdev-approved-with-concerns"
             TRUST_LABEL_COLOR="FBCA04"
             TRUST_LABEL_DESC="Trust trail: /review-pr YELLOW: deferred CRITICAL; /merge needs --accept-critical-deferred." ;;
   esac
   # Belt-and-braces: clear the OPPOSITE-tier label if present, so a re-run that
   # downgrades GREEN→YELLOW (or upgrades YELLOW→GREEN) doesn't leave a stale
   # contradictory label on the PR. Failures here are fail-soft (the new label
   # add below is the authoritative artifact).
   case "$TRUST_TRAIL_STATE" in
     GREEN)  gh pr edit <N> --remove-label uberdev-approved-with-concerns 2>/dev/null || true ;;
     YELLOW) gh pr edit <N> --remove-label uberdev-approved 2>/dev/null || true ;;
   esac
   ```

   ```bash
   # Provision the trust label BEFORE adding it (#170). `gh pr edit --add-label`
   # CANNOT auto-create a repo label and exits non-zero when it is missing — on a
   # fresh repo (or any repo where the trust labels were never created) this
   # aborts the whole trust-signal emission. `--force` makes this idempotent (it
   # updates an existing label's colour/description, never errors on "already
   # exists"), so a non-zero exit here is a genuine failure (auth / missing repo
   # write-or-triage scope / API error). Fail-loud + exit 2 mirrors the --add-label
   # guard below: the label is the load-bearing trust artifact /merge reads, so
   # emission cannot proceed without it. (Same assume-label-exists class as #168,
   # but fail-loud rather than swallowed.)
   if ! gh label create --force "$TRUST_LABEL" --color "$TRUST_LABEL_COLOR" --description "$TRUST_LABEL_DESC"; then
     echo "error: failed to provision the '$TRUST_LABEL' trust label (gh pr edit --add-label cannot auto-create it). Check gh auth and repo write/triage permission." >&2
     exit 2
   fi
   # Mirror artifact 1's push-failure guard: if `gh pr edit` exits non-zero
   # (network, auth, rate limit, label-permission denial), bash continues silently
   # and the audit JSON below gets written without the label being applied.
   # `/merge` Phase 1.4 PATH_2 sub-condition (a) then fails downstream with a cryptic
   # `trust_trail_label_missing`. Per artifact-emission-failure prose below, exit 2.
   if ! gh pr edit <N> --add-label "$TRUST_LABEL"; then
     echo "error: trust-trail label add failed (gh pr edit ... exited non-zero). Re-run /review-pr after resolving." >&2
     exit 2
   fi
   ```

   ```bash
   # Note: kept as a SEPARATE gh pr edit call (not combined with the
   # --add-label uberdev-approved call above) so that the differential
   # error contract is preserved: --add-label is exit-2-on-failure
   # (trust-signal artifact), while --remove-label is fail-soft per D4.
   # New (#95): clear the review-pr:pending backstop label on green outcome.
   # Fail-soft per spec D4 — /uberdev:review-pr may be invoked directly outside
   # a finish-branch chain, so the label may legitimately be absent; an exit-2
   # guard would falsely fail green direct-invocation runs.
   if ! gh pr edit <N> --remove-label review-pr:pending 2>/dev/null; then
     echo "note: review-pr:pending label not present (either never set or already cleared)" >&2
   fi
   ```

   **Pending-label clearance** — the `gh pr edit <N> --remove-label review-pr:pending` call pairs with the `--add-label uberdev-approved` above; together they form the green-outcome trust-signal handoff. See `REVIEW_PR_PENDING_LABEL` in `skills/merge-pipeline/SKILL.md` Constants. The label is set by `finish-branch/SKILL.md` immediately before this Skill is dispatched (issue #95). It is intentionally preserved on REVISIONS_REQUIRED, agent crash, or non-green exit so `/merge` Step 1.4.5's label-present probe can backstop the missed review on the next integration run.

3. **Audit JSON** — write to `.uberdev/runs/<run-id>/review-pr-verdict.json`. The `"sha"` field MUST be `${ANCHOR_SHA}` from artifact 1 (the post-emission `headRefOid`, equal to the anchor commit's own SHA). It is NOT `${PARENT_SHA}` — the trailer payload references the pre-anchor parent, but the JSON `"sha"` references the anchor itself, matching what `gh pr view --json headRefOid` returns immediately after the push:

```json
{
  "pr": <int>,
  "sha": "${ANCHOR_SHA}",
  "verdict": "APPROVE" | "REVISIONS_REQUIRED" | "REJECT" | "BLOCKED",
  "trust_trail_state": "GREEN" | "YELLOW" | "RED",
  "phases": {
    "phase1": {"status": "ran", "verdict": "APPROVE"},
    "phase2": {"status": "ran/APPROVE" | "skipped", "verdict": "APPROVE" | null},
    "phase2_5": {
      "status": "ran" | "skipped" | "blocked",
      "issues_filed": <int>,
      "by_severity": {
        "blocker":  <int>,
        "critical": <int>,
        "major":    <int>
      },
      "overflow_count": <int>,
      "halted_due_to_overflow": <bool>,
      "halted": <bool>,
      "filed_issue_urls": ["https://github.com/<owner>/<repo>/issues/<N>", ...],
      "override_reason": null | "user-selected-emit-green-on-blocker-deferred"
    },
    "phase3": {
      "status": "ran" | "skipped_no_checks" | "unreachable",
      "outcome": "green" | "green_after_fix" | "skipped_no_checks" | "halted" | "loop_cap_exhausted",
      "iterations": <int>,
      "failure_classes_seen": [],
      "fix_pushes": [],
      "ci_refused_issue_url": null | "https://github.com/.../issues/<N>"
    }
  },
  "timestamp": "<ISO8601>"
}
```

**`phases.phase2_5` block (RFC 0002 §3.4)** — present on every run where the Phase 2.5 sub-phase was reachable (i.e., Phase 1 + Phase 2 didn't crash before Step 6b). `status: "skipped"` when `DEFER_ISSUES_EFFECTIVE=0` (CLI flag or config disabled the sub-phase); `status: "blocked"` when the agent return YAML failed to parse; `status: "ran"` otherwise. The `halted`, `by_severity`, and `override_reason` fields are the load-bearing inputs for `/merge`'s `trust-trail-evaluator` per RFC 0002 §3.6. Legacy audit JSON (pre-v0.26.0) without this block → trust-trail-evaluator emits STALE, prompting `/review-pr` re-run.

**`trust_trail_state` field (RFC 0002 §3.4)** — top-level GREEN/YELLOW/RED discriminator, redundant with the `phases.*` blocks but exposed at the JSON root for faster downstream gating (`/merge` can branch on a single string instead of recomputing the predicate from each phase block).

**`phases.phase3.ci_refused_issue_url` (RFC 0002 §3.2)** — populated when Phase 3 halted on `ci-code-fixer` `status: REFUSED` and the failing test was filed as a CRITICAL-tier issue. `null` on all other Phase 3 outcomes.

The JSON is **local debug telemetry only** — `.uberdev/` is gitignored, so the JSON does NOT cross-clone. `/merge` consumes the trailer as the load-bearing trust artifact and treats the JSON as a corroborating presence check. See `skills/merge-pipeline/SKILL.md` Phase 1.4 Path 2 for the consumer side.

On any artifact-emission failure (anchor commit fails — pre-commit hook rejection, push rejection, network failure; label add fails; JSON write fails): exit 2 (treat as `blocked`-equivalent because the trust-signal contract is broken). Print the failing `git` / `gh` / filesystem stderr; suggest re-running `/review-pr`.

### Run-ID format

`<run-id>` MUST be derived as:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
```

This mirrors the convention in `skills/merge-pipeline/SKILL.md:209` (Phase 3.3ii scratch worktree path). Before any path concatenation, validate `<run-id>` against the regex:

```
^[0-9]{8}-[0-9]{6}-[a-f0-9]+$
```

See `skills/merge-pipeline/SKILL.md` Constants `RUN_ID_REGEX`. If the regex match fails (defensive — should never trigger with internally-generated values), exit 2 and print: `BUG: run-id <value> does not match ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ — file an issue`. The regex constraint forecloses path-traversal if a future iteration ever sources `<run-id>` from external input.

## Exit-Code Contract

| Exit code | Condition |
|-----------|-----------|
| `0` | GREEN OR YELLOW OR OVERRIDE_GREEN — Phase 1 verdict == `APPROVE` AND Phase 2 status ∈ {`ran/APPROVE`, `skipped`} AND Phase 3 outcome ∈ {`green`, `green_after_fix`, `skipped_no_checks`} AND (Phase 2.5 halted == false OR Phase 2.5 halt was overridden) |
| `1` | Phase 1 verdict ∈ {`REJECT`, `REVISIONS_REQUIRED`} (regardless of Phase 2) OR **Phase 3 outcome ∈ {`halted`, `loop_cap_exhausted`}** OR **Phase 2.5 halted == true AND PHASE2_5_HALT_CHOICE ∈ {solve_suggestion, skip}** (RFC 0002 §3.4 — `override` takes the OVERRIDE_GREEN path and exits 0) |
| `2` | Phase 2 status == `blocked` (fanout crash, agent error, aggregator failure, artifact-emission failure) OR Phase 2.5 status == `blocked` (agent return YAML parse failure) OR Step 6a post-fixer push failure (blocked-equivalent — Phase 3 would probe a stale remote SHA) |

Exit code `2` is a **behavioral break** from the previous always-exit-0 contract. Callers that scripted `/review-pr` against the old "always exits successfully" prose must either ignore the exit code (preserve old behavior) or branch on it (use new behavior). The new contract surfaces silent reviewer-crash failures that the trust signal exists to eliminate. Documented in CHANGELOG.

The exit code is rooted in Phase 2 *status*, not Phase 2 *verdict* — a `ran/APPROVE` exit-0 may still contain advisory `REVISIONS_REQUIRED` simplify findings surfaced in the aggregation table (step 7).

Phase 3 reuses exit `1` (no new exit code introduced — Q2 decision). The audit JSON `phases.phase3.outcome` field disambiguates Phase 3 halt from Phase 1 reject.

## Usage Examples:

**Full review (default):**
```
/uberdev:review-pr
```

**Specific aspects:**
```
/uberdev:review-pr tests errors
# Reviews only test coverage and error handling

/uberdev:review-pr comments
# Reviews only code comments

/uberdev:review-pr simplify
# Simplifies code after passing review
```

**Sequential override** (default is parallel):
```
/uberdev:review-pr all sequential
# Force one-at-a-time dispatch — use only for interactive walkthroughs
```

**Skip Phase 2 simplify pass** (legacy single-pass behavior):
```
/uberdev:review-pr --no-simplify
# Run only Phase 1 review-and-fix; skip the mandatory simplify fanout.
# Use when only correctness review is wanted (e.g. pre-merge gate after a
# /simplify pass already ran). Combinable with aspect args:
/uberdev:review-pr tests errors --no-simplify
```

**Skip Phase 3 CI fix loop** (probe-only mode):
```
/uberdev:review-pr --no-ci-fix
# Run Phase 1 + Phase 2 + Phase 3 PROBE/MONITOR/CLASSIFY (audit-only).
# Use for fast iterative review loops where you don't want fix attempts.
# Combinable with aspect args:
/uberdev:review-pr tests errors --no-ci-fix
```

**Skip Phase 2.5 findings-to-issues sub-phase** (suppress deferred-critical issue filing):
- `/uberdev:review-pr --no-defer-issues` — runs the full review chain (Phase 1 + Phase 2 + Phase 3) but skips the Phase 2.5 findings-to-issues sub-phase. Final summary table shows `(skipped: --no-defer-issues)`.
- `/uberdev:review-pr tests errors --no-defer-issues` — same as above with additional review aspects.

## Agent Descriptions:

### Phase 1 reviewers (6 — fanned out by `Skill(uberdev:post-impl-review)`)

**uberdev:comment-analyzer**:
- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**uberdev:pr-test-analyzer**:
- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**uberdev:silent-failure-hunter**:
- Finds silent failures
- Reviews catch blocks
- Checks error logging

**uberdev:type-design-analyzer**:
- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**uberdev:code-reviewer**:
- Checks CLAUDE.md compliance
- Detects bugs and issues
- Reviews general code quality

**uberdev:code-reviewer (general lens)**:
- 6th fanout slot — re-dispatched against the same agent file with a "general code-quality" framing in the brief (see `skills/post-impl-review/SKILL.md` Step 2 dispatch table)

### Phase 2 lens dispatcher (3 lens-parameterised routed child calls calls)

**uberdev:code-simplifier** (named lens — `subagent_type: uberdev:code-simplifier`):
- Simplifies complex code (Reuse / Quality / Efficiency lens via `## Lens emphasis:`)
- Improves clarity and readability
- Applies project standards
- Preserves functionality (audit-only persona — does not modify files)

### Apply-loop fixer (Phase 1 + Phase 2)

**uberdev:code-fixer** (`subagent_type: uberdev:code-fixer`):
- Reads the post-impl-review aggregate or simplify aggregate — each file carries its own envelope as leading/trailing file bytes (`<external-untrusted-input source="post-impl-review-aggregate">` for Phase 1, `source="simplify-aggregate"` for Phase 2); the dispatch passes the path or the enveloped bytes verbatim, never re-wrapped
- Applies minimal-scope edits + creates `fix:`/`refactor:` conventional commits
- Phase 1 commit type: `fix:` (default) or `refactor:` if all findings are non-behavioral
- Phase 2 commit type: `refactor:` (R8.6 invariant — no override; one commit per run)
- Returns commit SHAs and per-finding disposition table; advisory findings surface in the final aggregation table

### Phase 3 agents (CI Health — dispatched per-class from Step 6c.4 ROUTE)

**uberdev:ci-failure-classifier** (`subagent_type: uberdev:ci-failure-classifier`):
- Classifies one failed GitHub Actions check log into one of six classes (`CI_FAILURE_CLASS_ENUM`)
- Reads log under `<external-untrusted-input>` envelope; never quotes lines verbatim
- Returns YAML with `failure_class` + `signal_anchor` (file:line pointer)

**uberdev:ci-code-fixer** (`subagent_type: uberdev:ci-code-fixer`):
- Applies root-cause fix for `code_bug` or `env_drift` classes
- Refuses on forbidden patterns (`--no-verify`, test-skip, error-swallow, secret-mask, new-file-creation, multi-lockfile-churn)
- Commits as `fix(ci):` (code_bug) or `chore(deps):` (env_drift); never pushes (caller handles)

**uberdev:ci-rebase-handler** (`subagent_type: uberdev:ci-rebase-handler`):
- Rebases the PR branch onto its base for `stale_base` class
- Uses `--force-with-lease=<branch>:<sha> --force-if-includes` (sanctioned exception to `merge-pipeline/SKILL.md`'s never-`--force-with-lease`-against-PR-head invariant)
- Worktree-scoped lock prevents parallel-run lease races
- Returns `CONFLICT` for caller to fan out `conflict-resolver` agents (single message)

## Tips:

- **Run early**: Before creating PR, not after
- **Focus on changes**: Agents analyze git diff by default
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use specific reviews**: Target specific aspects when you know the concern

## Workflow Integration:

**Before committing:**
```
1. Write code
2. Run: /uberdev:review-pr code errors
3. Fix any critical issues
4. Commit
```

**Before creating PR:**
```
1. Stage all changes
2. Run: /uberdev:review-pr all
3. Address all critical and important issues
4. Run specific reviews again to verify
5. Create PR
```

**After PR feedback:**
```
1. Make requested changes
2. Run targeted reviews based on feedback
3. Verify issues are resolved
4. Push updates
```

## Notes:

- Agents run autonomously and return detailed reports
- Each agent focuses on its specialty for deep analysis
- Results are actionable with specific file:line references
- Agents use appropriate models for their complexity
- All agents available in `/agents` list

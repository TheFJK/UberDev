#!/usr/bin/env bash
# tests/dispatch-child-worktree-teardown.test.sh
#
# Issue #381 / RULING 4 — the isolated-worktree teardown must survive the codex
# backend's removal.
#
# Before this fixture, `_uberdev_dispatch_cleanup_codex_worktree` was the ONLY
# teardown in the tree and it was reachable exclusively from
# `_uberdev_dispatch_codex`. Both surviving detached backends
# (`_uberdev_dispatch_background`, `_uberdev_dispatch_wezterm`) create a
# dispatcher-owned worktree unconditionally and never removed it, so an
# isolated CHILD_OWNED=1 dispatch on either backend leaked a worktree AND its
# branch permanently.
#
# What this fixture proves — by OBSERVING git state in a scratch repository,
# not by observing that a function was called:
#   T1  a child-owned background dispatch leaves NO worktree and NO branch
#       behind once the child reaches a terminal state.
#   T2  a teardown that cannot safely run is REPORTED (stderr + non-zero
#       provider exit + failed status), never swallowed, and the worktree that
#       still holds work is PRESERVED.
#   T3  a NON-child-owned dispatch (top-level /solve) keeps its worktree — the
#       teardown boundary is CHILD_OWNED, exactly as the codex arm drew it.
#   T4  the shared helper removes worktree + branch on its own, and refuses
#       (non-zero) rather than destroying uncommitted work.
#   T5  the wezterm arm is wired to the same teardown.
#
# T1-T5 cover the TERMINAL door: a child that started and then finished. The
# SETUP/LAUNCH door was still wide open — every dispatcher-side failure between
# a successful `git worktree add` and a running child returned with the
# worktree and its branch still on disk, on BOTH surviving backends. Because
# the leaked path derives purely from ISSUE_NUM, that also self-blocks the next
# dispatch of the same issue. T6-T10 close it:
#   T6  a child-owned BACKGROUND dispatch that fails setup after the worktree
#       exists leaves NO worktree and NO branch (reproduced red first: rc 1
#       with `solve-issue-77` still in `git worktree list`).
#   T7  the same failure at CHILD_OWNED=0 still keeps the operator's workspace.
#   T8  the same for the WEZTERM arm.
#   T9  a dispatcher-side teardown that cannot safely run is REPORTED (rc 74 +
#       stderr) and the work is PRESERVED — never swallowed into the plain
#       setup rc.
#   T10 the wezterm in-pane wrapper tears down on a bare `exit`, not only on a
#       signal — it had no EXIT trap at all, unlike the background wrapper.
#
# T1-T10 all assume the child got far enough to HAVE a teardown. #384 is the
# last window where it did not: the wrapper's first safe instruction is
# `. "$DISPATCH_LIB"`, and by then the worktree and branch already exist while
# `_uberdev_dispatch_cleanup_child_worktree` — and every preservation guard it
# depends on — still lives only in the file that just failed to load. T11-T14
# close it from the DISPATCHER side, before anything exists to leak:
#   T11  a dispatch whose child could not load the library creates NOTHING
#        (reproduced red first: rc 0 and `solve-issue-912` still registered).
#   T11b the refusal does not depend on CHILD_OWNED.
#   T12  a library that LOADS but does not define the teardown is refused too —
#        which is what forces the probe into a fresh child process instead of
#        re-checking this shell's already-loaded copy.
#   T13  the same for the WEZTERM arm, against a mux that spawns successfully.
#   T14  the probe is ordered BEFORE `git worktree add` in both arms.
#
# Unix-runtime fixture: real `git worktree add`, real nohup detachment, real
# POSIX ownership predicates. Skipped on windows-latest (see the ci-wiring
# windows-skip-list marker block in .github/workflows/test.yml).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCH_LIB="$REPO_ROOT/plugins/uberdev/lib/dispatch.sh"

PASS=0
FAIL=0

ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup_tmp() {
  # Every scratch worktree lives under $TMP; prune the registry copies too so a
  # failed case cannot leave a dangling admin entry behind in the fixture repo.
  rm -rf "$TMP"
}
trap cleanup_tmp EXIT

mkdir -p "$TMP/bin"
printf 'child worktree teardown\n' >"$TMP/prompt.txt"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

new_repo() {
  local path="$1"
  git init -q "$path" || return 1
  git -C "$path" config user.email fixture@example.com || return 1
  git -C "$path" config user.name fixture || return 1
  printf 'seed\n' >"$path/seed.txt" || return 1
  git -C "$path" add seed.txt || return 1
  git -C "$path" commit -qm seed || return 1
}

worktree_registered() {
  # 0 when $2 appears as a worktree of the repository at $1.
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $2"
}

branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

wait_terminal() {
  # wait_terminal STATUS_FILE BUDGET_S -> 0 once a terminal state is published
  local status_file="$1" budget="$2" started=$SECONDS status
  while [ $((SECONDS - started)) -lt "$budget" ]; do
    status="$(cat "$status_file" 2>/dev/null || true)"
    case "$status" in
      *'"state":"completed"'*|*'"state":"failed"'*|*'"state":"timed_out"'*|*'"state":"cancelled"'*)
        return 0 ;;
    esac
    sleep 0.05
  done
  return 1
}

# A provider stub standing in for `claude -p`. $TEARDOWN_FIXTURE_MODE selects
# whether it leaves the worktree pristine or dirties it.
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
case "${TEARDOWN_FIXTURE_MODE:-clean}" in
  dirty) printf 'unstaged child work\n' >"./child-scratch.txt" ;;
esac
printf 'child result\n'
SH
chmod +x "$TMP/bin/claude"

# Drive the real `_uberdev_dispatch_background` against a scratch repository.
# Only `_uberdev_dispatch_wait_owned_session` is stubbed (the fixture has no
# process-group supervisor); `git worktree add` and the teardown are REAL.
# $6 (optional) is the #384 injection: the path the CHILD is handed as its
# `$DISPATCH_LIB`. `_UBERDEV_DISPATCH_FILE` is a plain, non-readonly global and
# is exactly the argv slot both wrappers unpack, so reassigning it AFTER the
# dispatcher has loaded the real library reproduces the issue precisely — this
# process is fine, the child is not — without chmod'ing a file in the repo.
run_background_dispatch() {
  local repo="$1" runtime="$2" issue="$3" child_owned="$4" mode="$5" child_lib="${6:-}"
  mkdir -p "$runtime"
  (
    cd "$repo" || exit 1
    PATH="$TMP/bin:$PATH" \
    TEARDOWN_FIXTURE_MODE="$mode" \
    UBERDEV_AGENT_CHILD_OWNED="$child_owned" \
      /bin/bash -c '
        set -u
        . "$1"
        _uberdev_dispatch_wait_owned_session() { return 0; }
        MODEL=sonnet
        AUTO_MODE=0
        SKIP_PERMISSIONS=0
        PERM_FLAG=()
        EFFORT_FLAG=()
        UBERDEV_TMPDIR="$2"
        UBERDEV_AGENT_STATUS_FILE="$2/status.json"
        UBERDEV_AGENT_RESULT_FILE="$2/result.md"
        DISPATCH_RC=0
        DISPATCH_ID=""
        DISPATCH_LOG=""
        [ -z "$5" ] || _UBERDEV_DISPATCH_FILE="$5"
        _uberdev_dispatch_background "$4" medium "$3"
      ' _ "$DISPATCH_LIB" "$runtime" "$TMP/prompt.txt" "$issue" "$child_lib"
  ) >"$runtime/dispatch.out" 2>&1
}

# ---------------------------------------------------------------------------
# T1 — child-owned background dispatch tears its worktree AND branch down
# ---------------------------------------------------------------------------
echo "== T1: child-owned background dispatch removes worktree + branch =="
T1_REPO="$TMP/t1-repo"
new_repo "$T1_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T1_ISSUE=901
T1_WORKTREE="$(cd "$T1_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T1_ISSUE"
T1_BRANCH="worktree-solve-issue-$T1_ISSUE"
run_background_dispatch "$T1_REPO" "$TMP/t1-runtime" "$T1_ISSUE" 1 clean
T1_DISPATCH_RC=$?
if [ "$T1_DISPATCH_RC" -ne 0 ]; then
  ko "T1 background dispatch failed: $(tr '\n' ';' <"$TMP/t1-runtime/dispatch.out" 2>/dev/null)"
elif ! wait_terminal "$TMP/t1-runtime/status.json" 60; then
  ko "T1 child never reached a terminal state: $(cat "$TMP/t1-runtime/status.json" 2>/dev/null)"
else
  ok "T1 child-owned background dispatch reached a terminal state"
  if [ -e "$T1_WORKTREE" ]; then
    ko "T1 worktree directory survived the terminal child: $T1_WORKTREE"
  else
    ok "T1 worktree directory removed"
  fi
  if worktree_registered "$T1_REPO" "$T1_WORKTREE"; then
    ko "T1 worktree still registered in git worktree list"
  else
    ok "T1 worktree deregistered from git worktree list"
  fi
  if branch_exists "$T1_REPO" "$T1_BRANCH"; then
    ko "T1 branch $T1_BRANCH survived the terminal child"
  else
    ok "T1 branch removed from git branch --list"
  fi
fi

# ---------------------------------------------------------------------------
# T2 — an unsafe teardown is reported, and the work is preserved
# ---------------------------------------------------------------------------
echo "== T2: unsafe teardown is reported, never swallowed =="
T2_REPO="$TMP/t2-repo"
new_repo "$T2_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T2_ISSUE=902
T2_WORKTREE="$(cd "$T2_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T2_ISSUE"
T2_BRANCH="worktree-solve-issue-$T2_ISSUE"
run_background_dispatch "$T2_REPO" "$TMP/t2-runtime" "$T2_ISSUE" 1 dirty
if ! wait_terminal "$TMP/t2-runtime/status.json" 60; then
  ko "T2 child never reached a terminal state: $(cat "$TMP/t2-runtime/status.json" 2>/dev/null)"
else
  T2_STATUS="$(cat "$TMP/t2-runtime/status.json" 2>/dev/null || true)"
  T2_LOG="$(cat "$TMP/t2-runtime/solve-bg-stdout-$T2_ISSUE.log" 2>/dev/null || true)"
  case "$T2_STATUS" in
    *'"state":"failed"'*) ok "T2 unsafe teardown terminalizes the child as failed" ;;
    *) ko "T2 status did not report the teardown failure: $T2_STATUS" ;;
  esac
  case "$T2_LOG" in
    *"failed to clean child worktree"*) ok "T2 teardown failure is reported on the child log" ;;
    *) ko "T2 teardown failure was swallowed; log=$(printf '%s' "$T2_LOG" | tr '\n' ';')" ;;
  esac
  if [ -d "$T2_WORKTREE" ] && branch_exists "$T2_REPO" "$T2_BRANCH"; then
    ok "T2 uncommitted child work is preserved, not force-deleted"
  else
    ko "T2 teardown destroyed a worktree holding uncommitted work"
  fi
  # Leave the fixture repository in a sane state for the trap.
  git -C "$T2_REPO" worktree remove --force "$T2_WORKTREE" >/dev/null 2>&1 || true
  git -C "$T2_REPO" branch -D "$T2_BRANCH" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# T3 — a NON-child-owned dispatch keeps its worktree
# ---------------------------------------------------------------------------
echo "== T3: top-level (CHILD_OWNED=0) worktree is not torn down =="
T3_REPO="$TMP/t3-repo"
new_repo "$T3_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T3_ISSUE=903
T3_WORKTREE="$(cd "$T3_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T3_ISSUE"
T3_BRANCH="worktree-solve-issue-$T3_ISSUE"
run_background_dispatch "$T3_REPO" "$TMP/t3-runtime" "$T3_ISSUE" 0 clean
if ! wait_terminal "$TMP/t3-runtime/status.json" 60; then
  ko "T3 child never reached a terminal state: $(cat "$TMP/t3-runtime/status.json" 2>/dev/null)"
elif [ -d "$T3_WORKTREE" ] && branch_exists "$T3_REPO" "$T3_BRANCH"; then
  ok "T3 non-child-owned worktree and branch survive the terminal agent"
else
  ko "T3 teardown crossed the CHILD_OWNED boundary and removed a caller-owned worktree"
fi

# ---------------------------------------------------------------------------
# T4 — the shared teardown helper, exercised directly
# ---------------------------------------------------------------------------
echo "== T4: _uberdev_dispatch_cleanup_child_worktree removes and refuses =="
T4_REPO="$TMP/t4-repo"
new_repo "$T4_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T4_ROOT="$(cd "$T4_REPO" && pwd -P)"
T4_HEAD="$(git -C "$T4_REPO" rev-parse --verify HEAD)"

t4_add() {
  local relative="$1" branch="$2"
  git -C "$T4_REPO" worktree add "$T4_ROOT/$relative" -b "$branch" "$T4_HEAD" >/dev/null 2>&1
}

t4_cleanup() {
  local relative="$1" branch="$2" terminal="$3"
  /bin/bash -c '
    set -u
    . "$1"
    _uberdev_dispatch_cleanup_child_worktree "$2" "$3" "$4" "$5" "$6"
  ' _ "$DISPATCH_LIB" "$T4_ROOT" "$relative" "$branch" "$T4_HEAD" "$terminal" 2>&1
}

T4_REL=".claude/worktrees/teardown-clean"
T4_BRANCH="teardown-clean"
if t4_add "$T4_REL" "$T4_BRANCH"; then
  T4_OUT="$(t4_cleanup "$T4_REL" "$T4_BRANCH" completed)"
  T4_RC=$?
  if [ "$T4_RC" -eq 0 ] && [ ! -e "$T4_ROOT/$T4_REL" ] \
      && ! worktree_registered "$T4_REPO" "$T4_ROOT/$T4_REL" \
      && ! branch_exists "$T4_REPO" "$T4_BRANCH"; then
    ok "T4 helper removes a pristine child worktree and its branch"
  else
    ko "T4 helper left state behind: rc=$T4_RC out=$(printf '%s' "$T4_OUT" | tr '\n' ';')"
  fi
else
  ko "T4 could not create the pristine fixture worktree"
fi

T4_DIRTY_REL=".claude/worktrees/teardown-dirty"
T4_DIRTY_BRANCH="teardown-dirty"
if t4_add "$T4_DIRTY_REL" "$T4_DIRTY_BRANCH"; then
  printf 'work in progress\n' >"$T4_ROOT/$T4_DIRTY_REL/wip.txt"
  T4_DIRTY_OUT="$(t4_cleanup "$T4_DIRTY_REL" "$T4_DIRTY_BRANCH" failed)"
  T4_DIRTY_RC=$?
  # rc 3 SPECIFICALLY — the preservation verdict. A bare "non-zero" would also
  # be satisfied by 127 (helper absent), which is the very regression this
  # fixture exists to catch.
  if [ "$T4_DIRTY_RC" -eq 3 ] && [ -d "$T4_ROOT/$T4_DIRTY_REL" ] \
      && branch_exists "$T4_REPO" "$T4_DIRTY_BRANCH"; then
    ok "T4 helper refuses (rc=3, preserve) rather than destroying uncommitted work"
  else
    ko "T4 helper mishandled a dirty worktree: rc=$T4_DIRTY_RC out=$(printf '%s' "$T4_DIRTY_OUT" | tr '\n' ';')"
  fi
  git -C "$T4_REPO" worktree remove --force "$T4_ROOT/$T4_DIRTY_REL" >/dev/null 2>&1 || true
  git -C "$T4_REPO" branch -D "$T4_DIRTY_BRANCH" >/dev/null 2>&1 || true
else
  ko "T4 could not create the dirty fixture worktree"
fi

T4_BAD_OUT="$(t4_cleanup ".claude/worktrees/teardown-clean" "teardown-clean" not-a-terminal-state)"
T4_BAD_RC=$?
if [ "$T4_BAD_RC" -eq 3 ]; then
  ok "T4 helper rejects a non-terminal state argument (rc=3)"
else
  ko "T4 helper accepted a non-terminal state: $(printf '%s' "$T4_BAD_OUT" | tr '\n' ';')"
fi

# ---------------------------------------------------------------------------
# T5 — both surviving detached backends are wired to the shared teardown
# ---------------------------------------------------------------------------
echo "== T5: background and wezterm arms are wired to the teardown =="
arm_body() {
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f{print} f&&/^}/{exit}' "$DISPATCH_LIB"
}
for arm in _uberdev_dispatch_background _uberdev_dispatch_wezterm; do
  BODY="$(arm_body "$arm")"
  if printf '%s\n' "$BODY" | grep -Fq '_uberdev_dispatch_cleanup_child_worktree'; then
    ok "T5 $arm invokes _uberdev_dispatch_cleanup_child_worktree"
  else
    ko "T5 $arm has no teardown call — an isolated child-owned worktree would leak"
  fi
  if printf '%s\n' "$BODY" | grep -Fq 'UBERDEV_AGENT_CHILD_OWNED'; then
    ok "T5 $arm reads UBERDEV_AGENT_CHILD_OWNED to scope the teardown"
  else
    ko "T5 $arm does not scope teardown by CHILD_OWNED"
  fi
  if printf '%s\n' "$BODY" | grep -Fq 'failed to clean child worktree'; then
    ok "T5 $arm reports a teardown failure instead of swallowing it"
  else
    ko "T5 $arm swallows teardown failures"
  fi
done

# ---------------------------------------------------------------------------
# T6-T10 — the SETUP/LAUNCH-failure door
# ---------------------------------------------------------------------------

# A `wezterm` stub. It stands in for the mux, and $WEZTERM_FIXTURE_MODE selects
# which real-world failure it reproduces:
#   spawn-fail   the mux is not up -> `wezterm cli spawn` exits non-zero. This
#                is the routine case: no pane id comes back, so nothing
#                downstream will ever take the worktree down.
#   dirty-fail   the same, but the pane got far enough to leave work behind, so
#                the teardown must REFUSE and say so.
#   run-pane     actually run the spawned wrapper locally, standing in for the
#                pane process, with the wrapper's status path redirected at an
#                unwritable location so `write_status running` exits 126.
#   run-pane-ok  a mux that WORKS: it runs the spawned wrapper, then returns a
#                pane id and exits 0. This is the #384 shape — the dispatcher
#                sees a successful spawn, so no dispatcher-side teardown ever
#                runs, and whatever the pane does to itself is the only
#                teardown there is.
cat >"$TMP/bin/wezterm" <<'SH'
#!/usr/bin/env bash
case "${WEZTERM_FIXTURE_MODE:-spawn-fail}" in
  spawn-fail) exit 3 ;;
  dirty-fail)
    printf 'pane work in progress\n' >"$WEZTERM_FIXTURE_WORKTREE/pane-scratch.txt"
    exit 3
    ;;
  run-pane)
    args=( "$@" )
    index=0
    while [ "$index" -lt "${#args[@]}" ] && [ "${args[$index]}" != "--" ]; do
      index=$((index + 1))
    done
    index=$((index + 1))
    pane=( "${args[@]:$index}" )
    # pane = bash -c BODY _ PY PREFIX LIB STATUS ... ; index 7 is the wrapper's
    # own $4 -> STATUS_FILE. Redirect it so write_status running fails.
    pane[7]="$WEZTERM_FIXTURE_STATUS_OVERRIDE"
    cd "$WEZTERM_FIXTURE_WORKTREE" || exit 1
    "${pane[@]}"
    exit $?
    ;;
  run-pane-ok)
    args=( "$@" )
    index=0
    while [ "$index" -lt "${#args[@]}" ] && [ "${args[$index]}" != "--" ]; do
      index=$((index + 1))
    done
    index=$((index + 1))
    pane=( "${args[@]:$index}" )
    cd "$WEZTERM_FIXTURE_WORKTREE" || exit 1
    "${pane[@]}" >/dev/null 2>&1
    # The spawn itself succeeded, whatever the pane body then did.
    printf '731\n'
    exit 0
    ;;
esac
exit 3
SH
chmod +x "$TMP/bin/wezterm"

# Drive the real `_uberdev_dispatch_background` to a dispatcher-side SETUP
# failure after `git worktree add` has already succeeded. An unreadable
# $PROMPT_FILE is the cheapest real one (dispatch.sh's `prompt_read` arm).
run_background_setup_failure() {
  local repo="$1" runtime="$2" issue="$3" child_owned="$4" prompt="$5"
  mkdir -p "$runtime"
  (
    cd "$repo" || exit 1
    PATH="$TMP/bin:$PATH" \
    UBERDEV_AGENT_CHILD_OWNED="$child_owned" \
      /bin/bash -c '
        set -u
        . "$1"
        _uberdev_dispatch_wait_owned_session() { return 0; }
        MODEL=sonnet
        AUTO_MODE=0
        SKIP_PERMISSIONS=0
        PERM_FLAG=()
        EFFORT_FLAG=()
        UBERDEV_TMPDIR="$2"
        UBERDEV_AGENT_STATUS_FILE="$2/status.json"
        UBERDEV_AGENT_RESULT_FILE="$2/result.md"
        DISPATCH_RC=0
        DISPATCH_ID=""
        DISPATCH_LOG=""
        _uberdev_dispatch_background "$4" medium "$3"
      ' _ "$DISPATCH_LIB" "$runtime" "$prompt" "$issue"
  ) >"$runtime/dispatch.out" 2>&1
}

# Drive the real `_uberdev_dispatch_wezterm`. Only the wezterm CONFIG probe is
# stubbed out (it writes to the operator's real WezTerm config); the mux itself
# is the $TMP/bin/wezterm stub above, and the worktree + teardown are REAL.
# $8 (optional) is the same #384 child-library injection as
# run_background_dispatch's $6.
run_wezterm_dispatch() {
  local repo="$1" runtime="$2" issue="$3" child_owned="$4" prompt="$5" mode="$6"
  local status_override="${7:-}" child_lib="${8:-}"
  mkdir -p "$runtime"
  (
    cd "$repo" || exit 1
    PATH="$TMP/bin:$PATH" \
    UBERDEV_AGENT_CHILD_OWNED="$child_owned" \
    WEZTERM_FIXTURE_MODE="$mode" \
    WEZTERM_FIXTURE_WORKTREE="$(cd "$repo" && pwd -P)/.claude/worktrees/solve-issue-$issue" \
    WEZTERM_FIXTURE_STATUS_OVERRIDE="$status_override" \
      /bin/bash -c '
        set -u
        . "$1"
        _uberdev_dispatch_wezterm_config() { return 0; }
        MODEL=sonnet
        PERM_FLAG=()
        EFFORT_FLAG=()
        UBERDEV_TMPDIR="$2"
        UBERDEV_AGENT_STATUS_FILE="$2/status.json"
        DISPATCH_RC=0
        DISPATCH_ID=""
        DISPATCH_LOG=""
        [ -z "$5" ] || _UBERDEV_DISPATCH_FILE="$5"
        _uberdev_dispatch_wezterm "$4" medium "$3"
      ' _ "$DISPATCH_LIB" "$runtime" "$prompt" "$issue" "$child_lib"
  ) >"$runtime/dispatch.out" 2>&1
}

echo "== T6: child-owned background SETUP failure leaves no worktree + no branch =="
T6_REPO="$TMP/t6-repo"
new_repo "$T6_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T6_ISSUE=906
T6_WORKTREE="$(cd "$T6_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T6_ISSUE"
T6_BRANCH="worktree-solve-issue-$T6_ISSUE"
run_background_setup_failure "$T6_REPO" "$TMP/t6-runtime" "$T6_ISSUE" 1 "$TMP/no-such-prompt.txt"
T6_RC=$?
if [ "$T6_RC" -eq 0 ]; then
  ko "T6 background dispatch reported success on an unreadable prompt file"
else
  ok "T6 background setup failure is still reported (rc=$T6_RC)"
fi
if [ -e "$T6_WORKTREE" ] || worktree_registered "$T6_REPO" "$T6_WORKTREE"; then
  ko "T6 setup failure leaked the child worktree: $T6_WORKTREE"
else
  ok "T6 setup failure removed the child worktree and deregistered it"
fi
if branch_exists "$T6_REPO" "$T6_BRANCH"; then
  ko "T6 setup failure leaked branch $T6_BRANCH — the next dispatch of this issue is now blocked"
else
  ok "T6 setup failure removed the child branch"
fi

echo "== T7: CHILD_OWNED=0 keeps its workspace through a setup failure =="
T7_REPO="$TMP/t7-repo"
new_repo "$T7_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T7_ISSUE=907
T7_WORKTREE="$(cd "$T7_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T7_ISSUE"
T7_BRANCH="worktree-solve-issue-$T7_ISSUE"
run_background_setup_failure "$T7_REPO" "$TMP/t7-runtime" "$T7_ISSUE" 0 "$TMP/no-such-prompt.txt"
if [ -d "$T7_WORKTREE" ] && branch_exists "$T7_REPO" "$T7_BRANCH"; then
  ok "T7 top-level workspace survives a setup failure — the teardown stays inside CHILD_OWNED"
else
  ko "T7 setup-failure teardown crossed the CHILD_OWNED boundary"
fi

echo "== T8: child-owned wezterm SETUP failure leaves no worktree + no branch =="
T8_REPO="$TMP/t8-repo"
new_repo "$T8_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T8_ISSUE=908
T8_WORKTREE="$(cd "$T8_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T8_ISSUE"
T8_BRANCH="worktree-solve-issue-$T8_ISSUE"
run_wezterm_dispatch "$T8_REPO" "$TMP/t8-runtime" "$T8_ISSUE" 1 "$TMP/no-such-prompt.txt" spawn-fail
T8_RC=$?
if [ "$T8_RC" -eq 0 ]; then
  ko "T8 wezterm dispatch reported success on an unreadable prompt file"
else
  ok "T8 wezterm setup failure is still reported (rc=$T8_RC)"
fi
if [ -e "$T8_WORKTREE" ] || worktree_registered "$T8_REPO" "$T8_WORKTREE" \
    || branch_exists "$T8_REPO" "$T8_BRANCH"; then
  ko "T8 wezterm setup failure leaked the child worktree/branch: $T8_WORKTREE"
else
  ok "T8 wezterm setup failure removed the child worktree and its branch"
fi

echo "== T8b: a failed wezterm spawn does not leak the worktree it created =="
T8B_REPO="$TMP/t8b-repo"
new_repo "$T8B_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T8B_ISSUE=909
T8B_WORKTREE="$(cd "$T8B_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T8B_ISSUE"
T8B_BRANCH="worktree-solve-issue-$T8B_ISSUE"
run_wezterm_dispatch "$T8B_REPO" "$TMP/t8b-runtime" "$T8B_ISSUE" 1 "$TMP/prompt.txt" spawn-fail
if [ -e "$T8B_WORKTREE" ] || worktree_registered "$T8B_REPO" "$T8B_WORKTREE" \
    || branch_exists "$T8B_REPO" "$T8B_BRANCH"; then
  ko "T8b a mux that is not up leaked a worktree with no pane id to reap it"
else
  ok "T8b a failed spawn removes the worktree it created"
fi

echo "== T9: an unsafe dispatcher-side teardown is reported (rc 74), work preserved =="
T9_REPO="$TMP/t9-repo"
new_repo "$T9_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T9_ISSUE=910
T9_WORKTREE="$(cd "$T9_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T9_ISSUE"
T9_BRANCH="worktree-solve-issue-$T9_ISSUE"
run_wezterm_dispatch "$T9_REPO" "$TMP/t9-runtime" "$T9_ISSUE" 1 "$TMP/prompt.txt" dirty-fail
T9_RC=$?
# rc 74 SPECIFICALLY. Plain "non-zero" would also be satisfied by the ordinary
# setup rc 1, which is exactly the swallowing this assertion exists to forbid.
if [ "$T9_RC" -eq 74 ]; then
  ok "T9 a failed dispatcher-side teardown is folded into the rc as 74"
else
  ko "T9 teardown failure was swallowed into rc=$T9_RC (expected 74)"
fi
T9_OUT="$(cat "$TMP/t9-runtime/dispatch.out" 2>/dev/null || true)"
case "$T9_OUT" in
  *"failed to clean child worktree"*) ok "T9 the teardown failure names the worktree on stderr" ;;
  *) ko "T9 teardown failure was silent: $(printf '%s' "$T9_OUT" | tr '\n' ';')" ;;
esac
if [ -d "$T9_WORKTREE" ] && branch_exists "$T9_REPO" "$T9_BRANCH"; then
  ok "T9 the work the pane left behind is preserved, not force-deleted"
else
  ko "T9 the dispatcher-side teardown destroyed a worktree holding work"
fi
git -C "$T9_REPO" worktree remove --force "$T9_WORKTREE" >/dev/null 2>&1 || true
git -C "$T9_REPO" branch -D "$T9_BRANCH" >/dev/null 2>&1 || true

echo "== T10: the wezterm pane wrapper tears down on a bare exit, not only on a signal =="
T10_REPO="$TMP/t10-repo"
new_repo "$T10_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T10_ISSUE=911
T10_WORKTREE="$(cd "$T10_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T10_ISSUE"
T10_BRANCH="worktree-solve-issue-$T10_ISSUE"
# $TMP/t10-unwritable does not exist, so the wrapper's own `write_status
# running null || exit 126` fails and the pane exits WITHOUT a signal. Before
# the EXIT trap was armed there, that exit stranded the worktree silently.
run_wezterm_dispatch "$T10_REPO" "$TMP/t10-runtime" "$T10_ISSUE" 1 "$TMP/prompt.txt" \
  run-pane "$TMP/t10-unwritable/status.json"
if [ -e "$T10_WORKTREE" ] || worktree_registered "$T10_REPO" "$T10_WORKTREE" \
    || branch_exists "$T10_REPO" "$T10_BRANCH"; then
  ko "T10 the pane wrapper exited without a signal and stranded $T10_WORKTREE"
else
  ok "T10 the pane wrapper's EXIT trap tore the worktree down on a bare exit"
fi

echo "== T10b: both wrappers arm an EXIT trap, not only HUP INT TERM =="
for arm in _uberdev_dispatch_background _uberdev_dispatch_wezterm; do
  BODY="$(arm_body "$arm")"
  if printf '%s\n' "$BODY" | grep -Fq "cleanup_child_worktree cancelled || true'\\'' EXIT"; then
    ok "T10b $arm arms an EXIT trap on its child wrapper"
  else
    ko "T10b $arm has no EXIT trap — a bare exit after worktree creation leaks"
  fi
done

# ---------------------------------------------------------------------------
# T11-T14 — the PRE-SOURCE door (#384)
#
# Everything above assumes the child reached `. "$DISPATCH_LIB"` successfully.
# When it does not, the worktree and branch exist and the teardown does not, so
# the only fix that does not invert the preservation guards is to refuse
# EARLIER — before `git worktree add` — on the dispatcher side.
# ---------------------------------------------------------------------------

# Never created: the "partial checkout / file is gone" shape.
MISSING_CHILD_LIB="$TMP/no-such-dispatch-lib.sh"
# Loads without error and defines NONE of the teardown surface: the "truncated
# library" shape. A preflight that only asks whether `. "$lib"` returned 0 —
# or that re-checks THIS shell, where the real functions are already defined —
# passes this one and still hands the child a worktree it cannot remove.
PARTIAL_CHILD_LIB="$TMP/partial-dispatch-lib.sh"
cat >"$PARTIAL_CHILD_LIB" <<'SH'
# Deliberately truncated stand-in for plugins/uberdev/lib/dispatch.sh.
_UBERDEV_PARTIAL_FIXTURE_LOADED=1
SH

echo "== T11: a child that cannot load the dispatch library gets no worktree at all =="
T11_REPO="$TMP/t11-repo"
new_repo "$T11_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T11_ISSUE=912
T11_WORKTREE="$(cd "$T11_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T11_ISSUE"
T11_BRANCH="worktree-solve-issue-$T11_ISSUE"
run_background_dispatch "$T11_REPO" "$TMP/t11-runtime" "$T11_ISSUE" 1 clean "$MISSING_CHILD_LIB"
T11_RC=$?
# rc 1 SPECIFICALLY. rc 0 is the pre-fix behaviour (the dispatch "succeeded"
# and leaked), and rc 74 would mean a worktree WAS created and then had to be
# torn down — the exact sequence this preflight exists to make impossible.
if [ "$T11_RC" -eq 1 ]; then
  ok "T11 the dispatcher refuses (rc=1) instead of dispatching a child that cannot clean up"
else
  ko "T11 expected rc 1, got rc=$T11_RC: $(tr '\n' ';' <"$TMP/t11-runtime/dispatch.out" 2>/dev/null)"
fi
if [ -e "$T11_WORKTREE" ] || worktree_registered "$T11_REPO" "$T11_WORKTREE" \
    || branch_exists "$T11_REPO" "$T11_BRANCH"; then
  ko "T11 the child could not load $MISSING_CHILD_LIB and still got a worktree: $T11_WORKTREE"
else
  ok "T11 no worktree and no branch were ever created"
fi
T11_OUT="$(cat "$TMP/t11-runtime/dispatch.out" 2>/dev/null || true)"
case "$T11_OUT" in
  *"refusing to create a child worktree"*"$MISSING_CHILD_LIB"*)
    ok "T11 the refusal is loud and names the library it could not load" ;;
  *) ko "T11 the refusal did not name the library: $(printf '%s' "$T11_OUT" | tr '\n' ';')" ;;
esac

echo "== T11b: the refusal does not depend on CHILD_OWNED =="
# A child that cannot source the library never does any work for anybody, so
# creating a top-level workspace and launching a child that dies immediately is
# strictly worse than saying so. The teardown boundary is CHILD_OWNED; this
# precondition is not.
T11B_REPO="$TMP/t11b-repo"
new_repo "$T11B_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T11B_ISSUE=913
T11B_WORKTREE="$(cd "$T11B_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T11B_ISSUE"
T11B_BRANCH="worktree-solve-issue-$T11B_ISSUE"
run_background_dispatch "$T11B_REPO" "$TMP/t11b-runtime" "$T11B_ISSUE" 0 clean "$MISSING_CHILD_LIB"
T11B_RC=$?
if [ "$T11B_RC" -eq 1 ] && [ ! -e "$T11B_WORKTREE" ] \
    && ! branch_exists "$T11B_REPO" "$T11B_BRANCH"; then
  ok "T11b a top-level dispatch is refused the same way (rc=1, nothing created)"
else
  ko "T11b expected rc 1 and no worktree, got rc=$T11B_RC worktree_exists=$([ -e "$T11B_WORKTREE" ] && echo yes || echo no)"
fi

echo "== T12: a library that loads but has no teardown is refused too =="
T12_REPO="$TMP/t12-repo"
new_repo "$T12_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T12_ISSUE=914
T12_WORKTREE="$(cd "$T12_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T12_ISSUE"
T12_BRANCH="worktree-solve-issue-$T12_ISSUE"
run_background_dispatch "$T12_REPO" "$TMP/t12-runtime" "$T12_ISSUE" 1 clean "$PARTIAL_CHILD_LIB"
T12_RC=$?
if [ "$T12_RC" -eq 1 ] && [ ! -e "$T12_WORKTREE" ] \
    && ! worktree_registered "$T12_REPO" "$T12_WORKTREE" \
    && ! branch_exists "$T12_REPO" "$T12_BRANCH"; then
  ok "T12 the probe asks whether the TEARDOWN is reachable, not merely whether the source returned 0"
else
  ko "T12 a truncated library still got a worktree: rc=$T12_RC out=$(tr '\n' ';' <"$TMP/t12-runtime/dispatch.out" 2>/dev/null)"
fi

echo "== T13: the wezterm arm refuses before the pane's worktree exists =="
T13_REPO="$TMP/t13-repo"
new_repo "$T13_REPO" || { echo "  ABORT  cannot create fixture repo"; exit 99; }
T13_ISSUE=915
T13_WORKTREE="$(cd "$T13_REPO" && pwd -P)/.claude/worktrees/solve-issue-$T13_ISSUE"
T13_BRANCH="worktree-solve-issue-$T13_ISSUE"
# run-pane-ok: the mux is up and the spawn succeeds, so NOTHING on the
# dispatcher side will ever take this worktree back down — only the pane could,
# and the pane is the process that cannot load the library.
run_wezterm_dispatch "$T13_REPO" "$TMP/t13-runtime" "$T13_ISSUE" 1 "$TMP/prompt.txt" \
  run-pane-ok "" "$MISSING_CHILD_LIB"
T13_RC=$?
if [ "$T13_RC" -eq 1 ]; then
  ok "T13 the wezterm arm refuses (rc=1) before spawning a pane that cannot clean up"
else
  ko "T13 expected rc 1, got rc=$T13_RC: $(tr '\n' ';' <"$TMP/t13-runtime/dispatch.out" 2>/dev/null)"
fi
if [ -e "$T13_WORKTREE" ] || worktree_registered "$T13_REPO" "$T13_WORKTREE" \
    || branch_exists "$T13_REPO" "$T13_BRANCH"; then
  ko "T13 a successful spawn of a pane that cannot source the library leaked $T13_WORKTREE"
else
  ok "T13 no worktree and no branch were ever created"
fi
T13_OUT="$(cat "$TMP/t13-runtime/dispatch.out" 2>/dev/null || true)"
case "$T13_OUT" in
  *"refusing to create a child worktree"*"$MISSING_CHILD_LIB"*)
    ok "T13 the wezterm refusal names the library it could not load" ;;
  *) ko "T13 the wezterm refusal did not name the library: $(printf '%s' "$T13_OUT" | tr '\n' ';')" ;;
esac

echo "== T14: both arms probe the child's library BEFORE git worktree add =="
for arm in _uberdev_dispatch_background _uberdev_dispatch_wezterm; do
  BODY="$(arm_body "$arm")"
  PREFLIGHT_LINE="$(printf '%s\n' "$BODY" | grep -nF '_uberdev_dispatch_preflight_child_lib' | head -1 | cut -d: -f1)"
  ADD_LINE="$(printf '%s\n' "$BODY" | grep -nF '_uberdev_dispatch_git_worktree_add' | head -1 | cut -d: -f1)"
  # Ordering is the whole property: a probe that runs after the add guards
  # nothing, because by then the thing it would have prevented already exists.
  if [ -n "$PREFLIGHT_LINE" ] && [ -n "$ADD_LINE" ] && [ "$PREFLIGHT_LINE" -lt "$ADD_LINE" ]; then
    ok "T14 $arm probes the child's dispatch library before creating the worktree"
  else
    ko "T14 $arm preflight=${PREFLIGHT_LINE:-none} worktree-add=${ADD_LINE:-none} — the probe must come first"
  fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

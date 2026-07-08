#!/usr/bin/env bash
# tests/goal-pipeline-zsh.test.sh — RUNTIME coverage for the /uberdev:goal
# ORCHESTRATION layer (issue #293).
#
# lib/goal-state.sh is densely unit-tested (goal.test.sh + goal-state-zsh.test.sh
# + goal-dispatch-helpers.test.sh + goal-state-sidecar.test.sh), but until this
# fixture NO test ever EXECUTED the bash-fenced blocks in
# skills/goal-pipeline/SKILL.md — CI only sources the lib and greps the markdown
# (G6-G10/G17/G22/G33/G37 are all `assert_grep`). The whole orchestration loop
# (Phase-0 arg-parse + the bash>=4 resolver, the per-phase rehydration fences,
# the watch loop, the circuit-breaker firing sites, the merge barrier, the
# Phase-3 convergence calc) shipped with zero runtime coverage, so every wiring
# regression — including the sibling /ubergoal-audit defects — shipped green.
#
# THIS fixture EXTRACTS the load-bearing `bash`-fenced blocks from SKILL.md and
# RUNS them under the REAL shell with `gh` / `claude` / `uberdev_dispatch_one`
# (and the heavy lib helpers) MOCKED. The repo's empirically-confirmed execution
# model: the Claude-Code Bash tool runs every SKILL.md fence under /bin/zsh
# (BASH_VERSINFO unset), and a bash>=4 binary exists at /opt/homebrew/bin/bash.
# So the extracted fences are run under a dedicated `zsh` subprocess — that is
# the real runtime the #294 / #270 / #290.2 cross-shell fixes were written for,
# and the failure mode grep-only coverage can never catch.
#
# Launcher: CI runs this exactly like its sibling tests/goal-state-zsh.test.sh:
#
#   zsh tests/goal-pipeline-zsh.test.sh   # CI launcher (matches test.yml)
#   bash tests/goal-pipeline-zsh.test.sh  # also works — the HARNESS is dual-
#                                         # launchable; the extracted FENCES are
#                                         # ALWAYS run under `zsh -f` regardless
#                                         # of which shell launched the harness.
#
# Coverage (issue #293 acceptance set):
#   P0  Phase-0 arg-parse + bash>=4 resolver (#294) — under zsh, a present
#       bash>=4 resolves UBERDEV_GOAL_BASH and does NOT spuriously `exit 2`;
#       with NO bash>=4 reachable it DOES `exit 2` (the brew-install dead-end).
#   P3  Phase-3 terminal/convergence calc (#288) — does NOT converge while the
#       rollover `queue` is non-empty; DOES converge when queue empty + all
#       terminal; halts queue_empty_not_converged when a PR is stuck.
#   W   One watch-loop iteration (step 2b) — the verdict-locator glob
#       (_uberdev_goal_glob_worktree, #270/#290.2) finds a WORKTREE-MIRROR
#       verdict under zsh and the loop transitions pushed-reviewing -> green
#       WITHOUT fataling.
#
# Mutation guards (each behavioural assertion catches a real regression — revert
# the named production fix in your worktree and re-run; the assertion goes RED):
#   - P0a: resolver `for _cand … ; if major>=4 then UBERDEV_GOAL_BASH=…` arm ->
#          old `[ -z BASH_VERSINFO ] && exit 2` guard  => P0a RED (spurious exit 2).
#   - P3a: terminal-gate `&& [ "${#queue[@]}" -eq 0 ]` clause (issue #288 #1)
#          removed => P3a RED (converges with a non-empty rollover queue).
#   - W:   _uberdev_goal_glob_worktree `${~pat}` (zsh arm) -> bare `$pat`
#          (#270/#290.2) => W RED (worktree-mirror verdict never found -> never
#          transitions to green).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT
GOAL_SKILL="$CLAUDE_PLUGIN_ROOT/skills/goal-pipeline/SKILL.md"
GOAL_LIB="$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
DISPATCH_LIB="$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"

for f in "$GOAL_SKILL" "$GOAL_LIB" "$DISPATCH_LIB"; do
  if [ ! -r "$f" ]; then
    printf 'FATAL: required file missing or unreadable: %s\n' "$f" >&2
    exit 2
  fi
done

# The fences MUST run under a real zsh — that is the SKILL.md execution model
# this fixture exists to cover. Refuse to run if no zsh is reachable rather than
# silently degrading to a bash-only (false-confidence) run.
ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
if [ -z "$ZSH_BIN" ]; then
  echo "FATAL: zsh not found on PATH — this fixture runs the goal-pipeline SKILL.md" >&2
  echo "       fences under zsh (their real Claude-Code Bash-tool runtime)." >&2
  exit 2
fi

# Report which shell launched the HARNESS (the fences run under $ZSH_BIN either
# way). Mirrors goal-state-zsh.test.sh's banner.
if [ -n "${ZSH_VERSION:-}" ]; then
  LAUNCH_SHELL="zsh"
else
  LAUNCH_SHELL="bash"
fi
echo "== goal-pipeline-zsh.test.sh — harness launched under: $LAUNCH_SHELL; fences run under: $ZSH_BIN =="

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# Fence extractors. SKILL.md fences are Skill-RENDERED markdown; the bash
# blocks (some 3-space-indented inside the Phase-0 numbered steps) execute
# under /bin/zsh. These awk helpers pull a fence (or a precise slice of one)
# by CONTENT ANCHOR — robust to line-number drift, which matters for the
# mutation tests in #293's discipline section (reverting a fix shifts lines).
#
# extract_fence ANCHOR  — print the body of the ```bash fence containing ANCHOR.
# slice_fence S E       — print the lines from the (in-fence) line containing S
#                         through the line containing E (inclusive); used to
#                         pull one loop out of the 587-line Phase-2 watch fence.
# Both exit 3 (-> caller fails the test) when the anchor is not found, so a
# SKILL.md edit that removes/renames an anchored block fails LOUD here.
# --------------------------------------------------------------------------
EXTRACT_AWK="$WORK/extract.awk"
cat > "$EXTRACT_AWK" <<'AWK'
BEGIN { infence=0; curbash=0; found=0; buf="" }
{
  line=$0
  if (line ~ /^[[:space:]]*```/) {
    if (infence==0) {
      stripped=line; sub(/^[[:space:]]*```/, "", stripped)
      curbash = (stripped ~ /^bash[[:space:]]*$/) ? 1 : 0
      infence=1; buf=""; hasanchor=0; next
    } else {
      if (curbash==1 && hasanchor==1) { printf "%s", buf; found=1; exit }
      infence=0; curbash=0; next
    }
  }
  if (infence==1 && curbash==1) {
    buf = buf line "\n"
    if (index(line, ANCHOR) > 0) hasanchor=1
  }
}
END { if (found==0) exit 3 }
AWK

SLICE_AWK="$WORK/slice.awk"
cat > "$SLICE_AWK" <<'AWK'
BEGIN { infence=0; curbash=0; emitting=0; found=0 }
{
  line=$0
  if (line ~ /^[[:space:]]*```/) {
    if (infence==0) {
      stripped=line; sub(/^[[:space:]]*```/, "", stripped)
      curbash = (stripped ~ /^bash[[:space:]]*$/) ? 1 : 0
      infence=1; next
    } else { infence=0; curbash=0; next }
  }
  if (infence==1 && curbash==1) {
    if (emitting==0 && index(line, SANCHOR) > 0) emitting=1
    if (emitting==1) { print line; if (index(line, EANCHOR) > 0) { found=1; exit } }
  }
}
END { if (found==0) exit 3 }
AWK

extract_fence() { awk -v ANCHOR="$1" -f "$EXTRACT_AWK" "$GOAL_SKILL"; }
slice_fence()   { awk -v SANCHOR="$1" -v EANCHOR="$2" -f "$SLICE_AWK" "$GOAL_SKILL"; }

# ==========================================================================
# P0 — Phase-0 arg-parse + bash>=4 execution-contract resolver (#294).
#
# The pre-#294 guard hard-`exit 2`ed whenever BASH_VERSINFO was unset, which is
# ALWAYS the case under the zsh-backed Bash tool — so /goal was unrunnable
# out-of-box even with bash 5.x installed. The fix: discover a bash>=4, publish
# UBERDEV_GOAL_BASH, and proceed; hard-exit 2 ONLY when no bash>=4 is reachable.
# A pure grep cannot tell the two states apart — only running the resolver under
# zsh can. We run the EXTRACTED resolver fence verbatim, swapping ONLY the
# hard-coded candidate-path list (via sed) so the test controls which bash
# binaries are probed (the version-gate + exit/publish logic stays verbatim).
# ==========================================================================
echo
echo "== P0: Phase-0 bash>=4 resolver (#294) under zsh =="

RESOLVER_FENCE="$WORK/resolver.fence.sh"
if extract_fence 'Execution-contract resolver' > "$RESOLVER_FENCE" && [ -s "$RESOLVER_FENCE" ]; then
  pass "P0.extract: located the #294 execution-contract resolver fence in SKILL.md"
else
  fail "P0.extract: could NOT extract the resolver fence (anchor 'Execution-contract resolver' moved/removed?)"
fi

# Fake bash binaries: one reporting MAJOR 5 (usable) and one reporting MAJOR 3
# (the stock-macOS /bin/bash that must be REJECTED). The fence probes each
# candidate with `"$cand" -c 'echo "${BASH_VERSINFO[0]:-0}"'`.
mk_fake_bash() {  # $1=path $2=major
  cat > "$1" <<FAKE
#!/bin/sh
[ "\$1" = "-c" ] && { echo $2; exit 0; }
exit 0
FAKE
  chmod +x "$1" || { echo "FATAL: chmod +x $1 failed (fake bash would be non-executable -> P0 false result)" >&2; exit 3; }
}
mk_fake_bash "$WORK/bash5" 5
mk_fake_bash "$WORK/bash3" 3

# Candidate-list rewrite: the fence iterates
#   for _cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash …)"
# Replace the two hard-coded paths with test-controlled ones, and stub
# `command -v bash` to return nothing, so ONLY our fake binaries are probed.
make_resolver_variant() {  # $1=outfile  $2=first-cand  $3=second-cand
  sed "s#/opt/homebrew/bin/bash /usr/local/bin/bash#$2 $3#" "$RESOLVER_FENCE" > "$1" \
    || { echo "FATAL: make_resolver_variant sed failed writing $1" >&2; exit 3; }
  # Fail LOUD if the substitution did not apply. A drifted SKILL.md candidate-list
  # anchor would make sed a no-op passthrough, leaving the REAL bash paths in the
  # variant -> P0a/P0b would then probe the host's real bash and FALSE-PASS,
  # defeating the regression guard. Assert the test-controlled path landed.
  grep -q "$2" "$1" \
    || { echo "FATAL: resolver candidate-list substitution did not apply (SKILL.md anchor '/opt/homebrew/bin/bash /usr/local/bin/bash' drifted?)" >&2; exit 3; }
}

# --- P0a POSITIVE: a usable bash>=4 is present -> resolve + proceed (NOT exit 2).
RES_POS="$WORK/resolver.pos.sh"
make_resolver_variant "$RES_POS" "$WORK/bash5" "$WORK/none"
DRV_POS="$WORK/drv_pos.zsh"
{
  echo 'set -u'
  echo 'command() { if [ "$1" = "-v" ] && [ "$2" = "bash" ]; then return 1; fi; builtin command "$@"; }'
  echo "source '$RES_POS'"
  echo 'echo "PROCEEDED rc=$? bash=${UBERDEV_GOAL_BASH:-UNSET}"'
} > "$DRV_POS"
POS_OUT="$("$ZSH_BIN" -f "$DRV_POS" 2>&1)"
POS_RC=$?
if [ "$POS_RC" -eq 0 ] \
   && printf '%s' "$POS_OUT" | grep -q "PROCEEDED rc=0" \
   && printf '%s' "$POS_OUT" | grep -q "bash=$WORK/bash5"; then
  pass "P0a: under zsh with a bash>=4 present, the resolver PROCEEDS (rc 0) and publishes UBERDEV_GOAL_BASH (no spurious exit 2 — the #294 fix)"
else
  fail "P0a: resolver did NOT proceed/publish under zsh (got rc=$POS_RC, out=[$POS_OUT]) — #294 regression?"
fi

# --- P0b NEGATIVE: no bash>=4 anywhere (only a bash3) -> exit 2 + brew directive.
RES_NEG="$WORK/resolver.neg.sh"
make_resolver_variant "$RES_NEG" "$WORK/bash3" "$WORK/none"
DRV_NEG="$WORK/drv_neg.zsh"
{
  echo 'set -u'
  echo 'command() { if [ "$1" = "-v" ] && [ "$2" = "bash" ]; then return 1; fi; builtin command "$@"; }'
  echo "source '$RES_NEG'"
  echo 'echo "DID-NOT-EXIT rc=$?"'
} > "$DRV_NEG"
NEG_OUT="$("$ZSH_BIN" -f "$DRV_NEG" 2>&1)"
NEG_RC=$?
if [ "$NEG_RC" -eq 2 ] && ! printf '%s' "$NEG_OUT" | grep -q 'DID-NOT-EXIT'; then
  pass "P0b: under zsh with NO bash>=4 reachable, the resolver hard-exits 2 (the genuine-dead-end case)"
else
  fail "P0b: resolver should exit 2 when no bash>=4 exists (got rc=$NEG_RC, out=[$NEG_OUT])"
fi
if printf '%s' "$NEG_OUT" | grep -q 'brew install bash'; then
  pass "P0c: the no-bash>=4 dead-end prints the brew-install remediation directive"
else
  fail "P0c: the exit-2 dead-end must print the 'brew install bash' directive (got: [$NEG_OUT])"
fi

# --- P0d: the bash>=4 ARM (already running bash>=4) is a no-op, not exit 2.
# Run the resolver fence under bash>=4 itself (HBASH) — arm (a) must short-
# circuit and the fence must NOT exit 2. This guards the `BASH_VERSINFO[0]>=4`
# short-circuit branch the zsh runs never take.
HBASH=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  m="$("$c" -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) continue ;; esac
  if [ "$m" -ge 4 ]; then HBASH="$c"; break; fi
done
if [ -n "$HBASH" ]; then
  DRV_A="$WORK/drv_arma.sh"
  { echo 'set -u'; echo "source '$RESOLVER_FENCE'"; echo 'echo "ARMA-OK rc=$?"'; } > "$DRV_A"
  ARMA_OUT="$("$HBASH" "$DRV_A" 2>&1)"
  ARMA_RC=$?
  if [ "$ARMA_RC" -eq 0 ] && printf '%s' "$ARMA_OUT" | grep -q 'ARMA-OK rc=0'; then
    pass "P0d: when already running bash>=4, the resolver short-circuits arm (a) — no exit 2 (got: [$ARMA_OUT])"
  else
    fail "P0d: resolver arm (a) (already bash>=4) should be a clean no-op (rc=$ARMA_RC, out=[$ARMA_OUT])"
  fi
else
  fail "P0d: no bash>=4 found on this host to exercise resolver arm (a) — install bash (brew install bash)"
fi

# --- P0e: arg-parse fence collects positional issue numbers + flags under the
# RESOLVED bash>=4 (the documented post-resolver execution contract).
# The parser's `for tok in $ARGUMENTS` relies on word-splitting — which bash
# does but zsh (SH_WORD_SPLIT=off) does NOT — so $ARGUMENTS arrives as ONE token
# under raw zsh. That is EXACTLY why Phase 0's #294 resolver publishes
# UBERDEV_GOAL_BASH and commands/goal.md directs the remaining fences to run
# under it: the arg-parse + watch fences are bash>=4 fences. So this assertion
# runs the EXTRACTED arg-parse fence under $HBASH (the resolved interpreter
# P0d discovered) and asserts numeric tokens land in `queue` + flags set their
# scalars — the parser the dry-run / dispatch paths depend on. (Running it under
# raw zsh would only re-prove the word-split gap, not the parser's correctness.)
ARGPARSE_FENCE="$WORK/argparse.fence.sh"
if extract_fence 'for tok in $ARGUMENTS' > "$ARGPARSE_FENCE" && [ -s "$ARGPARSE_FENCE" ]; then
  pass "P0e.extract: located the Phase-0 arg-parse fence in SKILL.md"
  if [ -n "$HBASH" ]; then
    DRV_AP="$WORK/drv_argparse.sh"
    {
      echo 'set -u'
      echo 'ARGUMENTS="101 --max-cycles=7 202 --only-mine --dry-run --backend=claude-bg 303"'
      echo "source '$ARGPARSE_FENCE'"
      echo 'echo "queue=[${queue[*]}] mc=[$max_cycles_cli] om=[$only_mine] dr=[$dry_run] be=[$backend_cli]"'
    } > "$DRV_AP"
    AP_OUT="$("$HBASH" "$DRV_AP" 2>&1)"
    AP_RC=$?
    if [ "$AP_RC" -eq 0 ] \
       && printf '%s' "$AP_OUT" | grep -q 'queue=\[101 202 303\]' \
       && printf '%s' "$AP_OUT" | grep -q 'mc=\[7\]' \
       && printf '%s' "$AP_OUT" | grep -q 'om=\[1\] dr=\[1\] be=\[claude-bg\]'; then
      pass "P0e: arg-parse fence under the resolved bash collects positional issues (101/202/303) + flags (got: $AP_OUT)"
    else
      fail "P0e: arg-parse fence mis-parsed under the resolved bash (rc=$AP_RC, out=[$AP_OUT])"
    fi
  else
    fail "P0e: no resolved bash>=4 available to run the arg-parse fence (see P0d)"
  fi
else
  fail "P0e.extract: could not extract the Phase-0 arg-parse fence (anchor 'for tok in \$ARGUMENTS' moved?)"
fi

# ==========================================================================
# P3 — Phase-3 terminal / convergence calc (#288).
#
# The convergence + queue-empty-not-converged gates are ALSO guarded on the
# rollover `queue` being EMPTY (issue #288 #1). With more issues than
# --max-parallel, Phase 1 defers the overflow into `queue`; those issues have
# no PR yet, so a clean cycle has new_candidates empty AND terminal_count ==
# all_pr_count even though work remains — without the `${#queue[@]} -eq 0`
# clause the goal FALSELY converges (or false-halts queue_empty_not_converged)
# while the overflow stays OPEN and never dispatched. We run the EXTRACTED
# terminal-check fence under zsh against a seeded pr-states.tsv, stubbing the
# rehydration + exit-side helpers (we set the loop scalars directly).
# ==========================================================================
echo
echo "== P3: Phase-3 terminal/convergence calc (#288) under zsh =="

TERMINAL_FENCE="$WORK/terminal.fence.sh"
if extract_fence 'Terminal set for convergence' > "$TERMINAL_FENCE" && [ -s "$TERMINAL_FENCE" ]; then
  pass "P3.extract: located the Phase-3 terminal/convergence fence in SKILL.md"
else
  fail "P3.extract: could NOT extract the terminal fence (anchor 'Terminal set for convergence' moved?)"
fi

# Driver template emitter: $1=goal-id $2=case(conv|queue|stuck|failed).
# Seeds the pr-states.tsv per case, then runs the extracted terminal fence.
write_term_driver() {  # $1=outfile $2=gid $3=case
  local out="$1" gid="$2" cs="$3"
  {
    echo 'set -u'
    echo "export UBERDEV_TMPDIR='$WORK/state'"
    echo "export GOAL_ID='$gid'"
    echo "export UBERDEV_GOAL_ID='$gid'"
    echo "PIPELINE_GOAL_CASE='$cs'"
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
    # Stub the fence's rehydration + terminal-exit side effects (the loop
    # scalars are set directly below; reaper/print/cleanup/write are not under
    # test here and would otherwise touch live state / fork agents).
    echo 'uberdev_goal_read_run_state() { return 0; }'
    echo 'uberdev_dispatch_resolve_env() { return 0; }'
    echo '_uberdev_goal_reap_zombies() { return 0; }'
    echo 'print_summary() { :; }'
    echo 'uberdev_goal_cleanup_run_state() { return 0; }'
    echo 'uberdev_goal_write_run_state() { return 0; }'
    echo 'cycle=1'
    echo 'MAX_CYCLES=5'
    echo 'new_candidates=()'
    echo 'watch_start="$(date +%s)"'
    case "$cs" in
      conv)  echo 'queue=()' ;;
      queue) echo 'queue=(777)' ;;   # #288 #1: a non-empty rollover must BLOCK convergence
      stuck) echo 'queue=()' ;;
      failed) echo 'queue=()' ;;
    esac
    echo "source '$TERMINAL_FENCE'"
    echo 'echo "FELL-THROUGH rc=$?"'
  } > "$out"
}

mkdir -p "$WORK/state" || { echo "FATAL: mkdir -p $WORK/state failed" >&2; exit 3; }
audit_for() { printf '%s' "$WORK/state/goal-$1.jsonl"; }

# --- P3a: rollover queue NON-EMPTY -> must NOT converge (issue #288 #1).
G_Q="pipequeue01"
printf '100\tmerged\t10\n200\tyellow-held\t20\n' > "$WORK/state/goal-$G_Q-pr-states.tsv"
: > "$(audit_for "$G_Q")"; : > "$WORK/state/goal-$G_Q-issue-states.tsv"
DRV_Q="$WORK/drv_term_queue.zsh"; write_term_driver "$DRV_Q" "$G_Q" queue
Q_OUT="$("$ZSH_BIN" -f "$DRV_Q" 2>&1)"
Q_RC=$?
if printf '%s' "$Q_OUT" | grep -q 'FELL-THROUGH rc=0' \
   && ! grep -q 'goal_converged' "$(audit_for "$G_Q")" 2>/dev/null \
   && grep -q 'goal_cycle_completed' "$(audit_for "$G_Q")" 2>/dev/null; then
  pass "P3a: with all PRs terminal BUT a non-empty rollover queue, the gate does NOT converge — it loops back (goal_cycle_completed). #288 #1"
else
  fail "P3a: non-empty rollover queue wrongly converged/halted (rc=$Q_RC, out=[$Q_OUT], audit=[$(tr -d '\n' < "$(audit_for "$G_Q")" 2>/dev/null)])"
fi

# --- P3b: queue EMPTY + all PRs terminal -> CONVERGE (goal_converged, exit 0).
G_C="pipeconv01"
printf '100\tmerged\t10\n200\tyellow-held\t20\n' > "$WORK/state/goal-$G_C-pr-states.tsv"
: > "$(audit_for "$G_C")"; : > "$WORK/state/goal-$G_C-issue-states.tsv"
DRV_C="$WORK/drv_term_conv.zsh"; write_term_driver "$DRV_C" "$G_C" conv
C_OUT="$("$ZSH_BIN" -f "$DRV_C" 2>&1)"
C_RC=$?
# The fence `exit 0`s on convergence, so the driver's FELL-THROUGH line is NOT
# printed and the zsh rc is 0.
if [ "$C_RC" -eq 0 ] \
   && ! printf '%s' "$C_OUT" | grep -q 'FELL-THROUGH' \
   && grep -q 'goal_converged' "$(audit_for "$G_C")" 2>/dev/null; then
  pass "P3b: queue empty + all PRs terminal (merged + held) -> goal_converged, exit 0"
else
  fail "P3b: convergence path wrong (rc=$C_RC, out=[$C_OUT], audit=[$(tr -d '\n' < "$(audit_for "$G_C")" 2>/dev/null)])"
fi

# --- P3c: queue empty + a NON-terminal PR -> queue_empty_not_converged, exit 1.
G_S="pipestuck01"
printf '100\tpushed-reviewing\t10\n' > "$WORK/state/goal-$G_S-pr-states.tsv"
: > "$(audit_for "$G_S")"; : > "$WORK/state/goal-$G_S-issue-states.tsv"
DRV_S="$WORK/drv_term_stuck.zsh"; write_term_driver "$DRV_S" "$G_S" stuck
S_OUT="$("$ZSH_BIN" -f "$DRV_S" 2>&1)"
S_RC=$?
if [ "$S_RC" -eq 1 ] \
   && grep -q 'queue_empty_not_converged' "$(audit_for "$G_S")" 2>/dev/null \
   && ! grep -q 'goal_converged' "$(audit_for "$G_S")" 2>/dev/null; then
  pass "P3c: queue empty + a PR still pushed-reviewing -> queue_empty_not_converged, exit 1 (deterministic pre-empt of the 4h stuck_loop)"
else
  fail "P3c: stuck-but-drained path wrong (rc=$S_RC, out=[$S_OUT], audit=[$(tr -d '\n' < "$(audit_for "$G_S")" 2>/dev/null)])"
fi

# --- P3d: queue empty + no PRs + a failed issue -> solver_failed, exit 1.
G_F="pipefailed01"
: > "$WORK/state/goal-$G_F-pr-states.tsv"
printf '4242\tfailed\t10\n' > "$WORK/state/goal-$G_F-issue-states.tsv"
: > "$(audit_for "$G_F")"
DRV_F="$WORK/drv_term_failed.zsh"; write_term_driver "$DRV_F" "$G_F" failed
F_OUT="$("$ZSH_BIN" -f "$DRV_F" 2>&1)"
F_RC=$?
if [ "$F_RC" -eq 1 ] \
   && grep -q 'solver_failed' "$(audit_for "$G_F")" 2>/dev/null \
   && ! grep -q 'goal_converged' "$(audit_for "$G_F")" 2>/dev/null; then
  pass "P3d: failed solver issue halts with solver_failed before convergence, exit 1"
else
  fail "P3d: failed solver issue did not halt before convergence (rc=$F_RC, out=[$F_OUT], audit=[$(tr -d '\n' < "$(audit_for "$G_F")" 2>/dev/null)])"
fi

# ==========================================================================
# W — One watch-loop iteration: the step-2b verdict read (#270 / #290.2).
#
# The watch loop's verdict locator (uberdev_goal_locate_review_pr_audit_by_pr ->
# _uberdev_goal_glob_worktree) iterates worktree-prefix globs that carry a `*`.
# bash glob-expands a var-derived `*`; zsh does NOT unless flagged `${~pat}`
# (GLOB_SUBST). Since the watch fence runs under /bin/zsh, the pre-fix bare
# `${prefix}` form silently matched NOTHING for the worktree-mirror prefixes —
# so a /review-pr verdict written into a worktree mirror (the normal /goal
# layout: each solver runs in its own .claude/worktrees/<wt>/ checkout) was
# NEVER discovered, and the held/green transition never fired. We seed a GREEN
# verdict in a WORKTREE-MIRROR path and run the EXTRACTED step-2b loop verbatim
# under zsh; the PR must transition pushed-reviewing -> green. Reverting
# _uberdev_goal_glob_worktree to the bare `$pat` form makes this RED (the
# verdict is invisible -> signal stays missing -> no transition).
# ==========================================================================
echo
echo "== W: watch-loop step-2b verdict read — verdict-locator glob under zsh (#270/#290.2) =="

STEP2B_SLICE="$WORK/step2b.slice.sh"
if slice_fence 'for pr_num in $(uberdev_goal_list_prs_in_state "$GOAL_ID" pushed-reviewing)' \
               '2c. Barrier-gated merge dispatch' > "$STEP2B_SLICE" \
   && [ -s "$STEP2B_SLICE" ] && grep -q 'uberdev_goal_locate_review_pr_audit_by_pr' "$STEP2B_SLICE" \
   && grep -qE '^[[:space:]]*done' "$STEP2B_SLICE"; then
  pass "W.extract: sliced the step-2b verdict-read loop (incl. the verdict locator call + a loop-closing 'done' — guards a head-only partial slice) from the watch fence"
else
  fail "W.extract: could NOT slice the step-2b loop (loop head / step-2c marker moved?)"
fi

# Build a worktree-rooted sandbox: state dir under it, and a GREEN verdict in a
# .claude/worktrees/<wt>/.uberdev/runs/<run-id>/ mirror (NOT the cwd-root path —
# the cwd-root prefix is the one bare-`$pat` would still find, so seeding the
# verdict ONLY in a mirror is what makes this discriminate the fix from the bug).
WT_ROOT="$WORK/wt-root"
WT_STATE="$WT_ROOT/state"
WT_VERDICT_DIR="$WT_ROOT/.claude/worktrees/wt-A/.uberdev/runs/20260529-140000-cafe01"
mkdir -p "$WT_STATE" "$WT_VERDICT_DIR" || { echo "FATAL: mkdir -p worktree-mirror sandbox ($WT_VERDICT_DIR) failed" >&2; exit 3; }
printf '%s\n' '{"pr":200,"sha":"cafe01","phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}' \
  > "$WT_VERDICT_DIR/review-pr-verdict.json"

W_GID="pipewatch01"
DRV_W="$WORK/drv_watch.zsh"
{
  echo 'set -u'
  echo "cd '$WT_ROOT' || exit 9"
  echo "export UBERDEV_TMPDIR='$WT_STATE'"
  echo "export GOAL_ID='$W_GID'"
  echo "export UBERDEV_GOAL_ID='$W_GID'"
  echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
  # gh stub: headRefOid (read by read_trust_signal's #290.1 SHA-binding) matches
  # the seeded verdict sha, so the verdict binds and the colour is honoured.
  echo 'gh() { case "$1 $2" in "pr view") printf "cafe01\n" ;; *) return 0 ;; esac }'
  echo "uberdev_goal_state_init '$W_GID' >/dev/null 2>&1"
  echo "uberdev_goal_pr_state_transition '$W_GID' 200 dispatched pushed-reviewing >/dev/null 2>&1"
  # Scalars the loop body references on its NON-green arms (harmless on the green
  # path we exercise, but keep the loop set -u-clean if a future SKILL.md edit
  # reorders the case arms).
  echo 'now="$(date +%s)"'
  echo 'any_active=0'
  echo 'REVIEW_GRACE_SECS=3600'
  echo 'overflow_detected=0'
  echo 'overflow_count=0'
  echo 'echo "pre=[$(uberdev_goal_get_pr_state '"$W_GID"' 200)]"'
  echo "source '$STEP2B_SLICE'"
  echo 'echo "post=[$(uberdev_goal_get_pr_state '"$W_GID"' 200)]"'
} > "$DRV_W"

W_OUT="$("$ZSH_BIN" -f "$DRV_W" 2>"$WORK/watch.err")"
W_RC=$?
W_ERR="$(cat "$WORK/watch.err" 2>/dev/null)"
if [ "$W_RC" -eq 0 ] \
   && printf '%s' "$W_OUT" | grep -q 'pre=\[pushed-reviewing\]' \
   && printf '%s' "$W_OUT" | grep -q 'post=\[green\]'; then
  pass "W: the step-2b loop runs under zsh; the verdict locator finds the WORKTREE-MIRROR verdict and transitions pushed-reviewing -> green (no fatal). #270/#290.2"
else
  fail "W: step-2b loop did NOT reach green under zsh (rc=$W_RC, out=[$W_OUT], err=[$W_ERR]) — verdict-locator glob regression?"
fi
# The unmatched worktree-prefix globs must NOT have fataled the loop under zsh
# (the `no matches found` NOMATCH failure mode the lib's `nonomatch`/`${~pat}`
# guard prevents). Assert no such fatal leaked to stderr.
if printf '%s' "$W_ERR" | grep -qi 'no matches found'; then
  fail "W.nomatch: a zsh 'no matches found' fatal leaked from the verdict-locator glob (the #270/#290.2 nonomatch guard regressed)"
else
  pass "W.nomatch: no zsh 'no matches found' fatal from the verdict-locator glob"
fi

# ==========================================================================
# W2 — Phase-2 bounded-watch EXIT-CODE CONTRACT, executed (#299 finding 2).
#
# Finding-2's load-bearing behaviour is the exit code the watch loop returns so
# an orchestrating harness (the 600s-capped Bash tool) can drive it tick-by-tick:
#   exit 42 = bound (passes/budget) hit while work is STILL in flight -> re-invoke
#   exit  0 = step-2f DRAINED (no active agents AND no merging PR)    -> Phase 3
#   break   = the UNBOUNDED loop drains -> flow inline into Phase 3 (no exit)
# and a hard guarantee: the reaper does NOT fire on a bounded-tick pause (only on
# a circuit-breaker halt or a real INT/TERM), so the bg solver agents survive the
# paused tick. Until now this was asserted ONLY by STRUCTURAL grep of SKILL.md
# (goal-state-zsh.test.sh Z11b/Z11c grep for the `bounded-tick exit 42/0`
# breadcrumb STRINGS) — a regression that flipped the exit-0/exit-42 ARMS keeps
# both breadcrumb strings present (they live on separate lines from the `exit N`)
# and ships GREEN. This test EXECUTES the real arms under zsh and asserts the
# ACTUAL exit codes + the reaper-skip, so an arm-flip goes RED.
#
# Slicing discipline (mirrors the `W` step-2b slice above): the watch fence is a
# ~595-line `while true; do … done`; running it whole would mean mocking ~30
# step-2a..2e helpers (brittle, off-target). Instead slice the TWO load-bearing
# fragments verbatim from SKILL.md —
#   (A) the per-fence bound SETUP block (`_tick_start`/`_tick_passes`/the
#       `_watch_bounded` derivation from WATCH_PASSES/WATCH_BUDGET), and
#   (B) the step-2f drain check + the pass/budget gate + the trailing `sleep`
#       (the EXACT exit-42 / exit-0 / break arms — the mutation target) —
# then stitch them into a controllable single-iteration `while true` whose ONLY
# free inputs are `any_active` (which steps 2a-2e set in production; we set it
# directly) and the merging-PR list (seeded empty via state_init). This runs the
# production exit-code logic byte-for-byte; nothing about the arms is re-typed.
#
# Mocking choices (each isolates the exit-code contract, none fakes it):
#   - any_active is the loop's drain signal; set per scenario (the real 2a-2e
#     walk would compute it from gh/agent state we are deliberately not exercising
#     here — 2a-2e correctness is the `W` test's job, not W2's).
#   - uberdev_goal_write_run_state is stubbed to rc 0 so a tmpdir/write hiccup
#     cannot muddy the exit-code assertion (the bound's run-state ROUND-TRIP is
#     already proven by goal-state-zsh.test.sh Z11a).
#   - _uberdev_goal_reap_zombies is stubbed to TOUCH a sentinel so we can assert
#     it is NOT called on the exit-42/exit-0 pause (W2c) — and a positive control
#     (W2e) calls the stub directly to prove the sentinel mechanism works.
#   - sleep is stubbed to exit 77: the bounded arms exit (42/0) BEFORE the sleep,
#     so reaching sleep means the bound gate FAILED to fire (caught as rc 77, not
#     a 60s hang); the unbounded drain `break`s before sleep too.
#
# Mutation guards (revert in your worktree, re-run -> the named assertion goes RED):
#   - SWAP the two arms in SKILL.md's step 2f / budget gate (`exit 42`<->`exit 0`)
#     => W2a flips to rc 0 and W2b flips to rc 42 (both RED). This is the exact
#     regression Z11b/Z11c (grep-only) cannot see.
#   - Move `_uberdev_goal_reap_zombies` INTO the bounded exit-42 path (reap-on-
#     pause regression) => W2c RED (sentinel PRESENT after the 42 path).
#   - Drop the `[ "$_watch_bounded" = "1" ]` guard on the 2f bounded arm, or the
#     WATCH_PASSES/WATCH_BUDGET `-gt 0` derivation in the setup block
#     => W2d RED (the unbounded loop would exit 0/42 mid-fence instead of break).
# ==========================================================================
echo
echo "== W2: Phase-2 bounded-watch exit-code contract (42/0/break + reaper-skip) under zsh (#299 finding 2) =="

# (A) the bound SETUP fragment: `_tick_start` .. the `_watch_bounded=1` line. The
# slice deliberately STOPS before the closing `fi` (its own line carries no
# unique anchor); the driver appends `fi` so the `if` closes in the SAME parse
# unit (production runs setup + loop in one fence — inlining matches that).
W2_SETUP="$WORK/w2_setup.frag.sh"
# (B) the step-2f drain + pass/budget gate + trailing `sleep` — the real arms.
W2_GATE="$WORK/w2_gate.frag.sh"
if slice_fence '_tick_start="$(date' '_watch_bounded=1' > "$W2_SETUP" \
   && [ -s "$W2_SETUP" ] && grep -q 'WATCH_PASSES' "$W2_SETUP" && grep -q 'WATCH_BUDGET' "$W2_SETUP"; then
  pass "W2.extractA: sliced the per-fence bounded-watch SETUP block (_tick_start + _watch_bounded derivation) from the watch fence"
else
  fail "W2.extractA: could NOT slice the bounded-watch setup block (anchor '_tick_start=' / '_watch_bounded=1' moved?)"
fi
if slice_fence '2f. Termination check' 'sleep "$_UBERDEV_GOAL_POLL_SECS"' > "$W2_GATE" \
   && [ -s "$W2_GATE" ] \
   && grep -q 'bounded-tick exit 42' "$W2_GATE" \
   && grep -q 'bounded-tick exit 0'  "$W2_GATE" \
   && grep -qE '^[[:space:]]*exit 42[[:space:]]*$' "$W2_GATE" \
   && grep -qE '^[[:space:]]*exit 0[[:space:]]*$'  "$W2_GATE"; then
  pass "W2.extractB: sliced the step-2f drain check + pass/budget gate (both real 'exit 42' and 'exit 0' arms present — guards a head-only partial slice) from the watch fence"
else
  fail "W2.extractB: could NOT slice the step-2f/budget gate with BOTH exit arms (step-2f marker / sleep tail / an 'exit N' arm moved?)"
fi

# Emit one bounded-watch driver. $1=outfile $2=tag $3=WATCH_PASSES $4=WATCH_BUDGET
# $5=any_active. Stitches: lib source + state_init (so the 2f `merging` probe is
# set -u-clean and empty) + the stubs above + Slice A (+`fi`) + a single-iteration
# `while true` carrying the controlled any_active + Slice B verbatim. A reaper
# sentinel path is exported per driver so W2c can assert non-firing.
write_w2_driver() {  # $1=out $2=tag $3=passes $4=budget $5=any_active
  local out="$1" tag="$2" wp="$3" wb="$4" aa="$5"
  {
    echo 'set -u'
    echo "export UBERDEV_TMPDIR='$WORK/w2-state-$tag'"
    echo "export GOAL_ID='pipew2$tag'"
    echo "export UBERDEV_GOAL_ID='pipew2$tag'"
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh\""
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
    echo "uberdev_goal_state_init 'pipew2$tag' >/dev/null 2>&1"
    # Reaper sentinel: the stub TOUCHES it; the exit-42/exit-0 pause must NOT.
    echo "W2_REAPER_SENTINEL='$WORK/w2-reaper-$tag'"
    echo '_uberdev_goal_reap_zombies() { echo fired > "$W2_REAPER_SENTINEL"; }'
    # Isolate the exit-code contract from run-state I/O (Z11a proves the bound's
    # run-state round-trip; here a write hiccup must not muddy the rc assertion).
    echo 'uberdev_goal_write_run_state() { return 0; }'
    # If the loop reaches `sleep`, the bound gate FAILED to exit — surface it as
    # rc 77 (not a 60s hang). Bounded arms exit 42/0 BEFORE sleep; unbounded drain
    # `break`s before it.
    echo 'sleep() { echo "W2-REACHED-SLEEP arg=$1"; exit 77; }'
    echo "WATCH_PASSES=$wp"
    echo "WATCH_BUDGET=$wb"
    # --- Slice A (bounded-watch setup) verbatim, then the closing fi it omits.
    cat "$W2_SETUP"
    echo 'fi'
    # --- One controlled iteration carrying the real Slice B arms verbatim.
    echo 'while true; do'
    echo "  any_active=$aa"
    cat "$W2_GATE"
    echo 'done'
    # Reached ONLY if Slice B `break`s out (the unbounded-drain path).
    echo 'echo "W2-FELL-THROUGH rc=$?"'
  } > "$out"
}

w2_sentinel_state() {  # $1=tag -> PRESENT|ABSENT
  [ -f "$WORK/w2-reaper-$1" ] && printf 'PRESENT' || printf 'ABSENT'
}

# --- W2a: BOUND HIT, work in flight -> exit 42 (+ no reaper). WATCH_PASSES=1,
# any_active=1 (a solver still working) so step 2f does NOT drain; one pass
# completes, _tick_passes(1) >= WATCH_PASSES(1) -> _bound_hit -> exit 42.
DRV_W2A="$WORK/drv_w2a.zsh"; write_w2_driver "$DRV_W2A" a 1 0 1
W2A_OUT="$("$ZSH_BIN" -f "$DRV_W2A" 2>&1)"; W2A_RC=$?
if [ "$W2A_RC" -eq 42 ] && printf '%s' "$W2A_OUT" | grep -q 'bounded-tick exit 42'; then
  pass "W2a: bounded (WATCH_PASSES=1) + work in flight -> the watch fence EXITS 42 and prints the 'bounded-tick exit 42' breadcrumb (#299 finding 2)"
else
  fail "W2a: expected exit 42 + 'bounded-tick exit 42' breadcrumb (got rc=$W2A_RC, out=[$W2A_OUT]) — exit-code-arm regression?"
fi
# W2c (part 1): the reaper must NOT have fired on the exit-42 pause.
if [ "$(w2_sentinel_state a)" = "ABSENT" ]; then
  pass "W2c: reaper did NOT fire on the bounded exit-42 pause (bg solver agents survive the tick) — #299 finding 2 guarantee"
else
  fail "W2c: reaper FIRED on the bounded exit-42 pause (sentinel PRESENT) — reap-on-pause regression"
fi

# --- W2b: DRAINED -> exit 0. WATCH_PASSES=1 (bounded) but any_active=0 AND no
# merging PR (state_init left the pr-states TSV empty), so step 2f's bounded arm
# persists + exits 0 BEFORE the pass/budget gate is reached.
DRV_W2B="$WORK/drv_w2b.zsh"; write_w2_driver "$DRV_W2B" b 1 0 0
W2B_OUT="$("$ZSH_BIN" -f "$DRV_W2B" 2>&1)"; W2B_RC=$?
if [ "$W2B_RC" -eq 0 ] && printf '%s' "$W2B_OUT" | grep -q 'bounded-tick exit 0'; then
  pass "W2b: bounded + DRAINED (no active agents, no merging PR) -> the watch fence EXITS 0 and prints the 'bounded-tick exit 0' breadcrumb (#299 finding 2)"
else
  fail "W2b: expected exit 0 + 'bounded-tick exit 0' breadcrumb (got rc=$W2B_RC, out=[$W2B_OUT]) — exit-code-arm regression?"
fi
# W2c (part 2): reaper must NOT fire on the clean exit-0 drain either.
if [ "$(w2_sentinel_state b)" = "ABSENT" ]; then
  pass "W2c.drain: reaper did NOT fire on the bounded exit-0 drain (clean proceed-to-Phase-3 path)"
else
  fail "W2c.drain: reaper FIRED on the bounded exit-0 drain (sentinel PRESENT) — reap-on-drain regression"
fi

# --- W2d: UNBOUNDED -> no early exit. WATCH_PASSES=0 WATCH_BUDGET=0 so
# _watch_bounded=0; drained step 2f takes the legacy `break` (NOT exit 0/42) and
# control flows past the loop to the FELL-THROUGH breadcrumb (= inline Phase 3).
DRV_W2D="$WORK/drv_w2d.zsh"; write_w2_driver "$DRV_W2D" d 0 0 0
W2D_OUT="$("$ZSH_BIN" -f "$DRV_W2D" 2>&1)"; W2D_RC=$?
if [ "$W2D_RC" -eq 0 ] \
   && printf '%s' "$W2D_OUT" | grep -q 'W2-FELL-THROUGH' \
   && ! printf '%s' "$W2D_OUT" | grep -q 'bounded-tick exit' \
   && ! printf '%s' "$W2D_OUT" | grep -q 'W2-REACHED-SLEEP'; then
  pass "W2d: unbounded (WATCH_PASSES=0 WATCH_BUDGET=0) + drained -> step 2f BREAKS into inline Phase 3 (no mid-fence exit 0/42, no sleep) (#299 finding 2)"
else
  fail "W2d: unbounded drain should break (FELL-THROUGH, no 'bounded-tick exit', no sleep); got rc=$W2D_RC, out=[$W2D_OUT]"
fi

# --- W2.budget: the BUDGET bound (not pass count) also fires exit 42. POLL=60s is
# always added to the elapsed budget check, so WATCH_BUDGET=1 trips on pass 1 even
# with WATCH_PASSES=0 — proving the wall-clock arm of the bound, independent of
# the pass-count arm exercised by W2a.
DRV_W2BU="$WORK/drv_w2bu.zsh"; write_w2_driver "$DRV_W2BU" bu 0 1 1
W2BU_OUT="$("$ZSH_BIN" -f "$DRV_W2BU" 2>&1)"; W2BU_RC=$?
if [ "$W2BU_RC" -eq 42 ] && printf '%s' "$W2BU_OUT" | grep -q 'bounded-tick exit 42'; then
  pass "W2.budget: bounded by WATCH_BUDGET (wall-clock arm, WATCH_PASSES=0) + work in flight -> exit 42 (the budget gate fires, not just the pass-count gate)"
else
  fail "W2.budget: expected exit 42 from the budget arm (got rc=$W2BU_RC, out=[$W2BU_OUT]) — budget-gate regression?"
fi

# --- W2e: positive control — the reaper STUB itself writes the sentinel when
# CALLED. Without this, an always-broken stub would make W2c pass vacuously
# (sentinel never written for ANY reason). This proves W2c's ABSENT assertions
# mean "not called", not "stub is a no-op".
W2E_OUT="$("$ZSH_BIN" -f -c "
  W2_REAPER_SENTINEL='$WORK/w2-reaper-e'
  _uberdev_goal_reap_zombies() { echo fired > \"\$W2_REAPER_SENTINEL\"; }
  _uberdev_goal_reap_zombies
" 2>&1)"
if [ -f "$WORK/w2-reaper-e" ]; then
  pass "W2e: positive control — the reaper sentinel stub DOES write when invoked (so W2c's ABSENT means 'reaper not called', not 'stub is inert')"
else
  fail "W2e: reaper sentinel stub failed to write even when called directly (out=[$W2E_OUT]) — W2c would be a vacuous pass"
fi

# --- W2f: #300 Fix B (silent-failure-hunter CRITICAL) — a run-state FLUSH
# FAILURE at a bounded exit boundary must FAIL LOUD (exit 1 + 'run-state flush
# FAILED' breadcrumb), NOT degrade to a warning and still exit 42/0. write_run_state
# persists the SOURCE-OF-TRUTH run-state (cycle/queue/active_issues + the WATCH_*
# bound); if a failed flush still exit-42'd, the harness would re-invoke a fresh
# Phase-2 fence that rehydrates WATCH_*=0 -> the loop SILENTLY reverts to unbounded
# (then the 600s harness cap SIGTERMs it). So the boundary halts (exit 1) instead.
#
# Harness: bespoke driver mirroring write_w2_driver's slice assembly (cat $W2_SETUP
# + the closing `fi` it omits + an any_active line + cat $W2_GATE), but with two
# mutations: (1) uberdev_goal_write_run_state is stubbed to RETURN 1 (the flush
# failure under test); (2) a reaper sentinel stub proves the exit-1 fail-loud path
# does NOT reap (bg solver agents must survive a transient persist blip — the
# fail-loud halt is DISTINCT from a circuit-breaker exit 1 which reaps first).
# sleep is stubbed to exit 77 so a regression that falls through to the sleep is
# caught (the bounded arm must exit BEFORE sleep). list_prs_in_state is stubbed
# empty so the drain predicate is driven purely by $5 (any_active).
#
# MUTATION GUARD: revert EITHER bounded boundary's `if ! uberdev_goal_write_run_state;
# then ... exit 1; fi` back to the old `uberdev_goal_write_run_state || echo warning`
# form and W2f flips RED — the tick variant trips W2f.tick (rc 42 instead of 1), the
# drain variant trips W2f.drain (rc 0 instead of 1). This is the exact silent-revert-
# to-unbounded / proceed-on-unpersisted-state regression #300 Fix B closes.
echo "== W2f: bounded-watch run-state FLUSH FAILURE fails loud (exit 1, no reap) under zsh (#300 Fix B) =="

write_w2f_driver() {  # $1=out $2=tag $3=passes $4=budget $5=any_active
  local out="$1" tag="$2" wp="$3" wb="$4" act="$5"
  {
    echo '#!/usr/bin/env zsh'
    echo 'set -u'
    echo "UBERDEV_TMPDIR='$WORK'"
    echo 'GOAL_ID=w2f'
    echo '_UBERDEV_GOAL_POLL_SECS=60'
    # (1) the flush failure under test: write_run_state returns rc 1.
    echo 'uberdev_goal_write_run_state() { return 1; }'
    # (2) reaper sentinel — assert it does NOT fire on the fail-loud exit-1 path.
    echo "W2F_REAPER_SENTINEL='$WORK/w2f-reaper-$tag'"
    echo '_uberdev_goal_reap_zombies() { echo fired > "$W2F_REAPER_SENTINEL"; }'
    # drain predicate is driven purely by $act; merging set is always empty.
    echo 'uberdev_goal_list_prs_in_state() { :; }'
    # sleep must never be reached (bounded arm exits first).
    echo 'sleep() { echo "W2F-REACHED-SLEEP"; exit 77; }'
    echo "WATCH_PASSES=$wp"
    echo "WATCH_BUDGET=$wb"
    cat "$W2_SETUP"; echo 'fi'        # Slice A + the closing fi it omits.
    echo "any_active=$act"
    cat "$W2_GATE"                    # Slice B (step-2f drain + pass/budget gate).
    echo 'echo "W2F-FELL-THROUGH rc=$?"'
  } > "$out"
}

# W2f.tick: bounded (WATCH_PASSES=1) + work in flight -> pass-count bound hit ->
# flush fails -> EXIT 1 (NOT 42), 'run-state flush FAILED' breadcrumb, NO reaper.
DRV_W2FT="$WORK/drv_w2f_tick.zsh"; write_w2f_driver "$DRV_W2FT" tick 1 0 1
W2FT_OUT="$("$ZSH_BIN" -f "$DRV_W2FT" 2>&1)"; W2FT_RC=$?
if [ "$W2FT_RC" -eq 1 ] && printf '%s' "$W2FT_OUT" | grep -q 'run-state flush FAILED'; then
  pass "W2f.tick: bounded + work in flight + flush FAILS at the pass/budget bound -> the fence EXITS 1 (not 42) and prints the 'run-state flush FAILED' ERROR breadcrumb (#300 Fix B)"
else
  fail "W2f.tick: expected exit 1 + 'run-state flush FAILED' (got rc=$W2FT_RC, out=[$W2FT_OUT]) — a failed flush must NOT silently revert to unbounded via exit 42"
fi
if [ ! -f "$WORK/w2f-reaper-tick" ]; then
  pass "W2f.tick.noreap: the fail-loud exit-1 flush-halt did NOT reap (bg solver agents survive a transient persist blip — distinct from a circuit-breaker exit 1)"
else
  fail "W2f.tick.noreap: reaper FIRED on the fail-loud flush-halt (sentinel PRESENT) — Fix B must NOT reap on this path"
fi

# W2f.drain: bounded + DRAINED (any_active=0, merging empty) + flush FAILS at the
# step-2f drain boundary -> EXIT 1 (NOT 0), same breadcrumb. Cheap second arm.
DRV_W2FD="$WORK/drv_w2f_drain.zsh"; write_w2f_driver "$DRV_W2FD" drain 1 0 0
W2FD_OUT="$("$ZSH_BIN" -f "$DRV_W2FD" 2>&1)"; W2FD_RC=$?
if [ "$W2FD_RC" -eq 1 ] && printf '%s' "$W2FD_OUT" | grep -q 'run-state flush FAILED'; then
  pass "W2f.drain: bounded + drained + flush FAILS at the drain boundary -> the fence EXITS 1 (not 0); never proceeds to Phase 3 on unpersisted state (#300 Fix B)"
else
  fail "W2f.drain: expected exit 1 + 'run-state flush FAILED' (got rc=$W2FD_RC, out=[$W2FD_OUT]) — a failed drain flush must NOT proceed via exit 0"
fi

# ==========================================================================
# W3 — Phase-2 Codex malformed-status fail-closed (#329 review).
#
# The no-PR branch asks `uberdev_goal_codex_status_for_issue` whether the Codex
# solver wrapper has reached a terminal state. A malformed status JSON is not
# equivalent to "no status yet": it is a corrupted/unknown terminal signal and
# must be surfaced immediately. The regression this catches was
# `2>/dev/null || true`, which normalized parser/schema failures to empty state
# and then fell through to the generic solve timeout path.
# ==========================================================================
echo "== W3: Codex malformed solver status is surfaced, not swallowed (#329 review) =="

W3_STEP2A="$WORK/w3_step2a.slice.sh"
if slice_fence '_uberdev_goal_phase2_release_claim() {' '2b. Read the leaf /review-pr verdict' > "$W3_STEP2A" \
   && [ -s "$W3_STEP2A" ] \
   && grep -q 'uberdev_goal_codex_status_for_issue' "$W3_STEP2A" \
   && grep -q '_uberdev_goal_phase2_release_claim "$issue" "invalid_status"' "$W3_STEP2A" \
   && grep -qE '^[[:space:]]*done' "$W3_STEP2A"; then
  pass "W3.extract: sliced the step-2a no-PR solver-status loop from the watch fence"
else
  fail "W3.extract: could NOT slice the step-2a loop (loop head / step-2b marker moved?)"
fi

W3_STATE="$WORK/w3-state"
mkdir -p "$W3_STATE" || { echo "FATAL: mkdir -p $W3_STATE failed" >&2; exit 3; }
printf '{bad json\n' > "$W3_STATE/solve-codex-status-42.json"
DRV_W3="$WORK/drv_w3.zsh"
{
  echo 'set -u'
  echo "export UBERDEV_TMPDIR='$W3_STATE'"
  echo "export GOAL_ID='pipew3'"
  echo "export UBERDEV_GOAL_ID='pipew3'"
  echo 'export UBERDEV_RESOLVED_BACKEND=codex'
  echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh\""
  echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
  echo 'active_issues=(42)'
  echo 'now="$(date +%s)"'
  echo 'cycle=1'
  echo 'any_active=0'
  echo '_UBERDEV_GOAL_SOLVE_TIMEOUT=3600'
  echo 'uberdev_goal_get_issue_state() { printf "solving"; }'
  echo 'uberdev_goal_find_pr_for_issue() { :; }'
  echo 'uberdev_goal_gh_failure_count() { printf "0"; }'
  echo 'uberdev_goal_agent_busy_for_issue() { return 1; }'
  echo 'uberdev_goal_issue_ts_in_state() { printf "%s" "$now"; }'
  echo 'uberdev_goal_issue_state_transition() { echo "$2:$3->$4" > "$UBERDEV_TMPDIR/w3-transition"; return 0; }'
  echo 'uberdev_goal_audit() { printf "%s %s\n" "$1" "$2" >> "$UBERDEV_TMPDIR/w3-audit"; }'
  echo '_uberdev_goal_reap_zombies() { echo reaped > "$UBERDEV_TMPDIR/w3-reaped"; }'
  echo 'print_summary() { :; }'
  echo 'gh() { case "$1 $2" in "issue view") printf "OPEN";; "issue edit") printf "edit denied\n" >&2; return 9;; *) return 0;; esac; }'
  echo "source '$W3_STEP2A'"
  echo 'echo "W3-FELL-THROUGH any_active=$any_active"'
} > "$DRV_W3"

W3_OUT="$("$ZSH_BIN" -f "$DRV_W3" 2>"$WORK/w3.err")"; W3_RC=$?
W3_ERR="$(cat "$WORK/w3.err" 2>/dev/null)"
if [ "$W3_RC" -eq 1 ] \
   && printf '%s' "$W3_ERR" | grep -q 'invalid Codex status for issue 42' \
   && printf '%s' "$W3_ERR" | grep -q 'release uberdev:active claim failed for issue 42' \
   && printf '%s' "$W3_ERR" | grep -q 'edit denied' \
   && grep -q '"reason":"solver_failed"' "$W3_STATE/w3-audit" 2>/dev/null \
   && grep -q '"state":"invalid_status"' "$W3_STATE/w3-audit" 2>/dev/null \
   && grep -q '42:solving->failed' "$W3_STATE/w3-transition" 2>/dev/null; then
  pass "W3: malformed Codex status file fails closed with diagnostic, release breadcrumb, failed transition, and solver_failed audit"
else
  fail "W3: malformed Codex status should fail closed with release breadcrumb (rc=$W3_RC, out=[$W3_OUT], err=[$W3_ERR], audit=[$(cat "$W3_STATE/w3-audit" 2>/dev/null)], transition=[$(cat "$W3_STATE/w3-transition" 2>/dev/null)])"
fi

echo
echo "== Summary =="
echo "  harness shell: $LAUNCH_SHELL"
echo "  fence shell:   $ZSH_BIN"
echo "  $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]

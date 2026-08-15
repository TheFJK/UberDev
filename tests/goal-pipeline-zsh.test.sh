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

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"
export CLAUDE_PLUGIN_ROOT
GOAL_SKILL="$CLAUDE_PLUGIN_ROOT/skills/goal-pipeline/SKILL.md"
GOAL_LIB="$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"
DISPATCH_LIB="$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"
# RFC 0015 §5 — the orchestration body moved OUT of the SKILL.md bash fences
# into these four scripts. That is a straight WIN for this fixture: it used to
# slice markdown, and it now slices real shell files that a human can also run.
# The zsh runs below are still the point — lib/goal-phase0.sh's resolver is
# reached before any interpreter has been resolved, so it must survive zsh; and
# the watch script's verdict-locator globs are the #270/#290.2 class.
GOAL_P0="$CLAUDE_PLUGIN_ROOT/lib/goal-phase0.sh"
GOAL_P1="$CLAUDE_PLUGIN_ROOT/lib/goal-phase1.sh"
GOAL_WATCH="$CLAUDE_PLUGIN_ROOT/lib/goal-watch.sh"
GOAL_P3="$CLAUDE_PLUGIN_ROOT/lib/goal-phase3.sh"

for f in "$GOAL_SKILL" "$GOAL_LIB" "$DISPATCH_LIB" "$GOAL_P0" "$GOAL_P1" "$GOAL_WATCH" "$GOAL_P3"; do
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
# Region / slice extractors over the PHASE SCRIPTS (RFC 0015 §5). The fence
# extractors these replaced had to understand ```bash blocks and their 3-space
# markdown indentation; the phase scripts are plain shell, so the machinery
# gets simpler and the extracted text is byte-identical to what actually runs.
#
# extract_region NAME FILE — print the body between `# >>> region: NAME` and
#                            `# <<< region: NAME`. The phase scripts carry those
#                            markers precisely so ONE block can run standalone.
# slice_file S E FILE      — print the lines from the line containing S through
#                            the line containing E (inclusive); used to pull one
#                            loop out of the ~900-line watch script.
# Both exit 3 (-> caller fails the test) when the anchor is not found, so an
# edit that removes/renames an anchored block fails LOUD here.
# --------------------------------------------------------------------------
EXTRACT_AWK="$WORK/extract.awk"
cat > "$EXTRACT_AWK" <<'AWK'
BEGIN { inregion=0; found=0 }
{
  line=$0
  if (inregion==0) {
    if (line ~ ("^[[:space:]]*# >>> region: " NAME "[[:space:]]*$")) { inregion=1; found=1; next }
    next
  }
  if (line ~ ("^[[:space:]]*# <<< region: " NAME "[[:space:]]*$")) { exit }
  print line
}
END { if (found==0) exit 3 }
AWK

SLICE_AWK="$WORK/slice.awk"
cat > "$SLICE_AWK" <<'AWK'
BEGIN { emitting=0; found=0 }
{
  line=$0
  if (emitting==0 && index(line, SANCHOR) > 0) emitting=1
  if (emitting==1) { print line; if (index(line, EANCHOR) > 0) { found=1; exit } }
}
END { if (found==0) exit 3 }
AWK

extract_region() { awk -v NAME="$1" -f "$EXTRACT_AWK" "$2"; }
slice_file()     { awk -v SANCHOR="$1" -v EANCHOR="$2" -f "$SLICE_AWK" "$3"; }

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
if extract_region bash4-resolver "$GOAL_P0" > "$RESOLVER_FENCE" && [ -s "$RESOLVER_FENCE" ]; then
  pass "P0.extract: located the #294 execution-contract resolver region in lib/goal-phase0.sh"
else
  fail "P0.extract: could NOT extract the resolver region (region marker 'bash4-resolver' moved/removed?)"
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
    || { echo "FATAL: resolver candidate-list substitution did not apply (lib/goal-phase0.sh anchor '/opt/homebrew/bin/bash /usr/local/bin/bash' drifted?)" >&2; exit 3; }
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
   && grep -q "PROCEEDED rc=0" <<<"$POS_OUT" \
   && grep -q "bash=$WORK/bash5" <<<"$POS_OUT"; then
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
if [ "$NEG_RC" -eq 2 ] && ! grep -q 'DID-NOT-EXIT' <<<"$NEG_OUT"; then
  pass "P0b: under zsh with NO bash>=4 reachable, the resolver hard-exits 2 (the genuine-dead-end case)"
else
  fail "P0b: resolver should exit 2 when no bash>=4 exists (got rc=$NEG_RC, out=[$NEG_OUT])"
fi
if grep -q 'brew install bash' <<<"$NEG_OUT"; then
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
  if [ "$ARMA_RC" -eq 0 ] && grep -q 'ARMA-OK rc=0' <<<"$ARMA_OUT"; then
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
if extract_region argparse "$GOAL_P0" > "$ARGPARSE_FENCE" && [ -s "$ARGPARSE_FENCE" ]; then
  pass "P0e.extract: located the Phase-0 arg-parse region in lib/goal-phase0.sh"
  if [ -n "$HBASH" ]; then
    DRV_AP="$WORK/drv_argparse.sh"
    {
      echo 'set -u'
      echo 'ARGUMENTS="101 --max-cycles=7 202 --only-mine --dry-run --backend=background 303"'
      echo "source '$ARGPARSE_FENCE'"
      echo 'echo "queue=[${queue[*]}] mc=[$max_cycles_cli] om=[$only_mine] dr=[$dry_run] be=[$backend_cli]"'
    } > "$DRV_AP"
    AP_OUT="$("$HBASH" "$DRV_AP" 2>&1)"
    AP_RC=$?
    if [ "$AP_RC" -eq 0 ] \
       && grep -q 'queue=\[101 202 303\]' <<<"$AP_OUT" \
       && grep -q 'mc=\[7\]' <<<"$AP_OUT" \
       && grep -q 'om=\[1\] dr=\[1\] be=\[background\]' <<<"$AP_OUT"; then
      pass "P0e: arg-parse fence under the resolved bash collects positional issues (101/202/303) + flags (got: $AP_OUT)"
    else
      fail "P0e: arg-parse fence mis-parsed under the resolved bash (rc=$AP_RC, out=[$AP_OUT])"
    fi
  else
    fail "P0e: no resolved bash>=4 available to run the arg-parse fence (see P0d)"
  fi
else
  fail "P0e.extract: could not extract the Phase-0 arg-parse region (region marker 'argparse' moved?)"
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
if extract_region terminal "$GOAL_P3" > "$TERMINAL_FENCE" && [ -s "$TERMINAL_FENCE" ] \
   && grep -q 'Terminal set for convergence' "$TERMINAL_FENCE"; then
  pass "P3.extract: located the Phase-3 terminal/convergence region in lib/goal-phase3.sh"
else
  fail "P3.extract: could NOT extract the terminal region (region marker 'terminal' moved, or the convergence block left it?)"
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
if grep -q 'FELL-THROUGH rc=0' <<<"$Q_OUT" \
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
   && ! grep -q 'FELL-THROUGH' <<<"$C_OUT" \
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
if slice_file 'for pr_num in $(uberdev_goal_list_prs_in_state "$GOAL_ID" pushed-reviewing)' \
              '2c. Barrier-gated merge dispatch' "$GOAL_WATCH" > "$STEP2B_SLICE" \
   && [ -s "$STEP2B_SLICE" ] && grep -q 'uberdev_goal_locate_review_pr_audit_by_pr' "$STEP2B_SLICE" \
   && grep -qE '^[[:space:]]*done' "$STEP2B_SLICE"; then
  pass "W.extract: sliced the step-2b verdict-read loop (incl. the verdict locator call + a loop-closing 'done' — guards a head-only partial slice) from the watch script"
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
# The canonical selector treats malformed PR/SHA identity as INDETERMINATE
# rather than absence (RFC 0005 B13), so `sha` must be a full 40-hex object
# name — an abbreviated one makes the candidate identity-unknown and the loop
# never reaches green. Mirrors the fixture shape in tests/goal.test.sh.
printf '%s\n' '{"pr":200,"sha":"cafe010000000000000000000000000000000000","base":{"sha":"dddddddddddddddddddddddddddddddddddddddd","ref":"main"},"phases":{"phase2_5":{"by_severity":{"blocker":0,"critical":0},"halted":false}}}' \
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
  echo 'gh() { case "$1 $2" in "pr view") printf "cafe010000000000000000000000000000000000\n" ;; *) return 0 ;; esac }'
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
   && grep -q 'pre=\[pushed-reviewing\]' <<<"$W_OUT" \
   && grep -q 'post=\[green\]' <<<"$W_OUT"; then
  pass "W: the step-2b loop runs under zsh; the verdict locator finds the WORKTREE-MIRROR verdict and transitions pushed-reviewing -> green (no fatal). #270/#290.2"
else
  fail "W: step-2b loop did NOT reach green under zsh (rc=$W_RC, out=[$W_OUT], err=[$W_ERR]) — verdict-locator glob regression?"
fi
# The unmatched worktree-prefix globs must NOT have fataled the loop under zsh
# (the `no matches found` NOMATCH failure mode the lib's `nonomatch`/`${~pat}`
# guard prevents). Assert no such fatal leaked to stderr.
if grep -qi 'no matches found' <<<"$W_ERR"; then
  fail "W.nomatch: a zsh 'no matches found' fatal leaked from the verdict-locator glob (the #270/#290.2 nonomatch guard regressed)"
else
  pass "W.nomatch: no zsh 'no matches found' fatal from the verdict-locator glob"
fi

# ==========================================================================
# W1b — step-2b splits INDETERMINATE out of the stale|missing lane (#348).
#
# `stale|missing` is the "no verdict has landed YET" lane and its entire
# recovery is "wait, then re-review". An INDETERMINATE discovery (the canonical
# selector found candidates it cannot rank) reached that lane too, so /goal
# re-reviewed — which adds another candidate and makes the tie worse — until the
# review-pr dispatch cap ran out, at which point the PR was red-held under the
# reason `dispatch_cap_exhausted`. That label points the operator at /review-pr
# dispatch, which is not where the problem is.
#
# Executed through the SAME sliced fence as W, under zsh, three times (the cap):
# the first two passes must NOT dispatch a review, and the third must red-hold
# with reason=verdict_indeterminate.
# ==========================================================================
echo
echo "== W1b: step-2b bounds INDETERMINATE separately from stale|missing (#348) =="
W1B_ROOT="$WORK/w1b-root"
W1B_STATE="$W1B_ROOT/state"
mkdir -p "$W1B_STATE" || { echo "FATAL: mkdir -p $W1B_STATE failed" >&2; exit 3; }
W1B_GID="pipeanom001"
DRV_W1B="$WORK/drv_anomaly.zsh"
{
  echo 'set -u'
  echo "cd '$W1B_ROOT' || exit 9"
  echo "export UBERDEV_TMPDIR='$W1B_STATE'"
  echo "export GOAL_ID='$W1B_GID'"
  echo "export UBERDEV_GOAL_ID='$W1B_GID'"
  echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
  # Selector reports INDETERMINATE (rc 2). No verdict is ever produced.
  echo 'discover_review_verdict_json() { return 2; }'
  echo 'review_verdict_discovery_state() { printf "indeterminate\n"; }'
  echo 'recapture_review_verdict_snapshot() { printf "MUST-NOT-BE-CALLED\n"; }'
  echo 'cleanup_review_verdict_snapshot() { return 0; }'
  echo 'gh() { return 0; }'
  # Tripwire: reaching the benign cascade would call one of these.
  echo '_uberdev_goal_dispatch_review_pr() { printf "REVIEW-DISPATCHED\n"; return 0; }'
  echo '_uberdev_goal_locked_marker_for_pr_fresh() { printf "MARKER-PROBED\n"; return 1; }'
  echo "uberdev_goal_state_init '$W1B_GID' >/dev/null 2>&1"
  echo "uberdev_goal_pr_state_transition '$W1B_GID' 300 dispatched pushed-reviewing >/dev/null 2>&1"
  echo 'now="$(date +%s)"'
  echo 'any_active=0'
  echo 'REVIEW_GRACE_SECS=3600'
  echo 'overflow_detected=0'
  echo 'overflow_count=0'
  echo 'made_transition=0'
  # Three passes = the default _UBERDEV_GOAL_MAX_VERDICT_ANOMALIES.
  echo 'for _pass in 1 2 3; do'
  echo "  source '$STEP2B_SLICE'"
  echo '  echo "pass=$_pass state=[$(uberdev_goal_get_pr_state '"$W1B_GID"' 300)]"'
  echo 'done'
} > "$DRV_W1B"

W1B_OUT="$("$ZSH_BIN" -f "$DRV_W1B" 2>"$WORK/anomaly.err")"
W1B_RC=$?
W1B_ERR="$(cat "$WORK/anomaly.err" 2>/dev/null)"
W1B_AUDIT="$W1B_STATE/goal-$W1B_GID.jsonl"
if [ "$W1B_RC" -eq 0 ] \
   && grep -q 'pass=1 state=\[pushed-reviewing\]' <<<"$W1B_OUT" \
   && grep -q 'pass=2 state=\[pushed-reviewing\]' <<<"$W1B_OUT" \
   && grep -q 'pass=3 state=\[red-held\]' <<<"$W1B_OUT"; then
  pass "W1b: an indeterminate verdict holds the PR for 2 passes, then red-holds on the 3rd (bounded, never unbounded) — #348"
else
  fail "W1b: indeterminate bound wrong (rc=$W1B_RC out=[$W1B_OUT] err=[$W1B_ERR]) — #348"
fi
# The assertion is on the CASCADE ENTRY, not just on the dispatch. `REVIEW-
# DISPATCHED` alone is a tautology: without the #348 split the benign cascade
# still short-circuits at its grace arm (now - seen_ts ≈ 0 < REVIEW_GRACE_SECS),
# so no review is dispatched on ANY of the three passes and the assertion passes
# with the fix reverted. The FIRST cascade probe — the fresh-marker check — is
# what actually discriminates: the #348 arm `continue`s before it, the pre-fix
# code walks straight into it. Trip on either marker.
if grep -qE 'REVIEW-DISPATCHED|MARKER-PROBED' <<<"$W1B_OUT$W1B_ERR"; then
  fail "W1b.no-rereview: step-2b entered the benign stale|missing cascade for an INDETERMINATE verdict (marker probe and/or /review-pr dispatch reached) — the indeterminate arm must short-circuit before it; re-reviewing cannot resolve a ranking tie (#348)"
else
  pass "W1b.no-rereview: the indeterminate arm short-circuits BEFORE the benign cascade — neither the marker probe nor a /review-pr dispatch is reached (#348)"
fi
if grep -q 'verdict_indeterminate' "$W1B_AUDIT" 2>/dev/null \
   && ! grep -q 'dispatch_cap_exhausted' "$W1B_AUDIT" 2>/dev/null; then
  pass "W1b.reason: the held audit row names verdict_indeterminate, not the misleading dispatch_cap_exhausted (#348)"
else
  fail "W1b.reason: expected reason=verdict_indeterminate in the audit (got: [$(tr -d '\n' < "$W1B_AUDIT" 2>/dev/null)]) — #348"
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
if slice_file '_tick_start="$(date' '_watch_bounded=1' "$GOAL_WATCH" > "$W2_SETUP" \
   && [ -s "$W2_SETUP" ] && grep -q 'WATCH_PASSES' "$W2_SETUP" && grep -q 'WATCH_BUDGET' "$W2_SETUP"; then
  pass "W2.extractA: sliced the per-fence bounded-watch SETUP block (_tick_start + _watch_bounded derivation) from the watch script"
else
  fail "W2.extractA: could NOT slice the bounded-watch setup block (anchor '_tick_start=' / '_watch_bounded=1' moved?)"
fi
if slice_file '2f. Termination check' 'sleep "$_UBERDEV_GOAL_POLL_SECS"' "$GOAL_WATCH" > "$W2_GATE" \
   && [ -s "$W2_GATE" ] \
   && grep -q 'bounded-tick exit 42' "$W2_GATE" \
   && grep -q 'bounded-tick exit 0'  "$W2_GATE" \
   && grep -qE '^[[:space:]]*exit 42[[:space:]]*$' "$W2_GATE" \
   && grep -qE '^[[:space:]]*exit 0[[:space:]]*$'  "$W2_GATE"; then
  pass "W2.extractB: sliced the step-2f drain check + pass/budget gate (both real 'exit 42' and 'exit 0' arms present — guards a head-only partial slice) from the watch script"
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
if [ "$W2A_RC" -eq 42 ] && grep -q 'bounded-tick exit 42' <<<"$W2A_OUT"; then
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
if [ "$W2B_RC" -eq 0 ] && grep -q 'bounded-tick exit 0' <<<"$W2B_OUT"; then
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
   && grep -q 'W2-FELL-THROUGH' <<<"$W2D_OUT" \
   && ! grep -q 'bounded-tick exit' <<<"$W2D_OUT" \
   && ! grep -q 'W2-REACHED-SLEEP' <<<"$W2D_OUT"; then
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
if [ "$W2BU_RC" -eq 42 ] && grep -q 'bounded-tick exit 42' <<<"$W2BU_OUT"; then
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
if [ "$W2FT_RC" -eq 1 ] && grep -q 'run-state flush FAILED' <<<"$W2FT_OUT"; then
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
if [ "$W2FD_RC" -eq 1 ] && grep -q 'run-state flush FAILED' <<<"$W2FD_OUT"; then
  pass "W2f.drain: bounded + drained + flush FAILS at the drain boundary -> the fence EXITS 1 (not 0); never proceeds to Phase 3 on unpersisted state (#300 Fix B)"
else
  fail "W2f.drain: expected exit 1 + 'run-state flush FAILED' (got rc=$W2FD_RC, out=[$W2FD_OUT]) — a failed drain flush must NOT proceed via exit 0"
fi

# ==========================================================================
# W3 — RETIRED SURFACE (#381): the Phase-2 Codex malformed-status scenario.
#
# This drove the step-2a no-PR branch with a corrupt
# solve-codex-status-<ISSUE>.json and proved a malformed sidecar failed CLOSED
# (immediate solving->failed, release breadcrumb, solver_failed audit) instead
# of being normalized to "no status yet" and falling through to the 150-minute
# timeout -- the `2>/dev/null || true` regression from the #329 review.
#
# COVERAGE DELIBERATELY DROPPED: that fail-closed behaviour no longer has a
# subject. `uberdev_goal_codex_status_for_issue` was the only reader of the
# sidecar and is deleted from lib/goal-state.sh; the branch that called it is
# deleted from lib/goal-watch.sh; and UBERDEV_RESOLVED_BACKEND=codex -- the
# scenario's precondition -- is no longer producible, because `codex` is not in
# _UBERDEV_DISPATCH_BACKEND_ENUM (lib/dispatch.sh:509). `background` ships no
# equivalent sidecar and `workflow` reports through the runtime's structured
# return, so there is no malformed-status class left to fail closed on.
#
# What replaces it is the absence check: neither the reader nor its call site
# may come back, since a dormant sidecar reader is exactly how a retired status
# format drifts back onto a live path.
# ==========================================================================
# The step-2a no-PR loop is still sliced here: W3b/W3c below drive it. #381
# dropped only the `uberdev_goal_codex_status_for_issue` grep from this
# extraction guard, because that call site no longer exists in the slice.
W3_STEP2A="$WORK/w3_step2a.slice.sh"
if slice_file '_uberdev_goal_phase2_release_claim() {' '2b. Read the leaf /review-pr verdict' "$GOAL_WATCH" > "$W3_STEP2A" \
   && [ -s "$W3_STEP2A" ] \
   && grep -q 'gh issue view "$issue" --json state' "$W3_STEP2A" \
   && grep -qE '^[[:space:]]*done' "$W3_STEP2A"; then
  pass "W3.extract: sliced the step-2a no-PR solver-status loop from the watch script"
else
  fail "W3.extract: could NOT slice the step-2a loop (loop head / step-2b marker moved?)"
fi

echo "== W3: the Codex solver-status sidecar reader is gone (#381) =="
# Comment lines are excluded on purpose: both files keep a tombstone comment
# naming what was removed, and that documentation must not read as live code.
if ! grep -qE '^[^#]*uberdev_goal_codex_status_for_issue' "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh" "$GOAL_WATCH" \
   && ! grep -qE '^[^#]*solve-codex-status-' "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh" "$GOAL_WATCH"; then
  pass "W3: no Codex status-sidecar reader or call site survives in goal-state.sh / goal-watch.sh"
else
  fail "W3: a Codex status-sidecar reader or call site is still live (grep goal-state.sh / goal-watch.sh for uberdev_goal_codex_status_for_issue / solve-codex-status-)"
fi

# ==========================================================================
# W3b — RFC 0015 §5: with the fleet already settled, a no-PR issue is terminal
# NOW, not in 150 minutes.
#
# _UBERDEV_GOAL_SOLVE_TIMEOUT answers "is the DETACHED solver still working, or
# did it die?" — a question that only exists when the solver outlives the
# dispatcher. The Workflow-native fleet does not: the driver AWAITS its nested
# workflow() call, so by the time the watch script runs, every solver in the
# cycle has returned. Waiting out the 150-minute timeout there would burn the
# entire watch-tick budget proving something already known.
#
# Mutation guard: drop the UBERDEV_GOAL_SOLVERS_SETTLED arm from step 2a and
# W3b goes RED (any_active stays 1 and no failed transition is written), while
# W3c stays GREEN — proving the arm is gated on the env var, so an operator
# running lib/goal-watch.sh by hand keeps the timeout semantics.
# ==========================================================================
echo
echo "== W3b: a settled fleet makes a no-PR issue terminal immediately (RFC 0015 §5) =="

write_w3b_driver() {  # $1=outfile $2=state-dir $3=settled(0|1)
  local out="$1" sdir="$2" settled="$3"
  mkdir -p "$sdir" || { echo "FATAL: mkdir -p $sdir failed" >&2; exit 3; }
  {
    echo 'set -u'
    echo "export UBERDEV_TMPDIR='$sdir'"
    echo "export GOAL_ID='pipew3b'"
    echo "export UBERDEV_GOAL_ID='pipew3b'"
    echo "export UBERDEV_GOAL_SOLVERS_SETTLED=$settled"
    echo 'export UBERDEV_RESOLVED_BACKEND=workflow'
    echo '. "$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh"'
    echo '. "$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh"'
    echo 'active_issues=(77)'
    echo 'now="$(date +%s)"'
    echo 'cycle=1'
    echo 'any_active=0'
    echo '_UBERDEV_GOAL_SOLVE_TIMEOUT=9000'
    echo 'uberdev_goal_get_issue_state() { printf "solving"; }'
    echo 'uberdev_goal_pr_list_snapshot() { :; }'
    echo 'uberdev_goal_find_pr_for_issue_from_json() { :; }'
    echo 'uberdev_goal_gh_failure_count() { printf "0"; }'
    echo 'uberdev_goal_agent_busy_for_issue() { return 1; }'
    # The issue entered `solving` one second ago, so the 150m timeout has NOT
    # lapsed: any terminal transition here can only come from the settled arm.
    echo 'uberdev_goal_issue_ts_in_state() { printf "%s" "$(( now - 1 ))"; }'
    echo 'uberdev_goal_issue_state_transition() { echo "$2:$3->$4" >> "$UBERDEV_TMPDIR/w3b-transition"; return 0; }'
    echo 'uberdev_goal_audit() { printf "%s %s\n" "$1" "$2" >> "$UBERDEV_TMPDIR/w3b-audit"; }'
    echo '_uberdev_goal_reap_zombies() { return 0; }'
    echo 'print_summary() { :; }'
    echo 'gh() { case "$1 $2" in "issue view") printf "OPEN";; *) return 0;; esac; }'
    echo "source '$W3_STEP2A'"
    echo 'echo "W3B-DONE any_active=$any_active"'
  } > "$out"
}

W3B_SET="$WORK/w3b-settled"
DRV_W3B="$WORK/drv_w3b.zsh"; write_w3b_driver "$DRV_W3B" "$W3B_SET" 1
W3B_OUT="$("$ZSH_BIN" -f "$DRV_W3B" 2>&1)"
if grep -q 'W3B-DONE any_active=0' <<<"$W3B_OUT" \
   && grep -q '77:solving->failed' "$W3B_SET/w3b-transition" 2>/dev/null; then
  pass "W3b: with UBERDEV_GOAL_SOLVERS_SETTLED=1 a no-PR issue transitions solving->failed on the FIRST pass and does not hold any_active"
else
  fail "W3b: settled fleet did not terminalise the no-PR issue (out=[$W3B_OUT], transition=[$(cat "$W3B_SET/w3b-transition" 2>/dev/null)])"
fi

W3C_SET="$WORK/w3c-unsettled"
DRV_W3C="$WORK/drv_w3c.zsh"; write_w3b_driver "$DRV_W3C" "$W3C_SET" 0
W3C_OUT="$("$ZSH_BIN" -f "$DRV_W3C" 2>&1)"
if grep -q 'W3B-DONE any_active=1' <<<"$W3C_OUT" \
   && [ ! -s "$W3C_SET/w3b-transition" ]; then
  pass "W3c: WITHOUT the settled marker the same input keeps the issue active (the 150m detached-solver timeout still governs a hand-run watch)"
else
  fail "W3c: the settled arm is not gated on the env var (out=[$W3C_OUT], transition=[$(cat "$W3C_SET/w3b-transition" 2>/dev/null)])"
fi

# ==========================================================================
# W4 — step-2a per-pass PR snapshot: N resolutions, ONE fetch, and ZERO fetches
# when no issue needs one (#301 speedup finding 1).
#
# Two properties, and the SECOND is the load-bearing one:
#
#   (1) When k>0 active issues still need a PR number, the whole pass takes
#       exactly ONE `gh pr list` page and every issue is resolved against THAT
#       page (the pre-#301 code took k identical pages, and the k answers could
#       disagree mid-pass).
#   (2) When every active issue is already pr-pushed/terminal, the pass takes
#       ZERO pages. This is not a micro-optimisation: `uberdev_goal_pr_list_snapshot`
#       calls `_uberdev_goal_reset_gh_failure` on every healthy fetch, so a
#       snapshot taken UNCONDITIONALLY at the top of the pass resets the #290.3
#       consecutive-failure counter every 60s. In the reviewing/merging steady
#       state — where the only remaining gh traffic is 2c/2d `gh pr view` — that
#       pins the counter at 1 forever and the gh_api_failed breaker can NEVER
#       fire; /goal then rides the 4h stuck_loop instead of halting in ~5 min.
#
# Mutation guards (revert in your worktree, re-run -> the named assertion RED):
#   - Hoist `pr_snapshot="$(uberdev_goal_pr_list_snapshot)"` back above the
#     `for issue` loop (unconditional) => W4b RED (snap_calls=1, not 0).
#   - Go back to the per-issue live finder (uberdev_goal_find_pr_for_issue)
#     => W4a RED (snap_calls=0 and the LIVE-FINDER tripwire fires).
#   - Re-fetch per issue inside the loop => W4a RED (snap_calls=3, not 1).
# ==========================================================================
echo
echo "== W4: step-2a resolves N issues from ONE PR-list page — and none at all when nobody needs one (#301) =="

W4_SNAP='[{"number":501,"closingIssuesReferences":[{"number":41}],"headRefName":"feat/41-a"},
          {"number":502,"closingIssuesReferences":[{"number":42}],"headRefName":"feat/42-a"},
          {"number":503,"closingIssuesReferences":[{"number":43}],"headRefName":"feat/43-a"}]'

# $1=outfile $2=tag $3=issue state reported for all three active issues
write_w4_driver() {
  # Two statements, not one: zsh's `local` declares every name in the command
  # BEFORE assigning, so a `state_dir="…$tag"` in the same `local` reads an
  # unset $tag and aborts under set -u.
  local out="$1" tag="$2" istate="$3"
  local state_dir="$WORK/w4-state-$tag"
  mkdir -p "$state_dir" || { echo "FATAL: mkdir -p $state_dir failed" >&2; exit 3; }
  {
    echo 'set -u'
    echo "export UBERDEV_TMPDIR='$state_dir'"
    echo "export GOAL_ID='pipew4$tag'"
    echo "export UBERDEV_GOAL_ID='pipew4$tag'"
    echo 'export UBERDEV_RESOLVED_BACKEND=workflow'
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh\""
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
    echo "uberdev_goal_state_init 'pipew4$tag' >/dev/null 2>&1"
    echo 'active_issues=(41 42 43)'
    echo 'now="$(date +%s)"'
    echo 'cycle=1'
    echo 'any_active=0'
    echo 'made_transition=0'
    echo '_UBERDEV_GOAL_SOLVE_TIMEOUT=3600'
    echo "W4_SNAP='$W4_SNAP'"
    echo "uberdev_goal_get_issue_state() { printf '%s' '$istate'; }"
    # The fetch happens inside a command substitution (a SUBSHELL), so the call
    # tally has to live on disk — an in-memory counter would be lost every time.
    echo 'uberdev_goal_pr_list_snapshot() { printf "x" >> "$UBERDEV_TMPDIR/snap-calls"; printf "%s" "$W4_SNAP"; }'
    # Tripwire: the retired per-issue live finder must never be reached again.
    echo 'uberdev_goal_find_pr_for_issue() { printf "LIVE-FINDER-CALLED\n" >> "$UBERDEV_TMPDIR/w4-log"; printf "999"; }'
    echo 'uberdev_goal_gh_failure_count() { printf "0"; }'
    echo 'uberdev_goal_batch_has_pr() { return 1; }'
    echo 'uberdev_goal_register_batch_pr() { printf "resolved issue=%s pr=%s\n" "$3" "$2" >> "$UBERDEV_TMPDIR/w4-log"; return 0; }'
    echo 'uberdev_goal_issue_state_transition() { return 0; }'
    echo 'uberdev_goal_pr_state_transition() { return 0; }'
    echo 'uberdev_goal_pr_is_merged() { return 1; }'
    echo 'uberdev_goal_agent_busy_for_issue() { return 0; }'
    # Any real gh reach-through is a bug: record it so it cannot pass silently.
    echo 'gh() { printf "GH-CALLED %s\n" "$*" >> "$UBERDEV_TMPDIR/w4-log"; return 0; }'
    echo "source '$W3_STEP2A'"
    echo '_snap="$(cat "$UBERDEV_TMPDIR/snap-calls" 2>/dev/null)"'
    echo 'printf "snap_calls=%s any_active=%s\n" "${#_snap}" "$any_active"'
  } > "$out"
}

# --- W4a: three issues in `solving` all need a PR number -> ONE page, three
# resolutions off that page, live finder never touched.
DRV_W4A="$WORK/drv_w4a.zsh"; write_w4_driver "$DRV_W4A" a solving
W4A_OUT="$("$ZSH_BIN" -f "$DRV_W4A" 2>"$WORK/w4a.err")"; W4A_RC=$?
W4A_LOG="$(cat "$WORK/w4-state-a/w4-log" 2>/dev/null)"
if [ "$W4A_RC" -eq 0 ] \
   && grep -q 'snap_calls=1' <<<"$W4A_OUT" \
   && grep -q 'resolved issue=41 pr=501' <<<"$W4A_LOG" \
   && grep -q 'resolved issue=42 pr=502' <<<"$W4A_LOG" \
   && grep -q 'resolved issue=43 pr=503' <<<"$W4A_LOG"; then
  pass "W4a: three active issues resolve to their own PRs off exactly ONE gh pr list page (was one page per issue) — #301"
else
  fail "W4a: expected snap_calls=1 + all three issues resolved from that page (rc=$W4A_RC, out=[$W4A_OUT], log=[$W4A_LOG], err=[$(cat "$WORK/w4a.err" 2>/dev/null)])"
fi
if grep -qE 'LIVE-FINDER-CALLED|GH-CALLED' <<<"$W4A_LOG"; then
  fail "W4a.nolive: step-2a reached the retired per-issue live finder / a raw gh call instead of the per-pass snapshot (log=[$W4A_LOG]) — #301"
else
  pass "W4a.nolive: step-2a never touches the per-issue live finder or a raw gh call — the snapshot is the only PR-resolution route (#301)"
fi

# --- W4b: every active issue is already pr-pushed -> the loop `continue`s past
# all of them and the pass must take ZERO pages, so the #290.3 counter is free
# to accumulate the 2c/2d gh failures that are the only gh traffic left.
DRV_W4B="$WORK/drv_w4b.zsh"; write_w4_driver "$DRV_W4B" b pr-pushed
W4B_OUT="$("$ZSH_BIN" -f "$DRV_W4B" 2>"$WORK/w4b.err")"; W4B_RC=$?
W4B_LOG="$(cat "$WORK/w4-state-b/w4-log" 2>/dev/null)"
if [ "$W4B_RC" -eq 0 ] \
   && grep -q 'snap_calls=0' <<<"$W4B_OUT" \
   && [ -z "$W4B_LOG" ]; then
  pass "W4b: a pass in which every active issue is already pr-pushed issues ZERO gh pr list pages — so a healthy 'pr list' can never reset the #290.3 counter out from under a sustained 'pr view' outage (#301/#290.3)"
else
  fail "W4b: expected snap_calls=0 and no gh traffic for an all-pr-pushed pass (rc=$W4B_RC, out=[$W4B_OUT], log=[$W4B_LOG], err=[$(cat "$WORK/w4b.err" 2>/dev/null)]) — an UNCONDITIONAL snapshot defeats the gh_api_failed breaker"
fi

# ==========================================================================
# W5 — the made_transition fast path skips the poll sleep, and the consecutive
# bound stops it degenerating into a hot loop (#301 speedup finding 2).
#
# Steps run 2a…2f in a fixed order, so a transition applied in a later step is
# not consumed until the next pass; sleeping 60s first is dead latency. But an
# UNBOUNDED "transition => no sleep" rule is a gh-hammering hot loop the moment
# two PRs keep handing each other work. Both halves are behaviour, and both were
# untested — the gate lives in the watch fence, which no unit test executes.
#
# Reuses W2's Slice A (bound setup) + Slice B (2f drain + bound gate + trailing
# sleep) verbatim; only the loop-driving scalars are ours.
#
# Mutation guards (revert in your worktree, re-run -> the named assertion RED):
#   - Delete the `made_transition=1 && _fast_passes < MAX` continue gate
#     => W5a RED (7 sleeps instead of 1).
#   - Drop the `-lt "${_UBERDEV_GOAL_MAX_FAST_PASSES:-5}"` bound (unbounded fast
#     path) => W5a RED (0 sleeps — the hot loop).
#   - Make the gate fire regardless of made_transition => W5b RED (0 sleeps).
# ==========================================================================
echo
echo "== W5: made_transition fast path — bounded burst, then a real sleep (#301) =="

# $1=outfile $2=tag $3=made_transition value per pass $4=passes to run
write_w5_driver() {
  local out="$1" tag="$2" mt="$3" passes="$4"
  {
    echo 'set -u'
    echo "export UBERDEV_TMPDIR='$WORK/w5-state-$tag'"
    echo "export GOAL_ID='pipew5$tag'"
    echo "export UBERDEV_GOAL_ID='pipew5$tag'"
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/dispatch.sh\""
    echo ". \"\$CLAUDE_PLUGIN_ROOT/lib/goal-state.sh\""
    echo "uberdev_goal_state_init 'pipew5$tag' >/dev/null 2>&1"
    echo '_uberdev_goal_reap_zombies() { :; }'
    echo 'uberdev_goal_write_run_state() { return 0; }'
    # Counting sleep stub: same shell as the loop, so a plain counter is fine
    # (unlike W4's snapshot, this call is not inside a command substitution).
    echo 'W5_SLEEPS=0'
    echo 'sleep() { W5_SLEEPS=$(( W5_SLEEPS + 1 )); printf "SLEPT pass=%s\n" "$_iter"; }'
    echo 'WATCH_PASSES=0'   # unbounded watch: isolate the fast-path gate from
    echo 'WATCH_BUDGET=0'   # the #299 bounded-tick exits (W2 owns those).
    cat "$W2_SETUP"
    echo 'fi'
    echo '_iter=0'
    echo 'while true; do'
    echo '  _iter=$(( _iter + 1 ))'
    echo "  [ \"\$_iter\" -gt $passes ] && break"
    echo '  any_active=1'                 # never drains: 2f must fall through
    echo "  made_transition=$mt"
    cat "$W2_GATE"
    echo 'done'
    echo 'printf "passes=%s sleeps=%s fast_passes=%s\n" "$(( _iter - 1 ))" "$W5_SLEEPS" "${_fast_passes:-0}"'
  } > "$out"
}

# --- W5a: a transition on EVERY pass. Passes 1-5 skip the sleep, pass 6 hits
# the MAX_FAST_PASSES bound and sleeps (resetting the burst), pass 7 is fast
# again => exactly ONE sleep in seven passes.
DRV_W5A="$WORK/drv_w5a.zsh"; write_w5_driver "$DRV_W5A" a 1 7
W5A_OUT="$("$ZSH_BIN" -f "$DRV_W5A" 2>&1)"; W5A_RC=$?
if [ "$W5A_RC" -eq 0 ] \
   && grep -q 'passes=7 sleeps=1' <<<"$W5A_OUT" \
   && grep -q 'SLEPT pass=6' <<<"$W5A_OUT"; then
  pass "W5a: with a transition every pass, the first ${_UBERDEV_GOAL_MAX_FAST_PASSES:-5} passes skip the 60s sleep and the 6th sleeps anyway — fast path bounded, never a hot loop (#301)"
else
  fail "W5a: expected passes=7 sleeps=1 with the sleep landing on pass 6 (got rc=$W5A_RC, out=[$W5A_OUT]) — missing fast path (7 sleeps) or missing bound (0 sleeps)?"
fi

# --- W5b: no transition => the gate must NOT fire; every pass sleeps.
DRV_W5B="$WORK/drv_w5b.zsh"; write_w5_driver "$DRV_W5B" b 0 7
W5B_OUT="$("$ZSH_BIN" -f "$DRV_W5B" 2>&1)"; W5B_RC=$?
if [ "$W5B_RC" -eq 0 ] && grep -q 'passes=7 sleeps=7' <<<"$W5B_OUT"; then
  pass "W5b: a pass that moved NOTHING still sleeps the full poll interval — the fast path is gated on made_transition, not always-on (#301)"
else
  fail "W5b: expected passes=7 sleeps=7 when made_transition=0 (got rc=$W5B_RC, out=[$W5B_OUT]) — an always-on skip would hammer gh"
fi

# ==========================================================================
# PS — the post-Workflow summary fence, under the shell it actually runs in.
#
# This is the ONE executable block still living in skills/goal-pipeline/SKILL.md
# after the RFC 0015 §5 extraction, so it is the one block that still runs under
# the Claude-Code Bash tool's /bin/zsh rather than under a resolved bash>=4.
# It shipped gated on `[ -n "${UBERDEV_GOAL_ID:-}" ]` — an env var that
# lib/goal-phase0.sh exports inside its OWN child process, several Bash calls
# earlier — so the gate was never true and the operator summary was never
# printed. The fix is the standard unconditional rehydrate:
# uberdev_goal_read_run_state bootstraps GOAL_ID from the fixed-path
# goal-active-id.txt pointer.
#
# Mutation guard: re-introduce the `GOAL_ID="${UBERDEV_GOAL_ID:-}"` +
# `[ -n "$GOAL_ID" ]` gate => PSa RED (fence prints nothing).
# ==========================================================================
echo
echo "== PS: the post-Workflow summary fence under zsh =="

PS_FENCE="$WORK/summary.fence.sh"
awk '
  { sub(/\r$/, "") }   # CRLF-tolerant: a windows-latest checkout may carry \r,
                       # which would defeat every $-anchored match below AND
                       # make the extracted fence unrunnable.
  /^## Post-Workflow summary$/ { seen=1; next }
  seen && /^```bash$/          { cap=1; next }
  cap && /^```$/               { exit }
  cap                          { print }
' "$GOAL_SKILL" > "$PS_FENCE"
if [ -s "$PS_FENCE" ]; then
  pass "PS.extract: located the post-Workflow summary fence in skills/goal-pipeline/SKILL.md"

  PS_TMP="$WORK/ps-state"; mkdir -p "$PS_TMP"
  PS_ID="1700000077-pszshfence"
  # Seed a real run the way lib/goal-phase0.sh does — in its OWN process, so the
  # fence below inherits nothing but $UBERDEV_TMPDIR (exactly production).
  PS_SEED_RC=0
  UBERDEV_TMPDIR="$PS_TMP" "$ZSH_BIN" -f -c '
    . "'"$DISPATCH_LIB"'"
    . "'"$GOAL_LIB"'"
    GOAL_ID="'"$PS_ID"'"
    export UBERDEV_GOAL_ID="$GOAL_ID"
    uberdev_goal_state_init "$GOAL_ID" || exit 9
    cycle=4; watch_start="$(date +%s)"; MAX_CYCLES=5; MAX_PARALLEL=3
    queue=(); active_issues=()
    uberdev_goal_write_run_state || exit 9
  ' >/dev/null 2>&1 || PS_SEED_RC=$?
  if [ "$PS_SEED_RC" -eq 0 ]; then
    pass "PS.seed: run-state + goal-active-id.txt pointer written under zsh"
  else
    fail "PS.seed: could not seed run-state under zsh (rc=$PS_SEED_RC)"
  fi

  # THE ASSERTION: the fence, under zsh, with UBERDEV_GOAL_ID genuinely unset.
  PS_OUT="$(UBERDEV_TMPDIR="$PS_TMP" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
    "$ZSH_BIN" -f -c 'unset UBERDEV_GOAL_ID GOAL_ID; . "$1"' zsh "$PS_FENCE" 2>&1)"
  if grep -q "^goal $PS_ID: cycles=4/5 " <<<"$PS_OUT"; then
    pass "PSa: the fence rehydrates from goal-active-id.txt and prints the operator summary with UBERDEV_GOAL_ID unset (the production condition)"
  else
    fail "PSa: fence printed no summary under zsh — a UBERDEV_GOAL_ID gate makes it dead code (got: [$PS_OUT])"
  fi
  if grep -q "audit: .*goal-$PS_ID\.jsonl" <<<"$PS_OUT"; then
    pass "PSb: the fence names the audit log for the rehydrated id"
  else
    fail "PSb: audit path missing or unkeyed (got: [$PS_OUT])"
  fi
  # Non-vacuity control: no pointer => refuse loudly, print no summary.
  PS_EMPTY="$WORK/ps-empty"; mkdir -p "$PS_EMPTY"
  PS_NEG="$(UBERDEV_TMPDIR="$PS_EMPTY" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" \
    "$ZSH_BIN" -f -c 'unset UBERDEV_GOAL_ID GOAL_ID; . "$1"' zsh "$PS_FENCE" 2>&1)"
  if grep -q 'no run-state to summarise' <<<"$PS_NEG" && ! grep -q 'cycles=' <<<"$PS_NEG"; then
    pass "PSc: with no active-id pointer the fence refuses loudly and prints no summary (PSa is discriminating)"
  else
    fail "PSc: pointer-less run should refuse loudly and print nothing (got: [$PS_NEG])"
  fi
else
  fail "PS.extract: could NOT extract the post-Workflow summary fence (heading renamed?)"
fi

echo
echo "== Summary =="
echo "  harness shell: $LAUNCH_SHELL"
echo "  fence shell:   $ZSH_BIN"
echo "  $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]

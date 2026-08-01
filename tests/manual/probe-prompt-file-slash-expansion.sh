#!/usr/bin/env bash
# tests/manual/probe-prompt-file-slash-expansion.sh
# Wave 1 empirical probe for issue #240.
# Verifies whether `claude --bg --prompt-file <path>` re-evaluates the body
# through the interactive parser (slash-expansion fires).
# NOT wired into CI — requires real claude binary + live session quota.
#
# Writes verdict (PASS|FAIL|INDETERMINATE) to:
#   ${UBERDEV_TMPDIR:-/tmp}/issue-240-probe-verdict.txt
# Exit codes: 0=PASS, 1=FAIL, 2=INDETERMINATE, 3=CLI/setup failure.
#
# Observation surface: `claude agents --json` (canonical session-tracking
# pattern — see lib/goal-state.sh). Verified against claude-code 2.1.153:
# top-level subcommands are agents/auth/doctor/install/mcp/plugin/setup-token/
# update — there is no `claude logs` or `claude stop`, so the only way to
# observe a backgrounded session from outside is the `agents --json` listing
# (id / name / status fields).
#
# Verdict mapping:
#   PASS          — session `name` diverged from the short id AND is not the
#                   literal `/help` prompt body. Slash-expansion fired and
#                   set a new name from the expanded command (skill invoke
#                   description, Help-command label, etc.).
#   FAIL          — session `name` is set to the literal prompt body
#                   (`/help`) AND status is non-idle, i.e. the CLI is
#                   conversationally engaging with the literal text rather
#                   than expanding it.
#   INDETERMINATE — session `name` stayed equal to the short id throughout
#                   the 30s poll window (file body never reached any
#                   observable session-tracking surface — slash-expansion
#                   firing-vs-not is then ambiguous).
#
# Test payload: `/help` — chosen for recursion-safety. The original plan
# example used `/uberdev:orchestrator solve GH issue #N`, but that body
# would recursively dispatch another orchestrator pipeline if expansion
# fires. `/help` is a built-in Claude Code slash that produces a
# deterministic command surface when expanded and a conversational
# treatment when not — both signals are detectable from the `agents --json`
# name + status fields.
set -uo pipefail

VERDICT_FILE="${UBERDEV_TMPDIR:-/tmp}/issue-240-probe-verdict.txt"
# write_verdict: emit verdict to the documented file-based contract.
# Returns nonzero on write failure (disk-full / permission / read-only-FS) and
# emits a stderr diagnostic so the operator sees the failure mode — the
# file-based verdict is the primary output channel for this manual test,
# and a silent write failure would leave the operator without any signal.
write_verdict() {
  printf '%s' "$1" > "$VERDICT_FILE" || {
    printf 'probe: FAILED to write verdict file %s\n' "$VERDICT_FILE" >&2
    return 1
  }
}

PROBE_FILE="$(mktemp -t issue240-probe.XXXXXX)" || { write_verdict INDETERMINATE || true; exit 3; }
SESSION_ID=""
cleanup() {
  rm -f "$PROBE_FILE"
  # No in-CLI teardown exists; sessions idle out naturally. `claude stop` is
  # not a real subcommand on claude-code 2.1.153 (verified via `claude --help`).
}
trap cleanup EXIT

# Guard the /help body write — if the probe file cannot be populated, the
# downstream `claude --bg --prompt-file` invocation would run against an empty
# file and the SESSION_ID guard would catch only the symptom, not the root
# cause. Emit INDETERMINATE + stderr diagnostic + exit 3 (setup failure).
printf '/help\n' > "$PROBE_FILE" || {
  write_verdict INDETERMINATE || true
  printf 'probe: FAILED to write probe file %s\n' "$PROBE_FILE" >&2
  exit 3
}

probe_out="$(claude --bg --prompt-file "$PROBE_FILE" 2>&1)" || {
  write_verdict INDETERMINATE; exit 3;
}

# ANSI-strip portably. The previous `sed -E 's/\x1B\[…//g'` relied on GNU sed's
# `\xHH` escape, which BSD/macOS sed treats as the literal chars `x1B` — the ESC
# (0x1B) bytes then survived into the awk extraction, yielding an empty
# SESSION_ID and a spurious INDETERMINATE/exit-3 on the macOS operator's box.
# `tr -d '\033'` removes the ESC control byte on every platform (octal escape is
# POSIX tr); the residual CSI body (`[<params><final>`) is then stripped with a
# POSIX-portable sed that matches only literal `[`. Mirrors the canonical
# ANSI-strip contract in lib/dispatch.sh without the GNU-only escape.
SESSION_ID="$(printf '%s\n' "$probe_out" \
  | tr -d '\033' \
  | sed -E 's/\[[0-9;]*[a-zA-Z]//g' \
  | awk '/backgrounded · [0-9a-f]{8}/ { print $3; exit }')"
if [[ -z "$SESSION_ID" ]]; then
  write_verdict INDETERMINATE; exit 3
fi

deadline=$(( $(date +%s) + 30 ))
agent_row=""
while (( $(date +%s) < deadline )); do
  # Canonical session-observation pattern (see lib/goal-state.sh, which uses
  # `claude agents --json` at three sites to drive autonomous-loop state).
  # `claude agents --json` lists all live sessions; we filter by short-id
  # prefix and project the two fields that reflect slash-expansion outcome:
  # `name` (set from the opening message / expanded command) and `status`.
  agent_row="$(head -1 <<<"$(claude agents --json 2>/dev/null \
    | jq -r --arg sid "$SESSION_ID" \
        '.[] | select(.sessionId | startswith($sid)) | "name=\(.name) status=\(.status)"' \
        2>/dev/null)")"
  if [[ -z "$agent_row" ]]; then
    sleep 1
    continue
  fi
  # PASS: session name diverged from both the short id AND the literal /help
  # prompt body. Slash-expansion fired and produced an expansion-side name
  # (Help label, skill_invoke marker, command surface, etc.).
  if [[ "$agent_row" == name=*"Help"* \
     || "$agent_row" == name=*"help"*command* \
     || "$agent_row" == *skill_invoke* ]]; then
    write_verdict PASS || true
    printf 'AC1=PASS: slash-expansion fired (session %s, %s)\n' "$SESSION_ID" "$agent_row"
    exit 0
  fi
  # FAIL: session name = literal prompt body verbatim. The non-short-id guard
  # excludes the INDETERMINATE case where name simply equals the session id.
  if [[ "$agent_row" == "name=/help status="* \
     && "$agent_row" != "name=$SESSION_ID status="* ]]; then
    write_verdict FAIL || true
    printf 'AC1=FAIL: conversational echo (session %s, %s)\n' "$SESSION_ID" "$agent_row"
    exit 1
  fi
  sleep 1
done
# Poll exhausted: name field never diverged from short-id (or never populated).
# This is the genuine INDETERMINATE — the prompt-file body did not reach any
# observable session-tracking surface within the poll window, so slash-
# expansion firing-vs-not is unobservable from outside the session.
write_verdict INDETERMINATE || true
printf 'AC1=INDETERMINATE: 30s poll exhausted (session %s, last_row=%s)\n' "$SESSION_ID" "${agent_row:-<none>}"
exit 2

#!/usr/bin/env bash
# Tests/testers-agent-contract.test.sh
#
# Grep-based structural contract test for the /uberdev:testers agent fleet.
# Asserts every agent file under plugins/uberdev/agents/testers-*.md has:
#   - Canonical frontmatter (name, description, model, color)
#   - a `tools:` grant -- the key the agent LOADER honours -- that excludes
#     Edit and carries a write grant. (#749: `allowed-tools:` is the
#     SLASH-COMMAND key and is inert on an agent card.)
#   - A reference to the reviewer YAML contract (verdict / findings / confidence)
#   - At least one of the documented invariant IDs from invariants.yaml
#
# This test is intentionally grep-based (no agent execution) — same style as
# tests/aliases.test.sh and tests/audit-fixups.test.sh.

set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AGENT_DIR="plugins/uberdev/agents"
SKILL_DIR="plugins/uberdev/skills/testers-pipeline"
INVARIANTS="$SKILL_DIR/invariants.yaml"

EXPECTED_AGENTS=(
  testers-panicked-grandma
  testers-power-user
  testers-adversarial-security
  testers-chaos-engineer
  testers-a11y-critic
  testers-mobile-thumb
  testers-monitor-primary
  testers-monitor-devils-advocate
)

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# C1: invariants.yaml exists and has 10 invariants
[ -f "$INVARIANTS" ] || fail "C1: invariants.yaml missing at $INVARIANTS"
N="$(python3 -c "import yaml; print(len(yaml.safe_load(open('$INVARIANTS'))['invariants']))")"
[ "$N" = "10" ] || fail "C1: expected 10 invariants, got $N"
pass "C1: invariants.yaml has 10 entries"

# C2: skill SKILL.md exists and declares schema_version
[ -f "$SKILL_DIR/SKILL.md" ] || fail "C2: SKILL.md missing"
grep -q "schema_version: 1" "$SKILL_DIR/SKILL.md" || fail "C2: SKILL.md lacks schema_version: 1"
pass "C2: SKILL.md present and declares schema_version: 1"

# C3: command file exists and invokes testers-pipeline
[ -f "plugins/uberdev/commands/testers.md" ] || fail "C3: command file missing"
grep -q "uberdev:testers-pipeline" "plugins/uberdev/commands/testers.md" || fail "C3: command does not invoke uberdev:testers-pipeline"
pass "C3: command file invokes testers-pipeline"

# C4: each expected agent file exists with canonical frontmatter
for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  [ -f "$F" ] || fail "C4: $a missing"
  grep -q "^name: $a$" "$F" || fail "C4 $a: name line wrong"
  grep -q "^model: " "$F" || fail "C4 $a: model line missing"
  grep -q "^color: " "$F" || fail "C4 $a: color line missing"
done
pass "C4: all 8 agent files exist with canonical frontmatter"

# C5 (#749): the read-only ceiling is asserted against `tools:` -- the key the
# AGENT LOADER honours. The pre-#749 body read `allowed-tools:`, which is the
# SLASH-COMMAND frontmatter key: an agent card is not read for it, so all eight
# personas shipped with every tool granted while this row printed PASS. Both of
# its arms keyed on that literal string, so MOVING the declaration onto `tools:`
# did not fix the row, it finished emptying it -- the grep arm then matched
# nothing and the python arm did `if not m: sys.exit(0)`. Measured on this tree
# before the rewrite: a card with "Edit" injected into its `tools:` array passed
# the pre-#749 row completely clean.
#
# WHAT IS ASSERTED -- only what the runtime actually implements:
#   1. `tools:` is PRESENT        -- absent, the agent loader grants ALL tools
#   2. `allowed-tools:` is ABSENT -- the inert key must not come back, and a
#      half-migrated card carrying both is the likeliest way it would
#   3. no `Edit` token            -- THE ceiling. A `tools:` entry filters tool
#      NAMES, so striking a name off the roster is a real restriction.
#   4. a write grant IS present, in EITHER accepted spelling -- bare `Write` or
#      `Write(<anything>)`. These agents must write their findings file;
#      "read-only with respect to the audited target" is not the same property
#      as "needs no write tool", and denying the write would break the squad's
#      only evidence channel.
#
# WHAT IS DELIBERATELY *NOT* ASSERTED, and why asserting it would re-create the
# defect this row exists to remove: that a `Write(<pattern>)` pattern ADMITS the
# path the runtime hands a persona. A `tools:` entry filters tool NAMES; the
# text inside its parentheses is never matched against a filesystem path, so
# `Write(.uberdev/research/**)` and bare `Write` grant exactly the same thing.
# Nor is `Write(<path>)` a valid file-permission rule -- the runtime rejects the
# spelling verbatim: "is not matched by file permission checks -- only
# `Edit(path)` rules are." A guard asserting path admission would therefore be
# GREEN over a property the runtime does not have: a ceiling that is not a
# ceiling, which is this same vacuity class in a new costume. See the #749
# amendment in docs/rfc/0006-testers-command.md, "What the migration restores,
# and what it does not". Bare `Write` is consequently ACCEPTED here rather than
# rejected -- it is the shape every working live allowlist in this repo uses and
# it is semantically identical to the scoped spelling. The scoped spelling is
# pinned separately, as a CONVENTION and not as a ceiling, by C5c below.
#
# ONE definition of the predicate, driven below over the live cards AND over the
# synthetic mutants in C5b -- one function, two call sites. A transcribed second
# copy of the predicate would be a replica test: permanently green no matter
# what the live one does, which is strictly worse than no test at all.
c5_verdict() { # $1=full card text  $2=label ; rc 0 clean, rc 1 violation (reason on stderr)
  local c5_rc=0
  C5_TEXT="$1" C5_LABEL="$2" python3 - <<'PY' || c5_rc=$?
import os, re, sys

text, label = os.environ["C5_TEXT"], os.environ["C5_LABEL"]
# Distinct from 1 so a CRASHED predicate cannot masquerade as "rejected" and
# quietly turn every C5b reject row green. See the c5_rc case below.
VIOLATION = 9


def bad(reason):
    print(f"FAIL  C5 {label}: {reason}", file=sys.stderr)
    sys.exit(VIOLATION)


head = re.match(r'(?s)\A---\n(.*?)\n---(?:\n|\Z)', text)
if head is None:
    bad("no --- frontmatter block")
block = head.group(1)
if re.search(r'(?m)^allowed-tools:', block):
    bad("declares 'allowed-tools:' -- that is the SLASH-COMMAND key; an agent "
        "card is read for 'tools:', so this declaration is inert (#749)")
declared = re.search(r'(?m)^tools:[ \t]*(.+)$', block)
if declared is None:
    bad("no 'tools:' declaration -- the agent loader then grants ALL tools (#749)")
tokens = re.findall(r'[A-Za-z_]+(?:\([^)]*\))?', declared.group(1))
if any(t == 'Edit' or t.startswith('Edit(') for t in tokens):
    bad("forbidden 'Edit' in tools: -- tool-NAME filtering is the one ceiling an "
        "agent card can actually impose, and this contract spends it on Edit")
if not any(t == 'Write' or t.startswith('Write(') for t in tokens):
    bad("no write grant in tools: -- these agents must write their findings "
        "file, so the contract requires a write, not no write (#749)")
sys.exit(0)
PY
  case "$c5_rc" in
    0) return 0 ;;
    9) return 1 ;;
    *) fail "C5: harness error -- the predicate exited $c5_rc for '$2'. A predicate that CRASHED must never read as 'rejected'; that would make every C5b reject row vacuous" ;;
  esac
}

for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  c5_verdict "$(cat "$F")" "$a" || exit 1
done
pass "C5: all 8 agents declare tools: with no Edit and a write grant"

# C5b (#749) ANTI-VACUITY. C5 must be able to RED. Every mutant below is fed to
# the SAME c5_verdict function the live cards go through -- there is no second
# copy of the predicate to drift. A mutant that passes means the guard has
# stopped guarding.
#
# The ACCEPT rows are the opposite polarity and are not decoration: a predicate
# that rejects EVERYTHING is vacuous too, and rejecting everything is also what
# an interpreter error looks like from the outside.
c5_mutant() { # $1=name  $2=frontmatter line(s) under test -> a whole card text
  printf -- '---\nname: %s\nmodel: inherit\ncolor: blue\n%s\n---\n\nbody\n' "$1" "$2"
}
# Each reject row is a real regression, not an invented one:
#   no-tools-key    the state most agent cards in this repo are in -- all tools
#   legacy-key      the pre-#749 state of these eight cards
#   both-keys       a half-migrated card: `tools:` added, inert key not deleted
#   edit-grant      the ceiling breach itself
#   scoped-edit     the same breach wearing parentheses
#   no-write-grant  the over-correction that breaks the evidence channel
C5_REJECT_NAMES=( no-tools-key legacy-key both-keys edit-grant scoped-edit no-write-grant )
C5_REJECT_BODIES=(
  '# this card declares no tool key at all'
  'allowed-tools: ["Read", "Write(.uberdev/research/**)"]'
  'tools: ["Read", "Write(.uberdev/research/**)"]
allowed-tools: ["Read", "Write(.uberdev/research/**)"]'
  'tools: ["Read", "Edit", "Write(.uberdev/research/**)"]'
  'tools: ["Read", "Edit(.uberdev/research/**)", "Write"]'
  'tools: ["Read", "Grep"]'
)
# And each accept row states something C5 must NOT do:
#   good-live-shape   the shape the eight live cards carry
#   good-bare-write   bare `Write` is a valid grant here, never a violation
#   good-single-star  DECLARED BOUNDARY: C5 asserts no path-admission property,
#                     so a scope that would not cover the runtime path is still
#                     clean at THIS row. C5c is where that spelling is pinned.
C5_ACCEPT_NAMES=( good-live-shape good-bare-write good-single-star )
C5_ACCEPT_BODIES=(
  'tools: ["Read", "Write(.uberdev/research/**)"]'
  'tools: ["Read", "Write"]'
  'tools: ["Read", "Write(.uberdev/research/*)"]'
)
for c5_i in "${!C5_REJECT_NAMES[@]}"; do
  c5_name="${C5_REJECT_NAMES[$c5_i]}"
  if c5_verdict "$(c5_mutant "$c5_name" "${C5_REJECT_BODIES[$c5_i]}")" "mutant/$c5_name" 2>/dev/null; then
    fail "C5b: the C5 predicate ACCEPTED mutant '$c5_name' -- the guard cannot fail, which is the exact defect #749 found"
  fi
done
for c5_i in "${!C5_ACCEPT_NAMES[@]}"; do
  c5_name="${C5_ACCEPT_NAMES[$c5_i]}"
  c5_verdict "$(c5_mutant "$c5_name" "${C5_ACCEPT_BODIES[$c5_i]}")" "mutant/$c5_name" \
    || fail "C5b: the C5 predicate REJECTED known-good card '$c5_name' -- a predicate that rejects everything is vacuous in the other direction"
done
pass "C5b: the C5 predicate rejects all 6 mutants and accepts all 3 known-good cards"

# C5c (#749) CONVENTION, NOT A CEILING -- read the C5 header first. The text
# inside a `tools:` entry's parentheses binds NOTHING at runtime, so this row
# asserts nothing whatsoever about what a persona is able to write. What it does
# assert is that the eight cards keep SAYING the same thing about where they
# intend to write, so the roster cannot half-drift: wherever a write grant is
# spelled with a scope, that scope is the run-dir glob the pipeline actually
# uses. The single-segment `.uberdev/research/*` these cards shipped with does
# not cover the path the runtime hands a persona
# (`.uberdev/research/<RUN_ID>/testers/scratch/<persona>/out.yaml`, four
# segments deeper), so as DOCUMENTATION OF INTENT it was simply false; this row
# is what stops it coming back. A bare `Write` declares no scope and is exempt
# by construction, never by waiver.
C5_WRITE_SCOPE_CONVENTION='Write(.uberdev/research/**)'
c5_spelling() { # $1=full card text  $2=label ; rc 0 on-convention, rc 1 off
  local c5_rc=0
  C5_TEXT="$1" C5_LABEL="$2" C5_CONV="$C5_WRITE_SCOPE_CONVENTION" python3 - <<'PY' || c5_rc=$?
import os, re, sys

text, label = os.environ["C5_TEXT"], os.environ["C5_LABEL"]
canonical = os.environ["C5_CONV"]
VIOLATION = 9

head = re.match(r'(?s)\A---\n(.*?)\n---(?:\n|\Z)', text)
declared = re.search(r'(?m)^tools:[ \t]*(.+)$', head.group(1)) if head else None
if declared is None:
    print(f"FAIL  C5c {label}: no 'tools:' declaration to inspect", file=sys.stderr)
    sys.exit(VIOLATION)
scoped = re.findall(r'(?<![A-Za-z_])Write\([^)]*\)', declared.group(1))
off = [t for t in scoped if t != canonical]
if off:
    print(f"FAIL  C5c {label}: scoped write grant {off!r} is not the run-dir "
          f"convention '{canonical}'. This is documentation of intent, not a "
          f"runtime ceiling -- read the C5c header before changing either side.",
          file=sys.stderr)
    sys.exit(VIOLATION)
sys.exit(0)
PY
  case "$c5_rc" in
    0) return 0 ;;
    9) return 1 ;;
    *) fail "C5c: harness error -- the convention predicate exited $c5_rc for '$2'" ;;
  esac
}

for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  c5_spelling "$(cat "$F")" "$a" || exit 1
done
# Same anti-vacuity discipline as C5b, through the SAME c5_spelling function.
c5_spelling "$(c5_mutant conv-canonical "tools: [\"Read\", \"$C5_WRITE_SCOPE_CONVENTION\"]")" "mutant/conv-canonical" \
  || fail "C5c: the convention predicate REJECTED its own canonical spelling"
c5_spelling "$(c5_mutant conv-bare-write 'tools: ["Read", "Write"]')" "mutant/conv-bare-write" \
  || fail "C5c: the convention predicate REJECTED a bare Write grant, which declares no scope and is exempt by construction"
if c5_spelling "$(c5_mutant conv-single-star 'tools: ["Read", "Write(.uberdev/research/*)"]')" "mutant/conv-single-star" 2>/dev/null; then
  fail "C5c: the convention predicate ACCEPTED the pre-#749 single-segment scope -- it cannot fail"
fi
pass "C5c: all 8 scoped write grants carry the run-dir convention (documentation of intent, not a runtime ceiling)"

# C6: each persona references at least one invariant ID from invariants.yaml
INV_IDS="$(python3 -c "import yaml; [print(i['id']) for i in yaml.safe_load(open('$INVARIANTS'))['invariants']]")"
PERSONA_AGENTS=( testers-panicked-grandma testers-power-user testers-adversarial-security testers-chaos-engineer testers-a11y-critic testers-mobile-thumb )
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  FOUND=0
  while IFS= read -r id; do
    if grep -qE "\\b$id\\b" "$F"; then FOUND=1; break; fi
  done <<< "$INV_IDS"
  [ "$FOUND" = "1" ] || fail "C6 $a: references no invariant from invariants.yaml"
done
pass "C6: every persona references at least one invariant"

# C6b: every persona references the polite-rate-cap enforcement helper
# (uberdev_rate_limit_curl) AND uses audit-consequence framing.
# This is the structural counterpart to T2.3 (which edited the 6 persona files).
PERSONA_LIST=( adversarial-security a11y-critic chaos-engineer mobile-thumb panicked-grandma power-user )
c6b_count=0
for f in "${PERSONA_LIST[@]}"; do
  PFILE="$AGENT_DIR/testers-${f}.md"
  grep -q "uberdev_rate_limit_curl" "$PFILE" || fail "C6b: missing uberdev_rate_limit_curl ref in $f"
  grep -qE "polite_rate_cap|audit phase|rolling 1-second RPS" "$PFILE" || fail "C6b: missing audit-consequence ref in $f"
  c6b_count=$((c6b_count + 1))
done
[ "$c6b_count" -eq 6 ] || fail "C6b: expected 6 personas, got $c6b_count"
pass "C6b: polite-rate clause present in all 6 persona files"

# C7: each agent emits the reviewer YAML contract markers
for a in "${EXPECTED_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -q "verdict:" "$F" || fail "C7 $a: missing 'verdict:' in output contract"
  grep -q "findings:" "$F" || fail "C7 $a: missing 'findings:' in output contract"
  grep -q "confidence:" "$F" || fail "C7 $a: missing 'confidence:' in output contract"
done
pass "C7: all agents declare verdict / findings / confidence in their output contract"

# C8 (#306 / RFC 0012 §3.10, re-anchored at the Workflow migration): the
# never-worked master-dispatch mode is REMOVED, not guarded. lib/dispatch.sh
# never provided dispatch_master (public surface:
# uberdev_dispatch_preflight/_resolve_env/_one), so the documented default mode
# printed "dispatched master" with nothing running. The migration deletes the
# whole detached path: the Workflow runtime IS the background execution the
# master was for, and the No-Workflow fallback is the retained inline --watch
# directive recipe. This test now asserts the mode's ABSENCE (no dispatch_master
# call site anywhere in SKILL.md) and that the SKILL records the removal so a
# future re-introduction is a conscious, reviewed act.
SKILL_FILE="$SKILL_DIR/SKILL.md"
# No EXECUTABLE dispatch_master call site (the function-invocation form, e.g.
# `dispatch_master "$MASTER_PROMPT"` or a bare-word `dispatch_master ...`
# command). A backtick-quoted prose MENTION explaining the removal is allowed
# and expected — we only forbid a live call. The patterns below match an
# invocation: dispatch_master followed by a quote or by a non-backtick word,
# but NOT `dispatch_master` in inline-code backticks.
if [ -n "$(grep -nE 'dispatch_master[[:space:]]+("|\$|[A-Za-z./])' "$SKILL_FILE" | grep -vE '`dispatch_master`')" ]; then
  fail "C8: an executable dispatch_master call site remains in SKILL.md — the never-worked master mode is removed at the RFC 0012 migration, not re-guarded (#306 / §3.10)"
fi
grep -qE 'master.dispatch.+(remove|removed)|master-dispatch mode is .*remove' "$SKILL_FILE" \
  || fail "C8: SKILL.md must document that the master-dispatch mode is removed (No-Workflow fallback section, #306)"
grep -q '#306' "$SKILL_FILE" \
  || fail "C8: SKILL.md must reference #306 where it records the master-mode removal"
pass "C8: no live dispatch_master call site; the master-mode removal is documented (#306 / §3.10)"

# C8b (#306 / RFC 0012 §3.10): the Workflow path is mandated and the No-Workflow
# fallback is present — the migration's two-sided opt-in shape. workflow.js ships
# as the sibling; SKILL.md must carry the Workflow invocation block AND the
# fallback section (the carrier's §4.2 shape guard also enforces this, but
# anchoring it here keeps the testers contract self-describing).
[ -f "$SKILL_DIR/workflow.js" ] || fail "C8b: skills/testers-pipeline/workflow.js missing (the migrated Workflow script)"
grep -q 'Workflow(' "$SKILL_FILE" || fail "C8b: SKILL.md lacks the Workflow invocation block"
grep -qF 'workflow.js' "$SKILL_FILE" || fail "C8b: SKILL.md does not reference the workflow.js scriptPath"
grep -qF '## No-Workflow fallback' "$SKILL_FILE" || fail "C8b: SKILL.md lacks the '## No-Workflow fallback' section (DR-10)"
# The headline politeBreach exit-1 contract is stated at the post-Workflow seam.
grep -qiE 'exit 1|exit.1' "$SKILL_FILE" || fail "C8b: SKILL.md must state the politeBreach exit-1 mandate"
grep -q 'politeBreach' "$SKILL_FILE" || fail "C8b: SKILL.md must name the politeBreach return field (the fail-the-run signal)"
pass "C8b: Workflow path mandated, fallback present, politeBreach exit-1 contract stated"

# C9 (#306 / RFC 0012 testers-R3a): every persona's network_request evidence schema
# carries url + timestamp. lib/rate-cap-audit.sh silently skips rows lacking EITHER
# field (`if not url or not ts: continue`) — without these schema keys the personas
# never emit them and the polite-rate breach gate audits ~nothing.
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -q 'network_request:' "$F" || fail "C9 $a: missing network_request evidence block"
  grep -q 'url:' <<<"$(grep -A5 'network_request:' "$F")" \
    || fail "C9 $a: network_request block lacks url: (rate-cap audit skips the row)"
  grep -q 'timestamp:' <<<"$(grep -A5 'network_request:' "$F")" \
    || fail "C9 $a: network_request block lacks timestamp: (rate-cap audit skips the row)"
done
pass "C9: all 6 persona network_request schema blocks carry url + timestamp"

# C10 (#306 / RFC 0012 §3.10): the executable lib/rl-curl shim exists and the
# rate-limit invocation chain is allowlist-reachable end to end:
#   - shim is executable, bash-shebanged, sources the SSOT wrapper, and accepts
#     per-call --rate-state-dir= / --rps-cap= argv injection;
#   - every persona allowlist carries the Bash(*/lib/rl-curl*) pattern (the compound
#     export+source+uberdev_rate_limit_curl form matches no Bash() pattern);
#   - persona polite-rate blocks and the SKILL dispatch directive document the
#     per-call long-option form (Phase-0 fence exports never reach persona agents).
RLC="plugins/uberdev/lib/rl-curl"
[ -f "$RLC" ] || fail "C10: $RLC missing"
[ -x "$RLC" ] || fail "C10: $RLC is not executable (x-bit lost on checkout?)"
grep -q 'bash' <<<"$(head -1 "$RLC")" || fail "C10: $RLC must run under a bash shebang"
grep -q 'rate-limit-curl.sh' "$RLC" || fail "C10: shim does not source the SSOT wrapper rate-limit-curl.sh"
grep -q 'uberdev_rate_limit_curl' "$RLC" || fail "C10: shim does not call uberdev_rate_limit_curl"
grep -q -- '--rate-state-dir=' "$RLC" || fail "C10: shim lacks --rate-state-dir= argv injection"
grep -q -- '--rps-cap=' "$RLC" || fail "C10: shim lacks --rps-cap= argv injection"
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -qF 'Bash(*/lib/rl-curl*)' "$F" || fail "C10 $a: tools: lacks the Bash(*/lib/rl-curl*) pattern"
  grep -q -- '--rate-state-dir=' "$F" || fail "C10 $a: polite-rate block lacks the per-call --rate-state-dir= injection form"
done
grep -q 'lib/rl-curl' "$SKILL_FILE" || fail "C10: SKILL dispatch directive does not reference lib/rl-curl"
grep -q -- '--rate-state-dir=' "$SKILL_FILE" || fail "C10: SKILL dispatch directive lacks the per-call --rate-state-dir= injection form"
pass "C10: rl-curl shim, persona allowlists and per-call injection are consistent"

# C11 (RFC 0012 DR-3/DR-4): the Workflow dispatches every agent with an
# opts.schema and the agent's ## Output section must NAME the StructuredOutput
# return fields — otherwise the agent receives a YAML-by-prose contract that
# CONTRADICTS the schema it is forced through (the DR-4 prompt-tension class).
# The disk YAML stays the evidence channel (C7 keeps verdict/findings/confidence);
# this asserts the ADDED dual-channel stanza names the exact schema.* field set
# workflow.js sends (S.persona / S.monitorPrimary / S.monitorDA).
for a in "${PERSONA_AGENTS[@]}"; do
  F="$AGENT_DIR/$a.md"
  grep -q 'StructuredOutput' "$F" || fail "C11 $a: ## Output lacks the StructuredOutput dual-channel stanza (DR-4 prompt tension — the schema dispatch is undocumented)"
  for field in scratchPath findingCount; do
    grep -qF "$field" "$F" || fail "C11 $a: StructuredOutput stanza missing the '$field' schema field (S.persona)"
  done
  # The persona return field is `persona`; assert the stanza names it as a return field.
  grep -qE '`persona`' "$F" || fail "C11 $a: StructuredOutput stanza missing the 'persona' return field (S.persona)"
done
# monitor-primary: scratchPath + followUps (camelCase return) + verifiedAdded,
# AND the explicit reconciliation with the snake_case disk key.
MP="$AGENT_DIR/testers-monitor-primary.md"
grep -q 'StructuredOutput' "$MP" || fail "C11 monitor-primary: missing the StructuredOutput dual-channel stanza"
for field in scratchPath followUps verifiedAdded; do
  grep -qF "$field" "$MP" || fail "C11 monitor-primary: StructuredOutput stanza missing the '$field' schema field (S.monitorPrimary)"
done
# The camelCase return vs snake_case disk-key reconciliation must be explicit
# (both names present so the two channels are documented in lockstep).
grep -q 'follow_ups_for_next_wave' "$MP" \
  || fail "C11 monitor-primary: stanza does not reconcile the snake_case follow_ups_for_next_wave disk key with the camelCase followUps return"
# monitor-devils-advocate: scratchPath + rejected.
MDA="$AGENT_DIR/testers-monitor-devils-advocate.md"
grep -q 'StructuredOutput' "$MDA" || fail "C11 monitor-devils-advocate: missing the StructuredOutput dual-channel stanza"
for field in scratchPath rejected; do
  grep -qF "$field" "$MDA" || fail "C11 monitor-devils-advocate: StructuredOutput stanza missing the '$field' schema field (S.monitorDA)"
done
pass "C11: all 8 agents document the StructuredOutput dual-channel return matching the workflow schema (DR-4)"

echo "ALL TESTS PASS"

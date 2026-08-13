---
name: finish-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---
<!-- Vendored from obra/superpowers@e7a2d16476bf042e9add4699c9d018a90f86e4a6 (MIT) — see plugins/uberdev/licenses/superpowers-MIT.txt — the base this component was copied from and the SHA vendor.json records for it; stance is `fork`, so the local bytes diverge deliberately — see this component's stance_reason. -->

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the finish-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run the project test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Determine Base Branch

Do NOT guess. finish-branch runs while already standing on the feature branch, and
"what did I branch from" is not reliably recoverable from git — `git merge-base` answers
a different question (the shared ancestor with a branch you name), so on a stacked branch
it happily confirms `main` while the real parent is another PR's branch.

Resolution is EXPLICIT-FIRST, and the executable fence in Option 2 below implements exactly
this chain (`# --- BEGIN pr-base resolution (#439) ---`):

1. **Operator override** — `UBERDEV_PR_BASE_BRANCH=<branch>` in the environment.
2. **Per-project config** — `pr_base_branch: <branch>` in `.claude/uberdev.local.md`
   (see `using-uberdev/references/configuration.md`).
3. **The origin default branch** — `refs/remotes/origin/HEAD`, then `origin/main`,
   then `origin/master`. This is the unchanged legacy behaviour.

The resolved base has exactly two consumers, and they must agree: the pre-push secret-scan
range, and `gh pr create --base`. Tiers 1 and 2 emit `--base`; tier 3 does not, because the
resolved value already IS what `gh` targets by default.

**Opening a stacked (dependent) PR:** set tier 1 or 2 to the parent PR's branch. That both
points the new PR at its parent and stops the scan from re-reading the parent's commits.

If a configured base names a branch this checkout has never fetched (or a typo), `--base` is
still passed to `gh` — GitHub has the branch even when this clone does not — but the scan
range degrades to the origin default branch and says so on stderr. It never degrades to the
branch root commit, which would scan strictly more than the pre-#439 range.

### Step 3: Mode selection (precedence: UBERDEV_TURBO=1 > --interactive > default)

Detect mode from the inherited environment variable `UBERDEV_TURBO` (set by the turbo/solve-pipeline dispatch environment and propagated by the active backend, per #97) AND from `$ARGUMENTS` (for the `--interactive` flag only — finish-branch no longer parses `--turbo` as an argument; turbo signal is env-var-only on the chain hot path):

1. **Turbo mode** — if `[[ "${UBERDEV_TURBO:-0}" == "1" ]]`:
   Skip the prompt, auto-select **Option 2 (Push and create a Pull Request)**, and chain into `/uberdev:review-pr` (no `--turbo` arg — review-pr inherits the env var via Skill() invocation in the same agent process). Announce:

   > "Implementation complete. Turbo mode (UBERDEV_TURBO=1) — auto-selecting Option 2 (Push and create PR). Chaining into /uberdev:review-pr."

   Proceed to Step 4 → Option 2.

2. **Interactive mode** — if `--interactive` is in `$ARGUMENTS` (and `UBERDEV_TURBO` is not `1` — turbo wins per precedence above):
   Present the legacy 4-option menu below. If the user picks Option 2, chain into `/uberdev:review-pr` (no `--turbo`). Other options behave as today.

   ```
   Implementation complete. What would you like to do?

   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is (I'll handle it later)
   4. Discard this work

   Which option?
   ```

   > **Caveat — Options 1, 3, 4 bypass post-impl review.** Options 1 (Merge back to base locally), 3 (Keep the branch as-is), and 4 (Discard this work) skip `gh pr create` entirely, and therefore skip the chain into `/uberdev:review-pr` whose Phase 1 hosts the 6-reviewer post-impl-review fanout. `plugins/uberdev/skills/post-impl-review/SKILL.md` is the authoritative owner of the reviewer-fanout facts (agent roster, count, dispatch shape — per its "When to invoke", `/uberdev:review-pr` Phase 1 is the sole live caller); this skill owns only the chain mode-signal. Users who pick Options 1, 3, or 4 explicitly opt out of automated post-impl review for that branch. Only Option 2 (Push and create a Pull Request) preserves the chain. The default mode (always-PR, no flags) and Turbo mode (`UBERDEV_TURBO=1`) both auto-select Option 2 — neither is affected by this bypass.

   **Don't add explanation** — keep options concise.

3. **Default mode** — neither `UBERDEV_TURBO=1` nor `--interactive` set (the always-PR path):
   Auto-select **Option 2 (Push and create a Pull Request)** and chain into `/uberdev:review-pr` (no `--turbo` forwarded). Announce:

   > "Implementation complete. Pushing branch and creating PR. Chaining into /uberdev:review-pr…"

   Proceed to Step 4 → Option 2.

**Conflict resolution:** if `--interactive` is in `$ARGUMENTS` AND `UBERDEV_TURBO=1` is also set, env var wins (turbo's contract is unattended end-to-end; interactive prompts are mutually exclusive). The `UBERDEV_TURBO` env var is the canonical signal on the chain hot path; finish-branch no longer accepts a `--turbo` argument (#97 — env-var-only since the orchestrator → SDD → finish-branch chain is fully internal). This Step 3 is the authoritative owner of the chain mode-signal contract — upstream docs (orchestrator Phase 6, SDD Step 5) defer to it and must not restate flag-forwarding behaviour.

**The chain never gains a blocking prompt (#470).** `/uberdev:review-pr` Phase 0 offers to consolidate every open PR into one review when more than one is open — but the chain from here must reach the pipeline, not a question. Both chain modes are covered, by two different gates:

- **Turbo mode** forwards `UBERDEV_TURBO=1`, which Phase 0 reads through its hybrid OR detector → `REVIEW_CONSOLIDATE OFFER=no REASON=turbo`.
- **Default mode forwards no flag at all**, so the turbo gate does nothing for it. What covers it is the run carrier: a chained run inherits `UBERDEV_RUN_CARRIER_JSON` from the `/solve` (or `/turbo`) run that produced this branch, and Phase 0 treats an inherited carrier as `REASON=chained`. A standalone `/review-pr` the operator typed themselves has no inherited carrier and is therefore still offered the choice.

Both arms reach their verdict from the environment alone, before any `gh` round-trip. Do not "simplify" this to the turbo gate alone: the default always-PR path is the one that actually regresses, because it is the path a plain `/solve` takes.

**Discoverability:** the `--interactive` flag restores the legacy 4-option menu (Merge back to base / Push and create a Pull Request / Keep the branch as-is / Discard) for users who want it. The default is now always-PR; this fulfills the `~/.claude/CLAUDE.md` mandate "MANDATORY: run `/uberdev:review-pr` after pushing the PR. No exceptions, hotfixes included."

### Step 4: Execute Choice

#### Option 1: Merge Locally

Option 1 carries no git sequence of its own. It supplies three inputs and runs
the single executable teardown block in Step 5, which switches to the base
branch, merges, verifies and cleans up in the one order that actually works.

Set the inputs in the same Bash call that runs the Step 5 block:

- `FB_MODE=merge`
- `FB_BASE_BRANCH=<the base branch resolved in Step 2>`
- `FB_TEST_COMMAND=<the project test command from Step 1>`

`FB_TEST_COMMAND` is mandatory in merge mode and has no default: the block
refuses rather than deleting a branch on an unverified merge.

Then: run the teardown block (Step 5)

#### Option 2: Push and Create PR

Option 2 PR-body composition: in addition to the standard Summary + Test Plan, two conditional sections are appended when their source artifacts exist:

- **`## Open questions answered by /turbo`** — table rendered from the active-run `questions.md` (written by orchestrator Phase 2 under `--turbo`; run identity resolved via the per-worktree `active-run-id` sidecar below, written by orchestrator Phase 0). Columns: Question | Choice | Confidence. Reviewers can scan for `medium`/`low` confidence rows quickly.
- **`## Reviewer findings summary`** — the post-impl-review aggregate (`post-impl-review-final.md`, written by `uberdev:post-impl-review` from `/uberdev:review-pr` Phase 1 after PR push) and any `pr-test-analyzer` output (large tier only, written by SDD Step 4.5 before this handoff). The read-site globs below are deliberately wider than the current filename of either producer: `post-impl-review-*.md` matches both the new `-final.md` filename and any legacy `-wave-final.md` artifacts left over from pre-refactor runs, and `pr-test-analyzer*.md` matches both the plan-scoped `pr-test-analyzer-<plan-scope>.md` that SDD Step 4.5 writes today (#458) and the legacy unscoped `pr-test-analyzer.md` from pre-#458 runs (the `*` matches the empty infix). Both are zero-migration by construction — a narrower glob would compose a silent "no findings" PR body rather than fail loudly.

Both sections are read-only dumps; finish-branch does not block on confidence threshold or reviewer verdict (per #11 Q1: advisory only, auto-fix deferred).

```bash
# Resolve run identity for the orchestrator artifact reads below. Environment
# exports do NOT survive the detached-dispatch / Skill process boundary, so the
# cross-process contract is the per-worktree sidecar written by orchestrator
# Phase 0 — never a RUN_ID export. An in-process RUN_ID (same-agent chain) is
# honoured first when it names a real run dir.
# RUN_ID_FORMAT is the repo-wide run-id contract, NOT a finish-branch dialect.
# Source of truth: RUN_ID_REGEX in skills/merge-pipeline/SKILL.md Constants
# (^[0-9]{8}-[0-9]{6}-[a-f0-9]+$), enforced identically by lib/command-workspace.py,
# commands/review-pr.md, commands/simplify.md, agents/findings-to-issues.md and
# skills/merge-pipeline/lib/discover.sh. It matches the orchestrator Phase 0 mint:
# date +%Y%m%d-%H%M%S, a hyphen, then the short SHA (or the 0000000 hex sentinel).
# Do NOT widen this locally — a run-id that only finish-branch accepts resolves
# here and is rejected as invalid_run_id by every other consumer (#345).
RUN_ID_FORMAT='^[0-9]{8}-[0-9]{6}-[a-f0-9]+$'
RESEARCH_ROOT="$(git rev-parse --show-toplevel)/.uberdev/research"
ACTIVE_RUN_ID=""
if [ -n "${RUN_ID:-}" ] && [[ "${RUN_ID}" =~ $RUN_ID_FORMAT ]] && [ -d "$RESEARCH_ROOT/${RUN_ID}" ]; then
  ACTIVE_RUN_ID="${RUN_ID}"
elif [ -f "$RESEARCH_ROOT/active-run-id" ]; then
  SIDECAR_ID="$(head -1 "$RESEARCH_ROOT/active-run-id" 2>/dev/null | tr -d '[:space:]')"
  # Validate BEFORE any path concatenation: the sidecar is a worktree-writable
  # file, so reject anything that does not match the run-id mint (this also
  # excludes path metacharacters and traversal bytes by construction).
  if [[ "$SIDECAR_ID" =~ $RUN_ID_FORMAT ]] && [ -d "$RESEARCH_ROOT/$SIDECAR_ID" ]; then
    ACTIVE_RUN_ID="$SIDECAR_ID"
  fi
fi
# There is deliberately NO newest-across-runs fallback here (the old
# ls -t over .uberdev/research/*/questions.md): mtime ordering can
# cross-attach a stale or concurrent run artifact into the wrong PR body
# (#308). When run identity does not resolve, the optional sections below
# are silently omitted — omission beats misattribution.

QUESTIONS_FILE=""
if [ -n "$ACTIVE_RUN_ID" ] && [ -f "$RESEARCH_ROOT/$ACTIVE_RUN_ID/questions.md" ]; then
  QUESTIONS_FILE="$RESEARCH_ROOT/$ACTIVE_RUN_ID/questions.md"
fi

# Read the post-impl-review aggregate (and pr-test-analyzer if present) for
# the Reviewer findings summary section — scoped to the active run dir when
# identity resolved; the wildcard branch covers manual invocations that have
# no orchestrator run. The legacy .uberdev/research/issue-N glob component
# was DELETED together with the orchestrator research cache (#308: the
# issue-N cache had zero writers, so the glob could only ever match nothing).
#
# REVIEW_FILES stays NEWLINE-delimited (raw `ls -t` output, no `tr '\n' ' '`
# join) so the consumer below can iterate it with a while-read loop. This
# fence runs under /bin/zsh on macOS (the Claude-Code Bash tool default), where
# SH_WORD_SPLIT is OFF: a space-joined scalar fed to a for-loop over the list
# would NOT word-split — $f would bind to the whole list as one token, the
# `[ -f "$f" ]` guard would fail, and the entire section (including the envelope
# strip) would be silently skipped. Newline-delimited + read-loop is word-split-
# independent and behaves identically under bash and zsh.
if [ -n "$ACTIVE_RUN_ID" ]; then
  REVIEW_FILES=$(ls -t "$RESEARCH_ROOT/$ACTIVE_RUN_ID"/post-impl-review-*.md "$RESEARCH_ROOT/$ACTIVE_RUN_ID"/pr-test-analyzer*.md 2>/dev/null)
else
  REVIEW_FILES=$(ls -t .uberdev/research/*/post-impl-review-*.md .uberdev/research/*/pr-test-analyzer*.md 2>/dev/null)
fi

# Compose PR body. Heredoc delimiter is unquoted (`<<EOF`, not the single-
# quoted form) to avoid the Claude permission-pattern evaluator `unmatched '`
# bug (#42). The agent must compose the body free of `$`, backticks, and
# backslash — unquoted heredocs do not shield these from shell expansion.
PR_BODY_FILE=$(mktemp)
cat > "$PR_BODY_FILE" <<EOF_HEADER
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF_HEADER

if [ -n "$QUESTIONS_FILE" ] && [ -f "$QUESTIONS_FILE" ]; then
  {
    echo
    echo "## Open questions answered by /turbo"
    echo
    echo "The following questions were answered automatically — please review:"
    echo
    # Extract questions and auto-picks; render as a markdown table.
    awk -v c0=0 '/^## Q[0-9]+:/{q=$c0; sub(/^## Q[0-9]+: */, "", q)} /^\*\*Auto-pick:\*\*/{a=$c0; sub(/^\*\*Auto-pick:\*\* */, "", a)} /^\*\*Confidence:\*\*/{c=$c0; sub(/^\*\*Confidence:\*\* */, "", c); print "| " q " | " a " | " c " |"}' "$QUESTIONS_FILE" | (echo "| Question | Choice | Confidence |"; echo "|----------|--------|------------|"; cat)
  } >> "$PR_BODY_FILE"
fi

if [ -n "$REVIEW_FILES" ]; then
  {
    echo
    echo "## Reviewer findings summary"
    echo
    # Iterate the NEWLINE-delimited REVIEW_FILES with a while-read loop, NOT a
    # for-loop over $REVIEW_FILES — under zsh (the Bash-tool default on macOS,
    # and this is a raw bash code fence with no bash shebang) an unquoted scalar
    # does not word-split (SH_WORD_SPLIT off), so the for-loop would bind $f to
    # the entire list as one token, the `[ -f "$f" ]` guard would fail, and this
    # whole section — including the envelope strip below — would be silently
    # skipped. The read-loop is word-split-independent (identical under bash/zsh).
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      # A zero-byte report is workspace pre-allocation, never a review result:
      # command-workspace.py CALLERS["review-pr"] allocates the Phase 1
      # aggregate (post-impl-review-final.md) with empty initial bytes at
      # prepare time, so a run that never reached Phase 1 — or whose Phase 1
      # suppressed its aggregate — leaves an empty file on this glob path.
      # Empty bytes are rejected by the review-pr digest gate anyway
      # (code_fixer_contract.py digest --minimum 1, review-pr.md:1757/:1839),
      # so omitting the file loses no findings, whereas the strict validator
      # below would abort the entire PR body over it. NON-empty invalid bytes
      # still exit 1 below — this skip is zero-byte-only.
      [ -s "$f" ] || continue
      echo "### $(basename "$f")"
      case "$(basename "$f")" in
        post-impl-review-*.md)
          # Phase 1 aggregates are machine-authority documents. Validate the
          # exact v2 bytes and render a bounded human summary; never paste raw
          # compact JSON into the PR body.
          if ! python3 -I -B - "$f" <<PY
import json,pathlib,posixpath,re,sys

contributor_ids=[
 "review_pr.review.correctness",
 "review_pr.review.silent_failures",
 "review_pr.review.types",
 "review_pr.review.comments",
 "review_pr.review.tests",
 "review_pr.review.general",
 "review_pr.review.convention",
]
payload=pathlib.Path(sys.argv[1]).read_bytes()
opening=b'<external-untrusted-input source="post-impl-review-aggregate">\n'
closing=b'\n</external-untrusted-input>\n'
if not payload.startswith(opening) or not payload.endswith(closing): raise SystemExit(2)
body=payload[len(opening):-len(closing)]
try: document=json.loads(body)
except (UnicodeError,json.JSONDecodeError): raise SystemExit(2)
canonical=json.dumps(document,sort_keys=True,separators=(',',':'),ensure_ascii=True)
canonical=canonical.replace('</external-untrusted-input>',chr(92)+'u003c/external-untrusted-input>')
if body.decode('utf-8')!=canonical: raise SystemExit(2)
contributors=document.get('contributors')
if (list(document)!=['contributors','findings','phase','schema_version']
    or type(contributors) is not list or len(contributors)!=len(contributor_ids)
    or document.get('phase')!='phase1' or document.get('schema_version')!=2
    or type(document.get('findings')) is not list): raise SystemExit(2)
for index, contributor in enumerate(contributors):
 if (type(contributor) is not dict
     or list(contributor)!=['confidence','id','verdict']
     or contributor.get('id')!=contributor_ids[index]
     or contributor.get('confidence') not in {'low','medium','high'}
     or contributor.get('verdict') not in {'APPROVE','REVISIONS_REQUIRED','REJECT'}):
  raise SystemExit(2)
for finding in document['findings']:
 if (type(finding) is not dict
     or list(finding)!=['detail','scope','severity','source_edges','summary']
     or finding.get('severity') not in {'blocker','suggestion'}
     or not isinstance(finding.get('summary'),str) or not finding['summary']
     or not isinstance(finding.get('detail'),str) or not finding['detail']
     or type(finding.get('source_edges')) is not list
     or not finding['source_edges']): raise SystemExit(2)
 expected_edges=[edge for edge in contributor_ids if edge in finding['source_edges']]
 if finding['source_edges']!=expected_edges or len(expected_edges)!=len(set(expected_edges)):
  raise SystemExit(2)
 scope=finding.get('scope')
 if (type(scope) is not dict or list(scope)!=['line','operation','path']
     or scope.get('operation')!='modify_existing'
     or type(scope.get('line')) is not int or isinstance(scope.get('line'),bool)
     or scope['line']<1 or not isinstance(scope.get('path'),str)): raise SystemExit(2)
 path=scope['path']; parts=path.split('/')
 if (not path or path.startswith('/') or chr(92) in path or re.match(r'^[A-Za-z]:',path)
     or any(part in {'','.','..'} for part in parts) or parts[0]=='.git'
     or posixpath.normpath(path)!=path): raise SystemExit(2)
if not document['findings']:
 print('No findings.')
else:
 for finding in document['findings']:
  scope=finding['scope']
  tick=chr(96)
  print(f"- **{finding['severity']}** {tick}{scope['path']}:{scope['line']}{tick} — {finding['summary']}")
PY
          then
            echo "ERROR: invalid canonical Phase 1 review aggregate: $f" >&2
            return 1 2>/dev/null || exit 1
          fi
          ;;
        *)
          # Legacy analyzer reports remain human prose. Strip only pure
          # envelope tag lines; inline mentions survive.
          sed -E -e '/^[[:space:]]*<external-untrusted-input[^>]*>[[:space:]]*$/d' \
                 -e '/^[[:space:]]*<\/external-untrusted-input>[[:space:]]*$/d' "$f"
          ;;
      esac
      echo
    done <<< "$REVIEW_FILES"
  } >> "$PR_BODY_FILE"
fi

# Compose PR title via heredoc + read-back into a bash variable, then pass to
# `gh --title "$PR_TITLE_VAR"` — double-quoted variable expansion is byte-
# verbatim, no backtick/dollar re-evaluation. The heredoc delimiter is
# unquoted (`<<PR_TITLE_EOF`, not the single-quoted form) to avoid the Claude
# permission-pattern evaluator `unmatched '` bug (#42); the agent must
# compose the title free of `$`, backticks, and backslash. This closes the
# title-injection vector without inventing a `--title-file` flag (which gh
# does not support).
TITLE_FILE=$(mktemp) || { echo "ERROR: mktemp failed for title file" >&2; exit 1; }
cat > "$TITLE_FILE" <<PR_TITLE_EOF
<title>
PR_TITLE_EOF

# Read title back into a quoted variable — bytes pass through verbatim, no shell
# expansion. `IFS= read -r` reads the first line only; if the title file ever
# contains multiple lines (should not, per the heredoc above), subsequent lines
# are silently dropped. Empty-title rejection happens implicitly via the
# downstream `gh pr create` failure path.
IFS= read -r PR_TITLE_VAR < "$TITLE_FILE" || { echo "ERROR: failed to read title file" >&2; rm -f "$TITLE_FILE" "$PR_BODY_FILE"; exit 1; }

# Pre-push secret scan: layered defense (gitleaks primary + regex fallback)
# over ALL THREE texts this step ships outward — the to-be-pushed commit range,
# the composed PR-body file, AND the composed PR title. Any hit aborts the push
# BEFORE any text reaches GitHub. The title is not optional coverage: `gh pr
# create --title` publishes it exactly like `--body-file` publishes the body, so
# an unscanned title was the same leak under a different field name (#303).
# Worktree is preserved for investigation. The library signals leaks via non-zero
# exit code (matched content streams to stderr for diagnostic capture). Callers
# MUST check the exit code, NOT the captured stdout, because the library writes
# nothing to stdout on either path.
# Layered secret scan (gitleaks + regex fallback): sourced from shared library.
# Source-time idempotency guard prevents double-load if any caller already sourced.
source "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"

# Helper: scan stdin; abort if the library returns non-zero. Cleans up tmp files
# and preserves worktree. Captures stderr into $SCAN_DIAG so the abort message
# names the offending pattern.
abort_if_secret() {
  local label="${@:1:1}"
  local scan_diag="${@:2:1}"
  local scan_rc="${@:3:1}"
  [ "$#" -ge 3 ] || return 2
  [[ "$scan_rc" -eq 0 ]] && return 0
  # The library rc is TRI-STATE and the two non-zero cases need opposite
  # advice: rc 1 is a detected secret (offer the escape hatch); rc>=2 means the
  # scanner itself could not run (crashed gitleaks, unreadable ruleset, broken
  # fallback grep). Reporting the latter as "secret found" and offering the
  # allowlist marker would talk the operator into stripping a line from the
  # regex fallback too, removing the second layer while the first stays broken.
  if [[ "$scan_rc" -ge 2 ]]; then
    echo "ERROR: secret scan could not complete for $label (rc=$scan_rc): $scan_diag" >&2
    echo "This is a BROKEN SCANNER, not a detected secret — do NOT allowlist anything. Fix the scanner or its config and rerun." >&2
  else
    echo "ERROR: secret found in $label (rc=$scan_rc): $scan_diag" >&2
    # Name the escape hatch by expanding the marker variable owned by the library
    # rather than re-typing the literal — lib/secret-scan.sh holds the single
    # definition, so the two can never drift apart.
    echo "False positive? Exempt the individual line with the ${UBERDEV_SECRET_SCAN_ALLOW_MARKER} marker, or add an allowlist rule to the repo .gitleaks.toml." >&2
  fi
  echo "Push aborted. Worktree preserved. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
}

# --- BEGIN pr-base resolution (#439) ---
# Resolve the PR base branch ONCE. It feeds BOTH the pre-push scan range and
# `gh pr create --base`, so a stacked (dependent) PR targets its parent branch
# instead of the repository default — and the scan stops re-reading the commits
# of the parent PR, whose secret-shaped TEST FIXTURES would otherwise hard-abort
# the push of the child with no override.
#
# Precedence is EXPLICIT-FIRST, because "what did I branch from" is not
# recoverable from git once you are standing on the feature branch:
#   1. env override   UBERDEV_PR_BASE_BRANCH
#   2. project config pr_base_branch (.claude/uberdev.local.md)
#   3. the origin default branch (unchanged legacy behaviour)
# `command -v`, never `type -t`: this fence executes under zsh, where `type -t`
# prints nothing and the guard would misfire into a redundant re-source.

# The origin default branch NAME, or empty when no probe answers. Used by BOTH
# tier 3 and the "configured base did not resolve" recovery below, so the two can
# never drift into disagreeing about what "the default" is. Each probe is
# rc-checked SEPARATELY — see the dead-pipeline note in the tier-3 arm.
uberdev_origin_default_branch() {
  local _sym
  _sym="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$_sym" ]; then printf '%s' "${_sym#refs/remotes/origin/}"; return 0; fi
  if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then printf '%s' "main"; return 0; fi
  if git rev-parse --verify --quiet origin/master >/dev/null 2>&1; then printf '%s' "master"; return 0; fi
  printf '%s' ""
}

if ! command -v uberdev_read_string >/dev/null 2>&1; then
  source "${CLAUDE_PLUGIN_ROOT}/lib/config-read.sh"
fi
PR_BASE=""
PR_BASE_EXPLICIT=0
if command -v uberdev_read_string >/dev/null 2>&1; then
  PR_BASE="$(uberdev_read_string pr_base_branch UBERDEV_PR_BASE_BRANCH '^[A-Za-z0-9._/-]{1,255}$' '')"
elif [ -n "${UBERDEV_PR_BASE_BRANCH:-}" ]; then
  # The reader did not load but an override IS set. Degrading to tier 3 here is
  # survivable; doing it SILENTLY is not — the PR would target the default
  # branch while the operator believes it is stacked.
  echo "WARNING: lib/config-read.sh did not load, so UBERDEV_PR_BASE_BRANCH is being ignored; the PR will target the origin default branch." >&2
fi
if [ -n "$PR_BASE" ]; then
  PR_BASE_EXPLICIT=1
else
  # Tier 3 — the origin default branch. The previous shape chained the probes
  # through a single pipeline:
  #   BASE_REF=$(git symbolic-ref … | sed … || git rev-parse --verify origin/main …)
  # `||` binds to the whole PIPELINE, and `sed` exits 0 on empty input, so when
  # symbolic-ref failed the pipeline STILL returned 0: BASE_REF came back empty
  # and every fallback arm below it was unreachable dead code. The scan then
  # degraded to `git diff --staged`, which on a fully-committed branch scans
  # nothing — a fail-OPEN security control, not a cosmetic bug (#439).
  PR_BASE="$(uberdev_origin_default_branch)"
fi

# Diff range for the pre-push scan: prefer the remote-tracking ref, then a local
# branch of the same name.
BASE_REF=""
if [ -n "$PR_BASE" ]; then
  if git rev-parse --verify --quiet "origin/$PR_BASE" >/dev/null 2>&1; then
    BASE_REF="origin/$PR_BASE"
  elif git rev-parse --verify --quiet "$PR_BASE" >/dev/null 2>&1; then
    BASE_REF="$PR_BASE"
  fi
fi
# A CONFIGURED base that resolves to no ref here is the NORMAL state of a fresh
# stacked worktree: the parent PR was pushed from somewhere else and this clone
# never fetched it. `--base` stays correct (GitHub has the branch), but the scan
# has no narrow range to use — so widen to the origin default branch, NEVER to
# the root commit. The root commit is strictly WIDER than pre-#439 behaviour and
# drags the secret-shaped test fixtures of the parent back into range, re-creating
# the exact hard-abort-with-no-override this change exists to prevent. Say so out
# loud, too: a silent widening reaches the operator only as an unexplained
# secret-scan abort.
if [ -z "$BASE_REF" ] && [ "$PR_BASE_EXPLICIT" = "1" ]; then
  echo "WARNING: configured PR base '$PR_BASE' resolves to no ref in this checkout (try: git fetch origin $PR_BASE). --base is still passed to gh, but the pre-push secret scan is widening to the origin default branch, so that base branch's own commits are in scan range." >&2
  PR_BASE_FALLBACK="$(uberdev_origin_default_branch)"
  if [ -n "$PR_BASE_FALLBACK" ] && git rev-parse --verify --quiet "origin/$PR_BASE_FALLBACK" >/dev/null 2>&1; then
    BASE_REF="origin/$PR_BASE_FALLBACK"
  fi
fi
# Last resort — the branch root commit: scan everything since creation. Reached
# only when NO base resolved at all (no origin default branch either), so the
# widening is the safe direction, but it is still worth naming.
# `--max-count=1` keeps a multi-root repo from producing a multi-line value that
# `git diff "$BASE_REF..HEAD"` could not parse.
if [ -z "$BASE_REF" ]; then
  echo "WARNING: no base ref resolved (no origin default branch found); the pre-push secret scan is ranging from the branch root commit, so every commit in this branch's history is in scope." >&2
  BASE_REF="$(git rev-list --max-parents=0 --max-count=1 HEAD 2>/dev/null)"
fi

# `--base` is emitted ONLY when the base was explicitly configured (tier 1 or 2).
# With no override the resolved base IS the repository default, which is exactly
# what `gh pr create` targets on its own — so the unset path stays byte-identical
# to the previous invocation, flag and all.
#
# An ARRAY, never a scalar: zsh does not word-split an unquoted scalar, so a
# `$PR_BASE_ARG` holding `--base main` would reach gh as ONE argument. The
# `${a[@]+"${a[@]}"}` guard keeps the empty case a zero-word expansion even under
# `set -u` on bash 3.2 (macOS), where a bare `"${a[@]}"` errors instead.
PR_BASE_ARGS=()
if [ "$PR_BASE_EXPLICIT" = "1" ]; then
  PR_BASE_ARGS=(--base "$PR_BASE")
fi
# --- END pr-base resolution (#439) ---

# Scan target 1: the diff that will actually be pushed (commits ahead of upstream).
# Falls back to staged diff for fresh branches that have no remote tracking yet.
# Capture stderr (matched lines) into $SCAN_DIAG and the function exit code
# into $SCAN_RC for the abort_if_secret check.
if PUSH_DIFF=$(git diff @{u}..HEAD 2>/dev/null) && [[ -n "$PUSH_DIFF" ]]; then
  SCAN_DIAG=$(printf '%s' "$PUSH_DIFF" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
else
  # No upstream set or empty diff → scan from $BASE_REF, the range derived from
  # the ONE resolved PR base above. On a stacked branch that is the PARENT
  # branch, not origin/HEAD, so the commits of the parent PR (and their
  # secret-shaped test fixtures) fall correctly outside this push range. Note:
  # `git merge-base HEAD HEAD~1` is degenerate (= HEAD~1) and was removed — it
  # scanned only the last commit.
  if [[ -n "$BASE_REF" ]]; then
    SCAN_DIAG=$(git diff "$BASE_REF..HEAD" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
  else
    SCAN_DIAG=$(git diff --staged | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
  fi
fi
abort_if_secret "to-be-pushed diff" "$SCAN_DIAG" "$SCAN_RC"

# Scan target 2: composed PR body file
SCAN_DIAG=$(uberdev_run_secret_scan_stdin < "$PR_BODY_FILE" 2>&1 >/dev/null); SCAN_RC=$?
abort_if_secret "composed PR body" "$SCAN_DIAG" "$SCAN_RC"

# Scan target 3: composed PR title. Scanned from $PR_TITLE_VAR (the exact bytes
# handed to `gh pr create --title` below), not from $TITLE_FILE, so the scan and
# the publish read the identical value — the read-back at the heredoc above
# keeps only the first line, and scanning the file would cover text the title
# never carries while missing nothing the title does.
SCAN_DIAG=$(printf '%s\n' "$PR_TITLE_VAR" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
abort_if_secret "composed PR title" "$SCAN_DIAG" "$SCAN_RC"

# All three scans clean → push and create PR. Each step is exit-code-checked so a
# failure surfaces explicitly (rather than silently proceeding to the next step).
if ! git push -u origin <feature-branch>; then
  echo "ERROR: git push failed. Branch state preserved. Worktree retained. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi

# Capture PR URL from gh stdout AND its exit code together. gh returns the
# created PR URL on stdout when successful; non-zero exit on auth/network/quota
# errors. The negated-conditional branch below surfaces the gh failure
# explicitly (PR_URL captures stderr via 2>&1 in the failure case to keep
# the diagnostic).
if ! PR_URL=$(gh pr create --title "$PR_TITLE_VAR" --body-file "$PR_BODY_FILE" ${PR_BASE_ARGS[@]+"${PR_BASE_ARGS[@]}"} 2>&1); then
  echo "ERROR: gh pr create failed: $PR_URL" >&2
  echo "Branch state preserved. Worktree retained. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi
PR_URL_REGEX='^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$'
if [[ ! "$PR_URL" =~ $PR_URL_REGEX ]]; then
  echo "ERROR: gh pr create returned non-parseable URL: $PR_URL" >&2
  echo "Branch state preserved. Worktree retained. Do NOT chain into review-pr. Investigate and rerun." >&2
  rm -f "$TITLE_FILE" "$PR_BODY_FILE"
  exit 1
fi
echo "PR created: $PR_URL"
# Extract the PR number from PR_URL by stripping everything up to the final
# slash. PR_URL already passed PR_URL_REGEX immediately above (it ends in
# /pull/ then digits), so ${PR_URL##*/} yields exactly those digits with no
# further parse. This deliberately AVOIDS a capture-group [[ =~ ]] match
# (#270): finish-branch SKILL.md bash fences run under /bin/zsh on macOS, where
# the capture lands in the match array, not BASH_REMATCH; the bash-only form left
# PR_NUM empty, so gh pr edit with an empty arg failed (swallowed by the
# fail-soft guard) and the #95 review-pr:pending backstop label was never set on
# any PR created via finish-branch on macOS, defeating the /merge label-present
# probe. Both gh calls remain fail-soft per the fire-and-surface contract (issue
# #11 Q1): a transient gh failure loud-logs to stderr but MUST NOT exit non-zero
# or roll back the PR.
PR_NUM="${PR_URL##*/}"
if ! gh label create --force review-pr:pending \
     --color FBCA04 \
     --description "review-pr has not yet completed for this PR" 2>/dev/null; then
  echo "warning: failed to create review-pr:pending label; backstop may not fire" >&2
fi
if ! gh pr edit "$PR_NUM" --add-label review-pr:pending 2>/dev/null; then
  echo "warning: failed to add review-pr:pending label to PR #$PR_NUM; backstop will not fire if review-pr is missed" >&2
fi
rm -f "$TITLE_FILE" "$PR_BODY_FILE"
```

The two `gh` calls above are intentionally fail-soft — the fire-and-surface contract trumps backstop completeness, so a transient `gh` failure must not roll back PR creation. The literal label string `review-pr:pending` is declared as `REVIEW_PR_PENDING_LABEL` in `plugins/uberdev/skills/merge-pipeline/SKILL.md` Constants table; it is inlined here (mirroring how `UBERDEV_APPROVED_LABEL` is inlined in `commands/review-pr.md`) because bash does not dereference markdown constants — the literal string is the only available form in this position.

**Chain hand-off (always-PR path, default + turbo):**

This is the context-only lineage marker `finish_branch.review_pr` (`model_invocation: false`). It reuses the
current `UBERDEV_RUN_CARRIER_JSON` pointer/hash unchanged and does not resolve a
role, model, effort, service tier, sandbox, or provider. Only the downstream
review workflow may create provider children.

After the PR is created and `PR_URL` is validated, invoke `uberdev:review-pr` through the skill mechanism with `lineage_edge=finish_branch.review_pr`, the captured `PR_URL`, and the inherited `UBERDEV_RUN_CARRIER_JSON` when present. The skill boundary does not resolve a model. Review-pr inherits unattended mode via `UBERDEV_TURBO=1`; standalone review-pr initializes its own honest review carrier.

> Invoke `uberdev:review-pr` via the Skill tool with the captured `PR_URL` (no flag args). Findings are ADVISORY — do NOT block on `REVISIONS_REQUIRED` at this layer (the auto-fix loop is deferred per #11 Q1).

Mirrors the post-push `/review-pr` chain: `finish-branch` only kicks off the review skill; `/review-pr` owns reviewer fanout and any apply loop. `commands/review-pr.md` has no `disable-model-invocation` flag, so the `Skill` tool can invoke the slash command directly without promotion.

A review-pr failure (e.g., reviewer agent crash, `gh pr view` error) is loud-logged but does NOT roll back the PR or branch state. `finish-branch` returns success once the PR is open and the chain has been kicked off.

Use the `Skill` tool for this dispatch — never the agent-spawning tool.

Then: Step 5 — and Option 2 **keeps** the worktree. Do NOT run the Step 5
teardown block: the branch has to stay alive for PR-feedback fixups. Step 5 has
no `FB_MODE` for "keep", so there is nothing to run here.

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed, supply the inputs and run the same Step 5 teardown block:

- `FB_MODE=discard`
- `FB_BASE_BRANCH=<the base branch resolved in Step 2>`
- `FB_TEST_COMMAND` is not used in discard mode; leave it unset.

`discard` mode skips the pull, the merge and the test run, removes the worktree
with `--force` (the typed confirmation above is what authorises destroying
uncommitted work), and force-deletes the branch.

Then: run the teardown block (Step 5)

### Step 5: Cleanup Worktree

**For Options 1 and 4 ONLY:** run the block below. It is the one place that
switches to the base branch, merges or discards, verifies, removes the worktree
and deletes the branch. Options 2 and 3 must not run it — it deletes branches
for real, and `FB_MODE` has no value that means "keep".

Options 1 and 4 used to carry their own prose git sequences. Both were wrong in
the same four ways, and every one of the four was reproduced by an executed
probe against a real repository rather than inferred from a reading:

1. **`git checkout <base-branch>` was never rc-checked.** Run from a linked
   worktree it exits 128, because the base branch is already checked out by the
   main checkout. HEAD stays on the feature branch, and the next
   `git merge <feature-branch>` merges the branch into itself: rc 0,
   `Already up to date.` Option 1 reported a merge that never happened.
2. **The worktree probe was a substring grep** over `git worktree list`. In an
   ordinary clone it matched the row of the main checkout itself, so the flow
   went on to `git worktree remove` and hit `is a main working tree`.
3. **On a detached HEAD the same probe was vacuous.** `git branch
   --show-current` prints nothing there, so the grep pattern was the empty
   string and matched every row.
4. **The branch delete ran before the worktree removal.** git refuses to delete
   a branch that a live worktree still has checked out, so the delete failed and
   the worktree survived.

```bash
# Assign the three inputs in THIS Bash call, immediately above the block: skill
# fences do not share shell state, so an assignment made in another fence would
# never reach the code below.
FB_MODE=<merge for Option 1, discard for Option 4>
FB_BASE_BRANCH=<the base branch resolved in Step 2>
FB_TEST_COMMAND=<the project test command; required for merge, unused for discard>

# --- BEGIN worktree teardown (#460) ---
# Inputs, all mandatory and none defaulted. A defaulted value here IS the silent
# degradation this block exists to remove: an empty test command must refuse,
# never quietly become a skipped verification.
#   FB_MODE          merge | discard
#   FB_BASE_BRANCH   the base branch resolved in Step 2
#   FB_TEST_COMMAND  the project test command (merge mode only)
#
# Positional access uses the array-slice form throughout. The Claude Skill
# renderer substitutes positional slash-args into bash function bodies, so a
# bare positional in a shipped SKILL.md is not a positional at runtime — see
# abort_if_secret in Option 2 for the same idiom.
uberdev_fb_error() {
  printf 'ERROR: %s\n' "${@:1:1}" >&2
  return 1
}

uberdev_fb_warn() {
  printf 'WARNING: %s\n' "${@:1:1}" >&2
  return 0
}

# Classify a worktree by PROVENANCE: an anchored pattern match over absolute,
# physical paths. No grep and no regex, which is what retires defects 2 and 3
# above — a substring match is what let the main checkout row, a notworktrees
# sibling and a branch name carrying a regex metacharacter all read as a hit.
#   arg 1  the worktree path to classify
#   arg 2  the main checkout root
#   arg 3  the physical home directory
# The owned locations mirror using-git-worktrees/SKILL.md step 2; the
# dispatcher lane mirrors lib/dispatch.sh.
uberdev_fb_worktree_class() {
  local fb_wt="${@:1:1}"
  local fb_root="${@:2:1}"
  local fb_home="${@:3:1}"
  if [ "$#" -lt 3 ] || [ -z "$fb_wt" ] || [ -z "$fb_root" ] || [ -z "$fb_home" ]; then
    uberdev_fb_error "uberdev_fb_worktree_class needs <worktree-path> <main-root> <home-root>"
    return 2
  fi
  case "$fb_wt" in
    "$fb_root"/.claude/worktrees/*)
      printf '%s\n' dispatcher-owned ;;
    "$fb_root"/.worktrees/*|"$fb_root"/worktrees/*|"$fb_home"/.config/uberdev/worktrees/*)
      printf '%s\n' owned ;;
    *)
      printf '%s\n' foreign ;;
  esac
}

# The porcelain listing is one block per worktree — a worktree line, a HEAD
# line, then either a branch line or the bare word detached — and the MAIN
# worktree is always emitted first. awk field refs are parameterised via
# -v c0=0 for the same renderer reason as the positional slices above.
uberdev_fb_main_root() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v c0=0 'index($c0, "worktree ") == 1 { print substr($c0, 10); exit }'
}

# Which worktree currently holds a branch. Prints the holding path, or nothing
# when the branch is checked out nowhere.
uberdev_fb_branch_holder() {
  local fb_branch="${@:1:1}"
  local fb_want="branch refs/heads/$fb_branch"
  git worktree list --porcelain 2>/dev/null \
    | awk -v c0=0 -v want="$fb_want" '
        index($c0, "worktree ") == 1 { holder = substr($c0, 10) }
        $c0 == want { print holder; exit }
      '
}

# Remove an owned worktree, retry once behind a prune, then give up LOUDLY and
# leave it in place. The teardown never deletes a worktree directory behind git:
# a directory removed that way leaves a registered worktree pointing at nothing
# (merge-pipeline/SKILL.md keeps the same protocol). --force is used in discard
# mode only, where Option 4 has already taken a typed confirmation for
# destroying the branch and the worktree; merge mode must not silently destroy
# uncommitted work, which a commit-based merge never carried across.
uberdev_fb_remove_worktree() {
  local fb_wt="${@:1:1}"
  local fb_how="${@:2:1}"
  local fb_args
  fb_args=()
  if [ "$fb_how" = discard ]; then fb_args=(--force); fi
  if git worktree remove ${fb_args[@]+"${fb_args[@]}"} "$fb_wt"; then
    printf 'Removed worktree: %s\n' "$fb_wt"
    return 0
  fi
  if ! git worktree prune; then
    uberdev_fb_warn "git worktree prune failed while retrying the removal of $fb_wt"
  fi
  if git worktree remove ${fb_args[@]+"${fb_args[@]}"} "$fb_wt"; then
    printf 'Removed worktree after prune: %s\n' "$fb_wt"
    return 0
  fi
  uberdev_fb_warn "could not remove the worktree at $fb_wt; it is left in place. Remove it by hand once you know it is safe: git worktree remove --force $fb_wt"
  return 0
}

uberdev_fb_teardown() {
  local fb_mode="${FB_MODE:-}"
  local fb_base="${FB_BASE_BRANCH:-}"
  local fb_tests="${FB_TEST_COMMAND:-}"
  local fb_feature fb_git_dir fb_common_raw fb_common fb_worktree_root
  local fb_main_root fb_home_root fb_holder fb_linked fb_class

  # 1. Inputs.
  case "$fb_mode" in
    merge|discard) ;;
    *)
      uberdev_fb_error "FB_MODE must be merge or discard (got: $fb_mode)"
      return 1 ;;
  esac
  if [ -z "$fb_base" ]; then
    uberdev_fb_error "FB_BASE_BRANCH is empty — Step 2 resolves the base branch and this block will not guess it"
    return 1
  fi
  if [ "$fb_mode" = merge ] && [ -z "$fb_tests" ]; then
    uberdev_fb_error "FB_TEST_COMMAND is empty — merge mode never deletes a branch without a green test run on the merged result"
    return 1
  fi

  # 2. The feature branch. A detached HEAD prints nothing here, which is where
  #    defect 3 came from: refuse rather than proceed on an empty name.
  fb_feature="$(git branch --show-current 2>/dev/null)" || fb_feature=""
  if [ -z "$fb_feature" ]; then
    uberdev_fb_error "HEAD is detached — refusing to merge, delete a branch or remove a worktree with no named feature branch"
    return 1
  fi
  if [ "$fb_feature" = "$fb_base" ]; then
    uberdev_fb_error "already standing on the base branch $fb_base — refusing; this is the self-merge shape that reported Already up to date"
    return 1
  fi

  # 3. Resolve every root BEFORE any cd, checkout, merge or delete. Capture
  #    first, mutate second is a property of this code now, not an instruction
  #    somebody has to remember.
  fb_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || fb_git_dir=""
  if [ -z "$fb_git_dir" ]; then
    uberdev_fb_error "git rev-parse --absolute-git-dir produced nothing — not inside a work tree"
    return 1
  fi
  fb_common_raw="$(git rev-parse --git-common-dir 2>/dev/null)" || fb_common_raw=""
  if [ -z "$fb_common_raw" ]; then
    uberdev_fb_error "git rev-parse --git-common-dir produced nothing"
    return 1
  fi
  # Normalizing the common dir is mandatory, and the reason is NOT symlinks: git
  # already answers --absolute-git-dir, --show-toplevel and the worktree listing
  # with physical paths. It is that in an ORDINARY clone --git-common-dir
  # answers the relative string .git while --absolute-git-dir answers an
  # absolute path, so comparing the two unnormalized reports every ordinary
  # clone as a linked worktree.
  fb_common="$(cd "$fb_common_raw" 2>/dev/null && pwd -P)" || fb_common=""
  if [ -z "$fb_common" ]; then
    uberdev_fb_error "cannot resolve the git common directory: $fb_common_raw"
    return 1
  fi
  fb_worktree_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fb_worktree_root=""
  if [ -z "$fb_worktree_root" ]; then
    uberdev_fb_error "git rev-parse --show-toplevel produced nothing"
    return 1
  fi
  # HOME is shell-supplied rather than git-derived, so it is the one prefix in
  # the classifier that can genuinely be non-physical. When it does not resolve,
  # say so and use a sentinel that cannot prefix any real path — never an empty
  # string, which would turn the global-worktree arm into a wildcard.
  fb_home_root="$(cd "${HOME:-}" 2>/dev/null && pwd -P)" || fb_home_root=""
  if [ -z "$fb_home_root" ]; then
    uberdev_fb_warn "HOME does not resolve to a directory; a worktree under the global location will be reported as foreign"
    fb_home_root="/dev/null/unresolved-home"
  fi
  # The linked-worktree test that replaces the grep outright, and the same guard
  # lib/status.sh and lib/dispatch.sh already use: in a linked worktree the git
  # dir is <common>/worktrees/<name>; in the main checkout the two are equal.
  if [ "$fb_git_dir" = "$fb_common" ]; then fb_linked=0; else fb_linked=1; fi
  fb_main_root="$(uberdev_fb_main_root)" || fb_main_root=""
  if [ -z "$fb_main_root" ]; then
    uberdev_fb_error "cannot resolve the main checkout root from git worktree list --porcelain"
    return 1
  fi

  # 4. Everything below runs in the MAIN checkout. This is the structural half
  #    of the fix: the base branch cannot be checked out from a linked worktree
  #    at all, so a flow that stayed put could only ever fail its checkout and
  #    then merge the feature branch into itself.
  if ! cd "$fb_main_root"; then
    uberdev_fb_error "cannot enter the main checkout root $fb_main_root"
    return 1
  fi

  # 5. Refuse BEFORE any mutation when another worktree holds the base branch,
  #    then rc-check the checkout itself.
  fb_holder="$(uberdev_fb_branch_holder "$fb_base")" || fb_holder=""
  if [ -n "$fb_holder" ] && [ "$fb_holder" != "$fb_main_root" ]; then
    uberdev_fb_error "base branch $fb_base is checked out by the worktree at $fb_holder — refusing before any merge, delete or removal. Finish from that checkout, or free the branch there first."
    return 1
  fi
  if ! git checkout "$fb_base"; then
    uberdev_fb_error "git checkout $fb_base failed — aborting BEFORE the merge. An unchecked checkout here is exactly what turned the following merge into a self-merge that reported success."
    return 1
  fi

  # 6. merge mode only. The test command runs in a subshell so a stray cd or
  #    variable assignment inside it cannot repoint the git calls below.
  if [ "$fb_mode" = merge ]; then
    if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
      if ! git pull --ff-only; then
        uberdev_fb_error "git pull --ff-only failed on $fb_base — the local base has diverged from its upstream. Reconcile it, then rerun."
        return 1
      fi
    else
      uberdev_fb_warn "$fb_base has no upstream branch; merging into the local base without pulling"
    fi
    if ! git merge "$fb_feature"; then
      uberdev_fb_error "git merge $fb_feature failed. The repository is left mid-merge on $fb_base: resolve and commit, or run git merge --abort, then rerun."
      return 1
    fi
    if ! ( eval "$fb_tests" ); then
      uberdev_fb_error "the test command failed on the merged result. $fb_feature is NOT deleted and the worktree is NOT removed; fix the failures, or undo the merge, then rerun."
      return 1
    fi
  fi

  # 7. Worktree removal comes BEFORE the branch delete (defect 4): git refuses
  #    to delete a branch a live worktree still has checked out. A skip is never
  #    silent — every arm names the path and the reason.
  fb_class=not-linked
  if [ "$fb_linked" = 1 ]; then
    fb_class="$(uberdev_fb_worktree_class "$fb_worktree_root" "$fb_main_root" "$fb_home_root")" || fb_class=foreign
    case "$fb_class" in
      owned)
        uberdev_fb_remove_worktree "$fb_worktree_root" "$fb_mode" ;;
      dispatcher-owned)
        printf 'Left worktree in place: %s (dispatcher-owned: .claude/worktrees is created and torn down by lib/dispatch.sh, so removing it here would race the dispatcher).\n' "$fb_worktree_root" ;;
      *)
        printf 'Left worktree in place: %s (foreign: not a location this project creates, so only whoever made it knows whether it is still needed).\n' "$fb_worktree_root" ;;
    esac
  else
    printf 'No linked worktree to remove: this is the main checkout.\n'
  fi

  # 8. Branch delete last, and rc-checked. A failure here is a WARNING rather
  #    than an abort: the merge already landed, so the run must not report a
  #    failure it can no longer undo.
  if [ "$fb_mode" = merge ]; then
    if git branch -d "$fb_feature"; then
      printf 'Deleted branch: %s\n' "$fb_feature"
    else
      uberdev_fb_warn "could not delete $fb_feature (not fully merged, or still checked out somewhere). The merge itself succeeded — delete it by hand once you are sure."
    fi
  else
    if git branch -D "$fb_feature"; then
      printf 'Force-deleted branch: %s\n' "$fb_feature"
    else
      uberdev_fb_warn "could not force-delete $fb_feature; delete it by hand."
    fi
  fi

  # 9. Self-heal the registry, then say exactly what happened.
  if ! git worktree prune; then
    uberdev_fb_warn "git worktree prune failed; the worktree registry may still list a removed path"
  fi
  printf 'finish-branch teardown complete: mode=%s base=%s feature=%s worktree=%s\n' \
    "$fb_mode" "$fb_base" "$fb_feature" "$fb_class"
  return 0
}

uberdev_fb_teardown
# --- END worktree teardown (#460) ---
```

**What the block will and will not destroy.** Repairing Option 1 makes a
previously inert path start executing for real, so the destruction boundary is
explicit:

- It refuses before touching anything when the base branch is held by another
  worktree, when HEAD is detached, or when the test command is missing.
- Every git call is rc-checked and the first failure aborts.
- No branch is deleted in `merge` mode without a green test run on the merged
  result.
- `merge` mode removes the worktree **without** `--force`, so a worktree holding
  uncommitted work is left standing with a `WARNING` naming it — a commit-based
  merge never carried that work across, and losing it silently would be the same
  class of defect this block fixes. Only `discard` mode uses `--force`, and only
  behind the typed confirmation in Option 4.
- A worktree that is not in a location this project creates is never removed,
  and the skip always says which path and why.

**For Options 2 and 3:** Keep worktree. Option 2 leaves the branch alive for PR-feedback fixups; Option 3 is explicit "keep as-is". The Quick Reference table and Red Flags below codify this.

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch | Post-impl review |
|--------|-------|------|---------------|----------------|------------------|
| 1. Merge locally | ✓ | - | - | ✓ | bypassed (no PR) |
| 2. Create PR | - | ✓ | ✓ | - | runs (via /review-pr Phase 1) |
| 3. Keep as-is | - | - | ✓ | - | bypassed (no PR) |
| 4. Discard | - | - | - | ✓ (force) | bypassed (no PR) |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" → ambiguous
- **Fix:** Present exactly 4 structured options

**Automatic worktree cleanup**
- **Problem:** Remove worktree when might need it (Option 2, 3)
- **Fix:** Only cleanup for Options 1 and 4

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only

## Integration

**Called by:**
- **`uberdev:subagent-driven-dev`** — after all tasks complete and final review approves
- **`uberdev:execute-plan`** — after all batches complete and verification passes

**Pairs with:**
- The worktree-setup prose inlined in `uberdev:execute-plan` and `uberdev:subagent-driven-dev` — this skill cleans up the worktree those skills created.
- **`uberdev:merge`** — follows Option 2. `finish-branch` opens the PR; `/merge` lands it. Together they form the lifecycle `/issue → /solve → push → /review-pr → /merge`.

**Chains into:**
- **`uberdev:review-pr`** — invoked via the `Skill` tool after PR creation on the always-PR path (default mode + Turbo mode under `UBERDEV_TURBO=1`). `/review-pr` owns the post-push reviewer fanout; `finish-branch` does not block on reviewer verdict.

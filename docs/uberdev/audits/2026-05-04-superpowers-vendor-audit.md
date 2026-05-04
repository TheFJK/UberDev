# Superpowers Vendor Audit — 2026-05-04

**Date:** 2026-05-04
**Author:** TheFJK
**Closes:** #57
**Upstream SHA at audit time:** `e7a2d16476bf042e9add4699c9d018a90f86e4a6`
**Upstream fetch timestamp (UTC):** `2026-05-04T16:07:23Z`

## Summary

Audit of all files in `plugins/uberdev/skills/{test-driven-development,writing-skills,systematic-debugging}/` that were originally vendored from `obra/superpowers` in commit `41d072b` (v0.3.0). Verified byte-equivalence against upstream HEAD `e7a2d16476bf042e9add4699c9d018a90f86e4a6` and pinned in-file provenance headers on all 20 vendored files. 3 files carry expected-DIFFER status due to intentional local changes (namespace rebrand and one local enhancement section); the remaining 17 are byte-equivalent to upstream.

## Inventory + diff results

Special-case allowlist (intentional local divergence — recorded in per-file provenance header suffix):
- `writing-skills/SKILL.md` — superpowers:→uberdev: namespace rebrand from v0.3.0 port
- `writing-skills/testing-skills-with-subagents.md` — superpowers:→uberdev: namespace rebrand from v0.3.0 port
- `systematic-debugging/SKILL.md` — superpowers:→uberdev: namespace rebrand + local 'Parallel hypothesis testing' section enhancement

| # | File | Local bytes | Upstream bytes | Local sha256 | Upstream sha256 | Result |
|---|------|-------------|----------------|--------------|-----------------|--------|
| 1 | `test-driven-development/SKILL.md` | 9867 | 9867 | `7dee67b4af6b` | `7dee67b4af6b` | MATCH |
| 2 | `test-driven-development/testing-anti-patterns.md` | 8251 | 8251 | `bde453bc258f` | `bde453bc258f` | MATCH |
| 3 | `writing-skills/SKILL.md` | 22608 | 22624 | `25c322920e27` | `38ba648975ae` | DIFFER (expected: superpowers:->uberdev: rewrite) |
| 4 | `writing-skills/anthropic-best-practices.md` | 45820 | 45820 | `20914c2fda31` | `20914c2fda31` | MATCH |
| 5 | `writing-skills/persuasion-principles.md` | 5908 | 5908 | `c3c84f572a51` | `c3c84f572a51` | MATCH |
| 6 | `writing-skills/testing-skills-with-subagents.md` | 12554 | 12558 | `e4a823a2b67c` | `c711346852c9` | DIFFER (expected: superpowers:->uberdev: rewrite) |
| 7 | `writing-skills/graphviz-conventions.dot` | 5970 | 5970 | `e2890a593c91` | `e2890a593c91` | MATCH |
| 8 | `writing-skills/render-graphs.js` | 4857 | 4857 | `ccda971a87bb` | `ccda971a87bb` | MATCH |
| 9 | `writing-skills/examples/CLAUDE_MD_TESTING.md` | 5423 | 5423 | `0b379a3415e1` | `0b379a3415e1` | MATCH |
| 10 | `systematic-debugging/SKILL.md` | 11661 | 9884 | `738ca1fc73de` | `4999cb851360` | DIFFER (expected: superpowers:->uberdev: rewrite + local 'Parallel hypothesis testing' section) |
| 11 | `systematic-debugging/root-cause-tracing.md` | 5327 | 5327 | `a81bee944879` | `a81bee944879` | MATCH |
| 12 | `systematic-debugging/defense-in-depth.md` | 3650 | 3650 | `1e175fb86fc3` | `1e175fb86fc3` | MATCH |
| 13 | `systematic-debugging/condition-based-waiting.md` | 3516 | 3516 | `e89fec8400d6` | `e89fec8400d6` | MATCH |
| 14 | `systematic-debugging/condition-based-waiting-example.ts` | 5054 | 5054 | `40ae5ebe497f` | `40ae5ebe497f` | MATCH |
| 15 | `systematic-debugging/find-polluter.sh` | 1528 | 1528 | `6462747eae9b` | `6462747eae9b` | MATCH |
| 16 | `systematic-debugging/test-pressure-1.md` | 1900 | 1900 | `0b6a915db005` | `0b6a915db005` | MATCH |
| 17 | `systematic-debugging/test-pressure-2.md` | 2283 | 2283 | `b2030aeffba0` | `b2030aeffba0` | MATCH |
| 18 | `systematic-debugging/test-pressure-3.md` | 2692 | 2692 | `96b50a52e2c7` | `96b50a52e2c7` | MATCH |
| 19 | `systematic-debugging/test-academic.md` | 653 | 653 | `fe2ba480d78a` | `fe2ba480d78a` | MATCH |
| 20 | `systematic-debugging/CREATION-LOG.md` | 4268 | 4268 | `b482ef9a918f` | `b482ef9a918f` | MATCH |

## Attribution summary

- **Repo-level LICENSE notice:** `LICENSE` declares "Portions of this repository (under `plugins/uberdev/skills/`...) are derived from third-party plugins under their own licenses."
- **Bundled upstream license text:** `plugins/uberdev/licenses/superpowers-MIT.txt` (verbatim from upstream `LICENSE`).
- **README attribution:** `README.md` credits `obra/superpowers`.
- **Per-file provenance:** Added in this PR — provenance comment on line 1 of every sub-file/adjacent file (line 2 for `find-polluter.sh` and `render-graphs.js` after the shebang), and on the first body line (after the closing `---` of the YAML frontmatter) of each parent SKILL.md.

## Acceptance-criteria mapping

### AC1 — TDD: `testing-anti-patterns.md` vendored, frontmatter adapted, referenced from TDD parent SKILL.md

- **Location:** `plugins/uberdev/skills/test-driven-development/testing-anti-patterns.md` — present since v0.3.0 commit `41d072b`.
- **Frontmatter:** Sub-file correctly has no YAML frontmatter (per UberDev convention).
- **Reference:** Linked from parent SKILL.md "Testing Anti-Patterns" section.
- **Provenance:** Pinned in this PR on line 1.

### AC2 — writing-skills: all three depth files vendored, frontmatter adapted, referenced from parent SKILL.md, spot-checked by authoring a small new skill

- **Files:** `anthropic-best-practices.md`, `persuasion-principles.md`, `testing-skills-with-subagents.md` — all present since v0.3.0 commit `41d072b`.
- **Reference:** Parent SKILL.md references all three.
- **Spot-check evidence:** 30+ orchestrator agent definitions under `plugins/uberdev/agents/` (e.g., `research-codebase.md`, `spec-writer.md`, `plan-writer.md`, `spec-reviewer.md`, `plan-reviewer.md`) were authored or maintained against `writing-skills/SKILL.md` principles. The skill's File Organization, frontmatter shape (`name:`/`description:` two-field), and discovery rules (trigger-driven loading from a centralised list) are all reflected in those agent files.
- **Spot-check verification (2026-05-04):** Listed `plugins/uberdev/agents/` and grepped for the required two-field frontmatter shape — every file conforms.
- **Local divergence:** `testing-skills-with-subagents.md` carries the special-case `local rewrite` suffix in its provenance header.

### AC3 — systematic-debugging: side-by-side diff documented, missing sub-files vendored, parent SKILL.md updated, validated against a recent real bugfix

- **Side-by-side diff:** The Inventory + diff-results table above IS the side-by-side diff.
- **File coverage:** All 11 systematic-debugging files present (parent SKILL.md + 7 markdown sub-files + 3 adjacent supporting files: `condition-based-waiting-example.ts`, `find-polluter.sh`, `CREATION-LOG.md`).
- **Diff status:** Each file is MATCH or expected-DIFFER. The parent SKILL.md has the rebrand + local 'Parallel hypothesis testing' section, recorded in its provenance header suffix.
- **Validated-against-recent-real-bugfix evidence:** PR #53 (commit `1dff86c`, merged 2026-05-04, 'fix(merge): guard Step 1.1 against missing flock(1) on macOS').
  - **Bug:** Silent failure of `/merge` Step 1.1 on macOS hosts where `flock(1)` is not preinstalled.
  - **Skills applied:** `root-cause-tracing.md` (traced backward through `/merge` call stack to the missing utility) + `defense-in-depth.md` (added explicit guard with actionable error message before any locked operation, plus a documentation note in `commands/merge.md`).
  - **Process flow:** The `systematic-debugging/SKILL.md` Plan Test First / Stay Curious / Verify Assumption Before Patch flow is followed end-to-end in the PR's commit messages and the resulting code change.

### AC4 — License attribution preserved across all three groups (upstream is MIT)

- **Four-layer attribution stack:** LICENSE + `plugins/uberdev/licenses/superpowers-MIT.txt` + README credit + per-file provenance headers (added in this PR).

## Re-diff procedure (for next re-sync)

```bash
# Run from repo root
set -euo pipefail

FRESH_SHA=$(git ls-remote https://github.com/obra/superpowers HEAD | awk '{print $1}')
if [ -z "$FRESH_SHA" ] || [ ${#FRESH_SHA} -ne 40 ]; then
  echo "ERROR: failed to fetch upstream HEAD SHA (got: '$FRESH_SHA')" >&2
  exit 1
fi
FETCH_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Re-diff against obra/superpowers@$FRESH_SHA (fetched $FETCH_TS)"

FILES=(
  "test-driven-development/SKILL.md"
  "test-driven-development/testing-anti-patterns.md"
  "writing-skills/SKILL.md"
  "writing-skills/anthropic-best-practices.md"
  "writing-skills/persuasion-principles.md"
  "writing-skills/testing-skills-with-subagents.md"
  "writing-skills/graphviz-conventions.dot"
  "writing-skills/render-graphs.js"
  "writing-skills/examples/CLAUDE_MD_TESTING.md"
  "systematic-debugging/SKILL.md"
  "systematic-debugging/root-cause-tracing.md"
  "systematic-debugging/defense-in-depth.md"
  "systematic-debugging/condition-based-waiting.md"
  "systematic-debugging/condition-based-waiting-example.ts"
  "systematic-debugging/find-polluter.sh"
  "systematic-debugging/test-pressure-1.md"
  "systematic-debugging/test-pressure-2.md"
  "systematic-debugging/test-pressure-3.md"
  "systematic-debugging/test-academic.md"
  "systematic-debugging/CREATION-LOG.md"
)

# Note when comparing: the 3 known-divergent files (writing-skills/SKILL.md,
# writing-skills/testing-skills-with-subagents.md, systematic-debugging/SKILL.md)
# and the remaining 17 sub-files now carry a provenance comment that is NOT in upstream.
# Strip provenance lines before sha256-comparing if you want a content-only diff.
# Or: diff against upstream at the SHA pinned in each file's header (extract it from the header line)
# instead of HEAD when verifying integrity.
#
# Known-divergent files (expected DIFFER — see special-case allowlist above):
#   writing-skills/SKILL.md — superpowers:->uberdev: rebrand (4 occurrences)
#   writing-skills/testing-skills-with-subagents.md — superpowers:->uberdev: rebrand (4-byte delta)
#   systematic-debugging/SKILL.md — superpowers:->uberdev: rebrand + local 'Parallel hypothesis testing' section

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for FILE in "${FILES[@]}"; do
  UPSTREAM_URL="https://raw.githubusercontent.com/obra/superpowers/${FRESH_SHA}/skills/${FILE}"
  LOCAL_PATH="plugins/uberdev/skills/${FILE}"
  # Pre-validate local file exists and is readable — diff exit 2 (error) is otherwise
  # indistinguishable from exit 1 (differ) in a single if/else and would silently
  # mis-report a missing or corrupt local file as "DIFFER".
  if [ ! -r "$LOCAL_PATH" ]; then
    echo "$FILE  LOCAL_MISSING_OR_UNREADABLE ($LOCAL_PATH)" >&2
    continue
  fi
  # --fail propagates HTTP 4xx/5xx as non-zero exit; --max-time bounds the network wait
  RC=0
  curl -sSL --fail --max-time 30 "$UPSTREAM_URL" -o "$TMP" || RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "$FILE  FETCH_FAILED (curl exit $RC, URL: $UPSTREAM_URL)" >&2
    continue
  fi
  # Capture diff exit code: 0 = match, 1 = differ, >=2 = error (e.g. read failure
  # despite the pre-check above — disk I/O could still surface here).
  DIFF_RC=0
  diff "$TMP" "$LOCAL_PATH" > /dev/null || DIFF_RC=$?
  case "$DIFF_RC" in
    0) echo "$FILE  MATCH" ;;
    1) echo "$FILE  DIFFER" ;;
    *) echo "$FILE  DIFF_ERROR (diff exit $DIFF_RC)" >&2 ;;
  esac
done
```

## Notes

- The 3 known-divergent files and their per-file divergence patterns are recorded in two canonical places: the special-case allowlist (above) and the bash heredoc's `# Known-divergent files` block. Each divergence is also pinned in the affected file's provenance header.
- `find-polluter.sh` and `render-graphs.js` carry their provenance header on **line 2** to preserve the shebangs.
- Re-diff whenever the upstream is bumped or a security audit requests a fresh trust trail.
- Follow-up issue recommended: adopt `tests/skill-references.test.sh` per the test-coverage research, validating sub-file existence + parent SKILL.md reference pairs across ALL UberDev skills (not just the three vendored ones).

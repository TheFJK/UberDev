# CLAUDE.md — UberDev (project-local)

> Project-specific rules for the UberDev plugin repo.
> Inherits from `~/.claude/CLAUDE.md`. Project rules win on conflict.

---

## Bump version EVERYWHERE before merge (MANDATORY)

**Every user-facing change MUST arrive on `main` with the project version advanced.** The invariant binds the **landing commit** — the commit that actually puts the change on `main` — not every pull request along the way. If users never see a version change they never pull the update from the marketplace, and the change is invisible to them no matter how good it is.

Which commit that is depends on the lane the change came through, and one lane deliberately forbids the PR author from bumping at all. Check the lane before reading the diff.

### Which commit carries the bump — the three lanes

| Lane | Commit that carries the bump | What guarantees it |
|---|---|---|
| **`/goal`** | a `chore(release): vX.Y.Z` commit the pipeline pushes onto the PR branch on an **earlier pass** — the pass that pushes it deliberately withholds `/merge`, so the checks the push restarted can settle, and the dispatch happens on a later pass | `_uberdev_goal_ensure_version_bump` (`plugins/uberdev/lib/goal-state.sh`), called from the barrier-gated merge dispatch in `plugins/uberdev/lib/goal-watch.sh` (step 2c). It **fails closed**: any status it does not recognise as "bumped" withholds the `/merge` dispatch, and each failure stage it *does* recognise writes a `goal_merge_deferred` audit row with `reason=version_bump_failed` — the caller's catch-all arm withholds on an unrecognised status without writing a row of its own. Landing unbumped is the bug, so merging is never the fallback. |
| **`/solve` + `/turbo` fleet PRs** | the integration commit that lands the stack — `chore(stack): land #A #B … (vX.Y.Z)` — **once per stack**, never once per PR | `plugins/uberdev/skills/solve-fleet/workflow.js` tells every solver, in the dispatch prompt itself: *Do NOT bump the project version.* N solvers cut from one base all resolve the **same** next version; git auto-merges that identical edit with no conflict, so two intended releases collapse into one and a release is lost silently. |
| **Hand-authored PR landed directly** | the PR's own commits, or an immediately-preceding `chore(release): vX.Y.Z` commit on the same branch | the author. Nothing automated covers this lane. |

**A fleet PR whose diff carries no version surface is compliant.** Its bump belongs to the landing commit, and `plugins/uberdev/skills/solve-fleet/workflow.js` forbids the solver from writing one — so reviewing such a PR as an unbumped user-facing change is a false positive, not a blocker.

The lane carve-out governs **which commit carries the bump**, never **whether** a user-facing change may ship unbumped. **No exception for "small fixes" — even one-line patches get a patch-version bump on the commit that lands them.**

### How to bump — one command, never by hand

```bash
bash plugins/uberdev/lib/bump-version.sh <X.Y.Z>
```

- Idempotent: re-running at the current version is a no-op success, no CHANGELOG churn.
- Refuses (exit 3) **before editing anything** when the surfaces already disagree — a half-bumped repo needs a human, not more `sed`. Every surface is re-grepped afterwards; a miss fails loudly (exit 4).
- **Never runs `git` or `gh`**: no commit, no tag, no push, no release. It edits files and prints the remaining ritual; the destructive steps stay in the operator's foreground.
- **Never parallel-bump.** Two PRs cut off the same base resolve the same next version. Decide land order first, then bump each one to the next free version as it lands (RFC 0012 §9).

### Version locations (keep this list current)

**Six file surfaces — all must agree, and `bump-version.sh` moves every one of them:**

1. **`plugins/uberdev/.claude-plugin/plugin.json`** — `version` field (canonical source of truth; this is what `/plugin` reads).
2. **`.claude-plugin/marketplace.json`** — `plugins[0].version` field (what the marketplace listing shows).
3. **`README.md`** — top-of-file `![Version](https://img.shields.io/badge/version-X.Y.Z-blue)` badge.
4. **`CHANGELOG.md`** — new `## [X.Y.Z] — YYYY-MM-DD` section (Keep a Changelog 1.1.0 format; SemVer). The script inserts a dated stub; replace the placeholder with the real notes.
5. **`tests/goal.test.sh`** — the `G20: version bump locked (X.Y.Z)` block: one `assert_version_bump "$REPO_ROOT" "<ver>"` argument plus its echo header.
6. **`tests/solve-claim.test.sh`** — the `== Version bump A.B.C -> X.Y.Z propagated ==` block: the same one-argument shape.

Surfaces 5 and 6 are the CI release-ratchet locks. They live in no manifest, so a missed bump sails through every local manifest check and still turns CI red on a clean `main`.

**Two post-merge operator steps, by hand, only after the landing commit is on `main`:**

7. **Git tag** — `git tag vX.Y.Z && git push origin vX.Y.Z`.
8. **GitHub Release** — `gh release create vX.Y.Z --title "vX.Y.Z" --notes-file <changelog-section>` so the Releases tab shows it.

### Workflow

- Pick the SemVer bump: `fix:` → patch, `feat:` → minor, breaking → major.
- Run `bash plugins/uberdev/lib/bump-version.sh <X.Y.Z>`, fill in the CHANGELOG section, and put the result on whichever commit lands the change (see the lane table above).
- Verify the locks locally before pushing: `bash tests/goal.test.sh && bash tests/solve-claim.test.sh` (the authoritative full set is the run list in `.github/workflows/test.yml`).
- Tag and publish the release only once the landing commit is on `main` — one release per landing, sequentially.

### Why this is a hard rule

The marketplace manifest is what tells an installed plugin there is anything to pull. Without a bump the listing never changes and users keep running stale code. The README badge is the first thing a visitor sees — when it lags, the project reads as dead.

And the ratchet is *equality*, not *advancement*: the two CI locks assert that the surfaces agree with each other at a hardcoded literal, not that the number went up. A landing that bumps nothing is consistently stale and stays green. Closing that gap in CI is tracked as issue **#386**; until then this rule, and the `/goal` guarantor above, are what stand in for it.


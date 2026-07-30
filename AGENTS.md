# AGENTS.md — UberDev (project-local)

> Project-specific rules for the UberDev plugin repo.
> Inherits from `~/.codex/AGENTS.md`. Project rules win on conflict.

---

## Bump version EVERYWHERE before merge (MANDATORY)

**Every user-facing merge to `main` MUST bump the version in every location below — in the same PR (or in the immediately-preceding `chore(release):` commit on the same branch).** If users don't see a version change, they won't pull the update from the marketplace, and the change is invisible to them.

### Version locations (all must match — keep this list current)

1. **`plugins/uberdev/.claude-plugin/plugin.json`** — `version` field (canonical source of truth; this is what `/plugin` reads).
2. **`.claude-plugin/marketplace.json`** — `plugins[0].version` field (what the marketplace listing shows).
3. **`README.md`** — top-of-file `![Version](https://img.shields.io/badge/version-X.Y.Z-blue)` badge.
4. **`CHANGELOG.md`** — new `## [X.Y.Z] — YYYY-MM-DD` section with the changes (Keep a Changelog 1.1.0 format; SemVer).
5. **Git tag** — `git tag vX.Y.Z` on the release commit (created by the `chore(release): vX.Y.Z` commit).
6. **GitHub Release** — `gh release create vX.Y.Z --notes-file <changelog-section>` so the Releases tab shows it.
7. **Test version-locks (CI-gating release-ratchet guards)** — two CI-listed tests hardcode the exact version and turn CI red if not bumped: `tests/goal.test.sh` (the `G20: version bump locked (X.Y.Z)` block — plugin/marketplace/README/CHANGELOG asserts) and `tests/solve-claim.test.sh` (the `== Version bump A.B.C -> X.Y.Z propagated ==` block). The asserts mix plain, single-escaped (`0\.32\.0`) and double-escaped (`0\\.32\\.0`) regex forms — a literal multi-form replace is cleanest. These are NOT in the marketplace manifest, so a missed bump passes local manifest checks but fails CI on a clean `main`.

### Workflow

- Pick the SemVer bump: `fix:` → patch, `feat:` → minor, breaking → major.
- Update all seven locations above in one commit titled `chore(release): vX.Y.Z`.
- Create the git tag and GitHub Release after merge.
- Verify drift before opening the PR: `grep -RnE 'version["[:space:]]*[:=]|version-[0-9]' plugins/uberdev/.claude-plugin/plugin.json .claude-plugin/marketplace.json README.md` — all three should show the same `X.Y.Z`.
- Verify the test-locks too: `grep -RnE '0[.\\]+<previous-minor>[.\\]+0' tests/goal.test.sh tests/solve-claim.test.sh` should return nothing (all bumped to the new version).

### Why this is a hard rule

Without a version bump, Codex's auto-update for the marketplace doesn't pick up the new manifest, and users keep running stale code. The version badge in the README is the first thing users see — when it lags, they assume the project is dead. **No exception for "small fixes" — even one-line patches get a patch-version bump.**


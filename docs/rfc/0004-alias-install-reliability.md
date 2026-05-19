# RFC 0004 — Alias-Install Reliability

| Field          | Value                                                                                                                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**     | Draft (2026-05-19 — awaiting implementation)                                                                                                                                                                                                 |
| **Author**     | TheFJK                                                                                                                                                                                                                                       |
| **Created**    | 2026-05-19                                                                                                                                                                                                                                   |
| **Targets**    | NEW: `docs/rfc/0004-alias-install-reliability.md`. MODIFIED: `plugins/uberdev/lib/aliases-sync.sh`, `plugins/uberdev/hooks/session-start`, `tests/aliases.test.sh`, `tests/solve-claim.test.sh`, `README.md`, `CHANGELOG.md`, `.claude-plugin/marketplace.json`, `plugins/uberdev/.claude-plugin/plugin.json` |
| **Supersedes** | —                                                                                                                                                                                                                                            |
| **Builds on**  | Issue #21 (auto-alias sync via the `SessionStart` hook) — this RFC hardens that mechanism, it does not replace it.                                                                                                                            |
| **Tracking**   | none — ad-hoc design (reliability hardening, not an issue resolution)                                                                                                                                                                        |
| **Tier**       | Small–Medium (two behaviour files, no new command, no contract change to existing commands; a removed dependency plus an additive notice channel)                                                                                            |

---

## 1. Summary

The seven short-form alias forwarders — `/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`, `/dev` — are auto-installed into `~/.claude/commands/` on first session by the `SessionStart` hook (issue #21). Today that path is **fail-open and silent**: it installs *nothing* when `jq` is absent, and it skips an individual alias on collision — in both cases with no signal to the user. A new user can finish installation, expect `/turbo`, find it missing, and have no way to know why.

This RFC makes alias provisioning:

1. **jq-independent** — the forwarders install regardless of whether `jq` is on `PATH`; and
2. **observable** — any skipped or failed alias, and the first-run result, are surfaced in the session context instead of disappearing onto `stderr`.

The `SessionStart` hook stays the provisioning lever — Claude Code has no install-time hook (see §2.3). It is *hardened*, not relocated.

## 2. Motivation

### 2.1 A reliability gap against a stated promise

`README.md:66` already tells users: *"The seven short-form aliases … are auto-installed on first session and refreshed on plugin upgrade."* This is not a missing feature — it is a **reliability gap against a contract the project already advertises**. When the gap trips, the user silently gets less than the README promised.

### 2.2 Two silent failure modes

A codebase investigation (2026-05-19) isolated two root causes.

**(a) Incidental `jq` coupling.** `hooks/session-start:14-23` hard-requires `jq` — it needs it to JSON-encode the session-context injection safely — and `exit 0`s immediately if `jq` is missing, *before* control ever reaches the alias-sync block at `session-start:52`. Independently, `aliases_sync_main` re-checks `jq` itself (`aliases-sync.sh:106`, `command -v jq … || return 0`). Yet across the whole alias path `jq` is used for **exactly one thing**: `jq -r .version` against `plugin.json` (`aliases-sync.sh:118`) to drive the version-marker idempotency check. The dependency is incidental, not structural — but its effect is total: a new user on a machine without `jq` gets **zero aliases and zero alias-specific warning**.

**(b) Invisible skips.** `aliases_sync_main` already computes `SKIPPED_LIST` and `FAILED_LIST`, but it emits a one-line summary only to **`stderr`**, and only on first run (`aliases-sync.sh:173-183`). The collision case is *correct* behaviour — a pre-existing, un-managed `~/.claude/commands/turbo.md` must not be clobbered, so `/turbo` is rightly skipped — but the user is never told that `/turbo` is missing *because* their own file won, nor what to do about it.

### 2.3 No install-time hook exists — the hook is the right lever

Research against the Claude Code plugin documentation (early 2026) confirms: there is **no PostInstall / install-time plugin hook**. A lifecycle-hook feature request (anthropics/claude-code#11240) was closed unshipped. The plugin manifest has **no field for un-prefixed (top-level) command aliases** — plugin commands are always `/<plugin>:<command>`. Dropping forwarder files into `~/.claude/commands/` genuinely requires plugin-authored code, and the earliest such code can run is a `SessionStart` hook. UberDev's existing `matcher: "startup|clear|compact"` hook is therefore the *idiomatic* mechanism. The correct fix hardens it; it does not move the work elsewhere (see §6.2).

## 3. Design

### 3.1 jq-independent version read

`aliases-sync.sh` gains a small helper, `_aliases_read_version <plugin_json_path>`, that extracts the `version` value from the plugin's **own** `.claude-plugin/plugin.json` with `sed`:

```sh
sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1
```

This reads a file the plugin **ships and controls**, in which `"version": "x.y.z"` is a single normal line. An empty result is treated exactly as a bad `jq -r .version` read is treated today — the caller fails open (`return 0`, a no-op). The `command -v jq … || return 0` gate at `aliases-sync.sh:106` is removed. After this change `aliases-sync.sh` has **no `jq` dependency at all**.

A test (§4) asserts `_aliases_read_version` returns the same string as `jq -r .version` on the real manifest, so any future reformatting of `plugin.json` that breaks the parse is caught in CI.

### 3.2 `SessionStart` runs alias-sync unconditionally

The alias-sync block (`session-start:52-56`) moves to immediately **after** `PLUGIN_ROOT` resolution (`session-start:8`) and **before** the `jq` guard. `jq` remains required only for the context-injection JSON encoding — its original, legitimate purpose. The forwarders are written before the hook can possibly `exit` on a missing `jq`.

### 3.3 The notice channel

`aliases_sync_main` composes a single human-readable notice from first-run / `SKIPPED_LIST` / `FAILED_LIST` state and assigns it to an exported global, `UBERDEV_ALIAS_NOTICE` (the empty string when there is nothing to report — i.e. steady state). The hook already `source`s the library, so it reads that variable directly after the `aliases_sync_main` call:

- **`jq` present** — a non-empty notice is wrapped as an `<important-reminder>…</important-reminder>` block and concatenated into `session_context` alongside the existing `warning_message` and `gh_warning`. `jq` then encodes the whole string in one pass; the encoding path is **unchanged** and stays the single safe-encoding choke point.
- **`jq` absent** — the alias forwarders are *already installed* by this point. The hook's existing jq-missing branch hand-builds JSON and cannot safely encode arbitrary text, so it emits one **constant** notice — `uberdev: jq not found — install jq for the full session context` — which is safe to hand-encode precisely because it contains no interpolation and no user-derived data. As a bonus this finally makes the *previously silent* jq-missing degradation of the whole hook visible.

The `stderr` summary is retained for backward compatibility (the `/uberdev:install-aliases` command and existing test `S1` both rely on it); `UBERDEV_ALIAS_NOTICE` becomes the authoritative *user-facing* channel.

### 3.4 Notice content — conditional and low-noise

| State                       | Notice text                                                                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| First run, all installed    | `uberdev: installed N short-form aliases (/issue, /solve, …). Opt out with UBERDEV_NO_AUTO_ALIAS=1.`                                                      |
| Collision skip              | One aggregated line naming every skipped alias: `uberdev: these short-form aliases were not installed because a non-uberdev file already exists at ~/.claude/commands/<name>.md: /turbo /merge — use /uberdev:<name>, or rename the existing file and run /uberdev:install-aliases.` |
| Write failure               | `uberdev: failed to install alias(es): <names>. Re-run /uberdev:install-aliases.`                                                                        |
| Steady state (all in sync)  | *(empty — nothing is injected)*                                                                                                                          |

The notice fires only when there is something to say. After a clean first run, every subsequent session is silent — no per-session noise.

### 3.5 Safety invariants — unchanged

`aliases_sync_main` keeps its **fail-open contract**: it always returns `0`; a missing `PLUGIN_ROOT`, an unreadable manifest, a symlinked `~/.claude/commands`, or an empty version string each short-circuit to a no-op. Collisions still **never** overwrite a hand-authored file — the marker-scoped check (`managed-by: uberdev-aliases`) is untouched. This RFC makes a skip **visible**, not **aggressive**: a user's own `/turbo` always wins; we just tell them it did.

### 3.6 In-passing cleanup

The comment at `session-start:45-46` still enumerates only five of the seven aliases (`/issue, /solve, /turbo, /simplify, /review-pr` — `/merge` and `/dev` were never added). It is corrected while editing that file.

## 4. File impact summary

| File                                          | Change                                                                                                                |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `docs/rfc/0004-alias-install-reliability.md`  | NEW — this RFC.                                                                                                       |
| `plugins/uberdev/lib/aliases-sync.sh`         | MOD — add `_aliases_read_version()`; remove the `jq` gate; build and export `UBERDEV_ALIAS_NOTICE`.                   |
| `plugins/uberdev/hooks/session-start`         | MOD — move alias-sync above the `jq` guard; inject the notice (jq-present path); emit the constant jq-missing notice; fix the stale five-of-seven comment. |
| `tests/aliases.test.sh`                       | MOD — new cases: version-read parity, notice composition, jq-masked install, notice surfaced on collision and on first run. |
| `tests/solve-claim.test.sh`                   | MOD — retarget the version-drift assertions (pinned to `0.28.0`) to `0.29.0`.                                          |
| `README.md`                                   | MOD — version badge; clarify near line 66 that alias auto-install no longer requires `jq`.                            |
| `CHANGELOG.md`                                | MOD — new `## [0.29.0]` section.                                                                                      |
| `.claude-plugin/marketplace.json`             | MOD — `plugins[0].version` → `0.29.0`.                                                                                |
| `plugins/uberdev/.claude-plugin/plugin.json`  | MOD — `version` → `0.29.0`.                                                                                           |

**Testing strategy.** Extend the existing bash harness (`tests/aliases.test.sh`, the `A`/`S` sections; run in CI via `.github/workflows/test.yml`). New `S`-series cases:

- **jq-masked install** — run `session-start` (and `aliases_sync_main` directly) with `jq` removed from `PATH`; assert all seven forwarders *and* the version marker are written.
- **version-read parity** — `_aliases_read_version` against the real `plugin.json` equals `jq -r .version`.
- **collision surfaced** — extend `S5`: assert the skip notice appears in the hook's stdout `additionalContext`, not only on `stderr`.
- **first-run surfaced** — assert the first-run notice appears in `additionalContext`.

The `A1`–`A6` structural checks (notably the `A6` `ALIASES` ↔ `allowed-tools` drift check) and the existing `S1`–`S8` lifecycle cases are unaffected and must stay green.

## 5. Migration / rollout

A user-facing reliability change → a **minor** version bump `0.28.0 → 0.29.0` across every location, per the project "bump version everywhere" mandate: `plugin.json`, `marketplace.json`, the `README.md` badge, a `CHANGELOG.md` `## [0.29.0] — 2026-05-19` section, the `v0.29.0` git tag, and the GitHub Release. (Minor rather than patch because the notice channel is genuinely new user-visible behaviour, not only a bug fix.)

The change is **backward-compatible**. Existing users who already have the forwarders installed see a steady-state no-op (empty notice); the version bump triggers the usual single refresh pass. The `~/.claude/.uberdev-aliases-version` marker file format is **unchanged**, so there is no marker migration.

## 6. Alternatives considered

### 6.1 Surface failures only — keep the `jq` dependency

Make skips and failures visible, but leave `jq` load-bearing for alias-install. **Rejected:** a jq-less machine still ends up with zero aliases — the user is merely *told* it failed. This treats the symptom, not the root cause. (This was the explicit scope fork put to the user; the user chose guarantee + surface — see §9 Q1.)

### 6.2 Provision aliases from `install.sh`

Have the bootstrap `install.sh` run the alias sync itself after `/plugin install`. **Rejected as the primary mechanism:** `install.sh` is not run by every user — many install via `/plugin marketplace add` + `/plugin install` directly inside Claude Code and never touch the script — and it does not run on plugin *upgrades*. It would be a second, drift-prone code path delivering no reliability gain over a hardened hook (which already runs for every user, every session). Out of scope; see §7.

### 6.3 Status file instead of an exported shell variable

Have `aliases_sync_main` write a `~/.claude/.uberdev-aliases-status` file that the hook reads. **Rejected:** the hook *already* `source`s the library, so a shell variable is sufficient. A file would add a new artifact with its own lifecycle (uninstall cleanup, staleness handling) for no benefit at the one call site that needs it.

### 6.4 Content-hash idempotency in `${CLAUDE_PLUGIN_DATA}`

Replace the version-keyed marker with a content-hash sentinel — the pattern Claude Code's own plugin docs recommend for "run once after install, re-run on update" work. **Deferred, not adopted here:** it would additionally fix two latent bugs — a skipped alias stays "sticky" until the next version bump, and a new alias added without a version bump never propagates — but it changes the idempotency contract and the marker file's location and format, and needs a migration path. That is a separate concern from the stated reliability goal; it is captured as follow-up work (§7).

## 7. Open questions

None blocking. The single design fork — *how far the fix goes* — was resolved with the user as **guarantee + surface** (§9, Q1). Scope is focused enough for a single implementation plan.

Deliberately deferred to a follow-up issue, not designed here:

- Content-hash idempotency (§6.4) and the two latent bugs it would close.
- Retry of a previously skipped alias once the colliding file is removed (today a skip is "sticky" until the next version bump; the manual `/uberdev:install-aliases` is the current recovery path).
- `install.sh`-side provisioning (§6.2).

## 8. Risk / rollout

- **Risk: the `sed` version read mis-parses an unusually formatted `plugin.json`** (multi-line `version`, exotic whitespace). *Mitigation:* the manifest is the plugin's own controlled file and is conventionally formatted; the version-read-parity test (§4) catches any reformatting that breaks the parse; an empty read fails open to a no-op, exactly as a bad `jq` read does today.
- **Risk: notice noise** — a message on every session. *Mitigation:* the notice is conditional and empty in steady state (§3.4), so the post-first-run happy path stays silent.
- **Risk: reordering regression** — moving the alias-sync block changes hook control flow. *Mitigation:* the `S1`–`S8` hook-integration cases already exercise the full lifecycle, run in CI, and must stay green; the new jq-masked case adds the previously-missing coverage.
- **Rollback:** revert the two behaviour files and the version edits. The marker file format is unchanged, so a rollback is clean with no user-side migration.

## 9. Decision log

| #   | Decision              | Choice                                                                                                                          | Source                         |
| --- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Q1  | Fix depth             | **Guarantee + surface** — decouple from `jq` *and* surface skips/failures; not surface-only.                                    | User.                          |
| D2  | Mechanism             | Harden the existing `SessionStart` hook — Claude Code has no install-time hook (anthropics/claude-code#11240, closed unshipped). | Author (research).             |
| D3  | Version read          | A `jq`-free `sed` parse of the plugin's own `plugin.json`; not a separate plain-text `VERSION` file.                            | Author.                        |
| D4  | lib → hook channel    | An exported shell variable `UBERDEV_ALIAS_NOTICE`; not a status file (the hook already `source`s the library).                  | Author.                        |
| D5  | jq-missing notice     | A fixed constant string (safe to hand-encode); the dynamic notice is emitted only on the jq-present path.                       | Author.                        |
| D6  | Published artifact    | This RFC (`docs/rfc/`, tracked). `docs/uberdev/specs/` is gitignored, local-only — established by RFC 0003 §9 D9.               | Author (`.gitignore` — `docs/uberdev/*`). |
| D7  | Out of scope          | Content-hash idempotency, sticky-collision retry, and `install.sh` provisioning → a follow-up issue.                            | Author.                        |

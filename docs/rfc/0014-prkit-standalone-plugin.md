# RFC 0014 — `prkit`: standalone PR-phase plugin generated from UberDev

| Field | Value |
| --- | --- |
| **Status** | Accepted (brainstorm complete) → hand to `write-plan` |
| **Author** | TheFJK |
| **Created** | 2026-07-12 |
| **Tier** | Medium (new build tooling + one generated repo) |
| **Target ver** | prkit `0.1.0` (independent SemVer); UberDev gains `tools/prkit/` (no user-facing UberDev change) |
| **Related** | RFC 0001/0002 (`review-pr` phases), `skills/merge-pipeline`, `skills/post-impl-review`, RFC 0013 (dispatch/model-routing lib) |

---

## 1. Decision

Extract UberDev's **PR phase** (review → fix → simplify → land) into a new, standalone, coexist-safe Claude Code plugin named **`prkit`**, shipped from its **own repo**, and kept current by a **generator** that treats UberDev as the single source of truth. The generator copies the PR-phase dependency subgraph, applies a namespace-rewrite ruleset (`uberdev:` → `prkit:`, `UBERDEV_*` → `PRKIT_*`, config file, path fragments, label/trailer values, metadata), scaffolds the standalone repo files, and runs a verification gate that fails the build on any surviving `uberdev` token, dangling namespace reference, or missing lib/policy file. The prkit repo is a **build artifact** — regeneration prevents drift as UberDev's `review-pr`/`merge` evolve.

---

## 2. Commands shipped

| Command | Purpose |
|---|---|
| `/prkit:review-pr` | Parallel-fanout post-implementation review + auto-fix + CI-failure routing |
| `/prkit:simplify` | Reuse/quality/efficiency lens audit + fix |
| `/prkit:merge` | Trust-trail check → strategy pick → conflict resolution → land |

---

## 3. Goals / Non-goals

### Goals
- Minimal, self-contained plugin with the three PR-phase commands and their full transitive dependency graph.
- Coexistence: installable at the same time as UberDev with **no** command / agent / skill / label / env-var collision.
- Single source of truth in UberDev; a deterministic, idempotent, re-runnable generator so prkit never rots.
- A verify gate strong enough that a botched rewrite fails the build instead of shipping broken.

### Non-goals (YAGNI cuts for v1)
- **No hooks.** UberDev's SessionStart injects the whole `using-uberdev` skill and installs aliases; prkit ships neither. Users invoke `/prkit:review-pr` etc. directly.
- **No short-form aliases** (`/review-pr`, `/simplify`, `/merge`) — they would collide with UberDev's under coexistence.
- **No** brainstorm / solve / turbo / goal / testers / uberthink / uberscan / cluster / dev machinery.
- No runtime code sharing between the two installed plugins (each is self-contained via its own `${CLAUDE_PLUGIN_ROOT}`).

---

## 4. Locked decisions (from brainstorm)

| Axis | Decision | Consequence |
|---|---|---|
| Coexist with full UberDev | **Yes** | Forces `prkit:` namespace rewrite of every internal reference. |
| Name / namespace | **`prkit`** | Commands `/prkit:*`; agents `prkit:*`; skills `prkit:*`. |
| Location | **Brand-new repo** | prkit gets its own marketplace.json, README, LICENSE, CHANGELOG, CI, SemVer. |
| Sync relationship | **Generator script** | SSOT = UberDev; generator lives in `tools/prkit/`; prkit repo is generated. |
| `/merge` in scope | **Yes** | Full PR phase. Also required: `review-pr` reads CI constants defined in the `merge-pipeline` skill, so that skill ships regardless. |

---

## 5. Architecture

### 5.1 Two repos, one source of truth

```
UberDev repo (this repo)                     prkit repo (new, generated)
─────────────────────────                    ───────────────────────────
plugins/uberdev/            ──generate──►     plugins/prkit/
  commands/ agents/ …                           commands/ agents/ …  (namespace-rewritten)
tools/prkit/                                   .claude-plugin/marketplace.json
  generate.sh  manifest.txt                    README.md LICENSE CHANGELOG.md
  rewrite-rules  templates/  verify.sh         .github/workflows/  .gitignore
docs/rfc/0014-prkit-standalone-plugin.md       (this RFC stays in UberDev)
```

The generator **writes into a target directory** (a checkout/worktree of the prkit repo) passed as `--target`. It never commits or pushes; committing prkit is a separate, explicit step in the prkit repo.

### 5.2 prkit repo layout (generated)

```
prkit/                                   # repo root
├── .claude-plugin/marketplace.json      # lists prkit; "source": "./plugins/prkit"
├── plugins/prkit/
│   ├── .claude-plugin/plugin.json       # metadata only (name=prkit, version, …)
│   ├── commands/  (3)
│   ├── agents/    (14)
│   ├── skills/
│   │   ├── post-impl-review/SKILL.md
│   │   └── merge-pipeline/SKILL.md + lib/discover.sh
│   ├── lib/       (11)
│   └── policy/model-routing-v1.json
├── README.md  LICENSE  NOTICE  CHANGELOG.md  .gitignore
└── .github/workflows/ci.yml            # bash -n + ast.parse + jq + tomllib + inline uberdev grep
```

Mirroring `plugins/prkit/` (vs. plugin-at-repo-root) keeps generator copy paths uniform (`plugins/uberdev/X` → `plugins/prkit/X`) and matches the marketplace `source: ./plugins/<name>` pattern already used in UberDev.

### 5.3 Copy manifest (the PR-phase subgraph — 32 files)

Source paths under `plugins/uberdev/`. Authoritative, verified copy set.

**commands/ (3):** `review-pr.md`, `simplify.md`, `merge.md`

**agents/ (14):**
- Reviewers (via `post-impl-review` fanout): `code-reviewer.md`, `silent-failure-hunter.md`, `type-design-analyzer.md`, `comment-analyzer.md`, `pr-test-analyzer.md`
- Fixers: `code-fixer.md`, `code-simplifier.md`
- CI-failure path: `ci-failure-classifier.md`, `ci-code-fixer.md`, `ci-rebase-handler.md`
- Merge path: `trust-trail-evaluator.md`, `merge-strategy-decider.md`, `conflict-resolver.md`
- Issue sink (shared): `findings-to-issues.md`

**skills/ (2 + skill-local lib):** `post-impl-review/SKILL.md`, `merge-pipeline/SKILL.md`, `merge-pipeline/lib/discover.sh`

**lib/ (11):** `child-dispatch.sh`, `agent-dispatch.sh`, `dispatch.sh`, `config-read.sh`, `model_routing.py`, `run_manifest.py`, `live-semaphore.sh`, `child-receipts.py`, `child-inputs.py`, `command-workspace.py`, `secret-scan.sh`

**policy/ (1):** `model-routing-v1.json` — default routing policy resolved via `${CLAUDE_PLUGIN_ROOT}/policy/model-routing-v1.json`. **Correction over the initial dependency trace** (missed because it is a runtime data file loaded by path, not a Python import).

**Explicitly excluded:** `policy/solve-run-tree-v1.json` (solve-only), `lib/goal-state.sh` (consumer-side, read by `/goal`), all hooks, `lib/aliases-sync.sh` + `commands/install-aliases.md`, everything else in UberDev.

The manifest is stored declaratively (`tools/prkit/manifest.txt`) so the copy set is auditable and the verify gate can cross-check it.

### 5.4 Rewrite ruleset (ordered, allowlisted — NOT a blind sed)

Applied to every copied file's contents; order matters; each rule is scoped to avoid over-rewriting.

1. **Namespace references** — `uberdev:<name>` in the three forms → `prkit:<name>`: `subagent_type: uberdev:X` / `subagent_type=uberdev:X`; `Skill(uberdev:X)`; `/uberdev:X` prose. Only for **in-set** targets (3 commands, 14 agents, 2 skills).
2. **Out-of-set reference neutralization** — `/uberdev:goal` and `/uberdev:solve` are prose-mentioned but **not** in prkit. Do **not** rewrite into dangling `/prkit:goal` / `/prkit:solve`; remove or reword the chaining prose (merge's `auto_review_on_merge` `/goal` carve-out; review-pr's `locked`-marker note read by `/goal`). Sites enumerated at plan time.
3. **Env-var prefix** — `UBERDEV_` → `PRKIT_` across **all** copied `.sh` and `.py` files (~130 vars). Producer and consumer are both in-set, so uniform rewrite stays consistent.
4. **Config file name** — `uberdev.local.md` → `prkit.local.md` (and `.claude/uberdev.local.md` path form).
5. **Path fragments** — literal `plugins/uberdev/` → `plugins/prkit/`; the `uberdev-codex` fallback path in `config-read.sh` → `prkit-codex` **or dropped** (prkit ships no codex variant in v1; drop is simpler — decide at plan time).
6. **Label / trailer VALUES** (isolate prkit's trust domain from UberDev's):
   - `uberdev-approved` → `prkit-approved` (trust trailer/label; `PRKIT_APPROVED_LABEL` default value)
   - `uberdev-executable` → `prkit-executable`
   - findings-to-issues marker slug (default `review-pr`, marker `<slug>-finding`) and `review-pr:pending`-style labels → prkit-namespaced. Concrete values finalized at plan time; **invariant: prkit and UberDev must never read/write each other's labels or trailers.**
7. **Metadata** — `plugin.json`/`marketplace.json` `name`/`description`/`author`/`homepage`/`repository`/`version`; README title; product-name prose in generated docs → prkit's values. (Origin attribution intentionally preserved in `LICENSE`/`NOTICE`.)

### 5.5 Scaffold templates (standalone-only files)

Emitted/refreshed from `tools/prkit/templates/`, not copied from UberDev:
- `plugin.json` (metadata only — convention-based discovery, no command/agent/skill arrays)
- `marketplace.json` (single prkit entry, `source: ./plugins/prkit`)
- `README.md` (prkit-focused: what it is, install, the three commands, runtime deps `gh`/`git`/`jq`/`python3`, optional `gitleaks`)
- `LICENSE` (MIT) + `NOTICE` (credits UberDev / Superpowers / pr-review-toolkit / code-simplifier origins — carried from `plugins/uberdev/licenses/*`)
- `CHANGELOG.md` (Keep a Changelog; `## [0.1.0] — 2026-07-12`)
- `.gitignore`, `.github/workflows/ci.yml`

### 5.6 Verify gate (anti-drift / anti-broken-namespace)

Runs at the end of every generation; non-zero exit fails the build. Also runnable standalone in prkit CI.

- **Token guard:** no `uberdev` (case-insensitive) or `UBERDEV_` survives under `plugins/prkit/`, except an explicit allowlist (LICENSE/NOTICE origin attribution).
- **Referential integrity:** every `subagent_type: prkit:X` ↔ `agents/X.md`; every `Skill(prkit:X)` ↔ `skills/X/SKILL.md`; every `${CLAUDE_PLUGIN_ROOT}/lib/Y` and `/policy/Z` reference resolves to a copied file; **no** residual out-of-set ref (`prkit:goal`, `prkit:solve`).
- **Syntax:** `bash -n` on every `.sh`; `python3 -m py_compile` on every `.py`; `jq empty` on every `.json`.
- **Manifest completeness** is enforced by `tests/prkit-manifest.test.sh` (count-lock + every source exists), not by `verify.sh`; verify's own non-vacuity + shape checks assert the generated tree is plausibly-sized and has the required files.

---

## 6. Component breakdown (generator, under `tools/prkit/`)

| Component | Purpose | Interface | Depends on |
|---|---|---|---|
| `manifest.txt` | Declarative copy set (paths grouped by dir) | data | — |
| `rewrite-rules` | The §5.4 ruleset as data + a tiny applier | `apply_rewrites <file>` | manifest |
| `templates/` | Scaffold files with `{{VERSION}}`/`{{DATE}}` placeholders | data | — |
| `generate.sh` | Orchestrator: preflight → clean → copy → rewrite → scaffold → verify → summary | `generate.sh --target <dir> [--version X.Y.Z]` | all above |
| `verify.sh` | The §5.6 gate | `verify.sh <prkit-root>` | — |

**Stage flow (`generate.sh`):** (1) preflight — `--target` is a git worktree, refuse dirty unless `--force`; (2) clean generated `plugins/prkit/`; (3) copy per `manifest.txt`; (4) rewrite + out-of-set neutralization; (5) scaffold templates (interpolate version/date); (6) verify — fail run on any violation; (7) summary + "commit in target repo" hint.

Idempotent: same UberDev SSOT + version ⇒ byte-identical generated output.

---

## 7. Data flow

```
UberDev SSOT (plugins/uberdev/**)
      │  tools/prkit/generate.sh --target ../prkit
      ▼
copy → rewrite (namespace/env/config/path/label/meta) → scaffold → verify
      │
      ▼
prkit repo working tree (plugins/prkit/** + repo files)
      │  (human) git add/commit/tag/push in prkit repo
      ▼
prkit marketplace → user `/plugin` install → `/prkit:review-pr` runs,
resolving ${CLAUDE_PLUGIN_ROOT} to prkit's own root (fully self-contained)
```

---

## 8. Coexistence & namespace correctness (core invariant)

With both plugins installed, there must be **zero** shared mutable surface:
- **Commands:** `/uberdev:review-pr` vs `/prkit:review-pr` — distinct.
- **Agents/skills:** dispatched/invoked only by fully-qualified `prkit:` names inside prkit; UberDev only ever names `uberdev:`.
- **Env vars:** `PRKIT_*` vs `UBERDEV_*` — no overlap, so concurrent runs don't clobber state.
- **Config file:** `.claude/prkit.local.md` vs `.claude/uberdev.local.md`.
- **GitHub labels / trust trailers:** `prkit-approved` vs `uberdev-approved`; distinct finding markers — so a prkit review never satisfies an UberDev merge's trust check, and vice versa.

The verify gate's token guard + referential-integrity checks mechanically enforce this on every build.

---

## 9. Edge cases & risks

1. **Env-var self-initialization without a hook.** Some `UBERDEV_*` vars (e.g. `UBERDEV_TMPDIR`) may be set by UberDev's SessionStart hook and merely *read* by lib. prkit ships no hook. **Plan-time task:** for every `PRKIT_*` var read by copied lib, confirm the lib self-initializes it with a default; add defaults where a var was hook-only. Correctness gate.
2. **Out-of-set references** — enumerated and neutralized (§5.4 rule 2); verify gate forbids residuals.
3. **Policy data file** — `policy/model-routing-v1.json` must ship; `config-read.sh` resolves it via `${CLAUDE_PLUGIN_ROOT}/policy/…`, correctly pointing at prkit's root after the path-fragment rewrite.
4. **Hardcoded fallback paths** in `config-read.sh` (`plugins/uberdev/…`, `uberdev-codex/…`) — rewritten (rule 5) or codex fallback dropped; verify no `uberdev` survives.
5. **Label trust-domain leakage** — mitigated by rule 6; its own verify check.
6. **`merge` ↔ `review-pr` coupling** — both in set; `merge`'s optional `auto_review_on_merge` chain to `Skill(prkit:review-pr)` stays intra-plugin. The `/goal` carve-out prose is neutralized.
7. **Rewrite over/under-reach** — guarded both sides: token guard catches *under*-rewrite (surviving `uberdev`); referential-integrity catches *over*-rewrite (dangling `prkit:` ref).

---

## 10. Testing strategy

- **Generator unit checks** (UberDev repo `tests/`): manifest completeness (every listed file exists in SSOT); rewrite applier maps each ruleset case on fixtures; neutralization removes the enumerated out-of-set sites.
- **Verify-gate self-test:** deliberately-broken tree (surviving token / dangling ref / missing lib) must fail; clean tree must pass.
- **prkit CI (`.github/workflows/ci.yml`):** `bash -n`, `ast.parse` (artifact-free python syntax), `jq empty`, `tomllib`, and an inline `grep -rilE 'uberdev'` namespace guard on the committed tree — a subset of `verify.sh` (which runs only at generation time in UberDev, not in the prkit repo). Each `find` gate uses `|| exit 1` because `find -exec … \;` does not propagate failure.
- **Smoke test (manual, documented):** install prkit locally, run `/prkit:review-pr` on a throwaway PR, confirm fanout dispatches `prkit:*` agents with no `uberdev:*` resolution; run `/prkit:merge` dry path.
- **Determinism check:** generate twice into clean targets; `diff -r` empty.

---

## 11. Versioning & release (prkit)

- Independent SemVer, starting **`0.1.0`**.
- prkit's version locations (analogue of UberDev's rule): `plugins/prkit/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md` badge, `CHANGELOG.md`, git tag, GitHub Release.
- Version is a generator input (`--version`), interpolated into scaffold templates: release = bump `--version` → regenerate → commit/tag/release in the prkit repo.

---

## 12. Open items to verify at plan/impl time

- [ ] Enumerate exact out-of-set reference sites (`/uberdev:goal`, `/uberdev:solve`) across the copy set for the neutralization pass.
- [ ] Confirm every `PRKIT_*` var read by copied lib has a non-hook default (risk #1).
- [ ] Finalize the label/trailer value mapping (rule 6) — pick concrete prkit label names.
- [ ] Decide codex-fallback handling in `config-read.sh` (rewrite vs. drop).
- [ ] Confirm `merge-pipeline/SKILL.md` has no lib deps beyond `lib/discover.sh`.
- [ ] Confirm no copied `.py` reads a static data file other than `model-routing-v1.json`.
- [ ] Decide prkit repo name / URL for metadata scaffolding.

---

## 13. Handoff

Terminal step of brainstorm: invoke `uberdev:write-plan` to produce the wave-decomposed implementation plan for the generator + templates + verify gate + first prkit generation.

---

## 14. Codex port addendum (SHIPPED)

UberDev supports **two runtimes**: Claude Code (`plugins/uberdev/`) and the OpenAI Codex CLI (`codex/uberdev-codex/` native plugin + `codex/install-codex.sh` one-liner). The Claude-only extraction above left prkit unusable on Codex, so the generator was extended to also emit a Codex port — same SSOT extract+rewrite model.

### 14.1 Approach
UberDev's Codex tree is already Codex-adapted (commands→`uberdev-cmd-*` command-skills, agents→TOML via `codex/tools/convert-agents.py`, paths fixed to `~/.codex`/`CODEX_HOME`/`.codex-plugin`). So prkit's Codex port is extracted **from `codex/uberdev-codex/`** (not re-transformed from scratch): a second manifest (`tools/prkit/manifest-codex.txt`, count-locked at **51**) drives a copy stage that rewrites both the **destination path** and the **content** with `uberdev`→`prkit`. The existing blanket rewrite already handles every Codex-specific literal — `uberdev-codex`→`prkit-codex`, `uberdev-cmd-`→`prkit-cmd-`, the TOML agent names, the `uberdev-codex-primer` sentinel.

### 14.2 New rewrite rule (fixes both trees)
Repo-slug rule, ordered before the CamelCase pass: `TheFJK/UberDev`→`TheFJK/prkit` (lowercase), so clone/marketplace URLs in `install-codex.sh` resolve. Without it the CamelCase rule would mangle the slug to `TheFJK/Prkit` (a nonexistent repo).

### 14.3 Codex copy set (51) + scaffold
`codex/prkit-codex/`: 3 `prkit-cmd-*` command-skills, 3 support-skill files (`post-impl-review`, `merge-pipeline` + `lib/discover.sh`), 14 agent `.md`, 11 lib, 1 policy, `.codex-plugin` manifest (templated), `hooks/` (2), `shared/` (1); `codex/agents/prkit-*.toml` (14, reference); `codex/install-codex.sh` + `codex/tools/convert-agents.py` (the installer path that carries the agents — required because the Codex plugin manifest has no `agents` field). Three scaffold docs are **authored templates** (`codex-plugin.json.tmpl`, `codex-README.md.tmpl`, `codex-AGENTS.md.tmpl`) with prkit-correct counts (3 commands, 14 agents, 5 skills) rather than extract+rewrite, so they don't inherit UberDev's stale "44 subagents".

### 14.4 Verify + tests
`verify.sh` now scans both trees (space-safe arrays), adds TOML validation (`tomllib`, skipped gracefully if absent) and a Codex shape check. Tests: `tests/prkit-codex-manifest.test.sh` (completeness + count-lock 51) + `prkit-generate.test.sh` G6–G8 (codex tree presence, uberdev-free, determinism). The verify gate caught 3 real gaps during bring-up (template `UberDev` mentions leaking into scanned `codex/`).

### 14.5 Resolves open item §12
The `config-read.sh` codex-fallback path (`uberdev-codex`→`prkit-codex`) is handled by the blanket rewrite (not dropped) — the composite `${CODEX_HOME}/plugins/prkit-codex/...` correctly points at prkit's Codex runtime dir.

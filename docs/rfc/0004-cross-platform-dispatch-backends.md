# RFC 0004 — Cross-Platform Dispatch Backends for `/solve` and `/turbo`

| Field          | Value |
| -------------- | ----- |
| **Status**     | Implemented — v0.30.0 (2026-05-19) |
| **Author**     | TheFJK |
| **Created**    | 2026-05-19 |
| **Targets**    | NEW: `docs/rfc/0004-cross-platform-dispatch-backends.md`, `plugins/uberdev/lib/dispatch.sh`, `tests/dispatch-wezterm.test.sh`, `tests/dispatch-background.test.sh`, `tests/dispatch-fallback.test.sh`. MODIFIED: `plugins/uberdev/skills/solve-pipeline/SKILL.md`, `plugins/uberdev/commands/solve.md`, `plugins/uberdev/commands/turbo.md`, `plugins/uberdev/skills/using-uberdev/SKILL.md`, `tests/dispatch-claude-bg.test.sh`, `.github/workflows/test.yml`, `README.md`, `CHANGELOG.md`, `.claude-plugin/marketplace.json`, `plugins/uberdev/.claude-plugin/plugin.json` |
| **Supersedes** | — |
| **Builds on**  | v0.22.0 `claude --bg` dispatch (`#85`) · `lib/config-read.sh` (`uberdev_read_enum`) · the retired `--terminal=` deprecation shim (the opt-in surface this RFC parallels) |
| **Tracking**   | none — ad-hoc design (cross-platform support + new feature, not an issue resolution) |
| **Tier**       | Large (new `lib/` module, three dispatch backends, Windows CI matrix, pipeline portability rework, multiple new test files) |

---

## 1. Summary

`/solve` and `/turbo` dispatch one autonomous agent per GitHub issue. Today that dispatch is hardcoded to `claude --bg`, and the pipeline wrapping it (`solve-pipeline/SKILL.md`) is bash that assumes a Unix environment — so the commands **do not run on native Windows**.

This RFC introduces a **`dispatch_backend` abstraction** with three tested backends:

- **`claude-bg`** — today's `claude --bg` supervised background sessions (unchanged behaviour).
- **`wezterm`** — each agent in a visible WezTerm pane; opt-in; the one terminal whose control CLI is identical on macOS and Windows.
- **`background`** — a dependency-free `git worktree add` + detached headless `claude -p`; the Windows-robust fallback.

A **platform-aware fallback chain** selects a backend once per invocation, and the dispatch pipeline is **hardened to run under Git Bash on native Windows**. Net effect: `/solve` and `/turbo` work on macOS *and* Windows, and gain an opt-in "watch the agents work live" mode.

## 2. Motivation

### 2.1 `/solve` and `/turbo` do not run on native Windows

The dispatch logic in `solve-pipeline/SKILL.md` is bash-in-Markdown: heredocs, `[[ ]]`, bash arrays, a hard `timeout`/`gtimeout` probe that `exit 1`s if neither binary is found (the Phase A `TIMEOUT_BIN` block), hardcoded `/tmp/` paths, and `jq`/`awk`/`sed -E`. `.github/workflows/test.yml` runs `ubuntu-latest` only — **zero Windows coverage** — while the `README.md` FAQ calls `/solve` "platform-agnostic", which is only half-true.

### 2.2 The real blocker is the bash pipeline — not `claude --bg`, not terminals

Verified across four research rounds (May 2026):

- **`claude --bg` works on native Windows** as of Claude Code **v2.1.144**. The early gate (issue **#58204**, v2.1.139, `'--bg' is not enabled`) is **closed**; v2.1.120 shipped the Windows background-sessions update; v2.1.141–144 ship a stream of Windows-specific `claude agents` fixes. The dispatch *engine* is not the blocker.
- **The pipeline is the blocker.** On native Windows, Claude Code's Bash tool runs in **Git Bash** when present — the script then runs but hits MSYS path-mangling, a `timeout.exe`↔coreutils-`timeout` name collision, and a missing `jq` — and falls back to the **PowerShell tool** when Git Bash is absent, where the bash script does not parse at all.
- **Terminals were never the blocker.** The v0.22.0 design is already terminal-agnostic — `claude --bg` needs no terminal. "Windows lacks terminals" is a non-problem; a Windows terminal backend is not what unblocks Windows.

### 2.3 The visibility gap — no way to watch agents work live

`claude --bg` is monitored out-of-band via `claude agents` (Agent View). There is no way to watch an agent's work scroll live in a pane — useful for interactive `/solve` use and for debugging a misbehaving agent. **WezTerm** is the only terminal whose control CLI (`wezterm cli spawn|list|get-text`) is **identical on macOS and Windows**, making it the one backend that delivers visible panes without per-OS code.

### 2.4 The v0.22.0 constraint — backends must be tested

v0.22.0 retired a five-branch dispatcher (`cmux|ghostty|iterm|terminal|nohup`, issue **#85**) because three branches had **zero test coverage** and terminal-emulator init raced. `dispatch-claude-bg.test.sh` (new surface present) and `ghostty-dispatch-no-instance-leak.test.sh` (retired surface absent) lock that decision in. **Any new backend MUST ship with shape-check coverage** or it repeats the exact mistake v0.22.0 corrected. This RFC treats per-backend tests as part of the definition of done, not as optional follow-up.

## 3. Design

### 3.1 The `dispatch_backend` abstraction

One new config key, read with the **existing** `uberdev_read_enum` from `lib/config-read.sh` — no new config machinery:

```bash
DISPATCH_BACKEND="$(uberdev_read_enum dispatch_backend UBERDEV_DISPATCH_BACKEND \
  'auto|claude-bg|wezterm|background' 'auto')"
```

Precedence (the established `config-read.sh` order): `--backend=` CLI flag > `UBERDEV_DISPATCH_BACKEND` env > `dispatch_backend:` in `.claude/uberdev.local.md` > default **`auto`**. `auto` defers to the platform-aware fallback chain (§3.3).

### 3.2 The three backends

| Backend | Mechanism | Agent process | Monitored via | Platforms |
| --- | --- | --- | --- | --- |
| `claude-bg` | `claude --bg --worktree …` (today's dispatch) | detached supervised bg session | `claude agents` | macOS; Windows on v2.1.144+ |
| `wezterm` | `wezterm cli spawn -- claude -p …` | foreground, in a visible pane | the pane + `wezterm cli get-text`/`list` | macOS; native-Windows + Git Bash |
| `background` | `git worktree add` + detached `claude -p` | detached OS process | log + status files | all (universal fallback) |

The `MODEL`, `PERM_FLAG`, `EFFORT_FLAG` arrays and the `UBERDEV_TURBO` env passthrough — all resolved once in Phase A — thread into every backend's `claude` invocation unchanged.

### 3.3 The platform-aware fallback chain

A **preflight capability check** runs once per invocation (Phase A): detect OS class (`macos` | `windows-native` | `wsl2`) and probe WezTerm availability — *available* means the `wezterm` binary is on PATH **and** preflight can bring its mux up (start `wezterm-mux-server`, poll `wezterm cli list-clients` until it answers). It resolves `auto` to a concrete backend and **commits for the whole batch** — it never half-switches mid-fanout (a batch split across backends is forbidden, the same principle as the existing "no partial dispatch" rule).

Resolution preference order:

- **`auto` + macOS** → `wezterm` if available, else `claude-bg`.
- **`auto` + native Windows** → `wezterm` if available, else `background`.
- **`auto` + WSL2** → `claude-bg` (it is Linux; `claude --bg` is native and reliable there).
- **Explicit `--backend=X`** → use `X`; preflight still validates `X` is usable on this host and **hard-errors** if not (the user asked for `X` specifically — no silent downgrade).

`claude-bg` is deliberately **absent from the Windows `auto` chain** (D8): `claude agents` was deadlocking on Windows as recently as v2.1.142 (five days before this RFC). It remains forceable via `--backend=claude-bg` for users on v2.1.144+ who want Agent View.

### 3.4 `lib/dispatch.sh` — code structure

A new sourced library, mirroring `lib/config-read.sh` (sourced never executed; idempotent load guard; all expansions double-quoted). Public surface:

- `uberdev_dispatch_preflight` — detects OS class + capabilities, resolves `auto` → a concrete backend, exports `UBERDEV_RESOLVED_BACKEND`, emits the `dispatch_backend_resolved` audit event.
- `uberdev_dispatch_one ISSUE_NUM TIER PROMPT_FILE` — dispatches one issue via the resolved backend; sets per-issue result vars (`DISPATCH_RC`, a backend-specific id).
- internal `_uberdev_dispatch_claude_bg`, `_uberdev_dispatch_wezterm`, `_uberdev_dispatch_background` — one function per backend.

`solve-pipeline/SKILL.md` Step 5b' sources `lib/dispatch.sh` and calls `uberdev_dispatch_one` inside the existing wave-batching loop, replacing the inline `case "$BG_PROMPT_MODE"`. The `argv`/`file`/`stdin` prompt sub-modes move *inside* `_uberdev_dispatch_claude_bg`, preserved verbatim. This keeps the 66 KB SKILL.md from growing and makes each backend independently shape-checkable — exactly as `config-read.sh` is tested by `config-override.test.sh`.

### 3.5 The `claude-bg` backend (current behaviour, formalised)

Today's dispatch lifted verbatim into `_uberdev_dispatch_claude_bg`: the `case "$BG_PROMPT_MODE" in file|stdin|argv` switch, `--worktree solve-issue-N`, the `env "${BG_TURBO_ENV[@]}"` prefix, `"${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"`, the `timeout`/`gtimeout` wrap, the `backgrounded · <id>` session-id extraction, and the `agent_dispatched` audit event. **No behaviour change** — a pure extract-to-function refactor. macOS default; Windows-capable on v2.1.144+ but kept out of the Windows `auto` chain (§3.3, D8).

### 3.6 The `wezterm` backend

`_uberdev_dispatch_wezterm` spawns each agent as a **foreground** `claude` in a visible WezTerm pane:

```bash
wezterm cli spawn --domain-name uberdev --cwd "<worktree-abs-path>" -- \
  claude -p "<prompt>" --model "$MODEL" "${PERM_FLAG[@]}" "${EFFORT_FLAG[@]}"
```

`spawn` prints the new pane-id → captured as the dispatch handle (`agent_dispatched` payload `{"backend":"wezterm","pane_id":N}`). Hard constraints from the WezTerm research round:

- **Mux up before the first spawn.** `wezterm cli` does not auto-start a GUI. Preflight starts `wezterm-mux-server` (or a GUI) and polls `wezterm cli list-clients` until it answers *before* the first `spawn` — the cold-start race otherwise returns `connection refused`.
- **The backend owns a `.wezterm.lua`.** It merges a fenced, clearly-marked managed block defining a named `unix_domains` entry (`uberdev`) and `exit_behavior = "Hold"` — so a finished or crashed agent pane (and its transcript) stays visible. The default `"Close"` makes the pane vanish on exit. The managed block is merged, never an overwrite of the user's config.
- **Pin the socket.** Every `wezterm cli` call runs with `$WEZTERM_UNIX_SOCKET` pinned to the `uberdev` domain, so fan-out does not scatter across stray WezTerm instances.
- **Foreground model.** A pane hosts a foreground process, so the agent runs as `claude -p` (headless print mode streaming into the pane). `claude --bg` cannot be hosted in a pane — it detaches, the pane empties and closes. The `wezterm` backend therefore does not use `claude agents`.
- **Same-OS only.** The dispatcher and the WezTerm it drives must be on the same OS side — the WSL2↔native-Windows mux interop is permanently broken (WSL2 dropped AF_UNIX interop). Preflight enforces this; a cross-boundary selection is a hard error with an explanatory message.
- **Worktrees.** The backend runs `git worktree add` itself (a pane's `claude -p` does not get `claude --bg`'s native `--worktree`), then `--cwd`s the pane into the worktree. Paths are absolute and quoted — the repo path may contain spaces.

### 3.7 The `background` backend

`_uberdev_dispatch_background` — the dependency-free fallback. Per issue:

1. `git worktree add .claude/worktrees/solve-issue-N worktree-solve-issue-N` — explicit, dispatcher-controlled. This also **sidesteps the Windows worktree-isolation bug #40164**, which lives in `claude --bg --worktree`'s own POSIX-vs-Windows path handling.
2. Launch `claude -p "<prompt>" --model … "${EFFORT_FLAG[@]}" "${PERM_FLAG[@]}"` as a **detached** background process (`nohup … >"$LOG" 2>&1 &` then `disown`), cwd = the worktree. `claude -p` headless print mode is verified on native Windows and is non-interactive by design, so it **logs cleanly** — no garbled-TUI-in-a-logfile problem.
3. Record PID + log path + status into per-issue status files; emit `agent_dispatched` `{"backend":"background","pid":N,"log":"…"}`.

Monitoring: no `claude agents`, no pane — the dispatcher tracks PID liveness, exit code, and the log tail. Role: the **Windows `auto` default** (depends on nothing fragile — only `git`, `claude -p`, and shell backgrounding) and the universal last-resort fallback. Portable to macOS but not in the macOS `auto` chain (macOS has `claude-bg`'s Agent View).

### 3.8 Windows pipeline hardening

Backend-independent — the pipeline is bash and must run under Git Bash on native Windows for *any* backend to dispatch. Changes to `solve-pipeline/SKILL.md` and `lib/*.sh`:

- **`timeout` resolution.** The Phase A `TIMEOUT_BIN` probe must prefer Git Bash's coreutils `timeout` and must not resolve to `C:\Windows\System32\timeout.exe` (an incompatible command). Probe the explicit MSYS path (`/usr/bin/timeout`) before a bare `command -v`.
- **MSYS path-mangling.** Wrap path-bearing argv (`--worktree`, worktree absolute paths, `--cwd`) with `MSYS_NO_PATHCONV=1` / `MSYS2_ARG_CONV_EXCL` so Git Bash does not silently rewrite POSIX-looking arguments into Windows paths before they reach `claude`/`git`/`wezterm`.
- **Temp paths.** Replace hardcoded `/tmp/solve-prompt-N.txt`, `/tmp/solve-bg-stdout-N.log`, `/tmp/solve-claim-N.json` with a single `UBERDEV_TMPDIR` resolved once at Phase A entry (`${TMPDIR:-/tmp}`; Git Bash sets `TMPDIR`).
- **`jq`.** Not bundled with Git for Windows. The session-start hook already verifies `jq`; add a Windows install pointer (`winget install jqlang.jq`) to that check.
- **Git Bash requirement.** The pipeline is bash; under the PowerShell tool it cannot run. Phase A preflight detects "native Windows + no bash" and fails fast with an actionable pointer, instead of a parse error.
- **WSL2 is the blessed host.** Document WSL2 as the recommended Windows environment — the pipeline runs byte-identical to macOS, sandboxing works. Worktrees must live on the Linux ext4 filesystem (`~/…`), never `/mnt/c` (9P/DrvFs is 10–50× slower); a Phase A warning fires if the repo path is under `/mnt/`.

### 3.9 Opt-in surface — `--backend=` flag + `dispatch_backend:` config

- New `--backend=auto|claude-bg|wezterm|background` CLI flag (the same enum the `dispatch_backend:` key accepts), parsed in Phase A alongside the existing flags (anchored token regex).
- New `dispatch_backend:` key in `.claude/uberdev.local.md` (+ `UBERDEV_DISPATCH_BACKEND` env), read via `uberdev_read_enum`. `using-uberdev/SKILL.md`'s config documentation gains the key.
- The retired `--terminal=cmux|ghostty|iterm|terminal|nohup` flag **stays deprecated and inert** (removal target v1.0.0 unchanged). It named terminal *emulators* — a different concept from dispatch *backend* — and is **not** repurposed; `--backend=` is a clean, separately-named surface.

### 3.10 Post-dispatch summary + audit events

- `agent_dispatched` payload gains a `backend` field; the id field is backend-specific (`bg_session_id` | `pane_id` | `pid`) — an additive, backward-compatible payload extension.
- New `dispatch_backend_resolved` audit event: `{requested, resolved, os_class, reason}` from preflight — one new member added to `SOLVE_AUDIT_EVENT_ENUM` (the only enum-membership change in this RFC).
- Step 6's summary becomes backend-aware: `claude-bg` → "run `claude agents`"; `wezterm` → "agents are in the WezTerm window"; `background` → per-issue log paths + "tail these; exit code in `<status-file>`".

### 3.11 Error handling & edge cases

| Situation | Behaviour |
| --- | --- |
| `--backend=wezterm`, WezTerm not installed | Hard error (explicit request) + install pointer. |
| `auto`, WezTerm absent | Silent fall-through to the platform default. |
| `--backend=wezterm` from WSL2, WezTerm is native-Windows | Hard error: same-OS mux constraint, with the WSLg explanation. |
| `auto`-resolved `wezterm`, mux fails to come up | WezTerm counts as unavailable — fall through to the next backend in the chain. |
| `--backend=wezterm` (explicit), mux fails to come up | Hard error before any dispatch, with the cold-start pointer; no half-dispatch. |
| native Windows, no Git Bash | Phase A fails fast: "install Git for Windows, or use WSL2". |
| `background`: `git worktree add` fails for an issue | That dispatch fails (recorded in `DISPATCH_FAILED`); siblings proceed; claim rolled back — today's per-issue failure path. |
| repo under `/mnt/c` in WSL2 | Phase A warning (9P slowness); proceed. |
| `--backend=claude-bg` on native Windows < v2.1.144 | Phase A note: `claude --bg` may be gated; suggest `--backend=background` or an upgrade. |
| mixed backends mid-fanout | Forbidden — preflight resolves once and commits for the whole batch. |

## 4. File impact summary

| File | Change |
| --- | --- |
| `docs/rfc/0004-cross-platform-dispatch-backends.md` | NEW — this RFC. |
| `plugins/uberdev/lib/dispatch.sh` | NEW — preflight + fallback resolver + three backend functions. |
| `tests/dispatch-wezterm.test.sh` | NEW — `wezterm` backend shape-check. |
| `tests/dispatch-background.test.sh` | NEW — `background` backend shape-check. |
| `tests/dispatch-fallback.test.sh` | NEW — preflight resolver shape-check. |
| `plugins/uberdev/skills/solve-pipeline/SKILL.md` | MOD — Step 5b' sources `lib/dispatch.sh`, calls `uberdev_dispatch_one`; Phase A gains preflight + `--backend=` parse + Windows hardening. |
| `plugins/uberdev/commands/solve.md` / `commands/turbo.md` | MOD — document `--backend=`; `## Deprecated Flags` unchanged. |
| `plugins/uberdev/skills/using-uberdev/SKILL.md` | MOD — document the `dispatch_backend:` config key. |
| `tests/dispatch-claude-bg.test.sh` | MOD — re-anchor for the extract-to-`lib/dispatch.sh` move. |
| `.github/workflows/test.yml` | MOD — add a `windows-latest` job running the suite under Git Bash. |
| `README.md` / `CHANGELOG.md` / `.claude-plugin/marketplace.json` / `plugins/uberdev/.claude-plugin/plugin.json` | MOD — version bump `0.28.0 → 0.29.0`. |

**Testing strategy.** Shape-check bash tests mirroring `dispatch-claude-bg.test.sh`'s `assert_grep`/`assert_grep_not` style. `dispatch-wezterm.test.sh`: `wezterm cli spawn` + `--domain-name` present, the mux-preflight `list-clients` poll present, `.wezterm.lua` managed-block + `exit_behavior` Hold present, `claude --bg` **absent** from the wezterm arm. `dispatch-background.test.sh`: `git worktree add` + detached `claude -p` + `nohup`/`disown` + status-file writes present, `claude --bg` **absent**. `dispatch-fallback.test.sh`: the per-OS preference order, the WSL2 same-OS guard, and single-resolution (no mid-fanout switch). `.github/workflows/test.yml` gains a `windows-latest` job (`shell: bash`) — proving the shape-check harness is Git-Bash-portable; runtime dispatch validation stays out of scope (the suite is grep-and-assert throughout).

## 5. Migration / rollout

Per the project `CLAUDE.md` "bump version EVERYWHERE" mandate, this is a user-facing feature → a **minor** bump `0.28.0 → 0.29.0` across all six locations: `plugin.json`, `marketplace.json`, the `README.md` badge, a `CHANGELOG.md` `## [0.29.0]` section, the git tag `v0.29.0`, and the GitHub Release.

**Additive and backward-compatible.** `auto` resolves to `claude-bg` on macOS, so existing macOS users see **no behaviour change**. Windows users gain working `/solve` and `/turbo`. Implementation may split into two PRs — PR1: pipeline hardening + `lib/dispatch.sh` scaffold + `claude-bg` extract + `background` backend + Windows CI; PR2: the `wezterm` backend — `write-plan` will wave-decompose.

## 6. Alternatives considered

### 6.1 Keep dispatch inline in SKILL.md (a `case "$DISPATCH_BACKEND"` block)
**Rejected.** Grows the already-66 KB SKILL.md and repeats the untested-multi-arm shape v0.22.0 retired. A sourced `lib/` module is independently testable.

### 6.2 One `lib/dispatch-<backend>.sh` file per backend
**Rejected.** Over-split for ~3 functions; `config-read.sh` sets the precedent of one cohesive sourced lib.

### 6.3 A `wezterm` backend that wraps `claude --bg`
**Rejected.** A WezTerm pane hosts a foreground process; `claude --bg` detaches and the pane empties. They are structurally different dispatch models — `wezterm` must run `claude -p`.

### 6.4 Make WSL2 mandatory on Windows; no native-Windows support
**Rejected.** Native Windows + Git Bash is a small, well-understood hardening delta (§3.8). Forcing WSL2 turns users away for no real engineering saving. WSL2 is **recommended**, not **required**.

### 6.5 Full PowerShell / Node rewrite of the pipeline (no Git Bash dependency)
**Rejected.** A large rewrite of a working bash pipeline for the marginal gain of dropping a trivial Git-for-Windows install — fails "match rigor to blast radius".

### 6.6 Reuse the deprecated `--terminal=` flag for backend selection
**Rejected.** `--terminal=` names terminal *emulators*; `--backend=` names dispatch *mechanisms*. Overloading the deprecated flag muddies the v1.0.0 removal story.

## 7. Open questions

None. The Windows-support strategy, the three-backend set, the fallback chain, and the WezTerm focus were resolved with the user across four research rounds (May 2026) and the decisions in §9. The `lib/dispatch.sh` structure is an author decision grounded in the codebase audit. Scope is one RFC; implementation may wave-split into two PRs (§5).

## 8. Risk / rollout

- **Risk: a new backend ships untested → repeats #85.** *Mitigation:* §4 makes per-backend shape-checks part of the definition of done; CI gates them on both `ubuntu-latest` and `windows-latest`.
- **Risk: the `wezterm` backend clobbers a user's `.wezterm.lua`.** *Mitigation:* §3.6 — merge a fenced, clearly-marked managed block; never overwrite.
- **Risk: WezTerm cold-start race.** *Mitigation:* §3.6 mandates the `list-clients` poll before the first spawn.
- **Risk: `background` agents are unmonitorable if PID/log files are lost.** *Mitigation:* per-issue namespaced status files; the Step 6 summary prints their paths; the worktree + branch persist regardless.
- **Risk: Windows `claude --bg` regresses again.** *Mitigation:* it is not in the Windows `auto` chain — `background` is; `claude-bg` on Windows is opt-in only (D8).
- **Rollback:** additive. Reverting `lib/dispatch.sh` + the SKILL.md Step 5b' hunk + the new flag restores the v0.28.0 inline `claude --bg` dispatch with zero data migration.

## 9. Decision log

| # | Decision | Choice | Source |
| --- | --- | --- | --- |
| Q1 | Windows-support strategy | **WSL2 as the blessed host + harden the bash pipeline for Git Bash on native Windows.** | User. |
| Q2 | WezTerm as a backend | **Yes** — the one cross-platform visible-pane option (`wezterm cli` identical macOS/Windows). | User. |
| Q3 | Fallback when WezTerm is unavailable on Windows | **`background`** — explicit `git worktree add` + headless `claude -p`; chosen because `claude --bg` is not trusted as the Windows default. | User. |
| Q4 | RFC scope | **One RFC** covering pipeline hardening + all three backends. | User. |
| D5 | Code structure | **`lib/dispatch.sh`** — one sourced module: preflight + fallback resolver + three backend functions. | Author — v0.22.0 untested-code lesson + the `config-read.sh` precedent. |
| D6 | Opt-in surface | New `--backend=` flag + `dispatch_backend:` config key; the deprecated `--terminal=` is **not** repurposed. | Author. |
| D7 | `auto` resolution order | macOS `[wezterm, claude-bg]`; native Windows `[wezterm, background]`; WSL2 `[claude-bg]`. | Author — from the WezTerm same-OS-mux constraint. |
| D8 | `claude-bg` on Windows | **Out of the Windows `auto` chain**; forceable via `--backend=claude-bg`. | Author — `claude agents` was deadlocking on Windows as recently as v2.1.142. |
| D9 | Published design artifact | This RFC (`docs/rfc/0004-…`). The brainstorm default `docs/uberdev/specs/` is gitignored — mirrors RFC 0003 D9. | Author. |
| D10 | Windows CI | Run the shape-check suite on `windows-latest` under Git Bash (`shell: bash`). | Author. |

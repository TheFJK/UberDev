# Per-project configuration — `.claude/uberdev.local.md` / `.codex/uberdev.local.md`

> Moved out of `using-uberdev/SKILL.md` (the SessionStart injection) by the RFC 0012 §7.7 hook diet.
> The primer carries only a pointer here. Read this file when you need a key's type, range,
> default, env override, or precedence rule — do not answer config questions from memory.

UberDev reads optional project config from `.codex/uberdev.local.md` when present and falls back to `.claude/uberdev.local.md` for shared and legacy repos. The file uses YAML frontmatter for typed settings:

```yaml
---
solve_tier_default: small        # one of: small, medium, large
review_depth: full               # one of: quick, full
parallel_solve: true
auto_install_aliases: true       # Claude Code only: auto-install the short-form aliases (see aliases-sync.sh for the canonical set) at SessionStart (default: true; env override: UBERDEV_NO_AUTO_ALIAS=1). Codex uses $uberdev-cmd-* skills instead.
integration_branch: main         # branch /merge lands PRs into; default = repo default branch
dispatch_backend: auto           # one of: auto, workflow, wezterm, background — how /solve & /turbo run per-issue solvers (RFC 0004/0012/0015); default auto (-> workflow everywhere); env override: UBERDEV_DISPATCH_BACKEND
auto_review_on_merge: false      # boolean — when true, /merge Phase 1.4 auto-dispatches /review-pr <N> --turbo once per PR with missing trust trail (whitelisted reasons only); default false; env override: UBERDEV_AUTO_REVIEW_ON_MERGE (#89)
auto_confirm: false              # DEPRECATED — no behavioural effect. /merge is fully unattended (autopilot). Key parses for backward compat; first encounter emits a stderr deprecation notice.
bot_authors_allow_list:          # DEPRECATED — no behavioural effect. /merge no longer gates on PR-author identity (any APPROVED + CI-green PR is eligible). Key parses for backward compat.
  - dependabot[bot]
  - renovate[bot]

# --- GPT-5.6 routing (RFC 0013; opt-in in v0.40) ---
model_routing:
  mode: inherit                  # adaptive | inherit; v0.40 default: inherit
  service_tier: default          # default | fast | flex; independent of model/effort
  risk_escalation: true          # true | false; automatic risk upshift policy (hard floors remain enforced)
  adaptive_fallback: true        # true | false; provider-compatible fallback after resolution
  shadow: false                  # true computes an adaptive proposal but executes inherit
  workflows: {}                  # solve/turbo only; bounded route/effort/sandbox overrides
  roles: {}                      # canonical policy roles; bounded route/effort/sandbox overrides

# --- /solve tier clamp ---
solve_tier_floor: small          # one of: trivial, small, medium, large; clamps auto-triage UP to floor; default unset (no lower clamp); env: SOLVE_TIER_FLOOR
solve_tier_ceiling: medium       # one of: trivial, small, medium, large; clamps auto-triage DOWN to ceiling; default unset (no upper clamp); env: SOLVE_TIER_CEILING

# --- per-phase parallel fanout caps ---
# dot-path refs: fanout_concurrency.research, fanout_concurrency.post_impl_review, fanout_concurrency.merge_strategy, fanout_concurrency.conflict_resolver
fanout_concurrency:
  research: 6                    # int [1, 50]; orchestrator Phase 1 research-fanout cap; default 6; env: UBERDEV_FANOUT_RESEARCH
  solve_bg: 6                    # int [1, 50]; /turbo parallel claude --bg fanout cap; default 6; env: UBERDEV_FANOUT_SOLVE_BG
  post_impl_review: 6            # int [1, 50]; post-impl-review reviewer fanout cap; default 6; env: UBERDEV_FANOUT_POST_IMPL_REVIEW
  merge_strategy: 10             # int [1, 50]; /merge Phase 2.2 strategy-decider fanout cap; default 10; env: UBERDEV_FANOUT_MERGE_STRATEGY (alias for MAX_PARALLEL_AGENTS in merge-pipeline/SKILL.md Constants)
  conflict_resolver: 10          # int [1, 50]; /merge Phase 3.3 conflict-resolver fanout cap; default 10; env: UBERDEV_FANOUT_CONFLICT_RESOLVER (NEW — Phase 3.3 was uncapped previously)

# --- per-command wall-clock timeouts ---
# dot-path refs: command_timeouts.solve, command_timeouts.review_pr, command_timeouts.merge
command_timeouts:
  solve: 3600                    # int seconds [60, 86400]; ENFORCED via /solve launcher timeout(1)/gtimeout wrap; default 3600 (1h); env: UBERDEV_SOLVE_TIMEOUT
  review_pr: 900                 # int seconds [60, 86400]; ADVISORY-ONLY in v1 (parsed + audit-logged; no kill); default 900 (15m); env: UBERDEV_REVIEW_PR_TIMEOUT
  merge: 600                     # int seconds [60, 86400]; ADVISORY-ONLY in v1 (parsed + audit-logged; no kill); default 600 (10m); env: UBERDEV_MERGE_TIMEOUT
---

# Notes (optional, free-form markdown for human reference)
```

Settings take effect on next SessionStart. Environment variables (`UBERDEV_FANOUT_SOLVE_BG`, `SOLVE_AUTO`, etc.) override file settings — use whichever is more convenient for your workflow.

## GPT-5.6 model routing (RFC 0013, v0.40)

> **NOT ENFORCEABLE since #381 — read this first.**
> Every setting in this section is still parsed and still validated exactly as
> described below, but **no shipped dispatch backend can act on it.** UberDev no
> longer owns the provider invocation: `workflow`, `wezterm` and `background`
> children all inherit the ambient model and reasoning effort of the session
> that launched them, and the `codex` backend that could pass `-m` and
> `model_reasoning_effort` per child was retired.
>
> Consequently a `model_routing:` block that names anything **concrete** — a
> `route`, a `reasoning_effort`, a non-`default` `service_tier`, `mode:
> adaptive`, or any `roles:` / `workflows:` override entry — makes the dispatch
> fail with the typed error **`route_unenforceable`** rather than silently
> ignoring it. This is deliberate: asking for Sol-Ultra and being told it cannot
> be honoured is safer than believing it was applied. Validation is kept so that
> a typo'd effort or an unknown role is still caught at config-read time with a
> precise message.
>
> What still works end to end is the **logical** half: `classify_minimum_route`
> in `lib/model_routing.py` answers what capability rank a tier/role/risk
> combination is entitled to, and `policy/model-routing-v1.json` still declares
> route ranks, aliases, the lead-route matrix, the role inventory and the
> `reasoning_efforts` vocabulary this file validates against. The concrete
> resolver (`resolve_route`, `fallback_route`, `validate_catalog`, the per-route
> provider catalog and the JSON CLI) was deleted rather than shipped as an
> engine nothing can enter. See RFC 0013 §0 (2026-08-05 amendment).

`model_routing.mode` accepts `inherit | adaptive`. Version 0.40 defaults to
`inherit`, which is the safe rollback path: bundled workflows use an unpinned
provider carrier and keep the ambient model/reasoning selection. `adaptive` is
an explicit opt-in that lets the deterministic policy choose a route for each
lead and role. Version 0.42 plans to make `adaptive` the default only after its
quality gates pass; that transition is planned, not current behavior.

`model_routing.service_tier` accepts `default | fast | flex` and defaults to
`default`. It is independent from model and reasoning effort. The `--fast`
CLI alias is wired by the solve launcher in T40-6 and maps only to explicit
`--service-tier=fast`; setting this config key does not silently alter a route.

`model_routing.risk_escalation` and `model_routing.adaptive_fallback` are
strict booleans and both default to `true`. The former controls optional
automatic risk upshifts; setting it false never bypasses mandatory role/run
risk floors. The latter permits only the resolver's provider-compatible
post-resolution fallback chain. `model_routing.shadow` is
a strict boolean defaulting to `false`; when true, UberDev records the adaptive
proposal while effective execution remains `inherit` (unknown effective model
and effort stay null unless the provider reports them).

`model_routing.workflows` and `model_routing.roles` are data-only override
maps. Each accepts at most 64 entries and 16 KiB of normalized JSON. Keys use
`A-Za-z0-9._-` (no traversal-shaped `..` or slash). A value is either a route
name/alias or an object containing only `route`, `reasoning_effort` (the input
alias `effort` normalizes to this exact field), and/or `sandbox`. Reasoning
effort must appear in the policy's declared `reasoning_efforts` vocabulary
(`low | medium | high | max | ultra`); sandbox is `read-only |
workspace-write`. `route` and `reasoning_effort` are mutually exclusive in one
override entry. Role names are loaded from the canonical
`model-routing-v1.json`; the v0.40 public workflow scope is exactly `solve` and
`turbo`. Duplicate or unknown keys, duplicate effort aliases, unknown fields,
routes or efforts, malformed JSON/YAML, excessive input, and
`danger-full-access` reject the whole map to the safe `{}` default. Contents
are never evaluated as shell or Python code. YAML examples:

```yaml
model_routing:
  workflows:
    solve: quality
    turbo:
      effort: high               # normalized to reasoning_effort
      sandbox: read-only
  roles:
    triage-scout: economy
    code-reviewer:
      route: sol-high
      sandbox: read-only
```

Routing config precedence is environment > project files per key > release
default. For each omitted key, UberDev checks readable
`.codex/uberdev.local.md` first and then `.claude/uberdev.local.md`; a Codex
file can therefore define one key while a complementary Claude file supplies
another. An invalid higher-precedence value safely defaults and is not replaced
by a lower-precedence value. Explicit `UBERDEV_CONFIG_FILE` remains a sole-file
override: missing keys in it do not fall through to either project file.
Environment
names are `UBERDEV_MODEL_ROUTING_MODE`, `UBERDEV_SERVICE_TIER`,
`UBERDEV_MODEL_ROUTING_RISK_ESCALATION`,
`UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK`,
`UBERDEV_MODEL_ROUTING_SHADOW`, `UBERDEV_MODEL_ROUTING_WORKFLOWS`, and
`UBERDEV_MODEL_ROUTING_ROLES`. Map environment values are strict JSON. The
resolved exports use the separate `UBERDEV_ROUTING_*` namespace so input
overrides cannot self-shadow. Invalid values use the standard one-warning-per-
key fallback format. Existing files containing no `model_routing` block remain
warning-silent and behavior-compatible.

Map validation resolves its canonical policy from an explicit
`UBERDEV_ROUTING_POLICY_FILE`, then packaged/source/install-safe locations.
The explicit variable is also the test/embedding hook. If it is unreadable,
malformed, duplicate-keyed, or lacks canonical routes/roles/efforts, a present
map fails closed to `{}` with the standard single redacted warning; UberDev
never accepts unvalidated role typos merely because the JSON/YAML is valid.
Before extracting those bounded sets, the reader loads T40-1's trusted
`model_routing.py` and invokes its public complete validator. The optional
`UBERDEV_MODEL_ROUTING_LIB` selector is accepted only when its canonical,
absolute, regular, non-symlink path exactly matches the
`model_routing.py` sibling of the actual sourced `config-read.sh`. The helper
captures its own source identity at source time under Bash 3.2 or zsh; current
working directory, `CLAUDE_PLUGIN_ROOT`, and `CODEX_HOME` are not validator
trust roots. A copied helper without its own sibling therefore fails closed,
and the selector is not an arbitrary Python import path. Missing or unloadable
validators and semantically invalid policies (including incomplete route
mappings, duplicate capability ranks/provider pairs, malformed role rows, and
unsupported reasoning efforts) fail the map closed with the same single
redacted warning. Scalar/legacy readers do not require the validator.

All routing-map parsing and validator imports run with isolated Python mode
(`python3 -I`), so project-local modules such as `json.py` or `importlib.py`
cannot shadow the standard library or execute before trust checks.

When a config contains YAML delimiters, only the first YAML frontmatter body
is configuration; tabs, headings, examples, and hostile-looking text in the
Markdown notes after its closing `---` are ignored. The opening delimiter must
be the first non-empty line and the file must contain exactly one opening and
one closing delimiter. Unterminated or multiple delimiter structures fail a
present routing map closed with one redacted warning. Delimiter-free legacy
config remains supported and is parsed as the complete document. Per-key
Codex-to-Claude fallback examines the same frontmatter slice, so a key written
only in Codex notes cannot shadow a real Claude frontmatter value.

Concrete run-level environment controls are `UBERDEV_ROUTE`, `UBERDEV_MODEL`,
and `UBERDEV_REASONING_EFFORT`. The config reader leaves these inputs intact;
T40-6 passes them to the policy resolver, which validates catalog membership,
same-source conflicts, exact model/effort pairs, and risk floors before any
dispatch. Together with `UBERDEV_MODEL_ROUTING_MODE` and
`UBERDEV_SERVICE_TIER`, these are the complete RFC 0013 environment controls.

**Auto-installed aliases (Claude Code only):** UberDev's SessionStart hook installs 13 top-level forwarder commands (`/issue`, `/solve`, `/turbo`, `/simplify`, `/review-pr`, `/merge`, `/dev`, `/testers`, `/ubergoal`, `/uberscan`, `/ubersimplify`, `/uberthink`, `/ubercluster`) into Claude Code's user commands directory on first session and refreshes them on plugin upgrade. The `ALIASES` table in `lib/aliases-sync.sh` is the canonical set (SSOT) — this paragraph mirrors it and is count-checked by `tests/docs-accuracy.test.sh`. Hand-authored files at any of those command paths are preserved (the hook detects them via a `managed-by: uberdev-aliases` marker and skips). Disable per-project with `auto_install_aliases: false` or globally with `UBERDEV_NO_AUTO_ALIAS=1`. Remove already-installed forwarders with `/uberdev:uninstall-aliases`. Codex does not have a slash-alias install path; use the installed `$uberdev-cmd-*` skills instead.

**`integration_branch` precedence:** CLI flag `--integration-branch=<name>` > env var `UBERDEV_INTEGRATION_BRANCH` > config file (this YAML) > `gh repo view --json defaultBranchRef`. If all four tiers are empty, `/merge` falls back to the literal `main` and emits a one-line stderr warning — it does NOT prompt (autopilot is unconditional).

**`auto_review_on_merge` precedence (#89):** env var `UBERDEV_AUTO_REVIEW_ON_MERGE` > config file (this YAML) > default `false`. When `true`, `/merge` Phase 1.4 auto-dispatches `/review-pr <N> --turbo` once per PR per `/merge` run if the trust trail is missing (reasons `trust_trail_label_missing` or `trust_trail_trailer_missing` ONLY — see `merge-pipeline/SKILL.md` `## Common Mistakes` for the exhaustive exclusion list). Cap: 1 auto-review per `(pr_number, run_id)` composite key (no cross-run state). Audit: emits `auto_review_dispatched` (before) and `auto_review_returned` (after) per triggered PR. Default `false` is bit-identical to current `/merge` (zero new audit events, zero new wall-clock). Invalid values (anything outside `true|false`) fall back to default `false` non-fatally and emit a `uberdev_config_invalid` audit event via existing helper machinery.

**`bot_authors_allow_list` semantics:** **DEPRECATED.** As of the unconditional-autopilot release, `/merge` does NOT gate on PR-author identity — every APPROVED + CI-green PR is eligible regardless of whether the author is a collaborator, a bot, or an external contributor. Phase 1.4 trust resolution accepts EITHER `reviewDecision == "APPROVED"` (PATH_1, team / branch-protection path; required reviews + status checks anchor the trust) OR a green `/review-pr` trail bound to current HEAD SHA via the `trust-trail-evaluator` agent (PATH_2, solo-dev / no-protection path; the agent reads structural primitives — ancestor + diff-empty + log-empty — and returns verdicts in `{PASS, STALE, INVALID, FORCE_PUSHED}`). Author identity is NOT a gate in either path; the new trust trail does not re-introduce author-identity gating. The key is parsed without error for backward compat but has no behavioural effect.

**`auto_confirm` precedence:** **DEPRECATED.** As of the autopilot release, `auto_confirm` (config) and `--yes` / `-y` (CLI) are no-ops — `/merge` is fully unattended end-to-end. The flag is still parsed without error for backward compat; first encounter per run emits one stderr line: `warning: --yes / -y / auto_confirm are deprecated; /merge is now fully unattended. The flag has no behavioural effect.` An audit event `deprecated_flag_used` is recorded. No grace-window removal planned. See `commands/merge.md` `## Deprecated Flags`.

**`solve_tier_floor` / `solve_tier_ceiling`:** clamp the
`/solve` auto-triage tier into `[floor, ceiling]`. Both keys take an
enum value from `{trivial, small, medium, large}`. Asymmetric clamps
are supported (set only floor or only ceiling). If `floor > ceiling`,
one stderr warning fires (`floor_gt_ceiling`) and BOTH are ignored.
Env overrides: `SOLVE_TIER_FLOOR`, `SOLVE_TIER_CEILING`. Default:
unset on both sides.

**`fanout_concurrency.{research, post_impl_review, merge_strategy, conflict_resolver, solve_bg}`:**
per-phase cap on parallel agent fanout. Each value is an int in
`[1, 50]`. When the in-scope agent count exceeds the cap, the host
skill splits dispatch into `ceil(N / cap)` sequential single-message
waves (the per-wave single-message Task() invariant is preserved).
Useful for rate-limited tiers and laptop runs where 10 parallel Claude
sessions overwhelm RAM. `solve_bg` caps the number of parallel `claude --bg` background sessions dispatched by `/turbo` (and `/solve` when multiple issue numbers are passed). Larger queues split into `ceil(N / cap)` sequential single-message waves with per-wave `solve_bg_fanout_wave_started` audit events. Mirrors `merge_strategy` (`merge-pipeline/SKILL.md:401`).
Defaults: 6 / 6 / 10 / 10 / 6 respectively. Env overrides: `UBERDEV_FANOUT_{RESEARCH, POST_IMPL_REVIEW, MERGE_STRATEGY, CONFLICT_RESOLVER, SOLVE_BG}`. Note: `conflict_resolver`
introduces a NEW default cap of 10 in Phase 3.3 of `/merge`, where the
fanout was previously uncapped — queues of 11+ conflicted files in a
single PR now chunk into multiple waves (intentional behavioural
change; matches the `merge_strategy` chunking precedent).

**`dispatch_backend` precedence (RFC 0004 / RFC 0012):** CLI flag `--backend=<name>` > env var `UBERDEV_DISPATCH_BACKEND` > config file (this YAML) > default `auto`. Accepts `auto | workflow | wezterm | background`. `auto` resolves once per `/solve` or `/turbo` invocation via `lib/dispatch.sh`'s preflight: **everything → `workflow`** (RFC 0015), on every OS class including native Windows. `workflow` runs one worktree-isolated solver agent per issue inside the calling session's Workflow runtime (`skills/solve-fleet/workflow.js`) — watch it with `/workflows`. The detached `claude --bg` backend was removed in RFC 0015 §7 as amended, and the `codex` backend in #381 — naming either is now an enum error, not a deprecation warning. The resolved backend is committed for the whole batch — a fan-out is never split across backends. An explicit `--backend=X` hard-errors before any dispatch if `X` is unusable on the host (e.g. `--backend=wezterm` from WSL2 targeting a native-Windows WezTerm). Invalid values fall back to `auto` non-fatally and emit a `uberdev_config_invalid` audit event via the existing `uberdev_read_enum` machinery.

**`command_timeouts.{solve, review_pr, merge}`:** per-command
wall-clock timeout in seconds, range `[60, 86400]` (1m–24h).
**Enforcement scope:** only `command_timeouts.solve` is enforced — the
`/solve` launcher wraps the `claude` invocation in `timeout(1)` (probing
`gtimeout` as a fallback, since `brew install coreutils` on macOS
installs the GNU binary under that name; fails-open with one stderr
warning if neither is on PATH).
`command_timeouts.{merge, review_pr}` are **ADVISORY-ONLY in v1**:
they are parsed and recorded in the audit log under
`uberdev_config_read` but NOT enforced as wall-clock kills, because
`/merge` and `/review-pr` execute inside the calling Claude turn and
enforcing kill semantics there requires deeper orchestrator-loop
changes. v2 issue can extend. Env overrides:
`UBERDEV_{SOLVE, REVIEW_PR, MERGE}_TIMEOUT`. Defaults: 3600 / 900 / 600.

**Validation behaviour:** absence of any new key yields the documented
default silently. Out-of-range / non-integer / invalid-enum values
emit one stderr line in the verbatim format
`warning: <KEY> = '<VAL>' is invalid (<REASON>); falling back to default <DEFAULT>`
and record one `uberdev_config_invalid` audit event; subsequent reads
within the same shell-process tree are silenced via the
`UBERDEV_VALIDATED_<KEY>=1` sentinel. Validation is always non-fatal —
no new key can abort the parent command.

**Recommendation:** commit this file to share workflow conventions across the team; or add it to `.gitignore` if individual preferences differ.

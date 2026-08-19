---
description: "Read-only census of everything UberDev has in flight — /solve + /turbo + /turbox claims, /goal cycle state, /review-pr reservations, the /merge lock, and per-run agent liveness — with the runtime root each store was actually read from and a concrete re-entry command per row. Never writes."
argument-hint: ""
allowed-tools: ["Bash"]
---

# Status — Unified Read-Only Run-State Census

Answer the returning operator's two questions — **what is in flight, and where do
I re-enter?** — without them having to know the five stores UberDev spreads run
state across:

| # | Store | Where it lives |
|---|-------|----------------|
| 1 | `/solve` + `/turbo` + `/turbox` claims | the `uberdev:active` GitHub label + `solve-bg-status-<N>.json` under the runtime root |
| 2 | `/goal` | `GOAL_ID`-keyed sidecars (1 jsonl + 8 TSVs + the runstate files), found through the fixed-path `goal-active-id.txt` pointer |
| 3 | `/review-pr` | `.uberdev/runs/<RUN_ID>/{locked,pr-context.json}` |
| 4 | `/merge` | `<git-dir>/uberdev-merge.lock.d/{record.json,heartbeat}` + the repo-root `.uberdev/audit.jsonl` |
| 5 | dispatched agents | `<run_dir>/.agent-state-<euid>/agent-lifecycle.jsonl` (written by `lib/agent-dispatch.sh`) |

**Usage:** `/uberdev:status` — no arguments, no flags.

## Why the root is printed, not assumed

The stores disagree on their root. `lib/dispatch.sh` hardens the runtime root to
`${TMPDIR:-/tmp}/uberdev-$(id -u)` and exports `UBERDEV_TMPDIR`, but Bash tool
calls share no shell state, so that export is process-scoped; `lib/goal-state.sh`
falls back to bare `/tmp` in most helpers and `${TMPDIR:-/tmp}` in the newer ones.
A fresh post-crash shell therefore reads a *different* root than the one the
artefacts were written to, and reports "nothing in flight" while a half-finished
run sits one directory over. Section 0 of the output probes every root a writer
can reach and every later section names the root it **actually** read — that
visibility, not the table, is the point of this command.

## Read-only guarantee

`/uberdev:status` never creates, modifies, moves, or deletes anything, and issues
no mutating `gh` call. It re-implements `lib/dispatch.sh`'s runtime-root safety
checks *without* their `mkdir`/`chmod` hardening, and deliberately avoids
`config-read.sh`'s `uberdev_read_int_in_range` (which appends an audit row to
`.uberdev/audit.jsonl` on an invalid configured value). `tests/status.test.sh`
enforces the guarantee by diffing a fixture tree before and after a full render.

Liveness is taken from the lifecycle manifest, **not** from `claude agents` — the
manifest is backend-independent, so the census stays correct as the detached
transports are retired (RFC 0015).

## Steps

Run the reader as **ONE Bash tool call** and print its output verbatim:

```bash
. "$CLAUDE_PLUGIN_ROOT/lib/status.sh" && uberdev_status_render
```

**RULES:** Do NOT use the Task tool or any subagent, do NOT re-format or
summarise away the per-row re-entry hints, and do NOT act on what you find. This
command reports; the operator decides. If a section reports a stale `/review-pr`
reservation or a stale `/merge` lock, surface the printed re-entry command — never
`rm` the marker or the lock directory yourself: each owner has a bounded reaper
that verifies ownership and link-safety before removing anything, and a blind
delete races a live producer.

`lib/status.sh` is the executable SSOT; this file is a thin wrapper over it.

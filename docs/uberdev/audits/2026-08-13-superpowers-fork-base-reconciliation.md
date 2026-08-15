# Superpowers Fork-Base Reconciliation — 2026-08-13

**Date:** 2026-08-13
**Author:** TheFJK
**Closes:** #504
**Upstream SHA (the base this reconciliation pins):** `e7a2d16476bf042e9add4699c9d018a90f86e4a6`
**Upstream repository:** `obra/superpowers` (MIT)
**Upstream fetch timestamp (UTC):** `2026-08-13T20:22:51Z`
**Upstream `origin/main` at fetch time:** `b36e0829c6d0140e93cfef2ca599b1b07d4a7797` (2026-08-12)
**Local reference tree:** `TheFJK/UberDev@7493445` (v0.46.0)

## Summary

Five `fork`-stance components recorded `"vendored_at_commit": "unknown"` in
`plugins/uberdev/vendor.json`:

| Component | `upstream_path` | `vendored_on` |
| --- | --- | --- |
| `skills/brainstorm` | `skills/brainstorming` | 2026-04-27 |
| `skills/finish-branch` | `skills/finishing-a-development-branch` | 2026-04-27 |
| `skills/requesting-code-review` | `skills/requesting-code-review` | 2026-04-28 |
| `skills/subagent-driven-dev` | `skills/subagent-driven-development` | 2026-04-27 |
| `skills/using-uberdev` | `skills/using-superpowers` | 2026-04-28 |

This audit reconciles all five to the base `e7a2d16`, and records the measurement
that justifies it. `vendor-check.py`'s `C-BASE` is **offline by policy** — it can
prove a recorded base is restated in the shipped bytes, and nothing more. It
structurally cannot re-derive any evidence below. This document is therefore the
only place a reviewer's ability to *check* the pin actually lives.

`vendored_at_commit` is the **base** — where the copy started. It is not the
watermark. `last_reviewed_upstream_commit` stays `3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9`
and `last_reviewed_on` stays `2026-08-10` for all five: pinning a base is not a
re-baseline and not the recorded act of having looked.

## 1. Reproducing the measurement

```bash
mkdir -p /tmp/504-recon && cd /tmp/504-recon
git clone --filter=blob:none --quiet https://github.com/obra/superpowers sp
cd sp
git cat-file -t e7a2d16476bf042e9add4699c9d018a90f86e4a6            # -> commit
git log -1 --format='%H %ad %s' --date=iso e7a2d16                  # 2026-04-27 21:55:33 -0700
git log -2 --format='%H %ad' --date=iso e7a2d16 | tail -1           # 6efe32c 2026-04-23
git log --format='%H %ad' --date=iso --reverse --ancestry-path e7a2d16..origin/main | head -1
                                                                    # f2cbfbef 2026-05-04
git ls-tree -r --name-only e7a2d16 -- skills/using-superpowers/
```

Then the candidate scan: for each of the five components, walk **every** upstream
commit that touched its `upstream_path`, and score each resulting tree as

> **(file-set symmetric difference, then changed lines summed over the
> intersection)**

where "changed lines" is GNU `diff`'s `<` plus `>` line count against the shipped
copy. File-set agreement is the primary key deliberately: a residual-first ranking
nominates artefacts where most of our files do not exist upstream, because the
missing files contribute no residual at all.

The scan, run from the clone with the UberDev repo root as `argv[1]`:

```python
import subprocess, sys, os, json, tempfile
repo = sys.argv[1]
BASE = "e7a2d16476bf042e9add4699c9d018a90f86e4a6"
pairs = {
 "skills/brainstorm": "skills/brainstorming",
 "skills/finish-branch": "skills/finishing-a-development-branch",
 "skills/requesting-code-review": "skills/requesting-code-review",
 "skills/subagent-driven-dev": "skills/subagent-driven-development",
 "skills/using-uberdev": "skills/using-superpowers",
}
reg = json.load(open(os.path.join(repo, "plugins/uberdev/vendor.json"), encoding="utf-8"))
byid = {c["id"]: c for c in reg["components"]}

def run(a):
    p = subprocess.run(a, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("FAILED %s: %s" % (a, p.stderr.strip()))
    return p.stdout

cache = {}
def residual(oid, ourpath):
    if (oid, ourpath) in cache:
        return cache[(oid, ourpath)]
    p = subprocess.run(["git", "cat-file", "-p", oid], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("cat-file failed for %s: %s" % (oid, p.stderr.strip()))
    if not p.stdout:
        raise SystemExit("EMPTY blob %s — refusing to score it as total divergence" % oid)
    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as fh:
        fh.write(p.stdout); tmp = fh.name
    out = subprocess.run(["diff", tmp, ourpath], capture_output=True, text=True).stdout
    os.unlink(tmp)
    n = sum(1 for l in out.splitlines() if l.startswith("<") or l.startswith(">"))
    cache[(oid, ourpath)] = n
    return n

def tree(sha, up):
    fs = {}
    for ln in run(["git", "ls-tree", "-r", sha, "--", up + "/"]).splitlines():
        meta, path = ln.split("\t", 1)
        fs[path[len(up) + 1:]] = meta.split()[2]
    return fs

for local, up in pairs.items():
    ours = set(byid[local]["files"])
    basefs = tree(BASE, up)
    baseres = sum(residual(basefs[r], os.path.join(repo, "plugins/uberdev", local, r))
                  for r in sorted(set(basefs) & ours))
    scored = []
    for sha in run(["git", "rev-list", "origin/main", "--", up]).split():
        fs = tree(sha, up)
        if not fs:
            continue
        res = sum(residual(fs[r], os.path.join(repo, "plugins/uberdev", local, r))
                  for r in sorted(set(fs) & ours))
        scored.append((len(set(fs) ^ ours), res, sha))
    scored.sort()
    print("%-32s candidates=%d BASE=(symdiff %d, res %d) tiemate=%s top5=%s"
          % (local, len(scored), len(set(basefs) ^ ours), baseres,
             run(["git", "rev-list", "-1", BASE, "--", up]).strip()[:8],
             [(s[0], s[1], s[2][:8]) for s in scored[:5]]))
```

### A reproducibility trap in the scan itself

`--filter=blob:none` makes the clone lazy. `git cat-file -p <blob>` then triggers
a promisor fetch that **can fail**, and an unchecked `subprocess.run(...).stdout`
hands back an empty string — which the residual counter reads as "every one of our
lines is a change". That happened once on the first pass here and inflated
`skills/using-uberdev` from **16** to **129** (= our 125-line `SKILL.md` counted
whole, plus the two genuinely-shared residuals 3 + 1). The scan above checks the
return code and refuses an empty blob outright. Anyone re-running this must do the
same, or pre-fetch the blobs with a full clone. The numbers in this document are
from the hardened run.

## 2. `e7a2d16` was upstream `main`'s HEAD across the whole vendoring window

```
6efe32c9e2dd002d0c394e861e0529675d1ab32e  2026-04-23 18:31:11 -0700
e7a2d16476bf042e9add4699c9d018a90f86e4a6  2026-04-27 21:55:33 -0700   <- upstream HEAD
f2cbfbefebbfef77321e4c9abc9e949826bea9d7  2026-05-04 15:05:01 -0700
```

Upstream `main` sat at `e7a2d16` from 2026-04-27 21:55 PDT until 2026-05-04 15:05
PDT. All five components record `vendored_on` inside that window (2026-04-27 or
2026-04-28). Anyone copying from upstream `main` on those dates copied `e7a2d16`'s
trees.

The distinction between `e7a2d16` and its parent `6efe32c` is **byte-immaterial for
these five paths**: `e7a2d16` touches none of them, so its tree for each is
identical to `6efe32c`'s. Where the two are indistinguishable by content,
`e7a2d16` is the register-consistent choice — the four already-pinned superpowers
skill components and `docs/uberdev/audits/2026-05-04-superpowers-vendor-audit.md`
both record it.

Because `e7a2d16` touches none of the five paths, it does **not** appear in any
candidate list below. The identity check that connects the two is

```bash
git rev-list -1 e7a2d16 -- <upstream_path>
```

which names the last commit to touch the path at or before the base — the
**tie-mate** whose tree `e7a2d16` carries. For all five paths the tie-mate's
`git ls-tree -r` listing is byte-identical to the base's, so the tie-mate's row in
the candidate table *is* a measurement of the base, not an approximation of one:

| Component | tie-mate | tie-mate date |
| --- | --- | --- |
| `skills/brainstorm` | `9f04f063` | 2026-03-24 |
| `skills/finish-branch` | `141953a4` | 2025-10-17 |
| `skills/requesting-code-review` | `9ccce3bf` | 2026-03-11 |
| `skills/subagent-driven-dev` | `9ccce3bf` | 2026-03-11 |
| `skills/using-uberdev` | `8b166926` | 2026-03-25 |

## 3. Candidate scan results

| Component | candidates scanned | file set at `e7a2d16` | residual at `e7a2d16` | tie-mate | best candidate score |
| --- | ---: | --- | ---: | --- | --- |
| `skills/brainstorm` | 83 | 8/8, symdiff 0 | 1515 | `9f04f063` | `(0, 1515)` `9f04f063` |
| `skills/finish-branch` | 12 | 1/1, symdiff 0 | 949 | `141953a4` | `(0, 949)` `141953a4` |
| `skills/requesting-code-review` | 14 | 2/2, symdiff 0 | 18 | `9ccce3bf` | `(0, 18)` `030a222a` / `9ccce3bf` / `f57638a7` |
| `skills/subagent-driven-dev` | 62 | 4/4, symdiff 0 | 964 | `9ccce3bf` | `(0, 963)` `d7f47d35` / `f2cbfbef` — **see §5** |
| `skills/using-uberdev` | 35 | symdiff 2 | 16 | `8b166926` | `(2, 16)` `8b166926` |

For four of the five, no commit in upstream history scores better than the base's
tree. Verified for every row: the tie-mate's tree for the path is **byte-identical**
to the base's (`git ls-tree -r` listings compare equal), which is what makes the
tie-mate's score a measurement *of the base*.

Two rows have additional commits at the same top score, and those are **different
trees that happen to score equal**, not copies of the base's tree — checked, not
assumed:

- `skills/finish-branch` — `48410c7f` (2025-10-17) and `9c9547cc` (2025-10-16) also
  score `(0, 949)`; three distinct trees, one score.
- `skills/requesting-code-review` — `030a222a` (2025-12-11) and `f57638a7`
  (2026-01-22) also score `(0, 18)`; likewise three distinct trees.

All four predate `vendored_on` by five to nine months, and none of them was
upstream `main`'s HEAD on the vendoring dates. The score alone does not separate
them from the base; §2's HEAD-window evidence is what does, which is why this audit
leads with that and not with the ranking.

`skills/using-uberdev`'s symdiff of 2 is fully explained in §6.

One caveat on that last row, stated so nobody has to rediscover it: three commits
score `(3, 15)` — one changed line *fewer* over a file set that is one file
*further* away (`21a774e9` 2026-03-09, `687a6618` 2026-03-15, `2b1bfe5d`
2026-03-23). They rank below `(2, 16)` only because the key is file-set-first. If
you re-rank on residual alone, they win, and they are wrong: a tree that shares
fewer files with our copy contributes less residual precisely *because* the missing
files contribute none at all. That asymmetry is the whole reason for the key's
ordering — and all three predate `vendored_on` (2026-04-28) by a month besides, so
the date check excludes them independently.

## 4. Per-file residual at the base

Every number below is `diff <upstream-blob-at-e7a2d16> <shipped-file>` counting
`<` and `>` lines, measured 2026-08-13 against `TheFJK/UberDev@7493445`.

| Component | File | residual | upstream lines |
| --- | --- | ---: | ---: |
| `skills/brainstorm` | `SKILL.md` | 365 | 164 |
| | `scripts/frame-template.html` | 722 | 214 |
| | `scripts/helper.js` | 289 | 88 |
| | `scripts/server.cjs` | **6** | 354 |
| | `scripts/start-server.sh` | **4** | 148 |
| | `scripts/stop-server.sh` | 66 | 56 |
| | `spec-document-reviewer-prompt.md` | 17 | 49 |
| | `visual-companion.md` | 46 | 287 |
| | **total** | **1515** | |
| `skills/finish-branch` | `SKILL.md` | 949 | 200 |
| `skills/requesting-code-review` | `SKILL.md` | 10 | 105 |
| | `code-reviewer.md` | 8 | 146 |
| | **total** | **18** | |
| `skills/subagent-driven-dev` | `SKILL.md` | 804 | 277 |
| | `code-quality-reviewer-prompt.md` | 45 | 26 |
| | `implementer-prompt.md` | 79 | 113 |
| | `spec-reviewer-prompt.md` | 36 | 61 |
| | **total** | **964** | |
| `skills/using-uberdev` | `SKILL.md` | **12** | 117 |
| | `references/copilot-tools.md` | **3** | 52 |
| | `references/gemini-tools.md` | **1** | 33 |
| | **total** | **16** | |

### The near-identical files are the load-bearing evidence

A large aggregate residual is weak evidence — a fork can drift arbitrarily far
from any base. The **near-identical** files are what no earlier commit can
explain:

- `brainstorm/scripts/server.cjs` — 6 changed lines against a 354-line upstream file
- `brainstorm/scripts/start-server.sh` — 4 against 148
- `using-uberdev/references/gemini-tools.md` — 1 against 33
- `using-uberdev/references/copilot-tools.md` — 3 against 52

Four files that are essentially upstream's bytes at this exact commit. A component
whose script files sit within a handful of lines of `e7a2d16` did not descend from
somewhere else.

**Re-running these numbers after this change lands gives +1 on every `SKILL.md`
row** (and therefore +1 on each component total): the closing PR inserts one
provenance header line into each of the five `SKILL.md` files. The numbers above
are measured against the *pristine* tree at `7493445`, before that insertion. A
reviewer who reproduces them on `main` afterwards and gets 1516 / 950 / 19 / 965 /
17 has reproduced them correctly.

## 5. `skills/subagent-driven-dev`: two candidates score better, and are excluded on date

Two commits beat the base by **one line** — `(0, 963)` against the base's
`(0, 964)`:

| Candidate | date |
| --- | --- |
| `f2cbfbefebbfef77321e4c9abc9e949826bea9d7` | 2026-05-04 15:05:01 -0700 |
| `d7f47d350a5fb53014af8bd707420c811f82ac1f` | 2026-05-05 18:26:21 -0700 |

Both **postdate this component's `vendored_on` (2026-04-27) by a week**. They are
excluded chronologically, not by score. Stating this plainly matters: the claim
"no candidate scores better" is false for this component, and an audit that
asserted it would be wrong in a way a reviewer re-running the scan would catch
immediately.

A one-line advantage over 964 is noise besides. Both candidates are also
*descendants* of the base, so a one-line improvement is what a small upstream edit
that happens to move toward our copy looks like — not evidence of a later copy
event.

## 6. `skills/using-uberdev`: the symdiff of 2, and why `references/configuration.md` is not stamped

At `e7a2d16`, upstream ships:

```
skills/using-superpowers/SKILL.md
skills/using-superpowers/references/codex-tools.md
skills/using-superpowers/references/copilot-tools.md
skills/using-superpowers/references/gemini-tools.md
```

UberDev ships `SKILL.md`, `references/configuration.md`, `references/copilot-tools.md`,
`references/gemini-tools.md`. The base-relative divergence is therefore **exactly
two files**:

- **ours only** — `references/configuration.md` (UberDev's own config-schema
  reference; it does not exist upstream at the base)
- **upstream only** — `references/codex-tools.md` (never vendored)

Two further facts fall out of the same measurement:

1. `references/copilot-tools.md` **exists at the base and was deleted upstream by
   the watermark `3dcbd5c4`** (v6.2.0). The local copy is a base-era file, not a
   local invention — and its 3-line residual against the base is corroboration.
2. The register's existing `stance_reason` named upstream's set as
   `antigravity-tools.md` / `codex-tools.md` / `pi-tools.md`. That is exactly the
   file set at the **watermark**, not at the base. It was true; it was simply
   unlabelled. Both `stance_reason` entries that mix the two references now say
   which commit each claim is measured against.

### Why the witness sits on `SKILL.md`

`C-BASE` accepts a provenance witness on **any** file of the component. A pin
witnessed only on `references/configuration.md` would therefore be accepted while
being uncheckable against upstream by anyone — the file does not exist at the
recorded base, so there is nothing upstream to compare it to. Issue #504 names
this hazard directly.

Measured on this tree: moving `skills/brainstorm`'s header off `SKILL.md` onto its
sibling `visual-companion.md` leaves `vendor-check.py` at **rc 0 with all ten
checks green**. The checker cannot see *where* a witness sits.

`tests/vendor-provenance.test.sh` **V30** closes that gap: every pinned `skills/*`
component must restate its base on its own `SKILL.md`. `SKILL.md` is the one file
every vendored skill provably shares with upstream, so "the witness is on
`SKILL.md`" is the only *offline*-checkable proxy for "the witness is on a file
upstream actually had" — and offline is this guard's policy, by design. **V30b**
is its falsifiability arm: it moves a header off `SKILL.md` (keeping the component
witnessed, so `C-BASE` stays green) and demands V30 go red on placement alone.

## 7. Residual risk

`e7a2d16` is upstream `main`'s HEAD across the entire vendoring window, and it is
the best-scoring tree in upstream history for four of the five components (the
fifth is explained in §5). What this audit **cannot** produce is a repo artefact
recording the copy event itself: `git log` in this repository recovers the
*vendoring* commit, never the upstream base. The pin is a reconstruction from
measurement, stated as such — the same standard RFC 0019 §2.2 sets for
`"unknown"`, applied in the other direction.

Two consequences follow, and both are deliberate:

- The pin is not a re-baseline. `last_reviewed_upstream_commit` and
  `last_reviewed_on` are untouched, so `vendor-drift.py` keeps diffing from the
  watermark and week 1 does not report the whole pre-existing delta as new drift.
- No upstream bytes were adopted. The only content change in the closing PR is the
  five inserted provenance header lines.

## 8. What landed

- `plugins/uberdev/vendor.json` — `vendored_at_commit` set to `e7a2d16…` on the
  five components; each `stance_reason` restated to name the base, the method, the
  measured numbers, and which reference (base or watermark) each file-set claim is
  measured against. No other field moved.
- The five `SKILL.md` files — one provenance header line each, on the first body
  line after the closing frontmatter `---`, matching the house format already used
  by `skills/dispatching-parallel-agents/SKILL.md`.
- `tests/vendor-provenance.test.sh` — V5's header-count literal 21 → 26; **V30** +
  **V30b** added; **V21** re-shaped to manufacture its own precondition instead of
  hunting for an unpinned headerless component (a pool that #503 and #505 empty
  permanently).
- `docs/rfc/0019-vendored-upstream-policy.md` §2.2 — the two derived counts
  re-derived from the register: 10 → 5 unpinned skill directories, 16 → 11 of the
  20 components reading `"unknown"`. `tests/vendor-provenance.test.sh` V24 is what
  keeps them honest.

`docs/uberdev/audits/2026-05-04-superpowers-vendor-audit.md` is **not** amended by
this work: it is a historical snapshot of a different component set, with its own
amendment convention.

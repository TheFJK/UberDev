# RFC 0016 — `CONTRACT:` markers: making closed-vocabulary coupling machine-visible

- **Status:** Accepted — implemented in `tests/contract_markers.py` + `tests/contract-markers.test.sh`
- **Issue:** #370 (Half A). Ranks 6–13 of the contract-drift register, plus rank 4
  and one contract the register does not list (see §3).
- **Supersedes:** nothing. **Superseded by:** nothing.

**Reference convention (normative for this RFC):** every reference below is a
*symbol* — a function, constant, file or contract name — never a `file:line`
literal. Line numbers rot inside a single release; the symbols are greppable and
the marker itself is the durable anchor.

---

## 1. Context

Six bugs shipped in the v0.42.x round from one shape: **one contract, two or
more independent copies, and nothing comparing them.** #360 put the `--backend`
enum in two whitelists and aborted every `/goal` cycle at dispatch for nine
releases. #361 modelled the runtime's reply but not the constraint applied to
it. #362 split the `files` / `components` token shapes.

The 33-agent sweep recorded in #370 split the survivors into two mechanically
different halves. **Half A** is the set where every copy is *the same token set
written in a different language*: a bash `case` alternation, a jq regex, a
Python `frozenset`, a JSON array, a shell scalar, a Markdown table cell. Those
copies are textually comparable, so one comparator retires all of them.

What kept the class alive was not difficulty — it was **invisibility at the edit
site**. Before this RFC the only signal that two literals were coupled was a
prose comment. `uberdev_goal_read_run_state`'s allowlist says "Keep this list
byte-aligned with the dispatch enum minus `auto`". `lib/status.sh`'s Constants
block says "Contract mirrors, not independent policy … so drift stays
auditable". Auditable by a human, enforced by nothing.

**A comment is not a producer.** This RFC turns the comment into one.

---

## 2. Decision

Adopt a marker comment placed at every declaration site of a closed vocabulary,
and one meta-test — `tests/contract_markers.py`, wrapped by
`tests/contract-markers.test.sh` — that extracts every site per contract name,
applies each site's declared delta, and asserts set equality.

### 2.1 Grammar

```
CONTRACT: <name> [@<anchor>] [/<regex>/] [<delta> ...]
```

with an optional closing line that extends the region:

```
/CONTRACT: <name>
```

The comment leader is per-language and is stripped before parsing: `#` for
shell / Python / jq, `//` for JavaScript, `<!-- ... -->` for Markdown.

| Term | Meaning |
|---|---|
| `<name>` | kebab-case contract id (`dispatch-backend`, `trust-signal`). Must be present in the `CONTRACTS` registry. |
| `@<anchor>` | Optional. The region starts at the first line at or after the marker containing the literal anchor text, instead of the line directly below. |
| `/<regex>/` | Optional. Switches the site from *span mode* to *harvest mode*. |
| `<delta>` | Zero or more `-<member>` / `+<member>` terms declaring that this site is deliberately the contract minus / plus those members. |

### 2.2 Extraction

**Span mode** (default) enumerates candidate spans in the region — every quoted
string, every `[...]` / `{...}` group, every bare pipe-alternation, and every
Markdown table cell — tokenises each on `|`, `,`, whitespace and quote
characters, and keeps the span that yields the most distinct members **and
contains no rejected token**. A token is rejected when it does not fullmatch
`[A-Za-z0-9][A-Za-z0-9_.-]*`, which is how spans carrying shell or regex syntax
(`"$v"`, `type:`, `(audit-log`) disqualify themselves rather than poisoning the
member set.

**Harvest mode** (`/regex/` present) unions the tokens of every regex match in
the region. It exists for sites whose declaration is *scattered* rather than a
single literal: `uberdev_semaphore_acquire` assigns its twelve failure reasons
across ~20 statements, and `uberdev_goal_read_trust_signal` emits its five
values from fifteen separate `printf` calls. **The regex must key on the shape
of the emitting statement, never on the member names** — a regex that enumerates
the members makes the site vacuous, because it can then only ever agree with
itself.

### 2.3 Why a heuristic extractor is acceptable

Span mode is a heuristic, and that is safe here for exactly one reason: **its
failure mode is a failing test, never a passing one.** Pick the wrong span at a
mirror and that mirror's set will not equal the canonical's, so CI reds. Pick
the wrong span at the canonical and every mirror reds. There is no span choice
that makes two genuinely different token sets compare equal.

Because that property is the whole justification, it is protected explicitly:
every site must yield at least two members, and a marker whose region yields
zero is a hard failure — never a skip.

### 2.4 Why deltas are mandatory, not a convenience

A design without deltas would be vacuous exactly where the drift lives. The
`/goal` run-state allowlist inside `uberdev_goal_read_run_state` is the dispatch
enum **minus `auto`** (`auto` is a request, never a resolution).
`validated_terminal_status` in `lib/run_manifest.py` deliberately validates four
of the five `TERMINAL_EVENTS`. A child status-file validator in
`lib/child-dispatch.sh` is the terminal set **plus `running`**.

A declared delta is visible at the edit site and still reds when the **base**
changes. An undeclared one is the bug. Deltas are themselves checked: a `+m`
whose member is absent from the site, or a `-m` whose member is present, is a
stale delta and fails.

### 2.5 Sites that cannot carry a comment

Two escape hatches, both of which keep the site **compared** rather than skipped:

- **`@anchor`** covers declarations that a neighbouring comment line would
  damage. `skills/goal-pipeline/SKILL.md`'s Constants block is a fenced block
  held byte-identical by `tests/goal.test.sh` G24/G28/G34, and
  `skills/merge-pipeline/SKILL.md`'s `PARK_REASON_ENUM` lives in a Markdown
  table where an interleaved comment would split the table in two. The marker
  sits outside the fragile region and resolves forward to the declaration.
- **JSON has no comment syntax.** `policy/model-routing-v1.json`'s
  `risk_signals` is therefore declared in the test's own `JSON_SITES` table by
  path + key, and extracted exactly (`json.load` + key lookup) rather than
  heuristically. Adding a sibling key to a *versioned policy artifact* that
  `lib/model_routing.py` validates would be a behavioural change to shipped
  policy, which a marker package has no business making.

### 2.6 Anti-vacuity

`tests/component-token-schema.py` is the register's own cautionary tale: a guard
of this shape can sit in CI, look right, and cover nothing. So the meta-test
carries five ratchets:

1. **`CONTRACTS` registry** — every contract name with its **exact** expected
   site count. A deleted marker must red, not silently shrink the comparison
   set. Adding a legitimate new mirror is a deliberate one-number edit, in the
   same spirit as the repo's version-locks.
2. **No contract may have fewer than two sites.** A one-site "contract" needs no
   comparator, so its presence in the registry means someone marked the wrong
   thing.
3. **Both trees must be walked**, `plugins/uberdev/**` and
   `codex/uberdev-codex/**`, and each must yield files. A scan that silently
   missed the Codex mirror would be this very bug one level up.
4. **Mirror parity per contract** — the set of marked relative paths under
   `plugins/uberdev/` must equal the set under `codex/uberdev-codex/`, so a
   marker added to one tree and forgotten in the other reds.
5. **`--selftest` and the in-CI mutation.** The extractor is a producer too, so
   it has its own oracle: synthetic fixtures for every extraction mode plus the
   negative cases (zero members, one member, stale delta, unparsable term,
   unresolvable anchor). `tests/contract-markers.test.sh` C3 then copies the two
   trees, adds a sixth terminal event at one site, and asserts the scan reds and
   names both the contract and the moved member — so the anti-vacuity property
   is asserted on **every** CI run, not just in the PR that introduced it.

---

## 3. What is registered today

| Contract | #370 rank | Members | Sites (both trees) | Notes |
|---|---|---|---|---|
| `dispatch-backend` | 6 | 6 | 4 | run-state allowlist carries `-auto` |
| `agent-liveness-value` | 7 | 5 | 8 | three `goal-state.sh` probes carry `-queued` (declared divergence) |
| `run-terminal-status` | 8 | 4 | 18 | one child-dispatch validator carries `+running` |
| `goal-audit-event` | 9 | 13 | 4 | SKILL.md constants block via `@anchor` |
| `park-reason` | 10 | 4 | 4 | Markdown table via `@anchor`; goal-state side via harvest |
| `agent-terminal-event` | 11 | 5 | 14 | |
| `semaphore-lease-acquire-reason` | 12 | 12 | 8 | all four sites harvest `lease_acquire_*` |
| `trust-signal` | 13 | 5 | 8 | |
| `risk-signal` | 4 | 11 | 8 | includes the JSON-declared policy site |
| `goal-circuit-breaker-reason` | — | 9 | 4 | **not in the register** — found by applying this convention; the run-state allowlist carries `-solver_failed` |

The last row is the point of the exercise: the mechanism found a tenth member of
the family on its first application. `GOAL_CIRCUIT_BREAKER_REASONS` declares nine
halt reasons; the `CIRCUIT_BREAKER_HALT` allowlist inside
`uberdev_goal_read_run_state` enumerates eight. It is latent rather than live —
today only `agent_stuck_on_dialog` is ever assigned to that scalar — but the arm
has no else branch, so the residue shape is identical to the one that broke
`UBERDEV_RESOLVED_BACKEND` in #360. The divergence is declared at the site with a
comment saying it is drift, not intent, and it now reds on any one-sided edit.

---

## 4. What this does NOT do

- **It is not a shape guard.** Half B of #370 (ranks 3–5's regex/schema
  round-trips) is untouched, and textual diffing there would give false
  confidence: a scraper regex and a `fullmatch` validator are not supposed to be
  equal, and no literal comparison catches that one is unbounded while the other
  caps at 256. That half needs real producer output round-tripped through the
  real validator.
- **It does not fix behaviour.** Where marking exposed a live divergence, the
  divergence is *declared* and left to its own issue. The known one is rank 7:
  `queued` is a live lifecycle value to `agent-dispatch.sh`'s probe and not-live
  to all three `lib/goal-state.sh` probes. Each `goal-state.sh` site carries
  `-queued` and a comment naming #370. Deciding whether `queued` *should* be
  live is a behaviour question, as is the accompanying `state` vs `status`
  field-name divergence that this token-set comparator cannot express at all.
- **It does not replace the better fix where one exists.** Rank 13's
  `TRUST_SIGNAL_ENUM` copy inside `skills/goal-pipeline/workflow.js` buys
  nothing — the relay is mechanical, the shell side already validates, and the
  register's own recommendation is to delete it. Marking it is the interim: it
  cannot drift silently any more, but deletion remains the correct end state.

---

## 5. Adding a contract

1. Put `CONTRACT: <name>` above every declaration site, in **both** trees.
2. Add `"<name>": <exact site count>` to `CONTRACTS` in
   `tests/contract_markers.py`.
3. Run `python3 -I tests/contract_markers.py --dump` and read the extracted
   member set back. If a site extracted the wrong span, fix the marker (add an
   `@anchor` or a `/regex/`) — do not widen the tokeniser.
4. Mutation-prove it: change one member at one site, watch it red, revert.

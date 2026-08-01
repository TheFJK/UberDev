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
| `@<anchor>` | Optional. The region starts at the **unique** line at or after the marker containing the literal anchor text, instead of the line directly below. `@"..."` may contain spaces. Two matches is an error, not a first-match win. |
| `!<mode>` | Optional. Selects a built-in extractor. Today: `!case-arm`. |
| `/<regex>/` | Optional. Switches the site to *harvest mode*. Mutually exclusive with `!<mode>`. |
| `<delta>` | Zero or more `-<member>` / `+<member>` terms declaring that this site is deliberately the contract minus / plus those members. |

**The region defaults to ONE line.** That default is the wrong choice at any
`case` or `elif` chain: the most likely real edit there is *adding an arm*, and a
one-line region cannot see it. Close those regions with `/CONTRACT: <name>` at
the `esac` / end of chain — the closing marker binds to the nearest preceding
unclosed marker of the same name, bracket-style.

### 2.2 Extraction

**Region text is stripped of comments first**, quote-aware, per language. Without
that, a delimiter-separated decoy in a trailing comment
(`# keep aligned with a|b|c|d`) wins the max-members span and hides a member
*removal* from the real declaration beside it. Only a leader at line start or
after whitespace counts, which is the real shell rule and leaves `$#`,
`${x#y}` and `https://` intact.

**Span mode** (default) enumerates candidate spans in the region — every quoted
string, every `[...]` / `{...}` group, every bare pipe-alternation, and every
Markdown table cell — tokenises each on `|`, `,`, whitespace and quote
characters, and keeps the span that yields the most distinct members **and
contains no rejected token**. A token is rejected when it does not fullmatch
`[A-Za-z0-9][A-Za-z0-9_.-]*`, which is how spans carrying shell or regex syntax
(`"$v"`, `type:`, `(audit-log`) disqualify themselves rather than poisoning the
member set. If a **second** span in the region also carries ≥ 2 members and a
*different* set, the region declares two competing vocabularies and extraction is
a hard failure — see §2.3 for why that rule exists.

**`!case-arm` mode** harvests the arm heads of the region's outermost shell
`case`, splitting alternations and tokenising **quoted** arms (`"hook-fail")` is
legal shell, and a one-character edit must not hide an arm). It tracks
`case`/`esac` *depth*, so a nested case's arms are excluded structurally — the
`stale|missing)` arm of goal-watch's trust-signal switch sits *after* a nested
verdict-state case, so the region cannot simply stop short of it, and an
indentation anchor would break on any reindent.

**Harvest mode** (`/regex/`) unions the tokens of every regex match in the
region; every capturing group that participated contributes, so one pattern can
branch over several statement shapes. It exists for declarations that are
*scattered* rather than a single literal: `uberdev_semaphore_acquire` assigns its
twelve failure reasons across ~20 statements, and
`uberdev_goal_read_trust_signal` emits its five values from fifteen separate
`printf` calls.

> **The regex must key on the shape of the emitting statement — not on the
> member names, and not on a member-name PREFIX.** A prefix filter looks like it
> keys on shape and does not: `/lease_acquire_[a-z_]+/` extracts a 12-member
> *projection* of a 22-member and a 13-member set, and a projection of a superset
> **silently agrees** with the set it projects, so ten members at one validator
> and one at another were compared against nothing. The first edition of this RFC
> stated the rule correctly and the first edition of the guard violated it at all
> eight sites of `semaphore-lease-acquire-reason`. Where a site is a genuine
> superset, take the **whole container span** and declare the extra members as
> explicit `+member` deltas: a superset relationship declared at the site beats a
> projection that agrees by construction.
>
> The same trap in a different costume is keying on *quoting style*.
> `/printf '([a-z]+)\n'/` matched 15 of the producer's 22 `printf` statements, so
> a sixth value emitted as `printf "amber\n"` or `echo amber` was invisible. Key
> on the statement's **role** — an unredirected single-literal emission — and let
> the quoting vary.

### 2.3 What the heuristic extractor actually guarantees

**The first edition of this RFC claimed "there is no span choice that makes two
genuinely different token sets compare equal." That claim is false and is
withdrawn.** An adversarial sweep refuted it twice: a decoy token list in a
trailing comment won the max-members span and hid a member removal, and a
first-match `@anchor` bound to a decoy line inserted above a byte-locked
declaration. Both are now closed (comment stripping; anchor uniqueness), but the
*claim* was the real defect — it asserted a property the mechanism never had, and
a false claim in a shipped RFC is worse than no RFC.

Here is the property span mode actually has, stated so it can be checked:

1. A region containing **exactly one** multi-member vocabulary extracts that
   vocabulary, or fails loudly (zero members, or fewer than `MIN_MEMBERS`).
2. A region containing **two different** multi-member vocabularies is a hard
   failure — the extractor refuses to choose rather than silently preferring the
   larger. Singleton spans (an individual quoted string inside a set literal,
   `"string"` beside a JS enum array) are below `MIN_MEMBERS` and never compete,
   and a singleton cannot win against a real vocabulary anyway.
3. Given (1) and (2), a *mis-extraction that changes the member set* cannot be
   silent: the mirror sites disagree and CI reds.

What it does **not** guarantee is that the marker is attached to the declaration
you meant — only that whatever it is attached to is extracted honestly and
compared. §2.7 lists the residue that follows from that.

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
  **The anchor must resolve uniquely.** A first-match scan is not an escape
  hatch, it is a second attack surface: inserting a decoy line carrying the
  canonical set *between* the marker and a byte-locked declaration re-points the
  marker and lets the real declaration drift in silence. Two matches is an error;
  a `@"..."` anchor may contain spaces so the shortest unique anchor is always
  expressible (`PARK_REASON_ENUM` alone occurs eight times in
  merge-pipeline/SKILL.md, so that site anchors on ``@"| `PARK_REASON_ENUM` |"``).
- **jq comments.** Two of the three `agent-liveness-value` probes declare their
  vocabulary inside a jq program embedded in a single-quoted shell string. jq
  treats `#` as a comment to end of line, so those markers sit *on* the
  declaration and need no anchor at all — the better answer whenever it is
  available. (The prose in those comments carries no apostrophe: one would
  terminate the surrounding shell string.)
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

1. **`CONTRACTS` registry pins PATHS, not a count** — for each contract, the
   exact multiset of plugin-tree-relative files expected to declare it. A
   count-only ratchet passes when a marker is *moved* off one file and
   duplicated onto another: the count holds, per-tree parity holds, and the
   abandoned declaration drifts free. The path multiset must match in **both**
   trees, which folds mirror parity into the same comparison — a marker added to
   one tree and forgotten in the other reds, and the message names the file and
   the direction rather than printing two empty sets.
2. **No contract may have fewer than two sites.** A one-site "contract" needs no
   comparator, so its presence in the registry means someone marked the wrong
   thing.
3. **Both trees must be walked**, `plugins/uberdev/**` and
   `codex/uberdev-codex/**`, and each must yield files. A scan that silently
   missed the Codex mirror would be this very bug one level up. The walk is a
   **denylist** of binary suffixes, not an allowlist of "text" ones: the first
   edition allowlisted eleven extensions, which quietly excluded `.ts`, `.cmd`,
   `.html` and every extension-less executable under `hooks/` and `lib/` while
   looking exhaustive.
4. **A commented-out declaration cannot keep its marker.** Comment stripping
   runs before extraction, so commenting the declaration out empties the region
   and the site fails with ZERO members instead of tokenising the dead text.
5. **`--selftest` and two in-CI mutations.** The extractor is a producer too, so
   it has its own oracle: 27 synthetic fixtures covering every extraction mode
   plus eleven negative cases (zero members, one member, both stale-delta
   directions, unparsable term, unknown mode, two modes, unresolvable anchor,
   ambiguous anchor, ambiguous region, commented-out declaration).
   `tests/contract-markers.test.sh` then copies both trees and mutates them for
   real: **C3** adds a sixth terminal event at one site, **C4** adds a new `case`
   arm — the edit shape a one-line region cannot see — and both must red and name
   the contract and the moved member. The anti-vacuity property is therefore
   asserted on **every** CI run, not just in the PR that introduced it.

### 2.7 Known limits

Stated because an unstated limit reads as a guarantee:

- **A marker moved onto a same-set decoy in the same file is not detected.**
  Delete the marker from the real declaration, add a second declaration carrying
  the identical member set, and put the marker on that: every check passes, and
  the real declaration is no longer compared. Closing it needs a per-site
  *symbol* in the registry, which would make the registry a second copy of the
  declarations — the exact shape this file exists to eliminate. The mitigation is
  that the decoy is itself compared from then on, so the *next* edit to either
  copy reds. This is a sabotage shape, not a drift shape.
- **A computed emission is not statically extractable.** At the trust-signal
  producer, `printf '%s\n' "$override"` emits a value no literal harvest can see.
  The site catches every literal emission in any quoting style; a value routed
  through a variable is outside the mechanism.
- **A name-identity contract cannot be expressed.** #370 rank 7's larger half is
  the field name (`state` for background-kind rows, `status` for interactive),
  not the value set. That is a one-member contract, and `MIN_MEMBERS = 2` — the
  invariant that makes span mode safe at all — structurally forbids it. It needs
  a different mechanism, not a marker.
- **Prose is not a declaration.** `commands/goal.md` still says "seven circuit
  breakers" where the enum has nine. Sentences are not token sets and this
  comparator does not read them.

---

## 3. What is registered today

**How to read the site count.** "Sites" counts marker lines across both trees, so
it is 2× the number of declarations in the shipped plugin tree. Half of it is the
Codex mirror, and four of the twelve marked files
(`lib/agent-dispatch.sh`, `lib/dispatch.sh`, `lib/status.sh`,
`policy/model-routing-v1.json`) were **already** byte-locked to their plugin-tree
twin before this convention existed — `tests/child-dispatch.test.sh`,
`tests/solve-routing.test.sh` and `tests/status.test.sh` `cmp` them. For those
files the Codex-side markers add no coupling that did not already exist. The
honest figure is **40 declarations in `plugins/uberdev/`, of which the 13 Codex
counterparts in already-`cmp`-locked files are bookkeeping rather than new
coupling.**

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

- **It is not a shape guard.** Half B of #370 (ranks 3–5) is untouched, and
  textual diffing there would give false confidence: a scraper regex and a
  `fullmatch` validator are not supposed to be equal, and no literal comparison
  catches that one is unbounded while the other caps at 256. That half needs real
  producer output round-tripped through the real validator. Rank 4 appears in the
  table above only because its *five literal copies* are textually comparable —
  the guard it still needs is a round-trip of `solve_triage`'s `RISK_PATTERNS`
  (the actual producer, deliberately unmarked here) through those validators.
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

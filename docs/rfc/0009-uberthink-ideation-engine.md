# RFC 0009 — `/uberthink` Cross-Domain Ideation Engine

> Status: DRAFT · Date: 2026-05-26 · Author: TheFJK
> Spec: [`docs/uberdev/specs/2026-05-26-uberthink-design.md`](../uberdev/specs/2026-05-26-uberthink-design.md)

| Field          | Value                                                                              |
| -------------- | ---------------------------------------------------------------------------------- |
| **Status**     | Draft                                                                              |
| **Author**     | TheFJK                                                                             |
| **Created**    | 2026-05-26                                                                         |
| **Target**     | new `commands/uberthink.md`, new `skills/uberthink-pipeline/`, 6 new `agents/uberthink-*.md`, `agents/findings-to-issues.md` (allow-list extension) |
| **Supersedes** | —                                                                                  |
| **Tier**       | Medium (multi-agent, multi-file, contract-affecting; introduces a new command family) |
| **Target ver** | 0.34.0 (minor — new user-facing feature; current `main` is 0.33.18)                |

## 1. Context

A senior solo developer working across software engineering, game development, IT/systems, and applied mathematics regularly needs more than a single language-model "think harder" can produce: genuinely novel technical approaches that fuse the best mechanisms from disparate sub-fields. One-shot brainstorming — including `/uberdev:brainstorm` in its current form — is bounded by a single agent's prior, a single context window, and a single pass of self-critique. It is fast and good at *the obvious next idea*. It is structurally weak on three axes the user actually cares about:

- **Cross-domain transfer.** A single agent regresses to the dominant domain in its training mix and over-indexes on adjacent ideas (web → React, networking → QUIC). Forced distance — pulling, say, antigenic-variation from immunology or wave-function-collapse from gamedev procedural generation into an anti-censorship transport — requires deliberate scouting, not a single prompt.
- **Combination quality.** Truly novel designs are usually a fusion of two or three strong mechanisms from different domains, glued by a non-obvious bridge. A single pass cannot evaluate the synergy of a fusion it has not yet constructed; it tends to pick *one* mechanism and elaborate.
- **Falsification before delivery.** A one-shot brainstorm presents ideas without subjecting them to physics, red-team, and pre-mortem attacks. Crackpot ideas reach the user; the user is forced to be the adversarial filter manually.

`/uberthink` is the read-only, always-deep fleet ideation engine that addresses all three. It is to *ideas* what `/uberscan` is to *audit*: same orchestration shape (thin command → fat directive-emitter pipeline → wave-based `Task()` fanout → file-state circuit breakers → universal artifact handles), different objective. Where `/uberscan` produces a backlog of findings, `/uberthink` produces a ranked dossier of approaches plus one filed `uberthink-idea` issue.

The catalog of donor domains is **biased toward the user's actual build domains** (Tiers 1–4: SWE/CS, gamedev, IT/systems, math) with **forced far-field wildcards** (Tier 5: biology, economics, physics, rotating exotic). Without forced distance the fleet degrades to adjacent obvious ideas; without bias to build domains the dossier becomes a generic interdisciplinary essay instead of a buildable technical plan.

## 2. Decision

Ship `/uberthink` as a new top-level command in the `uber*` family — read-only, always-deep, whole-fleet — with these properties:

- **Read-only invariant.** `allowed-tools` excludes `Edit`/`MultiEdit`; no agent in the chain can write application code. Output is a markdown dossier in `.uberdev/think/<RUN_ID>/report.md` plus, by default, one `uberthink-idea`-labelled GitHub issue per `--max-new` (default 3) for the top design(s).
- **Always-deep.** No tier knob; every run executes the full 7-wave fleet with default `--islands 2`. Sizing knobs are circuit-breaker ceilings (cost guards), not a quality dial. This is a deliberate user decision: when the user invokes `/uberthink`, they are paying for depth.
- **`--handoff` to `/brainstorm`.** Opt-in flag that, after dossier generation and issue filing, invokes `Skill(uberdev:brainstorm)` seeded with the #1 design's dossier section. This is the only chain — `/uberthink` itself never writes app code, never auto-implements, never auto-merges.
- **Anthropic + Co-Scientist + GA islands.** Orchestrator-worker spine wraps a Generate → Reflect → Rank → Evolve cycle, run as **parallel evolutionary islands** (default 2). Islands evolve in isolation through Waves 1–5, then cross-pollinate at Wave 6 before a single global ranking at Wave 7.
- **4-axis scoring + moonshot lane.** Novelty, Feasibility, Combination, Impact — each 0–10 from weighted sub-criteria. Hard feasibility floor (axis < 4 OR any sub-criterion = 0) cuts crackpot ideas first; survivors are ranked by AmbitionScore = N^1.0 × F^1.2 × C^1.3 × I^1.2 (product form tanks one-axis weakness). A **dedicated moonshot Pareto frontier on (Novelty, Impact) only** guarantees high-ambition designs surface even when their feasibility is merely adequate.

The orchestration shape is the proven `/uberscan` / `/testers` template: pipeline `SKILL.md` bash is a **directive-emitter** that returns in milliseconds, writing dispatch directives and `DISPATCH:` sentinels. The orchestrating session fires each wave's `Task()` calls — across all islands — in a single assistant message. State lives in files (`run-state.txt`, per-island `shortlist.yaml`, per-wave dirs); the orchestrator reads only universal handles (status + `artifact_path` + `artifact_sha` + ≤200-word `summary` + `risks` + `next_phase_recommendation`), never raw artifact bodies.

> **SUPERSEDED (RFC 0012 §3.7, Phase 3).** The directive-emitter substrate described in this paragraph has been replaced by an on-disk Workflow script — see §11 below. Everything else in this RFC (the island topology, the genetic loop, the 4-axis scoring, the moonshot lane, the donor catalog, the safety posture) is unchanged and still authoritative.

## 3. Topology (island model)

Anthropic's multi-agent research system established that an orchestrator-worker topology with parallel Sonnet workers under an Opus lead beats single-agent on breadth by ~90% at ~15× tokens. DeepMind's AI Co-Scientist established that for *invention* (not search), a Generate → Reflect → Rank[Elo] → Evolve cycle outperforms a single deep pass. `/uberthink` composes both, then wraps the composition in the **GA island model** for population diversity.

```
                              Wave 0 (shared)
                                  Frame
                  schema | teardown | prior-art | constraints
                                    │
              ┌─────────────────────┴─────────────────────┐
              │                                           │
        Island 1 (independent)                      Island 2 (independent)
              │                                           │
   Wave 1 Generate (Field Scouts ×10–12 + TRIZ + morph + provocateur + bridge)
   Wave 2 Gap-gate (Co-STORM moderator → targeted re-dispatch on misses)
   Wave 3 Combine (weave / crossover / mutate)
   Wave 4 Converge (report.py Pareto → shortlist)
   Wave 5 Falsify (steelman / premortem / redteam / physics)
        │  └─ fixable kills → loop back to Wave 3, cap 3 (CB-LOOP)
        │  └─ fatal kills → cut permanently
              │                                           │
              └─────────────────────┬─────────────────────┘
                                    ▼
                       Wave 6 Cross-pollinate (global)
              crossover over union of island finalists only
                                    ▼
                            Wave 7 Rank & Deliver
                  Elo + 4-axis rubric + moonshot lane + novelty recheck
                          → ranked.yaml + report.md
                       → top-N → findings-to-issues
                       → if --handoff → /brainstorm seeded
```

Spec §2.1 establishes the topology; spec §2.2 enumerates the waves and per-wave personas/lenses.

**Why islands.** A single shared population would converge on the same local optimum: agents would discover each other's best mechanisms in Wave 3, splice them, and the population would collapse onto one lineage by Wave 5. Islands evolve in isolation through Waves 1–5 so genuinely different lineages compete; only their finalists meet at Wave 6, where crossover can splice the best building-blocks across populations. This is the standard GA island/deme technique and it is the structural diversity guarantee the moonshot lane (§5) relies on.

**Why directive-emitter, not in-process loop.** The pipeline `SKILL.md` bash is a thin directive-emitter that returns in milliseconds — it does not run agents inline. Each wave's bash reads prior artifacts, injects persona/lens/domain text from `personas.yaml` into dispatch directives, and prints `DISPATCH:` sentinels with a single-message instruction. The orchestrating session fires all `Task()` calls for that wave — across all islands — in one assistant message. Then the next wave's bash reads returned artifact handles. This matches `/uberscan` and `/testers`; the alternative (an in-process loop) would not parallelize across islands and would balloon wall-clock by an order of magnitude.

**Wave-by-wave fanout shape** (per spec §2.2):

| Wave | Scope | Archetype × persona/lens | Output |
|---|---|---|---|
| 0 | shared | `uberthink-frame` × {schema, teardown, prior-art, constraints} | `frame.md` + `scope-verdict.yaml` |
| 1 | per island | `uberthink-generator` × {Field Scouts ×10–12, triz, morphological, provocateur, bridge} | `island-K/candidates/*.yaml` (~40–80 mechanisms) |
| 2 | per island | `uberthink-moderator` (Co-STORM gap-gate) → targeted `uberthink-generator` re-dispatch | `island-K/gaps.yaml` + `candidates/gap-*.yaml` |
| 3 | per island | `uberthink-synthesizer` × {weave, crossover, mutate} | `island-K/composites/*.yaml` |
| 4 | per island | deterministic `report.py` (Pareto shortlist) | `island-K/shortlist.yaml` (~5–7) |
| 5 | per island | `uberthink-falsifier` × {steelman, premortem, redteam, physics} per design | `island-K/falsify/*.yaml`; fixable kills → loop back to Wave 3 |
| 6 | global | `uberthink-synthesizer` × crossover on union of island finalists | `composites/global-*.yaml` |
| 7 | global | `uberthink-arbiter` (Elo + 4-axis rubric + moonshot + novelty recheck) | `ranked.yaml` + `report.md` → `findings-to-issues` |

**Model assignment** (spec §2.5). The orchestrator-worker economics put ~80% of performance variance in the *lead* — so the pipeline `SKILL.md`, the synthesizer (highest-leverage reasoning), and the arbiter (final ranking judgment + novelty recheck) all run `opus`. The breadth fleet (generator, moderator, falsifier, frame) runs `sonnet`. This mirrors Anthropic's own production economics: upgrade the lead, parallelize the workers cheaply.

## 4. Genetic loop

The single most important behavior separating `/uberthink` from a one-shot brainstorm is the **fixable-kill loop-back**. After Wave 5 (Falsify), each composite carries a falsification dossier with per-feasibility-sub-criterion scores 0–10 and a `fatal: true | false` flag on every kill-cause.

- **Fatal kills cut permanently.** A physics-law violation, a trivially broken adversary attack, or a sub-criterion at 0 ends the lineage. Nothing compensates (this is the crackpot guard; see §5).
- **Fixable kills re-enter Wave 3 (Combine).** The composite is re-dispatched as input to a fresh crossover/mutate pass, with the falsifier's fix-suggestion injected as context. The synthesizer can splice in a building-block from another shortlist member to repair the flaw.
- **Cap: 3 loop-backs per island (CB-LOOP).** Bounded by a per-island counter in `run-state.txt`. Beyond 3, evolving stops and survivors carry to Wave 6 as-is. This is what converges ambitious-but-flawed ideas toward feasible-but-still-ambitious ones, instead of discarding them on the first failed attack.

**What this buys over one-shot.** A single deep pass surfaces ideas with their flaws still attached; the user filters manually. `/uberthink`'s loop *repairs* the most repairable ambitious ideas while killing the unrepairable ones — at the cost of K × 15× token spend. The output is a smaller, denser dossier of designs that have already survived three rounds of adversarial repair. The trade-off (cost for quality) is explicit and is consistent with the project rule "quality always wins over speed."

**Island bookkeeping.** Loop counters are keyed by island index in `run-state.txt` (`island-1.loop_count`, `island-2.loop_count`). A global counter would let one runaway island starve the others (spec §11). Per-island shortlist files (`island-K/shortlist.yaml`) keep the populations isolated through Wave 5.

**Falsifier output contract.** Each falsifier lens, applied to one composite, emits `island-K/falsify/comp-NNN-<lens>.yaml` containing: (1) the attack dossier (steelman → attack steps → outcome), (2) per-feasibility-sub-criterion scores 0–10 (hard_constraint, survives_adversary, buildability, premortem_resilience, deployment_reality), (3) each kill-cause tagged `fatal: true | false`, and (4) for fixable kills, a one-paragraph fix-suggestion injected into the loop-back's Wave-3 input. The synthesizer is therefore not blindly retrying — it has a specific repair target each time.

**Genetic loop vs naïve filtering.** Co-Scientist showed empirically that an Evolve step that *modifies* candidates outperforms a Generate + Rank step that merely filters them, because the iterative critic-driven repair surfaces designs the original generation could not produce. `/uberthink` extends that with island isolation so the repairs happen in parallel under independent priors. The combination produces denser, more thoroughly-attacked output than a one-shot brainstorm or even a single-island Co-Scientist cycle.

## 5. 4-axis scoring + moonshot lane 🌙

Four axes, each 0–10, produced by the falsifier fleet and the Arbiter and aggregated deterministically in `report.py`. Spec §3 is the contract; `tests/uberthink-report.test.sh` is the binding.

- **Axis 1 — Novelty:** prior-art distance (30%, Librarian-grounded), cross-domain reach (25%, Bridge-verified), non-obviousness of combination (25%), mechanism originality vs. mere reshuffle (20%).
- **Axis 2 — Feasibility:** hard-constraint compliance (30%, Physicist), survives the Adversary (25%, red-team), buildability (20%), pre-mortem resilience (15%), deployment/adoption reality (10%).
- **Axis 3 — Combination quality:** cross-consistency / homology (40%), synergy/emergence (35%, 1+1=3), coverage of best techniques (25%).
- **Axis 4 — Impact:** transformative potential if it works (40%), generality beyond this one problem (30%), defensibility/durability of the advantage (30%).

**Ranking function (deterministic, opinionated).**

1. **Hard feasibility floor (crackpot gate).** Any design with `Feasibility < 4` OR any single feasibility sub-criterion = 0 is **CUT**. One fatal flaw kills it; nothing compensates. Impact and Novelty cannot buy past the floor — this is the structural guard that keeps "ambitious" from becoming "crackpot."
2. **Above the floor.** `AmbitionScore = Novelty^1.0 × Feasibility^1.2 × Combination^1.3 × Impact^1.2`. Product form: a near-zero on any axis tanks the score. Exponents put **feasibility highest** (the guard), **combination next** (the synthesis objective), **impact next** (the ambition objective), novelty lowest among the four (novelty alone has buy-in-the-floor leverage already in the cut step, so the product weighs the post-floor signals harder). Tunable constants in `report.py`.
3. **Moonshot lane.** Among floor-survivors, compute a **second Pareto frontier on (Novelty, Impact) only**. The non-dominated set is the "moonshots," ranked by Novelty×Impact, and **surfaced first in the dossier** (`report.md` puts the Moonshot lane section before the AmbitionScore ranking). This is the structural guarantee that deliberately wild, high-impact, merely-adequate-feasibility designs are *always* presented — they cannot be buried by safer ideas that happen to score better on a multiplicative four-term product.
4. **4-axis Pareto overlay.** The full 4-axis non-dominated frontier is also presented alongside the scalar ranking, so the user can see which AmbitionScore-leaders are also Pareto-optimal.
5. **Elo tiebreak.** Top ~5 by AmbitionScore enter the Arbiter's pairwise debate. Elo order is the delivered order, rubric scores attached as audit trail. LLMs compare better than they calibrate, so the pairwise order is the trustworthy signal at the top of the ranking.

`report.py` is the only algorithmic code in the feature and is fully TDD'd (six asserts in `tests/uberthink-report.test.sh`, covering axis aggregation, the floor cut on both axis-<4 and any-sub=0 forms, the 4-term product tank, the 4-axis Pareto, the moonshot Pareto, and the rank() cut+sort).

**Why a separate moonshot lane, instead of just trusting AmbitionScore.** The product form `N × F^1.2 × C^1.3 × I^1.2` is multiplicative, so a design with Feasibility = 5.0 (just clears the floor) and Novelty/Impact = 10/10 can still lose to a design with Feasibility = 8.0 and Novelty/Impact = 7/7 — even though the first design is the more interesting moonshot. The moonshot Pareto frontier on (Novelty, Impact) only fixes this: the high-novelty/high-impact/adequate-feasibility design is *non-dominated* on those two axes, so it appears in the moonshot section regardless of where it lands in the scalar AmbitionScore ranking. Presenting the moonshot section *first* in `report.md` makes this lane structurally visible — the user sees the wild ideas before the safer top-of-scalar-ranking designs.

**Why the floor is hard, not soft.** A "soft floor" (penalize feasibility below 4 but allow it to be bought past by extreme novelty/impact) was considered and rejected. The whole point of the feasibility axis is to *cut crackpot ideas before they reach the user*; making it bought-past would re-introduce them. Compounding error: a one-shot brainstorm wastes the user's time evaluating crackpots; `/uberthink` wastes the user's compute too. The hard floor is the structural guarantee the cost premium buys.

## 6. Tech-centered donor catalog

The Cartographer (`uberthink-frame` × `schema` lens) abstracts the goal into a domain-neutral functional schema (Structure-Mapping Theory: relations, not surface features), then selects ~10–12 donor domains from the catalog. Selection is **biased toward Tiers 1–4** (the user's build domains) but **always includes ≥2 Tier-5 wildcards** for forced distance. Spec §2.3.

- **Tier 1 — Software engineering & CS theory:** distributed systems (consensus, CRDTs, gossip, sharding), compilers/PL (type systems, IR passes, JIT, DSLs), databases (query planning, MVCC, LSM, WAL), operating systems (scheduling, COW, capabilities), networking protocols (congestion control, QUIC, multipath, NAT traversal, overlays), security/crypto (zero-knowledge, indistinguishability, obfuscation, side-channels), concurrency (lock-free, actor model, STM, work-stealing), compression/coding (entropy coding, erasure codes, dedup, delta).
- **Tier 2 — Game development:** engine architecture (ECS, data-oriented design, hot-reload), netcode (rollback, lockstep, client prediction, lag compensation), procedural generation (noise, wave-function-collapse, L-systems), real-time rendering (LOD, culling, temporal reprojection), game physics (broadphase, constraint solvers, determinism), game AI (pathfinding, behavior trees, GOAP, influence maps), anti-cheat/integrity (server authority, deterministic replay), systems/economy design.
- **Tier 3 — IT / systems / infrastructure:** cloud/distributed infra, virtualization/containers, observability (tracing, metrics, eBPF), caching hierarchies, queueing/backpressure, fault tolerance (circuit breakers, bulkheads), edge/CDN, identity/authz.
- **Tier 4 — Mathematics:** graph theory (flows, matchings, spectral, expanders), information theory (entropy, channel capacity, Kolmogorov complexity), optimization (convex, combinatorial, metaheuristics, duality), probability/statistics (Bayesian, MCMC, randomized algorithms), number theory/algebra (lattices, finite fields, groups), category/type theory (functors, monads, dependent types), control theory/dynamical systems, combinatorics/discrete math (designs, codes, generating functions).
- **Tier 5 — Far-field wildcards (≥2 per run):** biology (evolution, immune systems, swarms, antigenic variation), economics/markets (mechanism design, auctions, signaling), physics (spread-spectrum, statistical mechanics, phase transitions), + 1 rotating exotic (linguistics, music/acoustics, epidemiology, logistics…).

Field Scouts each answer one question: *"In MY domain, what mechanism solves the Cartographer's abstract schema?"* The Bridge persona forces ≥2 maximally-distant Tier-5 imports and does the translation labor. Without the Bridge, Tier-5 imports tend to be name-drops; with it, they are concrete mechanism transfers ("immune-system antigenic-variation → rolling-key obfuscation that mutates a protocol's wire footprint per session").

**SSOT discipline.** `personas.yaml` is the single source of truth for the catalog and persona library. Agents never read it directly; the pipeline injects each persona's `prompt` text into the dispatch directive at wave start. This avoids drift: agents and pipeline cannot disagree on persona text because there is only one place it lives (spec §11).

**Why these five tiers, not more or fewer.** Earlier design iterations considered a flat catalog (no tiers) and an eight-tier catalog (separate tiers for theoretical CS, applied CS, systems, mathematics, physics, biology, economics, exotic). Both were rejected:

- **Flat catalog** has no mechanism to enforce build-domain bias. The Cartographer would treat astrophysics and distributed systems as equal-weight selections; in practice the model regresses to the most-trained-on domain regardless of relevance. The tier weighting in the Cartographer's prompt is what produces the build-domain bias the user actually wants.
- **Eight-tier catalog** is too granular for ~10–12 selections per run. The Bridge cannot meaningfully force "max distance" across eight tiers — the selection becomes one-of-each-tier rather than a deliberate diversity pick.

Five tiers gives the Cartographer a clean two-axis selection (tier index × catalog entry), the Bridge a clear "max-distance = Tier 5" target, and the user a legible explanation in the dossier ("the donor domains for this run were: 3× Tier 1 [SWE], 2× Tier 2 [gamedev], 3× Tier 4 [math], 2× Tier 5 [biology + physics]"). The exact catalog entries inside each tier are extensible (`personas.yaml` is text; new entries can be appended) without changing the tier structure.

## 7. Safety / dual-use posture

`/uberthink` runs adversarial ideation across security-relevant domains (security/crypto in Tier 1, anti-cheat in Tier 2, mechanism design in Tier 5). The canonical test goal — *"Design a novel, hard-to-fingerprint anti-censorship transport protocol"* — is legitimate freedom-of-information research (Tor pluggable-transport / obfs4 / Shadowsocks lineage), but the same machinery could be asked to design something harmful.

The safety posture is **a single lightweight Wave-0 gate, not a heavy approval checkpoint**, consistent with the project's no-hard-gates principle and the global `CLAUDE.md` security rules.

1. **Wave-0 scope gate.** The `uberthink-frame` schema lens emits `scope-verdict.yaml` with `verdict: PROCEED | REFUSE` plus rationale. `REFUSE` is reserved for goals whose **primary purpose** is unambiguous harm with no legitimate framing (ransomware-for-extortion, mass-targeting, DoS-as-a-service). The vast majority of dual-use research goals — anti-censorship, defensive security research, CTF, red-team exercises, academic exploration — **PROCEED**. On `REFUSE` the pipeline halts before any fanout and writes a short refusal report to `report.md`.
2. **The Adversary falsifier as safety lens.** The `redteam` lens in Wave 5 doubles as a safety analyzer: each composite's feasibility dossier includes a misuse-potential note (who could weaponize this, against whom, at what cost). This is part of the normal feasibility scoring — the Adversary is the same role whether the goal is offensive or defensive.

The gate is intentionally permissive on framing. Security research, censorship-circumvention research, and adversarial testing all require thinking like an attacker; refusing to ideate on attack vectors would refuse the legitimate research case along with the harmful one. The project's global rule — "never implement an insecure pattern" — applies at *implementation* time (`/dev`, `/solve`, `/turbo`). `/uberthink` is an ideation engine; it produces a dossier, not code.

### Output dossier shape

`report.md` is rendered deterministically by `report.py` from `ranked.yaml` + `frame.md`. The order is **intentional** — moonshots first, then scalar ranking, then culled-ideas appendix — so the user sees the wild ideas before the safer top of the ranking, and sees *what was killed and why* in the appendix as audit trail.

```
# /uberthink — <goal>           Run <RUN_ID> · islands=<K> · loop-backs=<n>
## Problem frame (locked)
  Schema · Inherited assumptions vs laws · Prior-art baseline · Constraint fence · Donor domains selected
## Moonshot lane (Novelty×Impact frontier)        ← surfaced FIRST in dossier
  Each moonshot: title · why it's audacious · Novelty/Impact · the one feasibility risk that gates it
## Ranked approaches (by AmbitionScore)
  Each (Elo order): title · AmbitionScore · Pareto · Moonshot? · one-line pitch
    Donor domains (tier-tagged) · mechanism · how it combines · 4-axis scores + sub-criteria
    Kill-causes & mitigations · First experiment to validate it
    Next step → /uberdev:brainstorm (auto if --handoff)
## Culled ideas (appendix)
  Each killed idea: died at Wave N, island K, because <which feasibility sub-criterion hit 0>
## Run metadata
  Agents dispatched · per-island loop-backs · circuit breakers tripped · partial?
```

Top `--max-new` ideas (default 3) are filed via `findings-to-issues` with `finding_label=uberthink-idea`, `finding_marker_slug=uberthink`, `source_ref=/uberthink run $RUN_ID`. The accepted-source allow-list in `findings-to-issues` gains `uberthink-aggregate` (one-line addition, mirroring the `ubersimplify-aggregate` extension in RFC 0008 §5.3). Label description ≤100 chars per the GitHub 422 guard.

## 8. Alternatives considered

### A — Extend `/uberdev:brainstorm` instead of a new command

Add a `--deep` flag to the existing brainstorm command that triggers a fleet under the hood. The brainstorm skill is the existing "design before implementing" entry point; adding fleet capability there would avoid a new top-level command and naturally chain into the rest of the writer-subagent pipeline.

**Rejected.** Three problems:
- **Scope mismatch.** `/brainstorm` is a *requirements + design* exploration phase for a *known direction*. `/uberthink` is *invention* — picking a direction in the first place. Conflating them would make `/brainstorm` either too heavy for its current users (every design discussion would inherit always-deep cost) or too shallow when invention is the actual need (a `--deep` flag is a quality dial; spec §1.2 explicitly rejects tiering).
- **Read-only invariant.** `/brainstorm` is part of the writer-subagent pipeline and the brainstorm output is implicitly trusted by downstream phases. Bolting a 15×-cost adversarial fleet inside that flow would either change the trust model (problematic) or run the fleet but discard most of it (wasteful).
- **`--handoff` direction is wrong.** The intended composition is `/uberthink → /brainstorm` (invent, then design the winner), not `/brainstorm → /uberthink → /brainstorm`. A separate command makes the handoff direction explicit; an in-place flag would obscure it.

### B — Single-model "deep think" agent

Build one Opus agent with an extended thinking budget and a long, structured prompt instructing it to brainstorm, cross-domain transfer, combine, falsify, and rank. No fleet, no waves, no islands. Modern long-context models are good at multi-step internal reasoning; perhaps the fleet is overkill.

**Rejected.** Three problems:
- **No structural diversity.** A single agent regresses to its prior. Even with a strong "diversify across domains" instruction, the same model produces the same correlated set of ideas; we measured this informally during the design phase — adjacent-domain suggestions dominate, far-field imports are name-drops without mechanism transfer.
- **No structural falsification.** Self-critique by a single agent is bounded by the agent's blind spots. A separate Adversary, Physicist, and pre-mortem agent — with their own context and their own prior — catch failure modes the generator does not.
- **No genetic loop.** Single-pass output cannot benefit from the fixable-kill loop-back. The most valuable behavior in `/uberthink` — *repairing* ambitious-but-flawed ideas rather than discarding them — is not expressible in one pass; it requires inter-agent state and a controlled feedback cycle.

In short: thinking depth in one agent maxes out at the prior; thinking *breadth + structural falsification + repair* requires a fleet.

### C — Build the fleet (chosen)

Anthropic orchestrator-worker spine × Co-Scientist Generate/Reflect/Rank/Evolve cycle × GA islands, with the donor catalog and moonshot lane as the distinguishing design choices.

**Why C wins.** Diversity (forced-distance Tier-5 imports + isolated islands) plus falsification (four-lens adversaries + per-feasibility-sub-criterion floor) plus the genetic loop (repair-not-discard) plus the moonshot lane (Novelty×Impact Pareto) collectively produce a *qualitatively different* output from A or B: a ranked dossier where every survivor has cleared a crackpot gate, every survivor has been adversarially attacked, and ambitious ideas have been deliberately rescued from the death-by-AmbitionScore-product trap. The cost (§9) is the explicit price of that quality, paid only when the user invokes `/uberthink`.

### Side comparison

| Property | A: `/brainstorm --deep` | B: single deep-think agent | C: `/uberthink` (chosen) |
|---|---|---|---|
| Token cost | medium (~5×) | low (~2×) | **K × 15×** |
| Structural diversity | shared prior | shared prior | islands + forced Tier-5 distance |
| Cross-domain transfer | implicit | implicit | Cartographer + Bridge enforced |
| Adversarial filtering | self-critique | self-critique | 4-lens falsifier fleet |
| Genetic repair | none | none | loop-back (cap 3) on fixable kills |
| Moonshot guarantee | none | none | Novelty×Impact Pareto lane |
| Output trust | mixed (crackpots reach user) | mixed | every survivor cleared the floor |

A trades quality for shape compatibility; B trades quality for cost. Both leave the user as the final adversarial filter. C inverts that: the user is the *consumer* of an already-filtered dossier, not the filter itself.

## 9. Cost note

`/uberthink` is **K × 15× a normal chat in token spend**, where K = `--islands` (default 2). This decomposes as:

- ~15× from the Anthropic orchestrator-worker pattern itself (the baseline cost of fleet vs single agent for breadth).
- × K from running the breadth fleet on each island independently through Waves 1–5.
- + the global Wave-6 cross-pollination and Wave-7 ranking (cheap relative to the per-island fleet — one synthesizer dispatch and one arbiter dispatch).

This is acceptable for three reasons:

1. **Always-deep is a feature, not a default.** `/uberthink` is invoked deliberately, with eyes open. `commands/uberthink.md` carries a prominent cost warning so the user is never surprised. The command is not chained from any other `uber*` command; it is always user-initiated.
2. **Quality wins over speed.** Per the project's global rule, we absorb wall-clock and token cost in exchange for designs that have survived three rounds of adversarial repair across diverse populations. A user invoking `/uberthink` is paying for the inventiveness premium.
3. **Hard ceilings exist.** Two circuit breakers cap the cost regardless of run shape:
   - **CB-ISLAND** — `MAX_AGENTS` ceiling for the whole run, scaled with islands. Default sized for `--islands 2`; halts fanout if dispatched agents exceed the cap. Spec §4.
   - **CB-CLOCK** — overall wall-clock budget. On trip, the deliver phase emits a partial report rather than running indefinitely.

The remaining four circuit breakers (CB-LOOP cap 3, CB-WAVE per-wave timeout, CB-FLOOD candidate flood per island, CB-CONVERGE non-convergence) bound per-wave behavior. All six write `CIRCUIT_BREAKER_HALT=<ID>` to `run-state.txt`, and the deliver phase reconstructs halt state by reading the file — the file is SSOT, the in-process bash variables are not (pattern lifted from `/uberscan`; the pipeline `SKILL.md` bash returns in ms, so in-process state is dead between waves).

**Full circuit-breaker matrix:**

| ID | Guard | Default trip | Action on trip |
|---|---|---|---|
| CB-LOOP | Genetic loop-backs (per island) | island loop counter > 3 | Stop evolving that island; carry survivors to Wave 6 |
| CB-WAVE | Per-wave timeout | previous wave elapsed > N min | Halt, emit partial `report.md` |
| CB-FLOOD | Candidate flood (per island) | candidates > 120 | Prune to top-N by prelim self-score before Wave 3 |
| CB-CLOCK | Overall wall-clock budget | cumulative > budget | Halt, emit partial `report.md` |
| CB-CONVERGE | Non-convergence | every island's frontier empty after CB-LOOP | Emit a partial report explaining *why nothing cleared the floor* (a useful negative result) |
| CB-ISLAND | Total fleet ceiling | dispatched agents > `MAX_AGENTS` | Halt fanout, proceed with what completed |

CB-CONVERGE is intentionally not a failure mode — when no island's frontier survives the floor across all loop-backs, the dossier reports *why* nothing cleared the floor (which feasibility sub-criterion repeatedly hit 0, which constraints were the consistent killers). This is itself a useful research result: it tells the user the goal as stated may be infeasible under the chosen constraint fence, and points at which constraint to relax for a productive re-run.

## 10. Open risks

Spec §11 enumerates implementation risks; the highlights:

- **Artifact path-leak in worktrees.** Earlier `uber*` work showed that research/audit agents writing to a relative `summary_dir` can land artifacts at the parent project root instead of the active worktree. Mitigation: all `summary_dir` values are anchored to the absolute `RUN_DIR` (including per-island subdirs) in dispatch prompts. Tested via shape grep in `tests/uberthink.test.sh`.
- **Single-message wave dispatch.** The orchestrating session MUST fire each wave's `Task()` calls — across all islands' Wave-N agents together — in one assistant message. Multi-message dispatch would serialize wall-clock by an order of magnitude and defeat the parallel island design. The pipeline `SKILL.md` states this invariant verbatim; the shape test asserts the invariant string is present.
- **Persona library drift.** `personas.yaml` is SSOT. Agents read persona text from the dispatch prompt (injected by the pipeline at wave start), **not** by re-reading the file. The shape test asserts agent files do not `Read` `personas.yaml`. This is the same SSOT pattern used in `/testers` for its persona library.
- **Island bookkeeping.** Per-island loop-back counters and per-island shortlist files must be keyed by island index in `run-state.txt` (`island-1.loop_count`, not a global `loop_count`). A global counter would let one runaway island starve the others by exhausting CB-LOOP before the other island reaches Wave 5 once. Pipeline phase-0 bash initializes per-island state; the shape test asserts the index keying.
- **Bashisms under zsh.** SKILL.md bash runs under `/bin/zsh` (the project rule: bash-only constructs misfire). `type -t fn` returns empty/rc1 under zsh — use `command -v`. `BASH_REMATCH[1]` is unset under zsh — use `$match`. Shape test greps `! grep -nE 'type -t|BASH_REMATCH'` to enforce.
- **Cost runaway despite breakers.** The two cost ceilings (CB-ISLAND, CB-CLOCK) are the only safeguards against a pathological run with both `--islands` high and many loop-backs. Defaults are sized for `--islands 2`; the command warns prominently and the user is expected to read the warning. Future work: a `--dry-run` mode that emits the dispatch plan without firing `Task()` calls, so cost can be previewed.
- **Cross-shell pipeline state.** Earlier `/uberdev:goal` work surfaced three traps for cross-shell run-state: helpers must re-EXPORT `UBERDEV_GOAL_ID` + `UBERDEV_TMPDIR` (gate on env var, not scalar); a fixed-path active-id bootstrap pointer is needed because keyed sidecars can't be found without the ID; per-fence `UBERDEV_TMPDIR` must be re-established because macOS splits paths across `/`, `/tmp`, `$TMPDIR`. `/uberthink` inherits the same pattern under `UBERDEV_THINK_ID` + `uberthink-active-id.txt`. Shape test covers all three.
- **Single failure within a wave.** If one island's Wave-N agent fails mid-fanout (model error, tool failure), the orchestrator records the failure in `run-state.txt` and proceeds with the surviving agents. A wave with no successful returns trips CB-WAVE. Single-agent loss within an island degrades that island's population for the wave but does not halt the run — the loop-back mechanism in subsequent waves can recover some of the lost coverage.

### Deferred enhancements

- **`--dry-run` cost preview.** Print the projected dispatch plan (number of agents, per-wave breakdown, expected token spend) and exit without firing `Task()` calls. Lets the user gut-check cost before committing.
- **Persona library hot-swap.** Allow per-run override of the donor catalog via `--catalog=<path>` for specialized problem domains (e.g., a pure-bio problem might want to invert the tier bias). Not in v1; users who need this can edit `personas.yaml` directly and rerun.
- **Auto-`--handoff` heuristic.** Detect "design …" or "invent …" prompts and suggest `--handoff` when the user has not specified. Not in v1 to keep the read-only invariant unambiguous (every `--handoff` is currently user-initiated).
- **Empty-`detail` auto-reject.** Mirror the `/uberscan` deferred enhancement: high-severity falsifier kill-causes with empty rationale could be auto-rejected as low-confidence. v1 surfaces them rather than silently dropping (same reasoning as `/uberscan`).

## 11. Amendment — Workflow migration (RFC 0012 §3.7, Phase 3)

The directive-emitter substrate in §2 has been replaced by an on-disk Workflow
script, `skills/uberthink-pipeline/workflow.js`. The pipeline `SKILL.md` is now a
thin preflight + args seam plus a retained `## No-Workflow fallback` recipe for
runtimes without the `Workflow` tool. **No wave semantics changed**: the island
topology (§3), the genetic loop (§4), the 4-axis scoring and moonshot lane (§5),
the donor catalog (§6) and the safety posture (§7) are carried over verbatim.

### Why it moved — three defects, one root cause

`run-state.txt` was *designed* as a key/value store (§3's "state lives in files")
and *implemented* as an append-only log. The write path and the read path
disagreed about which occurrence was authoritative, and everything downstream of
that disagreement was unsound:

1. **The fleet ceiling was inert.** All eight counter bumps used a first-match
   regex against the dispatched-agents key — forever the seeded `0` — while every
   reader took the last appended line. Simulated waves of 3+32+2+6 left the file
   as `0,3,32,2,6`: the reader saw `6`, the true total was `43`, and `MAX_AGENTS`
   (`200 × K`) was unreachable. **CB-ISLAND could not halt a runaway genetic
   loop.** The only test coverage was a grep that the literal string `CB-ISLAND`
   appeared in the SKILL — nothing exercised accumulation.
2. **Masked crashes were delivered as substance.** The Wave-4 Pareto cut and the
   Wave-7 floor-survivor cut ran as inline heredocs with stderr discarded and the
   exit status swallowed. A module-load failure wrote no shortlist, the falsifier
   count fell to 0, CB-CONVERGE fired, and after a ~90-minute run the deliver
   phase printed *"the goal as framed admitted no feasible novel approach"* —
   tooling breakage rendered as a substantive verdict.
3. **The Wave-5 file-set brief was missing.** Dispatch rows carried
   `island_index`/`lens`/`composite_id`/`composite_path`/`summary_dir`;
   `grep -n frame_dir` over the pipeline returned **zero** hits, while
   `agents/uberthink-falsifier.md` declares `frame_dir` mandatory and the
   `physics` lens must read `constraints.md` as its feasibility fence.

### What replaced them

- **One counter, one place.** `dispatched` is a JS variable spanning the run;
  every fanout passes through `guard(n, label)` which throws `CB-ISLAND` or
  `CB-BUDGET` *before* dispatching a wave it cannot afford. A `dispatchLedger`
  makes accumulation observable, and `tests/uberthink-workflow.test.sh` pins the
  worked example: waves of 3+32+2+6 must reach 43, and a ceiling of 44 must trip
  on the fourth wave.
- **Crash ≠ empty.** Both deterministic cuts are now first-class `report.py` CLI
  modes (`--emit shortlist`, `--emit floor-survivors`) that raise `ArtifactError`
  → exit 3 on a missing/unreadable input and exit 0 with an empty result when the
  frontier is honestly empty. A non-zero rc becomes a `TOOLING:` halt;
  `convergenceIsHonest()` gates the single site that can raise CB-CONVERGE, and
  the rank phase is skipped outright so no dossier can be assembled from
  artifacts that were never written.
- **The file set is script-derived.** `falsifyPrompt()` composes `frame_dir`, all
  four frame artifacts, `composite_path`, `summary_dir`, `working_dir`,
  `island_index` and the enveloped goal from constants — the omission is
  structurally impossible, and the fixture asserts it on *every* Wave-5 prompt.
- **Donors are returned, not scraped.** The `schema` lens returns its selected
  donor slugs via `StructuredOutput` instead of the pipeline regex-scraping them
  out of `frame.md` prose; each slug is validated to a closed character class
  before it reaches a prompt.
- **The lens diet is over.** `personas.yaml` prompts are multi-line block
  scalars. The old TSV sidecar flattened every prompt through
  `.replace(chr(10), " ")`, capping each lens at one line; the Workflow relay
  carries them as JSON strings with newlines intact.
- **`--resume RUN_ID`** rehydrates an existing run tree from a disk artifact scan
  and skips the waves that already produced artifacts.

### Deliberately preserved

- **The scope gate stays VERDICT-FIRST.** The `schema` lens is dispatched alone
  and its `PROCEED|REFUSE` verdict is read before any sibling agent exists. There
  is no pre-verdict parallel Wave 0 — that refusal path is shipped safety (§7),
  not an optimisation target. The stale artifact was the claim in
  `agents/uberthink-frame.md` that the pipeline "fans out all four in parallel";
  post-verdict, the three remaining lenses now fire in the same burst as Wave 1.
- **No `lib/uberthink-state.sh`.** RFC 0012 explicitly rejects re-implementing
  the run ledger in shell; the fix was to stop having a second representation of
  the counter at all.

### Retired breakers

`CB-WAVE` (>1800 s/wave) and `CB-CLOCK` (>5400 s total) are removed. They were
already dead in the directive-emitter era — the bash fence that "timed" a wave
returned in milliseconds, before that wave's `Task()` fanout had started — and
the Workflow runtime forbids wall-clock globals outright (RFC 0012 DR-7). The
runtime `budget` lifetime cap plus the now-live CB-ISLAND / CB-FLOOD / CB-LOOP
cover the real failure modes.

## Appendix: Shipping checklist

Per project `CLAUDE.md`, all of the following must land in the same PR or in the immediately-preceding `chore(release): v0.34.0` commit:

1. `plugins/uberdev/commands/uberthink.md` — thin entrypoint (flags + cost warning + `Skill(uberdev:uberthink-pipeline)` handoff).
2. `plugins/uberdev/skills/uberthink-pipeline/SKILL.md` — 7-wave island-aware directive-emitter, `model: opus`. *(Superseded by §11: now a thin preflight + args seam over `skills/uberthink-pipeline/workflow.js`, `model: inherit`, with a retained `## No-Workflow fallback`.)*
3. `plugins/uberdev/skills/uberthink-pipeline/personas.yaml` — 5-tier catalog + persona library (SSOT).
4. `plugins/uberdev/skills/uberthink-pipeline/report.py` — deterministic 4-axis scoring + dual Pareto + dossier render + f2i aggregate.
5. Six new agents: `uberthink-frame.md`, `uberthink-generator.md`, `uberthink-moderator.md`, `uberthink-synthesizer.md`, `uberthink-falsifier.md`, `uberthink-arbiter.md` (model assignments per spec §2.5).
6. `plugins/uberdev/agents/findings-to-issues.md` — add `uberthink-aggregate` to the accepted-source set.
7. Tests: `tests/uberthink.test.sh` + `tests/uberthink-report.test.sh` (both CI-listed in `.github/workflows/test.yml`). *(§11 adds `tests/uberthink-workflow.test.sh` — shape greps plus the T3 behavioral fixtures that lock the three defects; CI-listed on both the ubuntu and windows jobs since it needs only grep + node.)*
8. Alias surfaces (5): `lib/aliases-sync.sh`, `commands/install-aliases.md`, `commands/uninstall-aliases.md`, `README.md`, `tests/aliases.test.sh`.
9. Version bump to `0.34.0` in all 7 locations (plugin.json, marketplace.json, README badge, CHANGELOG, git tag, GH release, and the two test-locks in `tests/goal.test.sh` G20 + `tests/solve-claim.test.sh`).

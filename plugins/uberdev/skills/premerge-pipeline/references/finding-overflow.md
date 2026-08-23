# Premerge — when the finding envelope overflows

Reference for `skills/premerge-pipeline/SKILL.md`, Phase 5-file. `MAX_FINDINGS = 64` bounds one aggregate; this is what the run must say when more rows than that were candidates, and why the sentence it prints turns on `TOTAL=`, not on `OVERFLOW=`.

#### When the envelope overflows

## The bound

`MAX_FINDINGS = 64` bounds one aggregate. A long stack can exceed it honestly:
`defer` unions the cross-attempt suggestion set, adds every surviving blocker,
and adds every lens finding Phase 4b declined to apply, and eight attempts each
contributing new fingerprints add up.

`defer` used to **refuse** above the bound — exit 74, no aggregate, and a Phase 5
fence with no arm for it. So the one step whose entire purpose is *"a thing the
machine could not fix must outlive the run"* filed **nothing at all**, on exactly
the runs that had the most to say. That is the same surviving-findings loss the
`CONVERGE_VERIFY_CEILING` comment exists to prevent, arriving through a different
door.

What happens now:

- **Whole files while they fit, then one row-filled boundary file.** The unit is
  the owning file, because the filer opens one issue per file and half a file's
  findings make an issue that reads as complete and is not. Files carrying a
  blocker are admitted first, then the rest in first-appearance order. The first
  file that does not fit is **not** skipped, and admission does **not** stop dead
  there: the leftover budget is row-filled from that one file — blockers within
  it first — and only then does admission end. The cut is arithmetic rather than
  policy, so no lower-ranked file jumps it and exactly one file is ever split. A
  hard stop would file *fewer* rows than the row-level truncation this replaces:
  a 4-row file, two 30-row files and a 5-row blocker file, cut against a 64-row
  envelope, would file 39 rows where a row-level cut files 64. That is the same
  maximal-loss trade the refusal above was making, wearing a better argument. A
  single file
  larger than the whole envelope needs no special arm: it is this same rule with
  no whole file admitted ahead of it. Rows keep their existing relative order
  inside the envelope.
- **The aggregate is still written** and `PATH=` still names a real, dispatchable
  file. Overflow is never a refusal and never an exit code; it is a count on the
  line.
- **The count is reported, never swallowed.** Surface `OVERFLOW=<n>` in the run
  summary. Silently dropping is the defect; reporting is what makes the drop
  legitimate rather than a repeat of the thing being fixed.
- **`OVERFLOW=` counts two populations, and every sentence about it must name
  which one.** A row whose `file` is not a usable string can become no issue
  under any ranking, so `defer` drops it on **every** run rather than only an
  overflowing one — and counts it in `OVERFLOW=` so the drop is stated instead of
  hidden. `OVERFLOW > 0` therefore no longer implies the envelope was full, or
  even that it holds anything: a run whose only deferred row has a non-string
  `file` prints `TOTAL=0 BLOCKER=0 SUGGESTION=0 FILES=0 OVERFLOW=1`. `TOTAL=` on
  the same line is what separates the two, in both directions: the cap spends its
  whole budget when it cuts — the boundary file is row-filled to exactly
  `MAX_FINDINGS` — so a displaced row implies `TOTAL == 64`, and a `TOTAL` below
  that proves the cap displaced nothing and every dropped row is one the filer
  could open no issue for. So **no arm says *"did not fit the 64-row envelope"***,
  which is false on exactly the new drop path and false twice over: three valid
  suggestions plus four rows with no usable `file` print `TOTAL=3 BLOCKER=0
  SUGGESTION=3 FILES=3 OVERFLOW=4` — nowhere near 64, nothing displaced by it.
  Each arm reports *displaced by the cap or dropped as unfilable* on a full
  envelope and *dropped as unfilable*, with the row count, below one. An arm
  reasoning about what the envelope CONTAINS needs `TOTAL=` as its witness
  besides.
- **The overflow classes are reported differently, and none promises more than it
  can — the `CLASS=` token included.** `TOTAL == 64 && SUGGESTION == 0 &&
  OVERFLOW > 0` means the envelope was FILLED entirely by blockers; it keeps the
  severe `CLASS=blocker` sentence, and an operator must never be shown a milder one
  over that state. `TOTAL == 64` is the half that is easy to get wrong and must
  not be: `TOTAL = BLOCKER + SUGGESTION`, so `SUGGESTION == 0` proves every row
  *in* the envelope is a blocker — and nothing except `TOTAL == MAX_FINDINGS`
  proves the envelope was FULL, which is the other half of what that sentence
  asserts. Guard the arm on `SUGGESTION == 0` alone, or on `TOTAL > 0 &&
  SUGGESTION == 0`, and a run that never overflowed takes it: two blockers in
  `a.py` plus one suggestion whose `file` is a JSON object print `TOTAL=2
  BLOCKER=2 SUGGESTION=0 FILES=1 OVERFLOW=1`, where all three of the severe
  sentence's claims are false — 2 of 64 rows held, the dropped row a suggestion,
  no blocker dropped at all. Because `CLASS=`
  is the only parseable part of the line, a scraper records the alarm as real. An
  envelope that is not full witnesses nothing about the dropped rows, so it falls
  through to the arms that answer from the **candidate set** rather than from the
  envelope, and those stay correct at any `TOTAL`. What the mild arm may no longer say
  is *every blocker was kept*. Files are the unit now, and a blocker-bearing file
  carries its own cleanup rows into the envelope with it — so cleanup can survive
  while a blocker is dropped, and `SUGGESTION > 0` no longer witnesses anything
  about blockers. Run the shipped rule over one file holding 40 cleanup rows plus
  a blocker and one holding 30 blockers and it prints `TOTAL=64 BLOCKER=24
  SUGGESTION=40 FILES=2 OVERFLOW=7`: all seven dropped rows are blockers. So the
  token retired with the sentence. `CLASS=cleanup` is now printed only where it is
  provable — the run deferred without `--include-blockers`, so no blocker was ever
  a candidate and `BLOCKER=0` says so — and every other overflow reports
  `CLASS=unknown`. `BLOCKER=` on the defer line is the only field that answers
  "did every blocker fit", and that arm points at it rather than guessing; the
  defer line is printed immediately after it so *the line below* is literally the
  line below.

**The blocker rows are the new thing here, and they needed a producer, not a
louder promise.** `_encode_aggregate` used to pin every row to `suggestion`, so
the claim that surviving blockers were filed had nothing behind it — the same
no-producer defect Phase 4 shipped with. `agents/findings-to-issues.md` was
already ready for them: `severity_rank(blocker)=3` sorts a blocker above every
cleanup row, and since the cap moved to file groups the file holding it ranks at
`group_tier_rank(BLOCKER)=3` above every cleanup-only file — so a `max_new`
overflow can never displace it, and a blocker sharing a file with cleanup rows is
not dragged under the cap by them. Step 8d gives it the `@author`-mention shape.
Only the writer was missing.

A deferred blocker **halts** the parent run in that agent (RFC 0002). That is the
correct outcome and not a regression: the loop has already stopped not-green, so
the run is reporting a failure either way, and the halt makes it impossible to
report one as a success.

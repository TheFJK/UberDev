"""Triage rule-token vocabulary conformance + validator-drift guard.

`matched_rules` is the ONLY free-form list `lib/solve_triage.py` puts into the
routing context, and `lib/agent-dispatch.sh` validates every entry against a
closed `allowed_rule` alternation. The two are independent copies of one
contract: a rule token the producer emits but that validator refuses makes
`uberdev_agent_context_create` fail with `route_context_create_failed`, which
does not decline one issue — it aborts the ENTIRE batch, so every sibling issue
in the same /solve, /turbo or /ubergoal run dies with it. Same class as the
component-token bug (see tests/component-token-schema.py), one field over.

This guard closes that gap from the producer side: `TRIAGE_RULE_TOKENS` declares
the vocabulary and `assert_rule_tokens` refuses an undeclared token with a bare
`triage_rule_unknown` (exit 2). That does not spare the sibling issues — the
launcher aborts the batch on a classification error too — it makes the drift red
CI here, at the producer, before it can ship. The checks below pin
`declared ⊆ validator` (G2) unconditionally, `emitted ⊆ declared` (G4) over the
fixture corpus, and both `assert_rule_tokens` call sites wired (G7).

WHY NOT A `CONTRACT:` MARKER. The #371 register (tests/contract_markers.py)
compares copies that are the SAME TOKEN SET written in two languages. These two
are not: the validator writes the clamp rules as a FACTORED CROSS PRODUCT
(`(?:floor|ceiling|override):(?:trivial|small|medium)`), so a member extractor
reads six tokens off it where the producer declares nine, and a marker parked
there would report permanent false drift. Mutual containment is
the real relation, and it needs an executable comparator — this file.

Usage: python3 -I tests/triage-rule-vocabulary.py <solve_triage.py> <agent-dispatch.sh>
"""
import importlib.util
import json
import pathlib
import re
import sys

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures" / "solve-routing"
# 4 fixed + 9 clamp/override (floor|ceiling|override x 3 tiers) + 5
# medium-label (the design labels) + 2 escalation-label (small|medium;
# `trivial` is deliberately NOT an escalation target -- see the G3 canary list
# below, which pins that exclusion from the validator side).
#
# It was 26 until #619 collapsed the `large` rung into `medium`, which is a NET
# loss of six:
#   * GONE (6): `large:three-files` and `large:multi-component-high-risk`, whose
#     predicates the surviving arms already exclude, plus the four the tier
#     vocabulary derived -- floor:large, ceiling:large, override:large and
#     escalation-label:large.
#   * RENAMED, not deleted (6): the five `large-label:*` became `medium-label:*`
#     and `large:cross-cutting-refactor` became `medium:cross-cutting-refactor`.
#     Those six pin a FLOOR that nothing else in the classifier expresses, so
#     dropping them would under-price rather than collapse. Counting them out of
#     this floor is how the first cut of #619 shipped a two-rung downgrade with
#     the guard green -- the number is a ratchet, so it has to move for a real
#     deletion and stay put for a rename.
MIN_DECLARED_TOKENS = 20


def load(path):
    spec = importlib.util.spec_from_file_location("solve_triage_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    triage_path, dispatch_path = sys.argv[1:3]
    st = load(triage_path)
    failures = []

    declared = getattr(st, "TRIAGE_RULE_TOKENS", None)
    if declared is None:
        failures.append("solve_triage.TRIAGE_RULE_TOKENS is not defined — the "
                        "rule vocabulary is undeclared")
        declared = frozenset()

    # G1. Scrape the validator's literal BY THE VARIABLE NAME IT GUARDS, so a
    #     rename cannot silently make this guard vacuous. An unfound literal is
    #     a FAILURE, never a pass (the tests/component-token-schema.py rule).
    dispatch_src = pathlib.Path(dispatch_path).read_text(encoding="utf-8")
    found = re.findall(r'allowed_rule\s*=\s*re\.compile\(r"([^"]+)"\)', dispatch_src)
    validator = None
    if len(found) != 1:
        failures.append(f"expected exactly one allowed_rule literal in "
                        f"{pathlib.Path(dispatch_path).name}, found {len(found)} "
                        "(the drift guard is vacuous — re-point it)")
    else:
        try:
            validator = re.compile(found[0])
        except re.error as error:
            failures.append(f"scraped allowed_rule literal does not compile: {error}")

    # G2. Producer vocabulary is a SUBSET of what the validator accepts. This is
    #     the direction that prevents the batch-wide outage.
    if validator is not None:
        for token in sorted(declared):
            if not validator.fullmatch(token):
                failures.append(f"declared rule token {token!r} is REFUSED by "
                                "agent-dispatch.sh allowed_rule — emitting it "
                                "aborts the whole batch")

    # G3. The validator is not a catch-all. Without this, G2 would be satisfied
    #     by an `allowed_rule` of `.*` and certify nothing.
    if validator is not None:
        for canary in ("escalation-label:trivial", "escalation:medium", "floor:huge",
                       "escalation-label:", "..*.."):
            if validator.fullmatch(canary):
                failures.append(f"agent-dispatch.sh allowed_rule ACCEPTS {canary!r} — "
                                "it is permissive, so the subset check above proves nothing")

    # G4. Everything classify() actually emits is declared. The cross product of
    #     clamps and overrides is what reaches the floor:/ceiling:/override:
    #     emitters; the fixtures cover the tier rules.
    fixtures = sorted(FIXTURES.glob("*.json"))
    if not fixtures:
        failures.append(f"no snapshots under {FIXTURES} — the emitted-token check is vacuous")
    observed = set()
    # One report per distinct defect, keyed by the first combination that
    # witnessed it: the cross product below runs 125 combinations per fixture,
    # and a single missing declaration would otherwise bury the run in
    # hundreds of identical lines.
    undeclared = {}
    refused = {}
    # First combination that emits at least one token — G7 probe B re-runs this
    # exact call under a narrowed vocabulary, so it must be one classify() is
    # known to reach the guard with.
    witness_call = None
    tier_arguments = (None,) + tuple(st.TIERS)
    for fixture in fixtures:
        snapshot = json.loads(fixture.read_text(encoding="utf-8"))
        for floor in tier_arguments:
            for ceiling in tier_arguments:
                for override in tier_arguments:
                    witness = (f"{fixture.name}, floor={floor}, ceiling={ceiling}, "
                               f"override={override}")
                    try:
                        decision = st.classify(dict(snapshot), floor, ceiling, override)
                    except st.TriageError as error:
                        refused.setdefault((fixture.name, str(error)), witness)
                        continue
                    if witness_call is None and decision["matched_rules"]:
                        witness_call = (snapshot, floor, ceiling, override, witness)
                    for token in decision["matched_rules"]:
                        observed.add(token)
                        if token not in declared:
                            undeclared.setdefault(token, witness)
    for (_, code), witness in sorted(refused.items()):
        failures.append(f"classify({witness}) refused a legitimate snapshot: {code}")
    for token, witness in sorted(undeclared.items()):
        failures.append(f"classify({witness}) emitted {token!r}, which "
                        "TRIAGE_RULE_TOKENS does not declare")
    if fixtures and not observed:
        failures.append("no rule token was emitted by any fixture — the emitted-token "
                        "check is vacuous")

    # G5. The guard is fail-loud and carries the bare error code the launcher
    #     surfaces, and it does NOT refuse a legitimate vocabulary.
    assert_rule_tokens = getattr(st, "assert_rule_tokens", None)
    if assert_rule_tokens is None:
        failures.append("solve_triage.assert_rule_tokens is not defined — an undeclared "
                        "token reaches the context validator and aborts the batch")
    else:
        try:
            assert_rule_tokens(["bogus:rule"])
        except st.TriageError as error:
            if str(error) != "triage_rule_unknown":
                failures.append(f"assert_rule_tokens raised {str(error)!r}, "
                                "expected the bare code 'triage_rule_unknown'")
        except Exception as error:
            # Any other exception type is itself the defect: the launcher maps
            # TriageError to the bare code on stderr and exit 2, and nothing
            # else, so a different type reaches the caller as a traceback.
            failures.append(f"assert_rule_tokens raised {type(error).__name__}: {error}, "
                            "expected TriageError")
        else:
            failures.append("assert_rule_tokens(['bogus:rule']) did not raise")
        try:
            # A guard that raises on everything would satisfy the arm above
            # while refusing every real classification.
            assert_rule_tokens(sorted(declared))
        except Exception as error:
            failures.append(f"assert_rule_tokens refused its own declared vocabulary: "
                            f"{type(error).__name__}: {error}")

    # G6. Anti-vacuity floor on the declaration itself. A derivation that
    #     collapsed to an empty or near-empty set would make G2 and G4 trivially
    #     true while declaring nothing.
    if len(declared) < MIN_DECLARED_TOKENS:
        failures.append(f"TRIAGE_RULE_TOKENS declares {len(declared)} tokens, "
                        f"expected at least {MIN_DECLARED_TOKENS}")

    # G7. Both ENFORCEMENT POINTS are wired. G2/G4/G6 are statements about the
    #     data and G5 about the function in isolation, and all four hold
    #     identically whether or not anything calls the guard: delete both call
    #     sites, keep assert_rule_tokens, and every check above stays green while
    #     an undeclared token goes back to surfacing as an opaque
    #     route_context_create_failed. That is the tests/component-token-schema.py
    #     lesson one field over — check the property at the entry point that the
    #     launcher actually calls, never at one producer helper.
    #
    #     Probe A: finalize_decision reads matched_rules straight off the
    #     caller-supplied --decision JSON, so an undeclared token is reachable
    #     with ordinary arguments and no monkeypatching.
    finalize_decision = getattr(st, "finalize_decision", None)
    if finalize_decision is None:
        failures.append("solve_triage.finalize_decision is not defined — the "
                        "launcher's finalize entry point is gone")
    else:
        try:
            finalize_decision({"raw_tier": "small", "matched_rules": ["bogus:rule"]},
                              "small", None)
        except st.TriageError as error:
            if str(error) != "triage_rule_unknown":
                failures.append(f"finalize_decision(matched_rules=['bogus:rule']) raised "
                                f"{str(error)!r}, expected the bare code "
                                "'triage_rule_unknown'")
        except Exception as error:
            failures.append(f"finalize_decision(matched_rules=['bogus:rule']) raised "
                            f"{type(error).__name__}: {error}, expected TriageError")
        else:
            failures.append("finalize_decision(matched_rules=['bogus:rule']) returned a "
                            "decision — it does not call assert_rule_tokens, so an "
                            "undeclared token reaches the context validator and aborts "
                            "the batch")
        try:
            # A call site that raised unconditionally would satisfy the arm above
            # while refusing every real decision the launcher finalizes.
            finalize_decision({"raw_tier": "small",
                               "matched_rules": ["small:concrete-reproduction"]},
                              "medium", None)
        except Exception as error:
            failures.append(f"finalize_decision refused a legitimate decision: "
                            f"{type(error).__name__}: {error}")

    #     Probe B: no legitimate snapshot can make classify() emit an undeclared
    #     token, so narrow the vocabulary instead. assert_rule_tokens looks
    #     TRIAGE_RULE_TOKENS up as a module global at call time, so an empty set
    #     makes the emitting combination G4 witnessed above refuse — unless the
    #     call site is missing. Restored in `finally`: G2/G4/G6 read the same
    #     object off the module.
    if witness_call is not None:
        snapshot, floor, ceiling, override, witness = witness_call
        original_tokens = st.TRIAGE_RULE_TOKENS
        try:
            st.TRIAGE_RULE_TOKENS = frozenset()
            try:
                decision = st.classify(dict(snapshot), floor, ceiling, override)
            except st.TriageError as error:
                if str(error) != "triage_rule_unknown":
                    failures.append(f"classify({witness}) under an empty vocabulary raised "
                                    f"{str(error)!r}, expected the bare code "
                                    "'triage_rule_unknown'")
            except Exception as error:
                failures.append(f"classify({witness}) under an empty vocabulary raised "
                                f"{type(error).__name__}: {error}, expected TriageError")
            else:
                failures.append(f"classify({witness}) emitted "
                                f"{sorted(decision['matched_rules'])} under an EMPTY "
                                "vocabulary without raising — it does not call "
                                "assert_rule_tokens on the way out, so an undeclared "
                                "token reaches the context validator and aborts the batch")
        finally:
            st.TRIAGE_RULE_TOKENS = original_tokens

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

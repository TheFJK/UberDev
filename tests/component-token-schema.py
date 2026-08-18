"""Component-token conformance + regex-drift guard.

Regression guard for the class that made the ENTIRE backlog undispatchable.

`component_tokens()` used `rsplit(".", 1)`, so `foo.test.sh` produced the token
`foo.test`. `lib/agent-dispatch.sh`'s routing-context schema validates every
component against `[a-z0-9][a-z0-9_-]{0,127}`, which forbids the dot — so
`uberdev_agent_context_create` raised `route_context_create_failed` and /solve,
/turbo and /goal all REFUSED the issue outright: no PR, no retry, no dispatch.
Every open issue in this repo names a `*.test.sh`, so none of them could be
worked at all.

Usage: python3 component_token_check.py <solve_triage.py> <agent-dispatch.sh>
"""
import importlib.util
import re
import sys

# One literal for the anti-vacuity probe, used both as a hostile-body row and as
# the standalone "filtering did not empty a real body" check below — they are the
# same body by intent, and two copies is how they drift apart.
ORDINARY_BODY = "update tests/goal.test.sh and the run_manifest module"


def load(path):
    spec = importlib.util.spec_from_file_location("solve_triage_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    triage_path, dispatch_path = sys.argv[1:3]
    st = load(triage_path)
    failures = []

    # 1. Derived tokens for realistic names, including the exact shape that broke.
    cases = {
        "dispatch-codex.test.sh": ["dispatch-codex"],
        "tests/goal-pipeline-zsh.test.sh": ["tests"],
        "_workflow_harness.js": ["workflow_harness"],
        "x.d.ts": ["x"],
        "y.tar.gz": ["y"],
        "....sh": [],
    }
    for name, expected in cases.items():
        got = st.component_tokens([name])
        if got != expected:
            failures.append(f"component_tokens({name!r}) = {got!r}, expected {expected!r}")

    # 2. `foo.sh` and `foo.test.sh` are ONE component, not two — they are the
    #    same unit, and counting them twice inflates the multi-component tier rule.
    if st.component_tokens(["foo.sh", "foo.test.sh"]) != ["foo"]:
        failures.append("foo.sh + foo.test.sh must collapse to a single component")

    # 3. Property check at the FIELD level, via classify(), not at one producer.
    #    `components` has TWO producers unioned (component_tokens + named_modules)
    #    and `files` has its own. Property-checking a single producer certified a
    #    field that was still divergent: the earlier version of this test called
    #    st.component_tokens() and was structurally blind to named_modules().
    #    classify() is the only vantage point that sees every path into both fields.
    comp_shape = re.compile(r"[a-z0-9][a-z0-9_-]{0,127}")
    files_shape = re.compile(r"[a-z0-9_.][a-z0-9_./-]{0,255}")
    # Every path-bearing body here MARKS its path as a change target (#614):
    # `files` is the declared/marked change scope now, not every filename-shaped
    # token in the prose, so an unmarked path yields no token at all and the
    # schema-shape probe below would pass vacuously -- proving nothing about the
    # filter it exists to exercise.
    hostile_bodies = {
        "markdown code span with a leading dash": "patch `-foo.sh` for the repro",
        "pasted stack-trace path over the length cap": "fix the crash at " + ("a" * 300) + ".js:1",
        "non-ASCII filename surviving casefold": "rename the file \u0130ndex.js",
        "module word over the length cap": "the " + ("m" * 141) + " module is broken",
        "Turkish dotted capital in a module word": "the \u0130stanbul module is broken",
        "ordinary body": ORDINARY_BODY,
    }
    for label, body in hostile_bodies.items():
        snapshot = {"number": 1, "title": "t", "body": body, "labels": [], "state": "OPEN"}
        decision = st.classify(snapshot, None, None, None)
        for tok in decision.get("components", []):
            if not comp_shape.fullmatch(tok):
                failures.append(f"[{label}] component {tok!r} violates the context-schema shape")
        for tok in decision.get("files", []):
            if not files_shape.fullmatch(tok):
                failures.append(f"[{label}] file {tok!r} violates the context-schema shape")
    # The ordinary body must still yield signal — a filter that drops everything
    # would satisfy every assertion above while destroying triage.
    ordinary = st.classify({"number": 1, "title": "t", "body": ORDINARY_BODY,
                            "labels": [], "state": "OPEN"}, None, None, None)
    if not ordinary.get("files") or not ordinary.get("components"):
        failures.append("filtering emptied an ordinary body — the guard is over-broad, "
                        f"files={ordinary.get('files')!r} components={ordinary.get('components')!r}")

    # 4. DRIFT GUARD. The literal this module enforces must be byte-identical to
    #    the one the context schema enforces. Two independent copies of a single
    #    contract is exactly how this shipped — and how the `--backend` enum bug
    #    shipped before it. Whichever side is edited alone, dispatch breaks with
    #    no test to catch it.
    dispatch_src = open(dispatch_path, encoding="utf-8").read()
    # BOTH validated fields, not just components. Each literal is scraped from the
    # validator by the field name it guards, so a rename cannot silently make the
    # check vacuous — an unfound literal is a failure, never a pass.
    for field, producer_re in (("components", st.COMPONENT_TOKEN_RE),
                               ("files", st.FILES_TOKEN_RE)):
        found = re.findall(r'fullmatch\(r"([^"]+)",x\) for x in ' + field, dispatch_src)
        if not found:
            failures.append(f"could not locate the {field} regex in agent-dispatch.sh "
                            "(the drift guard is vacuous — re-point it)")
            continue
        if any(f != producer_re.pattern for f in found):
            failures.append(f"{field} regex drift: solve_triage={producer_re.pattern!r} "
                            f"agent-dispatch={found!r}")

    for f in failures:
        print(f"FAIL {f}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

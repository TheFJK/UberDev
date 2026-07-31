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

    # 3. Property check: EVERY emitted token conforms, not just the listed cases.
    sample = ["a/b.test.sh", "dispatch-codex.test.sh", "_h.js", "n.d.ts",
              "tests/x.test.py", ".hidden/y.sh", "z.min.js"]
    shape = re.compile(r"[a-z0-9][a-z0-9_-]{0,127}")
    for tok in st.component_tokens(sample):
        if not shape.fullmatch(tok):
            failures.append(f"emitted token {tok!r} violates the context-schema shape")

    # 4. DRIFT GUARD. The literal this module enforces must be byte-identical to
    #    the one the context schema enforces. Two independent copies of a single
    #    contract is exactly how this shipped — and how the `--backend` enum bug
    #    shipped before it. Whichever side is edited alone, dispatch breaks with
    #    no test to catch it.
    mine = st.COMPONENT_TOKEN_RE.pattern
    dispatch_src = open(dispatch_path, encoding="utf-8").read()
    found = re.findall(r'fullmatch\(r"(\[a-z0-9\]\[a-z0-9_-\]\{0,127\})",x\)', dispatch_src)
    if not found:
        failures.append("could not locate the component regex in agent-dispatch.sh "
                        "(the drift guard is vacuous — re-point it)")
    elif any(f != mine for f in found):
        failures.append(f"component regex drift: solve_triage={mine!r} agent-dispatch={found!r}")

    for f in failures:
        print(f"FAIL {f}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

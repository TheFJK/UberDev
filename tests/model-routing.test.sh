#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MODEL_ROUTING_TEST_ROOT="$ROOT"
export PYTHONDONTWRITEBYTECODE=1

# RETIRED SURFACE (#381) -- read this before adding anything back.
#
# This file used to be 843 lines and ~562 checks, and the overwhelming majority
# of them drove `resolve_route`, `fallback_route`, `validate_catalog` and the
# JSON CLI that fronted them. All four are deleted: they turned a logical route
# rank into a concrete provider model + reasoning effort, which is only
# enforceable on a backend that owns the provider invocation, and no shipped
# backend does any more. Keeping them would have meant shipping a routing engine
# no dispatch path can enter.
#
# LOST COVERAGE, named so it is not mistaken for coverage that still exists:
#   * concrete pair selection per route/alias/tier, and the `cli-route`,
#     `cli-exact`, `role-policy`, `task-policy`, `environment-route`,
#     `project-role`, `project-workflow` field-source provenance labels;
#   * `forced` / `forced-parent` route inheritance and `route_conflict`;
#   * `route_below_risk_floor`;
#   * shadow mode and its separate `adaptive_proposal`;
#   * `ignored_sources` / `ignored_fields` field-level precedence;
#   * sandbox selection from role/workflow override entries;
#   * catalog availability fallback, the `fallback_chain`, `invalid_fallback`
#     and every `incompatible_pair` / `invalid_catalog` diagnostic;
#   * CLI byte-determinism and PYTHONHASHSEED stability of the above.
# See RFC 0013 (2026-08-05 amendment).
#
# WHAT SURVIVES and is asserted below: the policy document itself (route ranks,
# aliases, lead-route matrix, the 44-role leaf inventory, the declared
# reasoning-effort vocabulary), its complete closed validator, and
# `classify_minimum_route` -- which is live, reached from lib/config-read.sh.

python3 - <<'PY'
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


@contextlib.contextmanager
def scratch_dir(prefix, parent=None):
    """Scratch tree whose TEARDOWN cannot decide this suite's verdict (#428).

    TemporaryDirectory.__exit__ re-raises every OSError but PermissionError and
    FileNotFoundError, so an unlink race reds a job whose diff never touched
    this file. Full rationale, tradeoff and the "no setup-python => no 3.10+
    ignore_cleanup_errors=" constraint: tests/code-fixer-contract.test.sh.

    This fence binds `Path`, not `pathlib`, so the factory must stay
    pathlib-free — it deals in the `str` mkdtemp returns, exactly as
    TemporaryDirectory did.
    """
    path = tempfile.mkdtemp(prefix=prefix, dir=parent)
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


ROOT = Path(os.environ["MODEL_ROUTING_TEST_ROOT"])
RESOLVER = ROOT / "plugins/uberdev/lib/model_routing.py"
POLICY_PATH = ROOT / "plugins/uberdev/policy/model-routing-v1.json"
FIXTURES = ROOT / "tests/fixtures/model-routing"

spec = importlib.util.spec_from_file_location("model_routing", RESOLVER)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load resolver: {RESOLVER}")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def expect_error(code, callable_):
    global checks
    try:
        callable_()
    except module.RouteError as error:
        if error.code != code:
            raise AssertionError(f"expected {code}, got {error.code}: {error.detail}")
        check(isinstance(error.detail, str) and bool(error.detail), f"{code} detail must be non-empty")
        checks += 1
        return error
    raise AssertionError(f"expected RouteError {code}")


def request(**overrides):
    base = {
        "workflow": "solve",
        "phase": "lead",
        "role": "lead",
        "task_tier": "small",
        "risk_signals": [],
    }
    base.update(overrides)
    return base


def classify(payload):
    return module.classify_minimum_route(policy, payload)


policy = module.load_policy(POLICY_PATH)

# The retired surface is genuinely gone, not merely unused.
for gone in ("resolve_route", "fallback_route", "validate_catalog", "main", "_build_parser"):
    check(not hasattr(module, gone), f"{gone} is still exported")
check(set(module.PUBLIC_API) == {"load_policy", "classify_minimum_route"}, "public API drifted")
check(module.ROUTE_ERROR_FIELDS == ("code", "detail"), "RouteError field contract drifted")
# Library-only: running the module as a script resolves nothing and prints nothing.
inert = subprocess.run(
    [sys.executable, str(RESOLVER), "resolve", "--policy", str(POLICY_PATH)],
    text=True, capture_output=True, check=False,
)
check(inert.returncode == 0 and not inert.stdout.strip(), f"module still behaves as a CLI: {inert.returncode} {inert.stdout!r}")

# Canonical route matrix, aliases, lead tiers, effort vocabulary.
# A route row is now a rank and nothing else -- the `codex` provider sub-object
# (model + reasoning_effort + service_tier) went with the resolver that read it.
expected_routes = {"economy": 0, "standard": 1, "quality": 2, "deep": 3, "frontier": 4, "ultra": 5}
check(set(policy["routes"]) == set(expected_routes), "canonical route names drifted")
for route, rank in expected_routes.items():
    row = policy["routes"][route]
    check(set(row) == {"rank"}, f"route row is not rank-only: {route}: {sorted(row)!r}")
    check(row["rank"] == rank, f"route rank drifted: {route}: {row['rank']!r}")
check(policy["aliases"] == {"luna": "economy", "terra": "standard", "sol": "quality", "sol-high": "deep", "sol-max": "frontier", "sol-ultra": "ultra"}, "alias set drifted")
check(policy["lead_routes"] == {
    "trivial": {"default": "standard", "high_risk": "deep"},
    "small": {"default": "standard", "high_risk": "deep"},
    "medium": {"default": "quality", "high_risk": "frontier"},
}, "lead route matrix drifted")
check(policy["fallback_order"] == ["ultra", "frontier", "deep", "quality", "standard", "economy"], "fallback order drifted")
# The reasoning-effort vocabulary lib/config-read.sh validates project configs
# against. It used to be scraped out of the per-route provider blocks; the token
# set is unchanged, only its source moved from derived to declared.
check(policy["reasoning_efforts"] == ["low", "medium", "high", "max", "ultra"], "declared reasoning-effort vocabulary drifted")

# Every canonical source agent has one complete leaf policy and no unknown policy exists.
source_roles = set()
for agent_path in sorted((ROOT / "plugins/uberdev/agents").glob("*.md")):
    role = None
    for line in agent_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("name: "):
            role = line.split(": ", 1)[1].strip()
            break
    source_roles.add(role or agent_path.stem)
check(len(source_roles) == 47, f"expected 47 canonical roles, got {len(source_roles)}")
check(set(policy["roles"]) == source_roles, "policy/source role inventory mismatch")
expected_route_groups = {
    "economy": {"triage-scout", "ci-failure-classifier", "merge-strategy-decider", "testers-monitor-primary", "testers-monitor-devils-advocate"},
    "standard": {"codebase-scout", "research-codebase", "research-constraints", "research-patterns", "research-prior-art", "research-test-coverage", "issue-similarity-analyzer", "comment-analyzer", "testers-a11y-critic", "testers-chaos-engineer", "testers-mobile-thumb", "testers-panicked-grandma", "testers-power-user"},
    "quality": {"code-simplifier", "implementation-worker", "spec-reviser", "uberthink-frame", "uberthink-generator", "uberthink-moderator"},
    "deep": {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "code-reviewer", "conflict-resolver", "convention-compliance", "design-planner", "finding-verifier", "findings-to-issues", "plan-reviewer", "plan-writer", "pr-test-analyzer", "research-security", "silent-failure-hunter", "spec-compliance-reviewer", "spec-reviewer", "spec-writer", "testers-adversarial-security", "type-design-analyzer", "uberthink-falsifier", "uberthink-synthesizer"},
    "frontier": {"trust-trail-evaluator", "uberthink-arbiter"},
}
workspace_write_roles = {"ci-code-fixer", "ci-rebase-handler", "code-fixer", "conflict-resolver", "design-planner", "implementation-worker", "plan-writer", "spec-reviser", "spec-writer"}
expected_floor = {"economy": "economy", "standard": "economy", "quality": "standard", "deep": "deep", "frontier": "deep"}
# The buckets must PARTITION the inventory, not merely sample it (#656). The
# loop below iterates expected_route_groups, so a role missing from every
# bucket is not a failure -- its route / floor / sandbox / leaf checks simply
# never run, and the suite stays green at a lower check count. That makes every
# per-role assertion opt-in, which is the same vacuous green as no assertion.
# `check` counts are not a backstop either: nothing pins the total.
routed_roles = set().union(*expected_route_groups.values())
check(sum(len(roles) for roles in expected_route_groups.values()) == len(routed_roles),
      "a role appears in more than one route bucket")
check(routed_roles == source_roles,
      "route buckets do not partition the role inventory: "
      f"unrouted={sorted(source_roles - routed_roles)!r} unknown={sorted(routed_roles - source_roles)!r}")
for route, roles in expected_route_groups.items():
    for role in roles:
        row = policy["roles"][role]
        check(row["route"] == route, f"wrong route for {role}")
        check(row["risk_floor"] == expected_floor[route], f"wrong floor for {role}")
        check(row["sandbox_ceiling"] == ("workspace-write" if role in workspace_write_roles else "read-only"), f"wrong sandbox for {role}")
        check(row["delegation_mode"] == "leaf", f"{role} must be leaf")
check(policy["delegation_contracts"]["leaf"] == {"features_multi_agent": False, "agents_max_depth": 0}, "leaf enforcement contract drifted")

# --- #749: sandbox_ceiling's first read-site whose subject is OUTSIDE the policy ---
# `sandbox_ceiling` was a dead contract. It is VALIDATED -- lib/model_routing.py
# enum-checks every row against _SELECTABLE_SANDBOXES -- and it is ASSERTED, by
# the loop above, against `workspace_write_roles`: a hardcoded twin of the same
# claim, transcribed into this file. Nothing projected it into a tool grant and
# nothing compared it with the agent cards. Two independent "read-only" claims
# existed -- the policy row and the card -- and neither reached the runtime nor
# checked the other. That is what let 31 of the 38 read-only-ceiling roles ship
# with every tool granted while this suite and
# tests/testers-agent-contract.test.sh both printed PASS.
#
# The block below reads policy[...]["sandbox_ceiling"] and compares it against
# plugins/uberdev/agents/*.md. Deriving read_only_roles from
# `workspace_write_roles` instead would reproduce the defect exactly: that set
# is the transcription, not the field.
#
# WHAT `tools:` ACTUALLY DOES, stated precisely -- a comment that claims a
# ceiling which does not exist is the same defect as a policy field that never
# reaches one. The key restricts which TOOL NAMES an agent may call. A
# parenthesised argument inside an entry is not matched against a filesystem
# path; `Write(<path>)` is not a file-permission rule (only `Edit(path)` is
# matched by those). So this block asserts that a role DECLARES a tools: list at
# all -- never that a pattern inside one bounds where the agent may write.
#
# What is asserted, and what deliberately is NOT:
#   * NOT: that every read-only role carries a `tools:` declaration. Writing one
#     for the rest is a per-agent judgement, not a mechanical sweep -- each agent
#     must still be able to call the tools it actually calls. The six Phase 1
#     review lenses write a result file /uberdev:review-pr validates from disk
#     (plugins/uberdev/shared/phase1-reviewer-output-v1.md), so any list written
#     for them has to include `Write`; one that omits it breaks Phase 1 for every
#     PR. #749 fixed the eight testers-* personas; the rest is the larger sweep
#     that issue defers, and the waiver below is its worklist.
#   * YES: no agent card may declare `allowed-tools:` AT ALL. On an agent that
#     key is inert. It stays correct under plugins/uberdev/commands/, which this
#     check does not look at.
#   * YES: every read-only role either declares `tools:` or is NAMED below. The
#     waiver is SHRINK-ONLY: a role that gains `tools:` while still listed is a
#     FAILURE, so the list cannot rot into a permanent exemption, and a NEW agent
#     shipped with no declaration reds instead of silently joining them.
FRONTMATTER_RE = re.compile(r"(?s)\A---\n(.*?)\n---\n")
# WHAT COUNTS AS A DECLARATION. This has to be the SAME answer declared_tools()
# gives in tests/testers-agent-contract.test.sh -- that function and this block
# ask one question of one set of cards, and the eight testers personas are inside
# both subjects.
#
# Bare key PRESENCE is not that answer. `tools:` with nothing after it and no
# block-sequence items is YAML null: the loader grants EVERY tool, exactly as if
# the key were absent. Keying on presence therefore made every row below vacuous
# on precisely the state #749 exists to red on -- measured on this tree by
# emptying the value on a live testers card, the role stayed in declares_tools,
# so the testers-subset row and the read-only projection row both still printed
# PASS while that agent held every tool. It is also the exact spelling a
# half-finished migration produces, which is what this stack IS.
#
# So a declaration is a `tools:` key with a NON-EMPTY value, in either YAML
# spelling of a list -- a same-line flow value, or the block-sequence item lines
# that follow an empty same-line value. ONLY `- item` lines are absorbed: an
# indented continuation of another key's folded scalar is not a tool declaration.
# Widening WHICH SPELLINGS count is not a relaxation; requiring the value be
# non-empty is the strictness the guard was always meant to have.
TOOLS_RE = re.compile(r"(?m)^tools:[ \t]*(.*(?:\n[ \t]*-[ \t]+\S.*)*)$")
declares_tools = set()
declares_allowed_tools = set()
for agent_path in sorted((ROOT / "plugins/uberdev/agents").glob("*.md")):
    matched = FRONTMATTER_RE.match(agent_path.read_text(encoding="utf-8"))
    check(matched is not None, f"{agent_path.name}: no --- frontmatter block")
    block = matched.group(1)
    named = re.search(r"(?m)^name:[ \t]*(\S+)", block)
    role = named.group(1).strip() if named else agent_path.stem
    declared = TOOLS_RE.search(block)
    if declared is not None and declared.group(1).strip():
        declares_tools.add(role)
    if re.search(r"(?m)^allowed-tools:", block):
        declares_allowed_tools.add(role)

check(not declares_allowed_tools,
      "agent cards declaring the inert slash-command key 'allowed-tools:' "
      f"(an agent card is read for 'tools:'): {sorted(declares_allowed_tools)!r}")

read_only_roles = {role for role, row in policy["roles"].items()
                   if row["sandbox_ceiling"] == "read-only"}
testers_roles = {role for role in read_only_roles if role.startswith("testers-")}
# Both counts are ANTI-VACUITY anchors for the subset assertions below, not
# release ratchets: `A <= B` is trivially true when A is empty, so an emptied
# read_only_roles or testers_roles would turn the real checks green by leaving
# them no subject. If one reds, re-derive the census -- do not just bump it.
check(len(read_only_roles) == 38,
      f"expected 38 read-only-ceiling roles in the policy, got {len(read_only_roles)} -- "
      "a role's sandbox_ceiling moved; re-derive the waiver below before changing this")
check(len(testers_roles) == 8, f"expected 8 testers-* read-only roles, got {len(testers_roles)}")

# The #749 worklist: a read-only ceiling in the policy that no `tools:`
# declaration mirrors. SHRINK-ONLY -- the stale-waiver row below is the ratchet.
# Deliberately NOT size-locked: deleting a name as an agent gains a tools: list
# is the intended success path, and a length assertion would red on it with a
# message that reads like a defect and force a two-place edit.
UNENFORCED_READ_ONLY_WAIVER = {
    "ci-failure-classifier", "code-reviewer", "code-simplifier", "comment-analyzer",
    "convention-compliance", "finding-verifier", "findings-to-issues",
    "merge-strategy-decider", "plan-reviewer", "pr-test-analyzer",
    "research-patterns", "research-prior-art", "silent-failure-hunter",
    "spec-compliance-reviewer", "spec-reviewer", "trust-trail-evaluator",
    "type-design-analyzer", "uberthink-arbiter", "uberthink-falsifier",
    "uberthink-frame", "uberthink-generator", "uberthink-moderator",
    "uberthink-synthesizer",
}
# ORDER MATTERS. `check` raises on the first failure, so a row placed after one
# that subsumes its trigger can never fire -- and a guard that cannot fail is the
# defect #749 is about. The testers-in-waiver row therefore comes FIRST: waiving
# a persona that still declares tools: would otherwise be swallowed by the
# stale-waiver row, and waiving one that does not would be swallowed by the
# testers-enforcement row, leaving this message permanently dead. Each of the
# five rows below owns a mutation no earlier row reaches.
check(not (testers_roles & UNENFORCED_READ_ONLY_WAIVER),
      "a testers-* persona was added to the #749 waiver, which re-opens the issue it closed: "
      f"{sorted(testers_roles & UNENFORCED_READ_ONLY_WAIVER)!r}")
check(UNENFORCED_READ_ONLY_WAIVER <= read_only_roles,
      "waiver names something that is not a read-only-ceiling role: "
      f"{sorted(UNENFORCED_READ_ONLY_WAIVER - read_only_roles)!r}")
stale_waiver = UNENFORCED_READ_ONLY_WAIVER & declares_tools
check(not stale_waiver,
      "waiver is STALE -- these roles now declare tools: and must be deleted from it: "
      f"{sorted(stale_waiver)!r}")
check(testers_roles <= declares_tools,
      "a testers-* persona lost its tools: declaration, which re-opens #749: "
      f"{sorted(testers_roles - declares_tools)!r}")
unprojected = read_only_roles - declares_tools - UNENFORCED_READ_ONLY_WAIVER
check(not unprojected,
      "a read-only sandbox_ceiling is neither mirrored by a tools: declaration nor waived "
      "(declare the tools: key, or name the role in UNENFORCED_READ_ONLY_WAIVER): "
      f"{sorted(unprojected)!r}")

# The policy schema is closed and JSON duplicate keys never silently win. These
# mutations used to enter through validate_catalog(policy, ...); load_policy /
# _validate_policy is the surviving entry point and validates the same document.
def reject(mutate, code="invalid_policy"):
    bad = copy.deepcopy(policy)
    mutate(bad)
    expect_error(code, lambda: module._validate_policy(bad))
    with scratch_dir("model-routing-") as temporary_directory:
        path = Path(temporary_directory) / "policy.json"
        path.write_text(json.dumps(bad), encoding="utf-8")
        expect_error(code, lambda: module.load_policy(path))


reject(lambda p: p.pop("policy_version"))
reject(lambda p: p.update(release_default_mode="automatic-ish"))
reject(lambda p: p.update(surprise=True))
reject(lambda p: p["routes"]["economy"].update(rank=False))
# A re-added provider block is a closed-schema violation, not silently ignored.
reject(lambda p: p["routes"]["deep"].update(codex={"model": "m", "reasoning_effort": "high", "service_tier": "default"}))
reject(lambda p: p["routes"]["deep"].update(rank=9))
reject(lambda p: p.update(reasoning_efforts=["warp"]))
reject(lambda p: p.update(reasoning_efforts=["low", "low"]))
reject(lambda p: p.update(reasoning_efforts=[]))
reject(lambda p: p.update(fallback_order=[{"not": "a route"}]))
reject(lambda p: p["fallback_order"].append("economy"))
reject(lambda p: p["aliases"].update(bogus="not-a-route"))
reject(lambda p: p["lead_routes"]["small"].update(default="not-a-route"))
reject(lambda p: p.update(high_risk_floor="not-a-route"))
reject(lambda p: p["roles"]["code-reviewer"].update(route="ultra"))
reject(lambda p: p["roles"]["code-reviewer"].update(route="economy"))
reject(lambda p: p["roles"]["code-reviewer"].update(delegation_mode="branch"), "invalid_leaf_contract")
reject(lambda p: p["delegation_contracts"]["leaf"].update(agents_max_depth=1), "invalid_leaf_contract")
expect_error("invalid_policy", lambda: module.load_policy(FIXTURES / "policy-duplicate-key.json"))

# classify_minimum_route: the live floor classifier. Lead tiers, high-risk
# escalation, role floors, judgment-bearing escalation, and the closed error set.
# THREE lead tiers since #619 collapsed `large` into `medium`. `medium` is the
# ceiling, so `quality` / `frontier` is the top of the lead ladder.
for tier, expected in (("trivial", "standard"), ("small", "standard"), ("medium", "quality")):
    check(classify(request(task_tier=tier)) == expected, f"default tier floor failed: {tier}")
for tier, expected in (("trivial", "deep"), ("small", "deep"), ("medium", "frontier")):
    check(classify(request(task_tier=tier, risk_signals=["security"])) == expected, f"high-risk tier floor failed: {tier}")
# The deleted rung is not merely unrouted, it is REFUSED -- lead_routes is the
# tier vocabulary this classifier validates against, so a stale `large` from any
# caller fails loudly instead of silently defaulting.
expect_error("invalid_task_tier", lambda: classify(request(task_tier="large")))
check(classify(request(role="code-simplifier", phase="review")) == "standard", "quality role floor failed")
check(classify(request(role="triage-scout", phase="triage")) == "economy", "economy role floor failed")
# A monitor role carries no risk judgment, so a risk signal must not lift it.
check(classify(request(role="testers-monitor-primary", phase="monitor", risk_signals=["security"])) == "economy", "bookkeeping monitor must retain role floor")
# A judgment-bearing role escalates to the policy high-risk floor.
check(classify(request(role="spec-reviser", phase="design", risk_signals=["security"])) == "deep", "judgment-bearing role did not escalate")
# plan-writer declares its own conditional high-risk route and uses it.
check(classify(request(role="plan-writer", phase="plan", risk_signals=["security"])) == "ultra", "plan-writer high_risk_route not honoured")
# Escalation is switchable from either the environment or the project layer.
check(classify(request(role="spec-reviser", risk_signals=["security"], project_routing={"risk_escalation": False})) == "standard", "project risk_escalation=False ignored")
check(classify(request(role="spec-reviser", risk_signals=["security"], environment={"UBERDEV_MODEL_ROUTING_RISK_ESCALATION": False})) == "standard", "environment risk_escalation=False ignored")
# risk_scope shapes which signals are legal, not which floor is chosen.
for risk_scope in ("run", "subtask"):
    check(classify(request(role="code-simplifier", risk_scope=risk_scope)) == "standard", f"{risk_scope} scope changed the normal role floor")
check(classify(request(role="research-codebase", risk_scope="none", risk_signals=[])) == "economy", "risk_scope none changed the role floor")
scope_mismatch = expect_error("risk_scope_mismatch", lambda: classify(request(role="research-codebase", risk_scope="none", risk_signals=["security"])))
check(scope_mismatch.detail == "risk scope 'none' requires empty risk_signals", "risk_scope none mismatch diagnostic drifted")
invalid_scope = expect_error("invalid_risk_scope", lambda: classify(request(role="code-simplifier", risk_scope="edge")))
check(invalid_scope.detail == "risk scope 'edge' must be run, subtask, or none", "invalid risk scope diagnostic drifted")
expect_error("invalid_task_tier", lambda: classify(request(task_tier="huge")))
expect_error("invalid_risk_signal", lambda: classify(request(risk_signals=["issue text says sol-ultra"])))
expect_error("invalid_risk_signal", lambda: classify(request(risk_signals=[7])))
expect_error("unknown_role", lambda: classify(request(role="no-such-agent")))
expect_error("invalid_request", lambda: classify(request(project_routing={"risk_escalation": "yes"})))
# Underscore spellings of declared signals normalize; undeclared ones do not.
check(classify(request(task_tier="medium", risk_signals=["data_loss"])) == "frontier", "underscore risk signal did not normalize")
# Classification never mutates the policy it was handed.
before = json.dumps(policy, sort_keys=True)
classify(request(task_tier="medium", risk_signals=["security"]))
check(json.dumps(policy, sort_keys=True) == before, "classify_minimum_route mutated the policy")

print(f"model-routing: PASS ({checks} checks)")
PY

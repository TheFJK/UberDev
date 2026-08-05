#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import copy, importlib.util, json, pathlib, sys
root=pathlib.Path(sys.argv[1]); path=root/'plugins/uberdev/lib/model_routing.py'
spec=importlib.util.spec_from_file_location('routing',path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
policy=m.load_policy(root/'plugins/uberdev/policy/model-routing-v1.json')
count=0
def check(value, expected):
 global count
 assert value == expected, (value, expected); count += 1
def classify(tier, risks=None, **extra):
 request={'role':'plan-writer','task_tier':tier,'risk_signals':risks or []}
 request.update(extra); return m.classify_minimum_route(policy,request)

# RETIRED SURFACE (#381). This file used to drive m.resolve_route and assert a
# concrete (logical_route, reasoning_effort) pair per tier off plan-writer's
# `tier_routes` ladder. Both are gone: no shipped backend owns the provider
# invocation, so the resolver was deleted rather than left unreachable, and
# `tier_routes` was validated-but-unread policy data that went with it.
# LOST COVERAGE, stated plainly: the per-tier concrete ladder
# (trivial/small->deep/high, medium->frontier/max, large->ultra/ultra), the
# forced-parent pair inheritance, and the adaptive-vs-inherit split. Nothing
# enforces per-rank routing any more, so there is nothing left to assert about
# it -- see RFC 0013 (2026-08-05 amendment).
# WHAT SURVIVES, and is asserted below: the logical floor classifier, which is
# still live via lib/config-read.sh, plus every plan-writer policy invariant.
check(m.PUBLIC_API.get('resolve_route'), None)
check(hasattr(m,'resolve_route'), False)
check(hasattr(m,'fallback_route'), False)
check(hasattr(m,'validate_catalog'), False)
check('tier_routes' in policy['roles']['plan-writer'], False)

# plan-writer floors at `deep` on every tier, and escalates to its declared
# high_risk_route when a risk signal is present and escalation is enabled.
for tier in ('trivial','small','medium','large'):
 check(classify(tier),'deep')
check(classify('small',['security']),'ultra')
check(classify('large',['security']),'ultra')
check(classify('small',['security'],project_routing={'risk_escalation':False}),'deep')
check(classify('small',['security'],environment={'UBERDEV_MODEL_ROUTING_RISK_ESCALATION':False}),'deep')
check(policy['roles']['plan-writer']['high_risk_route'],'ultra')
check(policy['roles']['plan-writer']['delegation_mode'],'leaf'); check(policy['roles']['plan-writer']['sandbox_ceiling'],'workspace-write')
for mutate in ('unknown-high-risk-route','missing-high-risk-route','unconditional-ultra','unknown-field','tier-routes-readded'):
 bad=copy.deepcopy(policy); row=bad['roles']['plan-writer']
 if mutate=='unknown-high-risk-route': row['high_risk_route']='bogus'
 elif mutate=='missing-high-risk-route': del row['high_risk_route']
 elif mutate=='unconditional-ultra': row['route']='ultra'
 elif mutate=='tier-routes-readded': row['tier_routes']={'trivial':'deep','small':'deep','medium':'frontier','large':'ultra'}
 else: row['surprise']=True
 try: m._validate_policy(bad)
 except m.RouteError as e: check(e.code,'invalid_policy')
 else: raise AssertionError(mutate)
print(f'plan-writer-routing: {count} checks passed')
PY

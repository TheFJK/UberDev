#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import copy, importlib.util, json, pathlib, sys
root=pathlib.Path(sys.argv[1]); path=root/'plugins/uberdev/lib/model_routing.py'
spec=importlib.util.spec_from_file_location('routing',path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
policy=m.load_policy(root/'plugins/uberdev/policy/model-routing-v1.json')
catalog=json.loads((root/'tests/fixtures/model-routing/catalog-gpt-5.6.json').read_text())
count=0
def check(value, expected):
 global count
 assert value == expected, (value, expected); count += 1
def resolve(tier, risks=None, **extra):
 request={'backend':'codex','workflow':'solve','phase':'plan','role':'plan-writer','task_tier':tier,'risk_signals':risks or [],'routing_mode':'adaptive'}
 if extra.get('parent_run',{}).get('forced') is True: request.pop('routing_mode')
 request.update(extra); return m.resolve_route(policy,catalog,request)
for tier, route, effort in [('trivial','deep','high'),('small','deep','high'),('medium','frontier','max'),('large','ultra','ultra')]:
 decision=resolve(tier); check(decision['logical_route'],route); check(decision['reasoning_effort'],effort)
check(resolve('small',['security'])['logical_route'],'ultra')
check(resolve('small',['security'],project_routing={'risk_escalation':False})['logical_route'],'deep')
check(resolve('large',project_routing={'risk_escalation':False})['logical_route'],'ultra')
forced={'logical_route':'ultra','model':'gpt-5.6-sol','reasoning_effort':'ultra','service_tier':'default','sandbox':'workspace-write','forced':True}
check(resolve('small',parent_run=forced)['logical_route'],'ultra')
inherit=resolve('large',routing_mode='inherit'); check(inherit['model'],None); check(inherit['reasoning_effort'],None)
check(policy['roles']['plan-writer']['delegation_mode'],'leaf'); check(policy['roles']['plan-writer']['sandbox_ceiling'],'workspace-write')
for mutate in ('missing-tier','unknown-route','unconditional-ultra','unknown-field'):
 bad=copy.deepcopy(policy); row=bad['roles']['plan-writer']
 if mutate=='missing-tier': del row['tier_routes']['small']
 elif mutate=='unknown-route': row['tier_routes']['medium']='bogus'
 elif mutate=='unconditional-ultra': row['route']='ultra'
 else: row['surprise']=True
 try: m._validate_policy(bad)
 except m.RouteError as e: check(e.code,'invalid_policy')
 else: raise AssertionError(mutate)
print(f'plan-writer-routing: {count} checks passed')
PY

#!/usr/bin/env bash
# Instrumented detached-agent dispatch adapter (RFC 0013).
#
# Public API:
#   uberdev_agent_dispatch REQUEST_JSON PROMPT_FILE RESULT_FILE STATUS_FILE
#
# The caller supplies one provider boundary named
# `_uberdev_agent_dispatch_backend`.  lib/dispatch.sh owns the production
# boundary; tests replace it with a provider stub.  This file owns route
# resolution, lifecycle publication, and capacity leases, so provider arms can
# remain focused on preserving their existing launch semantics.

if [ "${_UBERDEV_AGENT_DISPATCH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

_uberdev_agent_dispatch_source_path() {
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    printf '%s' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s' "${(%):-%x}"
  else
    return 1
  fi
}

_UBERDEV_AGENT_DISPATCH_FILE="$(_uberdev_agent_dispatch_source_path)" || return 1
case "$_UBERDEV_AGENT_DISPATCH_FILE" in
  */*) _UBERDEV_AGENT_DISPATCH_DIR="${_UBERDEV_AGENT_DISPATCH_FILE%/*}" ;;
  *) _UBERDEV_AGENT_DISPATCH_DIR='.' ;;
esac
_UBERDEV_AGENT_DISPATCH_DIR="$(cd "$_UBERDEV_AGENT_DISPATCH_DIR" 2>/dev/null && pwd -P)" || return 1
_UBERDEV_AGENT_DISPATCH_ROOT="$(cd "$_UBERDEV_AGENT_DISPATCH_DIR/.." 2>/dev/null && pwd -P)" || return 1
_UBERDEV_AGENT_ROUTER="$_UBERDEV_AGENT_DISPATCH_DIR/model_routing.py"
_UBERDEV_AGENT_MANIFEST_TOOL="$_UBERDEV_AGENT_DISPATCH_DIR/run_manifest.py"
_UBERDEV_AGENT_POLICY="$_UBERDEV_AGENT_DISPATCH_ROOT/policy/model-routing-v1.json"

# shellcheck source=/dev/null
. "$_UBERDEV_AGENT_DISPATCH_DIR/live-semaphore.sh" || return 1
_UBERDEV_AGENT_DISPATCH_LOADED=1

# live-semaphore.sh is shared with standalone Bash callers and discovers its
# sibling through BASH_SOURCE. Pin the already-canonical adapter sibling so
# clean zsh execution does not resolve that helper relative to the caller cwd.
_uberdev_semaphore_manifest_tool() {
  printf '%s\n' "$_UBERDEV_AGENT_MANIFEST_TOOL"
}

_uberdev_agent_error() {
  printf 'uberdev agent dispatch: %s\n' "$1" >&2
}

# Detached PR review/simplify children cannot service an interactive Claude
# permission prompt. Require an explicit unattended opt-in before any route
# event or capacity lease is created. Other workflows preserve their existing
# interactive behavior, and an explicit claude-bg backend remains explicit --
# this gate validates its execution posture rather than silently rerouting it.
_uberdev_agent_claude_permissions_preflight() {
  case "${1:-}" in
    review-pr|simplify) ;;
    *) return 0 ;;
  esac
  if [ "${SKIP_PERMISSIONS:-0}" = "1" ] || [ "${AUTO_PERMISSIONS:-0}" = "1" ]; then
    return 0
  fi
  _uberdev_agent_error 'claude-bg review fanout requires unattended permissions; set AUTO_PERMISSIONS=1 or SKIP_PERMISSIONS=1, or select backend=codex'
  return 2
}

_uberdev_agent_json_get() {
  local raw="$1" key="$2"
  python3 -I -B -c '
import json, sys
try:
    value = json.loads(sys.argv[1])
    for key in sys.argv[2].split("."):
        value = value[key]
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(3)
if value is None:
    raise SystemExit(3)
if isinstance(value, bool):
    print("true" if value else "false", end="")
elif isinstance(value, (str, int)) and not isinstance(value, bool):
    text = str(value)
    if not text or any(ch in text for ch in ("\r", "\n", "\0")):
        raise SystemExit(2)
    print(text, end="")
else:
    raise SystemExit(2)
' "$raw" "$key"
}

_uberdev_agent_validate_issue_identity() {
  python3 -I -B -c '
import json, re, sys
try:
    request = json.loads(sys.argv[1])
except (TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)
if not isinstance(request, dict):
    raise SystemExit(2)
issue = request.get("issue_num")
workflow=request.get("workflow")
if workflow not in {"solve","turbo","review-pr","simplify"} or type(issue) is not int or issue < 0 or (workflow!="simplify" and issue==0):
    raise SystemExit(2)
if workflow in {"solve", "turbo", "review-pr"}:
    reference = request.get("issue_or_pr")
    if type(reference) is int:
        normalized = reference if reference > 0 else None
    elif isinstance(reference, str):
        match = re.fullmatch(
            r"(?:#?|(?:issue|pr)[:#]?)([1-9][0-9]*)|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#([1-9][0-9]*)",
            reference,
            re.IGNORECASE,
        )
        normalized = int(next(group for group in match.groups() if group)) if match else None
    else:
        normalized = None
    if normalized != issue:
        raise SystemExit(2)
print(issue, end="")
' "$1"
}

_uberdev_agent_validate_run_dir() {
  python3 -I -B -c '
import os, stat, sys
path = os.path.abspath(sys.argv[1])
if not os.path.isabs(sys.argv[1]) or not os.path.isdir(path):
    raise SystemExit(2)
resolved = os.path.realpath(path)
entry = os.stat(resolved)
if not stat.S_ISDIR(entry.st_mode):
    raise SystemExit(2)
print(resolved, end="")
' "$1"
}

_uberdev_agent_validate_paths() {
  local run_dir="$1" state_root="$2" prompt_arg="$3" result_arg="$4" status_arg="$5"
  python3 -I -c '
import json, os, stat, sys
run_dir, state_root, *requested = sys.argv[1:]
run_dir = os.path.realpath(run_dir)
state_lexical = os.path.abspath(state_root)
state_canonical = os.path.realpath(state_root)

def beneath(root, path):
    try:
        return os.path.commonpath((root, path)) == root
    except ValueError:
        return False

def inspect(path, mode):
    if not os.path.isabs(path):
        raise SystemExit(2)
    lexical = os.path.abspath(path)
    parent = os.path.realpath(os.path.dirname(lexical))
    canonical = os.path.join(parent, os.path.basename(lexical))
    if not beneath(run_dir, canonical):
        raise SystemExit(2)
    if beneath(state_lexical, lexical) or beneath(state_canonical, canonical):
        raise SystemExit(2)
    if os.path.lexists(lexical) and stat.S_ISLNK(os.lstat(lexical).st_mode):
        raise SystemExit(2)
    identity = None
    if os.path.exists(lexical):
        entry = os.stat(lexical, follow_symlinks=False)
        if not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
            raise SystemExit(2)
        identity = (entry.st_dev, entry.st_ino)
    if mode == "input":
        if identity is None or not os.access(lexical, os.R_OK):
            raise SystemExit(2)
    elif mode == "output":
        if not os.path.isdir(parent):
            raise SystemExit(2)
    else:
        raise SystemExit(2)
    return {"lexical": lexical, "canonical": canonical, "identity": identity}

items = [inspect(requested[0], "input"), inspect(requested[1], "output"), inspect(requested[2], "output")]
for index, left in enumerate(items):
    for right in items[index + 1:]:
        if left["lexical"] == right["lexical"] or left["canonical"] == right["canonical"]:
            raise SystemExit(2)
        if left["identity"] is not None and left["identity"] == right["identity"]:
            raise SystemExit(2)
print(json.dumps({name: item["canonical"] for name, item in zip(("prompt", "result", "status"), items)}, sort_keys=True, separators=(",", ":")), end="")
' "$run_dir" "$state_root" "$prompt_arg" "$result_arg" "$status_arg"
}

_uberdev_agent_prepare_state_dir() {
  python3 -I -c '
import os, stat, sys
run_dir = sys.argv[1]
uid_fn = getattr(os, "geteuid", None)
uid = uid_fn() if uid_fn else None
path = os.path.join(run_dir, f".agent-state-{uid if uid is not None else 0}")
if os.name == "nt":
    # Native Windows denies POSIX-style os.open() on directories and has no
    # meaningful st_uid/fchmod contract. The run root is already canonical;
    # reject reparse-point aliases, then rely on the current-user ACL inherited
    # from the private temp root instead of weakening the POSIX branch below.
    os.makedirs(path, exist_ok=True)
    entry = os.lstat(path)
    if os.path.islink(path) or not stat.S_ISDIR(entry.st_mode):
        raise SystemExit(2)
    print(path, end="")
    raise SystemExit(0)
try:
    os.mkdir(path, 0o700)
except FileExistsError:
    pass
entry = os.lstat(path)
if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode):
    raise SystemExit(2)
if uid is not None and entry.st_uid != uid:
    raise SystemExit(2)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    current = os.fstat(descriptor)
    if not stat.S_ISDIR(current.st_mode) or (uid is not None and current.st_uid != uid):
        raise SystemExit(2)
    os.fchmod(descriptor, 0o700)
finally:
    os.close(descriptor)
print(path, end="")
' "$1"
}

# Resolve a request without publishing lifecycle state or acquiring capacity.
# This is the stable launcher seam for Wave 4a.2: callers pass raw CLI fields at
# top level, raw environment values in `environment`, project values in
# `project_routing`, and an already-normalized descendant decision in
# `parent_run`. Empty-string carrier values are rejected instead of silently
# changing provenance.
_uberdev_agent_resolve_request_internal() {
  local request_json="${1:-}" injected="${UBERDEV_MODEL_CATALOG_FILE:-}"
  [ "$#" -eq 1 ] || { _uberdev_agent_error 'resolve_request expects REQUEST_JSON'; return 2; }
  python3 -I -B -c '
import hashlib, importlib.util, json, os, pathlib, stat, sys
request_raw, policy_path, router_path, catalog_path = sys.argv[1:]
try:
    request=json.loads(request_raw)
    if not isinstance(request,dict): raise ValueError("request_not_object")
    allowed={"schema_version","run_dir","run_id","repository_id","backend","workflow","phase","role","task_tier","risk_scope","risk_signals","issue_or_pr","issue_num","capacity","timeout_s","routing_mode","explicit_route","explicit_model","explicit_effort","explicit_service_tier","fast","explicit_sandbox","parent_sandbox","environment","project_routing","project_config","parent_run","shadow","adaptive_fallback","parent_run_id","agent_id","context_file","context_sha256","root_decision","triage_decision","workspace_mode","workspace_dir"}
    unknown=set(request)-allowed
    if unknown: raise ValueError("unknown_request_fields")
    workspace_mode=request.get("workspace_mode","isolated")
    workspace_dir=request.get("workspace_dir")
    if workspace_mode not in {"isolated","caller"}: raise ValueError("invalid_workspace_mode")
    if workspace_mode=="isolated":
        if workspace_dir is not None: raise ValueError("unexpected_workspace_dir")
    else:
        repository_id=request.get("repository_id"); backend=request.get("backend","codex")
        if backend not in {"codex","claude-bg"}: raise ValueError("workspace_mode_unsupported")
        if not isinstance(workspace_dir,str) or not os.path.isabs(workspace_dir) or not os.path.isdir(workspace_dir): raise ValueError("invalid_workspace_dir")
        entry=os.lstat(workspace_dir)
        reparse=getattr(entry,"st_file_attributes",0)&getattr(stat,"FILE_ATTRIBUTE_REPARSE_POINT",0)
        if stat.S_ISLNK(entry.st_mode) or reparse or os.path.realpath(workspace_dir)!=workspace_dir: raise ValueError("invalid_workspace_dir")
        if not isinstance(repository_id,str) or os.path.realpath(repository_id)!=workspace_dir: raise ValueError("workspace_repository_mismatch")
    carriers={"routing_mode","explicit_route","explicit_model","explicit_effort","explicit_service_tier","explicit_sandbox","parent_sandbox"}
    if any(request.get(key)=="" for key in carriers): raise ValueError("empty_carrier")
    environment=request.get("environment",{})
    if not isinstance(environment,dict): raise ValueError("invalid_environment")
    environment_allowed={"UBERDEV_MODEL_ROUTING_MODE","UBERDEV_ROUTE","UBERDEV_MODEL","UBERDEV_REASONING_EFFORT","UBERDEV_SERVICE_TIER","UBERDEV_MODEL_ROUTING_RISK_ESCALATION","UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK","UBERDEV_MODEL_ROUTING_SHADOW","UBERDEV_MODEL_ROUTING_WORKFLOWS","UBERDEV_MODEL_ROUTING_ROLES"}
    if set(environment)-environment_allowed: raise ValueError("unknown_environment_fields")
    string_environment={"UBERDEV_MODEL_ROUTING_MODE","UBERDEV_ROUTE","UBERDEV_MODEL","UBERDEV_REASONING_EFFORT","UBERDEV_SERVICE_TIER"}; map_environment={"UBERDEV_MODEL_ROUTING_WORKFLOWS","UBERDEV_MODEL_ROUTING_ROLES"}
    for key,value in environment.items():
        if value is None: continue
        if key in string_environment and (not isinstance(value,str) or not value): raise ValueError("invalid_environment_carrier")
        if key in map_environment and not isinstance(value,dict): raise ValueError("invalid_environment_map")
        if key not in string_environment|map_environment and not isinstance(value,bool): raise ValueError("invalid_environment_boolean")
    decision_fields={"schema_version","policy_version","backend","service_tier","sandbox","field_sources","adaptive_fallback","risk_signals","risk_scope","minimum_route","fallback_chain","ignored_sources","ignored_fields","logical_route","model","reasoning_effort","routing_mode","effective_policy","route_source","forced","reason_codes","adaptive_proposal"}
    parent=request.get("parent_run",{})
    if not isinstance(parent,dict) or set(parent)-decision_fields: raise ValueError("invalid_parent_run")
    config_allowed={"mode","routing_mode","service_tier","risk_escalation","adaptive_fallback","shadow","roles","workflows"}
    def validate_project(value):
        if not isinstance(value,dict): raise ValueError("invalid_project_routing")
        if set(value)-config_allowed: raise ValueError("unknown_project_fields")
        for scope in ("roles","workflows"):
            entries=value.get(scope,{})
            if not isinstance(entries,dict): raise ValueError("invalid_project_map")
            for name,entry in entries.items():
                if not isinstance(name,str) or not name or (not isinstance(entry,str) and not isinstance(entry,dict)): raise ValueError("invalid_project_entry")
                if isinstance(entry,dict) and (set(entry)-{"route","reasoning_effort","sandbox"}): raise ValueError("unknown_project_entry_fields")
    if "project_routing" in request: validate_project(request["project_routing"])
    if "project_config" in request:
        project=request["project_config"]
        if not isinstance(project,dict): raise ValueError("invalid_project_config")
        if "model_routing" in project:
            if set(project)!={"model_routing"}: raise ValueError("unknown_project_config_fields")
            validate_project(project["model_routing"])
        else: validate_project(project)
    routing={key:value for key,value in request.items() if key not in {"schema_version","run_dir","run_id","repository_id","issue_or_pr","issue_num","capacity","timeout_s","parent_run_id","agent_id","context_file","context_sha256","root_decision","triage_decision","workspace_mode","workspace_dir"}}
    backend=routing.get("backend","codex")
    if backend!="codex":
        project=request.get("project_routing") or request.get("project_config") or {}
        if isinstance(project,dict) and "model_routing" in project: project=project["model_routing"]
        role=routing.get("role","lead"); workflow=routing.get("workflow","")
        project_concrete=(project.get("service_tier") not in (None,"","default") or (isinstance(project.get("roles"),dict) and project["roles"].get(role) is not None) or (isinstance(project.get("workflows"),dict) and project["workflows"].get(workflow) is not None))
        environment_concrete=any(environment.get(key) not in (None,"") for key in ("UBERDEV_ROUTE","UBERDEV_MODEL","UBERDEV_REASONING_EFFORT")) or environment.get("UBERDEV_SERVICE_TIER") not in (None,"","default") or any(environment.get(key) for key in ("UBERDEV_MODEL_ROUTING_WORKFLOWS","UBERDEV_MODEL_ROUTING_ROLES"))
        service=routing.get("explicit_service_tier") or environment.get("UBERDEV_SERVICE_TIER") or project.get("service_tier") or "default"
        adaptive_requested=(routing.get("routing_mode")=="adaptive" or environment.get("UBERDEV_MODEL_ROUTING_MODE")=="adaptive" or project.get("mode",project.get("routing_mode"))=="adaptive")
        if adaptive_requested or any(routing.get(k) not in (None,"") for k in ("explicit_route","explicit_model","explicit_effort")) or parent.get("forced") is True or service!="default" or environment_concrete or project_concrete:
            class Unenforceable(Exception): code="route_unenforceable"
            raise Unenforceable()
        decision={"schema_version":1,"backend":backend,"routing_mode":"inherit","effective_policy":"inherit","logical_route":None,"model":None,"reasoning_effort":None,"service_tier":"default","sandbox":None,"forced":False,"route_source":"backend-neutral-inherit","risk_signals":routing.get("risk_signals",[]),"fallback_chain":[],"minimum_route":None}
        print(json.dumps(decision,sort_keys=True,separators=(",",":")),end=""); raise SystemExit(0)
    spec=importlib.util.spec_from_file_location("_uberdev_model_routing",router_path)
    if spec is None or spec.loader is None: raise ValueError("router_unavailable")
    module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module; spec.loader.exec_module(module)
    policy=module.load_policy(pathlib.Path(policy_path))
    if catalog_path:
        path=pathlib.Path(catalog_path)
        if not path.is_absolute() or path.is_symlink() or not path.is_file(): raise ValueError("unsafe_catalog")
        catalog=json.loads(path.read_text(encoding="utf-8"))
    else:
        models={}; ranked=[]; available=[]; tiers={"default","fast","flex"}
        for route,row in sorted(policy["routes"].items(),key=lambda item:item[1]["rank"]):
            provider=row["codex"]; model=provider["model"]; effort=provider["reasoning_effort"]
            models.setdefault(model,{"reasoning_efforts":[]})["reasoning_efforts"].append(effort)
            ranked.append({"logical_route":route,"rank":row["rank"],"model":model,"reasoning_effort":effort})
            available.append({"model":model,"reasoning_effort":effort}); tiers.add(provider["service_tier"])
        for row in models.values(): row["reasoning_efforts"]=list(dict.fromkeys(row["reasoning_efforts"]))
        catalog={"schema_version":1,"provider":"codex","models":models,"ranked_pairs":ranked,"available_pairs":available,"service_tiers":sorted(tiers),"source_roles":sorted(policy["roles"])}
    resolver_request=dict(routing); resolver_environment=dict(environment)
    project_config=dict(request.get("project_routing") or {})
    for env_key,scope in (("UBERDEV_MODEL_ROUTING_WORKFLOWS","workflows"),("UBERDEV_MODEL_ROUTING_ROLES","roles")):
        env_map=resolver_environment.pop(env_key,None)
        if env_map is not None:
            project_config[scope]=dict(env_map)
    if resolver_environment: resolver_request["environment"]=resolver_environment
    else: resolver_request.pop("environment",None)
    if project_config: resolver_request["project_routing"]=project_config
    decision=module.resolve_route(policy,catalog,resolver_request)
    role=resolver_request.get("role","lead"); workflow=resolver_request.get("workflow","")
    source_rewrites=[]
    if isinstance(environment.get("UBERDEV_MODEL_ROUTING_ROLES"),dict) and role in environment["UBERDEV_MODEL_ROUTING_ROLES"]:
        source_rewrites.append(("project-role","environment-role"))
    if isinstance(environment.get("UBERDEV_MODEL_ROUTING_WORKFLOWS"),dict) and workflow in environment["UBERDEV_MODEL_ROUTING_WORKFLOWS"]:
        source_rewrites.append(("project-workflow","environment-workflow"))
    def rewrite_source_tokens(value,old,new):
        if isinstance(value,dict): return {key:rewrite_source_tokens(item,old,new) for key,item in value.items()}
        if isinstance(value,list): return [rewrite_source_tokens(item,old,new) for item in value]
        if isinstance(value,str) and (value==old or value.startswith(old+"-")): return new+value[len(old):]
        return value
    for old,new in source_rewrites:
        decision=rewrite_source_tokens(decision,old,new)
    print(json.dumps(decision,sort_keys=True,separators=(",",":")),end="")
except Exception as exc:
    code=getattr(exc,"code","invalid_request")
    # Deliberately redact exception detail: request values and paths can carry secrets.
    print(json.dumps({"error":{"code":code,"detail":"routing request rejected"}},sort_keys=True,separators=(",",":")),file=sys.stderr)
    raise SystemExit(2)
' "$request_json" "$_UBERDEV_AGENT_POLICY" "$_UBERDEV_AGENT_ROUTER" "$injected"
}

uberdev_agent_resolve_request() {
  _uberdev_agent_resolve_request_internal "$@"
}

_uberdev_agent_compact_json() {
  python3 -I -B -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]),sort_keys=True,separators=(",",":")),end="")' "$1"
}

_uberdev_agent_context_schema_validate() {
  local mode="$1"; shift
  python3 -I -B -c '
import json,os,re,sys
mode=sys.argv[1]
routing_allowed={"backend","workflow","phase","role","task_tier","risk_scope","risk_signals","routing_mode","explicit_route","explicit_model","explicit_effort","explicit_service_tier","fast","explicit_sandbox","parent_sandbox","environment","project_routing","project_config","parent_run","shadow","adaptive_fallback"}
adapter_metadata={"schema_version","run_dir","run_id","repository_id","issue_or_pr","issue_num","capacity","timeout_s","parent_run_id","agent_id","context_file","context_sha256","root_decision","triage_decision","workspace_mode","workspace_dir"}
decision_allowed={"schema_version","policy_version","backend","service_tier","sandbox","field_sources","adaptive_fallback","risk_signals","risk_scope","minimum_route","fallback_chain","ignored_sources","ignored_fields","logical_route","model","reasoning_effort","routing_mode","effective_policy","route_source","forced","reason_codes","adaptive_proposal"}
provenance_keys={"mode","service_tier","risk_escalation","adaptive_fallback","shadow","workflows","roles"}; sources={"env","project-codex","project-claude","explicit-config-file","default"}
risks={"authentication","authorization","concurrency","cryptography","data-loss","destructive-operations","force-push","public-api-compatibility","release-infrastructure","schema-migration","security"}
def validate(payload):
 if not isinstance(payload,dict) or set(payload)!={"schema_version","created_at","routing_request","root_decision","config_provenance","metadata"} or payload.get("schema_version")!=1: raise ValueError()
 if not isinstance(payload["created_at"],str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",payload["created_at"]): raise ValueError()
 request=payload["routing_request"]
 if not isinstance(request,dict) or set(request)-routing_allowed: raise ValueError()
 environment=request.get("environment",{}); env_keys={"UBERDEV_MODEL_ROUTING_MODE","UBERDEV_ROUTE","UBERDEV_MODEL","UBERDEV_REASONING_EFFORT","UBERDEV_SERVICE_TIER","UBERDEV_MODEL_ROUTING_RISK_ESCALATION","UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK","UBERDEV_MODEL_ROUTING_SHADOW","UBERDEV_MODEL_ROUTING_WORKFLOWS","UBERDEV_MODEL_ROUTING_ROLES"}
 if not isinstance(environment,dict) or set(environment)-env_keys: raise ValueError()
 for key in ("routing_mode","explicit_route","explicit_model","explicit_effort","explicit_service_tier","explicit_sandbox","parent_sandbox"):
  if request.get(key)=="": raise ValueError()
 parent=request.get("parent_run",{})
 if not isinstance(parent,dict) or set(parent)-decision_allowed: raise ValueError()
 config_allowed={"mode","routing_mode","service_tier","risk_escalation","adaptive_fallback","shadow","roles","workflows"}
 def project(value):
  if not isinstance(value,dict) or set(value)-config_allowed: raise ValueError()
  for scope in ("roles","workflows"):
   entries=value.get(scope,{})
   if not isinstance(entries,dict): raise ValueError()
   for name,entry in entries.items():
    if not isinstance(name,str) or not name or (not isinstance(entry,str) and not isinstance(entry,dict)): raise ValueError()
    if isinstance(entry,dict) and set(entry)-{"route","reasoning_effort","sandbox"}: raise ValueError()
 if "project_routing" in request: project(request["project_routing"])
 if "project_config" in request:
  value=request["project_config"]
  if not isinstance(value,dict): raise ValueError()
  if "model_routing" in value:
   if set(value)!={"model_routing"}: raise ValueError()
   project(value["model_routing"])
  else: project(value)
 decision=payload["root_decision"]
 if not isinstance(decision,dict) or set(decision)-decision_allowed or not {"schema_version","backend","routing_mode","effective_policy","logical_route","model","reasoning_effort","service_tier","forced","route_source","risk_signals","fallback_chain","minimum_route"}.issubset(decision): raise ValueError()
 provenance=payload["config_provenance"]
 if not isinstance(provenance,dict) or set(provenance)!=provenance_keys: raise ValueError()
 for record in provenance.values():
  if not isinstance(record,dict) or set(record)!={"source","file"} or record["source"] not in sources: raise ValueError()
  path=record["file"]
  if record["source"] in {"env","default"} and path is not None: raise ValueError()
  if record["source"] not in {"env","default"} and (not isinstance(path,str) or not os.path.isabs(path) or os.path.normpath(path)!=path): raise ValueError()
 request_project=request.get("project_routing")
 if request_project is None:
  request_project=request.get("project_config",{})
  if isinstance(request_project,dict) and "model_routing" in request_project: request_project=request_project["model_routing"]
 if not isinstance(request_project,dict): raise ValueError()
 field_contracts={
  "mode":("UBERDEV_MODEL_ROUTING_MODE",("mode","routing_mode"),"inherit"),
  "service_tier":("UBERDEV_SERVICE_TIER",("service_tier",),"default"),
  "risk_escalation":("UBERDEV_MODEL_ROUTING_RISK_ESCALATION",("risk_escalation",),True),
  "adaptive_fallback":("UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK",("adaptive_fallback",),True),
  "shadow":("UBERDEV_MODEL_ROUTING_SHADOW",("shadow",),False),
  "workflows":("UBERDEV_MODEL_ROUTING_WORKFLOWS",("workflows",),{}),
  "roles":("UBERDEV_MODEL_ROUTING_ROLES",("roles",),{}),
 }
 for field,(env_key,project_keys,default) in field_contracts.items():
  record=provenance[field]; source=record["source"]
  env_selected=env_key is not None and env_key in environment and environment[env_key] is not None
  configured=[key for key in project_keys if key in request_project]
  project_selected=bool(configured)
  project_value=request_project[configured[0]] if configured else None
  if source=="env":
   if not env_selected: raise ValueError()
  elif source=="default":
   if env_selected or project_selected: raise ValueError()
  else:
   if env_selected or not project_selected: raise ValueError()
   path=record["file"]
   if source=="project-codex" and not path.endswith("/.codex/uberdev.local.md"): raise ValueError()
   if source=="project-claude" and not path.endswith("/.claude/uberdev.local.md"): raise ValueError()
 metadata=payload["metadata"]
 metadata_base={"run_id","repository_id","workflow","backend","issue_num","task_tier","risk_signals"}
 if not isinstance(metadata,dict) or frozenset(metadata) not in {frozenset(metadata_base),frozenset(metadata_base|{"triage_decision"})}: raise ValueError()
 if not isinstance(metadata["run_id"],str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",metadata["run_id"]): raise ValueError()
 if not isinstance(metadata["repository_id"],str) or not metadata["repository_id"] or metadata["workflow"] not in {"solve","turbo","review-pr","simplify"} or not isinstance(metadata["backend"],str): raise ValueError()
 if type(metadata["issue_num"]) is not int or metadata["issue_num"]<0 or (metadata["workflow"]!="simplify" and metadata["issue_num"]==0) or metadata["task_tier"] not in {"trivial","small","medium","large"}: raise ValueError()
 if not isinstance(metadata["risk_signals"],list) or any(item not in risks for item in metadata["risk_signals"]): raise ValueError()
 if "triage_decision" in metadata:
  triage=metadata["triage_decision"]
  triage_keys={"schema_version","issue","raw_tier","clamped_tier","effective_tier","tier","source","matched_rules","risk_signals","file_count","files","component_count","components"}
  if not isinstance(triage,dict) or set(triage)!=triage_keys or triage.get("schema_version")!=1: raise ValueError()
  if triage.get("issue")!=metadata["issue_num"] or triage.get("effective_tier")!=metadata["task_tier"] or triage.get("tier")!=metadata["task_tier"] or triage.get("risk_signals")!=metadata["risk_signals"]: raise ValueError()
  if triage.get("raw_tier") not in {"trivial","small","medium","large"} or triage.get("clamped_tier") not in {"trivial","small","medium","large"} or triage.get("source") not in {"computed","floor","ceiling","override"}: raise ValueError()
  if not isinstance(triage.get("matched_rules"),list) or not all(isinstance(x,str) and x for x in triage["matched_rules"]): raise ValueError()
  files=triage.get("files"); components=triage.get("components"); rules=triage.get("matched_rules")
  if not isinstance(files,list) or not isinstance(components,list): raise ValueError()
  if len(files)>256 or len(components)>64 or len(rules)>32 or triage.get("file_count")!=len(files) or triage.get("component_count")!=len(components): raise ValueError()
  if files!=sorted(set(files)) or components!=sorted(set(components)) or triage["risk_signals"]!=sorted(set(triage["risk_signals"])): raise ValueError()
  if any(not isinstance(x,str) or not re.fullmatch(r"[a-z0-9_.][a-z0-9_./-]{0,255}",x) for x in files): raise ValueError()
  if any(not isinstance(x,str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}",x) for x in components): raise ValueError()
  if any(not isinstance(x,str) or not re.fullmatch(r"[a-z0-9][a-z0-9:_-]{0,127}",x) for x in rules): raise ValueError()
  allowed_rule=re.compile(r"(?:large-label:(?:epic|needs-discussion|architectural|architecture|infrastructure)|large:(?:three-files|multi-component-high-risk|cross-cutting-refactor)|trivial:bounded-explicit-signal|small:concrete-reproduction|medium:fallback|(?:floor|ceiling|override):(?:trivial|small|medium|large))")
  if len(rules)!=len(set(rules)) or any(not allowed_rule.fullmatch(x) for x in rules): raise ValueError()
  if len(json.dumps(triage,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode("utf-8"))>32768: raise ValueError()
 if request.get("workflow")!=metadata["workflow"] or request.get("backend")!=metadata["backend"] or request.get("task_tier")!=metadata["task_tier"] or request.get("risk_signals",[])!=metadata["risk_signals"]: raise ValueError()
 if decision.get("backend")!=metadata["backend"] or decision.get("risk_signals",[])!=metadata["risk_signals"]: raise ValueError()
 return payload
if mode=="create":
 request,decision,provenance,metadata=(json.loads(value) for value in sys.argv[2:6]); created=sys.argv[6]
 if not isinstance(request,dict) or set(request)-(routing_allowed|adapter_metadata): raise ValueError()
 payload={"schema_version":1,"created_at":created,"routing_request":{key:value for key,value in request.items() if key not in adapter_metadata},"root_decision":decision,"config_provenance":provenance,"metadata":metadata}
else:
 payload=json.loads(sys.argv[2])
print(json.dumps(validate(payload),sort_keys=True,separators=(",",":"),ensure_ascii=False),end="")
' "$mode" "$@"
}

# Atomically create an immutable v1 root routing context. The filename is
# derived only from the validated run_id and is exclusive: an existing context
# is never replaced.
uberdev_agent_context_create() {
  local payload canonical_decision supplied_decision
  [ "$#" -eq 6 ] || { _uberdev_agent_error 'context_create expects RUN_ROOT REQUEST DECISION PROVENANCE METADATA CREATED_AT'; return 2; }
  canonical_decision="$(_uberdev_agent_resolve_request_internal "$2" 2>/dev/null)" || {
    _uberdev_agent_error 'route_context_request_invalid'; return 2;
  }
  supplied_decision="$(_uberdev_agent_compact_json "$3" 2>/dev/null)" || {
    _uberdev_agent_error 'route_context_decision_invalid'; return 2;
  }
  if [ "$canonical_decision" != "$supplied_decision" ]; then
    _uberdev_agent_error 'route_context_mismatch'; return 2
  fi
  payload="$(_uberdev_agent_context_schema_validate create "$2" "$3" "$4" "$5" "$6" 2>/dev/null)" || {
    _uberdev_agent_error 'route_context_create_failed'; return 2;
  }
  python3 -I -B -c '
import hashlib,json,os,re,secrets,stat,sys,tempfile
root,payload_raw=sys.argv[1:]
try:
 lexical_root=os.path.abspath(root)
 if os.name=="nt":
  drive,tail=os.path.splitdrive(lexical_root); current=drive+os.path.sep
  for component in tail.split(os.path.sep):
   if not component: continue
   current=os.path.join(current,component)
   if os.path.lexists(current) and stat.S_ISLNK(os.lstat(current).st_mode): raise ValueError()
 root=os.path.realpath(root)
 entry=os.stat(root,follow_symlinks=False)
 uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
 if not stat.S_ISDIR(entry.st_mode) or (uid is not None and entry.st_uid!=uid): raise ValueError()
 payload=json.loads(payload_raw); metadata=payload["metadata"]
 run_id=metadata["run_id"]
 state_name=f".agent-state-{uid if uid is not None else 0}"; state=os.path.join(root,state_name)
 raw=payload_raw.encode()
 digest=hashlib.sha256(raw).hexdigest(); destination=os.path.join(state,f"route-context-v1-{run_id}.json")
 if os.name=="nt":
  os.makedirs(state,exist_ok=True)
  se=os.lstat(state)
  if stat.S_ISLNK(se.st_mode) or not stat.S_ISDIR(se.st_mode): raise ValueError()
  reserve_fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_BINARY",0),0o600)
  try: reservation=os.fstat(reserve_fd)
  finally: os.close(reserve_fd)
  reserved=True; fd=None; tmp=None
  try:
   fd,tmp=tempfile.mkstemp(prefix=".route-context.",dir=state)
   written=os.write(fd,raw)
   if written!=len(raw): raise ValueError()
   os.fsync(fd); os.close(fd); fd=None
   current=os.lstat(destination)
   if (not stat.S_ISREG(current.st_mode) or current.st_size!=0
       or (current.st_dev,current.st_ino)!=(reservation.st_dev,reservation.st_ino)): raise ValueError()
   os.replace(tmp,destination); tmp=None; reserved=False
  finally:
   if fd is not None: os.close(fd)
   if tmp is not None and os.path.exists(tmp): os.unlink(tmp)
   if reserved and os.path.lexists(destination):
    current=os.lstat(destination)
    if ((current.st_dev,current.st_ino)==(reservation.st_dev,reservation.st_ino)
        and stat.S_ISREG(current.st_mode) and current.st_size==0): os.unlink(destination)
  current=os.lstat(state)
  if (current.st_dev,current.st_ino)!=(se.st_dev,se.st_ino): raise ValueError()
  print(json.dumps({"context_file":destination,"context_sha256":digest,"run_id":run_id,"workflow":metadata["workflow"]},sort_keys=True,separators=(",",":")),end="")
  raise SystemExit(0)
 rootfd=os.open(root,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
 try:
  try: os.mkdir(state_name,0o700,dir_fd=rootfd)
  except FileExistsError: pass
  statefd=os.open(state_name,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=rootfd)
 finally: os.close(rootfd)
 se=os.fstat(statefd)
 if not stat.S_ISDIR(se.st_mode) or (uid is not None and se.st_uid!=uid): raise ValueError()
 os.fchmod(statefd,0o700)
 tmp=f".route-context.{secrets.token_hex(16)}"; fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600,dir_fd=statefd)
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,"wb") as stream: stream.write(raw); stream.flush(); os.fsync(stream.fileno())
  os.link(tmp,os.path.basename(destination),src_dir_fd=statefd,dst_dir_fd=statefd,follow_symlinks=False)
 finally:
  try: os.unlink(tmp,dir_fd=statefd)
  except FileNotFoundError: pass
 current=os.stat(state,follow_symlinks=False)
 if (current.st_dev,current.st_ino)!=(se.st_dev,se.st_ino): raise ValueError()
 os.close(statefd)
 print(json.dumps({"context_file":destination,"context_sha256":digest,"run_id":run_id,"workflow":metadata["workflow"]},sort_keys=True,separators=(",",":")),end="")
except Exception:
 print("uberdev agent dispatch: route_context_create_failed",file=sys.stderr); raise SystemExit(2)
' "$1" "$payload"
}

uberdev_agent_context_validate() {
  local payload validated routing_request stored_decision canonical_decision
  [ "$#" -eq 3 ] || return 2
  payload="$(python3 -I -B -c '
import hashlib,json,os,stat,sys
path,expected,root=sys.argv[1:]
try:
 if not os.path.isabs(path) or not os.path.isabs(root): raise ValueError()
 root=os.path.realpath(root)
 uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None; state=os.path.join(root,f".agent-state-{uid if uid is not None else 0}"); lexical=os.path.abspath(path); name=os.path.basename(lexical)
 if os.path.dirname(lexical)!=state or not name.startswith("route-context-v1-"): raise ValueError()
 if stat.S_ISLNK(os.lstat(state).st_mode): raise ValueError()
 statefd=os.open(state,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
 state_entry=os.fstat(statefd)
 flags=os.O_RDONLY|getattr(os,"O_NOFOLLOW",0); fd=os.open(name,flags,dir_fd=statefd)
 try:
  opened=os.fstat(fd); current=os.stat(name,dir_fd=statefd,follow_symlinks=False); raw=os.read(fd,1048577)
  if len(raw)>1048576 or not stat.S_ISREG(opened.st_mode) or (uid is not None and opened.st_uid!=uid) or opened.st_nlink!=1 or stat.S_IMODE(opened.st_mode)!=0o600 or (opened.st_dev,opened.st_ino)!=(current.st_dev,current.st_ino): raise ValueError()
 finally: os.close(fd)
 state_current=os.stat(state,follow_symlinks=False)
 if (state_current.st_dev,state_current.st_ino)!=(state_entry.st_dev,state_entry.st_ino): raise ValueError()
 os.close(statefd)
 digest=hashlib.sha256(raw).hexdigest()
 if digest!=expected or len(expected)!=64 or expected.lower()!=expected: raise ValueError()
 print(raw.decode("utf-8"),end="")
except Exception: raise SystemExit(2)
' "$1" "$2" "$3")" || return 2
  validated="$(_uberdev_agent_context_schema_validate payload "$payload" 2>/dev/null)" || return 2
  routing_request="$(python3 -I -B -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["routing_request"],sort_keys=True,separators=(",",":")),end="")' "$validated")" || return 2
  stored_decision="$(python3 -I -B -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["root_decision"],sort_keys=True,separators=(",",":")),end="")' "$validated")" || return 2
  canonical_decision="$(_uberdev_agent_resolve_request_internal "$routing_request" 2>/dev/null)" || return 2
  [ "$canonical_decision" = "$stored_decision" ] || return 2
  python3 -I -B -c '
import json,sys
path,digest,raw=sys.argv[1:]; value=json.loads(raw)
print(json.dumps({"context_file":path,"context_sha256":digest,"run_id":value["metadata"]["run_id"],"workflow":value["metadata"]["workflow"],"root_decision":value["root_decision"]},sort_keys=True,separators=(",",":")),end="")
' "$1" "$2" "$validated"
}

_uberdev_agent_event_json() {
  local event="$1" request="$2" decision="$3" handle="${4:-}" status_path="${5:-}" rc="${6:-}" error_class="${7:-}" owner_pid="$$"
  python3 -I -c '
import json, sys
event_name, request_raw, decision_raw, handle, status_path, rc, error_class, owner_pid = sys.argv[1:]
request = json.loads(request_raw); decision = json.loads(decision_raw)
routing = decision.get("routing_mode", "inherit")
effective = decision.get("effective_policy", "inherit")
proposal = decision.get("adaptive_proposal") if routing == "shadow" else decision
if not isinstance(proposal, dict):
    proposal = decision
record = {
    "schema_version": 1, "event": event_name,
    "run_id": request["run_id"], "backend": request["backend"],
    "workflow": request.get("workflow"), "phase": request.get("phase"),
    "role": request.get("role"), "issue_or_pr": request.get("issue_or_pr"),
    "task_tier": request.get("task_tier"), "routing_mode": routing,
    "decision_logical_route": proposal.get("logical_route"),
    "decision_source": proposal.get("route_source"),
    "decision_model": proposal.get("model"),
    "decision_reasoning_effort": proposal.get("reasoning_effort"),
    "effective_policy": effective,
    "effective_logical_route": decision.get("logical_route") if effective != "inherit" else None,
    "effective_model": decision.get("model") if effective != "inherit" else None,
    "effective_reasoning_effort": decision.get("reasoning_effort") if effective != "inherit" else None,
    "effective_service_tier": decision.get("service_tier"),
    "effective_sandbox": decision.get("sandbox"),
    "enforcement_evidence": "explicit_argv" if effective != "inherit" else "ambient_unverified",
    "risk_signals": proposal.get("risk_signals", request.get("risk_signals", [])),
}
if request.get("parent_run_id") is not None: record["parent_run_id"] = request["parent_run_id"]
if request.get("agent_id") is not None: record["agent_id"] = request["agent_id"]
if event_name == "agent_started":
    record["owner_pid"] = int(owner_pid)
    record["timeout_s"] = int(request["timeout_s"])
    if handle: record["backend_handle"] = int(handle) if handle.isdigit() else handle
    if status_path: record["status_path"] = status_path
if event_name in {"completed", "failed", "timed_out", "cancelled", "abandoned"}:
    record["terminal_status"] = event_name
    if event_name == "failed": record["error_class"] = error_class or "provider_launch_failed"
print(json.dumps({key:value for key,value in record.items() if value is not None}, sort_keys=True, separators=(",", ":")))
' "$event" "$request" "$decision" "$handle" "$status_path" "$rc" "$error_class" "$owner_pid"
}

_uberdev_agent_append_event() {
  local manifest="$1" event_json="$2"
  python3 -I "$_UBERDEV_AGENT_MANIFEST_TOOL" append --manifest "$manifest" --event-json "$event_json" >/dev/null
}

_uberdev_agent_status_terminal_event() {
  local status_path="$1" backend="$2" handle="${3:-}" event
  event="$(python3 -I "$_UBERDEV_AGENT_MANIFEST_TOOL" probe-terminal \
    --status-path "$status_path" --expected-backend "$backend" \
    --expected-handle "$handle" 2>/dev/null)" || return 1
  case "$event" in
    completed|failed|timed_out|cancelled) printf '%s' "$event" ;;
    *) return 1 ;;
  esac
}

_uberdev_agent_publish_status() {
  local status_path="$1" backend="$2" handle="$3" state="$4" exit_code="${5:-}" mode="${6:-replace}" process_identity="${7:-}" lease_generation="${8:-}"
  python3 -I -c '
import json, os, stat, sys, tempfile
path, backend, handle, state, exit_code, mode, process_identity, lease_generation = sys.argv[1:]
parent = os.path.dirname(path)
if not os.path.isdir(parent):
    raise SystemExit(2)
payload = {"backend": backend, "state": state, "exit_code": int(exit_code) if exit_code else None, "pid": handle}
if process_identity: payload["process_identity"] = process_identity
if lease_generation: payload["lease_generation"] = lease_generation
fd, temporary = tempfile.mkstemp(prefix=".agent-status.", dir=parent)
try:
    if os.name != "nt":
        os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        fd = None
        json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    if mode == "create":
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            entry = os.lstat(path)
            if (stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode)
                    or (getattr(os,"geteuid",None) is not None and entry.st_uid != getattr(os,"geteuid")()) or entry.st_nlink != 1
                    or (os.name != "nt" and stat.S_IMODE(entry.st_mode) != 0o600)):
                raise SystemExit(2)
            replace = entry.st_size == 0
            if not replace:
                with open(path, "r", encoding="utf-8") as existing_stream:
                    existing = json.load(existing_stream)
                replace = (existing.get("state") == "running"
                           and existing.get("backend") == backend
                           and existing.get("pid") in (None, "", handle, int(handle) if handle.isdigit() else handle))
            current = os.stat(path, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (entry.st_dev, entry.st_ino):
                raise SystemExit(2)
            if replace:
                os.replace(temporary, path)
    else:
        if os.path.lexists(path) and stat.S_ISLNK(os.lstat(path).st_mode):
            raise SystemExit(2)
        os.replace(temporary, path)
finally:
    if fd is not None:
        os.close(fd)
    if os.path.exists(temporary):
        os.unlink(temporary)
' "$status_path" "$backend" "$handle" "$state" "$exit_code" "$mode" "$process_identity" "$lease_generation"
}

_uberdev_agent_process_identity() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  python3 -I -B - "$pid" <<'PY'
import hashlib,os,subprocess,sys
pid=int(sys.argv[1])
try:
 pgid=os.getpgid(pid); sid=os.getsid(pid)
 started=subprocess.check_output(["ps","-o","lstart=","-p",str(pid)],text=True,stderr=subprocess.DEVNULL).strip()
 if not started: raise ValueError()
 print(f"{pid}|{pgid}|{sid}|{hashlib.sha256(started.encode()).hexdigest()}",end="")
except Exception: raise SystemExit(1)
PY
}

_uberdev_agent_claude_probe() {
  local handle="$1" match_mode="${2:-prefix}"
  case "$match_mode" in prefix|exact) ;; *) return 2 ;; esac
  # Completed Claude sessions are omitted from the default view. Query the
  # full provider inventory so a terminal child cannot look absent merely
  # because it left the live-only list.
  claude agents --all --json 2>/dev/null | python3 -I -c '
import json, sys
session_id,match_mode = sys.argv[1:]
try:
    rows = json.load(sys.stdin)
except (ValueError, UnicodeError):
    raise SystemExit(2)
if not isinstance(rows, list):
    raise SystemExit(2)
matched = [row for row in rows if isinstance(row, dict) and isinstance(row.get("sessionId"), str)
           and (row["sessionId"] == session_id if match_mode == "exact" else row["sessionId"].startswith(session_id))]
if not matched:
    print("absent", end="")
    raise SystemExit(0)
if len(matched) != 1:
    raise SystemExit(2)
status = str(matched[0].get("status") or "").strip().lower()
state = str(matched[0].get("state") or "").strip().lower()
reason = " ".join(str(matched[0].get(key) or "") for key in ("blockedReason", "reason", "message")).lower()
if state == "blocked":
    print("blocked:permission" if "permission" in reason else "blocked:provider", end="")
    raise SystemExit(0)
lifecycle = state or status
if lifecycle == "idle":
    print("blocked:permission", end="")
elif lifecycle in {"busy", "running", "starting", "working", "queued"}:
    print("live", end="")
elif lifecycle in {"failed", "error"}:
    print("failed", end="")
elif lifecycle in {"timed_out", "timeout"}:
    print("timed_out", end="")
elif lifecycle in {"cancelled", "canceled", "stopped"}:
    print("cancelled", end="")
elif lifecycle in {"completed", "complete", "done", "finished"}:
    print("completed", end="")
else:
    raise SystemExit(2)
' "$handle" "$match_mode"
}

_uberdev_agent_lease_identity() {
  local lease="$1"
  python3 -I -c '
import os, stat, sys
path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    current = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        raise SystemExit(2)
    payload = os.read(descriptor, 65537)
    if len(payload) > 65536:
        raise SystemExit(2)
finally:
    os.close(descriptor)
try:
    rows = dict(line.split("=", 1) for line in payload.decode("utf-8").splitlines())
except (UnicodeError, ValueError):
    raise SystemExit(2)
generation = rows.get("generation", "")
if len(generation) != 32 or any(ch not in "0123456789abcdef" for ch in generation):
    raise SystemExit(2)
print(f"{opened.st_dev}:{opened.st_ino}:{generation}", end="")
' "$lease"
}

_uberdev_agent_release_exact_lease() {
  local lease="$1" identity="$2" scope rc
  _uberdev_semaphore_validate_lease_path "$lease" || return 2
  scope="$(dirname "$lease")"
  _uberdev_semaphore_mutex_acquire "$scope" || return $?
  python3 -I -c '
import os, stat, sys
path, identity = sys.argv[1:]
try:
    expected_device, expected_inode, expected_generation = identity.split(":", 2)
    expected = (int(expected_device), int(expected_inode))
except (TypeError, ValueError):
    raise SystemExit(2)
parent, name = os.path.dirname(path), os.path.basename(path)
parent_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
descriptor = None
try:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        raise SystemExit(0)
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != expected:
        raise SystemExit(3)
    payload = os.read(descriptor, 65537)
    if len(payload) > 65536:
        raise SystemExit(2)
    try:
        rows = dict(line.split("=", 1) for line in payload.decode("utf-8").splitlines())
    except (UnicodeError, ValueError):
        raise SystemExit(2)
    if rows.get("generation") != expected_generation:
        raise SystemExit(3)
    current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != expected:
        raise SystemExit(3)
    os.unlink(name, dir_fd=parent_descriptor)
finally:
    if descriptor is not None:
        os.close(descriptor)
    os.close(parent_descriptor)
' "$lease" "$identity"
  rc=$?
  _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
    [ "$rc" -ne 0 ] || rc=2
  }
  return "$rc"
}

_uberdev_agent_manifest_terminal_matches() {
  local manifest="$1" request_json="$2" expected="$3"
  python3 -I -c '
import json, pathlib, sys
manifest, request_raw, expected = sys.argv[1:]
request = json.loads(request_raw)
identity = (request["run_id"], request.get("agent_id"))
terminals = []
for line in pathlib.Path(manifest).read_text(encoding="utf-8").splitlines():
    event = json.loads(line)
    if (event.get("run_id"), event.get("agent_id")) != identity:
        continue
    if event.get("event") in {"completed", "failed", "timed_out", "cancelled", "abandoned"}:
        terminals.append(event.get("event"))
if terminals != [expected]:
    raise SystemExit(1)
' "$manifest" "$request_json" "$expected"
}

_uberdev_agent_manifest_started_matches() {
  local manifest="$1" request_json="$2"
  python3 -I -c '
import json, pathlib, sys
manifest, request_raw = sys.argv[1:]
request = json.loads(request_raw)
identity = (request["run_id"], request.get("agent_id"))
started = []
for line in pathlib.Path(manifest).read_text(encoding="utf-8").splitlines():
    event = json.loads(line)
    if (event.get("run_id"), event.get("agent_id")) == identity and event.get("event") == "agent_started":
        started.append(event)
if len(started) != 1:
    raise SystemExit(1)
' "$manifest" "$request_json"
}

_uberdev_agent_finalize_terminal() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" backend="$5" handle="$6"
  local request_json="$7" decision="$8" terminal_event="$9" terminal_rc event_json
  case "$terminal_event" in
    completed) terminal_rc=0 ;;
    failed|timed_out|cancelled|abandoned) terminal_rc=1 ;;
    *) return 2 ;;
  esac
  local published
  published="$(_uberdev_agent_status_terminal_event "$status_file" "$backend" "$handle" 2>/dev/null || true)"
  if [ "$published" != "$terminal_event" ]; then
    _uberdev_agent_publish_status "$status_file" "$backend" "$handle" "$terminal_event" "$terminal_rc" replace || return 2
  fi
  event_json="$(_uberdev_agent_event_json "$terminal_event" "$request_json" "$decision" "$handle" "$status_file" "$terminal_rc" "${10:-}")" || return 2
  if ! _uberdev_agent_append_event "$manifest" "$event_json"; then
    _uberdev_agent_manifest_terminal_matches "$manifest" "$request_json" "$terminal_event" || return 2
  fi
  PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity"
}

_uberdev_agent_persist_watcher_error() {
  local status_file="$1" backend="$2" handle="$3" terminal="$4" attempts="$5"
  local target="${6:-$status_file.watcher-error.json}" reason="${7:-}"
  python3 -I -B - "$target" "$backend" "$handle" "$terminal" "$attempts" "$reason" <<'PY'
import json,os,stat,sys,tempfile
path,backend,handle,terminal,attempts,*optional_reason=sys.argv[1:]
reason=optional_reason[0] if optional_reason else ''
parent=os.path.dirname(path)
entry=os.stat(parent,follow_symlinks=False)
uid_fn=getattr(os,"geteuid",None); uid=uid_fn() if uid_fn else None
if not stat.S_ISDIR(entry.st_mode) or (uid is not None and entry.st_uid!=uid): raise SystemExit(2)
if terminal == "provider_probe_failed": error="provider_probe_failed"
elif terminal.startswith("blocked:"): error="provider_cancel_failed"
elif terminal.startswith("launch:"): error="launch_finalize_failed"
else: error="terminal_finalize_failed"
allowed_reasons={"provider_stop_failed","provider_session_resolution_failed","provider_cancel_probe_failed","provider_cancel_unconfirmed","lease_acquire_invalid_input","lease_acquire_runtime_state_failed","lease_acquire_mutex_failed","lease_acquire_reconcile_failed","lease_acquire_duplicate_check_failed","lease_acquire_allocate_failed","lease_acquire_owner_failed","lease_acquire_publish_failed","lease_acquire_identity_failed","lease_acquire_rollback_failed","lease_acquire_mutex_release_failed","lease_handle_rollback_failed"}
payload={"schema_version":1,"error":error,"backend":backend,"handle":handle,"terminal":terminal,"attempts":int(attempts)}
if reason: payload["reason"]=reason if reason in allowed_reasons else "supervisory_failure"
fd,tmp=tempfile.mkstemp(prefix=".watcher-error.",dir=parent)
try:
 if os.name!="nt": os.fchmod(fd,0o600)
 with os.fdopen(fd,"w",encoding="utf-8") as stream:
  fd=None
  json.dump(payload,stream,sort_keys=True,separators=(",",":")); stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
 os.replace(tmp,path)
finally:
 if fd is not None: os.close(fd)
 if os.path.exists(tmp): os.unlink(tmp)
PY
}

_uberdev_agent_persist_watcher_error_retry() {
  local status_file="$1" fallback_file="$2" backend="$3" handle="$4" terminal="$5" attempts="$6"
  local reason="${7:-}" attempt=1
  while [ "$attempt" -le 3 ]; do
    _uberdev_agent_persist_watcher_error "$status_file" "$backend" "$handle" "$terminal" "$attempts" '' "$reason" && return 0
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  attempt=1
  while [ "$attempt" -le 3 ]; do
    _uberdev_agent_persist_watcher_error "$status_file" "$backend" "$handle" "$terminal" "$attempts" "$fallback_file" "$reason" && return 0
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  return 2
}

_uberdev_agent_start_watcher() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" backend="$5" handle="$6" request_json="$7" decision="$8"
  local watcher_pid watcher_instance watcher_fallback
  watcher_instance="$(_uberdev_agent_json_get "$request_json" run_id)" || return 2
  watcher_fallback="$(dirname "$manifest")/$watcher_instance.watcher-error.json"
  (
    local terminal_event='' probe='' absent_count=0 indeterminate_count=0 event_json='' error_class='' cancel_attempt=0 cancel_rc=0 cancel_reason='' supervision_reported=0
    while [ -d "$(dirname "$status_file")" ]; do
      terminal_event="$(_uberdev_agent_status_terminal_event "$status_file" "$backend" "$handle" 2>/dev/null || true)"
      [ -z "$terminal_event" ] || break
      if [ "$backend" = claude-bg ]; then
        probe="$(_uberdev_agent_claude_probe "$handle" 2>/dev/null || true)"
        case "$probe" in
          live) absent_count=0; indeterminate_count=0 ;;
          completed|failed|timed_out|cancelled) terminal_event="$probe"; break ;;
          blocked:permission|blocked:provider)
            # A blocked Claude session is still provider-owned live state. Stop
            # it and require the backend cancellation probe to confirm that the
            # handle is no longer live before terminalizing or releasing its
            # lease. A transient stop failure is retried in-place; exhaustion
            # publishes one durable error, then this watcher keeps passively
            # probing without reissuing stop so delayed provider convergence can
            # still finalize the lifecycle and release exact capacity.
            if [ "$supervision_reported" -eq 0 ]; then
              cancel_attempt=1
              while [ "$cancel_attempt" -le 3 ]; do
                if _uberdev_dispatch_cancel_backend claude-bg "$handle" ''; then
                  terminal_event=failed
                  [ "$probe" = blocked:permission ] && error_class=provider_permission_blocked || error_class=provider_blocked
                  break
                else
                  cancel_rc=$?
                fi
                cancel_reason="${_UBERDEV_DISPATCH_CANCEL_REASON:-provider_cancel_unconfirmed}"
                [ "$cancel_rc" -eq 2 ] && [ "$cancel_reason" = provider_stop_failed ] || break
                [ "$cancel_attempt" -ge 3 ] || sleep 0.1
                cancel_attempt=$((cancel_attempt + 1))
              done
              [ -z "$terminal_event" ] || break
              if ! _uberdev_agent_persist_watcher_error_retry "$status_file" "$watcher_fallback" "$backend" "$handle" "$probe" 3 "$cancel_reason"; then
                _uberdev_agent_error "failed to persist provider cancellation failure: $status_file"
                exit 70
              fi
              supervision_reported=1
            fi
            ;;
          absent)
            indeterminate_count=0
            absent_count=$((absent_count + 1))
            if [ "$absent_count" -ge 3 ]; then
              terminal_event=failed
              break
            fi
            ;;
          *)
            absent_count=0
            indeterminate_count=$((indeterminate_count + 1))
            if [ "$indeterminate_count" -ge 3 ]; then
              if [ "$supervision_reported" -eq 0 ]; then
                if _uberdev_agent_persist_watcher_error_retry "$status_file" "$watcher_fallback" "$backend" "$handle" provider_probe_failed "$indeterminate_count"; then
                  supervision_reported=1
                else
                  _uberdev_agent_error "failed to persist provider probe failure: $status_file"
                fi
                if _uberdev_dispatch_cancel_backend claude-bg "$handle" ''; then
                  terminal_event=failed
                  error_class=provider_probe_failed
                  break
                fi
              fi
              indeterminate_count=0
            fi
            ;;
        esac
      else
        case "$handle" in
          ''|*[!0-9]*) ;;
          *)
            if ! kill -0 "$handle" 2>/dev/null; then
              absent_count=$((absent_count + 1))
              if [ "$absent_count" -ge 3 ]; then
                terminal_event=failed
                break
              fi
            else
              absent_count=0
            fi
            ;;
        esac
      fi
      sleep 1
    done
    [ -n "$terminal_event" ] || exit 0
    local finalize_attempt=1
    [ "$terminal_event" != failed ] || [ -n "$error_class" ] || error_class=provider_execution_failed
    while [ "$finalize_attempt" -le 3 ]; do
      if _uberdev_agent_finalize_terminal "$manifest" "$lease" "$lease_identity" "$status_file" \
          "$backend" "$handle" "$request_json" "$decision" "$terminal_event" "$error_class"; then
        exit 0
      fi
      [ "$finalize_attempt" -ge 3 ] || sleep 0.1
      finalize_attempt=$((finalize_attempt + 1))
    done
    _uberdev_agent_persist_watcher_error_retry "$status_file" "$watcher_fallback" "$backend" "$handle" "$terminal_event" 3 || \
      _uberdev_agent_error "failed to persist watcher terminal failure: $status_file"
    exit 2
  ) </dev/null >/dev/null &
  watcher_pid="$!"
  disown "$watcher_pid" 2>/dev/null || true
}

_uberdev_agent_finalize_launch_failure() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" backend="$5"
  local request_json="$6" decision="$7" rc="$8" reason="$9"
  local attempt=1 event_json persisted=0 released=0 error_class=dispatch_setup_failed
  [ "$reason" != provider_launch ] || error_class=provider_launch_failed
  while [ "$attempt" -le 3 ]; do
    event_json="$(_uberdev_agent_event_json failed "$request_json" "$decision" '' "$status_file" "$rc" "$error_class" 2>/dev/null || true)"
    if [ -n "$event_json" ] && { _uberdev_agent_append_event "$manifest" "$event_json" || \
        _uberdev_agent_manifest_terminal_matches "$manifest" "$request_json" failed; }; then
      persisted=1
      break
    fi
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$persisted" -eq 1 ]; then
    attempt=1
    while [ "$attempt" -le 3 ]; do
      if PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity"; then
        released=1
        break
      fi
      [ "$attempt" -ge 3 ] || sleep 0.1
      attempt=$((attempt + 1))
    done
  fi
  if [ "$persisted" -eq 1 ] && [ "$released" -eq 1 ]; then
    return 0
  fi
  _uberdev_agent_persist_watcher_error "$status_file" "$backend" '' "launch:$reason" 3 || \
    _uberdev_agent_error "failed to persist launch finalization error: $reason"
  return 2
}

_uberdev_agent_finalize_prelaunch_failure() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" backend="$5"
  local request_json="$6" decision="$7" reason="$8"
  local event_json started_json attempt=1 started_persisted=0 status_persisted=0 terminal_persisted=0 released=0
  local run_id fallback_file
  run_id="$(_uberdev_agent_json_get "$request_json" run_id)" || return 2
  fallback_file="$(dirname "$manifest")/$run_id.watcher-error.json"
  while [ "$attempt" -le 3 ]; do
    started_json="$(_uberdev_agent_event_json agent_started "$request_json" "$decision" '' "$status_file" 2>/dev/null || true)"
    if [ -n "$started_json" ] && { _uberdev_agent_append_event "$manifest" "$started_json" || \
        _uberdev_agent_manifest_started_matches "$manifest" "$request_json"; }; then
      started_persisted=1
      break
    fi
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if _uberdev_agent_publish_status "$status_file" "$backend" '' failed 70 replace; then
      status_persisted=1
      break
    fi
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  attempt=1
  while [ "$attempt" -le 3 ]; do
    event_json="$(_uberdev_agent_event_json failed "$request_json" "$decision" '' "$status_file" 70 dispatch_setup_failed 2>/dev/null || true)"
    if [ -n "$event_json" ] && { _uberdev_agent_append_event "$manifest" "$event_json" || \
        _uberdev_agent_manifest_terminal_matches "$manifest" "$request_json" failed; }; then
      terminal_persisted=1
      break
    fi
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity"; then
      released=1
      break
    fi
    [ "$attempt" -ge 3 ] || sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$started_persisted" -eq 1 ] && [ "$status_persisted" -eq 1 ] \
      && [ "$terminal_persisted" -eq 1 ] && [ "$released" -eq 1 ]; then
    return 0
  fi
  _uberdev_agent_persist_watcher_error_retry "$status_file" "$fallback_file" "$backend" '' "launch:$reason" 3 || \
    _uberdev_agent_error "failed to persist pre-launch supervisory error: $reason"
  _uberdev_agent_error "pre-launch finalization failed: $reason"
  return 2
}

_uberdev_agent_abort_after_launch() {
  local manifest="$1" lease="$2" lease_identity="$3" status_file="$4" result_file="$5" backend="$6" handle="$7" request_json="$8" decision="$9" reason="${10}"
  local process_identity terminal_event cleanup_rc=0 fallback_file run_id provider_gone=0 cancel_rc=0
  run_id="$(_uberdev_agent_json_get "$request_json" run_id 2>/dev/null || true)"
  fallback_file="$(dirname "$manifest")/${run_id:-post-launch}.watcher-error.json"
  _UBERDEV_DISPATCH_CANCEL_REASON=''
  terminal_event="$(_uberdev_agent_status_terminal_event "$status_file" "$backend" "$handle" 2>/dev/null || true)"
  if [ -n "$terminal_event" ]; then
    if ! _uberdev_agent_finalize_terminal "$manifest" "$lease" "$lease_identity" "$status_file" \
        "$backend" "$handle" "$request_json" "$decision" "$terminal_event" dispatch_setup_failed; then
      _uberdev_agent_persist_watcher_error_retry "$status_file" "$fallback_file" "$backend" "$handle" "$terminal_event" 1 || \
        _uberdev_agent_error "failed to persist post-launch terminal finalization error: $reason"
    fi
    _uberdev_agent_error "post-launch setup failed after provider terminal: $reason"
    return 2
  fi
  process_identity="$(_uberdev_agent_process_identity "$handle" 2>/dev/null || true)"
  case "$backend" in
    codex|background)
      if [ -n "$process_identity" ]; then
        _uberdev_dispatch_cancel_backend "$backend" "$handle" "$process_identity" || cancel_rc=$?
      else
        case "$handle" in
          ''|*[!0-9]*) cancel_rc=2 ;;
          *) kill -0 "$handle" 2>/dev/null && cancel_rc=2 || provider_gone=1 ;;
        esac
      fi
      ;;
    *) _uberdev_dispatch_cancel_backend "$backend" "$handle" "$process_identity" || cancel_rc=$? ;;
  esac
  if [ "$cancel_rc" -ne 0 ]; then
    _uberdev_agent_persist_watcher_error_retry "$status_file" "$fallback_file" "$backend" "$handle" failed 1 \
      "${_UBERDEV_DISPATCH_CANCEL_REASON:-provider_cancel_unconfirmed}" || \
      _uberdev_agent_error "failed to persist post-launch cancellation error: $reason"
    return 2
  fi
  if [ "$backend" = background ] && { [ "$provider_gone" -eq 1 ] || [ -n "$process_identity" ]; }; then
    _uberdev_dispatch_cleanup_dead_partial_result "$result_file" "$handle" || cleanup_rc=2
  fi
  _uberdev_agent_finalize_terminal "$manifest" "$lease" "$lease_identity" "$status_file" \
    "$backend" "$handle" "$request_json" "$decision" failed dispatch_setup_failed || cleanup_rc=2
  if [ "$cleanup_rc" -ne 0 ]; then
    _uberdev_agent_persist_watcher_error_retry "$status_file" "$fallback_file" "$backend" "$handle" failed 1 || \
      _uberdev_agent_error "failed to persist post-launch cleanup error: $reason"
  fi
  _uberdev_agent_error "post-launch setup failed: $reason"
  return 2
}

uberdev_agent_dispatch() {
  local request_json="${1:-}" prompt_requested="${2:-}" result_requested="${3:-}" status_requested="${4:-}"
  local run_dir run_id repository_id backend workflow issue_num tier capacity timeout_s workspace_mode workspace_dir
  local prompt_file result_file status_file state_dir manifest decision lease lease_record lease_identity registered_identity event_json rc handle lease_handle terminal_event paths_json lease_failure_reason cleanup_identity
  local context_file context_sha context_validation persisted_decision supplied_root supplied_parent context_run_id parent_run_id agent_id process_identity lease_generation
  [ "$#" -eq 4 ] || { _uberdev_agent_error 'expected REQUEST_JSON PROMPT_FILE RESULT_FILE STATUS_FILE'; return 2; }
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt localoptions nullglob || return 2
  fi
  command -v python3 >/dev/null 2>&1 || { _uberdev_agent_error 'python3 is required'; return 2; }
  [ -r "$_UBERDEV_AGENT_ROUTER" ] && [ -r "$_UBERDEV_AGENT_POLICY" ] && [ -r "$_UBERDEV_AGENT_MANIFEST_TOOL" ] || {
    _uberdev_agent_error 'routing runtime is incomplete'; return 2;
  }
  issue_num="$(_uberdev_agent_validate_issue_identity "$request_json")" || {
    _uberdev_agent_error 'invalid issue identity'; return 2;
  }
  run_dir="$(_uberdev_agent_json_get "$request_json" run_dir)" || { _uberdev_agent_error 'invalid run_dir'; return 2; }
  run_dir="$(_uberdev_agent_validate_run_dir "$run_dir")" || { _uberdev_agent_error 'unsafe run_dir'; return 2; }
  state_dir="$run_dir/.agent-state-$(python3 -I -c 'import os; f=getattr(os,"geteuid",None); print(f() if f else 0)')" || return 2
  paths_json="$(_uberdev_agent_validate_paths "$run_dir" "$state_dir" "$prompt_requested" "$result_requested" "$status_requested")" || {
    _uberdev_agent_error 'unsafe or aliased caller paths'; return 2;
  }
  prompt_file="$(_uberdev_agent_json_get "$paths_json" prompt)" || return 2
  result_file="$(_uberdev_agent_json_get "$paths_json" result)" || return 2
  status_file="$(_uberdev_agent_json_get "$paths_json" status)" || return 2
  run_id="$(_uberdev_agent_json_get "$request_json" run_id)" || { _uberdev_agent_error 'invalid run_id'; return 2; }
  repository_id="$(_uberdev_agent_json_get "$request_json" repository_id)" || { _uberdev_agent_error 'invalid repository_id'; return 2; }
  backend="$(_uberdev_agent_json_get "$request_json" backend)" || { _uberdev_agent_error 'invalid backend'; return 2; }
  workflow="$(_uberdev_agent_json_get "$request_json" workflow)" || { _uberdev_agent_error 'invalid workflow'; return 2; }
  if [ "$backend" = claude-bg ]; then
    # Production child dispatch sources lib/dispatch.sh, whose resolver binds
    # the model, timeout, permission, and effort argv consumed by claude-bg.
    # Keep the adapter independently sourceable for provider-stub unit tests.
    if command -v uberdev_dispatch_resolve_env >/dev/null 2>&1; then
      uberdev_dispatch_resolve_env claude-bg || return $?
    fi
    _uberdev_agent_claude_permissions_preflight "$workflow" || return $?
  fi
  tier="$(_uberdev_agent_json_get "$request_json" task_tier)" || { _uberdev_agent_error 'invalid task_tier'; return 2; }
  capacity="$(_uberdev_agent_json_get "$request_json" capacity)" || { _uberdev_agent_error 'invalid capacity'; return 2; }
  timeout_s="$(_uberdev_agent_json_get "$request_json" timeout_s)" || { _uberdev_agent_error 'invalid timeout_s'; return 2; }
  workspace_mode="$(_uberdev_agent_json_get "$request_json" workspace_mode 2>/dev/null || printf isolated)"
  workspace_dir="$(_uberdev_agent_json_get "$request_json" workspace_dir 2>/dev/null || true)"

  decision="$(uberdev_agent_resolve_request "$request_json")" || return $?
  context_file="$(_uberdev_agent_json_get "$request_json" context_file 2>/dev/null || true)"
  context_sha="$(_uberdev_agent_json_get "$request_json" context_sha256 2>/dev/null || true)"
  supplied_root="$(python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]).get("root_decision"); print(json.dumps(v,sort_keys=True,separators=(",",":")),end="") if v is not None else None' "$request_json")" || return 2
  if [ -n "$context_file$context_sha$supplied_root" ]; then
    if [ -z "$context_file" ] || [ -z "$context_sha" ] || [ -z "$supplied_root" ]; then
      _uberdev_agent_error 'route_context_mismatch'; return 2
    fi
    context_validation="$(uberdev_agent_context_validate "$context_file" "$context_sha" "$run_dir")" || {
      _uberdev_agent_error 'route_context_mismatch'; return 2;
    }
    persisted_decision="$(python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["root_decision"],sort_keys=True,separators=(",",":")),end="")' "$context_validation")" || return 2
    if [ "$persisted_decision" != "$supplied_root" ]; then
      _uberdev_agent_error 'route_context_mismatch'; return 2
    fi
    parent_run_id="$(_uberdev_agent_json_get "$request_json" parent_run_id 2>/dev/null || true)"
    agent_id="$(_uberdev_agent_json_get "$request_json" agent_id 2>/dev/null || true)"
    if [ -n "$parent_run_id$agent_id" ]; then
      [ -n "$parent_run_id" ] && [ -n "$agent_id" ] || { _uberdev_agent_error 'route_context_mismatch'; return 2; }
      context_run_id="$(_uberdev_agent_json_get "$context_validation" run_id 2>/dev/null || true)"
      supplied_parent="$(python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]).get("parent_run"); print(json.dumps(v,sort_keys=True,separators=(",",":")),end="") if v is not None else None' "$request_json")" || return 2
      if [ "$parent_run_id" != "$context_run_id" ] || [ "$supplied_parent" != "$persisted_decision" ]; then
        _uberdev_agent_error 'route_context_mismatch'; return 2
      fi
    elif [ "$decision" != "$persisted_decision" ]; then
      _uberdev_agent_error 'route_context_mismatch'; return 2
    fi
  fi

  state_dir="$(_uberdev_agent_prepare_state_dir "$run_dir")" || {
    _uberdev_agent_error 'unsafe agent state directory'; return 2;
  }
  manifest="$state_dir/agent-lifecycle.jsonl"

  event_json="$(_uberdev_agent_event_json route_decided "$request_json" "$decision")" || return 2
  _uberdev_agent_append_event "$manifest" "$event_json" || return 2

  lease_record=''
  if UBERDEV_SEMAPHORE_OWNER_PID=$$ PYTHONPATH= PYTHONHOME= uberdev_semaphore_acquire \
      "$state_dir" "$repository_id" "$backend" "$capacity" "$run_id" "$timeout_s" \
      exact-identity lease_record; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      lease_failure_reason="${_UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON:-lease_acquire_identity_failed}"
      case "$lease_failure_reason" in
        lease_acquire_invalid_input|lease_acquire_runtime_state_failed|lease_acquire_mutex_failed|lease_acquire_reconcile_failed|lease_acquire_duplicate_check_failed|lease_acquire_allocate_failed|lease_acquire_owner_failed|lease_acquire_publish_failed|lease_acquire_identity_failed|lease_acquire_rollback_failed|lease_acquire_mutex_release_failed) ;;
        *) lease_failure_reason=lease_acquire_identity_failed ;;
      esac
      _uberdev_agent_persist_watcher_error_retry "$status_file" "$state_dir/$run_id.watcher-error.json" \
        "$backend" '' launch:lease_identity 3 "$lease_failure_reason" || \
        _uberdev_agent_error 'failed to persist lease acquisition identity error'
      case "$lease_record" in
        *$'\t'*)
          lease="${lease_record%%$'\t'*}"
          lease_identity="${lease_record#*$'\t'}"
          PYTHONPATH= PYTHONHOME= _uberdev_agent_release_exact_lease "$lease" "$lease_identity" >/dev/null 2>&1 || true
          ;;
      esac
    fi
    return "$rc"
  fi
  case "$lease_record" in
    *$'\t'*) lease="${lease_record%%$'\t'*}"; lease_identity="${lease_record#*$'\t'}" ;;
    *) lease=''; lease_identity='' ;;
  esac
  if [ -z "$lease" ] || [ -z "$lease_identity" ]; then
    _uberdev_agent_persist_watcher_error_retry "$status_file" "$state_dir/$run_id.watcher-error.json" \
      "$backend" '' launch:lease_identity 3 lease_acquire_identity_failed || \
      _uberdev_agent_error 'failed to persist malformed lease acquisition identity'
    DISPATCH_RC=2
    return 2
  fi

  # Register the canonical status path before the launch boundary.  It may be
  # absent until an opaque provider publishes its first probe; absence is
  # intentionally "unknown", never synthetic evidence that a backend is live.
  registered_identity=''
  if ! PYTHONPATH= PYTHONHOME= uberdev_semaphore_set_handle "$lease" '' "$status_file" exact-identity registered_identity; then
    rc=2
    cleanup_identity="${registered_identity:-$lease_identity}"
    _uberdev_agent_finalize_prelaunch_failure "$manifest" "$lease" "$cleanup_identity" "$status_file" "$backend" \
      "$request_json" "$decision" lease_identity || true
    DISPATCH_RC="$rc"
    return "$rc"
  fi
  if [ -z "$registered_identity" ]; then
    _uberdev_agent_finalize_prelaunch_failure "$manifest" "$lease" "$lease_identity" "$status_file" "$backend" \
      "$request_json" "$decision" lease_identity || true
    DISPATCH_RC=2
    return 2
  fi
  lease_identity="$registered_identity"

  event_json="$(_uberdev_agent_event_json agent_started "$request_json" "$decision" '' "$status_file")" || {
    _uberdev_agent_finalize_prelaunch_failure "$manifest" "$lease" "$lease_identity" "$status_file" "$backend" \
      "$request_json" "$decision" agent_started_event || true
    DISPATCH_RC=2
    return 2
  }
  if ! _uberdev_agent_append_event "$manifest" "$event_json"; then
    _uberdev_agent_finalize_prelaunch_failure "$manifest" "$lease" "$lease_identity" "$status_file" "$backend" \
      "$request_json" "$decision" agent_started_append || true
    DISPATCH_RC=2
    return 2
  fi

  UBERDEV_AGENT_DECISION_JSON="$decision"
  UBERDEV_AGENT_RESULT_FILE="$result_file"
  UBERDEV_AGENT_STATUS_FILE="$status_file"
  agent_id="$(_uberdev_agent_json_get "$request_json" agent_id 2>/dev/null || true)"
  UBERDEV_AGENT_INSTANCE_ID="${agent_id:-$run_id}"
  UBERDEV_AGENT_CHILD_OWNED=0
  [ -z "$agent_id" ] || UBERDEV_AGENT_CHILD_OWNED=1
  UBERDEV_AGENT_WORKSPACE_MODE="$workspace_mode"
  UBERDEV_AGENT_WORKSPACE_DIR="$workspace_dir"
  export UBERDEV_AGENT_DECISION_JSON UBERDEV_AGENT_RESULT_FILE UBERDEV_AGENT_STATUS_FILE UBERDEV_AGENT_INSTANCE_ID UBERDEV_AGENT_CHILD_OWNED
  export UBERDEV_AGENT_WORKSPACE_MODE UBERDEV_AGENT_WORKSPACE_DIR
  if _uberdev_agent_dispatch_backend "$backend" "$issue_num" "$tier" "$prompt_file" "$result_file" "$status_file" "$decision"; then
    rc=0
  else
    rc=$?
  fi
  handle="${DISPATCH_ID:-}"
  if [ "$rc" -ne 0 ] || [ -z "$handle" ]; then
    [ "$rc" -ne 0 ] || rc=1
    if [ -n "$handle" ]; then
      _uberdev_agent_abort_after_launch "$manifest" "$lease" "$lease_identity" "$status_file" "$result_file" \
        "$backend" "$handle" "$request_json" "$decision" provider_launch
      return $?
    fi
    if ! _uberdev_agent_finalize_launch_failure "$manifest" "$lease" "$lease_identity" "$status_file" \
        "$backend" "$request_json" "$decision" "$rc" provider_launch; then
      DISPATCH_RC=2
      return 2
    fi
    DISPATCH_RC="$rc"
    return "$rc"
  fi

  terminal_event="$(_uberdev_agent_status_terminal_event "$status_file" "$backend" "$handle" 2>/dev/null || true)"
  lease_handle="$handle"
  [ "$backend" != wezterm ] || lease_handle="pane:$handle"
  registered_identity="$lease_identity"
  lease_identity=''
  if ! PYTHONPATH= PYTHONHOME= uberdev_semaphore_set_handle "$lease" "$lease_handle" "$status_file" exact-identity lease_identity; then
    cleanup_identity="${lease_identity:-$registered_identity}"
    _uberdev_agent_abort_after_launch "$manifest" "$lease" "$cleanup_identity" "$status_file" "$result_file" \
      "$backend" "$handle" "$request_json" "$decision" lease_handle_update
    return $?
  fi
  if [ -z "$lease_identity" ]; then
    _uberdev_agent_abort_after_launch "$manifest" "$lease" "$registered_identity" "$status_file" "$result_file" \
      "$backend" "$handle" "$request_json" "$decision" lease_identity
    return $?
  fi
  lease_generation="${lease_identity##*:}"
  if [ -n "$terminal_event" ]; then
    _uberdev_agent_finalize_terminal "$manifest" "$lease" "$lease_identity" "$status_file" \
      "$backend" "$handle" "$request_json" "$decision" "$terminal_event" || return 2
  else
    process_identity="$(_uberdev_agent_process_identity "$handle" 2>/dev/null || true)"
    _uberdev_agent_publish_status "$status_file" "$backend" "$lease_handle" running '' create "$process_identity" "$lease_generation" || {
      _uberdev_agent_abort_after_launch "$manifest" "$lease" "$lease_identity" "$status_file" "$result_file" \
        "$backend" "$handle" "$request_json" "$decision" status_publication
      return $?
    }
    _uberdev_agent_start_watcher "$manifest" "$lease" "$lease_identity" "$status_file" "$backend" "$lease_handle" "$request_json" "$decision"
  fi
  DISPATCH_RC=0
  return 0
}

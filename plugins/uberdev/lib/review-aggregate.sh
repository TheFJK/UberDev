# review-aggregate.sh -- the Phase-1 evidence, aggregation and aggregate-writer
# functions, on disk.
#
# WHY THIS FILE EXISTS (#381). These three functions used to live only as
# markdown fence text inside skills/post-impl-review/SKILL.md. Every `bash`
# block in a command file is a FRESH shell (commands/review-pr.md:1301), so
# `Skill(uberdev:post-impl-review)` left nothing callable behind: a caller that
# ran its own reviewer fanout -- for example a Workflow-dispatched review stage
# driving skills/review-fleet/workflow.js -- had no way to reach the canonical
# aggregate builders at all, and no on-disk executable to invoke. That, not any
# property of the proofs themselves, was the blocker.
#
# Nothing here is weakened by the move. Both consumers source this file and get
# byte-identical behaviour:
#
#   - skills/post-impl-review/SKILL.md's `uberdev-executable` fence
#   - any calling session that has already resolved UBERDEV_REVIEW_PLUGIN_ROOT
#
# NO logging, NO git, NO gh, NO network. Every digest is computed here in the
# calling session from bytes read off disk, or inside
# lib/code_fixer_contract.py, which stays the sole binding authority. A relay
# agent must never compute one: the authority chain would silently degrade from
# *the controller proved it* to *an LLM said so* while every downstream equality
# check still looked correct.
#
# Callers must have these bound before the first call:
#   UBERDEV_REVIEW_PLUGIN_ROOT   plugin root (lib/run_manifest.py lives under it)
#   _UBERDEV_DISPATCH_BACKEND_ENUM  the dispatch backend policy alternation
#   UBERDEV_CARRIER_BACKEND      the carrier's resolved backend
#   REVIEW_EDGES                 the ordered roster array

post_review_validated_evidence_complete() {
  python3 -I -B - "$1" "$2" "$3" "$4" "$5" "$UBERDEV_REVIEW_PLUGIN_ROOT" \
    "$_UBERDEV_DISPATCH_BACKEND_ENUM" "$UBERDEV_CARRIER_BACKEND" "${REVIEW_EDGES[@]}" <<'PY'
import hashlib,importlib.util,json,os,re,stat,subprocess,sys,tempfile
ledger,expected,initial_ledger,repair_ledger,carrier_run_dir,plugin_root,backend_policy,expected_backend,*allowed=sys.argv[1:]; expected=int(expected)
def fail(reason,row=None):
 edge=(row or {}).get('edge','unknown')
 index=(row or {}).get('index','unknown')
 print(f'post_review_evidence_failure class={reason} edge={edge} index={index}',file=sys.stderr)
 raise SystemExit(2)
# The Workflow-native binding proof. A `workflow`-backend child is awaited
# in-process: it owns no pid, no process group and no lease, so the detached
# supervision triple this builder normally matches CANNOT exist -- and
# fabricating one would leave every equality below looking correct while
# proving nothing. The controller instead mints a single-use nonce BEFORE the
# Workflow call and the child echoes it into status.json.
#
# Proving that binding is lib/code_fixer_contract.py's job, not this builder's.
# It stays the sole binding authority, it is invoked here as a subprocess from
# the CALLING SESSION, and it is handed no digest -- it computes both itself
# from bytes it reads off disk, and this builder re-reads the same two files
# and requires the digests to agree.
CONTRACT=os.path.join(plugin_root,'lib','code_fixer_contract.py')
BOUND_CHILD_KEYS={'edge_id','instance_id','status_path','status_sha256','result_path','result_sha256'}
def capture_bound_child(binding,edge_id,row=None):
 if not isinstance(binding,str) or not binding or len(binding)>65536: fail('roster-mismatch',row)
 try:
  completed=subprocess.run([sys.executable,'-I','-B',CONTRACT,'capture-bound-child',
                            '--edge-id',edge_id,'--launch-binding-json',binding],
                           stdin=subprocess.DEVNULL,capture_output=True,timeout=120)
 except (OSError,ValueError,subprocess.SubprocessError): fail('unsafe-artifact',row)
 if completed.returncode!=0: fail('roster-mismatch',row)
 try: value=json.loads(completed.stdout.decode('utf-8'))
 except (UnicodeError,ValueError): fail('roster-mismatch',row)
 if (not isinstance(value,dict) or set(value)!=BOUND_CHILD_KEYS
     or value['edge_id']!=edge_id
     or not re.fullmatch(r'[0-9a-f]{64}',value['status_sha256'] or '')
     or not re.fullmatch(r'[0-9a-f]{64}',value['result_sha256'] or '')):
  fail('roster-mismatch',row)
 return value
def load_helper():
 spec=importlib.util.spec_from_file_location('uberdev_post_review_artifacts',os.path.join(plugin_root,'lib','run_manifest.py'))
 if spec is None or spec.loader is None: fail('unsafe-artifact')
 module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module
 try: spec.loader.exec_module(module)
 except Exception: fail('unsafe-artifact')
 return module
def capture(module,path,minimum,maximum,reason,row=None):
 try: return module.secure_capture_regular(path,minimum,maximum)
 except Exception: fail(reason,row)
def json_lines(payload):
 return [json.loads(line) for line in payload.decode('utf-8').splitlines() if line.strip()]
try:
 artifacts=load_helper()
 policy_backends=backend_policy.split('|')
 if (not policy_backends or any(not item for item in policy_backends)
     or len(policy_backends)!=len(set(policy_backends)) or 'auto' not in policy_backends):
  fail('roster-mismatch')
 allowed_backends=set(policy_backends); allowed_backends.remove('auto')
 if expected_backend not in allowed_backends: fail('roster-mismatch')
 carrier_run=os.path.realpath(carrier_run_dir)
 if not os.path.isabs(carrier_run_dir) or not os.path.isdir(carrier_run): fail('unsafe-artifact')
 carrier_entry=os.lstat(carrier_run)
 uid_fn=getattr(os,'geteuid',None); uid=uid_fn() if uid_fn else None
 if (stat.S_ISLNK(carrier_entry.st_mode) or not stat.S_ISDIR(carrier_entry.st_mode)
     or (uid is not None and carrier_entry.st_uid!=uid)): fail('unsafe-artifact')
 children_root=os.path.join(carrier_run,'children')
 # A ledger the wave never wrote, a well-formed ledger that is short of the
 # roster, and a ledger whose bytes are damaged demand three different
 # investigations, so they carry three different classes. An empty ledger is
 # therefore captured (floor 0) and classed by the roster check below rather
 # than rejected as corruption.
 if not os.path.lexists(ledger): fail('ledger-absent')
 ledger_payload=capture(artifacts,ledger,0,1048576,'malformed-ledger')[0]
 rows=json_lines(ledger_payload)
 launched=[]; launch_payloads=[]
 for source in (initial_ledger,repair_ledger):
  if source and os.path.lexists(source):
   source_payload=capture(artifacts,source,0,1048576,'malformed-ledger')[0]
   launch_payloads.append(source_payload); launched.extend(json_lines(source_payload))
 allowed_pairs={(edge,index) for index,edge in enumerate(allowed,1)}
 if len(rows)<expected: fail('incomplete-roster')
 if (len(rows)!=expected or len({row.get('edge') for row in rows})!=expected
     or len({row.get('index') for row in rows})!=expected
     or {(row.get('edge'),row.get('index')) for row in rows}!=allowed_pairs):
  fail('malformed-ledger')
 context=hashlib.sha256(ledger_payload+b'\0'+b'\0'.join(launch_payloads)).hexdigest()[:16]
 trusted_dir_base=os.path.abspath(ledger)+'.trusted-artifacts-'+context
 trusted_dir=tempfile.mkdtemp(prefix=os.path.basename(trusted_dir_base)+'.attempt-',
                              dir=os.path.dirname(trusted_dir_base))
 trusted_ledger_base=os.path.join(trusted_dir,'trusted-ledger.jsonl')
 trusted_dir_entry=os.lstat(trusted_dir)
 if (stat.S_ISLNK(trusted_dir_entry.st_mode) or not stat.S_ISDIR(trusted_dir_entry.st_mode)
     or (uid is not None and trusted_dir_entry.st_uid!=uid)): fail('unsafe-artifact')
 seen_provider_paths=set(); seen_paths=set(); seen_evidence=set(); trusted_rows=[]
 # One dispatcher per wave. A ledger that mixes receipt-shaped and
 # binding-shaped launch rows describes six children that did not come from one
 # fanout, and the whole point of this builder is that the aggregate covers ONE
 # complete roster. Recorded on the first row and enforced on every later one.
 launch_shape=None
 for row in rows:
  if set(row)!={'edge','index','instance','result','sha256'} or type(row['index']) is not int:
   fail('malformed-ledger',row)
  matches=[candidate for candidate in launched
           if candidate.get('edge')==row['edge']
           and candidate.get('index')==row['index']
           and candidate.get('instance')==row['instance']]
  if len(matches)!=1: fail('roster-mismatch',row)
  launch=matches[0]; launched_result=launch.get('result'); launched_status=launch.get('status')
  # Two launch-row shapes, one per dispatcher. `receipt` is the detached
  # transports (wezterm / background — codex was the third until #381 deleted
  # it), which issue a dispatch receipt and supervise by pid. `binding` is the
  # session's Workflow
  # tool, which issues neither -- see capture_bound_child above.
  if set(launch)=={'edge','index','instance','receipt','result','status'}: row_shape='receipt'
  elif set(launch)=={'edge','index','instance','binding','result','status'}: row_shape='binding'
  else: fail('roster-mismatch',row)
  if launch_shape is None: launch_shape=row_shape
  if row_shape!=launch_shape: fail('roster-mismatch',row)
  if isinstance(launched_result,str) and launched_result in seen_provider_paths:
   fail('duplicate-artifact',row)
  if isinstance(launched_result,str): seen_provider_paths.add(launched_result)
  expected_child=os.path.join(children_root,row['instance'])
  expected_provider=os.path.join(expected_child,'result.md')
  expected_status=os.path.join(expected_child,'status.json')
  if (not isinstance(launched_result,str) or not os.path.isabs(launched_result)
      or not isinstance(launched_status,str) or not os.path.isabs(launched_status)
      or launched_result!=expected_provider or launched_status!=expected_status
      or os.path.realpath(os.path.dirname(launched_result))!=expected_child):
   fail('unsafe-artifact',row)
  if row_shape=='binding':
   # The carrier's own backend still has to be the one that dispatched this
   # child; the binding shape does not exempt the wave from that equality, it
   # only changes what proves it.
   if expected_backend!='workflow': fail('roster-mismatch',row)
   captured=capture_bound_child(launch['binding'],row['edge'],row)
   if (captured['instance_id']!=row['instance']
       or captured['status_path']!=launched_status
       or captured['result_path']!=launched_result):
    fail('roster-mismatch',row)
   status_payload,status_identity=capture(artifacts,launched_status,1,65536,'roster-mismatch',row)
   provider_payload,provider_identity=capture(artifacts,launched_result,1,16777216,'unsafe-artifact',row)
   # Read twice, by two independent readers, and required to agree. A file
   # swapped between the contract's capture and this one fails closed here.
   if (hashlib.sha256(status_payload).hexdigest()!=captured['status_sha256']
       or hashlib.sha256(provider_payload).hexdigest()!=captured['result_sha256']):
    fail('digest-mismatch',row)
  else:
   try: receipt=json.loads(launch['receipt'])
   except (TypeError,json.JSONDecodeError): fail('roster-mismatch',row)
   receipt_keys={'schema_version','edge_id','instance_id','backend','handle','state','result_file','status_file'}
   if (not isinstance(receipt,dict) or set(receipt)!=receipt_keys or receipt.get('schema_version')!=1
       or receipt.get('edge_id')!=row['edge'] or receipt.get('instance_id')!=row['instance']
       or receipt.get('result_file')!=launched_result or receipt.get('status_file')!=launched_status
       or receipt.get('backend')!=expected_backend
       or not isinstance(receipt.get('handle'),str) or not receipt['handle']
       or receipt.get('state') not in {'running','completed'}):
    fail('roster-mismatch',row)
   status_payload,status_identity=capture(artifacts,launched_status,1,65536,'roster-mismatch',row)
   provider_payload,provider_identity=capture(artifacts,launched_result,1,16777216,'unsafe-artifact',row)
   status_value=json.loads(status_payload.decode('utf-8'))
   status_handle=status_value.get('pid')
   if (status_value.get('state')!='completed'
       or type(status_value.get('exit_code')) is not int or status_value['exit_code']!=0
       or status_value.get('backend')!=receipt['backend'] or status_handle is None
       or receipt['handle'] not in {str(status_handle),'pane:'+str(status_handle)}):
    fail('roster-mismatch',row)
  expected_result=os.path.join(expected_child,'validated-result.md')
  path=row['result']; digest=row['sha256']
  canonical_path=os.path.realpath(path)
  if (not os.path.isabs(path) or path!=expected_result or canonical_path!=path
      or not re.fullmatch(r'[0-9a-f]{64}',digest or '')):
   fail('unsafe-artifact',row)
  payload,identity=capture(artifacts,path,1,1048576,'unsafe-artifact',row)
  if os.name!='nt' and stat.S_IMODE(identity[5])!=0o400: fail('unsafe-artifact',row)
  evidence_key=(identity,hashlib.sha256(payload).hexdigest())
  provider_key=(provider_identity,hashlib.sha256(provider_payload).hexdigest())
  status_key=(status_identity,hashlib.sha256(status_payload).hexdigest())
  if len({identity,provider_identity,status_identity})!=3:
   fail('duplicate-artifact',row)
  if canonical_path in seen_paths or any(key in seen_evidence for key in (evidence_key,provider_key,status_key)):
   fail('duplicate-artifact',row)
  seen_paths.add(canonical_path); seen_evidence.update((evidence_key,provider_key,status_key))
  if evidence_key[1]!=digest:
   fail('digest-mismatch',row)
  snapshot_base=os.path.join(trusted_dir,f"{row['index']:02d}-{digest}.md")
  snapshot,snapshot_identity,snapshot_digest=artifacts.secure_publish_captured(snapshot_base,payload)
  captured_snapshot,captured_identity=artifacts.secure_capture_published(snapshot,digest,1,1048576)
  if (snapshot_digest!=digest or captured_snapshot!=payload
      or captured_identity!=snapshot_identity): fail('digest-mismatch',row)
  trusted_rows.append({'edge':row['edge'],'index':row['index'],'instance':row['instance'],
                       'result':snapshot,'sha256':digest})
 trusted_payload=(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n'
                          for row in trusted_rows)).encode('utf-8')
 trusted_ledger,trusted_ledger_identity,trusted_ledger_digest=artifacts.secure_publish_captured(
     trusted_ledger_base,trusted_payload)
 captured_ledger,captured_ledger_identity=artifacts.secure_capture_published(
     trusted_ledger,trusted_ledger_digest,1,1048576)
 if captured_ledger!=trusted_payload or captured_ledger_identity!=trusted_ledger_identity:
  fail('digest-mismatch')
 print(trusted_ledger,end='')
except SystemExit: raise
except (OSError,UnicodeError,ValueError,TypeError,json.JSONDecodeError):
 fail('malformed-ledger')
except Exception:
 fail('unsafe-artifact')
PY
}
post_review_capture_aggregation_inputs() {
  python3 -I -B - "$1" "$2" "$UBERDEV_REVIEW_PLUGIN_ROOT" <<'PY'
import hashlib,importlib.util,json,os,re,sys
ledger,expected_text,plugin_root=sys.argv[1:]
def fail(reason):
 print(f'post_review_aggregation_failure class={reason}',file=sys.stderr)
 raise SystemExit(1)
def closed_object(pairs):
 value={}
 for key,item in pairs:
  if key in value: raise ValueError('duplicate-key')
  value[key]=item
 return value
try:
 if re.fullmatch(r'[1-9][0-9]?',expected_text) is None:
  fail('malformed-ledger')
 expected=int(expected_text)
 spec=importlib.util.spec_from_file_location(
     'uberdev_review_aggregation_artifacts',os.path.join(plugin_root,'lib','run_manifest.py'))
 if spec is None or spec.loader is None: fail('unsafe-artifact')
 artifacts=importlib.util.module_from_spec(spec); sys.modules[spec.name]=artifacts
 spec.loader.exec_module(artifacts)
 if expected<1 or expected>64 or not os.path.isabs(ledger): fail('malformed-ledger')
 ledger_name=re.fullmatch(
     r'trusted-ledger\.jsonl\.attempt-[0-9a-f]{32}-([0-9a-f]{64})',
     os.path.basename(ledger))
 if ledger_name is None: fail('malformed-ledger')
 ledger_digest=ledger_name.group(1)
 ledger_payload,_=artifacts.secure_capture_published(
     ledger,ledger_digest,1,1048576)
 ledger_text=ledger_payload.decode('utf-8')
 lines=ledger_text.splitlines()
 if not ledger_text.endswith('\n') or not lines or any(not line for line in lines):
  fail('malformed-ledger')
 rows=[json.loads(line,object_pairs_hook=closed_object) for line in lines]
 allowed={
  'review_pr.review.correctness','review_pr.review.silent_failures',
  'review_pr.review.types','review_pr.review.comments',
  'review_pr.review.tests','review_pr.review.general',
  'review_pr.review.convention',
 }
 if len(rows)!=expected: fail('roster-mismatch')
 ledger_parent=os.path.dirname(os.path.abspath(ledger))
 seen_edges=set(); seen_indexes=set(); captured_rows=[]
 for row in rows:
  if (type(row) is not dict
      or set(row)!={'edge','index','instance','result','sha256'}
      or type(row['index']) is not int or isinstance(row['index'],bool)
      or row['index']<1 or row['index']>expected
      or row['index'] in seen_indexes
      or type(row['edge']) is not str or row['edge'] not in allowed
      or row['edge'] in seen_edges
      or type(row['instance']) is not str
      or re.fullmatch(r'[A-Za-z0-9._-]{1,128}',row['instance']) is None
      or type(row['result']) is not str or not os.path.isabs(row['result'])
      or os.path.dirname(os.path.abspath(row['result']))!=ledger_parent
      or type(row['sha256']) is not str
      or re.fullmatch(r'[0-9a-f]{64}',row['sha256']) is None):
   fail('malformed-ledger')
  snapshot_name=re.fullmatch(
      r'([0-9]{2})-([0-9a-f]{64})\.md\.attempt-[0-9a-f]{32}-([0-9a-f]{64})',
      os.path.basename(row['result']))
  if (snapshot_name is None or int(snapshot_name.group(1))!=row['index']
      or snapshot_name.group(2)!=row['sha256']
      or snapshot_name.group(3)!=row['sha256']):
   fail('digest-mismatch')
  snapshot,_=artifacts.secure_capture_published(
      row['result'],row['sha256'],1,1048576)
  content=snapshot.decode('utf-8')
  if '\x00' in content: fail('unsafe-artifact')
  seen_edges.add(row['edge']); seen_indexes.add(row['index'])
  captured_rows.append({
      'edge':row['edge'],'index':row['index'],'instance':row['instance'],
      'sha256':row['sha256'],'content':content,
  })
 if seen_indexes!=set(range(1,expected+1)): fail('roster-mismatch')
 captured_rows.sort(key=lambda row:row['index'])
 print(json.dumps({
     'schema_version':1,'ledger_sha256':ledger_digest,'rows':captured_rows,
 },sort_keys=True,separators=(',',':')),end='')
except SystemExit:
 raise
except (OSError,UnicodeError,ValueError,TypeError,json.JSONDecodeError):
 fail('malformed-ledger')
except Exception:
 fail('unsafe-artifact')
PY
}

# Convert the seven authenticated reviewer snapshots into the one canonical
# Phase 1 document. The captured JSON arrives on stdin so the bounded reviewer
# payloads never cross the platform argv/env-size boundary.
#
# THE CITATION GATE (#433) RUNS HERE, and it runs on the AGGREGATE only. Each
# child's own `result.md` is sha256-pinned in the trusted ledger and read back
# through `secure_capture_published`; rewriting one to drop a finding would break
# the tamper-evidence chain that makes the whole wave provable. So the raw child
# result stays intact and auditable, the aggregate is what gets filtered, and the
# filtering itself is published as an artifact — a cull is never swallowed.
post_review_write_aggregate_v2() {
  local aggregation_input="$1" aggregate_path="$2" rule_sources_path="$3" \
        rule_root="$4" changed_paths_path="$5" citation_log_path="$6" writer_code=
  IFS= read -r -d '' writer_code <<'PY' || :
import hashlib,importlib.util,json,os,posixpath,re,stat,sys,tempfile

(aggregate_path,plugin_root,rule_sources_path,rule_root,changed_paths_path,
 citation_log_path)=sys.argv[1:]
temporary_path=None

def fail(reason):
 print(f'post_review_aggregate_failure class={reason}',file=sys.stderr)
 raise SystemExit(1)

def closed_object(pairs):
 value={}
 for key,item in pairs:
  if key in value: raise ValueError('duplicate-key')
  value[key]=item
 return value

def scalar(raw):
 if not raw or raw.strip()!=raw or any(ord(char)<32 or ord(char)==127 for char in raw):
  raise ValueError('invalid-scalar')
 def checked(value):
  if (not isinstance(value,str) or not value or value.strip()!=value
      or any(ord(char)<32 or ord(char)==127 for char in value)):
   raise ValueError('invalid-scalar')
  return value
 if raw.startswith('"'):
  return checked(json.loads(raw))
 if raw.startswith("'"):
  if len(raw)<2 or not raw.endswith("'"): raise ValueError('invalid-scalar')
  inner=raw[1:-1]; value=''; index=0
  while index<len(inner):
   if inner[index]=="'":
    if index+1>=len(inner) or inner[index+1]!="'": raise ValueError('invalid-scalar')
    value+="'"; index+=2
   else:
    value+=inner[index]; index+=1
  return checked(value)
 if raw[0] in '-?:,[]{}#&*!|>@`' or ': ' in raw or ' #' in raw:
  raise ValueError('invalid-scalar')
 if re.fullmatch(r'(?i:null|true|false|~|[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]+)?(?:e[-+]?[0-9]+)?|[-+]?\.(?:inf|nan))',raw):
  raise ValueError('invalid-scalar')
 return checked(raw)

def parse_reviewer(content):
 match=re.fullmatch(r'\s*```yaml[ \t]*\r?\n(.*?)\r?\n```[ \t]*\s*',content,re.S)
 if match is None: raise ValueError('invalid-reviewer')
 verdict=None; confidence=None; findings_mode=None; findings=[]; current=None
 for line in match.group(1).splitlines():
  if not line.strip(): continue
  top=re.fullmatch(r'(verdict|confidence):[ \t]*(\S(?:.*\S)?)',line)
  if top:
   key,value=top.groups(); value=scalar(value)
   if key=='verdict':
    if verdict is not None or value not in {'APPROVE','REVISIONS_REQUIRED','REJECT'}:
     raise ValueError('invalid-reviewer')
    verdict=value
   else:
    if confidence is not None or value not in {'low','medium','high'}:
     raise ValueError('invalid-reviewer')
    confidence=value
   continue
  found=re.fullmatch(r'findings:[ \t]*(\[\])?',line)
  if found:
   if findings_mode is not None: raise ValueError('invalid-reviewer')
   findings_mode='empty' if found.group(1) else 'rows'
   continue
  severity=re.fullmatch(r'  - severity:[ \t]*(blocker|suggestion)',line)
  if severity and findings_mode=='rows':
   if current is not None: findings.append(current)
   current={'severity':severity.group(1)}
   continue
  field=re.fullmatch(r'    (location|summary|detail):[ \t]*(\S(?:.*\S)?)',line)
  if field and findings_mode=='rows' and current is not None:
   key,value=field.groups(); value=scalar(value)
   if key in current: raise ValueError('invalid-reviewer')
   current[key]=value
   continue
  raise ValueError('invalid-reviewer')
 if current is not None: findings.append(current)
 if verdict is None or confidence is None or findings_mode is None:
  raise ValueError('invalid-reviewer')
 if findings_mode=='empty' and findings: raise ValueError('invalid-reviewer')
 if findings_mode=='rows' and not findings: raise ValueError('invalid-reviewer')
 blockers=[finding for finding in findings if finding.get('severity')=='blocker']
 if (verdict=='APPROVE')==bool(blockers): raise ValueError('invalid-reviewer')
 for finding in findings:
  if set(finding)!={'severity','location','summary','detail'}:
   raise ValueError('invalid-reviewer')
 return {'confidence':confidence,'findings':findings,'verdict':verdict}

def scope(location):
 if not isinstance(location,str) or re.fullmatch(r'.+:[1-9][0-9]*',location) is None:
  raise ValueError('invalid-location')
 path,line_text=location.rsplit(':',1)
 parts=path.split('/')
 if (path.startswith('/') or re.match(r'^[A-Za-z]:',path) or '\\' in path
     or any(part in {'','.','..'} for part in parts) or parts[0]=='.git'
     or posixpath.normpath(path)!=path):
  raise ValueError('invalid-location')
 return {'line':int(line_text),'operation':'modify_existing','path':path}

# Bounds for the three gate inputs. The allowlist is a capped path list, the
# changed-path set is one JSON array, and a cited rule document is read once and
# cached. None of them is a diff, so none of them needs a diff-sized ceiling.
RULE_SOURCES_LIMIT=65536
CHANGED_PATHS_LIMIT=1048576
RULE_FILE_LIMIT=1048576
CITATION_LOG_ROW_LIMIT=500

def cell(text):
 # Repo-derived text -- and in a PR that edits a rule document, ATTACKER-derived
 # text -- on its way into a markdown artifact other agents read. Collapse to one
 # line, drop controls, neutralise the envelope/table metacharacters, and bound
 # the length. Same treatment as any other untrusted string in this pipeline.
 value=' '.join(str(text).split())
 value=''.join(char for char in value if ord(char)>=32 and ord(char)!=127)
 for source,replacement in (('&','&amp;'),('<','&lt;'),('>','&gt;'),('|','&#124;')):
  value=value.replace(source,replacement)
 return value[:200] if value else '(empty)'

def read_bounded(path,limit,reason):
 if not path or not os.path.isfile(path): fail(reason)
 try:
  with open(path,'rb') as handle:
   payload=handle.read(limit+1)
 except OSError: fail(reason)
 if len(payload)>limit: fail(reason)
 try: return payload.decode('utf-8')
 except UnicodeError: fail(reason)

try:
 spec=importlib.util.spec_from_file_location(
     'uberdev_code_fixer_contract',os.path.join(plugin_root,'lib','code_fixer_contract.py'))
 if spec is None or spec.loader is None: fail('writer-unavailable')
 contract=importlib.util.module_from_spec(spec); sys.modules[spec.name]=contract
 spec.loader.exec_module(contract)
 contributor_ids=list(contract.PHASE_CONTRIBUTORS['phase1'])
 # ---- the convention lens's citation gate (#433) ----
 # Both documents are REQUIRED. A missing allowlist is not "no rules to check" --
 # it is a controller that did not run discovery, and the honest outcome of that
 # is a refused aggregate, not a clean-looking one whose every convention finding
 # was silently dropped. An allowlist that exists and is EMPTY is different, and
 # legitimate: it means the repo wrote no conventions down.
 rule_sources=[line.strip() for line in
               read_bounded(rule_sources_path,RULE_SOURCES_LIMIT,'rule-sources-unavailable').splitlines()
               if line.strip()]
 changed_paths=json.loads(read_bounded(changed_paths_path,CHANGED_PATHS_LIMIT,'changed-paths-unavailable'))
 if type(changed_paths) is not list or any(type(item) is not str for item in changed_paths):
  fail('changed-paths-unavailable')
 if not rule_root or not os.path.isdir(rule_root): fail('rule-root-unavailable')
 rule_root_real=os.path.realpath(rule_root)
 rule_cache={}
 def rule_lines_for(rule_path):
  # Only ever called for an allowlisted path, and still re-checked against the
  # root: the cited string is reviewer-authored, so `..` and absolute spellings
  # have to fail closed here even though the allowlist already excluded them.
  if rule_path in rule_cache: return rule_cache[rule_path]
  lines=[]
  candidate=os.path.realpath(os.path.join(rule_root_real,rule_path))
  if ((candidate==rule_root_real or candidate.startswith(rule_root_real+os.sep))
      and os.path.isfile(candidate)):
   try:
    with open(candidate,'rb') as handle:
     payload=handle.read(RULE_FILE_LIMIT+1)
    if len(payload)<=RULE_FILE_LIMIT:
     lines=payload.decode('utf-8',errors='replace').splitlines()
   except OSError:
    lines=[]
  rule_cache[rule_path]=lines
  return lines
 def gate_citation(finding,location_path):
  parsed=contract.parse_convention_detail(finding['detail'])
  rule_path=parsed['rule_path'] if parsed else ''
  # A path outside the allowlist is NEVER opened. The allowlist is what bounds
  # this reader's reach into the checkout, so it gates the read, not just the
  # verdict.
  lines=rule_lines_for(rule_path) if rule_path in rule_sources else []
  return contract.classify_convention_citation({
      'detail':finding['detail'],
      'location_path':location_path,
      'allowlist':rule_sources,
      'changed_paths':changed_paths,
      'rule_lines':lines,
  })
 captured=json.loads(sys.stdin.buffer.read().decode('utf-8'),object_pairs_hook=closed_object)
 if (type(captured) is not dict
     or set(captured)!={'ledger_sha256','rows','schema_version'}
     or captured.get('schema_version')!=1
     or re.fullmatch(r'[0-9a-f]{64}',captured.get('ledger_sha256','')) is None
     or type(captured.get('rows')) is not list
     or len(captured['rows'])!=len(contributor_ids)):
  fail('malformed-input')
 contributors=[]; finding_groups={}; finding_order=[]; citation_culls=[]
 for index,(row,edge) in enumerate(zip(captured['rows'],contributor_ids),1):
  if (type(row) is not dict
      or set(row)!={'content','edge','index','instance','sha256'}
      or row.get('edge')!=edge or row.get('index')!=index
      or not isinstance(row.get('content'),str)
      or not isinstance(row.get('instance'),str)
      or re.fullmatch(r'[0-9a-f]{64}',row.get('sha256','')) is None
      or hashlib.sha256(row['content'].encode('utf-8')).hexdigest()!=row['sha256']):
   fail('roster-mismatch')
  reviewer=parse_reviewer(row['content'])
  reviewer_findings=reviewer['findings']; reviewer_verdict=reviewer['verdict']
  # Gate PER OBSERVATION and BEFORE scope grouping. Grouping merges findings from
  # different edges that land on the same (path,line) into one aggregate finding;
  # culling after that point would take another lens's finding with it.
  if edge==contract.CONVENTION_EDGE:
   survivors=[]
   for finding in reviewer_findings:
    location_path=scope(finding['location'])['path']
    verdict=gate_citation(finding,location_path)
    if verdict['outcome']=='cull':
     citation_culls.append({
         'reason':verdict['reason'],
         'cited_path':verdict.get('rule_path',''),
         'location':finding['location'],
         'quote_prefix':verdict.get('quote_prefix',''),
     })
     continue
    if verdict['outcome']=='demote':
     finding=dict(finding,severity='suggestion')
     citation_culls.append({
         'reason':verdict['reason'],
         'cited_path':verdict.get('rule_path',''),
         'location':finding['location'],
         'quote_prefix':verdict.get('quote_prefix',''),
     })
    survivors.append(finding)
   reviewer_findings=survivors
   # The two-way verdict/severity invariant holds on the AGGREGATE exactly as it
   # holds on the child result: a reviewer whose every blocker was culled did not
   # find a blocker, so its contributor row must say APPROVE.
   if not any(item['severity']=='blocker' for item in reviewer_findings):
    reviewer_verdict='APPROVE'
  contributors.append({
      'confidence':reviewer['confidence'],
      'id':edge,
      'verdict':reviewer_verdict,
  })
  for finding in reviewer_findings:
   finding_scope=scope(finding['location'])
   scope_key=(finding_scope['path'],finding_scope['line'])
   if scope_key not in finding_groups:
    finding_groups[scope_key]={'observations':[],'scope':finding_scope}
    finding_order.append(scope_key)
   finding_groups[scope_key]['observations'].append({
       'detail':finding['detail'],
       'edge':edge,
       'severity':finding['severity'],
       'summary':finding['summary'],
   })
 findings=[]
 for scope_key in finding_order:
  group=finding_groups[scope_key]; observations=group['observations']
  source_edges=[]
  for observation in observations:
   if observation['edge'] not in source_edges:
    source_edges.append(observation['edge'])
  findings.append({
      'detail':(observations[0]['detail'] if len(observations)==1 else
                ' | '.join(f"{item['edge']}: {item['detail']}" for item in observations)),
      'scope':group['scope'],
      'severity':('blocker' if any(item['severity']=='blocker' for item in observations)
                  else 'suggestion'),
      'source_edges':source_edges,
      'summary':(observations[0]['summary'] if len(observations)==1 else
                 ' | '.join(f"{item['edge']}: {item['summary']}" for item in observations)),
  })
 document={
     'contributors':contributors,
     'findings':findings,
     'phase':'phase1',
     'schema_version':2,
 }
 encoded=contract.encode_aggregate(document,'phase1')
 # Validate the aggregate DESTINATION before publishing anything. An unusable
 # destination must refuse the whole write, not leave a cull log behind for an
 # aggregate that never existed.
 target=os.path.abspath(aggregate_path); parent=os.path.dirname(target)
 if not os.path.isabs(aggregate_path) or not os.path.isdir(parent):
  fail('unsafe-output')
 parent_entry=os.stat(parent,follow_symlinks=False)
 if not stat.S_ISDIR(parent_entry.st_mode): fail('unsafe-output')
 # ---- publish the cull log FIRST (#433) ----
 # A cull is never swallowed: the filtered aggregate may not exist without the
 # artifact that says what was filtered and why. Written even when nothing was
 # culled, so its ABSENCE means the gate did not run rather than "nothing to
 # report" -- and written before the aggregate, so a log that cannot be published
 # refuses the whole write instead of leaving a silently-thinner review.
 log_lines=['# Convention citation gate',
            '',
            'Rule sources: '+(', '.join(cell(item) for item in rule_sources)
                              if rule_sources else 'none'),
            'Culled or demoted citations: '+str(len(citation_culls)),
            '']
 if citation_culls:
  log_lines += ['| reason | cited rule | finding location | normalised quote (prefix) |',
                '|---|---|---|---|']
  for record in citation_culls[:CITATION_LOG_ROW_LIMIT]:
   log_lines.append('| %s | %s | %s | %s |' % (
       cell(record['reason']), cell(record['cited_path']),
       cell(record['location']), cell(record['quote_prefix'])))
  if len(citation_culls)>CITATION_LOG_ROW_LIMIT:
   log_lines.append('')
   log_lines.append('%d further rows omitted.'
                    % (len(citation_culls)-CITATION_LOG_ROW_LIMIT))
 log_payload=('\n'.join(log_lines)+'\n').encode('utf-8')
 log_target=os.path.abspath(citation_log_path); log_parent=os.path.dirname(log_target)
 if not os.path.isabs(citation_log_path) or not os.path.isdir(log_parent):
  fail('citation-log-unwritable')
 log_descriptor,temporary_path=tempfile.mkstemp(prefix='.post-review-citations-',dir=log_parent)
 with os.fdopen(log_descriptor,'wb') as log_output:
  log_output.write(log_payload)
  log_output.flush(); os.fsync(log_output.fileno())
 if os.name!='nt': os.chmod(temporary_path,0o600)
 os.replace(temporary_path,log_target); temporary_path=None
 descriptor,temporary_path=tempfile.mkstemp(prefix='.post-review-v2-',dir=parent)
 with os.fdopen(descriptor,'wb') as output:
  output.write(encoded)
  output.flush(); os.fsync(output.fileno())
 if os.name!='nt': os.chmod(temporary_path,0o600)
 os.replace(temporary_path,target); temporary_path=None
except SystemExit:
 raise
except (OSError,UnicodeError,ValueError,TypeError,json.JSONDecodeError):
 fail('malformed-input')
except Exception:
 fail('writer-failed')
finally:
 if temporary_path is not None:
  try: os.unlink(temporary_path)
  except OSError: pass
PY
  printf '%s' "$aggregation_input" | python3 -I -B -c "$writer_code" \
    "$aggregate_path" "$UBERDEV_REVIEW_PLUGIN_ROOT" "$rule_sources_path" \
    "$rule_root" "$changed_paths_path" "$citation_log_path"
}

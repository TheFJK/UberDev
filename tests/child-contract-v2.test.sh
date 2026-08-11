#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$ROOT/plugins/uberdev/policy/solve-run-tree-v1.json"
LIB="$ROOT/plugins/uberdev/lib/child-dispatch.sh"
CONTRACT="$ROOT/plugins/uberdev/shared/phase1-reviewer-output-v1.md"
FINDINGS_AGENT="$ROOT/plugins/uberdev/agents/findings-to-issues.md"

python3 -I -B - "$TREE" <<'PY'
import json,sys
tree=json.load(open(sys.argv[1])); providers={k:v for k,v in tree['edges'].items() if v['kind']=='provider'}
assert tree.get('input_limits')=={'max_serialized_bytes':49152}
types={'integer','string','bounded_text','optional_string','boolean','path','optional_path','directory','string_array','path_array','optional_path_array','repo_path_array'}
assert providers
for edge,row in providers.items():
    assert row.get('workspace_mode','isolated') in {'isolated','caller'}, edge
    assert 'inputs' not in row and 'input_types' not in row, edge
    assert isinstance(row.get('required_inputs'),dict), edge
    assert isinstance(row.get('optional_inputs'),dict), edge
    assert not (set(row['required_inputs']) & set(row['optional_inputs'])), edge
    assert set(row['required_inputs'].values())|set(row['optional_inputs'].values()) <= types, edge
    allowed=row.get('allowed_workflows')
    assert isinstance(allowed,list) and allowed==sorted(set(allowed)), edge
    assert set(allowed) <= {'solve','turbo','review-pr','simplify'}, edge
for edge in ('orchestrator.plan.write','sdd.task.implement'):
    assert providers[edge]['allowed_workflows']==['solve','turbo']
assert providers['orchestrator.plan.write']['retry']=={'revision':1,'verification':2}
assert providers['orchestrator.plan.write']['optional_inputs']['verification_feedback_path']=='path'
assert providers['orchestrator.plan.write']['optional_inputs']['revision_brief_path']=='path'
for edge,row in providers.items():
    if row.get('retry',{}).get('format'):
        assert row['optional_inputs']['format_retry']=='boolean', edge
        assert row['optional_inputs']['format_example_path']=='path', edge
for edge in ('review_pr.simplify.reuse','review_pr.simplify.quality','review_pr.simplify.efficiency'):
    row=providers[edge]
    assert 'focus' not in row['required_inputs'], edge
    assert row['optional_inputs'].get('focus')=='optional_string', edge
    assert 'additional_focus' not in row['optional_inputs'], edge
fixer_inputs={
 'findings_path':'path',
 'findings_sha256':'string',
 'commit_range_path':'path',
 'commit_range_sha256':'string',
 'working_dir':'directory',
 'pr_number':'integer',
 'disposition_path':'path',
 'authority_path':'path',
 'authority_sha256':'string',
}
for edge,policy_phase in (
 ('review_pr.fix.phase1','review_fix'),
 ('review_pr.fix.phase2','simplify_fix'),
):
    row=providers[edge]
    assert row['required_inputs']==fixer_inputs, edge
    assert row['optional_inputs']=={}, edge
    assert row['phase']==policy_phase, edge
standalone_fixer_inputs={
 'findings_path':'path',
 'findings_sha256':'string',
 'standalone_snapshot_path':'path',
 'standalone_snapshot_sha256':'string',
 'working_dir':'directory',
 'pr_number':'integer',
 'disposition_path':'path',
 'authority_path':'path',
 'authority_sha256':'string',
}
standalone=providers['simplify.fix.phase2']
assert standalone['required_inputs']==standalone_fixer_inputs
assert standalone['optional_inputs']=={}
assert standalone['phase']=='simplify_fix'
assert standalone['allowed_workflows']==['simplify']
review_edges={edge for edge in providers if edge.startswith('review_pr.review.')}
assert len(review_edges)==7
assert tree.get('output_contracts')=={'phase1-reviewer-v1':'shared/phase1-reviewer-output-v1.md'}
for edge in review_edges:
    row=providers[edge]
    assert row['required_inputs']['changed_paths']=='repo_path_array', edge
    assert row.get('output_contract')=='phase1-reviewer-v1', edge
caller_edges={
 'review_pr.fix.phase1','review_pr.fix.phase2','simplify.fix.phase2','review_pr.ci.fix_code',
 'review_pr.ci.rebase','review_pr.ci.resolve_conflict'
}
assert {edge for edge,row in providers.items() if row.get('workspace_mode')=='caller'}==caller_edges
for edge in caller_edges:
    assert providers[edge]['required_inputs'].get('working_dir')=='directory', edge
PY

grep -q '^uberdev_preflight_child_batch()' "$LIB"
grep -q '^uberdev_unwind_child()' "$LIB"
python3 -I -B - \
  "$LIB" "$CONTRACT" \
  "$FINDINGS_AGENT" <<'PY'
import contextlib
import errno
import io
import os
import pathlib
import sys
import tempfile

lib_path,contract_path,*agent_paths=sys.argv[1:]
lib=pathlib.Path(lib_path).read_text()
contract=pathlib.Path(contract_path).read_text()
failures=[]

if "def safe_existing(" in lib:
    failures.append("unused safe_existing helper remains")
if "`` -?:,[]{}#&*!|>@` ``; contain" not in contract:
    failures.append("literal-backtick grammar does not use a safe code-span delimiter")
# #403: the boundary is re.fullmatch over the RESULT FILE, but the contract used
# to bind "the final content of your response" — reply-scoped wording that
# permits a leading sentence the validator always refuses.
if "entire contents of the result file" not in contract:
    failures.append("contract is reply-scoped; it must bind the RESULT FILE's whole contents")
if "as the final content of your response" in contract:
    failures.append("contract still carries the reply-scoped wording that permits leading prose")

for agent_path in agent_paths:
    value=pathlib.Path(agent_path).read_text()
    if (
        "partial second request cannot turn a healthy API into two empty values:\n\n"
        "   ```bash\n"
    ) not in value:
        failures.append(f"{agent_path}: rate-limit fence lacks a leading blank line")
    if (
        '     SEARCH_REMAINING=""\n'
        "   fi\n"
        "   ```\n\n"
        "   The core bucket funds"
    ) not in value:
        failures.append(f"{agent_path}: rate-limit fence lacks a trailing blank line")

function_start=lib.index("uberdev_child_validate_phase1_review_result() {")
snippet_start=lib.index("<<'PY'\n",function_start)+len("<<'PY'\n")
snippet_end=lib.index("\nPY\n}",snippet_start)
snippet=lib[snippet_start:snippet_end]

with tempfile.TemporaryDirectory() as temporary:
    result=pathlib.Path(temporary)/"result.md"
    result.write_text(
        "```yaml\nverdict: APPROVE\nfindings: []\nconfidence: high\n```\n",
        encoding="utf-8",
    )
    original_open=os.open
    original_read=os.read
    original_fstat=os.fstat
    original_lstat=os.lstat
    original_close=os.close
    original_geteuid=getattr(os,"geteuid",None)

    def execute(*,allowed_raw="",validated_path="",platform=None,os_name=None):
        previous_argv=sys.argv
        previous_platform=sys.platform
        previous_os_name=os.name
        sys.argv=["phase1-validator",str(result),allowed_raw,str(validated_path)]
        if platform is not None:
            sys.platform=platform
        if os_name is not None:
            os.name=os_name
        try:
            with (
                contextlib.redirect_stdout(io.StringIO()),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                try:
                    exec(compile(snippet,"phase1-validator","exec"),{})
                except SystemExit as error:
                    return error.code
                return 0
        finally:
            sys.argv=previous_argv
            sys.platform=previous_platform
            os.name=previous_os_name

    def execute_with_io(*,read_hook=None,fstat_hook=None,lstat_hook=None,**execute_kwargs):
        opened_descriptors=[]
        closed_descriptors=[]
        def tracked_open(path,flags,*args,**kwargs):
            descriptor=original_open(path,flags,*args,**kwargs)
            opened_descriptors.append(descriptor)
            return descriptor
        def tracked_close(descriptor):
            closed_descriptors.append(descriptor)
            return original_close(descriptor)
        os.open=tracked_open
        os.read=read_hook or original_read
        os.fstat=fstat_hook or original_fstat
        os.lstat=lstat_hook or original_lstat
        os.close=tracked_close
        try:
            return execute(**execute_kwargs),opened_descriptors,closed_descriptors
        finally:
            os.open=original_open
            os.read=original_read
            os.fstat=original_fstat
            os.lstat=original_lstat
            os.close=original_close

    class LinkCountView:
        def __init__(self,entry,link_count):
            self._entry=entry
            self.st_nlink=link_count
        def __getattr__(self,name):
            return getattr(self._entry,name)

    class StatView:
        def __init__(self,entry,*,missing=(),**overrides):
            self._entry=entry
            self._missing=frozenset(missing)
            self._overrides=overrides
        def __getattr__(self,name):
            if name in self._missing:
                raise AttributeError(name)
            if name in self._overrides:
                return self._overrides[name]
            return getattr(self._entry,name)

    windows_birthtime_ns=1_700_000_000_123_456_789
    windows_path_ctime_ns=1_700_000_000_223_456_789
    windows_fd_ctime_ns=1_700_000_000_323_456_789

    def identity_view(
        entry,
        *,
        birthtime_ns,
        ctime_ns,
        birthtime_available=True,
        device_offset=0,
        inode_offset=0,
    ):
        birthtime_fields=("st_birthtime_ns","st_birthtime")
        overrides={
            "st_ctime_ns":ctime_ns,
            "st_ctime":ctime_ns/1_000_000_000,
            "st_dev":entry.st_dev+device_offset,
            "st_ino":entry.st_ino+inode_offset,
        }
        if birthtime_available:
            overrides.update(
                st_birthtime_ns=birthtime_ns,
                st_birthtime=birthtime_ns/1_000_000_000,
            )
        return StatView(
            entry,
            missing=() if birthtime_available else birthtime_fields,
            **overrides,
        )

    def execute_identity_case(
        *,
        path_birthtimes=(windows_birthtime_ns,windows_birthtime_ns),
        descriptor_birthtimes=(windows_birthtime_ns,windows_birthtime_ns),
        path_ctimes=(windows_path_ctime_ns,windows_path_ctime_ns),
        descriptor_ctimes=(windows_fd_ctime_ns,windows_fd_ctime_ns),
        path_device_offsets=(0,0),
        descriptor_device_offsets=(0,0),
        path_inode_offsets=(0,0),
        descriptor_inode_offsets=(0,0),
        birthtime_available=True,
        platform="win32",
        os_name=None,
    ):
        fstat_calls=[0]
        lstat_calls=[0]
        def modeled_fstat(descriptor):
            entry=original_fstat(descriptor)
            snapshot=fstat_calls[0]
            fstat_calls[0]+=1
            return identity_view(
                entry,
                birthtime_ns=descriptor_birthtimes[snapshot],
                ctime_ns=descriptor_ctimes[snapshot],
                birthtime_available=birthtime_available,
                device_offset=descriptor_device_offsets[snapshot],
                inode_offset=descriptor_inode_offsets[snapshot],
            )
        def modeled_lstat(path):
            snapshot=lstat_calls[0]
            lstat_calls[0]+=1
            return identity_view(
                original_lstat(path),
                birthtime_ns=path_birthtimes[snapshot],
                ctime_ns=path_ctimes[snapshot],
                birthtime_available=birthtime_available,
                device_offset=path_device_offsets[snapshot],
                inode_offset=path_inode_offsets[snapshot],
            )
        rc,opened,closed=execute_with_io(
            fstat_hook=modeled_fstat,
            lstat_hook=modeled_lstat,
            platform=platform,
            os_name=os_name,
        )
        return rc,fstat_calls[0],lstat_calls[0],opened,closed

    def require_identity_case(label,result,expected_rc):
        rc,fstat_calls,lstat_calls,opened,closed=result
        if rc!=expected_rc or (fstat_calls,lstat_calls)!=(2,2):
            failures.append(
                f"phase1 validator {label}: rc={rc} "
                f"calls={(fstat_calls,lstat_calls)} expected_rc={expected_rc}"
            )
        if not opened or opened!=closed:
            failures.append(
                f"phase1 validator leaked its descriptor for {label}: "
                f"opened={opened} closed={closed}"
            )

    require_identity_case(
        "rejected an unchanged native-Windows result when path birthtime "
        "matched the descriptor but raw ctime views differed",
        execute_identity_case(),
        0,
    )
    require_identity_case(
        "accepted an initial native-Windows pathname/descriptor birthtime mismatch",
        execute_identity_case(
            path_birthtimes=(windows_birthtime_ns+1,windows_birthtime_ns),
        ),
        2,
    )
    require_identity_case(
        "accepted a final native-Windows pathname/descriptor birthtime mismatch",
        execute_identity_case(
            path_birthtimes=(windows_birthtime_ns,windows_birthtime_ns+1),
        ),
        2,
    )
    require_identity_case(
        "accepted an initial native-Windows pathname/descriptor device replacement",
        execute_identity_case(path_device_offsets=(1,0)),
        2,
    )
    require_identity_case(
        "accepted an initial native-Windows pathname/descriptor inode replacement",
        execute_identity_case(path_inode_offsets=(1,0)),
        2,
    )
    require_identity_case(
        "accepted a final native-Windows pathname/descriptor device replacement",
        execute_identity_case(path_device_offsets=(0,1)),
        2,
    )
    require_identity_case(
        "accepted a final native-Windows pathname/descriptor inode replacement",
        execute_identity_case(path_inode_offsets=(0,1)),
        2,
    )
    require_identity_case(
        "accepted a POSIX pathname/descriptor raw ctime mismatch despite "
        "matching synthetic birthtimes",
        execute_identity_case(
            path_ctimes=(windows_path_ctime_ns,windows_fd_ctime_ns),
            platform="darwin",
            os_name="posix",
        ),
        2,
    )
    require_identity_case(
        "accepted a native-Windows raw ctime mismatch when birthtime fields "
        "were unavailable",
        execute_identity_case(
            path_ctimes=(windows_path_ctime_ns,windows_fd_ctime_ns),
            birthtime_available=False,
        ),
        2,
    )
    require_identity_case(
        "accepted a native-Windows same-descriptor raw ctime mutation between "
        "fd snapshots",
        execute_identity_case(
            descriptor_ctimes=(windows_fd_ctime_ns,windows_fd_ctime_ns+1),
        ),
        2,
    )

    case_number=[0]
    def execute_link_case(
        *,
        descriptor_overrides=None,
        path_overrides=None,
        platform=None,
        os_name=None,
    ):
        case_number[0]+=1
        validated=pathlib.Path(temporary)/f"validated-{case_number[0]}.md"
        fstat_calls=[0]
        lstat_calls=[0]
        observed_descriptor_links=[]
        observed_path_links=[]
        descriptor_overrides=descriptor_overrides or {}
        path_overrides=path_overrides or {}
        def modeled_fstat(descriptor):
            entry=original_fstat(descriptor)
            fstat_calls[0]+=1
            link_count=descriptor_overrides.get(fstat_calls[0],entry.st_nlink)
            observed_descriptor_links.append(link_count)
            return LinkCountView(entry,link_count)
        def modeled_lstat(path):
            entry=original_lstat(path)
            lstat_calls[0]+=1
            link_count=path_overrides.get(lstat_calls[0],entry.st_nlink)
            observed_path_links.append(link_count)
            return LinkCountView(entry,link_count)
        try:
            rc,opened,closed=execute_with_io(
                fstat_hook=modeled_fstat,
                lstat_hook=modeled_lstat,
                allowed_raw='["README.md"]',
                validated_path=validated,
                platform=platform,
                os_name=os_name,
            )
            return rc,observed_descriptor_links,observed_path_links,opened,closed
        finally:
            try:
                validated.unlink()
            except FileNotFoundError:
                pass

    windows_zero_result=execute_link_case(
        descriptor_overrides={1:0,2:0,3:0,4:0,5:0,6:0},
        platform="win32",
    )
    windows_zero_rc,windows_descriptor_links,windows_path_links,windows_opened,windows_closed=windows_zero_result
    if (
        windows_zero_rc!=0
        or windows_descriptor_links!=[0,0,0,0,0,0]
        or any(link_count!=1 for link_count in windows_path_links)
        or not windows_opened
        or windows_opened!=windows_closed
    ):
        failures.append(
            "phase1 validator rejected modeled native-Windows zero-link open descriptors "
            f"or relaxed pathname identity: rc={windows_zero_rc} "
            f"descriptor_links={windows_descriptor_links} path_links={windows_path_links} "
            f"opened={windows_opened} closed={windows_closed}"
        )

    os_name_zero_result=execute_link_case(
        descriptor_overrides={1:0,2:0,3:0,4:0,5:0,6:0},
        os_name="nt",
    )
    if os_name_zero_result[0]!=0:
        failures.append(
            "phase1 validator did not recognize os.name native-Windows zero-link descriptors: "
            f"rc={os_name_zero_result[0]} descriptor_links={os_name_zero_result[1]} "
            f"path_links={os_name_zero_result[2]}"
        )

    expected_rejection={1:2,2:2,3:74,4:74,5:74,6:74}
    for snapshot,expected_rc in expected_rejection.items():
        posix_result=execute_link_case(
            descriptor_overrides={snapshot:0},
            platform="darwin",
            os_name="posix",
        )
        if posix_result[0]!=expected_rc:
            failures.append(
                "phase1 validator accepted a zero-link POSIX descriptor snapshot "
                f"{snapshot}: rc={posix_result[0]} descriptor_links={posix_result[1]}"
            )
        windows_result=execute_link_case(
            descriptor_overrides={snapshot:2},
            platform="win32",
        )
        if windows_result[0]!=expected_rc:
            failures.append(
                "phase1 validator accepted a multi-link native-Windows descriptor snapshot "
                f"{snapshot}: rc={windows_result[0]} descriptor_links={windows_result[1]}"
            )
        if snapshot<=5:
            for path_link_count in (0,2):
                path_result=execute_link_case(
                    path_overrides={snapshot:path_link_count},
                    platform="win32",
                )
                if path_result[0]!=expected_rc:
                    failures.append(
                        "phase1 validator accepted an invalid native-Windows pathname snapshot "
                        f"{snapshot} with link count {path_link_count}: "
                        f"rc={path_result[0]} path_links={path_result[2]}"
                    )

    if callable(original_geteuid):
        os.geteuid=lambda: original_geteuid()+1
        try:
            if execute()!=2:
                failures.append("phase1 validator accepted a foreign-owned result")
        finally:
            os.geteuid=original_geteuid

    observed_flags=[]
    def tracked_open(path,flags,*args,**kwargs):
        observed_flags.append(flags)
        return original_open(path,flags,*args,**kwargs)
    os.open=tracked_open
    try:
        if execute()!=0:
            failures.append("phase1 validator rejected a caller-owned valid result")
    finally:
        os.open=original_open
    if not observed_flags:
        failures.append("phase1 validator did not use descriptor-pinned os.open")
    nofollow=getattr(os,"O_NOFOLLOW",0)
    if nofollow and observed_flags and not observed_flags[0]&nofollow:
        failures.append("phase1 validator omitted O_NOFOLLOW")

    short_reads=[]
    def short_read(descriptor,maximum):
        chunk=original_read(descriptor,min(maximum,7))
        short_reads.append((maximum,len(chunk)))
        return chunk
    short_rc,short_opened,short_closed=execute_with_io(read_hook=short_read)
    bounded_chunks=all(
        next_maximum==maximum-size
        for (maximum,size),(next_maximum,_) in zip(short_reads,short_reads[1:])
    )
    if (
        short_rc!=0
        or sum(size>0 for _,size in short_reads)<2
        or not short_reads
        or short_reads[0][0]!=1048577
        or not bounded_chunks
        or not short_opened
        or short_opened!=short_closed
    ):
        failures.append(
            "phase1 validator did not consume multiple bounded short reads "
            f"with descriptor cleanup: rc={short_rc} reads={short_reads} "
            f"opened={short_opened} closed={short_closed}"
        )

    read_failure_calls=[0]
    def failing_read(descriptor,maximum):
        read_failure_calls[0]+=1
        if read_failure_calls[0]==2:
            raise OSError(errno.EIO,"injected phase1 read failure")
        return original_read(descriptor,min(maximum,7))
    read_rc,read_opened,read_closed=execute_with_io(read_hook=failing_read)
    if (
        read_rc!=2
        or read_failure_calls[0]!=2
        or not read_opened
        or read_opened!=read_closed
    ):
        failures.append(
            "phase1 validator did not fail closed and clean its descriptor "
            f"after read OSError: rc={read_rc} calls={read_failure_calls[0]} "
            f"opened={read_opened} closed={read_closed}"
        )

    fstat_failure_calls=[0]
    def failing_final_fstat(descriptor):
        fstat_failure_calls[0]+=1
        if fstat_failure_calls[0]==2:
            raise OSError(errno.EIO,"injected phase1 final fstat failure")
        return original_fstat(descriptor)
    fstat_rc,fstat_opened,fstat_closed=execute_with_io(fstat_hook=failing_final_fstat)
    if (
        fstat_rc!=2
        or fstat_failure_calls[0]!=2
        or not fstat_opened
        or fstat_opened!=fstat_closed
    ):
        failures.append(
            "phase1 validator did not fail closed and clean its descriptor "
            f"after fstat OSError: rc={fstat_rc} calls={fstat_failure_calls[0]} "
            f"opened={fstat_opened} closed={fstat_closed}"
        )

if failures:
    raise AssertionError("; ".join(failures))
PY

# The shared constructor must enforce RepoPathArray before the later handoff
# boundary so a successful build always carries the same nominal invariant.
INPUT_HELPER="$ROOT/plugins/uberdev/lib/child-inputs.py"
! grep -q 'MAX_INPUT_BYTES[[:space:]]*=' "$INPUT_HELPER"
grep -q "input_limits" "$INPUT_HELPER"
grep -q "input_limits" "$LIB"
python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
  changed_paths '["README.md","src/example.ts"]' \
  diff_path '"/tmp/diff"' criteria_path '"/tmp/criteria"' emphasis '[]' >/dev/null
for unsafe in \
  '["/absolute"]' \
  '["../traversal"]' \
  '["src/./dot.ts"]' \
  '["src\\windows.ts"]' \
  '["src//empty.ts"]'
do
  if python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
      changed_paths "$unsafe" diff_path '"/tmp/diff"' criteria_path '"/tmp/criteria"' emphasis '[]' \
      >/dev/null 2>&1; then
    echo "child-contract-v2: unsafe RepoPathArray reached a successful construction boundary: $unsafe" >&2
    exit 1
  fi
done

# A successful constructor result must fit inside the dispatcher's immutable
# 64-KiB handoff after the fixed carrier/schema overhead is added.
OVERSIZED_PATHS="$(python3 -I -B - <<'PY'
import json
print(json.dumps([f"src/generated/{index:05d}-{'x' * 80}.ts" for index in range(700)],separators=(',',':')))
PY
)"
if python3 -I -B "$INPUT_HELPER" --manifest "$TREE" build review_pr.review.correctness \
    changed_paths "$OVERSIZED_PATHS" diff_path '"/tmp/diff"' \
    criteria_path '"/tmp/criteria"' emphasis '[]' >/dev/null 2>&1; then
  echo "child-contract-v2: oversized RepoPathArray crossed the construction boundary" >&2
  exit 1
fi

# Exact immutable-input boundary from the shared manifest contract: the limit is
# accepted and limit-plus-one is rejected by the constructor.
python3 -I -B - "$INPUT_HELPER" "$TREE" <<'PY'
import importlib.util,json,pathlib,sys
helper_path,manifest_path=sys.argv[1:]
spec=importlib.util.spec_from_file_location("child_inputs",helper_path)
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
manifest=json.loads(pathlib.Path(manifest_path).read_text())
limit=manifest['input_limits']['max_serialized_bytes']
paths=[f"src/p{index:02d}-"+("x"*2990)+".ts" for index in range(16)]
accepted={"changed_paths":paths,"diff_path":"/tmp/diff","criteria_path":"/tmp/criteria","emphasis":[]}
current=len(json.dumps(accepted,sort_keys=True,separators=(",",":")).encode())
accepted["changed_paths"][-1]=accepted["changed_paths"][-1][:-3]+("x"*(limit-current))+".ts"
rejected=json.loads(json.dumps(accepted))
rejected["changed_paths"][-1]=rejected["changed_paths"][-1][:-3]+"x.ts"
assert len(json.dumps(accepted,sort_keys=True,separators=(",",":")).encode())==limit
assert len(json.dumps(rejected,sort_keys=True,separators=(",",":")).encode())==limit+1
assert max(map(len,accepted["changed_paths"]))<=4096
module.validate_inputs(manifest,"review_pr.review.correctness",accepted)
try:
    module.validate_inputs(manifest,"review_pr.review.correctness",rejected)
except module.InputFailure:
    pass
else:
    raise AssertionError("limit-plus-one inputs crossed the constructor boundary")
PY
echo 'child-contract-v2: PASS'

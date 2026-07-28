#!/usr/bin/env bash
# tools/prkit/generate.sh — generate the standalone prkit plugin from UberDev SSOT.
#   generate.sh --target <dir> [--version X.Y.Z] [--force]
# Stages: preflight -> clean -> copy -> rewrite -> scaffold -> codex -> verify -> summary.
# Idempotent: same SSOT + version => byte-identical output.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$REPO_ROOT/plugins/uberdev"
MANIFEST="$HERE/manifest.txt"
CODEX_SOURCE="$REPO_ROOT/codex"
MANIFEST_CODEX="$HERE/manifest-codex.txt"
TEMPLATES="$HERE/templates"
PATH_GUARD="$HERE/managed-path-guard.py"
. "$HERE/rewrite.sh"

TARGET=""; VERSION="0.1.0"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2;;
    --version) VERSION="${2:-}"; shift 2;;
    --force) FORCE=1; shift;;
    *) echo "generate: unknown arg '$1'" >&2; exit 2;;
  esac
done
[ -n "$TARGET" ] || { echo "generate: --target <dir> required" >&2; exit 2; }

# Test-only path overrides exercise the real mandatory-input checks without
# renaming shared SSOT files while parallel tests or agents may be reading them.
if [ "${PRKIT_GENERATOR_TEST_MODE:-}" = "1" ]; then
  [ -n "${PRKIT_TEST_CODEX_MANIFEST_PATH:-}" ] \
    && MANIFEST_CODEX="$PRKIT_TEST_CODEX_MANIFEST_PATH"
  [ -n "${PRKIT_TEST_CODEX_SOURCE_PATH:-}" ] \
    && CODEX_SOURCE="$PRKIT_TEST_CODEX_SOURCE_PATH"
fi

# Mandatory SSOT inputs are checked before target creation/resolution. The
# generated verifier requires the native Codex tree and marketplace
# unconditionally, so a Claude-only partial generation is never valid.
[ -d "$SRC" ] && [ -r "$SRC" ] \
  || { echo "generate: SSOT missing/unreadable: $SRC" >&2; exit 1; }
[ -r "$MANIFEST" ] \
  || { echo "generate: manifest missing/unreadable: $MANIFEST" >&2; exit 1; }
[ -d "$CODEX_SOURCE" ] && [ -r "$CODEX_SOURCE" ] \
  || { echo "generate: Codex SSOT missing/unreadable: $CODEX_SOURCE" >&2; exit 1; }
[ -r "$MANIFEST_CODEX" ] \
  || { echo "generate: Codex manifest missing/unreadable: $MANIFEST_CODEX" >&2; exit 1; }
[ -r "$PATH_GUARD" ] \
  || { echo "generate: managed path guard missing/unreadable: $PATH_GUARD" >&2; exit 1; }

# Canonicalize only the parent so the target's final entry remains visible to
# lstat. A target-root symlink or Windows junction is rejected, not silently
# resolved. Once the real root passes the shared guard, pwd -P only normalizes
# an entry already proven to be a real directory.
TARGET_PARENT_INPUT="$(dirname "$TARGET")"
TARGET_NAME="$(basename "$TARGET")"
mkdir -p "$TARGET_PARENT_INPUT" \
  || { echo "generate: cannot create target parent: $TARGET_PARENT_INPUT" >&2; exit 1; }
TARGET_PARENT="$(cd "$TARGET_PARENT_INPUT" && pwd -P)" \
  || { echo "generate: cannot resolve target parent: $TARGET_PARENT_INPUT" >&2; exit 1; }
TARGET="$TARGET_PARENT/$TARGET_NAME"
if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  mkdir "$TARGET" || { echo "generate: cannot create target dir: $TARGET" >&2; exit 1; }
fi
if ! python3 -I -B "$PATH_GUARD" "$TARGET" ".prkit-root-probe" tree; then
  echo "generate: target root must be a real, non-reparse directory: $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd -P)" \
  || { echo "generate: cannot resolve validated target dir: $TARGET" >&2; exit 1; }
[ "$TARGET" != "/" ] \
  || { echo "generate: refusing to use the filesystem root as target" >&2; exit 1; }

# Deterministic DATE input (no wall-clock in output beyond the version's date):
# use PRKIT_RELEASE_DATE if provided, else a fixed placeholder the release ritual
# overrides. The determinism test pins this.
DATE="${PRKIT_RELEASE_DATE:-2026-07-12}"

# --- 1. Target preflight ---
P="$TARGET/plugins/prkit"
MANAGED_PATHS=(
  "plugins/prkit"
  "codex"
  "README.md"
  "LICENSE"
  "NOTICE"
  "CHANGELOG.md"
  ".gitignore"
  ".github/workflows/ci.yml"
  ".claude-plugin/marketplace.json"
  ".agents/plugins/marketplace.json"
)
TARGET_GIT_GUARDED=0
GENERATION_LOCK="$TARGET/.prkit-generate.lock"
GENERATION_LOCK_HELD=0

fail_generation(){
  echo "generate: $1" >&2
  exit 1
}

# The shared helper uses component-wise os.lstat and rejects both symbolic links
# and Windows junction/reparse points. It returns nonzero rather than exiting
# this shell, which lets render() clean an unpublished destination-local temp.
check_managed_destination(){
  python3 -I -B "$PATH_GUARD" "$TARGET" "$1" "$2"
}

require_managed_destination(){
  local rel="$1" kind="$2"
  check_managed_destination "$rel" "$kind" \
    || fail_generation "unsafe managed destination: $rel"
}

atomic_replace(){
  python3 -I -B - "$1" "$2" <<'PY'
import os
import sys

try:
    os.replace(sys.argv[1], sys.argv[2])
except OSError as exc:
    raise SystemExit(f"atomic replace failed: {exc}")
PY
}

# Copy into a destination-local temporary, recheck containment immediately
# before publication, atomically replace the canonical leaf, then require the
# published file to exist. A late leaf symlink is replaced as a directory entry;
# it is never opened as the copy destination.
copy_managed_file(){
  local src="$1" dst="$2" rel="$3" out_dir tmp
  require_managed_destination "$rel" file
  out_dir="$(dirname "$dst")" \
    || fail_generation "cannot resolve copy destination directory: $rel"
  mkdir -p "$out_dir" \
    || fail_generation "cannot create copy destination directory: $rel"
  require_managed_destination "$rel" file
  if ! tmp="$(mktemp "$out_dir/.prkit-copy.XXXXXX")"; then
    fail_generation "cannot create destination-local copy temporary: $rel"
  fi
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp" || echo "generate: warning: cannot remove failed copy temporary: $tmp" >&2
    fail_generation "copy failed (manifest source missing?): $rel"
  fi
  if ! check_managed_destination "$rel" file; then
    rm -f "$tmp" || echo "generate: warning: cannot remove unpublished copy temporary: $tmp" >&2
    fail_generation "copy destination changed before publication: $rel"
  fi
  if [ "${PRKIT_GENERATOR_TEST_MODE:-}" = "1" ] \
     && [ "${PRKIT_TEST_COPY_PUBLISH_FAIL:-}" = "$rel" ]; then
    rm -f "$tmp" || fail_generation "injected copy failure also could not clean temporary: $tmp"
    fail_generation "injected copy publication failure: $rel"
  fi
  if ! atomic_replace "$tmp" "$dst"; then
    rm -f "$tmp" || echo "generate: warning: cannot remove unpublished copy temporary: $tmp" >&2
    fail_generation "cannot publish copied output: $rel"
  fi
  require_managed_destination "$rel" required-file
}

probe_target_status(){
  if [ "${PRKIT_GENERATOR_TEST_MODE:-}" = "1" ] \
     && [ "${PRKIT_TEST_GIT_STATUS_FAIL:-}" = "1" ]; then
    return 1
  fi
  git -C "$TARGET" status --porcelain --untracked-files=all "$@" 2>/dev/null
}

# Git status deliberately omits ignored files. Inventory ignored, untracked
# content separately for every path this generator recursively replaces or
# overwrites. Path-scoped rechecks run immediately before each destructive or
# overwrite boundary. The exclusive target lock below serializes cooperative
# generator processes for the complete mutation + verification lifecycle.
guard_managed_paths(){
  [ "$TARGET_GIT_GUARDED" -eq 1 ] || return 0
  local dirty ignored
  if ! dirty="$(probe_target_status -- "$@")"; then
    fail_generation "cannot inspect target working tree status — refusing to modify it"
  fi
  if [ -n "$dirty" ]; then
    fail_generation "managed target path became dirty (use --force to override)"
  fi
  if ! ignored="$(git -C "$TARGET" ls-files --others --ignored --exclude-standard -- "$@" 2>/dev/null)"; then
    fail_generation "cannot inventory ignored content under managed target paths"
  fi
  if [ -n "$ignored" ]; then
    fail_generation "ignored content exists under a managed target path (use --force to override)"
  fi
}

lock_error="target generation lock exists: $GENERATION_LOCK (another generator may be running; remove it only after confirming it is stale)"
if [ -e "$GENERATION_LOCK" ] || [ -L "$GENERATION_LOCK" ]; then
  fail_generation "$lock_error"
fi

if { [ -e "$TARGET/.git" ] || [ -L "$TARGET/.git" ]; } && [ "$FORCE" -eq 0 ]; then
  TARGET_GIT_GUARDED=1
  target_status=""
  if ! target_status="$(probe_target_status)"; then
    fail_generation "cannot inspect target working tree status — refusing to modify it"
  fi
  if [ -n "$target_status" ]; then
    fail_generation "target working tree is dirty (use --force to override)"
  fi
  guard_managed_paths "${MANAGED_PATHS[@]}"
elif [ "$FORCE" -eq 0 ]; then
  first_entry=""
  if ! first_entry="$(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; then
    fail_generation "cannot inspect non-Git target contents — refusing to modify it"
  fi
  if [ -n "$first_entry" ]; then
    fail_generation "non-Git target is not empty (initialize Git or use --force to replace managed paths)"
  fi
fi

# Shape/containment checks are independent of Git cleanliness and are never
# bypassed by --force. Check the whole managed surface before the first write,
# then recheck individual paths immediately before each mutation boundary.
require_managed_destination "plugins/prkit" tree
require_managed_destination "codex" tree
for managed_file in \
  "README.md" "LICENSE" "NOTICE" "CHANGELOG.md" ".gitignore" \
  ".github/workflows/ci.yml" ".claude-plugin/marketplace.json" \
  ".agents/plugins/marketplace.json"; do
  require_managed_destination "$managed_file" file
done

# mkdir is the cross-platform atomic lock acquisition primitive. Cleanup uses
# rmdir (never recursive deletion), so a replaced/nonempty lock fails safely.
if ! mkdir "$GENERATION_LOCK"; then
  fail_generation "$lock_error"
fi
GENERATION_LOCK_HELD=1
cleanup_generation_lock(){
  local status=$?
  trap - EXIT
  if [ "$GENERATION_LOCK_HELD" -eq 1 ]; then
    if ! rmdir "$GENERATION_LOCK"; then
      echo "generate: cannot remove generation lock safely: $GENERATION_LOCK" >&2
      [ "$status" -ne 0 ] || status=1
    fi
    GENERATION_LOCK_HELD=0
  fi
  exit "$status"
}
trap cleanup_generation_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- 2. Clean previously generated plugin tree (leave the rest of the repo) ---
guard_managed_paths "plugins/prkit"
require_managed_destination "plugins/prkit" optional-sealed-tree
rm -rf "$P" || fail_generation "cannot remove generated plugin tree: $P"
mkdir -p "$P" || fail_generation "cannot create generated plugin tree: $P"
require_managed_destination "plugins/prkit" required-tree

# --- 3. Copy per manifest. A failed cp (e.g. a manifest source went missing in
# the SSOT) MUST abort — otherwise a broken tree ships and the "copied N" summary
# lies. copied is asserted to equal the manifest entry count. ---
copied=0; expected=0
while IFS= read -r rel; do
  rel="${rel%$'\r'}"   # strip CR (Windows Git-Bash autocrlf checkout)
  case "$rel" in ''|\#*) continue;; esac
  expected=$((expected+1))
  dst="$P/$rel"
  plugin_rel="plugins/prkit/$rel"
  copy_managed_file "$SRC/$rel" "$dst" "$plugin_rel"
  copied=$((copied+1))
done < "$MANIFEST"
[ "$copied" -eq "$expected" ] || { echo "generate: copied $copied of $expected manifest files" >&2; exit 1; }

# --- 5. Scaffold standalone-only files from templates ---
# render fails loudly: a missing template or a sed error must not silently ship a
# zero-byte scaffold (a bare `> out` redirect truncates out before sed runs, and
# the root-level scaffolds are outside verify's plugins/prkit + codex scan roots).
render(){
  local tmpl="$1" out="$2" rel="$3" out_dir tmp injected_publish injected_dir
  [ -r "$tmpl" ] || fail_generation "template missing: $tmpl"
  require_managed_destination "$rel" file
  out_dir="$(dirname "$out")" || fail_generation "cannot resolve render destination directory: $out"
  mkdir -p "$out_dir" || fail_generation "cannot create render destination directory: $out_dir"
  require_managed_destination "$rel" file
  [ -d "$out_dir" ] || fail_generation "render destination is not a directory: $out_dir"
  if ! tmp="$(mktemp "$out_dir/.prkit-render.XXXXXX")"; then
    fail_generation "cannot create destination-local render temporary: $out_dir"
  fi
  if ! sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{DATE}}/$DATE/g" "$tmpl" > "$tmp" \
     || [ ! -s "$tmp" ]; then
    rm -f "$tmp" || echo "generate: warning: cannot remove failed render temporary: $tmp" >&2
    fail_generation "render produced empty/failed output: $tmpl"
  fi
  if [ "${PRKIT_GENERATOR_TEST_MODE:-}" = "1" ] \
     && [ -n "${PRKIT_TEST_RENDER_PUBLISH_FAIL:-}" ]; then
    injected_publish="$PRKIT_TEST_RENDER_PUBLISH_FAIL"
    injected_dir="$(dirname "$injected_publish")"
    if [ -d "$injected_dir" ]; then
      injected_publish="$(cd "$injected_dir" && pwd -P)/$(basename "$injected_publish")"
    fi
    if [ "$injected_publish" = "$out" ]; then
      rm -f "$tmp" || fail_generation "injected publication failure also could not clean temporary: $tmp"
      fail_generation "injected render publication failure: $out"
    fi
  fi
  if ! check_managed_destination "$rel" file; then
    rm -f "$tmp" || echo "generate: warning: cannot remove unpublished render temporary: $tmp" >&2
    fail_generation "render destination changed before publication: $rel"
  fi
  if ! atomic_replace "$tmp" "$out"; then
    rm -f "$tmp" || echo "generate: warning: cannot remove unpublished render temporary: $tmp" >&2
    fail_generation "cannot publish rendered output: $out"
  fi
  require_managed_destination "$rel" required-file
}

render_managed(){
  local tmpl="$1" out="$2" rel="$3"
  guard_managed_paths "$rel"
  render "$tmpl" "$out" "$rel"
}

# Project the canonical UberDev run tree down to the review-only closure shipped
# by standalone prkit. Parse and publish fail closed: duplicate keys and Python's
# otherwise-accepted NaN/Infinity constants are rejected, and the exact
# deterministic bytes are reparsed before the atomic replace.
project_review_policy(){
  local policy="$1" roles_dir="$2" role_prefix="$3" role_suffix="$4"
  python3 -I -B - "$policy" "$roles_dir" "$role_prefix" "$role_suffix" <<'PY' || return 1
import json
import os
import pathlib
import stat
import sys
import tempfile

policy = pathlib.Path(sys.argv[1])
roles_dir = pathlib.Path(sys.argv[2])
role_prefix = sys.argv[3]
role_suffix = sys.argv[4]
expected_roles = {
    'ci-code-fixer', 'ci-failure-classifier', 'ci-rebase-handler',
    'code-fixer', 'code-reviewer', 'code-simplifier', 'comment-analyzer',
    'conflict-resolver', 'findings-to-issues', 'merge-strategy-decider',
    'pr-test-analyzer', 'silent-failure-hunter', 'trust-trail-evaluator',
    'type-design-analyzer',
}
allowed_workflows = ('review-pr', 'simplify', 'solve', 'turbo')
review_contract = 'phase1-reviewer-v1'
edge_semantics = {
    'review_pr.post_impl_review': ('skill', None, None, None),
    'review_pr.review.correctness': ('provider', 'code-reviewer', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.review.silent_failures': ('provider', 'silent-failure-hunter', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.review.types': ('provider', 'type-design-analyzer', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.review.comments': ('provider', 'comment-analyzer', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.review.tests': ('provider', 'pr-test-analyzer', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.review.general': ('provider', 'code-reviewer', ('review-pr', 'solve', 'turbo'), review_contract),
    'review_pr.fix.phase1': ('provider', 'code-fixer', ('review-pr', 'solve', 'turbo'), None),
    'review_pr.simplify.reuse': ('provider', 'code-simplifier', ('review-pr', 'simplify', 'solve', 'turbo'), None),
    'review_pr.simplify.quality': ('provider', 'code-simplifier', ('review-pr', 'simplify', 'solve', 'turbo'), None),
    'review_pr.simplify.efficiency': ('provider', 'code-simplifier', ('review-pr', 'simplify', 'solve', 'turbo'), None),
    'review_pr.fix.phase2': ('provider', 'code-fixer', ('review-pr', 'simplify', 'solve', 'turbo'), None),
    'review_pr.defer.findings': ('provider', 'findings-to-issues', ('review-pr', 'simplify', 'solve', 'turbo'), None),
    'review_pr.ci.classify': ('provider', 'ci-failure-classifier', ('review-pr', 'solve', 'turbo'), None),
    'review_pr.ci.fix_code': ('provider', 'ci-code-fixer', ('review-pr', 'solve', 'turbo'), None),
    'review_pr.ci.rebase': ('provider', 'ci-rebase-handler', ('review-pr', 'solve', 'turbo'), None),
    'review_pr.ci.defer_refusal': ('provider', 'findings-to-issues', ('review-pr', 'solve', 'turbo'), None),
    'review_pr.ci.resolve_conflict': ('provider', 'conflict-resolver', ('review-pr', 'solve', 'turbo'), None),
}
expected_edges = set(edge_semantics)

def reject_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result

def reject_constant(value):
    raise ValueError(f'non-finite JSON constant: {value}')

def strict_load(text):
    return json.loads(
        text,
        object_pairs_hook=reject_pairs,
        parse_constant=reject_constant,
    )

try:
    source = strict_load(policy.read_text(encoding='utf-8'))
    schema_version = source['schema_version']
    input_limits = source['input_limits']
    source_edges = source['edges']
    source_contracts = source['output_contracts']
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
    raise SystemExit(f'policy source parse failed: {exc}')
if not isinstance(source_edges, dict) or not isinstance(source_contracts, dict):
    raise SystemExit('policy source edges/output_contracts must be objects')
if schema_version != 1:
    raise SystemExit(f'unsupported policy schema_version: {schema_version!r}')
if input_limits != {'max_serialized_bytes': 49152}:
    raise SystemExit(f'invalid input limit contract: {input_limits!r}')
try:
    shipped_roles = {
        entry.name[len(role_prefix):-len(role_suffix)]
        for entry in roles_dir.iterdir()
        if entry.is_file()
        and entry.name.startswith(role_prefix)
        and entry.name.endswith(role_suffix)
    }
except OSError as exc:
    raise SystemExit(f'policy shipped-role discovery failed: {exc}')
if shipped_roles != expected_roles:
    raise SystemExit(f'policy shipped-role set mismatch: {sorted(shipped_roles)}')

selected_edge_ids = {
    edge_id for edge_id in source_edges
    if isinstance(edge_id, str) and edge_id.startswith('review_pr.')
}
if selected_edge_ids != expected_edges:
    raise SystemExit(
        'policy review edge grammar mismatch: '
        f'missing={sorted(expected_edges - selected_edge_ids)} '
        f'unexpected={sorted(selected_edge_ids - expected_edges)}'
    )

edges = {}
for edge_id in sorted(expected_edges):
    original = source_edges[edge_id]
    if not isinstance(original, dict):
        raise SystemExit(f'policy edge must be an object: {edge_id}')
    edge = dict(original)
    expected_kind, expected_role, expected_workflows, expected_contract = edge_semantics[edge_id]
    if edge.get('kind') != expected_kind:
        raise SystemExit(f'policy edge kind mismatch: {edge_id}')
    if expected_kind == 'provider':
        role = edge.get('role')
        if role != expected_role or role not in shipped_roles:
            raise SystemExit(f'policy edge role mismatch: {edge_id}')
        workflows = edge['allowed_workflows']
        if not isinstance(workflows, list) or not all(isinstance(item, str) for item in workflows):
            raise SystemExit(f'policy edge workflows must be a string array: {edge_id}')
        edge['allowed_workflows'] = [
            workflow for workflow in allowed_workflows if workflow in workflows
        ]
        if tuple(edge['allowed_workflows']) != expected_workflows:
            raise SystemExit(f'policy edge workflow mismatch: {edge_id}')
    elif edge.get('role') is not None or edge.get('allowed_workflows') is not None:
        raise SystemExit(f'policy structural edge semantics mismatch: {edge_id}')
    actual_contract = edge.get('output_contract')
    if actual_contract != expected_contract or (expected_contract is None and 'output_contract' in edge):
        raise SystemExit(f'policy edge output contract mismatch: {edge_id}')
    edges[edge_id] = edge

contract_ids = {
    edge['output_contract']
    for edge in edges.values()
    if 'output_contract' in edge
}
if not all(isinstance(contract_id, str) for contract_id in contract_ids):
    raise SystemExit('policy output_contract references must be strings')
missing_contracts = contract_ids.difference(source_contracts)
if missing_contracts:
    raise SystemExit(f'policy projection references missing contracts: {sorted(missing_contracts)}')

projected = {
    'schema_version': schema_version,
    'tree_id': 'review-pr-run-tree-v1',
    'root_edge_id': 'review_pr.post_impl_review',
    'input_limits': input_limits,
    'output_contracts': {
        contract_id: source_contracts[contract_id]
        for contract_id in sorted(contract_ids)
    },
    'edges': edges,
}
try:
    serialized = (json.dumps(
        projected,
        sort_keys=True,
        allow_nan=False,
        indent=2,
    ) + '\n').encode('utf-8')
    reparsed = strict_load(serialized.decode('utf-8'))
except (TypeError, ValueError, json.JSONDecodeError) as exc:
    raise SystemExit(f'policy projection serialization failed: {exc}')
if reparsed != projected:
    raise SystemExit('policy projection changed during deterministic reparse')

temporary = None
try:
    mode = stat.S_IMODE(policy.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix='.solve-run-tree.', dir=policy.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(serialized)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    if os.environ.get('PRKIT_GENERATOR_TEST_MODE') == '1' and os.environ.get('PRKIT_TEST_POLICY_PUBLISH_FAIL') == '1':
        raise OSError('injected policy publication failure')
    os.replace(temporary, policy)
except OSError as exc:
    if temporary is not None:
        try:
            os.unlink(temporary)
        except OSError:
            pass
    raise SystemExit(f'policy projection publish failed: {exc}')
PY
}

# --- 4. Project the copied canonical policy, then rewrite every copied file.
# JSON policy files contain no uberdev token, so perl is a byte-preserving
# no-op on them; every copied file is text. ---
require_managed_destination "plugins/prkit/policy/solve-run-tree-v1.json" required-file
project_review_policy "$P/policy/solve-run-tree-v1.json" "$P/agents" "" ".md" \
  || { echo "generate: Claude policy projection failed" >&2; exit 1; }
require_managed_destination "plugins/prkit/policy/solve-run-tree-v1.json" required-file
rw_rc=0
while IFS= read -r -d '' f; do
  prkit_neutralize "$f" || { echo "generate: neutralize failed: $f" >&2; rw_rc=1; }
  prkit_apply_rewrites "$f" || { echo "generate: rewrite failed: $f" >&2; rw_rc=1; }
done < <(find "$P" -type f -print0)
[ "$rw_rc" -eq 0 ] || { echo "generate: rewrite pass had failures" >&2; exit 1; }

render "$TEMPLATES/plugin.json.tmpl"       "$P/.claude-plugin/plugin.json" "plugins/prkit/.claude-plugin/plugin.json"
render_managed "$TEMPLATES/marketplace.json.tmpl" "$TARGET/.claude-plugin/marketplace.json" ".claude-plugin/marketplace.json"
render_managed "$TEMPLATES/README.md.tmpl"        "$TARGET/README.md"                       "README.md"
render_managed "$TEMPLATES/LICENSE.tmpl"          "$TARGET/LICENSE"                         "LICENSE"
render_managed "$TEMPLATES/NOTICE.tmpl"           "$TARGET/NOTICE"                          "NOTICE"
render_managed "$TEMPLATES/CHANGELOG.md.tmpl"      "$TARGET/CHANGELOG.md"                    "CHANGELOG.md"
render_managed "$TEMPLATES/gitignore.tmpl"        "$TARGET/.gitignore"                      ".gitignore"
render_managed "$TEMPLATES/ci.yml.tmpl"           "$TARGET/.github/workflows/ci.yml"         ".github/workflows/ci.yml"

# --- 5b. Codex port (mandatory inputs were validated before target mutation) ---
cx_copied=0; cx_scaffolded=0
  # The prkit repo's entire codex/ tree is generated — clean it for an idempotent
  # regenerate (no stale files if the manifest shrinks).
  guard_managed_paths "codex"
  require_managed_destination "codex" optional-sealed-tree
  rm -rf "$TARGET/codex" || fail_generation "cannot remove generated Codex tree"
  # Copy each codex source to a dest path with uberdev->prkit applied
  # (codex/uberdev-codex -> codex/prkit-codex, uberdev-cmd- -> prkit-cmd-,
  #  codex/agents/uberdev-<a>.toml -> codex/agents/prkit-<a>.toml).
  cx_expected=0
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"   # strip CR (Windows Git-Bash autocrlf checkout)
    case "$rel" in ''|\#*) continue;; esac
    cx_expected=$((cx_expected+1))
    # uberdev->prkit, PLUS prefix the two support-skill dirs: Codex installs skills
    # into a FLAT ~/.agents/skills/, so plain post-impl-review / merge-pipeline would
    # collide with an UberDev-for-Codex install. The command-skills (prkit-cmd-*) and
    # agents (prkit-*.toml) are already namespaced.
    drel="$(printf '%s' "$rel" | sed -e 's/uberdev/prkit/g' \
              -e 's#/skills/post-impl-review/#/skills/prkit-post-impl-review/#' \
              -e 's#/skills/merge-pipeline/#/skills/prkit-merge-pipeline/#')"
    dst="$TARGET/$drel"
    copy_managed_file "$REPO_ROOT/$rel" "$dst" "$drel"
    cx_copied=$((cx_copied+1))
  done < "$MANIFEST_CODEX"
  [ "$cx_copied" -eq "$cx_expected" ] || { echo "generate: codex copied $cx_copied of $cx_expected files" >&2; exit 1; }
  require_managed_destination "codex" required-tree
  require_managed_destination "codex/prkit-codex/policy/solve-run-tree-v1.json" required-file
  project_review_policy "$TARGET/codex/prkit-codex/policy/solve-run-tree-v1.json" \
    "$TARGET/codex/agents" "prkit-" ".toml" \
    || { echo "generate: Codex policy projection failed" >&2; exit 1; }
  require_managed_destination "codex/prkit-codex/policy/solve-run-tree-v1.json" required-file
  # Rewrite content of every copied codex file (neutralize out-of-set, then blanket).
  while IFS= read -r -d '' f; do
    prkit_neutralize "$f" || { echo "generate: codex neutralize failed: $f" >&2; rw_rc=1; }
    prkit_apply_rewrites "$f" || { echo "generate: codex rewrite failed: $f" >&2; rw_rc=1; }
  done < <(find "$TARGET/codex" -type f -print0)
  [ "$rw_rc" -eq 0 ] || { echo "generate: codex rewrite pass had failures" >&2; exit 1; }
  # Repoint references to the two prefixed support-skill dirs (codex tree only —
  # the Claude tree keeps prkit:post-impl-review via plugin-scoping).
  while IFS= read -r -d '' f; do
    perl -0pi -e '
      s{prkit:post-impl-review}{prkit-post-impl-review}g;
      s{prkit:merge-pipeline}{prkit-merge-pipeline}g;
      s{skills/post-impl-review}{skills/prkit-post-impl-review}g;
      s{skills/merge-pipeline}{skills/prkit-merge-pipeline}g;
    ' "$f" || { echo "generate: codex skill-prefix rewrite failed: $f" >&2; exit 1; }
  done < <(find "$TARGET/codex" -type f \
    ! -path "$TARGET/codex/prkit-codex/policy/solve-run-tree-v1.json" -print0)
  # install-codex.sh is shared SSOT with full UberDev, whose comments and
  # verification hints describe the full fleet. The standalone extraction has
  # a deliberately smaller manifest (5 skills / 14 agents); rewrite those
  # user-facing counts here so generated installation guidance cannot claim a
  # fleet that prkit does not ship.
  require_managed_destination "codex/install-codex.sh" required-file
  python3 -I -B - "$TARGET" <<'PY' || {
import os,pathlib,stat,sys,tempfile
root=pathlib.Path(sys.argv[1])
skills=root/'codex/prkit-codex/skills'; agents=root/'codex/agents'; installer=root/'codex/install-codex.sh'
try:
 skill_count=sum(1 for entry in skills.iterdir() if entry.is_dir())
 agent_count=sum(1 for entry in agents.iterdir() if entry.is_file() and entry.name.startswith('prkit-') and entry.suffix=='.toml')
except OSError as exc:
 raise SystemExit(f'count discovery failed: {exc}')
if (skill_count,agent_count)!=(5,14):
 raise SystemExit(f'unexpected standalone fleet counts: skills={skill_count} agents={agent_count}')
try: source=installer.read_text()
except OSError as exc: raise SystemExit(f'installer read failed: {exc}')
rewrites=(
 ('NOT the 44 agents',f'NOT the {agent_count} agents'),
 ('# ~39 Prkit skills incl. command-skills',f'# {skill_count} prkit skills'),
 ('# 44 prkit-*.toml subagents',f'# {agent_count} prkit-*.toml subagents'),
)
for old,new in rewrites:
 if source.count(old)!=1: raise SystemExit(f'installer rewrite anchor count is not one: {old}')
 source=source.replace(old,new)
if any(source.count(new)!=1 for _,new in rewrites):
 raise SystemExit('installer rewrite verification failed')
try:
 mode=stat.S_IMODE(installer.stat().st_mode)
 fd,temporary=tempfile.mkstemp(prefix='.install-codex.',dir=installer.parent)
 with os.fdopen(fd,'w',encoding='utf-8') as stream:
  stream.write(source); stream.flush(); os.fsync(stream.fileno())
 os.chmod(temporary,mode)
 os.replace(temporary,installer)
except OSError as exc:
 try: os.unlink(temporary)
 except (NameError,OSError): pass
 raise SystemExit(f'installer rewrite failed: {exc}')
PY
    echo "generate: codex installer count rewrite failed" >&2
    exit 1
  }
  require_managed_destination "codex/install-codex.sh" required-file
  # Scaffold codex-specific files from prkit-correct templates (authored, not
  # rewritten — so they don't inherit UberDev's stale counts). AFTER the rewrite
  # loop so they stay pristine.
  render "$TEMPLATES/codex-plugin.json.tmpl" "$TARGET/codex/prkit-codex/.codex-plugin/plugin.json" \
    "codex/prkit-codex/.codex-plugin/plugin.json"
  render "$TEMPLATES/codex-README.md.tmpl" "$TARGET/codex/README.md" "codex/README.md"
  render "$TEMPLATES/codex-AGENTS.md.tmpl" "$TARGET/codex/AGENTS.md" "codex/AGENTS.md"
  render_managed "$TEMPLATES/codex-marketplace.json.tmpl" \
    "$TARGET/.agents/plugins/marketplace.json" ".agents/plugins/marketplace.json"
  cx_scaffolded=4
  # Restore exec bits on the entry scripts (cp preserves mode, but be explicit).
  require_managed_destination "codex/install-codex.sh" required-file
  chmod +x "$TARGET/codex/install-codex.sh" \
    || fail_generation "cannot mark Codex installer executable"
  require_managed_destination "codex/install-codex.sh" required-file
  [ -x "$TARGET/codex/install-codex.sh" ] \
    || fail_generation "Codex installer executable postcondition failed"
  require_managed_destination "codex/prkit-codex/hooks/session-start" required-file
  chmod +x "$TARGET/codex/prkit-codex/hooks/session-start" \
    || fail_generation "cannot mark Codex session-start hook executable"
  require_managed_destination "codex/prkit-codex/hooks/session-start" required-file
  [ -x "$TARGET/codex/prkit-codex/hooks/session-start" ] \
    || fail_generation "Codex session-start executable postcondition failed"

# --- 6. Verify (fail the whole run on any violation; covers both trees) ---
if ! bash "$HERE/verify.sh" "$TARGET"; then
  echo "generate: VERIFY FAILED — output left in $TARGET for inspection" >&2
  exit 1
fi
require_managed_destination "plugins/prkit" sealed-tree
require_managed_destination "codex" sealed-tree

# --- 7. Summary ---
echo "generate: OK — copied $copied claude + $cx_copied codex files, scaffolded $((8 + cx_scaffolded)), verified."
echo "generate: next -> git -C '$TARGET' add -A && git -C '$TARGET' commit -m 'chore: regenerate prkit $VERSION'"

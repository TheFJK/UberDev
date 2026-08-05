#!/usr/bin/env bash
# tests/prkit-generate.test.sh — end-to-end: generate a prkit tree into a scratch
# target, assert the verify gate passes, and assert determinism (two runs identical).
# Unix-only (perl + python3 + jq); declared in the test.yml windows-skip marker.
set -u
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/tools/prkit/generate.sh"
VERIFY="$REPO_ROOT/tools/prkit/verify.sh"
PATH_GUARD="$REPO_ROOT/tools/prkit/managed-path-guard.py"
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
echo "## prkit generate e2e (RFC 0014)"
[ -r "$GEN" ] || { echo "  ABORT — generate.sh missing"; exit 99; }

# T1's path deliberately CONTAINS A SPACE ("prkit tgt") — the real target lives at
# "/Volumes/FJK SSD/Cursor/prkit", and an earlier verify.sh regression word-split on
# that space. Keeping a spaced target here locks the fix in. T2 is space-free so G5
# also proves the generated output is independent of the target path.
_B1="$(mktemp -d)"; _B2="$(mktemp -d)"; _B3="$(mktemp -d)"
_B4="$(mktemp -d)"; _B5="$(mktemp -d)"; _B6="$(mktemp -d)"; _B7="$(mktemp -d)"; _B8="$(mktemp -d)"
_B9="$(mktemp -d)"; _B10="$(mktemp -d)"; _B11="$(mktemp -d)"; _B12="$(mktemp -d)"
_B13="$(mktemp -d)"; _B14="$(mktemp -d)"; _B15="$(mktemp -d)"; _B16="$(mktemp -d)"
T1="$_B1/prkit tgt"; T2="$_B2/out"
mkdir -p "$T1" "$T2"; trap 'rm -rf "$_B1" "$_B2" "$_B3" "$_B4" "$_B5" "$_B6" "$_B7" "$_B8" "$_B9" "$_B10" "$_B11" "$_B12" "$_B13" "$_B14" "$_B15" "$_B16"' EXIT
G1_INIT_TEMPLATE="$_B1/init-template"
G1_EMPTY_TEMPLATE="$_B1/empty-template"
G1_GLOBAL_CONFIG="$_B1/global.gitconfig"
G1_EMPTY_CONFIG="$_B1/empty.gitconfig"
G1_COMMAND_EXCLUDES="$_B1/command-excludes"
mkdir -p "$G1_INIT_TEMPLATE/info" "$G1_EMPTY_TEMPLATE"
printf '.prkit-generate.lock\n' > "$G1_INIT_TEMPLATE/info/exclude"
printf '.prkit*\n' > "$G1_COMMAND_EXCLUDES"
git config --file "$G1_GLOBAL_CONFIG" init.templateDir "$G1_INIT_TEMPLATE"
: > "$G1_EMPTY_CONFIG"
G1_CONFIG_PARAMETERS="'core.excludesFile'='$G1_COMMAND_EXCLUDES' 'init.templateDir'='$G1_INIT_TEMPLATE'"
GIT_CONFIG_GLOBAL="$G1_GLOBAL_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$G1_COMMAND_EXCLUDES" \
  GIT_CONFIG_KEY_1=init.templateDir GIT_CONFIG_VALUE_1="$G1_INIT_TEMPLATE" \
  GIT_CONFIG_PARAMETERS="$G1_CONFIG_PARAMETERS" \
  git -C "$T1" init -q --template="$G1_EMPTY_TEMPLATE"
GIT_CONFIG_GLOBAL="$G1_GLOBAL_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$G1_COMMAND_EXCLUDES" \
  GIT_CONFIG_KEY_1=init.templateDir GIT_CONFIG_VALUE_1="$G1_INIT_TEMPLATE" \
  GIT_CONFIG_PARAMETERS="$G1_CONFIG_PARAMETERS" \
  git -C "$T2" init -q --template="$G1_EMPTY_TEMPLATE"

# G1 — generate into a clean target succeeds and self-verifies
G1_OUTPUT=""
if G1_OUTPUT="$(
     GIT_CONFIG_COUNT=2 \
     GIT_CONFIG_KEY_0=core.excludesFile \
     GIT_CONFIG_VALUE_0="$G1_COMMAND_EXCLUDES" \
     GIT_CONFIG_KEY_1=init.templateDir \
     GIT_CONFIG_VALUE_1="$G1_INIT_TEMPLATE" \
     GIT_CONFIG_KEY_7=core.excludesFile \
     GIT_CONFIG_VALUE_7="$G1_COMMAND_EXCLUDES" \
     GIT_CONFIG_PARAMETERS="$G1_CONFIG_PARAMETERS" \
       bash "$GEN" --target "$T1" --version 0.1.0 2>&1
   )" \
   && [ ! -e "$T1/.prkit-generate.lock" ]; then
  ok "G1 generate exits 0 under hostile command-scope Git config (verify passed, lock cleaned)"
else
  no "G1 generate inherited hostile command-scope Git config, failed, or leaked its lock"
fi
if GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$G1_EMPTY_CONFIG" \
     git -C "$T1" check-ignore -q --no-index -- .prkit/audit.jsonl \
   && ! GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$G1_EMPTY_CONFIG" \
     git -C "$T1" check-ignore -q --no-index -- .prkit-generate.lock; then
  ok "G1a generated ignore contract covers .prkit artifacts but not the generation lock"
else
  no "G1a generated ignore contract is missing, overbroad, or ineffective"
fi

# G1b — linked worktrees represent .git as a FILE. Dirty tracked and untracked
# content must both fail closed without --force and remain byte-for-byte intact;
# after restoring the fixture to clean state, generation must still work.
GIT_SOURCE="$_B3/source"; GIT_LINKED="$_B3/linked target"
mkdir -p "$GIT_SOURCE"
git -C "$GIT_SOURCE" init -q
git -C "$GIT_SOURCE" config user.email prkit-test@example.invalid
git -C "$GIT_SOURCE" config user.name "prkit test"
printf 'tracked fixture\n' > "$GIT_SOURCE/tracked.txt"
git -C "$GIT_SOURCE" add tracked.txt
git -C "$GIT_SOURCE" commit -qm "test: linked worktree fixture"
git -C "$GIT_SOURCE" worktree add --detach "$GIT_LINKED" HEAD >/dev/null 2>&1
printf 'untracked sentinel\n' > "$GIT_LINKED/untracked.txt"
before_status="$(git -C "$GIT_LINKED" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$GIT_LINKED" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$GIT_LINKED/untracked.txt" 2>/dev/null)" != "untracked sentinel" ] \
   || [ "$(git -C "$GIT_LINKED" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1b linked worktree rejects and preserves dirty untracked content"
else
  ok "G1b linked worktree rejects and preserves dirty untracked content"
fi
rm -f "$GIT_LINKED/untracked.txt"
printf 'dirty tracked sentinel\n' > "$GIT_LINKED/tracked.txt"
before_status="$(git -C "$GIT_LINKED" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$GIT_LINKED" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$GIT_LINKED/tracked.txt" 2>/dev/null)" != "dirty tracked sentinel" ] \
   || [ "$(git -C "$GIT_LINKED" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1c linked worktree rejects and preserves dirty tracked content"
else
  ok "G1c linked worktree rejects and preserves dirty tracked content"
fi
printf 'tracked fixture\n' > "$GIT_LINKED/tracked.txt"
if [ ! -f "$GIT_LINKED/.git" ]; then
  no "G1d regression fixture is not a real linked worktree"
elif bash "$GEN" --target "$GIT_LINKED" --version 0.1.0 >/dev/null 2>&1; then
  ok "G1d clean linked worktree remains a supported generation target"
else
  no "G1d clean linked worktree generation failed"
fi

# G1e — git status intentionally omits ignored files. Every path the generator
# recursively replaces or overwrites must therefore get an explicit ignored-file
# inventory before mutation. Use the repository-local exclude file so even
# .gitignore itself can be an ignored, untracked sentinel.
IGNORED_LOCAL="$_B4/local excluded target"
mkdir -p "$IGNORED_LOCAL"
git -C "$IGNORED_LOCAL" init -q
git -C "$IGNORED_LOCAL" config user.email prkit-test@example.invalid
git -C "$IGNORED_LOCAL" config user.name "prkit test"
git -C "$IGNORED_LOCAL" commit --allow-empty -qm "test: local exclude fixture"
ignored_paths=(
  "plugins/prkit/ignored-sentinel.txt"
  "codex/ignored-sentinel.txt"
  "README.md"
  "LICENSE"
  "NOTICE"
  "CHANGELOG.md"
  ".gitignore"
  ".github/workflows/ci.yml"
  ".claude-plugin/marketplace.json"
  ".agents/plugins/marketplace.json"
)
local_exclude="$(git -C "$IGNORED_LOCAL" rev-parse --git-path info/exclude)"
case "$local_exclude" in
  /*) ;;
  *) local_exclude="$IGNORED_LOCAL/$local_exclude" ;;
esac
printf '%s\n' "${ignored_paths[@]}" >> "$local_exclude"
for rel in "${ignored_paths[@]}"; do
  mkdir -p "$IGNORED_LOCAL/$(dirname "$rel")"
  printf 'ignored sentinel: %s\n' "$rel" > "$IGNORED_LOCAL/$rel"
done
before_status="$(git -C "$IGNORED_LOCAL" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$IGNORED_LOCAL" --version 0.1.0 >/dev/null 2>&1; then
  rejected=0
else
  rejected=1
fi
preserved=1
for rel in "${ignored_paths[@]}"; do
  [ "$(cat "$IGNORED_LOCAL/$rel" 2>/dev/null)" = "ignored sentinel: $rel" ] || preserved=0
done
if [ "$rejected" -eq 1 ] && [ "$preserved" -eq 1 ] \
   && [ "$(git -C "$IGNORED_LOCAL" status --porcelain --untracked-files=all)" = "$before_status" ]; then
  ok "G1e local-excluded content across every managed target is rejected and preserved"
else
  no "G1e local-excluded content was accepted, deleted, or overwritten"
fi
if bash "$GEN" --target "$IGNORED_LOCAL" --version 0.1.0 --force >/dev/null 2>&1; then
  force_ok=1
  for rel in "${ignored_paths[@]}"; do
    grep -qxF "ignored sentinel: $rel" "$IGNORED_LOCAL/$rel" 2>/dev/null && force_ok=0
  done
  if [ "$force_ok" -eq 1 ]; then
    ok "G1f --force intentionally replaces ignored managed content"
  else
    no "G1f --force left ignored managed sentinels behind"
  fi
else
  no "G1f --force no longer permits intentional regeneration"
fi

# G1g — repository .gitignore rules are a second ignore source and must receive
# the same protection as info/exclude.
IGNORED_REPO="$_B5/repository ignored target"
mkdir -p "$IGNORED_REPO"
git -C "$IGNORED_REPO" init -q
git -C "$IGNORED_REPO" config user.email prkit-test@example.invalid
git -C "$IGNORED_REPO" config user.name "prkit test"
printf 'plugins/prkit/repository-ignored.txt\n' > "$IGNORED_REPO/.gitignore"
git -C "$IGNORED_REPO" add .gitignore
git -C "$IGNORED_REPO" commit -qm "test: repository ignore fixture"
mkdir -p "$IGNORED_REPO/plugins/prkit"
printf 'repository ignored sentinel\n' > "$IGNORED_REPO/plugins/prkit/repository-ignored.txt"
before_status="$(git -C "$IGNORED_REPO" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$IGNORED_REPO" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$IGNORED_REPO/plugins/prkit/repository-ignored.txt" 2>/dev/null)" != "repository ignored sentinel" ] \
   || [ "$(git -C "$IGNORED_REPO" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1g repository-ignored generated-root content was accepted or mutated"
else
  ok "G1g repository-ignored generated-root content is rejected and preserved"
fi

# G1h — if the status probe itself cannot establish cleanliness, generation
# must stop before changing even one byte. Injection keeps this deterministic
# across hosts and avoids depending on filesystem permissions or PATH tricks.
STATUS_FAIL="$_B7/status probe target"
mkdir -p "$STATUS_FAIL"
git -C "$STATUS_FAIL" init -q
git -C "$STATUS_FAIL" config user.email prkit-test@example.invalid
git -C "$STATUS_FAIL" config user.name "prkit test"
printf 'status probe sentinel\n' > "$STATUS_FAIL/tracked.txt"
git -C "$STATUS_FAIL" add tracked.txt
git -C "$STATUS_FAIL" commit -qm "test: status probe fixture"
before_status="$(git -C "$STATUS_FAIL" status --porcelain --untracked-files=all)"
if PRKIT_GENERATOR_TEST_MODE=1 PRKIT_TEST_GIT_STATUS_FAIL=1 \
     bash "$GEN" --target "$STATUS_FAIL" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$STATUS_FAIL/tracked.txt" 2>/dev/null)" != "status probe sentinel" ] \
   || [ "$(git -C "$STATUS_FAIL" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1h failed status probe was accepted or mutated target bytes"
else
  ok "G1h failed status probe refuses generation and preserves target bytes"
fi

# G1i — a fresh non-Git directory remains a supported bootstrap target. Once a
# non-Git target contains any entry, ownership is unknowable: refuse without
# --force, preserve every byte, and keep --force as the explicit replacement
# acknowledgement.
NONGIT_EMPTY="$_B8/empty target"
mkdir -p "$NONGIT_EMPTY"
if bash "$GEN" --target "$NONGIT_EMPTY" --version 0.1.0 >/dev/null 2>&1; then
  ok "G1i empty non-Git target remains supported"
else
  no "G1i empty non-Git target was rejected"
fi
NONGIT_DIR="$_B8/nonempty target"
mkdir -p "$NONGIT_DIR/plugins/prkit"
printf 'unrelated non-git sentinel\n' > "$NONGIT_DIR/user-owned.txt"
printf 'managed non-git sentinel\n' > "$NONGIT_DIR/plugins/prkit/user-owned.txt"
if bash "$GEN" --target "$NONGIT_DIR" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$NONGIT_DIR/user-owned.txt" 2>/dev/null)" != "unrelated non-git sentinel" ] \
   || [ "$(cat "$NONGIT_DIR/plugins/prkit/user-owned.txt" 2>/dev/null)" != "managed non-git sentinel" ]; then
  no "G1j non-empty non-Git target was accepted or mutated without --force"
else
  ok "G1j non-empty non-Git target is rejected and preserved without --force"
fi
if bash "$GEN" --target "$NONGIT_DIR" --version 0.1.0 --force >/dev/null 2>&1 \
   && [ "$(cat "$NONGIT_DIR/user-owned.txt" 2>/dev/null)" = "unrelated non-git sentinel" ] \
   && [ ! -e "$NONGIT_DIR/plugins/prkit/user-owned.txt" ]; then
  ok "G1k --force intentionally regenerates a non-empty non-Git target"
else
  no "G1k --force non-Git override failed or touched unrelated bytes"
fi

# G1l/G1m — Codex source inputs are mandatory, not an optional late-stage
# enhancement. A missing manifest or source directory must fail in preflight,
# before any target byte changes. Test-only path overrides exercise the real
# readability/existence checks without renaming shared repository inputs.
CODEX_MANIFEST_TARGET="$_B9/missing manifest target"
mkdir -p "$CODEX_MANIFEST_TARGET"
git -C "$CODEX_MANIFEST_TARGET" init -q
git -C "$CODEX_MANIFEST_TARGET" config user.email prkit-test@example.invalid
git -C "$CODEX_MANIFEST_TARGET" config user.name "prkit test"
printf 'missing manifest sentinel\n' > "$CODEX_MANIFEST_TARGET/tracked.txt"
git -C "$CODEX_MANIFEST_TARGET" add tracked.txt
git -C "$CODEX_MANIFEST_TARGET" commit -qm "test: missing Codex manifest fixture"
before_status="$(git -C "$CODEX_MANIFEST_TARGET" status --porcelain --untracked-files=all)"
if PRKIT_GENERATOR_TEST_MODE=1 PRKIT_TEST_CODEX_MANIFEST_PATH="$_B9/does-not-exist.txt" \
     bash "$GEN" --target "$CODEX_MANIFEST_TARGET" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$CODEX_MANIFEST_TARGET/tracked.txt" 2>/dev/null)" != "missing manifest sentinel" ] \
   || [ "$(git -C "$CODEX_MANIFEST_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1l missing Codex manifest was accepted or mutated target bytes"
else
  ok "G1l missing Codex manifest fails preflight and preserves target bytes"
fi

CODEX_SOURCE_TARGET="$_B10/missing source target"
mkdir -p "$CODEX_SOURCE_TARGET"
git -C "$CODEX_SOURCE_TARGET" init -q
git -C "$CODEX_SOURCE_TARGET" config user.email prkit-test@example.invalid
git -C "$CODEX_SOURCE_TARGET" config user.name "prkit test"
printf 'missing source sentinel\n' > "$CODEX_SOURCE_TARGET/tracked.txt"
git -C "$CODEX_SOURCE_TARGET" add tracked.txt
git -C "$CODEX_SOURCE_TARGET" commit -qm "test: missing Codex source fixture"
before_status="$(git -C "$CODEX_SOURCE_TARGET" status --porcelain --untracked-files=all)"
if PRKIT_GENERATOR_TEST_MODE=1 PRKIT_TEST_CODEX_SOURCE_PATH="$_B10/does-not-exist" \
     bash "$GEN" --target "$CODEX_SOURCE_TARGET" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$CODEX_SOURCE_TARGET/tracked.txt" 2>/dev/null)" != "missing source sentinel" ] \
   || [ "$(git -C "$CODEX_SOURCE_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1m missing Codex source was accepted or mutated target bytes"
else
  ok "G1m missing Codex source fails preflight and preserves target bytes"
fi

# G1n/G1o — every existing component below resolved TARGET must be a real
# directory, never a symlink. Use independent clean tracked fixtures so an early
# plugins rejection cannot mask an unsafe later .agents publication boundary.
DELETE_TARGET="$_B11/delete symlink target"
DELETE_OUTSIDE="$_B11/delete outside"
mkdir -p "$DELETE_TARGET" "$DELETE_OUTSIDE/prkit"
printf 'external delete sentinel\n' > "$DELETE_OUTSIDE/prkit/sentinel.txt"
git -C "$DELETE_TARGET" init -q
git -C "$DELETE_TARGET" config user.email prkit-test@example.invalid
git -C "$DELETE_TARGET" config user.name "prkit test"
ln -s "$DELETE_OUTSIDE" "$DELETE_TARGET/plugins"
git -C "$DELETE_TARGET" add plugins
git -C "$DELETE_TARGET" commit -qm "test: destructive ancestor symlink fixture"
before_status="$(git -C "$DELETE_TARGET" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$DELETE_TARGET" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$DELETE_OUTSIDE/prkit/sentinel.txt" 2>/dev/null)" != "external delete sentinel" ] \
   || [ "$(git -C "$DELETE_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1n plugins ancestor symlink escaped target containment"
else
  ok "G1n plugins ancestor symlink cannot delete external bytes"
fi
if bash "$GEN" --target "$DELETE_TARGET" --version 0.1.0 --force >/dev/null 2>&1 \
   || [ "$(cat "$DELETE_OUTSIDE/prkit/sentinel.txt" 2>/dev/null)" != "external delete sentinel" ] \
   || [ "$(git -C "$DELETE_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1na --force bypassed plugins ancestor containment"
else
  ok "G1na --force cannot bypass external-delete containment"
fi

WRITE_TARGET="$_B11/write symlink target"
WRITE_OUTSIDE="$_B11/write outside"
mkdir -p "$WRITE_TARGET" "$WRITE_OUTSIDE"
printf 'external write sentinel\n' > "$WRITE_OUTSIDE/sentinel.txt"
git -C "$WRITE_TARGET" init -q
git -C "$WRITE_TARGET" config user.email prkit-test@example.invalid
git -C "$WRITE_TARGET" config user.name "prkit test"
ln -s "$WRITE_OUTSIDE" "$WRITE_TARGET/.agents"
git -C "$WRITE_TARGET" add .agents
git -C "$WRITE_TARGET" commit -qm "test: publication ancestor symlink fixture"
before_status="$(git -C "$WRITE_TARGET" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$WRITE_TARGET" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$WRITE_OUTSIDE/sentinel.txt" 2>/dev/null)" != "external write sentinel" ] \
   || [ -e "$WRITE_OUTSIDE/plugins/marketplace.json" ] \
   || [ "$(git -C "$WRITE_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1o .agents ancestor symlink escaped target containment"
else
  ok "G1o .agents ancestor symlink cannot write external bytes"
fi
if bash "$GEN" --target "$WRITE_TARGET" --version 0.1.0 --force >/dev/null 2>&1 \
   || [ "$(cat "$WRITE_OUTSIDE/sentinel.txt" 2>/dev/null)" != "external write sentinel" ] \
   || [ -e "$WRITE_OUTSIDE/plugins/marketplace.json" ] \
   || [ "$(git -C "$WRITE_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1oa --force bypassed .agents ancestor containment"
else
  ok "G1oa --force cannot bypass external-write containment"
fi

# G1p — a managed file destination may be absent or a regular file only. A
# tracked directory at README.md must be rejected before a render temporary can
# be moved inside it.
DIRECTORY_TARGET="$_B12/directory output target"
mkdir -p "$DIRECTORY_TARGET/README.md"
printf 'directory output sentinel\n' > "$DIRECTORY_TARGET/README.md/sentinel.txt"
git -C "$DIRECTORY_TARGET" init -q
git -C "$DIRECTORY_TARGET" config user.email prkit-test@example.invalid
git -C "$DIRECTORY_TARGET" config user.name "prkit test"
git -C "$DIRECTORY_TARGET" add README.md/sentinel.txt
git -C "$DIRECTORY_TARGET" commit -qm "test: directory output fixture"
before_status="$(git -C "$DIRECTORY_TARGET" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$DIRECTORY_TARGET" --version 0.1.0 >/dev/null 2>&1 \
   || [ "$(cat "$DIRECTORY_TARGET/README.md/sentinel.txt" 2>/dev/null)" != "directory output sentinel" ] \
   || [ -n "$(find "$DIRECTORY_TARGET/README.md" -maxdepth 1 -name '.prkit-render.*' -print -quit)" ] \
   || [ "$(git -C "$DIRECTORY_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1p managed directory output was accepted, mutated, or received a temporary"
else
  ok "G1p managed file output rejects a directory without mutation or temp leak"
fi

# G1q — direct contract test for the shared component-wise guard. Bad relative
# path grammar must fail, required files must exist, and a synthetic Windows
# junction/reparse-point attribute must be rejected even on this Unix runner.
if python3 -I -B - "$PATH_GUARD" <<'PY'
import importlib.util
import os
import pathlib
import stat
import sys
import tempfile
import types

guard_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("prkit_managed_path_guard", guard_path)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load managed path guard")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    (root / "real").mkdir()
    guard.validate_managed_path(root, "real/output.txt", "file")
    guard.validate_managed_path(root, "real", "required-tree")
    try:
        guard.validate_managed_path(root, "real/missing.txt", "required-file")
    except guard.GuardError:
        pass
    else:
        raise AssertionError("required-file accepted a missing path")

    invalid = (
        "", "/absolute", "//server/share", "C:/drive", r"C:\drive",
        r"real\backslash", "real//empty", "real/./dot", "real/../escape",
        "real/trailing/", "CON", "con.txt", "PRN.md", "AUX", "NUL.json",
        "CLOCK$.txt", "CONIN$", "CONOUT$.txt", "COM1.log", "LPT9",
        "COM¹.txt", "LPT³", "real/ads:name", "real/trailing.",
        "real/trailing ", 'real/bad"name', "real/bad|name",
        "real/bad<name", "real/bad>name", "real/bad?name",
        "real/bad*name", "real/control\x01name",
    )
    had_isreserved = hasattr(guard.ntpath, "isreserved")
    original_isreserved = getattr(guard.ntpath, "isreserved", None)
    guard.ntpath.isreserved = lambda _part: False
    try:
        for relative in invalid:
            try:
                guard.validate_managed_path(root, relative, "file")
            except guard.GuardError:
                continue
            raise AssertionError(f"unsafe relative path accepted by fallback: {relative!r}")
    finally:
        if had_isreserved:
            guard.ntpath.isreserved = original_isreserved
        else:
            del guard.ntpath.isreserved

    root_stat = os.lstat(root)
    reparse_stat = types.SimpleNamespace(
        st_mode=stat.S_IFDIR | 0o755,
        st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT,
    )

    def synthetic_lstat(path):
        if pathlib.Path(path) == root:
            return root_stat
        if pathlib.Path(path) == root / "junction":
            return reparse_stat
        raise FileNotFoundError(os.fspath(path))

    try:
        guard.validate_managed_path(root, "junction/output.txt", "file", lstat_fn=synthetic_lstat)
    except guard.GuardError:
        pass
    else:
        raise AssertionError("Windows reparse point accepted")
PY
then
  ok "G1q shared guard rejects unsafe grammar, missing required files, and Windows reparse points"
else
  no "G1q shared managed-path guard contract failed"
fi

# G1r — manifest copies publish from a destination-local temporary. An injected
# late publication failure must leave no canonical leaf and no copy temporary.
COPY_FAIL_TARGET="$_B13/copy publication target"
mkdir -p "$COPY_FAIL_TARGET"
git -C "$COPY_FAIL_TARGET" init -q
if PRKIT_GENERATOR_TEST_MODE=1 \
     PRKIT_TEST_COPY_PUBLISH_FAIL="plugins/prkit/commands/review-pr.md" \
     bash "$GEN" --target "$COPY_FAIL_TARGET" --version 0.1.0 --force >/dev/null 2>&1; then
  no "G1r injected copy publication failure was accepted"
elif [ -e "$COPY_FAIL_TARGET/plugins/prkit/commands/review-pr.md" ]; then
  no "G1r failed copy publication left a canonical destination"
elif [ -n "$(find "$COPY_FAIL_TARGET" -name '.prkit-copy.*' -print -quit)" ]; then
  no "G1r failed copy publication leaked a destination temporary"
elif [ -e "$COPY_FAIL_TARGET/.prkit-generate.lock" ]; then
  no "G1r failed copy publication leaked its generation lock"
else
  ok "G1r copy publication fails closed without canonical output, temp, or lock leak"
fi

# G1s — the target's parent is canonicalized, but the final target entry stays
# visible to lstat. A linked target root is rejected by both generation and
# verification without touching the physical directory it points at.
PHYSICAL_TARGET="$_B14/physical target"
TARGET_LINK="$_B14/target link"
mkdir -p "$PHYSICAL_TARGET"
printf 'physical root sentinel\n' > "$PHYSICAL_TARGET/sentinel.txt"
ln -s "$PHYSICAL_TARGET" "$TARGET_LINK"
if bash "$GEN" --target "$TARGET_LINK" --version 0.1.0 --force >/dev/null 2>&1 \
   || bash "$VERIFY" "$TARGET_LINK" >/dev/null 2>&1 \
   || [ ! -L "$TARGET_LINK" ] \
   || [ "$(cat "$PHYSICAL_TARGET/sentinel.txt" 2>/dev/null)" != "physical root sentinel" ] \
   || [ -e "$PHYSICAL_TARGET/plugins" ]; then
  no "G1s linked target root was accepted or mutated"
else
  ok "G1s linked target root is rejected and its physical directory preserved"
fi

# G1t — the target-local mkdir lock is not bypassed by --force. A pre-existing
# lock gets a clear stale-lock diagnostic and no target mutation.
LOCK_TARGET="$_B15/locked target"
mkdir -p "$LOCK_TARGET/.prkit-generate.lock"
printf 'lock owner sentinel\n' > "$LOCK_TARGET/.prkit-generate.lock/owner"
printf 'locked target sentinel\n' > "$LOCK_TARGET/sentinel.txt"
lock_output=""
if lock_output="$(bash "$GEN" --target "$LOCK_TARGET" --version 0.1.0 --force 2>&1)" \
   || ! grep -qF "target generation lock exists:" <<<"$lock_output" \
   || ! grep -qF "confirming it is stale" <<<"$lock_output" \
   || [ "$(cat "$LOCK_TARGET/.prkit-generate.lock/owner" 2>/dev/null)" != "lock owner sentinel" ] \
   || [ "$(cat "$LOCK_TARGET/sentinel.txt" 2>/dev/null)" != "locked target sentinel" ] \
   || [ -e "$LOCK_TARGET/plugins" ]; then
  no "G1t stale generation lock was bypassed, unclear, or mutated"
else
  ok "G1t generation lock fails clearly and is never bypassed by --force"
fi

# G1u — recursive replacement is allowed only for a sealed existing tree.
# Even --force must reject a nested link/reparse entry before rm -rf begins.
NESTED_LINK_TARGET="$_B16/nested-link target"
NESTED_LINK_OUTSIDE="$_B16/nested-link outside"
mkdir -p "$NESTED_LINK_TARGET/plugins/prkit" "$NESTED_LINK_OUTSIDE"
printf 'nested external sentinel\n' > "$NESTED_LINK_OUTSIDE/sentinel.txt"
git -C "$NESTED_LINK_TARGET" init -q
git -C "$NESTED_LINK_TARGET" config user.email prkit-test@example.invalid
git -C "$NESTED_LINK_TARGET" config user.name "prkit test"
ln -s "$NESTED_LINK_OUTSIDE" "$NESTED_LINK_TARGET/plugins/prkit/nested-link"
git -C "$NESTED_LINK_TARGET" add plugins/prkit/nested-link
git -C "$NESTED_LINK_TARGET" commit -qm "test: nested pre-delete symlink fixture"
before_status="$(git -C "$NESTED_LINK_TARGET" status --porcelain --untracked-files=all)"
if bash "$GEN" --target "$NESTED_LINK_TARGET" --version 0.1.0 --force >/dev/null 2>&1 \
   || [ "$(cat "$NESTED_LINK_OUTSIDE/sentinel.txt" 2>/dev/null)" != "nested external sentinel" ] \
   || [ ! -L "$NESTED_LINK_TARGET/plugins/prkit/nested-link" ] \
   || [ -e "$NESTED_LINK_TARGET/.prkit-generate.lock" ] \
   || [ "$(git -C "$NESTED_LINK_TARGET" status --porcelain --untracked-files=all)" != "$before_status" ]; then
  no "G1u nested pre-delete link was accepted, removed, or leaked a lock"
else
  ok "G1u nested link is rejected before recursive delete, even with --force"
fi

# G2 — verify gate independently passes on the produced tree
if bash "$VERIFY" "$T1" >/dev/null 2>&1; then ok "G2 verify passes on generated tree"; else no "G2 verify failed on generated tree"; fi

# G3 — EXACTLY 38 source files landed under plugins/prkit (manifest count-lock;
# -eq not -ge so a silently-dropped copy OR a stray extra file both fail)
n=$(find "$T1/plugins/prkit/commands" "$T1/plugins/prkit/agents" "$T1/plugins/prkit/skills" "$T1/plugins/prkit/lib" "$T1/plugins/prkit/policy" "$T1/plugins/prkit/shared" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 38 ] && ok "G3 exactly 38 copied files present" || no "G3 copied $n files (expected 38)"

# G4 — scaffold files exist with interpolated version and a native Codex
# marketplace whose selector matches the generated README.
grep -q '0.1.0' "$T1/plugins/prkit/.claude-plugin/plugin.json" && ok "G4 plugin.json version interpolated" || no "G4 plugin.json version missing"
[ -f "$T1/README.md" ] && [ -f "$T1/.claude-plugin/marketplace.json" ] && ok "G4b README + marketplace scaffolded" || no "G4b scaffold files missing"
if python3 -I -B - "$T1" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
marketplace = json.loads((root / '.agents/plugins/marketplace.json').read_text())
assert marketplace['name'] == 'prkit'
assert marketplace['plugins'][0]['name'] == 'prkit-codex'
assert marketplace['plugins'][0]['source'] == {
    'source': 'local',
    'path': './codex/prkit-codex',
}
assert marketplace['plugins'][0]['policy'] == {
    'installation': 'AVAILABLE',
    'authentication': 'ON_INSTALL',
}
selector = f"{marketplace['plugins'][0]['name']}@{marketplace['name']}"
assert selector == 'prkit-codex@prkit'
readme = (root / 'codex/README.md').read_text()
commands = [
    line.strip()
    for line in readme.splitlines()
    if line.strip().startswith('codex plugin add ')
]
assert commands == [f'codex plugin add {selector}']
PY
then ok "G4c native Codex marketplace backs README selector prkit-codex@prkit"
else no "G4c native Codex marketplace missing, malformed, or disconnected from README selector"; fi
if grep -qF 'scaffolded 12, verified.' <<<"$G1_OUTPUT" \
   && grep -qF '.agents/plugins/marketplace.json' "$T1/.github/workflows/ci.yml"; then
  ok "G4d native marketplace is counted and covered by generated JSON syntax CI"
else
  no "G4d native marketplace missing from scaffold count or generated JSON syntax CI"
fi
if [ "$(grep -cF 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2' "$T1/.github/workflows/ci.yml")" -eq 1 ] \
   && ! grep -qE 'actions/checkout@v[0-9]+' "$T1/.github/workflows/ci.yml"; then
  ok "G4da generated CI pins actions/checkout to the reviewed immutable SHA"
else
  no "G4da generated CI checkout action is missing its immutable pin or regressed to a tag"
fi
if grep -qF 'test -d plugins/prkit && test -d codex' "$T1/.github/workflows/ci.yml" \
   && [ "$(grep -cF "find plugins/prkit codex -type f -name '" "$T1/.github/workflows/ci.yml")" -eq 4 ] \
   && [ "$(grep -cF 'test -s "$manifest"' "$T1/.github/workflows/ci.yml")" -eq 4 ] \
   && grep -qF 'find plugins/prkit -type f -print0 > "$claude_manifest" || exit 1' "$T1/.github/workflows/ci.yml" \
   && grep -qF 'find codex -type f -print0 > "$codex_manifest" || exit 1' "$T1/.github/workflows/ci.yml" \
   && grep -qF "grep -rilE 'uberdev' plugins/prkit codex" "$T1/.github/workflows/ci.yml" \
   && grep -qF 'case "$grep_status" in' "$T1/.github/workflows/ci.yml" \
   && ! grep -qF '$([ -d codex ] && echo codex)' "$T1/.github/workflows/ci.yml" \
   && ! grep -qF 'grep -rilE '\''uberdev'\'' plugins/prkit codex || true' "$T1/.github/workflows/ci.yml" \
   && ! grep -qi 'codex/ is optional' "$T1/.github/workflows/ci.yml"; then
  ok "G4db generated CI requires nonempty Codex/Claude scans and preserves namespace-scan errors"
else
  no "G4db generated CI permits a missing/empty scan or masks namespace-scan errors"
fi
JSON_CI_SCRIPT="$_B16/generated-json-ci.sh"
python3 -I -B - "$T1/.github/workflows/ci.yml" "$JSON_CI_SCRIPT" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
start = lines.index("      - name: Syntax — json")
assert lines[start + 1] == "        run: |"
body = []
for line in lines[start + 2:]:
    if line.startswith("      - name: "):
        break
    assert line.startswith("          "), line
    body.append(line[10:])
assert body
Path(sys.argv[2]).write_text("\n".join(body) + "\n", encoding="utf-8")
PY
JSON_CI_TARGET="$_B16/json-ci-empty-runtime"
cp -R "$T1" "$JSON_CI_TARGET"
find "$JSON_CI_TARGET/plugins/prkit" "$JSON_CI_TARGET/codex" -type f -name '*.json' -delete
if (cd "$T1" && bash "$JSON_CI_SCRIPT") >/dev/null 2>&1 \
   && ! (cd "$JSON_CI_TARGET" && bash "$JSON_CI_SCRIPT") >/dev/null 2>&1; then
  ok "G4dc generated JSON CI accepts runtime JSON and rejects empty runtime discovery"
else
  no "G4dc generated JSON CI did not preserve runtime JSON non-vacuity"
fi

# G4e — publication failures must not fall through to verification of a stale
# but valid canonical file. The injected final replace failure must preserve the
# old bytes, clean its destination-local temporary, and return nonzero.
PUBLISH_TARGET="$_B6/publication target"
mkdir -p "$PUBLISH_TARGET"
git -C "$PUBLISH_TARGET" init -q
bash "$GEN" --target "$PUBLISH_TARGET" --version 0.1.0 >/dev/null 2>&1
PUBLISH_FILE="$PUBLISH_TARGET/.agents/plugins/marketplace.json"
cp "$PUBLISH_FILE" "$_B6/expected-marketplace.json"
if PRKIT_GENERATOR_TEST_MODE=1 PRKIT_TEST_RENDER_PUBLISH_FAIL="$PUBLISH_FILE" \
     bash "$GEN" --target "$PUBLISH_TARGET" --version 0.1.0 --force >/dev/null 2>&1; then
  no "G4e injected render publication failure was masked by stale valid output"
elif ! cmp -s "$PUBLISH_FILE" "$_B6/expected-marketplace.json"; then
  no "G4e failed render publication changed the stale canonical output"
elif [ -n "$(find "$(dirname "$PUBLISH_FILE")" -maxdepth 1 -name '.prkit-render.*' -print -quit)" ]; then
  no "G4e failed render publication leaked a destination temporary"
else
  ok "G4e render publication fails closed, preserves stale bytes, and cleans temporary"
fi

# G5 — determinism: second generation into a fresh target is byte-identical
bash "$GEN" --target "$T2" --version 0.1.0 >/dev/null 2>&1
if diff -r "$T1/plugins/prkit" "$T2/plugins/prkit" >/dev/null 2>&1; then ok "G5 deterministic (diff -r empty)"; else no "G5 non-deterministic output"; fi
if diff -r -x .git "$T1" "$T2" >/dev/null 2>&1; then ok "G5b complete generated tree is deterministic"; else no "G5b complete generated tree is non-deterministic"; fi

# G6 — Codex port generated: prkit-cmd-* skills, renamed TOML, installer, manifest,
# and prkit-PREFIXED support skills (flat ~/.agents/skills/ coexistence) with NO
# un-prefixed post-impl-review/merge-pipeline dir that would collide with UberDev-codex
if [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-review-pr/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-simplify/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-cmd-merge/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-post-impl-review/SKILL.md" ] \
   && [ -f "$T1/codex/prkit-codex/skills/prkit-merge-pipeline/SKILL.md" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/post-impl-review" ] \
   && [ ! -e "$T1/codex/prkit-codex/skills/merge-pipeline" ] \
   && [ -f "$T1/codex/agents/prkit-code-reviewer.toml" ] \
   && [ -f "$T1/codex/install-codex.sh" ] \
   && grep -q '"name": "prkit-codex"' "$T1/codex/prkit-codex/.codex-plugin/plugin.json"; then
  ok "G6 codex port generated (prkit-cmd-* + prkit-prefixed support skills, no flat collision)"
else no "G6 codex port incomplete or has un-prefixed support skill"; fi

# G6a — the copied full-UberDev installer is rewritten to the standalone
# manifest's actual fleet size. These hints are user-facing verification, so a
# successful install must not claim the full 39/44 fleet.
if grep -qF '# 5 prkit skills' "$T1/codex/install-codex.sh" \
   && grep -qF '# 14 prkit-*.toml subagents' "$T1/codex/install-codex.sh" \
   && grep -qF 'NOT the 14 agents' "$T1/codex/install-codex.sh" \
   && ! grep -Eq '(^|[^0-9])(39|44)([^0-9]|$)' "$T1/codex/install-codex.sh"; then
  ok "G6a standalone installer reports the manifest-true 5 skills / 14 agents"
else no "G6a standalone installer retains full-UberDev fleet counts"; fi

# G6aa — exercise the rewrite transaction itself against synthetic drift. A
# traversal/count mismatch and a missing substitution anchor must both fail
# before touching the installer.
if python3 -I -B - "$GEN" <<'PY'
import pathlib,subprocess,sys,tempfile
source=pathlib.Path(sys.argv[1]).read_text()
marker='  python3 -I -B - "$TARGET" <<\'PY\' || {'
snippet=source.split(marker,1)[1].split('\nPY\n',1)[0]
anchors='NOT the 44 agents\n# ~39 Prkit skills incl. command-skills\n# 44 prkit-*.toml subagents\n'
def fixture(skills,installer_text):
 root=pathlib.Path(tempfile.mkdtemp()); (root/'codex/prkit-codex/skills').mkdir(parents=True); (root/'codex/agents').mkdir()
 for index in range(skills): (root/f'codex/prkit-codex/skills/s{index}').mkdir()
 for index in range(14): (root/f'codex/agents/prkit-a{index}.toml').write_text('x')
 target=root/'codex/install-codex.sh'; target.write_text(installer_text)
 return root,target
for root,target in (fixture(6,anchors),fixture(5,anchors.replace('NOT the 44 agents','anchor drift'))):
 before=target.read_bytes()
 result=subprocess.run([sys.executable,'-I','-B','-',str(root)],input=snippet,text=True,capture_output=True)
 assert result.returncode!=0,result
 assert target.read_bytes()==before
PY
then ok "G6aa count discovery and anchor drift fail closed without mutation"
else no "G6aa generator count/anchor transaction accepted drift"; fi

# G6ab — projection accepts only the canonical edge semantics and publishes
# atomically. Relationship drift must fail before mutation; an injected replace
# failure must preserve the copied policy and remove its temporary artifact.
if python3 -I -B - "$GEN" "$REPO_ROOT/plugins/uberdev/policy/solve-run-tree-v1.json" <<'PY'
import json,os,pathlib,subprocess,sys,tempfile
generator=pathlib.Path(sys.argv[1]).read_text()
canonical=pathlib.Path(sys.argv[2]).read_bytes()
marker='  python3 -I -B - "$policy" "$roles_dir" "$role_prefix" "$role_suffix" <<\'PY\' || return 1\n'
snippet=generator.split(marker,1)[1].split('\nPY\n',1)[0]
roles={
 'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
 'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
 'findings-to-issues','merge-strategy-decider','pr-test-analyzer',
 'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
def fixture():
 root=pathlib.Path(tempfile.mkdtemp())
 policy=root/'solve-run-tree-v1.json'; policy.write_bytes(canonical)
 agents=root/'agents'; agents.mkdir()
 for role in roles: (agents/f'{role}.md').write_text('fixture\n')
 return root,policy,agents
def reject_mutation(mutate):
 root,policy,agents=fixture(); tree=json.loads(policy.read_text()); mutate(tree)
 policy.write_text(json.dumps(tree,sort_keys=True,indent=2)+'\n'); before=policy.read_bytes()
 result=subprocess.run([sys.executable,'-I','-B','-',str(policy),str(agents),'','.md'],input=snippet,text=True,capture_output=True)
 assert result.returncode!=0,result
 assert policy.read_bytes()==before
 assert not list(root.glob('.solve-run-tree.*'))
def swap_roles(tree):
 left=tree['edges']['review_pr.review.correctness']; right=tree['edges']['review_pr.review.comments']
 left['role'],right['role']=right['role'],left['role']
def swap_workflows(tree):
 left=tree['edges']['review_pr.fix.phase2']; right=tree['edges']['simplify.fix.phase2']
 left['allowed_workflows'],right['allowed_workflows']=right['allowed_workflows'],left['allowed_workflows']
def attach_contract(tree):
 tree['edges']['review_pr.fix.phase1']['output_contract']='phase1-reviewer-v1'
def add_unexpected_simplify_edge(tree):
 tree['edges']['simplify.unexpected']=dict(tree['edges']['simplify.fix.phase2'])
def drift_fixer_posture(tree):
 tree['edges']['simplify.fix.phase2']['workspace_mode']='disposable'
for mutation in (swap_roles,swap_workflows,attach_contract,add_unexpected_simplify_edge,drift_fixer_posture): reject_mutation(mutation)
root,policy,agents=fixture(); before=policy.read_bytes(); env=os.environ.copy()
env['PRKIT_GENERATOR_TEST_MODE']='1'; env['PRKIT_TEST_POLICY_PUBLISH_FAIL']='1'
result=subprocess.run([sys.executable,'-I','-B','-',str(policy),str(agents),'','.md'],input=snippet,text=True,capture_output=True,env=env)
assert result.returncode!=0,result
assert policy.read_bytes()==before
assert not list(root.glob('.solve-run-tree.*'))
PY
then ok "G6ab policy projection enforces canonical edge semantics and atomic failure cleanup"
else no "G6ab policy projection accepted relationship drift or leaked partial publication"; fi

# G6b — both standalone runtimes ship one byte-identical, closed PR-phase policy
# projection and the manifest-declared reviewer contract, while native Codex
# role TOMLs remain edge-agnostic.
if [ -f "$T1/plugins/prkit/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/plugins/prkit/shared/phase1-reviewer-output-v1.md" ] \
   && [ -f "$T1/codex/prkit-codex/policy/solve-run-tree-v1.json" ] \
   && [ -f "$T1/codex/prkit-codex/shared/phase1-reviewer-output-v1.md" ] \
   && [ -f "$T1/plugins/prkit/lib/code_fixer_contract.py" ] \
   && [ -f "$T1/codex/prkit-codex/lib/code_fixer_contract.py" ] \
   && python3 -I -B - "$T1" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
claude_path=root/'plugins/prkit/policy/solve-run-tree-v1.json'
codex_path=root/'codex/prkit-codex/policy/solve-run-tree-v1.json'
assert claude_path.read_bytes()==codex_path.read_bytes()

def reject_pairs(pairs):
 result={}
 for key,value in pairs:
  if key in result: raise ValueError(f'duplicate JSON key: {key}')
  result[key]=value
 return result

tree=json.loads(
 claude_path.read_text(),
 object_pairs_hook=reject_pairs,
 parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f'non-finite JSON constant: {value}')),
)
assert set(tree)=={
 'schema_version','tree_id','root_edge_id','input_limits','output_contracts','edges'
}
assert tree['input_limits']=={'max_serialized_bytes':49152}
edges=tree['edges']; assert edges
expected_roles={
 'ci-code-fixer','ci-failure-classifier','ci-rebase-handler','code-fixer',
 'code-reviewer','code-simplifier','comment-analyzer','conflict-resolver',
 'findings-to-issues','merge-strategy-decider','pr-test-analyzer',
 'silent-failure-hunter','trust-trail-evaluator','type-design-analyzer',
}
claude_roles={path.stem for path in (root/'plugins/prkit/agents').glob('*.md')}
codex_roles={path.name.removeprefix('prkit-').removesuffix('.toml') for path in (root/'codex/agents').glob('prkit-*.toml')}
assert claude_roles==codex_roles==expected_roles
structural_edges={'review_pr.post_impl_review'}
provider_edges={
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.simplify.reuse',
 'review_pr.simplify.quality','review_pr.simplify.efficiency',
 'review_pr.fix.phase2','review_pr.defer.findings','review_pr.ci.classify',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict','simplify.fix.phase2',
}
assert set(edges)==structural_edges|provider_edges
assert all(edges[edge_id].get('kind')=='skill' for edge_id in structural_edges)
assert all(edges[edge_id].get('kind')=='provider' for edge_id in provider_edges)
for edge in edges.values():
 workflows=edge.get('allowed_workflows',[])
 assert all(workflow in {'review-pr','simplify','solve','turbo'} for workflow in workflows)
 if edge.get('kind')=='provider':
  assert workflows
  assert edge.get('role') in claude_roles
for edge_id in (
 'review_pr.review.correctness','review_pr.review.silent_failures',
 'review_pr.review.types','review_pr.review.comments','review_pr.review.tests',
 'review_pr.review.general','review_pr.fix.phase1','review_pr.ci.classify',
 'review_pr.fix.phase2',
 'review_pr.ci.fix_code','review_pr.ci.rebase','review_pr.ci.defer_refusal',
 'review_pr.ci.resolve_conflict',
):
 assert edges[edge_id]['allowed_workflows']==['review-pr','solve','turbo'], edge_id
for edge_id in (
 'review_pr.simplify.reuse','review_pr.simplify.quality',
 'review_pr.simplify.efficiency','review_pr.defer.findings',
):
 assert edges[edge_id]['allowed_workflows']==['review-pr','simplify','solve','turbo'], edge_id
assert edges['simplify.fix.phase2']['allowed_workflows']==['simplify']
review_inputs={
 'authority_path':'path','authority_sha256':'string',
 'commit_range_path':'path','commit_range_sha256':'string',
 'disposition_path':'path','findings_path':'path','findings_sha256':'string',
 'pr_number':'integer','working_dir':'directory',
}
standalone_inputs={
 'authority_path':'path','authority_sha256':'string',
 'disposition_path':'path','findings_path':'path','findings_sha256':'string',
 'pr_number':'integer','standalone_snapshot_path':'path',
 'standalone_snapshot_sha256':'string','working_dir':'directory',
}
assert edges['review_pr.fix.phase2']['required_inputs']==review_inputs
assert edges['simplify.fix.phase2']['required_inputs']==standalone_inputs
assert edges['review_pr.fix.phase2']['optional_inputs']=={}
assert edges['simplify.fix.phase2']['optional_inputs']=={}
assert (
 edges['review_pr.fix.phase2']['phase'],
 edges['review_pr.fix.phase2']['workspace_mode'],
 edges['review_pr.fix.phase2']['risk_scope'],
 edges['review_pr.fix.phase2']['required'],
 edges['review_pr.fix.phase2']['cardinality'],
)==('simplify_fix','caller','run',False,'zero_or_one_per_review_iteration')
assert (
 edges['simplify.fix.phase2']['phase'],
 edges['simplify.fix.phase2']['workspace_mode'],
 edges['simplify.fix.phase2']['risk_scope'],
 edges['simplify.fix.phase2']['required'],
 edges['simplify.fix.phase2']['cardinality'],
)==('simplify_fix','caller','run',False,'zero_or_one_per_review_iteration')
assert (root/'plugins/prkit/lib/code_fixer_contract.py').read_bytes()==(
 root/'codex/prkit-codex/lib/code_fixer_contract.py'
).read_bytes()
referenced={edge['output_contract'] for edge in edges.values() if 'output_contract' in edge}
assert set(tree.get('output_contracts',{}))==referenced
contract=(root/'codex/prkit-codex/shared/phase1-reviewer-output-v1.md').read_text()
roles=('code-reviewer','silent-failure-hunter','type-design-analyzer','comment-analyzer','pr-test-analyzer')
assert all(contract not in (root/f'codex/agents/prkit-{role}.toml').read_text() for role in roles)
PY
then ok "G6b PR-phase policy and authority helper are identical and closed across runtimes"
else no "G6b standalone policy projection or reviewer contract scope is incorrect"; fi

# G6bc — standalone /simplify uses PR_NUMBER=0. Execute the origin-derivation
# helper from the generated prkit agent and prove it binds the source to the
# validated worktree HEAD without probing a nonexistent PR.
if python3 -I -B - "$T1/plugins/prkit/agents/findings-to-issues.md" "$_B1" <<'PY'
import json,pathlib,subprocess,sys
agent=pathlib.Path(sys.argv[1]).read_text()
base=pathlib.Path(sys.argv[2])
marker='```bash prkit-executable origin=findings-to-issues\n'
assert 'pr_number is 0 AND source_ref non-empty' in agent
assert 'pr_number empty' not in agent
script=agent.split(marker,1)[1].split('\n```',1)[0]
repo=base/'standalone-origin'
repo.mkdir()
subprocess.run(['git','-C',str(repo),'init','-q'],check=True)
subprocess.run(['git','-C',str(repo),'config','user.email','prkit-test@example.invalid'],check=True)
subprocess.run(['git','-C',str(repo),'config','user.name','prkit test'],check=True)
(repo/'tracked').write_text('fixture\n')
subprocess.run(['git','-C',str(repo),'add','tracked'],check=True)
subprocess.run(['git','-C',str(repo),'commit','-qm','test: fixture'],check=True)
head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
shell='set -eu\n'+script+'\nfindings_derive_review_origin "$1" "$2" "$3" "$4" "$5" "$6" "$7"\n'
result=subprocess.run(
 ['bash','-c',shell,'origin-test',str(repo),'0','20260726-120000-abc123','owner/repo',
  'simplify','0','review_pr.defer.findings'],
 text=True,capture_output=True,
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'},
)
assert result.returncode==0,result
origin=json.loads(result.stdout)
assert origin=={
 'origin_kind':'standalone',
 'repo_slug':'owner/repo',
 'pr_commit_sha':head,
 'source_ref':'/simplify run 20260726-120000-abc123',
},origin
bad=subprocess.run(
 ['bash','-c',shell,'origin-test',str(repo),'7','20260726-120000-abc123','owner/repo',
  'simplify','0','review_pr.defer.findings'],
 text=True,capture_output=True,
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'},
)
assert bad.returncode!=0,bad
PY
then ok "G6bc generated standalone prkit derives PR_NUMBER=0 origin from validated HEAD"
else no "G6bc generated standalone prkit PR_NUMBER=0 origin derivation failed"; fi

# G6c — the generated standalone Codex runtime must execute the focused
# six-reviewer happy path, not merely pass structural namespace scans.
if SIX_CHILD_RUNTIME_ROOT="$T1/codex/prkit-codex" \
   SIX_CHILD_RUNTIME_NAMESPACE=prkit SIX_CHILD_CASE=1 \
   bash "$REPO_ROOT/tests/review-pr-codex-six-child.test.sh" >/dev/null 2>&1; then
  ok "G6c generated standalone prkit executes six-child review path"
else no "G6c generated standalone prkit six-child runtime failed"; fi

# G7 — no uberdev token survives anywhere under codex/
if grep -rilE 'uberdev' "$T1/codex" >/dev/null 2>&1; then no "G7 uberdev token survives under codex/"; else ok "G7 codex tree is uberdev-free"; fi

# G8 — codex tree deterministic across the two generations (spaced vs plain path)
if diff -r "$T1/codex" "$T2/codex" >/dev/null 2>&1; then ok "G8 codex deterministic (diff -r empty)"; else no "G8 codex non-deterministic"; fi

# G9 — regeneration CLEANS stale files (the rm -rf clean stage). Plant strays in
# both trees, regenerate into the SAME target, assert they are gone.
printf 'stale\n' > "$T1/plugins/prkit/STALE_CLAUDE.txt"
printf 'stale\n' > "$T1/codex/STALE_CODEX.txt"
bash "$GEN" --target "$T1" --version 0.1.0 --force >/dev/null 2>&1
if [ ! -e "$T1/plugins/prkit/STALE_CLAUDE.txt" ] && [ ! -e "$T1/codex/STALE_CODEX.txt" ]; then
  ok "G9 regeneration removes stale files from both trees"
else no "G9 stale files survived regeneration"; fi

echo "  Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

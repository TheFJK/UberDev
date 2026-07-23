#!/usr/bin/env bash
# Issue #335: the generated Codex review entrypoint must preserve its provider
# provenance even when CODEX_HOME is absent, without overriding an explicit
# provider selection. The canonical Claude command remains provider-neutral.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONVERTER="$ROOT/codex/tools/convert-commands.py"
SOURCE="$ROOT/plugins/uberdev/commands/review-pr.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

python3 "$CONVERTER" "$ROOT/plugins/uberdev/commands" "$TMP/skills" >/dev/null
GENERATED="$TMP/skills/uberdev-cmd-review-pr/SKILL.md"
CHECKED_IN="$ROOT/codex/uberdev-codex/skills/uberdev-cmd-review-pr/SKILL.md"

for skill in "$GENERATED" "$CHECKED_IN"; do
  # shellcheck disable=SC2016 # The generated shell expression is matched literally.
  grep -q 'UBERDEV_DISPATCH_BACKEND_REQUESTED="${UBERDEV_DISPATCH_BACKEND_REQUESTED:-codex}"' "$skill"
  grep -q 'export UBERDEV_DISPATCH_BACKEND_REQUESTED' "$skill"
  grep -q 'uberdev_dispatch_preflight_backend "$UBERDEV_CARRIER_BACKEND"' "$skill"
done
if grep -q 'UBERDEV_DISPATCH_BACKEND_REQUESTED=.*codex' "$SOURCE"; then
  echo "canonical Claude review command must remain provider-neutral" >&2
  exit 1
fi

for doc in "$SOURCE" "$GENERATED" "$CHECKED_IN"; do
  grep -q 'normalized, non-empty POSIX repository-relative paths' "$doc"
  grep -q 'absolute paths, traversal, dot components, backslashes, control characters, and unsafe names are rejected' "$doc"
done

awk '
  /uberdev-executable setup=review-pr/{active=1; next}
  active && /^```/{exit}
  active{print}
' "$GENERATED" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name Test
printf 'fixture\n' >"$TMP/repo/README.md"
git -C "$TMP/repo" add README.md
git -C "$TMP/repo" commit -qm init

for provider in codex claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/$provider"
  chmod +x "$TMP/bin/$provider"
done

run_setup() {
  local runtime="$1" requested="${2-}"
  mkdir -p "$runtime"
  if [ -n "$requested" ]; then
    # shellcheck disable=SC2016 # Positional parameters expand in the isolated child shell.
    env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
      UBERDEV_TMPDIR="$runtime" UBERDEV_DISPATCH_BACKEND_REQUESTED="$requested" \
      AUTO_PERMISSIONS=1 \
      RUN_ID=20260716-000000-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
      bash -c 'cd "$2"; . "$1"; python3 -I -B -c "import json,os,sys; print(json.dumps({\"requested\":os.environ[\"UBERDEV_DISPATCH_BACKEND_REQUESTED\"],\"backend\":json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"])[\"backend\"],\"model\":sys.argv[1],\"timeout\":sys.argv[2],\"permissions\":sys.argv[3],\"effort\":sys.argv[4]},sort_keys=True))" "${MODEL:-}" "${TIMEOUT_BIN:-}" "${PERM_FLAG[*]-}" "${EFFORT_FLAG[*]-}"' _ "$TMP/setup.sh" "$TMP/repo"
  else
    # shellcheck disable=SC2016 # Positional parameters expand in the isolated child shell.
    env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
      PLUGIN_ROOT="$ROOT/plugins/uberdev" WORKTREE_ROOT="$TMP/repo" \
      UBERDEV_TMPDIR="$runtime" RUN_ID=20260716-000001-abcdef0 PR_NUMBER=335 ARGUMENTS='' \
      bash -c 'cd "$2"; . "$1"; python3 -I -B -c "import json,os,sys; print(json.dumps({\"requested\":os.environ[\"UBERDEV_DISPATCH_BACKEND_REQUESTED\"],\"backend\":json.loads(os.environ[\"UBERDEV_AGENT_PREPARED_REQUEST_JSON\"])[\"backend\"],\"model\":sys.argv[1],\"timeout\":sys.argv[2],\"permissions\":sys.argv[3],\"effort\":sys.argv[4]},sort_keys=True))" "${MODEL:-}" "${TIMEOUT_BIN:-}" "${PERM_FLAG[*]-}" "${EFFORT_FLAG[*]-}"' _ "$TMP/setup.sh" "$TMP/repo"
  fi
}

# CODEX_HOME is intentionally absent in both clean environments. The generated
# Codex skill supplies the provenance signal before standalone carrier setup.
default_result="$(run_setup "$TMP/runtime-default")"
python3 -I -B - "$default_result" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value == {"requested": "codex", "backend": "codex", "model": "", "timeout": "", "permissions": "", "effort": ""}, value
PY

# An explicit operator selection remains higher precedence than entrypoint
# provenance and is the exact backend persisted into the immutable context.
override_result="$(run_setup "$TMP/runtime-override" claude-bg)"
python3 -I -B - "$override_result" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["requested"] == value["backend"] == "claude-bg", value
assert value["model"] and value["timeout"], value
assert value["permissions"] == "--dangerously-skip-permissions --permission-mode bypassPermissions", value
assert value["effort"] == "--effort max", value
PY

echo "review-pr Codex entrypoint tests passed"

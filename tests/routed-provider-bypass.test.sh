#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CANONICAL=(
  "$ROOT/plugins/uberdev/skills/brainstorm/SKILL.md"
  "$ROOT/plugins/uberdev/skills/orchestrator/SKILL.md"
  "$ROOT/plugins/uberdev/skills/subagent-driven-dev/SKILL.md"
  "$ROOT/plugins/uberdev/skills/post-impl-review/SKILL.md"
  "$ROOT/plugins/uberdev/commands/review-pr.md"
  "$ROOT/plugins/uberdev/commands/simplify.md"
)

scan_bash_fences() {
  python3 -I -B - "$@" <<'PY'
import os
import re
import shlex
import sys

fence_open = re.compile(r"^\s*```(?:bash|sh|zsh)(?:\s|$)")
fence_close = re.compile(r"^\s*```\s*$")
assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
heredoc = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
separators = {";", "&", "&&", "|", "||", "(", "{", "!"}
command_starters = {"if", "elif", "while", "until", "then", "else", "do"}
wrappers = {"command", "builtin", "exec", "env", "nohup", "sudo"}
forbidden_exact = {
    "spawn_agent",
    "uberdev_agent_dispatch",
    "uberdev_dispatch_one",
    "_uberdev_agent_dispatch_backend",
    "claude",
    "codex",
}


def tokens_for(line):
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|(){}")
    lexer.commenters = "#"
    lexer.whitespace_split = True
    return list(lexer)


def forbidden_command(line):
    try:
        tokens = tokens_for(line)
    except ValueError:
        return None
    expect_command = True
    wrapper_mode = False
    for index, token in enumerate(tokens):
        if token in separators or token in command_starters:
            expect_command = True
            wrapper_mode = False
            continue
        if not expect_command:
            continue
        if assignment.fullmatch(token) or assignment.match(token):
            continue
        if wrapper_mode and token.startswith("-"):
            continue
        name = os.path.basename(token)
        if name in forbidden_exact:
            return name
        if name in {"Task", "Agent"} and index + 1 < len(tokens) and tokens[index + 1] == "(":
            return name + "("
        if name in wrappers:
            wrapper_mode = True
            continue
        expect_command = False
        wrapper_mode = False
    return None


violations = []
for raw_path in sys.argv[1:]:
    path = os.path.abspath(raw_path)
    in_bash = False
    heredoc_end = None
    logical = ""
    logical_line = 0
    with open(path, encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            line = raw.rstrip("\n")
            if not in_bash:
                if fence_open.match(line):
                    in_bash = True
                continue
            if heredoc_end is not None:
                if line.strip("\t") == heredoc_end:
                    heredoc_end = None
                continue
            if fence_close.match(line):
                in_bash = False
                logical = ""
                continue
            if not logical and (not line.strip() or line.lstrip().startswith("#")):
                continue
            if not logical:
                logical_line = line_number
            if line.rstrip().endswith("\\"):
                logical += line.rstrip()[:-1] + " "
                continue
            logical += line
            hit = forbidden_command(logical)
            if hit is not None:
                violations.append(f"{path}:{logical_line}: routed provider bypass command: {hit}")
            match = heredoc.search(logical)
            if match:
                heredoc_end = match.group(2)
            logical = ""

if violations:
    print("\n".join(violations), file=sys.stderr)
    raise SystemExit(1)
PY
}

scan_bash_fences "${CANONICAL[@]}"

assert_rejected() {
  local label="$1" command_line="$2" fixture
  fixture="$TMP/$label.md"
  printf '```bash\n%s\n```\n' "$command_line" >"$fixture"
  if scan_bash_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner accepted forbidden command: $label" >&2
    exit 1
  fi
  grep -q 'routed provider bypass command' "$TMP/$label.stderr"
}

assert_rejected spawn-agent '    spawn_agent --task review'
assert_rejected task-call '  Task(prompt="review")'
assert_rejected agent-call $'\tAgent(role="reviewer")'
assert_rejected agent-dispatch 'uberdev_agent_dispatch "$request" "$prompt" "$result" "$status"'
assert_rejected dispatch-one '  uberdev_dispatch_one 42 medium'
assert_rejected backend-dispatch '    _uberdev_agent_dispatch_backend codex request prompt'
assert_rejected direct-claude '  claude --print review'
assert_rejected direct-codex '    codex exec review'
assert_rejected routed-comment-bypass 'spawn_agent --task review # routed-provider-edge: approved'
assert_rejected wrapped-codex 'env UBERDEV_TEST=1 codex exec review'

# Prose, comment-only mentions, quoted data, heredoc payloads, and the two
# centralized routed primitives are not command-position bypasses.
cat >"$TMP/clean.md" <<'EOF'
Prose may discuss spawn_agent, Task(...), Agent(...), uberdev_agent_dispatch,
uberdev_dispatch_one, _uberdev_agent_dispatch_backend, claude, and codex.

```bash
  # spawn_agent --task review
# routed-provider-edge: codex exec review
printf '%s\n' 'spawn_agent Task( Agent( uberdev_agent_dispatch uberdev_dispatch_one _uberdev_agent_dispatch_backend claude codex'
provider_name=codex
uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks"
uberdev_dispatch_child "$edge" "$handoff" "$result" "$status"
python3 - <<'PY'
codex exec is heredoc data, not a shell command
spawn_agent is also heredoc data
PY
```
EOF
scan_bash_fences "$TMP/clean.md"

echo 'routed-provider-bypass: PASS'

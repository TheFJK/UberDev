#!/usr/bin/env bash
set -euo pipefail

# ci-wiring: declared Unix-only in the test.yml windows-skip-list (#520).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "FATAL: ${0##*/} is declared Unix-only in test.yml (ci-wiring W9) but ran on $(uname -s)" >&2
    exit 2 ;;
esac
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

# This policy intentionally scans raw Markdown fence text. Quoting, comments,
# paths, heredocs, and other shell-language contexts do not create exemptions.
scan_shell_fences() {
  python3 -I -B - "$@" <<'PY'
import re
import sys

# CommonMark/GFM fences allow 0-3 leading spaces. Backtick info strings are
# validated below because, unlike tilde info strings, they cannot contain `.
fence_open = re.compile(
    r"^(?P<indent> {0,3})(?P<marker>`{3,}|~{3,})(?P<info>[^\r\n]*)$"
)
fence_close = re.compile(r"^ {0,3}(?P<marker>`+|~+)[ \t]*$")
fence_suffix = re.compile(r"(?P<marker>`{3,}|~{3,})(?P<info>[^\r\n]*)$")
container_prefix = re.compile(
    r"^[ \t]*(?:(?:>[ \t]*)|"
    r"(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?))+[ \t]*$"
)
shell_languages = {"bash", "sh", "zsh"}
forbidden = re.compile(
    r"(?<![A-Za-z0-9])(?:spawn_agent|uberdev_agent_dispatch|"
    r"uberdev_dispatch_one|_uberdev_agent_dispatch_backend|claude|codex)"
    r"(?![A-Za-z0-9])|"
    r"(?<![A-Za-z0-9])(?:Task|Agent)[ \t]*\("
)


def unsupported_shell_container(line):
    candidate = fence_suffix.search(line)
    if not candidate:
        return False
    marker = candidate.group("marker")
    info = candidate.group("info").strip(" \t")
    if marker[0] == "`" and "`" in info:
        return False
    language = info.split(None, 1)[0] if info else ""
    if language not in shell_languages:
        return False
    prefix = line[:candidate.start()]
    return bool(container_prefix.fullmatch(prefix))

violations = []
for path in sys.argv[1:]:
    in_fence = False
    scan_body = False
    marker_character = ""
    marker_length = 0
    fence_body_line = 0
    with open(path, encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            line = raw.rstrip("\r\n")
            if not in_fence:
                if unsupported_shell_container(line):
                    violations.append(
                        f"{path}:{line_number}: absolute deny violation: "
                        "unsupported container-prefixed executable shell fence"
                    )
                    continue
                opening = fence_open.fullmatch(line)
                if opening:
                    marker = opening.group("marker")
                    info = opening.group("info").strip(" \t")
                    if marker[0] == "`" and "`" in info:
                        continue
                    language = info.split(None, 1)[0] if info else ""
                    in_fence = True
                    scan_body = language in shell_languages
                    marker_character = marker[0]
                    marker_length = len(marker)
                    fence_body_line = line_number + 1
                continue

            closing = fence_close.fullmatch(line)
            closing_marker = closing.group("marker") if closing else ""
            if (
                closing_marker.startswith(marker_character)
                and len(closing_marker) >= marker_length
            ):
                in_fence = False
                scan_body = False
                continue

            if scan_body:
                for match in forbidden.finditer(raw):
                    violations.append(
                        f"{path}:{line_number}: absolute deny violation: {match.group(0)}"
                    )

    if in_fence and scan_body:
        violations.append(
            f"{path}:{fence_body_line}: absolute deny violation: unclosed executable fence"
        )

if violations:
    print("\n".join(violations), file=sys.stderr)
    raise SystemExit(1)
PY
}

FAILURES=0

assert_rejected() {
  local label="$1" body="$2" fixture
  fixture="$TMP/$label.md"
  printf '```bash\n%s\n```\n' "$body" >"$fixture"
  if scan_shell_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner accepted forbidden raw text: $label" >&2
    FAILURES=$((FAILURES + 1))
  elif ! grep -q 'absolute deny violation' "$TMP/$label.stderr"; then
    echo "scanner rejected $label without the policy diagnostic" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_document_rejected() {
  local label="$1" document="$2" fixture
  fixture="$TMP/$label.md"
  printf '%s' "$document" >"$fixture"
  if scan_shell_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner accepted forbidden document: $label" >&2
    FAILURES=$((FAILURES + 1))
  elif ! grep -q 'absolute deny violation' "$TMP/$label.stderr"; then
    echo "scanner rejected $label without the policy diagnostic" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_document_accepted() {
  local label="$1" document="$2" fixture
  fixture="$TMP/$label.md"
  printf '%s' "$document" >"$fixture"
  if ! scan_shell_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner rejected clean document: $label" >&2
    sed -n '1,10p' "$TMP/$label.stderr" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Every closed forbidden atom is rejected. Task/Agent accept horizontal space
# before the opening parenthesis.
assert_rejected spawn-agent 'spawn_agent --task review'
assert_rejected agent-dispatch 'uberdev_agent_dispatch "$request" "$prompt"'
assert_rejected dispatch-one 'uberdev_dispatch_one 42 medium'
assert_rejected backend-dispatch '_uberdev_agent_dispatch_backend route request'
assert_rejected direct-provider-a 'claude --print review'
assert_rejected direct-provider-b 'codex exec review'
assert_rejected task-call 'Task   (prompt="review")'
assert_rejected agent-call $'Agent\t(role="reviewer")'

# Absolute deny is deliberately context-free.
assert_rejected comment-context '# codex exec review'
assert_rejected quoted-context "printf '%s\\n' 'claude'"
assert_rejected assignment-context 'provider=codex'
assert_rejected path-context 'route=/opt/claude/bin/review'
assert_rejected heredoc-context $'cat <<EOF\nspawn_agent --task review\nEOF'
assert_rejected here-string-context "cat <<< 'uberdev_agent_dispatch'"
assert_rejected command-chain-context 'printf ok && uberdev_dispatch_one 42 medium'
assert_rejected underscore-boundary 'value=prefix_codex_suffix'
assert_document_rejected sh-fence $'```sh\nprintf "%s\\n" claude\n```\n'
assert_document_rejected zsh-fence $'```zsh\nAgent (role=reviewer)\n```\n'
assert_document_rejected four-backtick-fence $'````bash\nprintf "%s\\n" codex\n````\n'
assert_document_rejected longer-backtick-closer $'````sh\nprovider=claude\n`````\n'
assert_document_rejected tilde-shell-fence $'~~~zsh\nspawn_agent --task review\n~~~\n'
assert_document_rejected three-space-shell-fence $'   ```bash\ncodex exec review\n   ```\n'
assert_document_rejected short-backtick-closer $'````bash\nprintf ok\n```\n'
assert_document_rejected unclosed-fence $'```bash\nprintf ok\n'

# Invalid Markdown fences must not enter parser state and shadow a later real
# executable fence. Invalid over-indented closers likewise must not end one.
assert_document_rejected four-space-opener-shadow $'    ```text\n```bash\ncodex exec review\n```\n'
assert_document_rejected tab-opener-shadow $'\t~~~text\n~~~sh\nclaude --print review\n~~~\n'
assert_document_rejected backtick-info-shadow $'```text`invalid\n```bash\ncodex exec review\n```\n'
assert_document_rejected four-space-closer-shadow $'```bash\nprintf ok\n    ```\ncodex exec review\n```\n'
assert_document_rejected tab-closer-shadow $'~~~sh\nprintf ok\n\t~~~\nclaude --print review\n~~~\n'

# Container-prefixed and ambiguously over-indented executable fences are an
# unsupported governed-source form. Reject at the opener even when their body
# is clean; this keeps the scanner fail-closed without parsing container bodies.
assert_document_rejected blockquote-shell-clean $'> ```bash\n> printf ok\n> ```\n'
assert_document_rejected unordered-list-shell-clean $'- ~~~sh\n  printf ok\n  ~~~\n'
assert_document_rejected ordered-list-shell-clean $'10. ```zsh\n    printf ok\n    ```\n'
assert_document_rejected task-list-shell-clean $'- [ ] ```bash\n  printf ok\n  ```\n'
assert_document_rejected nested-container-shell-clean $'  > 1. - [x] ````sh\n      printf ok\n      ````\n'
assert_document_rejected blockquote-provider-bypass $'> ```bash\n> codex exec review\n> ```\n'

# Ordinary container prose and clearly non-shell container fences remain data.
assert_document_accepted blockquote-prose $'> Prose may mention ```bash and codex.\n'
assert_document_accepted list-prose $'- Prose may mention ~~~sh and claude.\n'
assert_document_accepted blockquote-non-shell $'> ```json\n> {"provider":"codex"}\n> ```\n'
assert_document_accepted list-non-shell $'- ~~~text\n  claude and codex are data\n  ~~~\n'
assert_document_accepted indented-pseudo-shell $'    ```bash\n    codex exec review\n    ```\n'

# A valid non-shell fence may still contain shell-looking literal text, and a
# tilde fence may contain backticks in its info string.
assert_document_accepted valid-non-shell-shadow $'   ```text\n```bash\ncodex exec review\n```\n'
assert_document_accepted tilde-backtick-info $'~~~text`allowed\n```bash\ncodex exec review\n~~~\n'

# Clean controls cover the intended exclusions: case-sensitive uppercase host
# variables, routed APIs, prose/non-shell fences, and alnum-extended words.
cat >"$TMP/clean.md" <<'EOF'
Prose may discuss spawn_agent, Task(...), Agent(...), uberdev_agent_dispatch,
uberdev_dispatch_one, _uberdev_agent_dispatch_backend, claude, and codex.

```json
{"examples":["spawn_agent","Task(","Agent(","claude","codex"]}
```

~~~~text
Non-shell fenced content may mention claude, codex, spawn_agent, Task(, and Agent(.
~~~~

```bash
set -euo pipefail
ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
printf '%s\n' "$ROOT" CLAUDE CODEX
uberdev_child_inputs_build review_pr.review.tests key '"value"'
uberdev_child_inputs_validate review_pr.review.tests '{}'
uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks"
uberdev_dispatch_child "$edge" "$handoff" "$handoff_sha256" "$result" "$status"
printf '%s\n' claudette codexes spawn_agent2 uberdev_agent_dispatcher
printf '%s\n' uberdev_dispatch_one2
printf '%s\n' Tasker Agentic
```
EOF

if ! scan_shell_fences "$TMP/clean.md" >"$TMP/clean.stdout" 2>"$TMP/clean.stderr"; then
  echo "scanner rejected clean controls" >&2
  sed -n '1,20p' "$TMP/clean.stderr" >&2
  FAILURES=$((FAILURES + 1))
fi

[ "$FAILURES" -eq 0 ]

# Governed sources are checked only after the scanner's own mutation and clean
# controls prove the policy. During TDD this is the intended RED gate.
scan_shell_fences "${CANONICAL[@]}"

echo 'routed-provider-bypass: PASS'

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
import re
import sys

fence_open = re.compile(r"^\s*```(?:bash|sh|zsh)(?:\s|$)")
fence_close = re.compile(r"^\s*```\s*$")
word_atom = re.compile(
    r"(?<![A-Za-z0-9_])(?:spawn_agent|uberdev_agent_dispatch|"
    r"uberdev_dispatch_one|_uberdev_agent_dispatch_backend|claude|codex)"
    r"(?![A-Za-z0-9_])"
)
call_atom = re.compile(r"(?<![A-Za-z0-9_])(?:Task|Agent)[ \t]*\(")
shell_boundaries = ";|&()<> \t\r\n"


class PolicyError(Exception):
    pass


def decode_ansi_escape(text, index):
    simple = {
        "a": "\a",
        "b": "\b",
        "e": "\x1b",
        "E": "\x1b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "\\": "\\",
        "'": "'",
        '"': '"',
        "?": "?",
    }
    if index + 1 >= len(text):
        raise PolicyError("unclosed ANSI-C escape")
    marker = text[index + 1]
    if marker in simple:
        return simple[marker], index + 2
    if marker in "01234567":
        end = index + 1
        while end < len(text) and end < index + 4 and text[end] in "01234567":
            end += 1
        return chr(int(text[index + 1:end], 8)), end
    if marker in "xuU":
        limit = {"x": 2, "u": 4, "U": 8}[marker]
        start = index + 2
        end = start
        while end < len(text) and end < start + limit and text[end] in "0123456789abcdefABCDEF":
            end += 1
        if end == start:
            raise PolicyError(f"invalid ANSI-C \\{marker} escape")
        value = int(text[start:end], 16)
        if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
            raise PolicyError("invalid ANSI-C Unicode code point")
        return chr(value), end
    if marker == "c":
        if index + 2 >= len(text):
            raise PolicyError("incomplete ANSI-C control escape")
        return chr(ord(text[index + 2].upper()) ^ 0x40), index + 3
    raise PolicyError(f"unsupported ANSI-C escape: \\{marker}")


def line_at(text, index, base_line):
    return base_line + text.count("\n", 0, index)


def check_atoms(chars, protected, text, base_line):
    semantic = "".join(chars)
    for pattern in (word_atom, call_atom):
        for match in pattern.finditer(semantic):
            if not all(protected[match.start():match.end()]):
                return match.group(0), line_at(semantic, match.start(), base_line)
    return None


def quoted_chunk(text, index, quote, ansi=False):
    chars = []
    index += 1
    while index < len(text):
        char = text[index]
        if char == quote:
            return index + 1, chars
        if ansi and char == "\\":
            decoded, index = decode_ansi_escape(text, index)
            chars.extend(decoded)
            continue
        chars.append(char)
        index += 1
    raise PolicyError("unclosed quote")


def backtick_body(text, index):
    start = index + 1
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "`":
            return text[start:index], index + 1
        index += 1
    raise PolicyError("unclosed backtick substitution")


def paren_body(text, index):
    start = index + 2
    index = start
    depth = 1
    state = "normal"
    while index < len(text):
        char = text[index]
        if state == "single":
            if char == "'":
                state = "normal"
            index += 1
            continue
        if state == "double":
            if char == "\\":
                index += 2
                continue
            if char == '"':
                state = "normal"
            index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if char == "'":
            state = "single"
            index += 1
            continue
        if char == '"':
            state = "double"
            index += 1
            continue
        if char == "`":
            _, index = backtick_body(text, index)
            continue
        if char == "#" and (index == start or text[index - 1] in shell_boundaries):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline + 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:index], index + 1
        index += 1
    raise PolicyError("unclosed dollar substitution")


def heredoc_word(text, index):
    chars = []
    quoted = False
    while index < len(text) and text[index] not in shell_boundaries:
        char = text[index]
        if char == "\\":
            quoted = True
            if index + 1 >= len(text) or text[index + 1] == "\n":
                raise PolicyError("malformed heredoc delimiter")
            chars.append(text[index + 1])
            index += 2
            continue
        if char in "'\"":
            quoted = True
            index, chunk = quoted_chunk(text, index, char)
            chars.extend(chunk)
            continue
        if text.startswith("$'", index):
            quoted = True
            index, chunk = quoted_chunk(text, index + 1, "'", ansi=True)
            chars.extend(chunk)
            continue
        chars.append(char)
        index += 1
    if not chars:
        raise PolicyError("missing heredoc delimiter")
    return "".join(chars), quoted, index


def scan_heredoc_expansions(body, base_line):
    index = 0
    while index < len(body):
        if body[index] == "\\":
            index += 2
            continue
        if body.startswith("$(", index):
            nested, end = paren_body(body, index)
            hit = scan_shell(nested, line_at(body, index, base_line))
            if hit is not None:
                return hit
            index = end
            continue
        if body[index] == "`":
            nested, end = backtick_body(body, index)
            hit = scan_shell(nested, line_at(body, index, base_line))
            if hit is not None:
                return hit
            index = end
            continue
        index += 1
    return None


def scan_shell(text, base_line):
    chars = []
    protected = []
    pending_heredocs = []
    at_boundary = True
    index = 0

    def append(value, is_protected):
        nonlocal at_boundary
        chars.extend(value)
        protected.extend([is_protected] * len(value))
        if value:
            at_boundary = value[-1] in shell_boundaries

    while index < len(text):
        char = text[index]
        if char == "\n":
            append(char, False)
            index += 1
            while pending_heredocs:
                delimiter, strip_tabs, quoted = pending_heredocs.pop(0)
                body_start = index
                body_parts = []
                while index < len(text):
                    end = text.find("\n", index)
                    if end < 0:
                        raw_line = text[index:]
                        next_index = len(text)
                    else:
                        raw_line = text[index:end]
                        next_index = end + 1
                    candidate = raw_line.lstrip("\t") if strip_tabs else raw_line
                    if candidate == delimiter:
                        index = next_index
                        break
                    body_parts.append(text[index:next_index])
                    index = next_index
                else:
                    raise PolicyError("unclosed heredoc")
                if index == len(text) and candidate != delimiter:
                    raise PolicyError("unclosed heredoc")
                if not quoted:
                    hit = scan_heredoc_expansions("".join(body_parts), line_at(text, body_start, base_line))
                    if hit is not None:
                        return hit
            continue
        if char == "#" and at_boundary:
            end = text.find("\n", index)
            if end < 0:
                index = len(text)
            else:
                append("\n", False)
                index = end + 1
            continue
        if char == "\\":
            if index + 1 >= len(text):
                raise PolicyError("dangling escape")
            if text[index + 1] == "\n":
                index += 2
                continue
            append(text[index + 1], False)
            at_boundary = False
            index += 2
            continue
        if char == "'":
            index, chunk = quoted_chunk(text, index, "'")
            append(chunk, True)
            at_boundary = False
            continue
        if text.startswith("$'", index):
            index, chunk = quoted_chunk(text, index + 1, "'", ansi=True)
            append(chunk, True)
            at_boundary = False
            continue
        if char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                if text[index] == "\\":
                    if index + 1 >= len(text):
                        raise PolicyError("unclosed double quote")
                    if text[index + 1] == "\n":
                        index += 2
                    else:
                        append(text[index + 1], True)
                        index += 2
                    continue
                if text.startswith("$(", index):
                    nested, end = paren_body(text, index)
                    hit = scan_shell(nested, line_at(text, index, base_line))
                    if hit is not None:
                        return hit
                    append("\0", True)
                    index = end
                    continue
                if text[index] == "`":
                    nested, end = backtick_body(text, index)
                    hit = scan_shell(nested, line_at(text, index, base_line))
                    if hit is not None:
                        return hit
                    append("\0", True)
                    index = end
                    continue
                append(text[index], True)
                index += 1
            if index >= len(text):
                raise PolicyError("unclosed double quote")
            index += 1
            at_boundary = False
            continue
        if text.startswith("$(", index):
            nested, end = paren_body(text, index)
            hit = scan_shell(nested, line_at(text, index, base_line))
            if hit is not None:
                return hit
            append("\0", False)
            index = end
            continue
        if char == "`":
            nested, end = backtick_body(text, index)
            hit = scan_shell(nested, line_at(text, index, base_line))
            if hit is not None:
                return hit
            append("\0", False)
            index = end
            continue
        if text.startswith("<<<", index):
            append("<<<", False)
            index += 3
            continue
        if text.startswith("<<", index):
            strip_tabs = text.startswith("<<-", index)
            index += 3 if strip_tabs else 2
            while index < len(text) and text[index] in " \t":
                index += 1
            delimiter, quoted, index = heredoc_word(text, index)
            pending_heredocs.append((delimiter, strip_tabs, quoted))
            append(" ", False)
            continue
        append(char, False)
        index += 1

    if pending_heredocs:
        raise PolicyError("unclosed heredoc")
    return check_atoms(chars, protected, text, base_line)


violations = []
for path in sys.argv[1:]:
    in_bash = False
    fence_lines = []
    fence_line = 0
    with open(path, encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            line = raw.rstrip("\n")
            if not in_bash:
                if fence_open.match(line):
                    in_bash = True
                    fence_line = line_number + 1
                    fence_lines = []
                continue
            if fence_close.match(line):
                try:
                    hit = scan_shell("".join(fence_lines), fence_line)
                    if hit is not None:
                        atom, hit_line = hit
                        violations.append(f"{path}:{hit_line}: routed provider bypass command: {atom}")
                except PolicyError as error:
                    violations.append(f"{path}:{fence_line}: routed provider bypass command: malformed shell ({error})")
                in_bash = False
                continue
            fence_lines.append(raw)
    if in_bash:
        violations.append(f"{path}:{fence_line}: routed provider bypass command: unclosed shell fence")

if violations:
    print("\n".join(violations), file=sys.stderr)
    raise SystemExit(1)
PY
}

scan_bash_fences "${CANONICAL[@]}"

MUTATION_FAILURES=0
assert_rejected() {
  local label="$1" command_line="$2" fixture
  fixture="$TMP/$label.md"
  printf '```bash\n%s\n```\n' "$command_line" >"$fixture"
  if scan_bash_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner accepted forbidden command: $label" >&2
    MUTATION_FAILURES=$((MUTATION_FAILURES + 1))
    return 0
  fi
  grep -q 'routed provider bypass command' "$TMP/$label.stderr"
}

assert_document_rejected() {
  local label="$1" document="$2" fixture
  fixture="$TMP/$label.md"
  printf '%s' "$document" >"$fixture"
  if scan_bash_fences "$fixture" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    echo "scanner accepted malformed document: $label" >&2
    MUTATION_FAILURES=$((MUTATION_FAILURES + 1))
    return 0
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
assert_rejected case-arm-codex 'case "$x" in foo) codex exec review ;; esac'
assert_rejected case-arm-spawn '  case "$x" in foo|bar) spawn_agent --task review ;; esac'
assert_rejected case-arm-multiline $'case "$x" in\n  foo)\n    Agent(role="reviewer")\n    ;;\nesac'
assert_rejected nested-case-outer-arm $'case "$outer" in\n  first)\n    case "$inner" in\n      nested) :; esac\n    ;;\n  second) codex exec review ;;\nesac'
assert_rejected esac-selector 'case esac in foo) codex exec review ;; esac'
assert_rejected esac-pattern 'case "$x" in esac) spawn_agent --task review ;; esac'
assert_rejected quoted-esac-pattern 'case "$x" in "esac") codex exec review ;; esac'
assert_rejected timed-codex 'time codex exec review'
assert_rejected timed-claude '  time -p claude --print review'
assert_rejected timed-after-if 'if time -p codex exec review; then :; fi'
assert_rejected backtick-codex 'result=`codex exec review`'
assert_rejected dollar-substitution-claude 'result="$(claude --print review)"'
assert_rejected command-inside-arithmetic 'value=$((1 + $(codex exec review)))'
assert_rejected hash-inside-word 'printf foo#$(claude --print review)'
assert_rejected assignment-atom 'provider_name=codex'
assert_rejected argument-atom 'printf "%s\n" codex'
assert_rejected case-selector-atom 'case codex in other) : ;; esac'
assert_rejected case-pattern-atom 'case "$provider_name" in codex) : ;; esac'
assert_rejected arithmetic-atom 'value=$((codex + 1))'
assert_rejected comparison-atom '[[ "$provider" == codex ]]'
assert_rejected backend-option-atom 'route --backend=codex review'
assert_rejected path-atom 'route /opt/codex/bin review'
assert_rejected attached-hash-atom 'printf foo#codex'
assert_rejected quoted-space-attached-hash 'printf "x "#codex'
assert_rejected escaped-space-attached-hash 'printf foo\ #codex'
assert_rejected brace-attached-hash 'printf foo{#codex'
assert_rejected bracket-attached-hash 'printf foo[#codex'
assert_rejected continued-atom $'co\\\ndex exec review'
assert_rejected mixed-double-quote 'co"dex" exec review'
assert_rejected mixed-single-quote "'co'dex exec review"
assert_rejected escaped-spelling 'co\dex exec review'
assert_rejected ansi-hex-codex "provider=\$'\\x63o'dex"
assert_rejected ansi-octal-codex "provider=\$'\\143o'dex"
assert_rejected ansi-unicode-codex "provider=\$'\\u0063o'dex"
assert_rejected ansi-hex-task-call "\$'\\x54ask' (prompt=review)"
assert_rejected ansi-octal-agent-call "\$'\\101gent'(role=reviewer)"
assert_rejected ansi-unicode-spawn-agent "\$'\\u0073pawn_'agent --task review"
assert_rejected ansi-hex-claude "cl\$'\\x61'ude --print review"
assert_rejected ansi-unsupported-escape "printf \$'\\q'"
assert_rejected ansi-empty-hex-escape "printf \$'\\x'"
assert_rejected ansi-invalid-unicode "printf \$'\\uD800'"
assert_rejected nested-substitution 'result="$(printf "%s" "$(codex exec review)")"'
assert_rejected double-quoted-backtick 'result="prefix `claude --print review` suffix"'
assert_rejected unquoted-heredoc-substitution $'cat <<EOF\n$(codex exec review)\nEOF'
assert_rejected unquoted-heredoc-backtick $'cat <<EOF\n`claude --print review`\nEOF'
assert_rejected multiple-heredoc-second $'cat <<ONE <<-TWO\nsafe\nONE\n\t$(spawn_agent --task review)\n\tTWO'
assert_rejected unclosed-single-quote "printf '%s codex"
assert_rejected unclosed-double-quote 'printf "%s codex'
assert_rejected unclosed-ansi-c-quote "printf $'codex"
assert_rejected unclosed-dollar-substitution 'result=$(printf ok'
assert_rejected unclosed-backtick 'result=`printf ok'
assert_rejected unclosed-heredoc $'cat <<EOF\nsafe'
assert_document_rejected unclosed-fence $'```bash\nprintf ok\n'
[ "$MUTATION_FAILURES" -eq 0 ]

# Prose, comment-only mentions, quoted data, heredoc payloads, and the two
# centralized routed primitives are not command-position bypasses.
cat >"$TMP/clean.md" <<'EOF'
Prose may discuss spawn_agent, Task(...), Agent(...), uberdev_agent_dispatch,
uberdev_dispatch_one, _uberdev_agent_dispatch_backend, claude, and codex.

```bash
  # spawn_agent --task review
# routed-provider-edge: codex exec review
printf '%s\n' 'spawn_agent Task( Agent( uberdev_agent_dispatch uberdev_dispatch_one _uberdev_agent_dispatch_backend claude codex'
printf '%s\n' 'literal `codex exec review` and $(claude --print review) data'
printf ok # $(codex exec review)
printf ok # `claude --print review`
case "$provider_name" in other) printf '%s\n' esac ;; esac
printf '%s\n' "codex"
printf '%s\n' 'claude'
printf '%s\n' $'spawn_agent Task( Agent('
printf '%s\n' $'\x63odex \143laude \u0073pawn_agent Task( Agent('
printf '%s\n' "fully quoted codex and claude data"
uberdev_create_child_handoff "$edge" "$instance" "$inputs" "$risks"
uberdev_dispatch_child "$edge" "$handoff" "$result" "$status"
python3 - <<'PY'
codex exec is heredoc data, not a shell command
spawn_agent is also heredoc data
$(claude --print review) remains inert in a quoted heredoc
PY
cat <<INNER
codex and spawn_agent are inert heredoc text without substitutions
INNER
```
EOF
scan_bash_fences "$TMP/clean.md"

echo 'routed-provider-bypass: PASS'

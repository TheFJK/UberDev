#!/usr/bin/env python3
"""
convert-agents.py — Claude Code agents/*.md → Codex ~/.codex/agents/*.toml

UberDev ships 42 subagents as Claude-Code-style markdown (YAML frontmatter +
body). Codex CLI's subagent system reads standalone TOML files from
~/.codex/agents/ (personal) or .codex/agents/ (project). This converter bridges
the two formats.

Field mapping (see codex/README.md §Agent port mapping for the rationale):
  name            → uberdev-<name>               (required; namespaced)
  description     → description                  (required)
  <body>          → developer_instructions       (required, triple-quoted)
  model: inherit  → (omitted — inherits default) [41 of 42 agents]
  model: haiku    → model = "gpt-5.4-mini"       [1 agent: research-test-coverage]
  color           → dropped                      (Claude-Code UI hint only)
  allowed-tools   → dropped                      (Codex uses sandbox/approval model)
  tools           → dropped                      (same)

Output filenames and `name` values are namespaced uberdev-<name> so they
coexist with any user-authored agents in ~/.codex/agents/ without collision.

Idempotent: re-running overwrites the output dir deterministically. Source is
never modified.

Usage:
    python3 convert-agents.py <agents_md_dir> <output_toml_dir>

Exit codes: 0 = success, 1 = usage/IO error, 2 = parse error in one+ agents.
An empty but existing source directory is treated as a conversion failure so an
installer cannot silently replace a working agent namespace with zero agents.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# NOTE: PyYAML is intentionally NOT used for frontmatter parsing. UberDev's
# agent .md files use Claude-Code-style frontmatter, which is *lenient* about
# unquoted scalar values containing colons (e.g. a description containing
# `user: "..."` or `/uberdev:issue`). Strict YAML reads those as nested
# mappings and fails ("mapping values are not allowed here"). 8 of 42 agents
# trip this. The parser below mirrors Claude's lenient reading instead.


# ─────────────────────────────────────────────────────────────────────────────
# Codex model mapping. Claude's model: inherit → Codex inherits the session
# model by simply omitting the `model` key. The lone non-inherit agent
# (research-test-coverage.md, model: haiku) maps to a Codex fast-tier model.
# Haiku is Claude's smallest/fastest coding tier; gpt-5.4-mini is OpenAI's
# current lower-cost/faster subagent tier as of 2026-07. Model names evolve —
# revisit on each OpenAI release.
# ─────────────────────────────────────────────────────────────────────────────
CODEX_MODEL_FOR_CLAUDE = {
    "haiku": "gpt-5.4-mini",
    # inherit → omit `model` key entirely (default behaviour); not listed here.
    # sonnet/opus/etc. are never used by UberDev agents, so unmapped → warning.
}

FRONTMATTER_RE = re.compile(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)(.*)\Z", re.DOTALL)

# Matches `key:` at the start of a frontmatter line (the Claude convention:
# every top-level field is `key: value` on its own line). Used to find where a
# plain-scalar value ends and the next field begins.
KEY_LINE_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_-]*):(?:[ \t]+(.*)|[ \t]*)$")


def _strip_inline_comment(value: str) -> str:
    r"""Strip a trailing `# comment` from a plain scalar (only when preceded
    by whitespace, and not inside quotes). UberDev doesn't use inline comments
    in frontmatter, but this keeps the parser safe if one is ever added.
    """
    in_squote = in_dquote = False
    for i, ch in enumerate(value):
        if ch == "'" and not in_dquote:
            in_squote = not in_squote
        elif ch == '"' and not in_squote:
            in_dquote = not in_dquote
        elif ch == "#" and not in_squote and not in_dquote and (
            i == 0 or value[i - 1] in " \t"
        ):
            return value[:i].rstrip()
    return value


def _unquote_scalar(raw: str) -> str:
    """Decode a single-line YAML scalar value: handle "..." / '...' / plain,
    and unescape backslash sequences in double-quoted strings (UberDev agent
    descriptions contain literal \\n as two chars — Claude treats them as text
    but Codex is happier with real newlines in the description block)."""
    raw = raw.rstrip("\r\n")
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        inner = raw[1:-1]
        return _decode_yaml_double_quoted(inner)
    if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
        # YAML single-quoted: only '' → '
        return raw[1:-1].replace("''", "'")
    return _strip_inline_comment(raw).rstrip()


def _decode_yaml_double_quoted(inner: str) -> str:
    """Decode the small YAML double-quoted escape set UberDev frontmatter uses.

    Avoid Python's unicode_escape codec here: it reinterprets already-decoded
    UTF-8 text byte-by-byte, which turns em dashes and other non-ASCII prose
    into mojibake in generated TOML.
    """
    escapes = {
        "0": "\0",
        "a": "\a",
        "b": "\b",
        "t": "\t",
        "\t": "\t",
        "n": "\n",
        "v": "\v",
        "f": "\f",
        "r": "\r",
        "e": "\033",
        '"': '"',
        "/": "/",
        "\\": "\\",
        " ": " ",
    }
    out: list[str] = []
    i = 0
    while i < len(inner):
        ch = inner[i]
        if ch != "\\" or i + 1 >= len(inner):
            out.append(ch)
            i += 1
            continue
        nxt = inner[i + 1]
        if nxt in escapes:
            out.append(escapes[nxt])
            i += 2
            continue
        out.append(nxt)
        i += 2
    return "".join(out)


def parse_agent(md_path: Path) -> tuple[dict, str]:
    """Split a Claude agent .md into (frontmatter_dict, body_str).

    Tolerant of the three real frontmatter shapes UberDev uses:
      1. plain scalar, possibly multi-line (value continues on subsequent
         non-key lines — Claude's lenient reading; strict YAML rejects the
         colons inside these as nested mappings),
      2. double/single-quoted single-line scalar,
      3. block scalar (`|` / `>` — folded/literal).
    """
    text = md_path.read_text(encoding="utf-8")
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError(
            f"{md_path.name}: missing YAML frontmatter delimiters (---/---)"
        )
    fm_raw, body = m.group(1), m.group(2)
    fm_lines = fm_raw.split("\n")

    fm: dict = {}
    i = 0
    n = len(fm_lines)
    while i < n:
        line = fm_lines[i]
        if line.strip() == "":
            i += 1
            continue
        km = KEY_LINE_RE.match(line)
        if not km:
            # A non-key, non-indented line inside frontmatter. Under the
            # lenient reading this can only be a continuation of the previous
            # plain scalar (e.g. a multi-line unquoted description). We don't
            # expect these here because we consume continuations inline below.
            i += 1
            continue
        key = km.group(1)
        rest = km.group(2) or ""

        # Block scalar: `|` (literal) or `>` (folded). Value = all following
        # indented lines, de-indented by the common indent.
        if rest in ("|", ">", "|-", ">-", "|+", ">+"):
            block_lines: list[str] = []
            i += 1
            while i < n and (fm_lines[i].startswith(" ") or fm_lines[i] == ""):
                block_lines.append(fm_lines[i])
                i += 1
            # Strip common leading indent (usually 2 spaces).
            indent = min(
                (len(b) - len(b.lstrip(" ")) for b in block_lines if b.strip()),
                default=0,
            )
            value = "\n".join(b[indent:] for b in block_lines)
            if rest.startswith("|"):
                value += "\n"  # literal keeps trailing newline
            else:
                value = re.sub(r"\n+", " ", value).strip() + "\n"  # folded
            fm[key] = value.strip()
            continue

        # Quoted single-line scalar.
        if rest[:1] in ('"', "'"):
            fm[key] = _unquote_scalar(rest)
            i += 1
            continue

        # Plain scalar — may continue across following non-key lines until the
        # next `key:` line or end of frontmatter (Claude's lenient reading).
        # Colons inside are part of the value, not nesting markers.
        parts = [_strip_inline_comment(rest).rstrip()]
        i += 1
        while i < n:
            nxt = fm_lines[i]
            if nxt.strip() == "":
                break
            if KEY_LINE_RE.match(nxt):
                break  # next field begins
            parts.append(nxt.strip())
            i += 1
        fm[key] = " ".join(p for p in parts if p).strip()
        continue

    return fm, body


def codex_model_for(claude_model: str | None, source: str) -> str | None:
    """Return the Codex model string, or None to inherit the session model."""
    if claude_model is None or claude_model == "inherit":
        return None
    mapped = CODEX_MODEL_FOR_CLAUDE.get(claude_model)
    if mapped is None:
        # Unknown non-inherit model: warn but don't fail the whole run. Fall
        # back to inherit so the agent still works (just on the session model).
        print(
            f"warning: {source}: unmapped model '{claude_model}' → "
            f"inheriting session model",
            file=sys.stderr,
        )
    return mapped


def codex_port_text(value: str) -> str:
    """Apply safe, context-free Codex path substitutions.

    This mirrors codex/tools/port-skill.sh so generated agents do not retain
    Claude-only runtime variables.
    """
    codex_plugin_root = "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}"
    codex_config_path = "__UBERDEV_CODEX_CONFIG_PATH__"
    claude_config_fallback = "__UBERDEV_CLAUDE_CONFIG_FALLBACK__"
    ported = (
        value.replace("`.claude/uberdev.local.md`", f"`{codex_config_path}` (falling back to `{claude_config_fallback}`)")
        .replace("CLAUDE_PLUGIN_ROOT", "PLUGIN_ROOT")
        .replace("${PLUGIN_ROOT}/", f"{codex_plugin_root}/")
        .replace("$PLUGIN_ROOT/", f"{codex_plugin_root}/")
        .replace(".claude/uberdev.local.md", ".codex/uberdev.local.md")
        .replace("~/.claude/CLAUDE.md", "~/.codex/AGENTS.md")
        .replace("~/.claude/", "~/.codex/")
        .replace("~/.claude", "~/.codex")
        .replace(codex_config_path, ".codex/uberdev.local.md")
        .replace(claude_config_fallback, ".claude/uberdev.local.md")
        .replace("Reads CLAUDE.md/AGENTS.md (global + project)", "Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md")
        .replace("Reads CLAUDE.md (global + project)", "Reads Codex AGENTS.md plus project CLAUDE.md/AGENTS.md")
        .replace("from CLAUDE.md/AGENTS.md, RFCs, and ADRs", "from AGENTS.md/CLAUDE.md, RFCs, and ADRs")
        .replace("from CLAUDE.md, RFCs, and ADRs", "from AGENTS.md/CLAUDE.md, RFCs, and ADRs")
    )
    ported = ported.replace("Opus 4.8 1M", "the Codex session model")
    ported = re.sub(r"\s*\([^()\n]*`# WAIT 4\.8 sonnet`[^()\n]*\)", "", ported)
    ported = re.sub(r"\s*`# WAIT 4\.8 sonnet`[^\n]*", "", ported)
    ported = re.sub(r"\s*# WAIT 4\.8 sonnet:[^\n]*", "", ported)
    ported = re.sub(
        r"\s*To force a specific subagent model[^.\n]*CLAUDE_CODE_SUBAGENT_MODEL[^.\n]*(?:\([^)]*\))?\.\s*",
        " ",
        ported,
    )
    ported = re.sub(
        r"\s*Escape hatch to force[^.\n]*CLAUDE_CODE_SUBAGENT_MODEL[^.\n]*(?:\([^)]*\))?\.\s*",
        " ",
        ported,
    )
    ported = "\n".join(
        line
        for line in ported.split("\n")
        if "CLAUDE_CODE_SUBAGENT_MODEL" not in line
        and "Sonnet 4.8" not in line
        and "WAIT 4.8" not in line
    )
    return "\n".join(line.rstrip(" \t") for line in ported.split("\n"))


def toml_escape_scalar(value: str) -> str:
    """Escape a TOML basic-string scalar (for name/description single-liners).

    Description is rendered as a multi-line basic string (toml_block below);
    this is only for short scalar fields.
    """
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def toml_block(value: str) -> str:
    """Render a string as a TOML multi-line basic string (\"\"\"...\"\"\").

    Audited: no UberDev agent body or description contains a triple-double-quote
    sequence (verified at port time), so the closing delimiter is unambiguous.
    A trailing newline is normalised to match the conventional TOML form.
    """
    # Basic-string escaping inside """ is limited: backslash + control chars.
    # Backslashes are load-bearing in agent prose (e.g. regex, shell), so we
    # escape them. Newlines stay literal (that's the point of a block string).
    escaped = value.replace("\\", "\\\\").replace("\r", "")
    # TOML multi-line basic strings strip one leading newline right after """.
    if not escaped.startswith("\n"):
        escaped = "\n" + escaped
    if not escaped.endswith("\n"):
        escaped += "\n"
    return f'"""{escaped}"""'


def render_toml(fm: dict, body: str, source: str) -> str:
    """Render the full Codex agent TOML document."""
    lines: list[str] = []

    source_name = fm.get("name")
    if not isinstance(source_name, str) or not source_name:
        raise ValueError(f"{source}: frontmatter missing required 'name'")
    description = fm.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ValueError(f"{source}: frontmatter missing required 'description'")
    if not body.strip():
        raise ValueError(f"{source}: empty agent body (developer_instructions)")

    name = f"uberdev-{source_name}"
    description = codex_port_text(description)
    body = codex_port_text(body)

    lines.append(f"name = {toml_escape_scalar(name)}")
    lines.append(f"description = {toml_block(description)}")

    model = codex_model_for(fm.get("model"), source)
    if model is not None:
        lines.append(f"model = \"{model}\"")

    # developer_instructions is the agent's system-prompt body. Required by Codex.
    lines.append(f"developer_instructions = {toml_block(body)}")

    # Header comment so users editing ~/.codex/agents/ know the file's origin.
    header = (
        f"# Generated by codex/tools/convert-agents.py from "
        f"plugins/uberdev/agents/{source}\n"
        f"# Re-run the installer to refresh; do not edit by hand "
        f"(edits will be overwritten).\n"
    )
    return header + "\n".join(lines) + "\n"


def convert_dir(src_dir: Path, out_dir: Path) -> tuple[int, int]:
    """Convert every *.md in src_dir → uberdev-<name>.toml in out_dir.

    Returns (ok_count, fail_count).
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    ok = fail = 0
    md_files = sorted(src_dir.glob("*.md"))
    if not md_files:
        print(f"error: no *.md agents found in {src_dir}", file=sys.stderr)
        return 0, 1

    for md_path in md_files:
        source_name = md_path.name
        try:
            fm, body = parse_agent(md_path)
            toml_text = render_toml(fm, body, source_name)
        except (ValueError, OSError) as e:
            print(f"error: {e}", file=sys.stderr)
            fail += 1
            continue

        agent_name = fm["name"]
        out_path = out_dir / f"uberdev-{agent_name}.toml"
        out_path.write_text(toml_text, encoding="utf-8")
        ok += 1
        print(f"  ✓ {source_name} → {out_path.name}")

    return ok, fail


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    src_dir = Path(argv[1])
    out_dir = Path(argv[2])
    if not src_dir.is_dir():
        print(f"error: source dir not found: {src_dir}", file=sys.stderr)
        return 1

    print(f"Converting agents: {src_dir} → {out_dir}")
    ok, fail = convert_dir(src_dir, out_dir)
    print(f"\nDone: {ok} converted, {fail} failed.")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

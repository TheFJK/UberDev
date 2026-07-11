#!/usr/bin/env python3
"""
convert-commands.py — Claude Code commands/*.md → Codex uberdev-cmd-* skills.

Codex custom prompts are deprecated, and skills are the shareable replacement
for reusable workflows. This converter re-homes each UberDev command as a
Codex skill named `uberdev-cmd-<name>`, so they're invokable via
`$uberdev-cmd-<name>` or implicitly when the user's task matches the trigger
description.

Mapping per command:
  name            → uberdev-cmd-<command-name>   (namespaced under uberdev-cmd-)
  description     → rewritten as a when-to-use trigger (prefixed "Use when …")
  argument-hint   → preserved as an "## Arguments" section
  allowed-tools   → dropped (Codex uses sandbox/approval, not tool allowlists)
  <body>          → preserved verbatim, behind a Codex bridge preamble that
                    explains how $ARGUMENTS / Task / Skill map on Codex
                    (the runtime tool shim from references/codex-tools.md).
                    Claude-only path variables are rewritten for Codex.

Two commands are Claude-Code-specific and SKIPPED (return a note instead):
  install-aliases, uninstall-aliases — manage ~/.claude/commands/ forwarders,
  which have no Codex equivalent (Codex has no slash-command alias system).

Idempotent: re-running overwrites deterministically. Source never modified.

Usage:
    python3 convert-commands.py <commands_md_dir> <output_skills_dir>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

FRONTMATTER_RE = re.compile(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)(.*)\Z", re.DOTALL)
KEY_LINE_RE = re.compile(r'^([a-zA-Z_][a-zA-Z0-9_-]*):(?:[ \t]+(.*))?[ \t]*$')

# Commands that don't port to Codex (Claude-Code-specific machinery).
SKIP_COMMANDS = {
    "install-aliases": "manages ~/.claude/commands/ short-form alias forwarders; "
                       "Codex has no slash-command alias system to install into.",
    "uninstall-aliases": "removes ~/.claude/commands/ forwarders; "
                         "Codex has no equivalent (nothing was installed).",
}


def parse_command(md_path: Path) -> tuple[dict, str]:
    """Parse a Claude command .md frontmatter (tolerant, like convert-agents)."""
    text = md_path.read_text(encoding="utf-8")
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError(f"{md_path.name}: missing ---/--- frontmatter delimiters")
    fm_raw, body = m.group(1), m.group(2)
    fm: dict = {}
    for line in fm_raw.split("\n"):
        km = KEY_LINE_RE.match(line)
        if not km:
            continue
        key, rest = km.group(1), (km.group(2) or "")
        # strip surrounding quotes if present
        if len(rest) >= 2 and rest[0] in ('"', "'") and rest[-1] == rest[0]:
            rest = rest[1:-1]
        fm[key] = rest
    return fm, body


BRIDGE_PREAMBLE = """\
# Codex bridge — read first

This skill was ported from a Claude Code slash command (`/{name}`). On Codex:

- **`$ARGUMENTS`** below = the user's free-text request (the words after the
  command name, or your whole task description if invoked implicitly).
- **`Task` tool** calls → use `spawn_agent`; collect results with `wait_agent`
  (see ~/.agents/skills/using-uberdev/references/codex-tools.md for the
  named-agent mapping).
- **`Skill` tool** invocations → skills load natively; just follow the named
  skill's instructions.
- **`Workflow` tool** (testers/uberscan/ubersimplify) → no Codex equivalent;
  follow the skill's `## No-Workflow fallback` section instead.
- **`MultiEdit`** → apply edits with your native file-edit tool.

Original argument hint: `{arg_hint}`

---

"""


def codex_port_text(value: str) -> str:
    """Apply safe Codex prompt normalization and path substitutions.

    This mirrors codex/tools/port-skill.sh for shared path rewrites, then
    normalizes generated command-skill wording that differs between Claude and
    Codex.
    """
    codex_plugin_root = "${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}/plugins/uberdev-codex}"
    claude_with_codex_fallback = (
        "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CODEX_HOME:-$HOME/.codex}"
        "/plugins/uberdev-codex}}"
    )
    neutral_plugin_root = "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
    normalized_neutral_root = "${PLUGIN_ROOT:-${PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
    codex_config_path = "__UBERDEV_CODEX_CONFIG_PATH__"
    claude_config_fallback = "__UBERDEV_CLAUDE_CONFIG_FALLBACK__"
    ported = (
        value.replace(claude_with_codex_fallback, codex_plugin_root)
        .replace(neutral_plugin_root, codex_plugin_root)
        .replace("`.claude/uberdev.local.md`", f"`{codex_config_path}` (falling back to `{claude_config_fallback}`)")
        .replace("CLAUDE_PLUGIN_ROOT", "PLUGIN_ROOT")
        .replace(normalized_neutral_root, codex_plugin_root)
        .replace('"$PLUGIN_ROOT/', f'"{codex_plugin_root}/')
        .replace('"${PLUGIN_ROOT}/', f'"{codex_plugin_root}/')
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
    return ported


def render_skill(name: str, fm: dict, body: str) -> str:
    """Render the full Codex command-skill SKILL.md."""
    description = codex_port_text(fm.get("description", "").strip())
    arg_hint = codex_port_text(fm.get("argument-hint", "").strip())
    body = codex_port_text(body)
    # Rewrite the description as a Codex trigger: "Use when …".
    # The original descriptions are already imperative ("Create a GitHub issue…")
    # so we prefix "Use when the user wants to " and lower-case the first char
    # for natural trigger phrasing. Keep the full original as a second sentence.
    trigger_base = description.rstrip(".")
    first_lower = trigger_base[:1].lower() + trigger_base[1:] if trigger_base else ""
    trigger = (
        f"Use when the user wants to {first_lower}. "
        f"Invokable explicitly as $uberdev-cmd-{name}. "
        f"Original description: {description}"
    )

    out = []
    out.append("---")
    out.append(f"name: uberdev-cmd-{name}")
    out.append(f'description: "{trigger.replace(chr(34), chr(39))}"')
    out.append("---")
    out.append("")
    out.append(BRIDGE_PREAMBLE.format(name=name, arg_hint=arg_hint or "(none)"))
    out.append(body.rstrip())
    out.append("")
    return "\n".join(out)


def convert_dir(src_dir: Path, out_dir: Path) -> tuple[int, int, int]:
    """Convert commands. Returns (ok, skipped, failed)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    ok = skipped = failed = 0
    md_files = sorted(src_dir.glob("*.md"))

    for md_path in md_files:
        cmd_name = md_path.stem
        if cmd_name in SKIP_COMMANDS:
            print(f"  ⊘ {md_path.name} → skipped ({SKIP_COMMANDS[cmd_name]})")
            skipped += 1
            continue
        try:
            fm, body = parse_command(md_path)
            skill_text = render_skill(cmd_name, fm, body)
        except (ValueError, OSError) as e:
            print(f"error: {e}", file=sys.stderr)
            failed += 1
            continue
        skill_dir = out_dir / f"uberdev-cmd-{cmd_name}"
        skill_dir.mkdir(parents=True, exist_ok=True)
        (skill_dir / "SKILL.md").write_text(skill_text, encoding="utf-8")
        ok += 1
        print(f"  ✓ {md_path.name} → uberdev-cmd-{cmd_name}/SKILL.md")

    return ok, skipped, failed


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    src_dir, out_dir = Path(argv[1]), Path(argv[2])
    if not src_dir.is_dir():
        print(f"error: source commands dir not found: {src_dir}", file=sys.stderr)
        return 1
    print(f"Converting commands: {src_dir} → {out_dir}")
    ok, skipped, failed = convert_dir(src_dir, out_dir)
    print(f"\nDone: {ok} converted, {skipped} skipped (Claude-only), {failed} failed.")
    if ok == 0:
        print(f"error: no command skills generated from: {src_dir}", file=sys.stderr)
        return 2
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

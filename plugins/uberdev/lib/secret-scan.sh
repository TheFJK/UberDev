#!/usr/bin/env bash
# plugins/uberdev/lib/secret-scan.sh
#
# Layered-defense pre-push secret scan: gitleaks primary + inline regex fallback.
# Fail-CLOSED on either signal (leak found OR gitleaks crashed).
#
# Public surface:
#   uberdev_run_secret_scan_stdin     Read candidate text from stdin, exit non-zero
#                                     if any secret is detected; exit zero on clean.
#
# Source from any uberdev shell context as:
#   source "${CLAUDE_PLUGIN_ROOT}/lib/secret-scan.sh"
#
# The library is idempotent at source-time: a second `source` is a no-op.
# Mirrors the lib/config-read.sh idempotency guard pattern.

if [ "${_UBERDEV_SECRET_SCAN_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_SECRET_SCAN_LOADED=1

# Line-level allowlist marker — the single escape hatch for a false positive.
# `gitleaks:allow` is gitleaks' own native inline-exemption token, so reusing it
# keeps BOTH layers on one contract: gitleaks skips a marked line itself, and the
# regex fallback filters marked lines out before scanning. Any other spelling
# would make the two layers disagree (gitleaks clean, fallback still aborting).
#
# Deliberately a plain shell variable, not a `local`: callers name the escape
# hatch in their own abort message by expanding it (see
# skills/finish-branch/SKILL.md `abort_if_secret`) instead of re-typing the
# literal, so the marker has exactly one definition site.
UBERDEV_SECRET_SCAN_ALLOW_MARKER='gitleaks:allow'

# _uberdev_secret_scan_gitleaks_config
#   Resolve the gitleaks config that governs this scan. Precedence:
#     1. $GITLEAKS_CONFIG      — explicit operator override
#     2. <repo-root>/.gitleaks.toml — repo-owned rules/allowlist
#     3. (none)                — gitleaks' built-in default ruleset
#   Prints the resolved path and returns 0; returns 1 when no config applies.
#
#   Without this, `gitleaks stdin` ran with neither `--config` nor an inherited
#   `GITLEAKS_CONFIG`, so a repo `.gitleaks.toml` allowlist was silently ignored
#   and a false positive had no escape hatch at all (#303).
#
#   A configured-but-missing path is printed rather than skipped: gitleaks then
#   fails on it and the scan fails CLOSED, instead of silently downgrading to the
#   default ruleset and reporting a differently-configured repo as clean.
#
#   NOTE for repo owners: `--config` REPLACES gitleaks' built-in ruleset, so a
#   `.gitleaks.toml` that carries only an allowlist detects nothing. Declare
#   `[extend] useDefault = true` to keep the built-ins. Either way the regex
#   fallback below always runs, so the config can never disarm this library
#   entirely — that is the point of the second layer.
_uberdev_secret_scan_gitleaks_config() {
  local root candidate
  if [ -n "${GITLEAKS_CONFIG:-}" ]; then
    printf '%s\n' "$GITLEAKS_CONFIG"
    return 0
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  candidate="$root/.gitleaks.toml"
  [ -f "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# _uberdev_secret_scan_grep_failure LAYER RC
#   One diagnostic template for every tri-state `grep` in this library, so a
#   broken scanner always reads the same way regardless of which grep broke.
_uberdev_secret_scan_grep_failure() {
  printf 'ERROR: uberdev secret-scan scanner failure — %s grep exited %s (regex/I-O error, NOT a secret match). Failing CLOSED; fix the patterns in lib/secret-scan.sh.\n' \
    "$1" "$2" >&2
}

# _uberdev_secret_scan_allow_hint
#   Name the escape hatch on every abort path, so a false positive is
#   actionable without reading this file.
_uberdev_secret_scan_allow_hint() {
  printf 'uberdev secret-scan: if this is a false positive, exempt the individual line with the %s marker, or add an allowlist rule to the repo .gitleaks.toml.\n' \
    "$UBERDEV_SECRET_SCAN_ALLOW_MARKER" >&2
}

# uberdev_run_secret_scan_stdin
#   Reads candidate text from stdin. Returns:
#     0    — clean (no secret detected)
#     1    — secret detected (fail-CLOSED)
#     >=2  — scanner itself failed: gitleaks crashed OR the regex-fallback grep
#            errored (fail-CLOSED on a code distinct from the match code 1, so a
#            broken scanner is never silently clean nor mistaken for a real leak)
#   Layered scan: gitleaks primary (when installed), regex fallback always.
uberdev_run_secret_scan_stdin() {
  # Primary: gitleaks (when installed). gitleaks exits 0 if no leaks found,
  # 1 if leaks found, anything else on crash. Fail-CLOSED on any non-zero.
  local input out rc config
  input=$(cat)
  if command -v gitleaks >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    if config=$(_uberdev_secret_scan_gitleaks_config); then
      out=$(printf '%s' "$input" | gitleaks stdin --no-banner --redact --config "$config" 2>&1) ; rc=$?
    else
      out=$(printf '%s' "$input" | gitleaks stdin --no-banner --redact 2>&1) ; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" >&2
      _uberdev_secret_scan_allow_hint
      return "$rc"
    fi
  fi
  # Regex fallback: always run (defense in depth even when gitleaks ran clean).
  # Patterns mirror the existing inline list in finish-branch/SKILL.md.
  #
  # grep's exit status is TRI-STATE and the three cases are NOT interchangeable:
  #   0   one or more patterns matched -> secret found (fail-CLOSED, return 1)
  #   1   no line matched              -> clean (return 0)
  #   >=2 grep itself failed (a malformed pattern, I/O error, …) -> the SCANNER
  #       is broken, NOT a secret match. Emit a distinct diagnostic and
  #       fail-CLOSED on grep's own rc so a broken scanner can never be (a)
  #       silently reported clean NOR (b) mistaken for a real leak (#189).
  # `|| grep_rc=$?` captures grep's rc (the pipeline's status is grep's, the last
  # stage) while keeping the non-zero pipeline out of an enclosing `set -e`.
  #
  # Line-level allowlist: marked lines are dropped BEFORE the regex pass so the
  # fallback honours exactly the same exemption gitleaks applies natively.
  # `grep -v` is tri-state too: rc 1 means every line was filtered (or the input
  # was empty), which leaves an empty — and therefore genuinely clean — scan
  # surface; rc>=2 is a broken filter and must fail CLOSED like any other.
  local filter_rc=0 scan_input
  scan_input=$(printf '%s' "$input" | grep -Fv -e "$UBERDEV_SECRET_SCAN_ALLOW_MARKER") \
    || filter_rc=$?
  if [ "$filter_rc" -ge 2 ]; then
    _uberdev_secret_scan_grep_failure 'allowlist filter' "$filter_rc"
    return "$filter_rc"
  fi
  local grep_rc=0
  printf '%s' "$scan_input" | grep -EnH --color=never \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'aws_access_key[_-]?id[[:space:]]*[:=][[:space:]]*[A-Z0-9]{16,}' \
      -e 'aws_secret_access_key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{40}' \
      -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
      -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
      -e 'sk-[A-Za-z0-9]{32,}' \
      -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
      >&2 || grep_rc=$?
  if [ "$grep_rc" -eq 0 ]; then
    _uberdev_secret_scan_allow_hint
    return 1                  # match -> secret found (fail-CLOSED)
  elif [ "$grep_rc" -ge 2 ]; then
    _uberdev_secret_scan_grep_failure 'regex fallback' "$grep_rc"
    return "$grep_rc"         # scanner error -> fail-CLOSED, distinct from a match
  fi
  return 0                     # grep_rc == 1 -> no match -> clean
}

# Emit gitleaks-missing warning ONCE per parent shell — the source-time guard
# above already protects against a second emission on re-source. We do NOT
# emit inside the function because subshell exports do not propagate.
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "WARNING: gitleaks not installed — using regex fallback only. Recommend: brew install gitleaks" >&2
fi

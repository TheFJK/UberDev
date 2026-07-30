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
#     1. $GITLEAKS_CONFIG           — explicit operator override
#     2. <repo-root>/.gitleaks.toml — repo-owned rules/allowlist
#     3. (none)                     — caller pins gitleaks' built-in ruleset
#   Prints the resolved path and returns 0; returns 1 when no config applies.
#
#   gitleaks already resolves a config on its own: it binds `$GITLEAKS_CONFIG`
#   natively, and for `stdin` it auto-discovers a `.gitleaks.toml` in the CURRENT
#   WORKING DIRECTORY (both verified against gitleaks 8.30.1). Resolving it here
#   anyway is what makes the governing ruleset (a) anchored to the REPO root
#   instead of to wherever the caller happens to stand, and (b) inspectable by
#   `_uberdev_secret_scan_config_extends_default` before a clean verdict from it
#   is believed. Both are load-bearing, because a config REPLACES gitleaks'
#   built-in ruleset (#303).
#
#   A configured-but-missing path is printed rather than skipped so the caller
#   fails CLOSED on it with a scanner-failure diagnostic. gitleaks' own answer to
#   a missing config is exit 1 — indistinguishable from "leak found" — which is
#   exactly the confusion the caller's readability check removes.
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

# _uberdev_secret_scan_config_extends_default CONFIG
#   Returns 0 iff CONFIG declares `useDefault = true` inside the `[extend]`
#   table — i.e. iff a CLEAN verdict under CONFIG is also a statement about
#   gitleaks' built-in ruleset.
#
#   This is the guard against the config becoming a fail-OPEN: `--config`
#   REPLACES the built-ins, so a repo that merely contains a rules-less
#   `.gitleaks.toml` would otherwise downgrade the primary layer to nothing —
#   and since that file is itself part of the diff being scanned, a leaking
#   change could ship its own disarm.
#
#   Anything that is not an unambiguous `[extend] useDefault = true` reads as
#   "does not extend": a rules-less allowlist-only file, a standalone custom
#   ruleset, or a `useDefault` key outside `[extend]` (which gitleaks ignores).
#   Being wrong in that direction costs one extra scan pass; being wrong in the
#   other direction costs coverage.
#   Case folding and blank stripping mirror what gitleaks itself does when it
#   decodes the file (viper matches keys case-insensitively), so the check is
#   about the DECLARATION, not about its formatting.
_uberdev_secret_scan_config_extends_default() {
  local normalized token section=''
  [ -f "${1-}" ] && [ -r "${1-}" ] || return 1
  # One normalising pipeline for the whole file — blanks and any CR from a CRLF
  # checkout removed, case folded — so the loop below spawns nothing per line
  # even for a large ruleset.
  normalized=$(tr -d '[:blank:]\r' < "$1" | tr '[:upper:]' '[:lower:]') || return 1
  while IFS= read -r token || [ -n "$token" ]; do
    token="${token%%#*}"
    case "$token" in
      '')   continue ;;
      '['*) section="$token"; continue ;;
    esac
    if [ "$section" = '[extend]' ] && [ "$token" = 'usedefault=true' ]; then
      return 0
    fi
  done <<<"$normalized"
  return 1
}

# _uberdev_secret_scan_default_config
#   Materialise a throwaway config that pins gitleaks to EXACTLY its built-in
#   ruleset and print its path. An explicit `--config` this library owns is the
#   only way to get that guarantee: `$GITLEAKS_CONFIG` in the environment and a
#   `.gitleaks.toml` in the caller's CWD are both picked up by gitleaks
#   unprompted, and both REPLACE the built-ins. The `--config` flag outranks
#   both (verified against gitleaks 8.30.1).
#   Prints nothing and returns 1 when the file cannot be created — the caller
#   turns that into a fail-CLOSED scanner failure rather than an unpinned scan.
#
#   NOT named `path`: this library is sourced under zsh too (the finish-branch
#   fences run under /bin/zsh), and there `path` is tied to `PATH` — `local path`
#   empties the command search path for the whole function body, so every
#   external call inside it (mktemp here) silently stops resolving.
_uberdev_secret_scan_default_config() {
  local config_path
  config_path=$(mktemp "${TMPDIR:-/tmp}/uberdev-gitleaks-defaults.XXXXXX" 2>/dev/null) || return 1
  printf '[extend]\nuseDefault = true\n' > "$config_path" 2>/dev/null || {
    rm -f "$config_path"
    return 1
  }
  printf '%s\n' "$config_path"
}

# _uberdev_secret_scan_grep_failure LAYER RC
#   One diagnostic template for every tri-state `grep` in this library, so a
#   broken scanner always reads the same way regardless of which grep broke.
_uberdev_secret_scan_grep_failure() {
  printf 'ERROR: uberdev secret-scan scanner failure — %s grep exited %s (regex/I-O error, NOT a secret match). Failing CLOSED; fix the patterns in lib/secret-scan.sh.\n' \
    "$1" "$2" >&2
}

# _uberdev_secret_scan_scanner_failure DETAIL
#   Broken-scanner diagnostic for the gitleaks layer, deliberately worded like
#   _uberdev_secret_scan_grep_failure above: a scanner that could not RUN is not
#   a secret match, and must never be answered with the allowlist hint. Telling
#   an operator to mark the line would strip it from the regex fallback too
#   (see the filter below), removing the second layer while the first stays
#   broken — the exact fail-OPEN the tri-state grep handling exists to prevent.
_uberdev_secret_scan_scanner_failure() {
  printf 'ERROR: uberdev secret-scan scanner failure — %s (NOT a secret match). Failing CLOSED; fix the scanner or its config and rerun.\n' \
    "$1" >&2
}

# _uberdev_secret_scan_config_downgrade CONFIG
#   Warn that CONFIG replaces rather than extends the built-in ruleset, so the
#   caller's extra built-ins pass is explainable instead of mysterious.
_uberdev_secret_scan_config_downgrade() {
  printf 'WARNING: uberdev secret-scan — %s does not declare `useDefault = true` under `[extend]`, so it REPLACES gitleaks built-in ruleset instead of extending it. Re-scanning with the built-ins so a config can never silently disarm the primary layer; add those two lines to the config to make its rules and allowlist govern the whole scan.\n' \
    "$1" >&2
}

# _uberdev_secret_scan_gitleaks_verdict OUT RC
#   Surface one non-zero gitleaks result. rc 1 is a real match (name the escape
#   hatch); rc>=2 is a crashed scanner (name the scanner failure instead — the
#   allowlist hint is actively harmful advice there).
_uberdev_secret_scan_gitleaks_verdict() {
  printf '%s\n' "$1" >&2
  if [ "$2" -ge 2 ]; then
    _uberdev_secret_scan_scanner_failure "gitleaks exited $2"
  else
    _uberdev_secret_scan_allow_hint
  fi
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
#     >=2  — scanner itself failed: gitleaks crashed, its configured ruleset is
#            unreadable, the built-in-ruleset config could not be materialised,
#            OR the regex-fallback grep errored (fail-CLOSED on a code distinct
#            from the match code 1, so a broken scanner is never silently clean
#            nor mistaken for a real leak)
#   Layered scan: gitleaks primary (when installed), regex fallback always.
uberdev_run_secret_scan_stdin() {
  # Primary: gitleaks (when installed). gitleaks exits 0 if no leaks found,
  # 1 if leaks found, anything else on crash. Fail-CLOSED on any non-zero.
  #
  # A resolved config may only ADD coverage on top of gitleaks' built-in
  # ruleset, never replace it: `--config` REPLACES the built-ins, so a clean
  # verdict from a config that does not declare `[extend] useDefault = true`
  # says nothing about the built-in rules and must be followed by a pass that
  # does. Every gitleaks invocation therefore carries an EXPLICIT `--config`,
  # including the no-repo-config case — otherwise gitleaks would silently adopt
  # `$GITLEAKS_CONFIG` or a `.gitleaks.toml` from the caller's CWD and the
  # ruleset that governed the scan would not be the one this library resolved.
  local input out rc config floor needs_floor
  input=$(cat)
  if command -v gitleaks >/dev/null 2>&1; then
    needs_floor=1
    if config=$(_uberdev_secret_scan_gitleaks_config); then
      if [ ! -f "$config" ] || [ ! -r "$config" ]; then
        _uberdev_secret_scan_scanner_failure "gitleaks config '$config' is not a readable file"
        return 2
      fi
      out=$(printf '%s' "$input" | gitleaks stdin --no-banner --redact --config "$config" 2>&1) ; rc=$?
      if [ "$rc" -ne 0 ]; then
        _uberdev_secret_scan_gitleaks_verdict "$out" "$rc"
        return "$rc"
      fi
      if _uberdev_secret_scan_config_extends_default "$config"; then
        needs_floor=0
      else
        _uberdev_secret_scan_config_downgrade "$config"
      fi
    fi
    if [ "$needs_floor" -eq 1 ]; then
      floor=$(_uberdev_secret_scan_default_config) || {
        _uberdev_secret_scan_scanner_failure 'gitleaks built-in ruleset config could not be created'
        return 2
      }
      out=$(printf '%s' "$input" | gitleaks stdin --no-banner --redact --config "$floor" 2>&1) ; rc=$?
      rm -f "$floor"
      if [ "$rc" -ne 0 ]; then
        _uberdev_secret_scan_gitleaks_verdict "$out" "$rc"
        return "$rc"
      fi
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

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
  local input out rc
  input=$(cat)
  if command -v gitleaks >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    out=$(printf '%s' "$input" | gitleaks stdin --no-banner --redact 2>&1) ; rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" >&2
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
  local grep_rc=0
  printf '%s' "$input" | grep -EnH --color=never \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'aws_access_key[_-]?id[[:space:]]*[:=][[:space:]]*[A-Z0-9]{16,}' \
      -e 'aws_secret_access_key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{40}' \
      -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
      -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
      -e 'sk-[A-Za-z0-9]{32,}' \
      -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
      >&2 || grep_rc=$?
  if [ "$grep_rc" -eq 0 ]; then
    return 1                  # match -> secret found (fail-CLOSED)
  elif [ "$grep_rc" -ge 2 ]; then
    printf 'ERROR: uberdev secret-scan scanner failure — regex fallback grep exited %s (regex/I-O error, NOT a secret match). Failing CLOSED; fix the patterns in lib/secret-scan.sh.\n' "$grep_rc" >&2
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

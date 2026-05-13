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
#     0 — clean (no secret detected)
#     non-zero — secret detected OR gitleaks crashed (fail-CLOSED on both)
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
  if printf '%s' "$input" | grep -EnH --color=never \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'aws_access_key[_-]?id[[:space:]]*[:=][[:space:]]*[A-Z0-9]{16,}' \
      -e 'aws_secret_access_key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{40}' \
      -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
      -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
      -e 'sk-[A-Za-z0-9]{32,}' \
      -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
      >&2; then
    return 1
  fi
  return 0
}

# Emit gitleaks-missing warning ONCE per parent shell — the source-time guard
# above already protects against a second emission on re-source. We do NOT
# emit inside the function because subshell exports do not propagate.
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "WARNING: gitleaks not installed — using regex fallback only. Recommend: brew install gitleaks" >&2
fi

# plugins/uberdev/lib/config-read.sh
#
# Shared library for reading + validating the new optional config keys
# under .claude/uberdev.local.md. SOURCED, never executed.
# No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_read_int_in_range  KEY ENV_VAR MIN MAX DEFAULT
#   uberdev_read_enum          KEY ENV_VAR ALLOWED_PIPE_LIST DEFAULT
#   uberdev_read_string        KEY ENV_VAR REGEX DEFAULT
#   uberdev_tier_rank          TIER_NAME            -> 0|1|2|3|""
#   uberdev_tier_name          RANK                 -> trivial|small|medium|large
#   uberdev_clamp_tier         TIER FLOOR CEILING   -> clamped tier name
#
# Sourced by:
#   - launcher script written by skills/solve-pipeline/SKILL.md (/tmp/solve-$N.sh)
#   - tests/config-override.test.sh
#
# All variable expansions are double-quoted (security mitigation 1, mirrors
# aliases-sync.sh:36 discipline).
#
# Source-time idempotent: a guard at the top of the file makes repeat
# `source` calls cheap (the function bodies are re-defined but no
# external state is created).

if [ "${_UBERDEV_CONFIG_READ_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_UBERDEV_CONFIG_READ_LOADED=1

# Verbatim warning format (D7). Constant string template — no free-form prose.
# Used by every validation-failure path; tests assert on this exact shape.
_UBERDEV_WARN_FORMAT='warning: %s = %s is invalid (%s); falling back to default %s'

# Default config-file path (callers may override by exporting UBERDEV_CONFIG_FILE).
: "${UBERDEV_CONFIG_FILE:=${PWD}/.claude/uberdev.local.md}"

# _uberdev_sentinel_name KEY
# Translate dot-separated key path to UBERDEV_VALIDATED_<UPPER_UNDER> form.
# e.g. fanout_concurrency.research -> UBERDEV_VALIDATED_FANOUT_CONCURRENCY_RESEARCH
_uberdev_sentinel_name() {
  local key="$1"
  local upper
  upper="$(printf '%s' "$key" | tr '.[:lower:]' '_[:upper:]')"
  printf 'UBERDEV_VALIDATED_%s' "$upper"
}

# _uberdev_set_validated KEY
# Set the sentinel env var to 1, exported, so child shells inherit it.
_uberdev_set_validated() {
  local sentinel
  sentinel="$(_uberdev_sentinel_name "$1")"
  export "$sentinel=1"
}

# _uberdev_is_validated KEY -> exit 0 if validated, 1 otherwise.
_uberdev_is_validated() {
  local sentinel val
  sentinel="$(_uberdev_sentinel_name "$1")"
  val="$(eval "printf '%s' \"\${$sentinel:-}\"")"
  [ "$val" = "1" ]
}

# _uberdev_warn_invalid KEY VAL REASON DEFAULT
# Emit one stderr line in the verbatim D7 format. No-op if sentinel set
# (one warning per key per session; mirrors STRATEGY_FLAGS_DEPRECATED_NOTE).
_uberdev_warn_invalid() {
  local key="$1" val="$2" reason="$3" default="$4"
  if _uberdev_is_validated "$key"; then return 0; fi
  # shellcheck disable=SC2059
  printf "$_UBERDEV_WARN_FORMAT\n" "$key" "'$val'" "$reason" "$default" >&2
  _uberdev_audit_invalid "$key" "$val" "$reason" "$default"
}

# _uberdev_audit_invalid KEY VAL REASON DEFAULT
# Append one JSON line to .uberdev/audit.jsonl when the audit dir exists.
# Missing dir is silent (operators opt-in by creating .uberdev/). A write
# failure on an existing dir (read-only file, full disk, stale NFS) surfaces
# one stderr line so the operator sees the audit gap.
_uberdev_audit_invalid() {
  local key="$1" val="$2" reason="$3" default="$4"
  local audit_dir="${PWD}/.uberdev"
  [ -d "$audit_dir" ] || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  if ! printf '{"event":"uberdev_config_invalid","key":"%s","value":"%s","reason":"%s","fallback_to":"%s","ts":"%s"}\n' \
    "$key" "$val" "$reason" "$default" "$ts" \
    >> "$audit_dir/audit.jsonl" 2>/dev/null; then
    echo "warning: failed to write config audit event for $key (audit.jsonl write-protected?)" >&2
  fi
}

# _uberdev_read_nested KEY_PATH FILE
# Two-pass grep for a 2-level YAML-ish key (e.g. fanout_concurrency.research).
# Top-level keys (no dot) read with simple anchored grep.
# Returns: stdout = raw value (post-colon, leading-whitespace stripped); empty on miss.
_uberdev_read_nested() {
  local key_path="$1" file="$2"
  [ -f "$file" ] || return 0
  local parent leaf raw
  case "$key_path" in
    *.*)
      parent="${key_path%%.*}"
      leaf="${key_path#*.}"
      # Section-bounded extraction: from the parent header to the next
      # top-level key (^[A-Za-z_]) OR end-of-file.
      raw="$(awk -v p="^${parent}:" -v l="^[[:space:]]+${leaf}:" '
        $0 ~ p { in_block=1; next }
        in_block && /^[A-Za-z_]/ { in_block=0 }
        in_block && $0 ~ l { sub(/^[[:space:]]+[^:]+:[[:space:]]*/, ""); print; exit }
      ' "$file")"
      ;;
    *)
      raw="$(grep -E "^${key_path}:" "$file" 2>/dev/null \
        | head -1 \
        | sed -E "s/^${key_path}:[[:space:]]*//")"
      ;;
  esac
  # Strip trailing whitespace and any inline `# comment` tail.
  raw="${raw%%#*}"
  # POSIX-portable trim: strip leading/trailing spaces and tabs.
  raw="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  printf '%s' "$raw"
}

# uberdev_read_int_in_range KEY ENV_VAR MIN MAX DEFAULT
# Returns: validated integer in [MIN, MAX] on stdout, or DEFAULT on miss/invalid.
# Side effect: stderr warning + audit event on validation failure (once per session).
uberdev_read_int_in_range() {
  local key="$1" env_var="$2" min="$3" max="$4" default="$5"
  local val source

  # Tier 1: env var.
  val="$(eval "printf '%s' \"\${$env_var:-}\"")"
  if [ -n "$val" ]; then
    source=env
  else
    # Tier 2: config file.
    val="$(_uberdev_read_nested "$key" "$UBERDEV_CONFIG_FILE")"
    source=file
  fi

  # Tier 3: empty -> default (silent; absence is not an error).
  if [ -z "$val" ]; then
    _uberdev_set_validated "$key"
    printf '%s' "$default"
    return 0
  fi

  # Anchored regex: positive integer, no leading zero (defensive against octal).
  if ! printf '%s' "$val" | grep -qE '^[1-9][0-9]*$'; then
    _uberdev_warn_invalid "$key" "$val" non_integer "$default"
    _uberdev_set_validated "$key"
    printf '%s' "$default"
    return 0
  fi

  if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
    _uberdev_warn_invalid "$key" "$val" out_of_range "$default"
    _uberdev_set_validated "$key"
    printf '%s' "$default"
    return 0
  fi

  _uberdev_set_validated "$key"
  printf '%s' "$val"
}

# uberdev_read_enum KEY ENV_VAR ALLOWED_PIPE_LIST DEFAULT
# ALLOWED_PIPE_LIST: pipe-separated values, e.g. "trivial|small|medium|large".
# Exact-match (case-sensitive); typoed capitalisation is rejected by design (D7 paranoia).
uberdev_read_enum() {
  local key="$1" env_var="$2" allowed="$3" default="$4"
  local val
  val="$(eval "printf '%s' \"\${$env_var:-}\"")"
  if [ -z "$val" ]; then
    val="$(_uberdev_read_nested "$key" "$UBERDEV_CONFIG_FILE")"
  fi
  if [ -z "$val" ]; then
    _uberdev_set_validated "$key"
    printf '%s' "$default"
    return 0
  fi
  # Exact-match against allowed pipe-list.
  case "|$allowed|" in
    *"|$val|"*)
      _uberdev_set_validated "$key"
      printf '%s' "$val"
      return 0
      ;;
  esac
  _uberdev_warn_invalid "$key" "$val" invalid_enum "$default"
  _uberdev_set_validated "$key"
  printf '%s' "$default"
}

# uberdev_read_string KEY ENV_VAR REGEX DEFAULT
# REGEX: anchored ERE pattern (caller supplies leading ^ and trailing $).
uberdev_read_string() {
  local key="$1" env_var="$2" regex="$3" default="$4"
  local val
  val="$(eval "printf '%s' \"\${$env_var:-}\"")"
  if [ -z "$val" ]; then
    val="$(_uberdev_read_nested "$key" "$UBERDEV_CONFIG_FILE")"
  fi
  if [ -z "$val" ]; then
    _uberdev_set_validated "$key"
    printf '%s' "$default"
    return 0
  fi
  if printf '%s' "$val" | grep -qE -- "$regex"; then
    _uberdev_set_validated "$key"
    printf '%s' "$val"
    return 0
  fi
  _uberdev_warn_invalid "$key" "$val" regex_mismatch "$default"
  _uberdev_set_validated "$key"
  printf '%s' "$default"
}

# uberdev_tier_rank TIER_NAME -> integer rank (0..3) on stdout, "" on unknown.
uberdev_tier_rank() {
  case "$1" in
    trivial) printf '0' ;;
    small)   printf '1' ;;
    medium)  printf '2' ;;
    large)   printf '3' ;;
    *)       printf '' ;;
  esac
}

# uberdev_tier_name RANK -> tier name on stdout, "" on out-of-domain rank.
uberdev_tier_name() {
  case "$1" in
    0) printf 'trivial' ;;
    1) printf 'small' ;;
    2) printf 'medium' ;;
    3) printf 'large' ;;
    *) printf '' ;;
  esac
}

# uberdev_clamp_tier TIER FLOOR CEILING
# Clamp TIER into [FLOOR, CEILING]. Unset floor/ceiling => unbounded that side.
# If FLOOR_RANK > CEILING_RANK, warn under floor_gt_ceiling and ignore both
# (return TIER unchanged).
uberdev_clamp_tier() {
  local tier="$1" floor="$2" ceiling="$3"
  local tr fr cr
  tr="$(uberdev_tier_rank "$tier")"
  fr="$(uberdev_tier_rank "$floor")"
  cr="$(uberdev_tier_rank "$ceiling")"
  # Unknown input tier: pass through unchanged.
  [ -n "$tr" ] || { printf '%s' "$tier"; return 0; }
  # Both floor and ceiling set and inverted -> warn-once and pass through.
  if [ -n "$fr" ] && [ -n "$cr" ] && [ "$fr" -gt "$cr" ]; then
    _uberdev_warn_invalid "solve_tier_floor_vs_ceiling" "${floor}>${ceiling}" floor_gt_ceiling "(none)"
    printf '%s' "$tier"
    return 0
  fi
  # Apply floor.
  if [ -n "$fr" ] && [ "$tr" -lt "$fr" ]; then
    printf '%s' "$(uberdev_tier_name "$fr")"
    return 0
  fi
  # Apply ceiling.
  if [ -n "$cr" ] && [ "$tr" -gt "$cr" ]; then
    printf '%s' "$(uberdev_tier_name "$cr")"
    return 0
  fi
  printf '%s' "$tier"
}

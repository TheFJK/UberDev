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
#   uberdev_emit_workflow_args PIPELINE [KEY=VALUE ...]
#                              -> v1 Workflow args envelope between
#                                 WORKFLOW_ARGS_BEGIN/END markers (RFC 0012 §4.3)
#
# Sourced by:
#   - launcher script written by skills/solve-pipeline/SKILL.md (/tmp/solve-$N.sh)
#   - tests/config-override.test.sh
#   - tests/workflow-args.test.sh
#   - migrated-pipeline thin preflights (RFC 0012 DR-2)
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
  # Native bash `[[ =~ ]]` (POSIX ERE; supported by bash 3.2 and zsh 5.x) avoids
  # the printf+pipe+grep fork triple, ~2ms saved per call. Pattern is a literal,
  # so unquoted right-hand side is safe under bash 3.2's compat31-default.
  if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
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
  # Native bash `[[ =~ ]]` (POSIX ERE; supported by bash 3.2 and zsh 5.x) avoids
  # the printf+pipe+grep fork triple, ~2ms saved per call. The `$regex` RHS is
  # intentionally unquoted: bash treats a quoted RHS as a literal string, an
  # unquoted variable RHS as an ERE pattern (compat31-default behaviour).
  if [[ "$val" =~ $regex ]]; then
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

# uberdev_emit_workflow_args PIPELINE [KEY=VALUE ...]
# RFC 0012 §4.3 (infra-R7): assemble and print the VERSIONED Workflow args
# envelope between WORKFLOW_ARGS_BEGIN / WORKFLOW_ARGS_END marker lines, for
# verbatim relay into the skill-mandated Workflow({scriptPath: ...}, args)
# call (DR-2: the model relays the JSON between the markers verbatim — no
# LLM-composed handoffs).
#
# Envelope (v1), one compact-JSON line:
#   { "v": 1, "run_id": "...", "now_epoch": <int>, "now_iso": "...",
#     "plugin_root": "<abs>", "repo_root": "<abs>", "cwd": "<abs>",
#     "pipeline": "<name>", "config": { ... } }
#
# KEY=VALUE handling:
#   - overridable top-level keys: run_id, plugin_root, repo_root, cwd
#     (defaults: minted run_id / $CLAUDE_PLUGIN_ROOT / git toplevel / $PWD);
#   - locked keys (v, now_epoch, now_iso, pipeline, config) are REJECTED —
#     fail loud, never silently shadow the envelope skeleton;
#   - every other KEY lands under .config — KEY may be dotted (e.g.
#     fanout_concurrency.solve_bg), stored as a literal JSON key;
#   - VALUES are expected to be ALREADY RESOLVED by the caller via the
#     uberdev_read_int_in_range/enum/string helpers above. The env >
#     uberdev.local.md > default precedence, the warn-once sentinels and
#     the audit rows all live in THOSE helpers and are untouched here;
#   - integer-shaped values (no leading zeros) and bare true/false are
#     emitted as JSON numbers/booleans; everything else is a JSON string.
#
# FROZEN-TIME CONTRACT (RFC 0012 DR-7): now_epoch / now_iso freeze HERE, at
# preflight emission, and never advance for the life of the workflow run —
# the Workflow runtime forbids Date.now() / Math.random() / argless
# new Date() inside scripts (resume determinism), so scripts read time ONLY
# from these args. Any wall-clock gate evaluated MID-run (CI settle windows,
# grace timers, stuck detection) must take live time from agent-side `date`,
# NEVER from these frozen values. They are deliberately not overridable.
#
# SECURITY — constant-name discipline preserved: the read helpers above
# expand only CONSTANT env NAMES chosen by repo code (the four printf-based
# indirect-expansion sites in _uberdev_is_validated / uberdev_read_*).
# This emitter extends that property by never expanding anything as code:
# caller-supplied KEYs and VALUEs travel exclusively through `jq --arg` /
# `--argjson` (data, not code), and KEYs are allow-list validated before
# use. Values are never interpolated into shell words or jq programs.
#
# Requires jq (hard dependency for migrated preflights per RFC 0012 §4.3;
# the session-start hook already warns loudly when jq is missing, and the
# §4.2 No-Workflow fallback covers jq-less hosts).
# Returns 0 + envelope on stdout; 2 + one stderr line on any usage error.
uberdev_emit_workflow_args() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    echo "uberdev_emit_workflow_args: missing PIPELINE argument" >&2
    return 2
  fi
  local pipeline="$1"
  shift
  case "$pipeline" in
    *[!A-Za-z0-9._-]*)
      echo "uberdev_emit_workflow_args: invalid PIPELINE '$pipeline' (allowed: A-Za-z0-9._-)" >&2
      return 2
      ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    echo "uberdev_emit_workflow_args: jq is required (RFC 0012 §4.3) but not on PATH" >&2
    return 2
  fi

  local now_epoch now_iso
  now_epoch="$(date -u +%s)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$now_epoch" in
    ''|*[!0-9]*)
      echo "uberdev_emit_workflow_args: date -u +%s returned non-integer '$now_epoch'" >&2
      return 2
      ;;
  esac

  # Defaults for the overridable top-level keys. run_id shape matches the
  # established RUN_ID convention (^[0-9]{8}-[0-9]{6}-[a-f0-9]+$); callers
  # with their own minted RUN_ID pass run_id=... to override.
  local run_id plugin_root repo_root cwd
  run_id="$(date -u +%Y%m%d-%H%M%S)-$(printf '%04x%04x' "$$" "$RANDOM")"
  plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  [ -n "$repo_root" ] || repo_root="$PWD"
  cwd="$PWD"

  # First pass: pull out top-level overrides, validate every KEY, and
  # hard-reject locked keys. Second pass below folds the rest into .config.
  local kv k v
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *)
        echo "uberdev_emit_workflow_args: argument '$kv' is not KEY=VALUE" >&2
        return 2
        ;;
    esac
    k="${kv%%=*}"
    v="${kv#*=}"
    if [ -z "$k" ]; then
      echo "uberdev_emit_workflow_args: empty KEY in '$kv'" >&2
      return 2
    fi
    case "$k" in
      *[!A-Za-z0-9._-]*)
        echo "uberdev_emit_workflow_args: invalid KEY '$k' (allowed: A-Za-z0-9._-)" >&2
        return 2
        ;;
    esac
    case "$k" in
      v|now_epoch|now_iso|pipeline|config)
        echo "uberdev_emit_workflow_args: KEY '$k' is locked (envelope skeleton; now_* are frozen per DR-7)" >&2
        return 2
        ;;
      run_id)      run_id="$v" ;;
      plugin_root) plugin_root="$v" ;;
      repo_root)   repo_root="$v" ;;
      cwd)         cwd="$v" ;;
    esac
  done

  local envelope
  envelope="$(jq -nc \
    --arg pipeline "$pipeline" \
    --argjson now_epoch "$now_epoch" \
    --arg now_iso "$now_iso" \
    --arg run_id "$run_id" \
    --arg plugin_root "$plugin_root" \
    --arg repo_root "$repo_root" \
    --arg cwd "$cwd" \
    '{v: 1, run_id: $run_id, now_epoch: $now_epoch, now_iso: $now_iso,
      plugin_root: $plugin_root, repo_root: $repo_root, cwd: $cwd,
      pipeline: $pipeline, config: {}}')" || {
    echo "uberdev_emit_workflow_args: jq failed to assemble the envelope skeleton" >&2
    return 2
  }

  # Fold config entries in. Auto-typing keeps resolved ints/bools usable as
  # JSON numbers/booleans inside scripts; the regex rejects leading zeros so
  # values like "007" stay strings instead of shifting magnitude.
  local int_re='^(0|-?[1-9][0-9]*)$'
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      run_id|plugin_root|repo_root|cwd) continue ;;
    esac
    if [[ "$v" =~ $int_re ]]; then
      envelope="$(printf '%s' "$envelope" | jq -c --arg k "$k" --argjson tv "$v" '.config[$k] = $tv')"
    elif [ "$v" = "true" ] || [ "$v" = "false" ]; then
      envelope="$(printf '%s' "$envelope" | jq -c --arg k "$k" --argjson tv "$v" '.config[$k] = $tv')"
    else
      envelope="$(printf '%s' "$envelope" | jq -c --arg k "$k" --arg tv "$v" '.config[$k] = $tv')"
    fi
    if [ -z "$envelope" ]; then
      echo "uberdev_emit_workflow_args: jq failed while adding config key '$k'" >&2
      return 2
    fi
  done

  printf 'WORKFLOW_ARGS_BEGIN\n%s\nWORKFLOW_ARGS_END\n' "$envelope"
}

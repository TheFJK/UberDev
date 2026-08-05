# plugins/uberdev/lib/config-read.sh
#
# Shared library for reading + validating the new optional config keys
# under .claude/uberdev.local.md (Claude) or .codex/uberdev.local.md (Codex).
# SOURCED, never executed.
# No shebang (sourced only); .sh extension (convention).
#
# Public surface (functions):
#   uberdev_read_int_in_range  KEY ENV_VAR MIN MAX DEFAULT
#   uberdev_read_enum          KEY ENV_VAR ALLOWED_PIPE_LIST DEFAULT
#   uberdev_read_string        KEY ENV_VAR REGEX DEFAULT
#   uberdev_read_model_routing
#                              -> exports validated RFC 0013 routing config
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

# Preserve a caller-selected file as a sole-file override. Otherwise retain a
# compatibility value in UBERDEV_CONFIG_FILE for legacy direct consumers while
# the public readers below resolve each key across Codex then Claude.
if [ -n "${UBERDEV_CONFIG_FILE:-}" ]; then
  _UBERDEV_CONFIG_FILE_EXPLICIT=1
  _UBERDEV_CONFIG_FILE_DEFAULT=""
else
  _UBERDEV_CONFIG_FILE_EXPLICIT=0
  if [ -r "${PWD}/.codex/uberdev.local.md" ]; then
    UBERDEV_CONFIG_FILE="${PWD}/.codex/uberdev.local.md"
  elif [ -r "${PWD}/.claude/uberdev.local.md" ]; then
    UBERDEV_CONFIG_FILE="${PWD}/.claude/uberdev.local.md"
  elif [ -n "${CODEX_HOME:-}" ]; then
    UBERDEV_CONFIG_FILE="${PWD}/.codex/uberdev.local.md"
  else
    UBERDEV_CONFIG_FILE="${PWD}/.claude/uberdev.local.md"
  fi
  _UBERDEV_CONFIG_FILE_DEFAULT="$UBERDEV_CONFIG_FILE"
fi

if [ -n "${BASH_VERSION:-}" ]; then
  _UBERDEV_CONFIG_READ_SOURCE="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  # `%x` is zsh's source-file identity. Keep the zsh-only expansion inside a
  # constant eval so Bash 3.2 never parses it as a parameter expansion.
  eval '_UBERDEV_CONFIG_READ_SOURCE="${(%):-%x}"'
else
  _UBERDEV_CONFIG_READ_SOURCE=""
fi
_UBERDEV_CONFIG_READ_FILE=""
_UBERDEV_CONFIG_READ_DIR=""
if [ -n "$_UBERDEV_CONFIG_READ_SOURCE" ]; then
  case "$_UBERDEV_CONFIG_READ_SOURCE" in
    /*) _UBERDEV_CONFIG_READ_CANDIDATE="$_UBERDEV_CONFIG_READ_SOURCE" ;;
    *) _UBERDEV_CONFIG_READ_CANDIDATE="${PWD}/$_UBERDEV_CONFIG_READ_SOURCE" ;;
  esac
  if [ -f "$_UBERDEV_CONFIG_READ_CANDIDATE" ] \
    && [ -r "$_UBERDEV_CONFIG_READ_CANDIDATE" ] \
    && [ ! -L "$_UBERDEV_CONFIG_READ_CANDIDATE" ] \
    && [ "$(basename "$_UBERDEV_CONFIG_READ_CANDIDATE")" = "config-read.sh" ]; then
    _UBERDEV_CONFIG_READ_DIR="$(cd "$(dirname "$_UBERDEV_CONFIG_READ_CANDIDATE")" 2>/dev/null && pwd -P)"
    if [ -n "$_UBERDEV_CONFIG_READ_DIR" ]; then
      _UBERDEV_CONFIG_READ_FILE="${_UBERDEV_CONFIG_READ_DIR}/config-read.sh"
    fi
  fi
fi

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
      raw="$(_uberdev_frontmatter_body "$file" | awk -v p="^${parent}:" -v l="^[[:space:]]+${leaf}:" '
        $0 ~ p { in_block=1; next }
        in_block && /^[A-Za-z_]/ { in_block=0 }
        in_block && $0 ~ l { sub(/^[[:space:]]+[^:]+:[[:space:]]*/, ""); print; exit }
      ')"
      ;;
    *)
      raw="$(_uberdev_frontmatter_body "$file" \
        | grep -E "^${key_path}:" 2>/dev/null \
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

# _uberdev_frontmatter_body FILE
# Emit only the first YAML frontmatter body when the first non-empty line is
# `---`; otherwise emit the complete delimiter-free legacy document. Structural
# delimiter validation remains in the isolated routing-map parser.
_uberdev_frontmatter_body() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    !started {
      if ($0 ~ /^[[:space:]]*$/) { next }
      started=1
      if ($0 ~ /^---\r?$/) { frontmatter=1; next }
    }
    frontmatter && $0 ~ /^---\r?$/ { exit }
    { print }
  ' "$file"
}

# _uberdev_has_nested KEY_PATH FILE
# Exit 0 when the exact scalar/map key exists, even when its value is empty.
_uberdev_has_nested() {
  local key_path="$1" file="$2" parent leaf
  [ -f "$file" ] || return 1
  case "$key_path" in
    *.*)
      parent="${key_path%%.*}"
      leaf="${key_path#*.}"
      _uberdev_frontmatter_body "$file" | awk -v p="^${parent}:" -v l="^[[:space:]]+${leaf}:" '
        $0 ~ p { in_block=1; next }
        in_block && /^[A-Za-z_]/ { in_block=0 }
        in_block && $0 ~ l { found=1; exit }
        END { exit(found ? 0 : 1) }
      '
      ;;
    *)
      _uberdev_frontmatter_body "$file" | awk -v k="^${key_path}:" '
        $0 ~ k { found=1 }
        END { exit(found ? 0 : 1) }
      '
      ;;
  esac
}

# _uberdev_config_file_for_key KEY
# Explicit UBERDEV_CONFIG_FILE is the sole file. Otherwise choose per key:
# readable .codex value, then readable .claude value, then no file/default.
_uberdev_config_file_for_key() {
  local key="$1" candidate
  if [ -n "${UBERDEV_CONFIG_FILE:-}" ] && { \
    [ "${_UBERDEV_CONFIG_FILE_EXPLICIT:-0}" = "1" ] \
      || [ "${UBERDEV_CONFIG_FILE}" != "${_UBERDEV_CONFIG_FILE_DEFAULT:-}" ]; \
  }; then
    printf '%s' "${UBERDEV_CONFIG_FILE:-}"
    return 0
  fi
  for candidate in "${PWD}/.codex/uberdev.local.md" "${PWD}/.claude/uberdev.local.md"; do
    if [ -r "$candidate" ] && _uberdev_has_nested "$key" "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# _uberdev_read_project_key KEY
# Print the selected per-key project value, or empty when no file defines it.
_uberdev_read_project_key() {
  local key="$1" file
  if file="$(_uberdev_config_file_for_key "$key")"; then
    _uberdev_read_nested "$key" "$file"
  fi
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
    source='env'
  else
    # Tier 2: config file.
    val="$(_uberdev_read_project_key "$key")"
    source='file'
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
    val="$(_uberdev_read_project_key "$key")"
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
    val="$(_uberdev_read_project_key "$key")"
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

# _uberdev_parse_routing_map SCOPE SOURCE PAYLOAD
#
# Normalize a role/workflow override map into compact JSON. SOURCE is `env`
# (PAYLOAD is strict JSON) or `file` (PAYLOAD is the selected config path).
# The parser is deliberately data-only: it never evaluates map keys or values,
# rejects duplicate keys, and applies closed shape/count/size bounds before the
# JSON is handed to model_routing.py.
_uberdev_parse_routing_map() {
  local scope="$1" source="$2" payload="$3" policy_file="$4" routing_lib="$5"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  if [ "$source" = "env" ] && [ "${#payload}" -gt 16384 ]; then
    return 1
  fi
  python3 -I -c '
import json
import importlib.util
import re
import sys

scope, source, payload, policy_path, routing_lib = sys.argv[1:]
MAX_BYTES = 16384
MAX_ENTRIES = 64
KEY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
SANDBOXES = {"read-only", "workspace-write"}
WORKFLOWS = {"solve", "turbo"}

class Invalid(Exception):
    pass

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid("duplicate key")
        result[key] = value
    return result

def strict_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=unique)
    except (ValueError, TypeError) as exc:
        raise Invalid("invalid JSON") from exc

def policy_data(path, validator_path):
    try:
        spec = importlib.util.spec_from_file_location("_uberdev_model_routing_validator", validator_path)
        if spec is None or spec.loader is None:
            raise Invalid("validator unavailable")
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        policy = validator.load_policy(path)
        # Public API call deliberately exercises T40-1s complete policy
        # validator without requiring a provider/model invocation.
        validator.classify_minimum_route(
            policy,
            {"task_tier": "small", "risk_signals": [], "role": "lead"},
        )
    except BaseException as exc:
        raise Invalid("invalid canonical policy") from exc
    routes = policy["routes"]
    aliases = policy["aliases"]
    roles = policy["roles"]
    route_names = set(routes)
    # Reads the declared vocabulary rather than scraping it out of per-route
    # provider blocks, which no longer exist (#381). The accepted token set is
    # unchanged; only its source moved from derived to declared.
    efforts = set(policy["reasoning_efforts"])
    return route_names | set(aliases), set(roles), efforts

def scalar(raw):
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("\"", chr(39)):
        value = value[1:-1]
    if not value or any(char.isspace() for char in value):
        raise Invalid("invalid scalar")
    return value

def config_document(raw):
    lines = raw.splitlines(keepends=True)
    delimiters = [
        index for index, line in enumerate(lines)
        if line.rstrip("\r\n") == "---"
    ]
    if not delimiters:
        return raw
    first_nonempty = next(
        (index for index, line in enumerate(lines) if line.strip()),
        None,
    )
    if first_nonempty is None or delimiters[0] != first_nonempty or len(delimiters) != 2:
        raise Invalid("invalid frontmatter delimiters")
    return "".join(lines[delimiters[0] + 1:delimiters[1]])

def yaml_map(raw, wanted):
    if "\t" in raw:
        raise Invalid("tabs are not accepted")
    lines = raw.splitlines()
    model_headers = [i for i, line in enumerate(lines) if re.match(r"^model_routing:[ ]*(?:#.*)?$", line)]
    if not model_headers:
        return None
    if len(model_headers) != 1:
        raise Invalid("duplicate model_routing")
    start = model_headers[0] + 1
    end = len(lines)
    for i in range(start, len(lines)):
        line = lines[i]
        if line.strip() and not line.startswith((" ", "#")):
            end = i
            break
    headers = []
    header_value = ""
    for i in range(start, end):
        clean = lines[i].split("#", 1)[0].rstrip()
        match = re.fullmatch(r"  ([A-Za-z_][A-Za-z0-9_]*):(?:[ ]*(.*))?", clean)
        if match and match.group(1) == wanted:
            headers.append(i)
            header_value = (match.group(2) or "").strip()
    if not headers:
        return None
    if len(headers) != 1:
        raise Invalid("duplicate scope")
    if header_value:
        value = strict_json(header_value)
        return value

    block_start = headers[0] + 1
    block_end = end
    for i in range(block_start, end):
        clean = lines[i].split("#", 1)[0].rstrip()
        if clean and len(clean) - len(clean.lstrip(" ")) <= 2:
            block_end = i
            break
    block_raw = "\n".join(lines[headers[0]:block_end])
    if len(block_raw.encode("utf-8")) > MAX_BYTES:
        raise Invalid("map too large")
    result = {}
    i = block_start
    while i < block_end:
        clean = lines[i].split("#", 1)[0].rstrip()
        i += 1
        if not clean.strip():
            continue
        match = re.fullmatch(r"    ([A-Za-z0-9][A-Za-z0-9._-]{0,127}):(?:[ ]*(.*))?", clean)
        if not match:
            raise Invalid("invalid entry")
        key, rest = match.group(1), (match.group(2) or "").strip()
        if key in result:
            raise Invalid("duplicate key")
        if rest:
            result[key] = strict_json(rest) if rest.startswith("{") else scalar(rest)
            continue
        fields = {}
        while i < block_end:
            child = lines[i].split("#", 1)[0].rstrip()
            if not child.strip():
                i += 1
                continue
            indent = len(child) - len(child.lstrip(" "))
            if indent <= 4:
                break
            child_match = re.fullmatch(r"      ([A-Za-z_][A-Za-z0-9_]*):[ ]*(.*)", child)
            if not child_match:
                raise Invalid("invalid nested entry")
            field, value = child_match.group(1), scalar(child_match.group(2))
            if field in fields:
                raise Invalid("duplicate nested key")
            fields[field] = value
            i += 1
        if not fields:
            raise Invalid("empty entry")
        result[key] = fields
    return result

def validate(value, routes, roles, efforts):
    if not isinstance(value, dict) or len(value) > MAX_ENTRIES:
        raise Invalid("invalid map/count")
    for key, entry in value.items():
        if not isinstance(key, str) or not KEY_RE.fullmatch(key) or ".." in key:
            raise Invalid("invalid key")
        if scope == "roles" and key not in roles:
            raise Invalid("unknown role")
        if scope == "workflows" and key not in WORKFLOWS:
            raise Invalid("unknown workflow")
        if isinstance(entry, str):
            if entry not in routes:
                raise Invalid("invalid route")
            continue
        if not isinstance(entry, dict) or not entry or not set(entry).issubset({"route", "sandbox", "effort", "reasoning_effort"}):
            raise Invalid("invalid override shape")
        if "effort" in entry and "reasoning_effort" in entry:
            raise Invalid("duplicate effort aliases")
        if "effort" in entry:
            entry["reasoning_effort"] = entry.pop("effort")
        if "route" in entry and "reasoning_effort" in entry:
            raise Invalid("route/effort conflict")
        if "route" in entry and entry["route"] not in routes:
            raise Invalid("invalid route")
        if "sandbox" in entry and entry["sandbox"] not in SANDBOXES:
            raise Invalid("invalid sandbox")
        if "reasoning_effort" in entry and entry["reasoning_effort"] not in efforts:
            raise Invalid("invalid effort")
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > MAX_BYTES:
        raise Invalid("map too large")
    return encoded

try:
    routes, roles, efforts = policy_data(policy_path, routing_lib)
    if source == "env":
        value = strict_json(payload)
    elif source == "file":
        try:
            with open(payload, "r", encoding="utf-8") as handle:
                raw = handle.read(1048577)
        except FileNotFoundError:
            raw = ""
        if len(raw.encode("utf-8")) > 1048576:
            raise Invalid("config too large")
        value = yaml_map(config_document(raw), scope)
    else:
        raise Invalid("invalid source")
    if value is None:
        sys.exit(3)
    print(validate(value, routes, roles, efforts), end="")
except (Invalid, OSError, UnicodeError):
    sys.exit(1)
' "$scope" "$source" "$payload" "$policy_file" "$routing_lib"
}

# _uberdev_routing_policy_file
# Resolve the canonical policy explicitly, then through source/install/repo
# locations. An explicit unreadable path fails closed and never falls through.
_uberdev_routing_policy_file() {
  local candidate
  if [ -n "${UBERDEV_ROUTING_POLICY_FILE:-}" ]; then
    [ -r "$UBERDEV_ROUTING_POLICY_FILE" ] || return 1
    printf '%s' "$UBERDEV_ROUTING_POLICY_FILE"
    return 0
  fi
  candidate="${_UBERDEV_CONFIG_READ_DIR}/../policy/model-routing-v1.json"
  if [ -n "$_UBERDEV_CONFIG_READ_DIR" ] && [ -r "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    candidate="${CLAUDE_PLUGIN_ROOT}/policy/model-routing-v1.json"
    if [ -r "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  if [ -n "${CODEX_HOME:-}" ]; then
    candidate="${CODEX_HOME}/plugins/uberdev-codex/policy/model-routing-v1.json"
    if [ -r "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  # In-repo development fallback. The second candidate was
  # ${PWD}/codex/uberdev-codex/policy/model-routing-v1.json until issue #381
  # deleted that tree; it is unreachable, not merely unused. The CODEX_HOME
  # branch above is a different thing and stays — it resolves an INSTALLED
  # Codex runtime: `.codex/uberdev.local.md` is still a supported project
  # config family (`project-codex` provenance), independent of the deleted
  # `codex` dispatch backend.
  candidate="${PWD}/plugins/uberdev/policy/model-routing-v1.json"
  if [ -r "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# _uberdev_normalize_trusted_file PATH
# Resolve a regular non-symlink file to an absolute path. Used only to compare
# the validator against a fixed allowlist; arbitrary paths are never imported.
_uberdev_normalize_trusted_file() {
  local file_path="$1" dir base
  case "$file_path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -f "$file_path" ] && [ -r "$file_path" ] && [ ! -L "$file_path" ] || return 1
  dir="$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$file_path")"
  [ "$base" = "model_routing.py" ] || return 1
  printf '%s/%s' "$dir" "$base"
}

# _uberdev_model_routing_lib_file
# Resolve T40-1s canonical complete validator. UBERDEV_MODEL_ROUTING_LIB is a
# test/embedding selector, not a general import path: it must exactly match one
# trusted source/install/repo candidate after normalization.
_uberdev_model_routing_lib_file() {
  local requested="${UBERDEV_MODEL_ROUTING_LIB:-}" sibling normalized_sibling normalized_requested
  [ -n "${_UBERDEV_CONFIG_READ_FILE:-}" ] && [ -n "${_UBERDEV_CONFIG_READ_DIR:-}" ] || return 1
  sibling="${_UBERDEV_CONFIG_READ_DIR}/model_routing.py"
  normalized_sibling="$(_uberdev_normalize_trusted_file "$sibling")" || return 1
  if [ -z "$requested" ]; then
    printf '%s' "$normalized_sibling"
    return 0
  fi
  normalized_requested="$(_uberdev_normalize_trusted_file "$requested")" || return 1
  [ "$normalized_requested" = "$normalized_sibling" ] || return 1
  printf '%s' "$normalized_sibling"
}

# _uberdev_read_routing_map KEY ENV_VAR SCOPE
# Returns normalized compact JSON or `{}` after one existing-format warning.
_uberdev_read_routing_map() {
  local key="$1" env_var="$2" scope="$3"
  local raw source payload parsed policy_file routing_lib parse_status file
  raw="$(printenv "$env_var" 2>/dev/null || true)"
  if [ -n "$raw" ]; then
    source='env'
    payload="$raw"
  else
    source='file'
    if file="$(_uberdev_config_file_for_key "$key")"; then
      payload="$file"
    else
      _uberdev_set_validated "$key"
      printf '{}'
      return 0
    fi
  fi
  if ! policy_file="$(_uberdev_routing_policy_file)"; then
    _uberdev_warn_invalid "$key" "<invalid-map>" invalid_map "{}"
    _uberdev_set_validated "$key"
    printf '{}'
    return 0
  fi
  if ! routing_lib="$(_uberdev_model_routing_lib_file)"; then
    _uberdev_warn_invalid "$key" "<invalid-map>" invalid_map "{}"
    _uberdev_set_validated "$key"
    printf '{}'
    return 0
  fi
  if parsed="$(_uberdev_parse_routing_map "$scope" "$source" "$payload" "$policy_file" "$routing_lib")"; then
    _uberdev_set_validated "$key"
    printf '%s' "$parsed"
    return 0
  else
    parse_status=$?
  fi
  if [ "$parse_status" -eq 3 ]; then
    _uberdev_set_validated "$key"
    printf '{}'
    return 0
  fi
  _uberdev_warn_invalid "$key" "<invalid-map>" invalid_map "{}"
  _uberdev_set_validated "$key"
  printf '{}'
}

# uberdev_read_model_routing
# Resolve and export the v0.40 routing configuration. Input environment names
# intentionally differ from resolved output names so repeated reads cannot
# self-shadow a later caller-provided override. Role/workflow maps are compact
# JSON data for model_routing.py; no map content is evaluated by the shell.
uberdev_read_model_routing() {
  UBERDEV_ROUTING_MODE="$(uberdev_read_enum model_routing.mode UBERDEV_MODEL_ROUTING_MODE 'adaptive|inherit' 'inherit')"
  _uberdev_set_validated model_routing.mode
  UBERDEV_ROUTING_SERVICE_TIER="$(uberdev_read_enum model_routing.service_tier UBERDEV_SERVICE_TIER 'default|fast|flex' 'default')"
  _uberdev_set_validated model_routing.service_tier
  UBERDEV_ROUTING_RISK_ESCALATION="$(uberdev_read_enum model_routing.risk_escalation UBERDEV_MODEL_ROUTING_RISK_ESCALATION 'true|false' 'true')"
  _uberdev_set_validated model_routing.risk_escalation
  UBERDEV_ROUTING_ADAPTIVE_FALLBACK="$(uberdev_read_enum model_routing.adaptive_fallback UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK 'true|false' 'true')"
  _uberdev_set_validated model_routing.adaptive_fallback
  UBERDEV_ROUTING_SHADOW="$(uberdev_read_enum model_routing.shadow UBERDEV_MODEL_ROUTING_SHADOW 'true|false' 'false')"
  _uberdev_set_validated model_routing.shadow
  UBERDEV_ROUTING_WORKFLOWS="$(_uberdev_read_routing_map model_routing.workflows UBERDEV_MODEL_ROUTING_WORKFLOWS workflows)"
  _uberdev_set_validated model_routing.workflows
  UBERDEV_ROUTING_ROLES="$(_uberdev_read_routing_map model_routing.roles UBERDEV_MODEL_ROUTING_ROLES roles)"
  _uberdev_set_validated model_routing.roles
  export UBERDEV_ROUTING_MODE UBERDEV_ROUTING_SERVICE_TIER
  export UBERDEV_ROUTING_RISK_ESCALATION UBERDEV_ROUTING_ADAPTIVE_FALLBACK
  export UBERDEV_ROUTING_SHADOW UBERDEV_ROUTING_WORKFLOWS UBERDEV_ROUTING_ROLES
  local p_mode p_service p_risk p_fallback p_shadow p_workflows p_roles
  p_mode="$(_uberdev_routing_source model_routing.mode "${UBERDEV_MODEL_ROUTING_MODE:-}" "$UBERDEV_ROUTING_MODE" inherit)"
  p_service="$(_uberdev_routing_source model_routing.service_tier "${UBERDEV_SERVICE_TIER:-}" "$UBERDEV_ROUTING_SERVICE_TIER" default)"
  p_risk="$(_uberdev_routing_source model_routing.risk_escalation "${UBERDEV_MODEL_ROUTING_RISK_ESCALATION:-}" "$UBERDEV_ROUTING_RISK_ESCALATION" true)"
  p_fallback="$(_uberdev_routing_source model_routing.adaptive_fallback "${UBERDEV_MODEL_ROUTING_ADAPTIVE_FALLBACK:-}" "$UBERDEV_ROUTING_ADAPTIVE_FALLBACK" true)"
  p_shadow="$(_uberdev_routing_source model_routing.shadow "${UBERDEV_MODEL_ROUTING_SHADOW:-}" "$UBERDEV_ROUTING_SHADOW" false)"
  p_workflows="$(_uberdev_routing_source model_routing.workflows "${UBERDEV_MODEL_ROUTING_WORKFLOWS:-}" "$UBERDEV_ROUTING_WORKFLOWS" '{}')"
  p_roles="$(_uberdev_routing_source model_routing.roles "${UBERDEV_MODEL_ROUTING_ROLES:-}" "$UBERDEV_ROUTING_ROLES" '{}')"
  UBERDEV_ROUTING_PROVENANCE_JSON="$(python3 -I -c '
import json,sys
names=("mode","service_tier","risk_escalation","adaptive_fallback","shadow","workflows","roles")
rows={name:{"source":raw.split("\t",1)[0],"file":raw.split("\t",1)[1] or None} for name,raw in zip(names,sys.argv[1:])}
print(json.dumps(rows,sort_keys=True,separators=(",",":")),end="")
' "$p_mode" "$p_service" "$p_risk" "$p_fallback" "$p_shadow" "$p_workflows" "$p_roles")" || return 2
  export UBERDEV_ROUTING_PROVENANCE_JSON
}

_uberdev_routing_source() {
  local key="$1" env_value="$2" effective="$3" default="$4" file='' file_value='' source='default' canonical=''
  if [ -n "$env_value" ]; then
    if [ "$env_value" = "$effective" ] || [ "$effective" != "$default" ]; then source='env'; fi
  elif file="$(_uberdev_config_file_for_key "$key" 2>/dev/null)" && [ -n "$file" ]; then
    file_value="$(_uberdev_read_nested "$key" "$file")"
    if [ "$effective" != "$default" ] || { [ -n "$file_value" ] && [ "$file_value" = "$effective" ]; }; then
      if [ "${_UBERDEV_CONFIG_FILE_EXPLICIT:-0}" = 1 ] || { [ -n "${UBERDEV_CONFIG_FILE:-}" ] && [ "$UBERDEV_CONFIG_FILE" != "${_UBERDEV_CONFIG_FILE_DEFAULT:-}" ]; }; then
        source='explicit-config-file'
      else
        case "$file" in */.codex/uberdev.local.md) source='project-codex' ;; *) source='project-claude' ;; esac
      fi
      canonical="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)/$(basename "$file")"
    fi
  fi
  printf '%s\t%s' "$source" "$canonical"
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
  plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"
  if [ -z "$plugin_root" ] && [ -n "${CODEX_HOME:-}" ]; then
    plugin_root="${CODEX_HOME}/plugins/uberdev-codex"
  fi
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

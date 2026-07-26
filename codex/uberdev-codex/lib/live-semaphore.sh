#!/usr/bin/env bash
# Process-safe live-session semaphore for UberDev dispatch backends.
#
# This file is a library.  It deliberately installs no traps; callers own
# lifecycle traps because only they know when a backend session is terminal.

_uberdev_semaphore_error() {
  printf 'uberdev semaphore: %s\n' "$1" >&2
}

_uberdev_semaphore_is_positive_integer() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

_uberdev_semaphore_safe_text() {
  local sanitized
  [ -n "${1-}" ] || return 1
  sanitized="$(printf '%s' "$1" | tr -d '\r\n')"
  [ "$sanitized" = "$1" ]
}

_uberdev_semaphore_is_absolute_path() {
  case "${1-}" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;;
    *) return 1 ;;
  esac
}

_uberdev_semaphore_reject_symlinked_ancestors() {
  local path remaining current component os_name
  path="$1"
  case "$path" in
    [A-Za-z]:/*|[A-Za-z]:\\*)
      if command -v cygpath >/dev/null 2>&1; then
        path="$(cygpath -u "$path")" || return 2
      else
        _uberdev_semaphore_error 'cygpath is required for a native-Windows state path'
        return 2
      fi
      ;;
  esac
  case "$path" in
    /*) ;;
    *) return 2 ;;
  esac
  remaining="${path#/}"
  current=''
  os_name="$(uname -s 2>/dev/null || true)"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining='' ;;
    esac
    [ -n "$component" ] || continue
    [ "$component" != '..' ] || {
      _uberdev_semaphore_error 'path traversal component is forbidden'
      return 2
    }
    [ "$component" != '.' ] || continue
    current="$current/$component"
    if [ -L "$current" ]; then
      # macOS exposes these two stable platform roots as compatibility links.
      if [ "$os_name" = 'Darwin' ] && { [ "$current" = '/var' ] || [ "$current" = '/tmp' ]; }; then
        continue
      fi
      _uberdev_semaphore_error "symlinked path ancestor is forbidden: $current"
      return 2
    fi
    [ -e "$current" ] || break
  done
  return 0
}

_uberdev_semaphore_hash() {
  local raw digest
  if command -v shasum >/dev/null 2>&1; then
    raw="$(printf '%s' "$1" | shasum -a 256)" || {
      _uberdev_semaphore_error 'SHA-256 digest generation failed'
      return 2
    }
  elif command -v sha256sum >/dev/null 2>&1; then
    raw="$(printf '%s' "$1" | sha256sum)" || {
      _uberdev_semaphore_error 'SHA-256 digest generation failed'
      return 2
    }
  else
    _uberdev_semaphore_error 'SHA-256 utility is unavailable'
    return 2
  fi
  digest="${raw%%[[:space:]]*}"
  if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    _uberdev_semaphore_error 'SHA-256 utility returned a malformed digest'
    return 2
  fi
  printf '%s\n' "$digest"
}

_uberdev_semaphore_pid_live() {
  local pid
  pid="${1-}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$pid" 2>/dev/null
}

_uberdev_semaphore_process_identity() {
  local pid="${1-}" manifest_tool
  _uberdev_semaphore_is_positive_integer "$pid" || return 1
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  python3 -I -B "$manifest_tool" process-identity --pid "$pid"
}

_uberdev_semaphore_process_identity_matches() {
  local pid="${1-}" expected="${2-}" current probe_rc
  if current="$(_uberdev_semaphore_process_identity "$pid")"; then
    [ "$current" = "$expected" ]
    return $?
  else
    probe_rc=$?
  fi
  [ "$probe_rc" -ne 1 ] || return 1
  _uberdev_semaphore_error "process identity probe unavailable for pid $pid"
  return 2
}

_uberdev_semaphore_write_process_identity() {
  local mode="$1" destination="$2" manifest_tool
  command -v python3 >/dev/null 2>&1 || return 2
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  python3 -I -B "$manifest_tool" write-process-identity \
    --mode "$mode" --destination "$destination"
}

_uberdev_semaphore_capture_lease_owner() {
  local scope="$1" owner_mode="$2" probe old_umask owner identity
  if [ -n "${UBERDEV_SEMAPHORE_OWNER_PID:-}" ]; then
    owner="$UBERDEV_SEMAPHORE_OWNER_PID"
    if ! _uberdev_semaphore_is_positive_integer "$owner"; then
      _uberdev_semaphore_error 'UBERDEV_SEMAPHORE_OWNER_PID is invalid'
      return 2
    fi
    identity="$(_uberdev_semaphore_process_identity "$owner")" || {
      _uberdev_semaphore_error 'UBERDEV_SEMAPHORE_OWNER_PID is absent or its identity is unavailable'
      return 2
    }
    _UBERDEV_SEMAPHORE_LEASE_OWNER_PID="$owner"
    _UBERDEV_SEMAPHORE_LEASE_OWNER_IDENTITY="$identity"
    return 0
  fi
  old_umask="$(umask)"
  umask 077
  probe="$(mktemp "$scope/.owner-probe.XXXXXX")" || {
    umask "$old_umask"
    return 2
  }
  umask "$old_umask"
  if ! _uberdev_semaphore_write_process_identity "$owner_mode" "$probe"; then
    rm -f "$probe" 2>/dev/null || true
    return 2
  fi
  read -r owner < "$probe" || owner=''
  identity="$(sed -n '2p' "$probe" 2>/dev/null || true)"
  rm -f "$probe" 2>/dev/null || return 2
  _uberdev_semaphore_is_positive_integer "$owner" || return 2
  [ -n "$identity" ] || return 2
  _UBERDEV_SEMAPHORE_LEASE_OWNER_PID="$owner"
  _UBERDEV_SEMAPHORE_LEASE_OWNER_IDENTITY="$identity"
  return 0
}

_uberdev_semaphore_prepare_scope() {
  local state_root repo_id backend identity scope_hash version_root scope old_umask
  state_root="${1-}"
  repo_id="${2-}"
  backend="${3-}"

  _uberdev_semaphore_is_absolute_path "$state_root" || {
    _uberdev_semaphore_error 'STATE_ROOT must be absolute'; return 2
  }
  case "$state_root" in
    /|[A-Za-z]:|[A-Za-z]:/|[A-Za-z]:\\)
      _uberdev_semaphore_error 'STATE_ROOT cannot be filesystem root'
      return 2
      ;;
  esac
  _uberdev_semaphore_reject_symlinked_ancestors "$state_root" || return 2
  _uberdev_semaphore_safe_text "$repo_id" || {
    _uberdev_semaphore_error 'REPO_ID must be non-empty single-line text'
    return 2
  }
  case "$backend" in
    ''|*[!A-Za-z0-9._-]*)
      _uberdev_semaphore_error 'BACKEND contains unsafe characters'
      return 2
      ;;
  esac
  if [ -L "$state_root" ]; then
    _uberdev_semaphore_error 'STATE_ROOT symlinks are forbidden'
    return 2
  fi
  if [ -e "$state_root" ] && [ ! -d "$state_root" ]; then
    _uberdev_semaphore_error 'STATE_ROOT must be a directory'
    return 2
  fi

  old_umask="$(umask)"
  umask 077
  if ! mkdir -p "$state_root"; then
    umask "$old_umask"
    _uberdev_semaphore_error 'cannot create STATE_ROOT'
    return 2
  fi
  _uberdev_semaphore_reject_symlinked_ancestors "$state_root" || {
    umask "$old_umask"
    return 2
  }
  version_root="$state_root/semaphore-v1"
  if [ -L "$version_root" ]; then
    umask "$old_umask"
    _uberdev_semaphore_error 'semaphore version root is a symlink'
    return 2
  fi
  if ! mkdir -p "$version_root"; then
    umask "$old_umask"
    _uberdev_semaphore_error 'cannot create semaphore version root'
    return 2
  fi
  chmod 700 "$state_root" "$version_root" 2>/dev/null || {
    umask "$old_umask"
    _uberdev_semaphore_error 'cannot make semaphore state private'
    return 2
  }

  identity="repo:${#repo_id}:$repo_id|backend:${#backend}:$backend"
  scope_hash="$(_uberdev_semaphore_hash "$identity")" || {
    umask "$old_umask"
    return 2
  }
  scope="$version_root/$scope_hash.scope"
  if [ -L "$scope" ]; then
    umask "$old_umask"
    _uberdev_semaphore_error 'semaphore scope is a symlink'
    return 2
  fi
  if [ -e "$scope" ] && [ ! -d "$scope" ]; then
    umask "$old_umask"
    _uberdev_semaphore_error 'semaphore scope must be a directory'
    return 2
  fi
  if ! mkdir -p "$scope"; then
    umask "$old_umask"
    _uberdev_semaphore_error 'cannot create semaphore scope'
    return 2
  fi
  chmod 700 "$scope" 2>/dev/null || {
    umask "$old_umask"
    _uberdev_semaphore_error 'cannot make semaphore scope private'
    return 2
  }
  umask "$old_umask"
  printf '%s\n' "$scope"
}

_uberdev_semaphore_path_identity() {
  local value
  # GNU stat interprets `-f` as filesystem-report mode and can emit a
  # colon-bearing report before rejecting the following BSD format operand.
  # Probe GNU first, fall back to BSD, and validate the complete output before
  # using it as the load-bearing mutex directory identity.
  value="$(stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null)" || return 2
  case "$value" in
    ''|*[!0-9:]*|:*|*:|*:*:*) return 2 ;;
    *:*) printf '%s\n' "$value" ;;
    *) return 2 ;;
  esac
}

_uberdev_semaphore_lease_identity() {
  local lease="$1" generation="$2" manifest_tool value
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  value="$(python3 -I -B "$manifest_tool" secure-lease-identity \
    --lease-path "$lease" --generation "$generation")" || return 2
  case "$value" in
    ''|*[!0-9:]*|:*|*:|*:*:*) return 2 ;;
    *:*) printf '%s\n' "$value" ;;
    *) return 2 ;;
  esac
}

_uberdev_semaphore_quarantine_mutex() {
  local scope="$1" expected_identity="$2" mutex token_file token quarantine actual entry
  mutex="$scope/.mutex"
  token_file="$(mktemp "$scope/.quarantine-id.XXXXXX")" || return 2
  token="$(basename "$token_file")"
  rm -f "$token_file" 2>/dev/null || return 2
  quarantine="$scope/.mutex.quarantine.$token"
  mv "$mutex" "$quarantine" 2>/dev/null || return 1
  [ ! -L "$quarantine" ] && [ -d "$quarantine" ] || return 2
  actual="$(_uberdev_semaphore_path_identity "$quarantine")" || return 2
  [ "$actual" = "$expected_identity" ] || return 2
  for entry in "$quarantine"/* "$quarantine"/.[!.]* "$quarantine"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$(basename "$entry")" = owner_pid ] && [ -f "$entry" ] && [ ! -L "$entry" ] || return 2
    rm -f "$entry" 2>/dev/null || return 2
  done
  rmdir "$quarantine" 2>/dev/null
}

_uberdev_semaphore_mutex_release() {
  local scope mutex observed_token identity
  scope="$1"
  mutex="$scope/.mutex"
  [ ! -L "$mutex" ] || return 2
  if [ ! -d "$mutex" ]; then
    [ ! -e "$mutex" ] && return 0
    return 2
  fi
  [ -f "$mutex/owner_pid" ] && [ ! -L "$mutex/owner_pid" ] || return 2
  identity="$(_uberdev_semaphore_path_identity "$mutex")" || return 2
  [ -n "${_UBERDEV_SEMAPHORE_MUTEX_IDENTITY:-}" ] \
    && [ "$identity" = "$_UBERDEV_SEMAPHORE_MUTEX_IDENTITY" ] || return 2
  observed_token="$(sed -n '3p' "$mutex/owner_pid" 2>/dev/null || true)"
  [ -n "${_UBERDEV_SEMAPHORE_MUTEX_TOKEN:-}" ] \
    && [ "$observed_token" = "$_UBERDEV_SEMAPHORE_MUTEX_TOKEN" ] || {
      _uberdev_semaphore_error 'mutex ownership changed before release'
      return 2
    }
  _uberdev_semaphore_quarantine_mutex "$scope" "$identity" || return 2
  _UBERDEV_SEMAPHORE_MUTEX_TOKEN=''
  _UBERDEV_SEMAPHORE_MUTEX_IDENTITY=''
  return 0
}

_uberdev_semaphore_mutex_reclaim_dead() {
  local scope mutex allow_reclaim owner owner_identity observed identity current_identity probe_rc
  scope="$1"
  allow_reclaim="${2:-0}"
  case "$allow_reclaim" in 0|1|published) ;; *) return 2 ;; esac
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='absent'
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_IDENTITY=''
  mutex="$scope/.mutex"
  [ -e "$mutex" ] || [ -L "$mutex" ] || return 1
  if [ -L "$mutex" ]; then
    _uberdev_semaphore_error 'unsafe mutex path'
    return 2
  fi
  if [ ! -d "$mutex" ]; then
    # The owner may have released between our failed mkdir and inspection.
    [ ! -e "$mutex" ] && return 1
    _uberdev_semaphore_error 'unsafe mutex path'
    return 2
  fi
  identity="$(_uberdev_semaphore_path_identity "$mutex")" || return 1
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_IDENTITY="$identity"
  [ ! -L "$mutex/owner_pid" ] || {
    _uberdev_semaphore_error 'unsafe mutex owner path'
    return 2
  }
  if [ ! -e "$mutex/owner_pid" ]; then
    _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='ownerless'
    [ "$allow_reclaim" = 1 ] || return 1
    if _uberdev_semaphore_quarantine_mutex "$scope" "$identity"; then
      _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='reclaimed-ownerless'
      return 0
    else
      return $?
    fi
  fi
  if [ ! -f "$mutex/owner_pid" ]; then
    # A legitimate holder may atomically quarantine this mutex while a new
    # contender creates its successor between the existence and type checks.
    # Retry only when that directory generation changed or the owner vanished;
    # a stable non-regular owner remains a fail-closed path violation.
    current_identity="$(_uberdev_semaphore_path_identity "$mutex" 2>/dev/null || true)"
    if [ -z "$current_identity" ] || [ "$current_identity" != "$identity" ] \
        || [ ! -e "$mutex/owner_pid" ]; then
      return 1
    fi
    _uberdev_semaphore_error 'unsafe mutex owner path'
    return 2
  fi
  owner="$(sed -n '1p' "$mutex/owner_pid" 2>/dev/null || true)"
  owner_identity="$(sed -n '2p' "$mutex/owner_pid" 2>/dev/null || true)"
  if ! _uberdev_semaphore_is_positive_integer "$owner"; then
    _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='invalid-owner'
    [ "$allow_reclaim" = 1 ] || return 1
    if _uberdev_semaphore_quarantine_mutex "$scope" "$identity"; then
      _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='reclaimed-invalid-owner'
      return 0
    else
      return $?
    fi
  fi
  if [ -z "$(sed -n '3p' "$mutex/owner_pid" 2>/dev/null || true)" ] \
      && printf '%s\n' "$owner_identity" | grep -Eq '^[0-9a-f]{32}$'; then
    owner_identity=''
  fi
  if [ -n "$owner_identity" ]; then
    if _uberdev_semaphore_process_identity_matches "$owner" "$owner_identity"; then
      _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='published-live'
      return 1
    else
      probe_rc=$?
      [ "$probe_rc" -ne 2 ] || return 2
    fi
  else
    if _uberdev_semaphore_pid_live "$owner"; then
      _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='published-live'
      return 1
    fi
  fi
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='published-dead'
  [ "$allow_reclaim" = 1 ] || [ "$allow_reclaim" = published ] || return 1

  # Re-read before removal so a changed owner is never reclaimed.
  observed="$(cat "$mutex/owner_pid" 2>/dev/null || true)"
  [ "$(printf '%s\n' "$observed" | sed -n '1p')" = "$owner" ] || return 1
  if [ -n "$owner_identity" ]; then
    [ "$(printf '%s\n' "$observed" | sed -n '2p')" = "$owner_identity" ] || return 1
  fi
  if _uberdev_semaphore_quarantine_mutex "$scope" "$identity"; then
    _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='reclaimed-published-dead'
    return 0
  else
    return $?
  fi
}

_uberdev_semaphore_mutex_reclaim_ownerless_generation() {
  local scope="$1" expected_identity="$2" mutex identity
  mutex="$scope/.mutex"
  [ -n "$expected_identity" ] || return 2
  [ ! -L "$mutex" ] || return 2
  [ -d "$mutex" ] || { [ ! -e "$mutex" ] && return 1; return 2; }
  identity="$(_uberdev_semaphore_path_identity "$mutex")" || {
    # The observed ownerless generation may have been released or reclaimed
    # after the directory check. Treat confirmed absence as ordinary turnover;
    # a path that still exists but cannot be identified remains fail-closed.
    [ ! -e "$mutex" ] && [ ! -L "$mutex" ] && return 1
    return 2
  }
  [ "$identity" = "$expected_identity" ] || return 1
  [ ! -L "$mutex/owner_pid" ] || return 2
  [ ! -e "$mutex/owner_pid" ] || return 1
  _uberdev_semaphore_quarantine_mutex "$scope" "$expected_identity"
}

_uberdev_semaphore_mutex_acquire() {
  local scope mutex maximum tries old_umask reclaim_rc candidate candidate_name token pause_tries
  local identity current_identity observed_token
  scope="$1"
  mutex="$scope/.mutex"
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_STATE='unknown'
  _UBERDEV_SEMAPHORE_MUTEX_OBSERVED_IDENTITY=''
  maximum="${UBERDEV_SEMAPHORE_MUTEX_MAX_TRIES:-500}"
  _uberdev_semaphore_is_positive_integer "$maximum" || maximum=500
  tries=0
  while [ "$tries" -lt "$maximum" ]; do
    old_umask="$(umask)"
    umask 077
    candidate="$(mktemp "$scope/.mutex-candidate.XXXXXX")" || {
      umask "$old_umask"
      _uberdev_semaphore_error 'cannot create mutex owner candidate'
      return 2
    }
    if ! _uberdev_semaphore_write_process_identity direct "$candidate"; then
      umask "$old_umask"
      rm -f "$candidate" 2>/dev/null || true
      _uberdev_semaphore_error 'cannot record mutex owner'
      return 2
    fi
    candidate_name="$(basename "$candidate")"
    token="$(_uberdev_semaphore_hash "mutex:${#candidate_name}:$candidate_name")" || {
      umask "$old_umask"
      rm -f "$candidate" 2>/dev/null || true
      return 2
    }
    token="$(printf '%s' "$token" | cut -c 1-32)"
    printf '%s\n' "$token" >> "$candidate" || {
      umask "$old_umask"
      rm -f "$candidate" 2>/dev/null || true
      return 2
    }
    chmod 600 "$candidate" 2>/dev/null || {
      umask "$old_umask"
      rm -f "$candidate" 2>/dev/null || true
      _uberdev_semaphore_error 'cannot protect mutex owner candidate'
      return 2
    }
    if mkdir "$mutex" 2>/dev/null; then
      identity="$(_uberdev_semaphore_path_identity "$mutex")" || {
        umask "$old_umask"
        rm -f "$candidate" 2>/dev/null || true
        continue
      }
      if [ "${UBERDEV_SEMAPHORE_TESTING:-0}" = '1' ] \
          && [ -n "${UBERDEV_SEMAPHORE_TEST_PAUSE_AFTER_MKDIR:-}" ] \
          && [ -n "${UBERDEV_SEMAPHORE_TEST_CONTINUE_FILE:-}" ]; then
        printf 'paused\n' > "$UBERDEV_SEMAPHORE_TEST_PAUSE_AFTER_MKDIR"
        pause_tries=0
        while [ ! -e "$UBERDEV_SEMAPHORE_TEST_CONTINUE_FILE" ] \
            && [ "$pause_tries" -lt 1000 ]; do
          pause_tries=$((pause_tries + 1))
          sleep 0.01
        done
      fi
      current_identity="$(_uberdev_semaphore_path_identity "$mutex" 2>/dev/null || true)"
      if [ "$current_identity" = "$identity" ] \
          && ln "$candidate" "$mutex/owner_pid" 2>/dev/null \
          && [ "$candidate" -ef "$mutex/owner_pid" ] \
          && [ "$(_uberdev_semaphore_path_identity "$mutex" 2>/dev/null || true)" = "$identity" ]; then
        rm -f "$candidate" 2>/dev/null || {
          umask "$old_umask"
          _uberdev_semaphore_error 'cannot retire mutex owner candidate'
          return 2
        }
        _UBERDEV_SEMAPHORE_MUTEX_TOKEN="$token"
        _UBERDEV_SEMAPHORE_MUTEX_IDENTITY="$identity"
        umask "$old_umask"
        return 0
      fi
      if [ -f "$mutex/owner_pid" ] && [ ! -L "$mutex/owner_pid" ]; then
        observed_token="$(sed -n '3p' "$mutex/owner_pid" 2>/dev/null || true)"
        if [ "$observed_token" = "$token" ]; then
          current_identity="$(_uberdev_semaphore_path_identity "$mutex" 2>/dev/null || true)"
          [ -z "$current_identity" ] || _uberdev_semaphore_quarantine_mutex "$scope" "$current_identity" >/dev/null 2>&1 || true
        fi
      fi
      umask "$old_umask"
      rm -f "$candidate" 2>/dev/null || true
      tries=$((tries + 1))
      [ "$tries" -ge "$maximum" ] || sleep 0.01
      continue
    fi
    umask "$old_umask"
    rm -f "$candidate" 2>/dev/null || return 2
    _uberdev_semaphore_mutex_reclaim_dead "$scope" 0
    reclaim_rc=$?
    [ "$reclaim_rc" -ne 2 ] || return 2
    if [ "$reclaim_rc" -eq 0 ]; then
      continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$maximum" ]; then
      if [ "${UBERDEV_SEMAPHORE_MUTEX_PROBE_ONLY:-0}" = 1 ]; then
        _uberdev_semaphore_mutex_reclaim_dead "$scope" published
      else
        _uberdev_semaphore_mutex_reclaim_dead "$scope" 1
      fi
      reclaim_rc=$?
      [ "$reclaim_rc" -ne 2 ] || return 2
      if [ "$reclaim_rc" -eq 0 ]; then
        tries=$((maximum - 1))
        continue
      fi
    fi
    [ "$tries" -ge "$maximum" ] || sleep 0.01
  done
  [ "${UBERDEV_SEMAPHORE_MUTEX_QUIET_BUSY:-0}" = 1 ] || \
    _uberdev_semaphore_error 'mutex retry limit exceeded'
  return 75
}

_uberdev_semaphore_validate_lease_path() {
  local lease scope scope_base version_base lease_base
  lease="${1-}"
  _uberdev_semaphore_is_absolute_path "$lease" || {
    _uberdev_semaphore_error 'LEASE_PATH must be absolute'; return 2
  }
  scope="$(dirname "$lease")"
  scope_base="$(basename "$scope")"
  version_base="$(basename "$(dirname "$scope")")"
  lease_base="$(basename "$lease")"
  printf '%s\n' "$scope_base" | grep -Eq '^[0-9a-f]{64}\.scope$' || {
    _uberdev_semaphore_error 'LEASE_PATH is outside a semaphore scope'
    return 2
  }
  [ "$version_base" = 'semaphore-v1' ] || {
    _uberdev_semaphore_error 'LEASE_PATH has the wrong state version'
    return 2
  }
  printf '%s\n' "$lease_base" | grep -Eq '^[0-9a-f]{64}\.lease$' || {
    _uberdev_semaphore_error 'LEASE_PATH has an unsafe filename'
    return 2
  }
  [ ! -L "$scope" ] && [ -d "$scope" ] || {
    _uberdev_semaphore_error 'LEASE_PATH scope is unsafe'
    return 2
  }
  if [ -L "$lease" ]; then
    _uberdev_semaphore_error 'lease symlinks are forbidden'
    return 2
  fi
  if [ -e "$lease" ] && [ ! -f "$lease" ]; then
    _uberdev_semaphore_error 'lease must be a regular file'
    return 2
  fi
  return 0
}

_uberdev_semaphore_classify_handle() {
  local handle numeric
  handle="${1-}"
  case "$handle" in
    '')
      printf '%s\n' status-only
      ;;
    pid:*)
      numeric="${handle#pid:}"
      _uberdev_semaphore_is_positive_integer "$numeric" || return 1
      printf 'pid:%s\n' "$numeric"
      ;;
    *[!0-9]*)
      _uberdev_semaphore_safe_text "$handle" || return 1
      printf '%s\n' opaque
      ;;
    *)
      _uberdev_semaphore_is_positive_integer "$handle" || return 1
      printf 'pid:%s\n' "$handle"
      ;;
  esac
}

_uberdev_semaphore_read_lease() {
  local lease line key value handle_kind
  local seen_version=0 seen_generation=0 seen_run_id=0 seen_owner_pid=0 seen_owner_identity=0
  local seen_backend_handle=0 seen_backend_identity=0 seen_start_epoch=0 seen_timeout_s=0 seen_status_path=0
  lease="$1"
  _UBERDEV_LEASE_VERSION=''
  _UBERDEV_LEASE_GENERATION=''
  _UBERDEV_LEASE_RUN_ID=''
  _UBERDEV_LEASE_OWNER_PID=''
  _UBERDEV_LEASE_OWNER_IDENTITY=''
  _UBERDEV_LEASE_BACKEND_HANDLE=''
  _UBERDEV_LEASE_BACKEND_IDENTITY=''
  _UBERDEV_LEASE_START_EPOCH=''
  _UBERDEV_LEASE_TIMEOUT_S=''
  _UBERDEV_LEASE_STATUS_PATH=''
  [ ! -L "$lease" ] && [ -f "$lease" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *) return 1 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      version)
        [ "$seen_version" -eq 0 ] || return 1
        seen_version=1; _UBERDEV_LEASE_VERSION="$value"
        ;;
      generation)
        [ "$seen_generation" -eq 0 ] || return 1
        seen_generation=1; _UBERDEV_LEASE_GENERATION="$value"
        ;;
      run_id)
        [ "$seen_run_id" -eq 0 ] || return 1
        seen_run_id=1; _UBERDEV_LEASE_RUN_ID="$value"
        ;;
      owner_pid)
        [ "$seen_owner_pid" -eq 0 ] || return 1
        seen_owner_pid=1; _UBERDEV_LEASE_OWNER_PID="$value"
        ;;
      owner_identity)
        [ "$seen_owner_identity" -eq 0 ] || return 1
        seen_owner_identity=1; _UBERDEV_LEASE_OWNER_IDENTITY="$value"
        ;;
      backend_handle)
        [ "$seen_backend_handle" -eq 0 ] || return 1
        seen_backend_handle=1; _UBERDEV_LEASE_BACKEND_HANDLE="$value"
        ;;
      backend_identity)
        [ "$seen_backend_identity" -eq 0 ] || return 1
        seen_backend_identity=1; _UBERDEV_LEASE_BACKEND_IDENTITY="$value"
        ;;
      start_epoch)
        [ "$seen_start_epoch" -eq 0 ] || return 1
        seen_start_epoch=1; _UBERDEV_LEASE_START_EPOCH="$value"
        ;;
      timeout_s)
        [ "$seen_timeout_s" -eq 0 ] || return 1
        seen_timeout_s=1; _UBERDEV_LEASE_TIMEOUT_S="$value"
        ;;
      status_path)
        [ "$seen_status_path" -eq 0 ] || return 1
        seen_status_path=1; _UBERDEV_LEASE_STATUS_PATH="$value"
        ;;
      *) return 1 ;;
    esac
  done < "$lease"
  [ "$seen_version$seen_generation$seen_run_id$seen_owner_pid$seen_backend_handle$seen_start_epoch$seen_timeout_s$seen_status_path" = '11111111' ] || return 1
  [ "$seen_owner_identity" -eq "$seen_backend_identity" ] || return 1
  [ "$_UBERDEV_LEASE_VERSION" = '1' ] || return 1
  printf '%s\n' "$_UBERDEV_LEASE_GENERATION" | grep -Eq '^[0-9a-f]{32}$' || return 1
  case "$(basename "$lease")" in
    "$_UBERDEV_LEASE_GENERATION"*.lease) ;;
    *) return 1 ;;
  esac
  _uberdev_semaphore_safe_text "$_UBERDEV_LEASE_RUN_ID" || return 1
  _uberdev_semaphore_is_positive_integer "$_UBERDEV_LEASE_OWNER_PID" || return 1
  if [ -n "$_UBERDEV_LEASE_OWNER_IDENTITY" ]; then
    printf '%s\n' "$_UBERDEV_LEASE_OWNER_IDENTITY" \
      | grep -Eq '^[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}$' || return 1
    [ "${_UBERDEV_LEASE_OWNER_IDENTITY%%|*}" = "$_UBERDEV_LEASE_OWNER_PID" ] || return 1
  fi
  _uberdev_semaphore_is_positive_integer "$_UBERDEV_LEASE_START_EPOCH" || return 1
  _uberdev_semaphore_is_positive_integer "$_UBERDEV_LEASE_TIMEOUT_S" || return 1
  handle_kind="$(_uberdev_semaphore_classify_handle "$_UBERDEV_LEASE_BACKEND_HANDLE")" || return 1
  if [ -n "$_UBERDEV_LEASE_BACKEND_IDENTITY" ]; then
    printf '%s\n' "$_UBERDEV_LEASE_BACKEND_IDENTITY" \
      | grep -Eq '^[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}$' || return 1
    [ "$handle_kind" != status-only ] && [ "$handle_kind" != opaque ] || return 1
    [ "${_UBERDEV_LEASE_BACKEND_IDENTITY%%|*}" = "${handle_kind#pid:}" ] || return 1
  fi
  if [ -n "$_UBERDEV_LEASE_STATUS_PATH" ]; then
    _uberdev_semaphore_safe_text "$_UBERDEV_LEASE_STATUS_PATH" || return 1
    _uberdev_semaphore_is_absolute_path "$_UBERDEV_LEASE_STATUS_PATH" || return 1
  fi
  [ "$handle_kind" != opaque ] || [ -n "$_UBERDEV_LEASE_STATUS_PATH" ] || return 1
  return 0
}

_uberdev_semaphore_manifest_tool() {
  local library_dir
  library_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
  printf '%s\n' "$library_dir/run_manifest.py"
}

_uberdev_semaphore_status_kind() {
  local status_path manifest_tool output
  status_path="${1-}"
  [ -n "$status_path" ] || { printf '%s\n' unknown; return 0; }
  command -v python3 >/dev/null 2>&1 || return 2
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  output="$(python3 "$manifest_tool" probe-status --status-path "$status_path" 2>/dev/null)" || {
    _uberdev_semaphore_error 'backend status is malformed, ambiguous, or unsafe'
    return 2
  }
  case "$output" in
    live|terminal|unknown) printf '%s\n' "$output" ;;
    *) _uberdev_semaphore_error 'backend status probe returned an invalid verdict'; return 2 ;;
  esac
}

_uberdev_semaphore_backend_live() {
  local handle status_kind expected_identity handle_kind pid
  handle="${1-}"
  status_kind="${2-unknown}"
  expected_identity="${3-}"
  # Shared backend-liveness matrix (kept in parity with run_manifest.py):
  # terminal -> dead; status-only/opaque -> live only from live status;
  # numeric and pid:<numeric> -> process probe only.
  [ "$status_kind" != 'terminal' ] || return 1
  handle_kind="$(_uberdev_semaphore_classify_handle "$handle")" || return 1
  case "$handle_kind" in
    status-only|opaque)
      [ "$status_kind" = 'live' ]
      return $?
      ;;
    pid:*)
      pid="${handle_kind#pid:}"
      if [ -n "$expected_identity" ]; then
        _uberdev_semaphore_process_identity_matches "$pid" "$expected_identity"
      else
        _uberdev_semaphore_pid_live "$pid"
      fi
      return $?
      ;;
  esac
  return 1
}

_uberdev_semaphore_reconcile_locked() {
  local scope now lease status_kind age owner_live backend_live remove probe_rc
  scope="$1"
  now="$(date +%s)"
  _UBERDEV_SEMAPHORE_REMOVED=0
  for lease in "$scope"/*.lease; do
    [ -e "$lease" ] || [ -L "$lease" ] || continue
    [ ! -L "$lease" ] && [ -f "$lease" ] || {
      _uberdev_semaphore_error "unsafe lease: $(basename "$lease")"
      return 2
    }
    if ! _uberdev_semaphore_read_lease "$lease"; then
      _uberdev_semaphore_error "malformed lease: $(basename "$lease")"
      return 2
    fi
    status_kind="$(_uberdev_semaphore_status_kind "$_UBERDEV_LEASE_STATUS_PATH")" || return 2
    remove=0
    if [ "$status_kind" = 'terminal' ]; then
      remove=1
    else
      owner_live=0
      backend_live=0
      if [ -n "$_UBERDEV_LEASE_OWNER_IDENTITY" ]; then
        if _uberdev_semaphore_process_identity_matches "$_UBERDEV_LEASE_OWNER_PID" \
            "$_UBERDEV_LEASE_OWNER_IDENTITY"; then
          owner_live=1
        else
          probe_rc=$?
          [ "$probe_rc" -ne 2 ] || return 2
        fi
      else
        _uberdev_semaphore_pid_live "$_UBERDEV_LEASE_OWNER_PID" && owner_live=1
      fi
      if _uberdev_semaphore_backend_live "$_UBERDEV_LEASE_BACKEND_HANDLE" "$status_kind" \
          "$_UBERDEV_LEASE_BACKEND_IDENTITY"; then
        backend_live=1
      else
        probe_rc=$?
        [ "$probe_rc" -ne 2 ] || return 2
      fi
      age=$((now - _UBERDEV_LEASE_START_EPOCH))
      [ "$age" -ge 0 ] || age=0
      if [ "$owner_live" -eq 0 ] && [ "$backend_live" -eq 0 ]; then
        remove=1
      elif [ "$age" -gt "$_UBERDEV_LEASE_TIMEOUT_S" ] && [ "$backend_live" -eq 0 ]; then
        remove=1
      fi
    fi
    if [ "$remove" -eq 1 ]; then
      if _uberdev_semaphore_remove_lease "$lease" "$_UBERDEV_LEASE_GENERATION"; then
        _UBERDEV_SEMAPHORE_REMOVED=$((_UBERDEV_SEMAPHORE_REMOVED + 1))
      else
        _uberdev_semaphore_error "cannot remove reconciled lease: $(basename "$lease")"
        return 2
      fi
    fi
  done
}

_uberdev_semaphore_count_locked() {
  local scope lease count
  scope="$1"
  count=0
  for lease in "$scope"/*.lease; do
    [ -f "$lease" ] && [ ! -L "$lease" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

_uberdev_semaphore_run_exists_locked() {
  local scope="$1" run_id="$2" lease
  for lease in "$scope"/*.lease; do
    [ -e "$lease" ] || [ -L "$lease" ] || continue
    [ -f "$lease" ] && [ ! -L "$lease" ] || return 2
    _uberdev_semaphore_read_lease "$lease" || return 2
    [ "$_UBERDEV_LEASE_RUN_ID" != "$run_id" ] || return 0
  done
  return 1
}

_uberdev_semaphore_new_lease_path_locked() {
  local scope="$1" run_id="$2" nonce_file nonce lease_hash lease old_umask attempts
  attempts=0
  while [ "$attempts" -lt 3 ]; do
    old_umask="$(umask)"
    umask 077
    nonce_file="$(mktemp "$scope/.lease-id.XXXXXX")" || {
      umask "$old_umask"
      return 2
    }
    umask "$old_umask"
    nonce="$(basename "$nonce_file")"
    rm -f "$nonce_file" 2>/dev/null || return 2
    lease_hash="$(_uberdev_semaphore_hash "run:${#run_id}:$run_id|nonce:${#nonce}:$nonce")" || return 2
    lease="$scope/$lease_hash.lease"
    if [ ! -e "$lease" ] && [ ! -L "$lease" ]; then
      printf '%s\n' "$lease"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  _uberdev_semaphore_error 'cannot allocate unique lease identity'
  return 2
}

_uberdev_semaphore_publish_lease() {
  local scope lease generation run_id owner_pid owner_identity backend_handle backend_identity start_epoch timeout_s status_path manifest_tool published_identity
  scope="$1"
  lease="$2"
  generation="$(basename "$lease" .lease | cut -c 1-32)"
  run_id="$3"
  owner_pid="$4"
  owner_identity="$5"
  backend_handle="$6"
  backend_identity="$7"
  start_epoch="$8"
  timeout_s="$9"
  status_path="${10}"
  _UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY=''
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  published_identity="$(printf 'version=1\ngeneration=%s\nrun_id=%s\nowner_pid=%s\nowner_identity=%s\nbackend_handle=%s\nbackend_identity=%s\nstart_epoch=%s\ntimeout_s=%s\nstatus_path=%s\n' \
    "$generation" "$run_id" "$owner_pid" "$owner_identity" "$backend_handle" "$backend_identity" \
    "$start_epoch" "$timeout_s" "$status_path" \
    | python3 "$manifest_tool" secure-write-lease --lease-path "$lease")" || return 2
  case "$published_identity" in *[!0-9:]*|:*|*:|*:*:*) return 2 ;; esac
  _UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY="$published_identity"
}

_uberdev_semaphore_remove_lease() {
  local lease="$1" generation="${2-}" identity="${3-}" manifest_tool
  if [ -z "$generation" ]; then
    _uberdev_semaphore_read_lease "$lease" || return 2
    generation="$_UBERDEV_LEASE_GENERATION"
  fi
  if [ -z "$identity" ]; then
    identity="$(_uberdev_semaphore_lease_identity "$lease" "$generation")" || {
      [ ! -e "$lease" ] && [ ! -L "$lease" ] && return 0
      return 2
    }
  fi
  case "$identity" in ''|*[!0-9:]*|:*|*:|*:*:*) return 2 ;; esac
  manifest_tool="$(_uberdev_semaphore_manifest_tool)" || return 2
  python3 -I -B "$manifest_tool" secure-remove-lease --lease-path "$lease" \
    --generation "$generation" --identity "$identity" >/dev/null
}

uberdev_semaphore_acquire() {
  local state_root repo_id backend cap run_id timeout_s identity_mode output_variable scope lease active wait_tries wait_max mutex_rc duplicate_rc owner_pid
  local generation path_identity exact_identity cleanup_rc record owner_identity owner_mode
  _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=''
  state_root="${1-}"
  repo_id="${2-}"
  backend="${3-}"
  cap="${4-}"
  run_id="${5-}"
  timeout_s="${6-}"
  identity_mode="${7-}"
  output_variable="${8-}"
  case "$identity_mode" in ''|exact-identity) ;; *) _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input; return 2 ;; esac
  case "$output_variable" in ''|[A-Za-z_]*) ;; *) _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input; return 2 ;; esac
  case "$output_variable" in *[!A-Za-z0-9_]*) _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input; return 2 ;; esac
  if [ -n "$output_variable" ]; then owner_mode=direct; else owner_mode=parent; fi

  _uberdev_semaphore_is_positive_integer "$cap" || {
    _uberdev_semaphore_error 'CAP must be a positive integer'
    _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input
    return 2
  }
  _uberdev_semaphore_is_positive_integer "$timeout_s" || {
    _uberdev_semaphore_error 'TIMEOUT_S must be a positive integer'
    _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input
    return 2
  }
  _uberdev_semaphore_safe_text "$run_id" || {
    _uberdev_semaphore_error 'RUN_ID must be non-empty single-line text'
    _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_invalid_input
    return 2
  }
  scope="$(_uberdev_semaphore_prepare_scope "$state_root" "$repo_id" "$backend")" || {
    _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_runtime_state_failed
    return 2
  }
  wait_tries=0
  wait_max="${UBERDEV_SEMAPHORE_ACQUIRE_MAX_TRIES:-30000}"
  _uberdev_semaphore_is_positive_integer "$wait_max" || wait_max=30000

  while [ "$wait_tries" -lt "$wait_max" ]; do
    _uberdev_semaphore_mutex_acquire "$scope"
    mutex_rc=$?
    [ "$mutex_rc" -eq 0 ] || {
      [ "$mutex_rc" -ne 2 ] || _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_failed
      return "$mutex_rc"
    }
    if ! _uberdev_semaphore_reconcile_locked "$scope"; then
      if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
        _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
      else
        _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_reconcile_failed
      fi
      return 2
    fi
    _uberdev_semaphore_run_exists_locked "$scope" "$run_id"
    duplicate_rc=$?
    case "$duplicate_rc" in
      0)
        if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
          return 2
        fi
        _uberdev_semaphore_error 'RUN_ID already owns a live lease'
        return 73
        ;;
      1) ;;
      *)
        _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
          return 2
        }
        _uberdev_semaphore_error 'cannot validate leases for duplicate RUN_ID'
        _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_duplicate_check_failed
        return 2
        ;;
    esac
    active="$(_uberdev_semaphore_count_locked "$scope")" || {
      if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
        _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
        _uberdev_semaphore_error 'cannot release acquisition mutex'
      else
        _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_count_failed
      fi
      return 2
    }
    if [ "$active" -lt "$cap" ]; then
      lease="$(_uberdev_semaphore_new_lease_path_locked "$scope" "$run_id")" || {
        if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
          _uberdev_semaphore_error 'cannot release acquisition mutex'
        else
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_allocate_failed
        fi
        return 2
      }
      _uberdev_semaphore_capture_lease_owner "$scope" "$owner_mode" || {
        _uberdev_semaphore_error 'cannot resolve lease owner process'
        if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
          _uberdev_semaphore_error 'cannot release acquisition mutex'
        else
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_owner_failed
        fi
        return 2
      }
      owner_pid="$_UBERDEV_SEMAPHORE_LEASE_OWNER_PID"
      owner_identity="$_UBERDEV_SEMAPHORE_LEASE_OWNER_IDENTITY"
      generation="$(basename "$lease" .lease | cut -c 1-32)"
      if ! _uberdev_semaphore_publish_lease "$scope" "$lease" "$run_id" "$owner_pid" \
          "$owner_identity" '' '' "$(date +%s)" "$timeout_s" ''; then
        cleanup_rc=0
        exact_identity=''
        if [ -e "$lease" ] || [ -L "$lease" ]; then
          path_identity="$(_uberdev_semaphore_lease_identity "$lease" "$generation" 2>/dev/null || true)"
          case "$path_identity" in
            ''|*[!0-9:]*|:*|*:|*:*:*) ;;
            *) exact_identity="$path_identity:$generation" ;;
          esac
          _uberdev_semaphore_remove_lease "$lease" "$generation" \
            "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" || cleanup_rc=2
        fi
        _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || cleanup_rc=2
        if [ "$cleanup_rc" -eq 0 ]; then
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_publish_failed
          _uberdev_semaphore_error 'cannot publish lease'
        else
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_rollback_failed
          _uberdev_semaphore_error 'cannot publish or roll back lease'
          if [ -n "$exact_identity" ]; then
            record="$lease"$'\t'"$exact_identity"
            if [ -n "$output_variable" ]; then printf -v "$output_variable" '%s' "$record"; else printf '%s\n' "$record"; fi
          fi
        fi
        return 2
      fi
      exact_identity=''
      if [ "$identity_mode" = exact-identity ]; then
        exact_identity="${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}:$generation"
        path_identity="$(_uberdev_semaphore_lease_identity "$lease" "$generation" 2>/dev/null || true)"
        if [ "$path_identity:$generation" != "$exact_identity" ]; then
          cleanup_rc=0
          _uberdev_semaphore_remove_lease "$lease" "$generation" \
            "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" || cleanup_rc=2
          _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || cleanup_rc=2
          if [ "$cleanup_rc" -eq 0 ]; then
            _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_identity_failed
            _uberdev_semaphore_error 'cannot capture acquired lease identity'
          else
            _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_rollback_failed
            _uberdev_semaphore_error 'cannot capture or roll back acquired lease identity'
            record="$lease"$'\t'"$exact_identity"
            if [ -n "$output_variable" ]; then printf -v "$output_variable" '%s' "$record"; else printf '%s\n' "$record"; fi
          fi
          return 2
        fi
      fi
      if ! _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1; then
        cleanup_rc=0
        _uberdev_semaphore_remove_lease "$lease" "$generation" \
          "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" >/dev/null 2>&1 || cleanup_rc=2
        if [ "$cleanup_rc" -eq 0 ]; then
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
        else
          _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_rollback_failed
          record="$lease"$'\t'"$exact_identity"
          if [ -n "$output_variable" ]; then printf -v "$output_variable" '%s' "$record"; else printf '%s\n' "$record"; fi
        fi
        _uberdev_semaphore_error 'cannot release acquisition mutex'
        return 2
      fi
      if [ "$identity_mode" = exact-identity ]; then record="$lease"$'\t'"$exact_identity"; else record="$lease"; fi
      if [ -n "$output_variable" ]; then printf -v "$output_variable" '%s' "$record"; else printf '%s\n' "$record"; fi
      return 0
    fi
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
      _UBERDEV_SEMAPHORE_ACQUIRE_FAILURE_REASON=lease_acquire_mutex_release_failed
      return 2
    }
    wait_tries=$((wait_tries + 1))
    [ "$wait_tries" -ge "$wait_max" ] || sleep 0.02
  done
  _uberdev_semaphore_error 'capacity wait limit exceeded'
  return 75
}

uberdev_semaphore_set_handle() {
  local lease backend_handle status_path identity_mode output_variable backend_identity scope mutex_rc publish_rc handle_kind
  local expected_generation exact_identity='' path_identity='' rollback_rc=0
  _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=''
  lease="${1-}"
  backend_handle="${2-}"
  status_path="${3-}"
  identity_mode="${4-}"
  output_variable="${5-}"
  backend_identity="${6-}"
  case "$identity_mode" in ''|exact-identity) ;; *) return 2 ;; esac
  case "$output_variable" in ''|[A-Za-z_]*) ;; *) return 2 ;; esac
  case "$output_variable" in *[!A-Za-z0-9_]*) return 2 ;; esac
  _uberdev_semaphore_validate_lease_path "$lease" || return 2
  [ -f "$lease" ] || {
    _uberdev_semaphore_error 'lease does not exist'
    return 2
  }
  handle_kind="$(_uberdev_semaphore_classify_handle "$backend_handle")" || {
    _uberdev_semaphore_error 'BACKEND_HANDLE is invalid'
    return 2
  }
  if [ -n "$backend_identity" ]; then
    printf '%s\n' "$backend_identity" \
      | grep -Eq '^[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*\|[0-9a-f]{64}$' || return 2
    [ "$handle_kind" != status-only ] && [ "$handle_kind" != opaque ] || return 2
    [ "${backend_identity%%|*}" = "${handle_kind#pid:}" ] || return 2
  fi
  if [ "$handle_kind" = opaque ] && [ -z "$status_path" ]; then
    _uberdev_semaphore_error 'opaque BACKEND_HANDLE requires STATUS_PATH'
    return 2
  fi
  if [ -n "$status_path" ]; then
    _uberdev_semaphore_is_absolute_path "$status_path" || {
      _uberdev_semaphore_error 'STATUS_PATH must be absolute'; return 2
    }
    [ ! -L "$status_path" ] || {
      _uberdev_semaphore_error 'STATUS_PATH symlinks are forbidden'
      return 2
    }
    if [ -e "$status_path" ] && [ ! -f "$status_path" ]; then
      _uberdev_semaphore_error 'STATUS_PATH must be a regular file'
      return 2
    fi
    _uberdev_semaphore_safe_text "$status_path" || {
      _uberdev_semaphore_error 'STATUS_PATH must be single-line'
      return 2
    }
  fi
  scope="$(dirname "$lease")"
  _uberdev_semaphore_mutex_acquire "$scope"
  mutex_rc=$?
  [ "$mutex_rc" -eq 0 ] || return "$mutex_rc"
  if [ -L "$lease" ] || [ ! -f "$lease" ] || ! _uberdev_semaphore_read_lease "$lease"; then
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true
    _uberdev_semaphore_error 'lease changed before handle update'
    return 2
  fi
  expected_generation="$_UBERDEV_LEASE_GENERATION"
  _uberdev_semaphore_publish_lease "$scope" "$lease" "$_UBERDEV_LEASE_RUN_ID" \
    "$_UBERDEV_LEASE_OWNER_PID" "$_UBERDEV_LEASE_OWNER_IDENTITY" "$backend_handle" \
    "$backend_identity" "$_UBERDEV_LEASE_START_EPOCH" "$_UBERDEV_LEASE_TIMEOUT_S" "$status_path"
  publish_rc=$?
  if [ "$publish_rc" -eq 0 ] && [ "$identity_mode" = exact-identity ]; then
    exact_identity="${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}:$expected_generation"
    if _uberdev_semaphore_read_lease "$lease" \
        && [ "$_UBERDEV_LEASE_GENERATION" = "$expected_generation" ] \
        && [ "$_UBERDEV_LEASE_BACKEND_HANDLE" = "$backend_handle" ] \
        && [ "$_UBERDEV_LEASE_BACKEND_IDENTITY" = "$backend_identity" ] \
        && [ "$_UBERDEV_LEASE_STATUS_PATH" = "$status_path" ]; then
      if path_identity="$(_uberdev_semaphore_lease_identity "$lease" "$expected_generation")"; then
        [ "$path_identity:$expected_generation" = "$exact_identity" ] || publish_rc=2
      else
        publish_rc=2
      fi
    else
      publish_rc=2
    fi
    if [ "$publish_rc" -ne 0 ] || [ -z "$exact_identity" ]; then
      rollback_rc=0
      _uberdev_semaphore_remove_lease "$lease" "$expected_generation" \
        "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" >/dev/null 2>&1 || rollback_rc=2
      publish_rc=2
      if [ "$rollback_rc" -eq 0 ]; then
        exact_identity=''
        _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=lease_handle_validation_failed
      else
        _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=lease_handle_rollback_failed
      fi
    fi
  elif [ "$publish_rc" -ne 0 ]; then
    _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=lease_handle_publish_failed
  fi
  _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
    if [ "$publish_rc" -eq 0 ]; then
      rollback_rc=0
      _uberdev_semaphore_remove_lease "$lease" "$expected_generation" \
        "${_UBERDEV_SEMAPHORE_PUBLISHED_IDENTITY:-}" >/dev/null 2>&1 || rollback_rc=2
      publish_rc=2
      if [ "$rollback_rc" -eq 0 ]; then
        exact_identity=''
        _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=lease_handle_mutex_release_failed
      else
        _UBERDEV_SEMAPHORE_SET_HANDLE_FAILURE_REASON=lease_handle_rollback_failed
      fi
    fi
  }
  [ "$publish_rc" -eq 0 ] || _uberdev_semaphore_error 'cannot update lease handle'
  if [ "$identity_mode" = exact-identity ] && [ -n "$exact_identity" ]; then
    if [ -n "$output_variable" ]; then printf -v "$output_variable" '%s' "$exact_identity"; else printf '%s' "$exact_identity"; fi
  fi
  return "$publish_rc"
}

uberdev_semaphore_release() {
  local lease scope mutex_rc remove_rc
  lease="${1-}"
  _uberdev_semaphore_validate_lease_path "$lease" || return 2
  [ -e "$lease" ] || return 0
  scope="$(dirname "$lease")"
  _uberdev_semaphore_mutex_acquire "$scope"
  mutex_rc=$?
  [ "$mutex_rc" -eq 0 ] || return "$mutex_rc"
  remove_rc=0
  if [ -L "$lease" ]; then
    remove_rc=2
  elif [ -e "$lease" ]; then
    if ! _uberdev_semaphore_read_lease "$lease"; then
      remove_rc=2
    else
      _uberdev_semaphore_remove_lease "$lease" "$_UBERDEV_LEASE_GENERATION" || remove_rc=2
    fi
  fi
  _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || {
    [ "$remove_rc" -ne 0 ] || remove_rc=2
  }
  return "$remove_rc"
}

uberdev_semaphore_reconcile() {
  local state_root repo_id backend scope mutex_rc removed release_rc
  state_root="${1-}"
  repo_id="${2-}"
  backend="${3-}"
  scope="$(_uberdev_semaphore_prepare_scope "$state_root" "$repo_id" "$backend")" || return $?
  _uberdev_semaphore_mutex_acquire "$scope"
  mutex_rc=$?
  [ "$mutex_rc" -eq 0 ] || return "$mutex_rc"
  if ! _uberdev_semaphore_reconcile_locked "$scope"; then
    _uberdev_semaphore_mutex_release "$scope" >/dev/null 2>&1 || true
    return 2
  fi
  removed="$_UBERDEV_SEMAPHORE_REMOVED"
  _uberdev_semaphore_mutex_release "$scope"
  release_rc=$?
  [ "$release_rc" -eq 0 ] || return "$release_rc"
  printf '%s\n' "$removed"
}

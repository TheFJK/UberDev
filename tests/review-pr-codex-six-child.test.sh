#!/usr/bin/env bash
# Issue #335 end-to-end regression: a generated Codex review entrypoint creates
# one immutable Codex carrier and supervises the six Phase 1 reviewer children
# without touching Claude, colliding worktrees, or leaking capacity leases.

set -euo pipefail

six_child_update_readiness_deadline() {
  local startup_progress=0 numeric

  case "${fully_dispatched-}" in 0|1) ;; *) return 74 ;; esac
  for numeric in \
      "${ready_count-}" "${backend_bound_lease_count-}" "${max_ready_count-}" \
      "${max_backend_bound_lease_count-}" "${barrier_now-}" "${startup_timeout-}" \
      "${barrier_timeout-}" "${barrier_deadline-}"; do
    case "$numeric" in
      0) ;;
      [1-9]*) case "$numeric" in *[!0-9]*) return 74 ;; esac ;;
      *) return 74 ;;
    esac
    [ "${#numeric}" -le 18 ] || return 74
  done
  [ "$startup_timeout" -gt 0 ] && [ "$barrier_timeout" -gt 0 ] || return 74
  [ "$ready_count" -le 6 ] && [ "$backend_bound_lease_count" -le 6 ] \
    && [ "$max_ready_count" -le 6 ] && [ "$max_backend_bound_lease_count" -le 6 ] \
    || return 74

  # A progress sample does not retroactively rescue an already-expired phase.
  if [ "$barrier_now" -ge "$barrier_deadline" ]; then
    return 124
  fi

  if [ "$fully_dispatched" -eq 0 ]; then
    if [ "$ready_count" -gt "$max_ready_count" ]; then
      max_ready_count="$ready_count"
      startup_progress=1
    fi
    if [ "$backend_bound_lease_count" -gt "$max_backend_bound_lease_count" ]; then
      max_backend_bound_lease_count="$backend_bound_lease_count"
      startup_progress=1
    fi
    if [ "$startup_progress" -eq 1 ]; then
      barrier_deadline=$((barrier_now + startup_timeout))
    fi
    if [ "$backend_bound_lease_count" -eq 6 ]; then
      barrier_deadline=$((barrier_now + barrier_timeout))
      fully_dispatched=1
    fi
  fi

  return 0
}

six_child_count_readiness_leases() {
  local lease_root="${1-}" lease='' lease_probe='' scan_rc
  local root_probe='' lease_scope='' scope_probe=''

  raw_lease_count=0
  backend_bound_lease_count=0
  lease_scan_detail=''
  if [ -z "$lease_root" ]; then
    lease_scan_detail='lease-discovery-failed rc=74 root=missing'
    return 74
  fi
  if root_probe="$(find "$lease_root" -prune -type d -print 2>&1)"; then
    if [ "$root_probe" != "$lease_root" ]; then
      lease_scan_detail="lease-discovery-failed rc=74 root=$lease_root error=not-a-directory"
      return 74
    fi
  else
    scan_rc=$?
    root_probe="$(printf '%s' "$root_probe" | tr '\r\n' '  ')"
    lease_scan_detail="lease-discovery-failed rc=$scan_rc root=$lease_root error=$root_probe"
    return 74
  fi

  for lease_scope in "$lease_root"/.agent-state-*/semaphore-v1/*.scope; do
    if [ ! -e "$lease_scope" ] && [ ! -L "$lease_scope" ]; then
      case "$lease_scope" in *'*'*) continue ;; esac
      lease_scan_detail="lease-discovery-failed rc=74 scope=$lease_scope error=disappeared"
      return 74
    fi
    if [ ! -d "$lease_scope" ] || [ -L "$lease_scope" ]; then
      lease_scan_detail="lease-discovery-failed rc=74 scope=$lease_scope error=invalid-scope"
      return 74
    fi
    if scope_probe="$(LC_ALL=C ls -f "$lease_scope" 2>&1 >/dev/null)"; then
      :
    else
      scan_rc=$?
      scope_probe="$(printf '%s' "$scope_probe" | tr '\r\n' '  ')"
      lease_scan_detail="lease-discovery-failed rc=$scan_rc scope=$lease_scope error=scope-enumeration-failed:$scope_probe"
      return 74
    fi

    for lease in "$lease_scope"/*.lease; do
      if [ ! -e "$lease" ] && [ ! -L "$lease" ]; then
        if [ "$lease" = "$lease_scope/*.lease" ]; then
          continue
        fi
        lease_scan_detail="lease-candidate-disappeared lease=$lease"
        return 74
      fi
      if [ -L "$lease" ]; then
        lease_scan_detail="lease-candidate-invalid kind=symlink lease=$lease"
        return 74
      fi
      if [ ! -f "$lease" ]; then
        lease_scan_detail="lease-candidate-invalid kind=non-regular lease=$lease"
        return 74
      fi
      raw_lease_count=$((raw_lease_count + 1))
      if [ "$raw_lease_count" -gt 6 ]; then
        lease_scan_detail="raw-lease-count-exceeded count=$raw_lease_count"
        return 74
      fi
      if lease_probe="$(grep -q '^backend_identity=.' "$lease" 2>&1)"; then
        backend_bound_lease_count=$((backend_bound_lease_count + 1))
        if [ "$backend_bound_lease_count" -gt 6 ]; then
          lease_scan_detail="bound-lease-count-exceeded count=$backend_bound_lease_count"
          return 74
        fi
      else
        scan_rc=$?
        case "$scan_rc" in
          1) ;;
          *)
            lease_probe="$(printf '%s' "$lease_probe" | tr '\r\n' '  ')"
            lease_scan_detail="lease-read-failed rc=$scan_rc lease=$lease error=$lease_probe"
            return 74
            ;;
        esac
      fi
    done
  done
  return 0
}

six_child_resolve_readiness_preflight() {
  readiness_preflight_rc=0
  readiness_preflight_reason=continue
  readiness_preflight_detail=''

  case "${terminal-}" in
    1)
      readiness_preflight_rc=70
      readiness_preflight_reason=terminal-before-readiness
      return 0
      ;;
    0) ;;
    *)
      readiness_preflight_rc=74
      readiness_preflight_reason=coordinator-error
      readiness_preflight_detail=invalid-terminal-state
      return 0
      ;;
  esac

  case "${lease_scan_rc-}" in
    0) ;;
    [1-9]*)
      case "$lease_scan_rc" in
        *[!0-9]*)
          readiness_preflight_rc=74
          readiness_preflight_reason=coordinator-error
          readiness_preflight_detail=invalid-lease-scan-state
          return 0
          ;;
      esac
      readiness_preflight_rc="$lease_scan_rc"
      readiness_preflight_reason=coordinator-error
      readiness_preflight_detail="${lease_scan_detail-}"
      ;;
    *)
      readiness_preflight_rc=74
      readiness_preflight_reason=coordinator-error
      readiness_preflight_detail=invalid-lease-scan-state
      ;;
  esac
  return 0
}

run_readiness_progress_deadline_regression() {
  if ! declare -F six_child_update_readiness_deadline >/dev/null; then
    echo "missing six-child readiness progress deadline helper" >&2
    return 1
  fi
  if ! declare -F six_child_resolve_readiness_preflight >/dev/null; then
    echo "missing six-child readiness preflight decision helper" >&2
    return 1
  fi

  startup_timeout=60
  barrier_timeout=10
  barrier_deadline=60
  fully_dispatched=0
  max_ready_count=0
  max_backend_bound_lease_count=0

  # Total startup takes 190 logical seconds, but each ready/bound-lease advance
  # arrives less than 60 seconds after the previous one. No step may time out.
  while read -r barrier_now ready_count backend_bound_lease_count; do
    if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
    if [ "$step_rc" -ne 0 ]; then
      printf 'progress deadline expired: now=%s ready=%s bound_leases=%s rc=%s\n' \
        "$barrier_now" "$ready_count" "$backend_bound_lease_count" "$step_rc" >&2
      return 1
    fi
  done <<'EOF'
20 1 0
40 1 1
60 2 1
80 2 2
100 3 2
120 3 3
140 4 4
160 5 5
EOF
  [ "$barrier_deadline" -eq 220 ]

  # Regressing observations must not move the monotonic maxima or deadline.
  barrier_now=170
  ready_count=4
  backend_bound_lease_count=4
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 0 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "5:5:220" ]

  # The sixth bound lease switches to the existing barrier timeout phase.
  barrier_now=190
  ready_count=5
  backend_bound_lease_count=6
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 0 ]
  [ "$fully_dispatched:$barrier_deadline" = "1:200" ]

  # Ready progress observed after all six leases are bound belongs to the
  # fixed barrier phase. It must not refresh that phase's original deadline.
  barrier_deadline=200
  fully_dispatched=1
  max_ready_count=4
  max_backend_bound_lease_count=6
  barrier_now=195
  ready_count=5
  backend_bound_lease_count=6
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 0 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "4:6:200" ]
  barrier_now=200
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 124 ]
  [ "$barrier_deadline" -eq 200 ]

  # Once fully dispatched, ready=5/bound-leases=6 still times out on the
  # barrier deadline; repeated not-ready observations must not extend it.
  barrier_now=201
  ready_count=5
  backend_bound_lease_count=6
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 124 ]

  # Before full dispatch, a genuine 61-second no-progress stall remains rc124.
  barrier_deadline=60
  fully_dispatched=0
  max_ready_count=0
  max_backend_bound_lease_count=0
  barrier_now=20
  ready_count=1
  backend_bound_lease_count=1
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc:$barrier_deadline" = "0:80" ]
  barrier_now=81
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 124 ]

  # Progress first observed at or after the prior deadline is already late and
  # must not mutate either monotonic maximum or extend the expired deadline.
  barrier_deadline=60
  fully_dispatched=0
  max_ready_count=0
  max_backend_bound_lease_count=0
  barrier_now=60
  ready_count=1
  backend_bound_lease_count=0
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 124 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "0:0:60" ]

  barrier_now=61
  ready_count=0
  backend_bound_lease_count=1
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 124 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "0:0:60" ]

  # This isolated wave owns exactly six children. Counts above that invariant
  # are coordinator errors, never progress and never startup timeouts.
  barrier_deadline=100
  barrier_now=10
  ready_count=7
  backend_bound_lease_count=0
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 74 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "0:0:100" ]

  ready_count=0
  backend_bound_lease_count=7
  if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
  [ "$step_rc" -eq 74 ]
  [ "$max_ready_count:$max_backend_bound_lease_count:$barrier_deadline" = "0:0:100" ]

  # Every arithmetic/global input is validated before the helper mutates state.
  for malformed_value in not-a-number 999999999999999999999999; do
    for malformed_field in \
        fully_dispatched ready_count backend_bound_lease_count max_ready_count \
        max_backend_bound_lease_count barrier_now startup_timeout barrier_timeout \
        barrier_deadline; do
      fully_dispatched=0
      ready_count=0
      backend_bound_lease_count=0
      max_ready_count=0
      max_backend_bound_lease_count=0
      barrier_now=10
      startup_timeout=60
      barrier_timeout=10
      barrier_deadline=100
      printf -v "$malformed_field" '%s' "$malformed_value"
      if six_child_update_readiness_deadline; then step_rc=0; else step_rc=$?; fi
      [ "$step_rc" -eq 74 ] || {
        printf 'malformed deadline input was not rejected: field=%s value=%s rc=%s\n' \
          "$malformed_field" "$malformed_value" "$step_rc" >&2
        return 1
      }
    done
  done

  (
    lease_fixture="$(mktemp -d)"
    cleanup_lease_fixture() {
      if [ -n "${lease_scope-}" ] && [ -d "$lease_scope" ]; then
        chmod 700 "$lease_scope" 2>/dev/null || :
      fi
      rm -rf "$lease_fixture"
    }
    trap cleanup_lease_fixture EXIT
    if ! declare -F six_child_count_readiness_leases >/dev/null; then
      echo "missing six-child readiness lease scan helper" >&2
      exit 1
    fi

    if six_child_count_readiness_leases "$lease_fixture/missing"; then scan_rc=0; else scan_rc=$?; fi
    [ "$scan_rc" -eq 74 ]
    case "$lease_scan_detail" in lease-discovery-failed*) ;; *) exit 1 ;; esac

    lease_scope="$lease_fixture/.agent-state-test/semaphore-v1/test.scope"
    mkdir -p "$lease_scope"
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    [ "$scan_rc:$raw_lease_count:$backend_bound_lease_count" = "0:0:0" ]

    # An unreadable scope must not collapse to the same literal glob as a
    # genuinely empty scope. Root can bypass mode 000, so force the probe's
    # command failure only under uid 0 while retaining the real mode fixture.
    printf 'backend_identity=synthetic\n' >"$lease_scope/unreadable.lease"
    chmod 000 "$lease_scope"
    root_probe_override=0
    if [ "$(id -u)" -eq 0 ]; then
      ls() { printf 'synthetic unreadable scope\n' >&2; return 13; }
      root_probe_override=1
    fi
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    [ "$root_probe_override" -eq 0 ] || unset -f ls
    chmod 700 "$lease_scope"
    if [ "$scan_rc" -ne 74 ]; then
      printf 'unreadable lease scope was not rejected: rc=%s raw=%s bound=%s detail=%s\n' \
        "$scan_rc" "$raw_lease_count" "$backend_bound_lease_count" \
        "$lease_scan_detail" >&2
      exit 1
    fi
    case "$lease_scan_detail" in
      lease-discovery-failed\ rc=[1-9]*\ scope=*\ error=scope-enumeration-failed*) ;;
      *) printf 'unreadable lease scope lacked probe detail: %s\n' \
           "$lease_scan_detail" >&2; exit 1 ;;
    esac
    rm -f "$lease_scope/unreadable.lease"

    printf 'backend_identity=\n' >"$lease_scope/one.lease"
    mkdir "$lease_scope/volatile-mutex-state"
    chmod 000 "$lease_scope/volatile-mutex-state"
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    chmod 700 "$lease_scope/volatile-mutex-state"
    [ "$scan_rc:$raw_lease_count:$backend_bound_lease_count" = "0:1:0" ]

    # Direct-child enumeration must reject deceptive lease-shaped entries
    # instead of silently filtering them out as BSD find -type f would.
    rm -rf "$lease_scope"
    mkdir -p "$lease_scope"
    printf 'backend_identity=target\n' >"$lease_fixture/symlink-target"
    ln -s "$lease_fixture/symlink-target" "$lease_scope/symlink.lease"
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    [ "$scan_rc" -eq 74 ]
    case "$lease_scan_detail" in
      lease-candidate-invalid\ kind=symlink*) ;;
      *) printf 'symlink lease was not rejected: rc=%s detail=%s\n' \
           "$scan_rc" "$lease_scan_detail" >&2; exit 1 ;;
    esac

    rm -rf "$lease_scope"
    mkdir -p "$lease_scope/directory.lease"
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    [ "$scan_rc" -eq 74 ]
    case "$lease_scan_detail" in
      lease-candidate-invalid\ kind=non-regular*) ;;
      *) printf 'directory lease was not rejected: rc=%s detail=%s\n' \
           "$scan_rc" "$lease_scan_detail" >&2; exit 1 ;;
    esac

    # A candidate removed after the shell expands the direct-child glob is an
    # operational scan failure, not an unmatched glob and not an unbound lease.
    rm -rf "$lease_scope"
    mkdir -p "$lease_scope"
    printf 'backend_identity=\n' >"$lease_scope/a.lease"
    printf 'backend_identity=synthetic\n' >"$lease_scope/b.lease"
    grep() {
      case "${!#}" in
        */a.lease) rm -f "$lease_scope/b.lease"; return 1 ;;
        *) command grep "$@" ;;
      esac
    }
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    unset -f grep
    [ "$scan_rc" -eq 74 ]
    case "$lease_scan_detail" in
      lease-candidate-disappeared*) ;;
      *) printf 'disappearing lease was not classified: rc=%s detail=%s\n' \
           "$scan_rc" "$lease_scan_detail" >&2; exit 1 ;;
    esac
    disappearing_scan_detail="$lease_scan_detail"

    # In one coordinator sample, terminal evidence and the disappearing-lease
    # scan failure coexist. Durable terminal evidence must deterministically
    # win the decision before the scan error is mapped to coordinator failure.
    terminal=1
    lease_scan_rc="$scan_rc"
    six_child_resolve_readiness_preflight
    [ "$readiness_preflight_rc:$readiness_preflight_reason" = \
      "70:terminal-before-readiness" ]
    [ -z "$readiness_preflight_detail" ]

    terminal=0
    six_child_resolve_readiness_preflight
    [ "$readiness_preflight_rc:$readiness_preflight_reason" = \
      "74:coordinator-error" ]
    [ "$readiness_preflight_detail" = "$disappearing_scan_detail" ]

    # The scanner may probe the root, but it must never traverse a scope (and
    # therefore cannot enter volatile mutex quarantine descendants).
    rm -rf "$lease_scope"
    mkdir -p "$lease_scope/.mutex.quarantine.synthetic"
    printf 'backend_identity=\n' >"$lease_scope/one.lease"
    find() {
      if [ "${1-}" = "$lease_scope" ]; then
        printf 'per-scope find traversal is forbidden\n' >&2
        return 99
      fi
      command find "$@"
    }
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    unset -f find
    [ "$scan_rc:$raw_lease_count:$backend_bound_lease_count" = "0:1:0" ]

    rm -rf "$lease_scope"
    mkdir -p "$lease_scope"
    for i in 1 2 3 4 5 6 7; do
      printf 'backend_identity=\n' >"$lease_scope/$i.lease"
    done
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    [ "$scan_rc" -eq 74 ]
    [ "$raw_lease_count" -eq 7 ]
    case "$lease_scan_detail" in raw-lease-count-exceeded*) ;; *) exit 1 ;; esac

    rm -rf "$lease_scope"
    mkdir -p "$lease_scope"
    printf 'backend_identity=synthetic\n' >"$lease_scope/read-error.lease"
    grep() { printf 'synthetic lease read failure\n' >&2; return 2; }
    if six_child_count_readiness_leases "$lease_fixture"; then scan_rc=0; else scan_rc=$?; fi
    unset -f grep
    [ "$scan_rc" -eq 74 ]
    case "$lease_scan_detail" in lease-read-failed*) ;; *) exit 1 ;; esac
  )

  echo "review-pr Codex six-child progress deadline regression passed"
}

if [ "${SIX_CHILD_CASE:-all}" = progress-deadline ]; then
  run_readiness_progress_deadline_regression
  exit
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_GIT="$(command -v git)"
RUNTIME_ROOT="${SIX_CHILD_RUNTIME_ROOT:-$ROOT/codex/uberdev-codex}"
RUNTIME_NAMESPACE="${SIX_CHILD_RUNTIME_NAMESPACE:-uberdev}"
case "$RUNTIME_NAMESPACE" in
  uberdev) COMMAND_SKILL=uberdev-cmd-review-pr; POST_SKILL_DIR=post-impl-review ;;
  prkit) COMMAND_SKILL=prkit-cmd-review-pr; POST_SKILL_DIR=prkit-post-impl-review ;;
  *) echo "unknown SIX_CHILD_RUNTIME_NAMESPACE=$RUNTIME_NAMESPACE" >&2; exit 2 ;;
esac
SKILL="$RUNTIME_ROOT/skills/$COMMAND_SKILL/SKILL.md"
POST_SKILL="$RUNTIME_ROOT/skills/$POST_SKILL_DIR/SKILL.md"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
declare -f six_child_update_readiness_deadline >"$TMP/readiness-deadline.sh"
declare -f six_child_count_readiness_leases >>"$TMP/readiness-deadline.sh"
declare -f six_child_resolve_readiness_preflight >>"$TMP/readiness-deadline.sh"

awk -v marker="$RUNTIME_NAMESPACE-executable setup=review-pr" '
  index($0,marker){active=1; next}
  active && /^```/{exit}
  active{print}
' "$SKILL" >"$TMP/setup.sh"
test -s "$TMP/setup.sh"
python3 -I -B - "$POST_SKILL" "$TMP/post-setup.sh" "$TMP/post-boundary.sh" "$RUNTIME_NAMESPACE" <<'PY'
import pathlib,re,sys
source=pathlib.Path(sys.argv[1]).read_text()
namespace=sys.argv[4]
def one(marker):
    matches=re.findall(rf'^```bash {re.escape(marker)}\s*\n(.*?)^```\s*$',source,re.M|re.S)
    assert len(matches)==1,(marker,len(matches))
    return matches[0]
setup=one(f'{namespace}-executable setup=post-impl-review')
pathlib.Path(sys.argv[2]).write_text(setup)
pathlib.Path(sys.argv[3]).write_text(one(f'{namespace}-executable'))
PY

# Lock the cleanup authority model without depending on line wrapping or local
# variable placement. Receipt inspection must precede mutation, registry
# classification must bracket removal, Git must receive the translated native
# target (never the logical pathname), and durable retirement must be last.
python3 -I -B - "$RUNTIME_ROOT/lib/dispatch.sh" "$RUNTIME_NAMESPACE" <<'PY'
import pathlib,re,sys

source=pathlib.Path(sys.argv[1]).read_text()
namespace=sys.argv[2]
prefix=f"_{namespace}_dispatch_"
upper=namespace.upper()

def function_body(name):
    match=re.search(rf"(?m)^{re.escape(name)}\(\)[ \t]*\{{[ \t]*$",source)
    assert match is not None,name
    following=re.search(r"(?m)^[_A-Za-z][_A-Za-z0-9]*\(\)[ \t]*\{[ \t]*$",source[match.end():])
    end=len(source) if following is None else match.end()+following.start()
    return source[match.start():end]

helper_name=prefix+"worktree_receipt_helper"
helper=function_body(helper_name)
assert re.search(rf"\$_{upper}_DISPATCH_LIB_DIR/worktree_receipts\.py\b",helper),helper
assert prefix+"python" in helper and "-I -B" in helper,helper

for action,suffix in (
    ("create","create_codex_worktree_receipt_at_head"),
    ("inspect","inspect_codex_worktree_receipt"),
    ("retire","retire_codex_worktree_receipt"),
):
    body=function_body(prefix+suffix)
    assert re.search(rf"{re.escape(helper_name)}\s+{action}\b",body),action

classifier_name=prefix+"classify_codex_worktree_registry"
classifier=function_body(classifier_name)
assert re.search(r"git\s+worktree\s+list\s+--porcelain",classifier),classifier
assert f"_{upper}_CODEX_REGISTRY_EXACT" in classifier,classifier
assert f"_{upper}_CODEX_REGISTRY_BRANCH" in classifier,classifier

cleanup=function_body(prefix+"cleanup_codex_worktree_locked")
inspect_name=prefix+"inspect_codex_worktree_receipt"
retire_name=prefix+"retire_codex_worktree_receipt"
native_name=prefix+"native_cli_path"

inspect=cleanup.find(inspect_name)
retire=cleanup.rfind(retire_name)
remove_matches=list(re.finditer(r"git\s+worktree\s+remove\s+--force\s+\"?\$([_A-Za-z][_A-Za-z0-9]*)\"?",cleanup))
assert len(remove_matches)==1,remove_matches
remove=remove_matches[0].start()
assert remove_matches[0].group(1)=="native_target",remove_matches[0].group(0)
assert re.search(
    rf"native_target\s*=\s*\"\$\({re.escape(native_name)}\s+\"\$target\"\)\"",
    cleanup,
),cleanup
assert re.search(
    r"MSYS_NO_PATHCONV=1\s+git\s+worktree\s+remove\s+--force\s+\"?\$native_target\"?",
    cleanup,
),cleanup
assert not re.search(r"git\s+worktree\s+remove\s+--force\s+\"?\$target\"?",cleanup),cleanup
assert "worktree_list" not in cleanup,cleanup

classifications=[match.start() for match in re.finditer(re.escape(classifier_name),cleanup)]
before=[position for position in classifications if position<remove]
after=[position for position in classifications if position>remove]
assert before and after,classifications
pre_registry=cleanup[max(before):remove]
post_registry=cleanup[min(after):retire]
exact=f"_{upper}_CODEX_REGISTRY_EXACT"
branch=f"_{upper}_CODEX_REGISTRY_BRANCH"
assert exact in pre_registry and "expected" in pre_registry and "present" in pre_registry,pre_registry
assert exact in post_registry and branch in post_registry and post_registry.count("absent")>=2,post_registry

branch_delete_match=re.search(r"git\s+branch\s+-D\s+\"?\$branch\"?",cleanup)
assert branch_delete_match is not None,cleanup
branch_delete=branch_delete_match.start()
assert 0<=inspect<max(before)<remove<min(after)<branch_delete<retire,(inspect,before,remove,after,branch_delete,retire)
assert re.search(r'start_head\s*=\s*"\$\{token##\*:\}"',cleanup),cleanup
PY

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

stress="${SIX_CHILD_GIT_MUTATION_STRESS:-0}"
is_common_probe=0
if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --git-common-dir ]; then
  is_common_probe=1
fi

# Hold cleanup immediately before mutex acquisition. Five non-timeout siblings
# must all be pending before any may proceed; the timed-out sixth arrives later.
# This proves genuine concurrent demand without widening the protected section.
if [ "$stress" = 1 ] && [ "$is_common_probe" -eq 1 ] \
    && [ -e "$CODEX_STUB_RELEASE_DIR/.all" ]; then
  pre="$SIX_CHILD_GIT_PREACQUIRE_DIR"
  mkdir -p "$pre"
  mkdir "$pre/arrival-$PPID" 2>/dev/null || true
  printf 'pending\tcase=%s\towner=%s\n' "$SIX_CHILD_CASE_TAG" "$PPID" \
    >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  arrivals="$(find "$pre" -mindepth 1 -maxdepth 1 -type d -name 'arrival-*' | wc -l | tr -d ' ')"
  if [ "$arrivals" -ge 5 ] && mkdir "$pre/released" 2>/dev/null; then
    printf 'barrier-release\tcase=%s\tcount=%s\n' "$SIX_CHILD_CASE_TAG" "$arrivals" \
      >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  fi
  tries=0
  while [ ! -d "$pre/released" ] && [ "$tries" -lt 2000 ]; do
    tries=$((tries + 1))
    sleep 0.01
  done
  if [ ! -d "$pre/released" ]; then
    printf 'barrier-timeout\tcase=%s\towner=%s\tarrivals=%s\n' \
      "$SIX_CHILD_CASE_TAG" "$PPID" "$arrivals" \
      >>"$SIX_CHILD_GIT_COLLISION_LOG"
    exit 88
  fi
fi

if [ "$stress" != 1 ]; then
  exec "$SIX_CHILD_REAL_GIT" "$@"
fi

phase=''
case "${1:-}:${2:-}" in
  worktree:add) phase=add ;;
  worktree:remove) phase=remove ;;
  worktree:list) phase=list ;;
  branch:-D) phase=branch ;;
esac
[ -n "$phase" ] || exec "$SIX_CHILD_REAL_GIT" "$@"

common_dir="$("$SIX_CHILD_REAL_GIT" rev-parse --git-common-dir)"
case "$common_dir" in /*) ;; *) common_dir="$PWD/$common_dir" ;; esac
common_dir="$(cd "$common_dir" && pwd -P)"
sentinel="$common_dir/.uberdev-six-child-git-critical"
owner_file="$sentinel/owner"
transaction_owner=''

collision() {
  reason="$1"
  shift
  actual="$(cat "$owner_file" 2>/dev/null || printf missing)"
  printf 'overlap\tcase=%s\treason=%s\towner=%s\tactual=%s\tphase=%s\targv=%s\n' \
    "$SIX_CHILD_CASE_TAG" "$reason" "${transaction_owner:-unprotected-pid:$PPID}" \
    "$actual" "$phase" "$*" \
    >>"$SIX_CHILD_GIT_COLLISION_LOG"
  exit 89
}

# The production mutex publishes one three-line owner record for the whole
# multi-command cleanup transaction. Its random token identifies the exact
# generation, unlike Bash 3.2's PPID (which changes inside command
# substitution). Bind that generation to this Git process by requiring the
# recorded mutex holder to be an actual ancestor; an unrelated process cannot
# borrow a live token merely by reading the common directory.
owner_candidates=(
  "$common_dir"/.uberdev-worktree-metadata-locks/semaphore-v1/*.scope/.mutex/owner_pid
)
[ "${#owner_candidates[@]}" -eq 1 ] || collision no-owner "$@"
mutex_owner_record="${owner_candidates[0]}"
[ -f "$mutex_owner_record" ] && [ ! -L "$mutex_owner_record" ] \
  || collision no-owner "$@"
[ -d "$(dirname "$mutex_owner_record")" ] && [ ! -L "$(dirname "$mutex_owner_record")" ] \
  || collision invalid-owner "$@"
mutex_record="$(cat "$mutex_owner_record")" || collision invalid-owner "$@"
mutex_owner_pid="$(printf '%s\n' "$mutex_record" | sed -n '1p')"
mutex_owner_identity="$(printf '%s\n' "$mutex_record" | sed -n '2p')"
mutex_generation="$(printf '%s\n' "$mutex_record" | sed -n '3p')"
mutex_extra="$(printf '%s\n' "$mutex_record" | sed -n '4p')"
case "$mutex_owner_pid" in ''|*[!0-9]*) collision invalid-owner "$@" ;; esac
case "$mutex_owner_identity" in "$mutex_owner_pid"'|'*) ;; *) collision invalid-owner "$@" ;; esac
case "$mutex_generation" in
  ????????????????????????????????) ;;
  *) collision invalid-owner "$@" ;;
esac
case "$mutex_generation" in *[!0-9a-f]*) collision invalid-owner "$@" ;; esac
[ -z "$mutex_extra" ] || collision invalid-owner "$@"

ancestor="$PPID"
owner_is_ancestor=0
ancestor_depth=0
while [ "$ancestor_depth" -lt 64 ]; do
  if [ "$ancestor" = "$mutex_owner_pid" ]; then owner_is_ancestor=1; break; fi
  case "$ancestor" in ''|0|1|*[!0-9]*) break ;; esac
  ancestor="$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')"
  ancestor_depth=$((ancestor_depth + 1))
done
[ "$owner_is_ancestor" -eq 1 ] || collision unprotected-owner "$@"
[ "$(cat "$mutex_owner_record" 2>/dev/null || true)" = "$mutex_record" ] \
  || collision changed-owner "$@"
transaction_owner="$mutex_owner_pid:$mutex_generation"

# Before provider release, the protected registry probe and worktree add belong
# to creation, not cleanup. They still must prove a live exact mutex generation,
# but they must not claim the cleanup sentinel.
if [ ! -e "$CODEX_STUB_RELEASE_DIR/.all" ]; then
  case "$phase" in list|add) ;; *) collision unexpected-creation-phase "$@" ;; esac
  printf 'creation\tcase=%s\towner=%s\tphase=%s\n' \
    "$SIX_CHILD_CASE_TAG" "$transaction_owner" "$phase" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  if "$SIX_CHILD_REAL_GIT" "$@"; then exit 0; else exit $?; fi
fi

# Cleanup now classifies the registry before removal. That first protected list
# establishes the exact-generation sentinel; remove, the post-remove list, and
# branch deletion must all remain in the same transaction.
case "$phase" in
  list)
    if [ ! -e "$sentinel" ]; then
      if ! mkdir "$sentinel" 2>/dev/null; then collision sentinel-overlap "$@"; fi
      chmod 700 "$sentinel"
      printf '%s\n' "$transaction_owner" >"$owner_file"
    else
      [ -f "$owner_file" ] || collision missing-sentinel "$@"
      [ "$(cat "$owner_file")" = "$transaction_owner" ] || collision changed-generation "$@"
    fi
    ;;
  remove|branch)
  [ -f "$owner_file" ] || collision missing-sentinel "$@"
  [ "$(cat "$owner_file")" = "$transaction_owner" ] || collision changed-generation "$@"
    ;;
  *) collision unexpected-cleanup-phase "$@" ;;
esac
printf 'critical\tcase=%s\towner=%s\tphase=%s\n' \
  "$SIX_CHILD_CASE_TAG" "$transaction_owner" "$phase" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"

# Case 3 launches one unrelated worktree-list probe after the first protected
# remove enters. Hold that generation until the probe records its fail-loud
# result, removing scheduler luck from the negative collision assertion.
if [ "$phase" = remove ] && [ "${SIX_CHILD_GIT_EXPECT_UNPROTECTED_PROBE:-0}" = 1 ]; then
  if [ ! -e "$SIX_CHILD_GIT_NEGATIVE_RESULT" ]; then
    python3 -I -B - "$0" "$SIX_CHILD_GIT_NEGATIVE_RESULT" "$PWD" <<'PY'
import os,pathlib,subprocess,sys,time
wrapper,result,cwd=sys.argv[1:]
first=os.fork()
if first:
    os.waitpid(first,0)
    raise SystemExit(0)
os.setsid()
second=os.fork()
if second:
    os._exit(0)
time.sleep(0.05)
devnull=os.open(os.devnull,os.O_RDWR)
for descriptor in (0,1,2):
    os.dup2(devnull,descriptor)
completed=subprocess.run([wrapper,"worktree","list","--porcelain"],cwd=cwd,env=os.environ)
pathlib.Path(result).write_text(f"rc={completed.returncode}\n")
os._exit(0)
PY
  fi
  tries=0
  while [ ! -s "$SIX_CHILD_GIT_NEGATIVE_RESULT" ] && [ "$tries" -lt 1000 ]; do
    tries=$((tries + 1))
    sleep 0.01
  done
  [ -s "$SIX_CHILD_GIT_NEGATIVE_RESULT" ] || collision negative-probe-timeout "$@"
fi

if "$SIX_CHILD_REAL_GIT" "$@"; then rc=0; else rc=$?; fi
if [ "$phase" = branch ]; then
  printf 'critical\tcase=%s\towner=%s\tphase=release\n' \
    "$SIX_CHILD_CASE_TAG" "$transaction_owner" >>"$SIX_CHILD_GIT_ARRIVAL_LOG"
  rm -f "$owner_file"
  rmdir "$sentinel"
fi
exit "$rc"
SH
cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
result=''
argv="$*"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ] && [ "$#" -ge 2 ]; then result="$2"; shift 2; continue; fi
  shift
done
test -n "$result"
agent_instance="${UBERDEV_AGENT_INSTANCE_ID:-${PRKIT_AGENT_INSTANCE_ID:-missing}}"
agent_status_file="${UBERDEV_AGENT_STATUS_FILE:-${PRKIT_AGENT_STATUS_FILE:-}}"
printf '%s\t%s\t%s\n' "$agent_instance" "$PWD" "$argv" >>"$CODEX_STUB_LOG"
if [ -n "${CODEX_STUB_PRE_READY_FAIL_INSTANCE:-}" ] \
    && [ "$agent_instance" = "$CODEX_STUB_PRE_READY_FAIL_INSTANCE" ]; then
  exit 42
fi
case "$agent_instance" in
  post-review-*-attempt01)
    if [ "$agent_instance" != "${CODEX_STUB_SKIP_READY_INSTANCE:-}" ]; then
      : >"$CODEX_STUB_READY_DIR/$agent_instance"
    fi
    while [ ! -e "$CODEX_STUB_RELEASE_DIR/.all" ]; do sleep .05; done
    ;;
esac
if [ -n "${CODEX_STUB_HANG_INSTANCE:-}" ] \
    && [ "$agent_instance" = "$CODEX_STUB_HANG_INSTANCE" ]; then
  while :; do sleep 1; done
fi
case "$agent_instance" in
  *caller-fix*)
    printf 'caller repair\n' >>README.md
    git add README.md
    git commit -qm 'fix: exercise caller repair edge'
    printf '%s\n' '```yaml' 'status: APPLIED' 'commits:' "  - sha: $(git rev-parse HEAD)" 'findings_disposition: []' 'risks: []' '```' >"$result"
    ;;
  *format-retry-valid-attempt01*)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
      'confidence: high' '```' >"$result"
    ;;
  *format-retry-invalid*)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings:' \
      '  - severity: blocker' '    location: tests/example.test.sh:1' \
      '    summary: contradictory fixture' '    detail: malformed on purpose' \
      'confidence: high' '```' >"$result"
    ;;
  *)
    printf '%s\n' '```yaml' 'verdict: APPROVE' 'findings: []' 'confidence: high' '```' >"$result"
    ;;
esac
stub_run_dir="$(dirname "$(dirname "$(dirname "$agent_status_file")")")"
while ! python3 -I -B - "$stub_run_dir" "$agent_status_file" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); expected=f"status_path={sys.argv[2]}"
for lease in root.glob('.agent-state-*/semaphore-v1/*.scope/*.lease'):
    try: lines=lease.read_text().splitlines()
    except OSError: continue
    if expected in lines and any(line.startswith('backend_identity=') and line!='backend_identity=' for line in lines):
        raise SystemExit(0)
raise SystemExit(1)
PY
do sleep .05; done
if [ -n "${CODEX_STUB_FAIL_INSTANCE:-}" ] \
  && [ "$agent_instance" = "$CODEX_STUB_FAIL_INSTANCE" ]; then
  exit 42
fi
exit 0
SH
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_STUB_LOG"
exit 97
SH
chmod +x "$TMP/bin/git" "$TMP/bin/codex" "$TMP/bin/claude"

cat >"$TMP/run-case.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case_name="$1"
repo="$2"
setup="$3"
post_setup="$4"
post_boundary="$5"
fail_instance="${6-}"
timeout_instance="${7-}"
skip_ready_instance="${8-}"
pre_ready_fail_instance="${9-}"
readiness_deadline_helper="${10}"
cd "$repo"
. "$setup"
. "$readiness_deadline_helper"

# These are immutable command-owned artifacts consumed by all six reviewer
# handoffs. changed_paths deliberately remains repository-relative, including
# at the provider boundary.
printf 'diff fixture\n' >"$DIFF_ARTIFACT_PATH"
printf 'review criteria\n' >"$CRITERIA_PATH"

# Run the production review-wave executable boundary itself. A deterministic
# provider barrier proves all six dispatches happen before the first wait.
mkdir -p "$CODEX_STUB_READY_DIR" "$CODEX_STUB_RELEASE_DIR"
(
  barrier_timeout="${REVIEW_BARRIER_TIMEOUT_OVERRIDE:-60}"
  startup_timeout="${REVIEW_BARRIER_STARTUP_TIMEOUT_OVERRIDE:-60}"
  lease_visibility_delay="${REVIEW_BARRIER_LEASE_VISIBILITY_DELAY_OVERRIDE:-0}"
  case "$barrier_timeout:$startup_timeout:$lease_visibility_delay" in
    *[!0-9:]*|0:*|*:0:*) exit 2 ;;
  esac
  barrier_release() { : >"$CODEX_STUB_RELEASE_DIR/.all"; }
  trap barrier_release EXIT
  barrier_started="$(date +%s)"
  barrier_deadline=$((barrier_started + startup_timeout))
  lease_visibility_deadline=$((barrier_started + lease_visibility_delay))
  fully_dispatched=0
  max_ready_count=0
  max_backend_bound_lease_count=0
  barrier_rc=0; barrier_reason=ready; ready_count=0
  raw_lease_count=0; backend_bound_lease_count=0; lease_scan_rc=0
  lease_scan_detail=''; barrier_detail=''
  while :; do
    ready_count="$(find "$CODEX_STUB_READY_DIR" -type f | wc -l | tr -d ' ')"
    if six_child_count_readiness_leases "$UBERDEV_CARRIER_RUN_DIR"; then
      lease_scan_rc=0
    else
      lease_scan_rc=$?
    fi
    barrier_now="$(date +%s)"
    # Deterministic case-4 regression fixture: model one backend identity whose
    # lease visibility reaches the coordinator late on a loaded macOS runner.
    if [ "$lease_visibility_delay" -gt 0 ] && [ "$barrier_now" -lt "$lease_visibility_deadline" ] \
        && [ "$backend_bound_lease_count" -eq 6 ]; then
      backend_bound_lease_count=5
    fi
    terminal=0
    while IFS= read -r status; do
      case "$status" in *.watcher-error.json) terminal=1; break ;; esac
      if grep -Eq '"state"[[:space:]]*:[[:space:]]*"(completed|failed|timed_out|cancelled)"' "$status"; then
        terminal=1; break
      fi
    done < <(find "$UBERDEV_CARRIER_RUN_DIR/children" -type f \
      \( -name status.json -o -name '*.watcher-error.json' \) 2>/dev/null)
    lifecycle="$UBERDEV_CARRIER_RUN_DIR/.agent-state-$(id -u)/agent-lifecycle.jsonl"
    if [ "$terminal" -eq 0 ] && [ -f "$lifecycle" ] && \
        grep -Eq '"event":"(failed|timed_out|cancelled|abandoned)".*"run_id":"post-review-' "$lifecycle"; then
      terminal=1
    fi
    # Production persists terminal evidence before releasing the exact lease.
    # Therefore a lease that disappears during this scan is expected only when
    # the terminal probes corroborate it; every uncorroborated scan error is a
    # coordinator failure rather than an unbound lease.
    six_child_resolve_readiness_preflight
    if [ "$readiness_preflight_rc" -ne 0 ]; then
      barrier_rc="$readiness_preflight_rc"
      barrier_reason="$readiness_preflight_reason"
      barrier_detail="$readiness_preflight_detail"
      break
    fi
    if six_child_update_readiness_deadline; then
      :
    else
      barrier_rc=$?
      [ "$barrier_rc" -eq 124 ] || {
        barrier_reason=coordinator-error
        barrier_detail=invalid-deadline-state
        break
      }
      barrier_rc=124; barrier_reason=readiness-timeout; break
    fi
    if [ "$ready_count" -eq 6 ] && [ "$backend_bound_lease_count" -eq 6 ]; then break; fi
    sleep .05
  done
  launch_count=0
  if [ -f "$CODEX_STUB_LOG" ]; then
    launch_count="$(wc -l <"$CODEX_STUB_LOG" | tr -d ' ')"
  fi
  printf 'rc=%s reason=%s ready=%s leases=%s raw_leases=%s bound_leases=%s launches=%s max_ready=%s max_bound_leases=%s detail=%s\n' \
    "$barrier_rc" "$barrier_reason" "$ready_count" "$backend_bound_lease_count" \
    "$raw_lease_count" "$backend_bound_lease_count" "$launch_count" \
    "$max_ready_count" "$max_backend_bound_lease_count" "${barrier_detail:-none}" \
    >"$CODEX_STUB_BARRIER_REPORT"
  exit "$barrier_rc"
) & readiness_coordinator=$!

CHANGED_PATHS_JSON='["README.md"]'
EMPHASIS_JSON='[]'
REVIEW_PR_TIMEOUT="${REVIEW_PR_TIMEOUT_OVERRIDE:-10}"
# The wave's per-child supervision decisions and the evidence gate's failure
# class are both assertion targets below, so both phases write their stderr to
# one file the shell fills synchronously: the initial wave (and therefore every
# `post_review_child_wait_failure` line) runs inside post-setup, the evidence
# gate inside the boundary.
#
# The file must not become a buffer that is only replayed once the phase
# returns. If the boundary ever hangs until CI's wall-clock kill, a replay that
# never runs loses exactly the diagnostics this fixture exists to surface, and
# watcher children inherit this stderr and keep writing after the phase is
# over. Stream the file into the job log for the whole case instead, so the
# assertions read complete bytes while the reader still sees them live.
POST_BOUNDARY_DIAGNOSTIC="$UBERDEV_TMPDIR/post-boundary-$case_name.stderr"
: >"$POST_BOUNDARY_DIAGNOSTIC"
tail -n +1 -f "$POST_BOUNDARY_DIAGNOSTIC" >&2 &
post_boundary_stream=$!
trap 'kill "$post_boundary_stream" 2>/dev/null || true' EXIT
set +e
{ . "$post_setup"; post_setup_rc=$?; } 2>>"$POST_BOUNDARY_DIAGNOSTIC"
if [ "$post_setup_rc" -eq 0 ]; then
  { . "$post_boundary"; post_setup_rc=$?; } 2>>"$POST_BOUNDARY_DIAGNOSTIC"
fi
set -e
if wait "$readiness_coordinator"; then readiness_rc=0; else readiness_rc=$?; fi

dump_git_mutation_diagnostics() {
  if [ -s "$SIX_CHILD_GIT_COLLISION_LOG" ]; then
    echo "git metadata collision log:" >&2
    cat "$SIX_CHILD_GIT_COLLISION_LOG" >&2
  fi
  if [ -d "$repo/.git/.uberdev-six-child-git-critical" ]; then
    echo "leaked git critical sentinel:" >&2
    ls -la "$repo/.git/.uberdev-six-child-git-critical" >&2
    [ ! -f "$repo/.git/.uberdev-six-child-git-critical/owner" ] \
      || cat "$repo/.git/.uberdev-six-child-git-critical/owner" >&2
  fi
  for mutex_owner in \
      "$repo"/.git/.uberdev-worktree-metadata-locks/semaphore-v1/*.scope/.mutex/owner_pid; do
    [ -f "$mutex_owner" ] || continue
    echo "live production mutex owner: $mutex_owner" >&2
    cat "$mutex_owner" >&2
  done
}

# One `instance<TAB>state` row per provider child this wave published.
child_terminal_states() {
  local status_file instance state
  for status_file in "$UBERDEV_CARRIER_RUN_DIR"/children/*/status.json; do
    [ -f "$status_file" ] || continue
    instance="$(basename "$(dirname "$status_file")")"
    state="$(jq -r '.state // "unset"' "$status_file" 2>/dev/null || printf 'unreadable')"
    printf '%s\t%s\n' "$instance" "$state"
  done
}

dump_child_terminal_states() {
  local instance state
  while IFS=$'\t' read -r instance state; do
    printf 'child terminal state: instance=%s state=%s\n' "$instance" "$state" >&2
  done < <(child_terminal_states)
}

# At most one of these is ever set: the single reviewer child this case breaks
# on purpose. Every other child must be supervised to completion.
deliberate_instance="$fail_instance$timeout_instance$pre_ready_fail_instance"

# The supervisor's own decision, recorded by the production wait boundary at the
# moment it abandoned a reviewer child. This — not the child's state afterwards
# — is the only race-free evidence that the harness's wall-clock budget, rather
# than the reviewer, is what removed a row from the validated ledger.
#
# A child abandoned mid-settle keeps whatever terminal state it published for
# itself, normally `completed`: the harness never got to write `timed_out`
# because the provider had already finished and only its lifecycle record or
# capacity lease was still landing. Gating on `state == timed_out` therefore
# catches only the subset where the provider was still running when the budget
# expired; the rest reach the operator as a bare `class=incomplete-roster`,
# shaped exactly like a genuine missing-evidence defect (#365).
abandoned_reviewer_children() {
  grep -F 'post_review_child_wait_failure ' "$POST_BOUNDARY_DIAGNOSTIC" 2>/dev/null || true
}

assert_no_unbudgeted_child_abandonment() {
  local line instance rc spurious=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    instance="${line##*instance=}"; instance="${instance%% *}"
    rc="${line##*rc=}"; rc="${rc%% *}"
    [ "$instance" != "$deliberate_instance" ] || continue
    spurious=1
    if [ "$rc" = 124 ] \
        || grep -Fq "child settle budget exhausted: instance=$instance" "$POST_BOUNDARY_DIAGNOSTIC"; then
      printf 'case=%s harness wait budget exhausted: instance=%s rc=%s budget=%ss; the provider was still settling when the fixture stopped waiting for it (fixture budget failure, NOT missing review evidence)\n' \
        "$case_name" "$instance" "$rc" "$REVIEW_PR_TIMEOUT" >&2
    else
      printf 'case=%s reviewer child abandoned outside the deliberate fault for this case: instance=%s rc=%s (supervision failure, NOT missing review evidence)\n' \
        "$case_name" "$instance" "$rc" >&2
    fi
  done < <(abandoned_reviewer_children)
  [ "$spurious" -eq 0 ]
}

# Independent cross-check for a child that was never waited on at all, so it
# leaves no supervision decision behind: only a deliberately hung provider may
# end in `timed_out`.
assert_no_unbudgeted_provider_timeout() {
  local instance state spurious=0
  while IFS=$'\t' read -r instance state; do
    [ "$state" = timed_out ] || continue
    [ "$instance" != "$timeout_instance" ] || continue
    spurious=1
    printf 'case=%s harness wait budget exhausted: instance=%s budget=%ss; the provider was still settling when the fixture killed it (fixture budget failure, NOT missing review evidence)\n' \
      "$case_name" "$instance" "$REVIEW_PR_TIMEOUT" >&2
  done < <(child_terminal_states)
  [ "$spurious" -eq 0 ]
}
supervision_breach=0
assert_no_unbudgeted_child_abandonment || supervision_breach=1
assert_no_unbudgeted_provider_timeout || supervision_breach=1
if [ "$supervision_breach" -ne 0 ]; then
  dump_child_terminal_states
  dump_git_mutation_diagnostics
  exit 1
fi

readiness_report="$(cat "$CODEX_STUB_BARRIER_REPORT" 2>/dev/null || printf 'missing report')"
unexpected_readiness() {
  printf 'case=%s unexpected readiness: rc=%s report=%s\n' \
    "$case_name" "$readiness_rc" "$readiness_report" >&2
  dump_git_mutation_diagnostics
  exit 1
}
if [ -n "$pre_ready_fail_instance" ]; then
  [ "$readiness_rc" -eq 70 ] || unexpected_readiness
  grep -Fq 'reason=terminal-before-readiness' "$CODEX_STUB_BARRIER_REPORT" \
    || unexpected_readiness
elif [ -n "$skip_ready_instance" ]; then
  [ "$readiness_rc" -eq 124 ] || unexpected_readiness
  grep -Fq 'reason=readiness-timeout ready=5 leases=6' "$CODEX_STUB_BARRIER_REPORT" \
    || unexpected_readiness
else
  [ "$readiness_rc" -eq 0 ] || unexpected_readiness
fi
if [ -n "$fail_instance$timeout_instance$pre_ready_fail_instance" ]; then
  if [ "$post_setup_rc" -ne 70 ]; then
    printf 'case=%s unexpected post-setup rc=%s expected=70\n' \
      "$case_name" "$post_setup_rc" >&2
    dump_child_terminal_states
    dump_git_mutation_diagnostics
    exit 1
  fi
  # This wave genuinely loses exactly one reviewer's evidence. The gate must
  # report that shortfall as an incomplete roster: classing a complete-but-short
  # ledger as `malformed-ledger` made a supervision failure indistinguishable
  # from ledger corruption (#365).
  if ! grep -Fq 'post_review_evidence_failure class=incomplete-roster' \
      "$POST_BOUNDARY_DIAGNOSTIC"; then
    printf 'case=%s incomplete wave did not report class=incomplete-roster\n' \
      "$case_name" >&2
    cat "$POST_BOUNDARY_DIAGNOSTIC" >&2
    dump_child_terminal_states
    exit 1
  fi
else
  if [ "$post_setup_rc" -ne 0 ]; then
    printf 'case=%s unexpected post-setup rc=%s expected=0\n' \
      "$case_name" "$post_setup_rc" >&2
    dump_child_terminal_states
    dump_git_mutation_diagnostics
    exit 1
  fi
fi

edges=(correctness silent_failures types comments tests general)
instances=(); results=(); statuses=()
while IFS= read -r row; do
  statuses+=("$(jq -r .status <<<"$row")")
  results+=("$(jq -r .result <<<"$row")")
  instance_path="$(jq -r .status <<<"$row")"
  instances+=("$(basename "$(dirname "$instance_path")")")
done <"$REVIEW_LAUNCHED"
[ "${#instances[@]}" -eq 6 ]

# A receipt/status pair may be internally consistent while naming a different
# valid backend. Evidence acceptance must stay bound to the carrier-selected
# backend, not merely to any member of the provider policy enum.
if [ "$case_name" = 1 ]; then
  wrong_backend="$(python3 -I -B - "$_UBERDEV_DISPATCH_BACKEND_ENUM" "$UBERDEV_CARRIER_BACKEND" <<'PY'
import sys
policy,expected=sys.argv[1:]
print(next(item for item in policy.split('|') if item not in {'auto',expected}),end='')
PY
)"
  wrong_backend_launched="$RESEARCH_DIR_ABS/post-review-wrong-backend.launched"
  wrong_backend_status_backup="$RESEARCH_DIR_ABS/post-review-wrong-backend.status.backup"
  wrong_backend_status="$(python3 -I -B - "$REVIEW_LAUNCHED" "$wrong_backend_launched" \
    "$wrong_backend_status_backup" "$UBERDEV_CARRIER_BACKEND" "$wrong_backend" <<'PY'
import json,os,pathlib,sys
source,target,backup,expected,replacement=sys.argv[1:]
rows=[json.loads(line) for line in pathlib.Path(source).read_text().splitlines() if line]
receipt=json.loads(rows[0]['receipt'])
assert receipt['backend']==expected and replacement!=expected
receipt['backend']=replacement
rows[0]['receipt']=json.dumps(receipt,sort_keys=True,separators=(',',':'))
target_path=pathlib.Path(target)
target_path.write_text(''.join(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n' for row in rows))
os.chmod(target_path,0o600)
status_path=pathlib.Path(rows[0]['status'])
status_bytes=status_path.read_bytes()
pathlib.Path(backup).write_bytes(status_bytes)
status=json.loads(status_bytes)
assert status['backend']==expected
status['backend']=replacement
status_path.write_text(json.dumps(status,sort_keys=True,separators=(',',':'))+'\n')
print(status_path,end='')
PY
)"
  set +e
  post_review_validated_evidence_complete "$RESEARCH_DIR_ABS/post-review.validated" \
    "$REVIEW_EXPECTED_COUNT" "$wrong_backend_launched" "$REPAIR_PREFIX.launched" \
    "$UBERDEV_CARRIER_RUN_DIR" >"$RESEARCH_DIR_ABS/wrong-backend.stdout" \
    2>"$RESEARCH_DIR_ABS/wrong-backend.stderr"
  wrong_backend_rc=$?
  set -e
  python3 -I -B - "$wrong_backend_status_backup" "$wrong_backend_status" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())
PY
  [ "$wrong_backend_rc" -eq 2 ]
  grep -Fq 'post_review_evidence_failure class=roster-mismatch edge=review_pr.review.correctness index=1' \
    "$RESEARCH_DIR_ABS/wrong-backend.stderr"

  # Evidence classes stay decision-grade only while they stay separable. A
  # ledger that was never written, one that is merely short a reviewer, and one
  # whose bytes are damaged each demand a different investigation; collapsing
  # them into `malformed-ledger` is what taught readers to re-run a suppressed
  # aggregate instead of read it (#365). Every probe must still fail closed.
  evidence_class_must_be() {
    local label="$1" ledger="$2" expected_class="$3" probe_rc
    set +e
    post_review_validated_evidence_complete "$ledger" "$REVIEW_EXPECTED_COUNT" \
      "$REVIEW_LAUNCHED" "$REPAIR_PREFIX.launched" "$UBERDEV_CARRIER_RUN_DIR" \
      >"$RESEARCH_DIR_ABS/$label.stdout" 2>"$RESEARCH_DIR_ABS/$label.stderr"
    probe_rc=$?
    set -e
    if [ "$probe_rc" -ne 2 ]; then
      printf 'evidence probe %s returned rc=%s expected=2 (fail-closed)\n' \
        "$label" "$probe_rc" >&2
      exit 1
    fi
    if ! grep -Fq "post_review_evidence_failure class=$expected_class" \
        "$RESEARCH_DIR_ABS/$label.stderr"; then
      printf 'evidence probe %s expected class=%s, got: %s\n' "$label" \
        "$expected_class" "$(cat "$RESEARCH_DIR_ABS/$label.stderr")" >&2
      exit 1
    fi
  }
  sed '$d' "$RESEARCH_DIR_ABS/post-review.validated" \
    >"$RESEARCH_DIR_ABS/short-roster.validated"
  evidence_class_must_be short-roster "$RESEARCH_DIR_ABS/short-roster.validated" \
    incomplete-roster
  : >"$RESEARCH_DIR_ABS/empty-roster.validated"
  evidence_class_must_be empty-roster "$RESEARCH_DIR_ABS/empty-roster.validated" \
    incomplete-roster
  evidence_class_must_be absent-ledger \
    "$RESEARCH_DIR_ABS/never-written.validated" ledger-absent
  {
    sed '$d' "$RESEARCH_DIR_ABS/post-review.validated"
    printf 'not-a-json-row\n'
  } >"$RESEARCH_DIR_ABS/damaged.validated"
  evidence_class_must_be damaged-ledger "$RESEARCH_DIR_ABS/damaged.validated" \
    malformed-ledger
fi

if [ -n "$timeout_instance" ]; then
  if [ "${REVIEW_WAIT_RC:-}" -ne 124 ]; then
    echo "production review timeout returned rc=${REVIEW_WAIT_RC:-missing}, expected 124" >&2
    dump_git_mutation_diagnostics
    while IFS= read -r timeout_row; do
      timeout_status="$(jq -r .status <<<"$timeout_row")"
      echo "$(jq -r .edge <<<"$timeout_row") state=$(jq -r .state "$timeout_status" 2>/dev/null || echo missing)" >&2
      [ ! -f "$timeout_status" ] || cat "$timeout_status" >&2
      timeout_log="$(jq -r '.log // empty' "$timeout_status" 2>/dev/null || true)"
      [ -z "$timeout_log" ] || [ ! -f "$timeout_log" ] || cat "$timeout_log" >&2
    done <"$REVIEW_LAUNCHED"
    exit 1
  fi
  [ "$(cat "$SIX_CHILD_GIT_NEGATIVE_RESULT" 2>/dev/null || true)" = 'rc=89' ] || {
    echo "unprotected Git probe did not fail loud as expected" >&2
    dump_git_mutation_diagnostics
    exit 1
  }
  timeout_index=-1
  for i in "${!instances[@]}"; do [ "${instances[$i]}" != "$timeout_instance" ] || timeout_index="$i"; done
  [ "$timeout_index" -ge 0 ] || { echo "timed-out instance missing from launch roster" >&2; exit 1; }
  timeout_state="$(jq -r .state "${statuses[$timeout_index]}")"
  [ "$timeout_state" = timed_out ] || { echo "timeout state was $timeout_state" >&2; exit 1; }
  ! kill -0 "$(jq -r .pid "${statuses[$timeout_index]}")" 2>/dev/null || {
    echo "timed-out provider remains live" >&2; exit 1;
  }
fi

# Dispatch one mutating repair through the same routed stack. It must advance
# the carrier-selected caller branch in place, without a disposable worktree,
# ownership receipt, or retained capacity lease.
FIX_FINDINGS="$RESEARCH_DIR_ABS/e2e-findings.md"
FIX_RANGE="$RESEARCH_DIR_ABS/e2e-commit-range.txt"
FIX_DISPOSITION="$RESEARCH_DIR_ABS/phase1-disposition.json"
python3 -I -B - <<'PY' \
  | python3 -I -B "$CODE_FIXER_CONTRACT" encode-aggregate --phase phase1 \
  >"$FIX_FINDINGS"
import json

contributors = []
for edge in (
    "review_pr.review.correctness",
    "review_pr.review.silent_failures",
    "review_pr.review.types",
    "review_pr.review.comments",
    "review_pr.review.tests",
    "review_pr.review.general",
):
    contributors.append({
        "confidence": "high",
        "id": edge,
        "verdict": "REVISIONS_REQUIRED" if edge == "review_pr.review.correctness" else "APPROVE",
    })
print(json.dumps({
    "contributors": contributors,
    "findings": [{
        "detail": "Exercise the caller-owned fixer boundary.",
        "scope": {"line": 1, "operation": "modify_existing", "path": "README.md"},
        "severity": "blocker",
        "source_edges": ["review_pr.review.correctness"],
        "summary": "Apply the bounded caller repair",
    }],
    "phase": "phase1",
    "schema_version": 2,
}, sort_keys=True, separators=(",", ":")))
PY
FIX_RANGE_BASE="$(git rev-parse HEAD^)"
FIX_RANGE_HEAD="$(git rev-parse HEAD)"
printf '%s..%s\n' "$FIX_RANGE_BASE" "$FIX_RANGE_HEAD" >"$FIX_RANGE"
: >"$FIX_DISPOSITION"
FIX_FINDINGS_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest \
  --path "$FIX_FINDINGS" --minimum 1 --maximum 16777216)"
FIX_RANGE_SHA256="$(python3 -I -B "$CODE_FIXER_CONTRACT" digest \
  --path "$FIX_RANGE" --minimum 1 --maximum 256)"
FIX_AUTHORITY_RECEIPT="$(python3 -I -B "$CODE_FIXER_CONTRACT" prepare-authority \
  --edge-id review_pr.fix.phase1 --policy-phase review_fix \
  --findings-path "$FIX_FINDINGS" --findings-sha256 "$FIX_FINDINGS_SHA256" \
  --commit-range-path "$FIX_RANGE" --commit-range-sha256 "$FIX_RANGE_SHA256" \
  --working-dir "$repo" --disposition-path "$FIX_DISPOSITION")"
FIX_AUTHORITY_PATH="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["authority_path"],end="")' "$FIX_AUTHORITY_RECEIPT")"
FIX_AUTHORITY_SHA256="$(python3 -I -B -c 'import json,sys; print(json.loads(sys.argv[1])["authority_sha256"],end="")' "$FIX_AUTHORITY_RECEIPT")"
repair_instance="review-pr-e2e-${case_name}-caller-fix-iter1-attempt01"
before_repair="$(git rev-parse HEAD)"
repair_inputs="$(uberdev_child_inputs_build review_pr.fix.phase1 \
  findings_path "$(review_json_string "$FIX_FINDINGS")" \
  findings_sha256 "$(review_json_string "$FIX_FINDINGS_SHA256")" \
  commit_range_path "$(review_json_string "$FIX_RANGE")" \
  commit_range_sha256 "$(review_json_string "$FIX_RANGE_SHA256")" \
  working_dir "$(review_json_string "$repo")" \
  pr_number "$PR_NUMBER" \
  disposition_path "$(review_json_string "$FIX_DISPOSITION")" \
  authority_path "$(review_json_string "$FIX_AUTHORITY_PATH")" \
  authority_sha256 "$(review_json_string "$FIX_AUTHORITY_SHA256")")"
uberdev_create_child_handoff review_pr.fix.phase1 "$repair_instance" "$repair_inputs" null >/dev/null
repair_result="$UBERDEV_CHILD_RESULT"
repair_status="$UBERDEV_CHILD_STATUS"
uberdev_preflight_child_batch "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256"
uberdev_dispatch_child review_pr.fix.phase1 "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" \
  "$repair_result" "$repair_status" >/dev/null
uberdev_wait_child "$repair_status" "$repair_result" 20
after_repair="$(git rev-parse HEAD)"
[ "$after_repair" != "$before_repair" ] || { echo "caller repair did not advance the branch" >&2; exit 1; }

python3 -I -B - "$UBERDEV_CARRIER_RUN_DIR" "$repo" "$CODEX_STUB_LOG" \
  "$CLAUDE_STUB_LOG" "${fail_instance:-$pre_ready_fail_instance}" "$timeout_instance" "$repair_instance" "$before_repair" "$after_repair" "${instances[@]}" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

run_dir = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
codex_log = pathlib.Path(sys.argv[3])
claude_log = pathlib.Path(sys.argv[4])
failed = sys.argv[5]
timed_out = sys.argv[6]
repair = sys.argv[7]
before_repair = sys.argv[8]
after_repair = sys.argv[9]
instances = sys.argv[10:]
assert len(instances) == len(set(instances)) == 6, instances
assert before_repair != after_repair
assert subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip() == after_repair

lines = codex_log.read_text().splitlines()
assert len(lines) == 7, lines
launches = [line.split("\t", 2) for line in lines]
assert {row[0] for row in launches} == set(instances) | {repair}, launches
review_launches = [row for row in launches if row[0] != repair]
repair_launches = [row for row in launches if row[0] == repair]
assert len({row[1] for row in review_launches}) == 6, review_launches
assert len(repair_launches) == 1 and pathlib.Path(repair_launches[0][1]).resolve() == repo.resolve(), repair_launches
assert all("--ask-for-approval never" in row[2] for row in launches), launches
assert all("permission-mode" not in row[2] and "dangerously-skip-permissions" not in row[2] for row in launches)
assert not claude_log.exists() or not claude_log.read_text(), claude_log.read_text()

statuses = []
worktrees = set()
branches = set()
child_logs = set()
for instance in instances:
    child = run_dir / "children" / instance
    handoff = json.loads((run_dir / "handoffs" / f"{instance}.json").read_text())
    assert handoff["instance_id"] == instance
    assert handoff["inputs"]["changed_paths"] == ["README.md"]
    status = json.loads((child / "status.json").read_text())
    statuses.append(status["state"])
    assert status["backend"] == "codex", status
    if instance == timed_out:
        assert status["state"] == "timed_out" and status["exit_code"] == 124, status
        continue
    worktrees.add(status["worktree"])
    branches.add(status["branch"])
    child_logs.add(status["log"])
    assert status["log"] == str(child / "status.json") + ".log", status
    assert pathlib.Path(status["log"]).is_file(), status["log"]
    worktree = pathlib.Path(status["worktree"])
    if not worktree.is_absolute():
        worktree = repo / worktree
    if worktree.exists():
        print(f"leaked child status: {json.dumps(status, sort_keys=True)}", file=sys.stderr)
        log = pathlib.Path(status["log"])
        if log.is_file():
            print(f"leaked child log ({log}):\n{log.read_text()}", file=sys.stderr)
        raise AssertionError(worktree)
    branch = status["branch"]
    probe = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        check=False,
    )
    assert probe.returncode != 0, branch

expected_workspace_records = 5 if timed_out else 6
assert len(worktrees) == len(branches) == len(child_logs) == expected_workspace_records, (worktrees, branches, child_logs)
assert not [path for path in (repo / ".claude" / "worktrees").glob("*") if path.exists()]
if failed:
    assert statuses.count("failed") == 1 and statuses.count("completed") == 5, statuses
elif timed_out:
    terminal = json.loads((run_dir / "children" / timed_out / "status.json").read_text())["state"]
    assert terminal == "timed_out", terminal
    assert statuses.count("completed") == 5, statuses
else:
    assert statuses == ["completed"] * 6, statuses

repair_child = run_dir / "children" / repair
repair_status = json.loads((repair_child / "status.json").read_text())
assert repair_status["state"] == "completed" and repair_status["workspace_mode"] == "caller", repair_status
assert pathlib.Path(repair_status["worktree"]).resolve() == repo.resolve(), repair_status
assert repair_status["branch"] == "", repair_status
assert not pathlib.Path(str(repair_child / "status.json") + ".worktree-owner.json").exists()

uid_fn = getattr(os, "geteuid", None)
state = run_dir / f".agent-state-{uid_fn() if uid_fn is not None else 0}"
leases = list((state / "semaphore-v1").rglob("*.lease"))
assert not leases, leases
events = [json.loads(line) for line in (state / "agent-lifecycle.jsonl").read_text().splitlines() if line]
terminals = [row for row in events if row.get("event") in {"completed", "failed", "timed_out", "cancelled", "abandoned"}]
assert len(terminals) == 7, terminals
assert {row["run_id"] for row in terminals} == set(instances) | {repair}, terminals
PY
if [ "${SIX_CHILD_GIT_MUTATION_STRESS:-0}" = 1 ]; then
  python3 -I -B - "$SIX_CHILD_GIT_ARRIVAL_LOG" "$SIX_CHILD_GIT_COLLISION_LOG" \
    "$SIX_CHILD_GIT_NEGATIVE_RESULT" "$case_name" <<'PY'
import collections,pathlib,re,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
case=sys.argv[4]
def fields(line):
 return dict(field.split("=",1) for field in line.split("\t")[1:])
pending_rows=[fields(line) for line in lines if line.startswith("pending\t")]
assert all(row.get("case")==case for row in pending_rows),pending_rows
pending=[row["owner"] for row in pending_rows]
assert len(pending)==len(set(pending))==6,pending
releases=[fields(line) for line in lines if line.startswith("barrier-release\t")]
assert len(releases)==1 and releases[0].get("case")==case,releases
# The selected timeout case deliberately releases the five non-timeout siblings
# before the timed-out sixth joins cleanup; keep that scheduling proof exact.
assert releases[0].get("count")=="5",releases

creation=collections.defaultdict(list)
events=collections.defaultdict(list)
for line in lines:
    if line.startswith("creation\t"):
        row=fields(line); assert row.get("case")==case,row
        creation[row["owner"]].append(row["phase"])
    elif line.startswith("critical\t"):
        row=fields(line); assert row.get("case")==case,row
        events[row["owner"]].append(row["phase"])
assert len(creation)==6,creation
assert all(phases==["list","add"] for phases in creation.values()),creation
assert len(events)==6,events
assert all(phases==["list","remove","list","branch","release"] for phases in events.values()),events
assert set(creation).isdisjoint(events),(creation,events)
assert all(re.fullmatch(r"[1-9][0-9]*:[0-9a-f]{32}",owner) for owner in events),events

collisions=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert len(collisions)==1,collisions
row=fields(collisions[0])
assert row.get("case")==case,row
assert row["reason"]=="unprotected-owner" and row["phase"]=="list",row
assert re.fullmatch(r"unprotected-pid:[1-9][0-9]*",row["owner"]),row
assert re.fullmatch(r"[1-9][0-9]*:[0-9a-f]{32}",row["actual"]),row
assert pathlib.Path(sys.argv[3]).read_text()=="rc=89\n"
PY
  [ ! -e "$repo/.git/.uberdev-six-child-git-critical" ]
elif [ -s "$SIX_CHILD_GIT_COLLISION_LOG" ]; then
  echo "concurrent git metadata mutations escaped dispatch serialization:" >&2
  cat "$SIX_CHILD_GIT_COLLISION_LOG" >&2
  exit 1
fi

# The canonical reviewer boundary drives the existing one-shot format-retry
# edge. A repaired result is accepted; two contradictory documents remain
# fail-closed instead of reaching aggregation.
if [ "$case_name" = 1 ]; then
format_retry_case() {
  local outcome="$1" edge=review_pr.review.correctness inputs first_instance repair_instance
  local first_result first_status repair_inputs repair_result repair_status
  inputs="$(uberdev_child_inputs_build "$edge" \
    changed_paths '["README.md"]' \
    diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
    criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]')"
  first_instance="review-pr-e2e-${case_name}-format-retry-${outcome}-attempt01"
  uberdev_create_child_handoff "$edge" "$first_instance" "$inputs" '[]' >/dev/null
  first_result="$UBERDEV_CHILD_RESULT"; first_status="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child "$edge" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" \
    "$first_result" "$first_status" >/dev/null
  uberdev_wait_child "$first_status" "$first_result" 20
  ! uberdev_child_validate_phase1_review_result "$first_result"

  repair_inputs="$(uberdev_child_inputs_format_retry "$edge" "$inputs" "$CRITERIA_PATH")"
  repair_instance="review-pr-e2e-${case_name}-format-retry-${outcome}-attempt02"
  uberdev_create_child_handoff "$edge" "$repair_instance" "$repair_inputs" '[]' >/dev/null
  repair_result="$UBERDEV_CHILD_RESULT"; repair_status="$UBERDEV_CHILD_STATUS"
  uberdev_dispatch_child "$edge" "$UBERDEV_CHILD_HANDOFF" "$UBERDEV_CHILD_HANDOFF_SHA256" \
    "$repair_result" "$repair_status" >/dev/null
  uberdev_wait_child "$repair_status" "$repair_result" 20
  if [ "$outcome" = valid ]; then
    uberdev_child_validate_phase1_review_result "$repair_result"
  else
    ! uberdev_child_validate_phase1_review_result "$repair_result"
  fi
}
format_retry_case valid
format_retry_case invalid

# Preflight a complete six-reviewer wave, then fail the third child before any
# provider handle is published. The caller unwinds the two already-launched
# siblings and proves the batch leaves no lease, worktree, branch, or owner
# receipt behind.
eval "$(declare -f _uberdev_agent_dispatch_backend | sed '1s/_uberdev_agent_dispatch_backend/_real_prehandle_dispatch_backend/')"
_uberdev_agent_dispatch_backend() {
  case "${UBERDEV_AGENT_INSTANCE_ID:-}" in
    *prehandle-types*) DISPATCH_ID=''; DISPATCH_RC=86; return 86 ;;
    *) _real_prehandle_dispatch_backend "$@" ;;
  esac
}
pre_handoffs=(); pre_handoff_sha256s=(); pre_results=(); pre_statuses=(); pre_instances=()
for lens in "${edges[@]}"; do
  edge="review_pr.review.$lens"
  instance="review-pr-e2e-${case_name}-prehandle-${lens}-attempt01"
  pre_instances+=("$instance")
  if [ "$lens" = general ]; then
    inputs="$(uberdev_child_inputs_build "$edge" changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]' lens '"general"')"
  else
    inputs="$(uberdev_child_inputs_build "$edge" changed_paths '["README.md"]' \
      diff_path "$(review_json_string "$DIFF_ARTIFACT_PATH")" \
      criteria_path "$(review_json_string "$CRITERIA_PATH")" emphasis '[]')"
  fi
  uberdev_create_child_handoff "$edge" "$instance" "$inputs" '[]' >/dev/null
  pre_handoffs+=("$UBERDEV_CHILD_HANDOFF")
  pre_handoff_sha256s+=("$UBERDEV_CHILD_HANDOFF_SHA256")
  pre_results+=("$UBERDEV_CHILD_RESULT"); pre_statuses+=("$UBERDEV_CHILD_STATUS")
done
preflight_refs=()
for i in "${!pre_handoffs[@]}"; do
  preflight_refs+=("${pre_handoffs[$i]}" "${pre_handoff_sha256s[$i]}")
done
uberdev_preflight_child_batch "${preflight_refs[@]}"
launched_count=0
for i in "${!edges[@]}"; do
  if uberdev_dispatch_child "review_pr.review.${edges[$i]}" \
      "${pre_handoffs[$i]}" "${pre_handoff_sha256s[$i]}" \
      "${pre_results[$i]}" "${pre_statuses[$i]}" >/dev/null; then
    launched_count=$((launched_count + 1))
    continue
  else
    prehandle_rc=$?
  fi
  [ "${edges[$i]}" = types ] && [ "$prehandle_rc" -eq 86 ]
  break
done
[ "$launched_count" -eq 2 ]
for ((i=0; i<launched_count; i++)); do
  uberdev_unwind_child "${pre_statuses[$i]}" "${pre_results[$i]}" 20
done
eval "$(declare -f _real_prehandle_dispatch_backend | sed '1s/_real_prehandle_dispatch_backend/_uberdev_agent_dispatch_backend/')"
python3 -I -B - "$UBERDEV_CARRIER_RUN_DIR" "$repo" "${pre_statuses[2]}" <<'PY'
import json,os,pathlib,subprocess,sys
run_dir=pathlib.Path(sys.argv[1]); repo=pathlib.Path(sys.argv[2]); failed_status=pathlib.Path(sys.argv[3])
# A provider failure before handle publication has no canonical provider status
# snapshot; its durable terminal evidence is the lifecycle manifest below.
assert not failed_status.exists(),failed_status
state=run_dir/f".agent-state-{os.geteuid() if hasattr(os,'geteuid') else 0}"
assert not list((state/"semaphore-v1").rglob("*.lease"))
assert not list(repo.rglob("*.worktree-owner.json"))
assert not [path for path in (repo/".claude/worktrees").glob("*") if path.exists()]
branches=subprocess.check_output(["git","-C",str(repo),"branch","--format=%(refname:short)"],text=True).splitlines()
assert not [branch for branch in branches if "prehandle-" in branch],branches
events=[json.loads(line) for line in (state/"agent-lifecycle.jsonl").read_text().splitlines() if line]
failed=[row for row in events if row.get("run_id","").endswith("prehandle-types-attempt01") and row.get("event")=="failed"]
assert len(failed)==1,failed
PY
fi

expected_provider_launches=7
if [ "$case_name" = 1 ]; then expected_provider_launches=13; fi
[ "$(wc -l <"$CODEX_STUB_LOG" | tr -d ' ')" -eq "$expected_provider_launches" ] || {
  echo "case $case_name launched an unexpected number of providers" >&2
  exit 1
}
SH
RUN_CASE_SCRIPT="$TMP/run-case.sh"
if [ "$RUNTIME_NAMESPACE" = prkit ]; then
  RUN_CASE_SCRIPT="$TMP/run-case-prkit.sh"
  sed -e 's/uberdev_/prkit_/g' -e 's/UBERDEV_/PRKIT_/g' \
    "$TMP/run-case.sh" >"$RUN_CASE_SCRIPT"
fi
chmod +x "$RUN_CASE_SCRIPT"

# Wall-clock hang guard, in seconds, for ONE reviewer child.
#
# The production wave dispatches all six providers before it waits on any of
# them, so the first child's budget starts ticking the moment the sixth
# dispatch returns and must still cover the entire post-release settle: this
# fixture's readiness coordinator releasing the provider barrier, the released
# provider exiting, its watcher publishing the terminal status.json plus
# lifecycle record, and the capacity lease being released. That settle was
# measured at ~9s for a six-provider wave on an idle Apple-silicon host and
# 23-26s under 6x runner contention, so the previous hardcoded 10s left under
# one second of local headroom and none at all on a loaded macOS runner: the
# first child was killed as `timed_out`, the wave dropped to five validated
# rows, and the evidence gate suppressed the aggregate (#365). This budget is a
# hang guard, never a performance assertion — only a genuinely stuck provider
# may consume it, which is why the deliberate-hang case pays it in full.
#
# Overridable so the budget-exhaustion diagnostics below stay exercisable
# without a source edit: starving the budget (`SIX_CHILD_PROVIDER_SETTLE_BUDGET=1`)
# must make the fixture fail with its own named budget class, never with a
# generic missing-evidence report.
SIX_CHILD_PROVIDER_SETTLE_BUDGET="${SIX_CHILD_PROVIDER_SETTLE_BUDGET:-60}"
case "$SIX_CHILD_PROVIDER_SETTLE_BUDGET" in
  ''|*[!0-9]*)
    echo "invalid SIX_CHILD_PROVIDER_SETTLE_BUDGET=$SIX_CHILD_PROVIDER_SETTLE_BUDGET" >&2
    exit 2
    ;;
esac
[ "$SIX_CHILD_PROVIDER_SETTLE_BUDGET" -gt 0 ] || {
  echo "invalid SIX_CHILD_PROVIDER_SETTLE_BUDGET=$SIX_CHILD_PROVIDER_SETTLE_BUDGET" >&2
  exit 2
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'fixture\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  printf 'reviewed change\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm 'test: add reviewed change'
}

run_case() {
  local name="$1" fail_instance="${2-}" timeout_instance="${3-}" skip_ready_instance="${4-}" pre_ready_fail_instance="${5-}"
  local repo runtime codex_log claude_log barrier_timeout=60 barrier_startup_timeout=60
  local lease_visibility_delay=0 review_timeout git_mutation_stress=0 expect_unprotected_probe=0
  local coordinator_release_bound=0
  repo="$TMP/repo-$name"; runtime="$TMP/runtime-$name"
  codex_log="$TMP/codex-$name.log"; claude_log="$TMP/claude-$name.log"
  make_repo "$repo"
  mkdir -p "$runtime" "$runtime/git-preacquire"
  ready_dir="$runtime/ready"; release_dir="$runtime/release"
  [ -z "$skip_ready_instance" ] || barrier_timeout=2
  if [ "$name" = 4 ]; then
    lease_visibility_delay=30
    # This case deliberately withholds one ready file, so the coordinator holds
    # every provider hostage until its OWN startup + barrier budget expires.
    # The child wait must outlive that release bound too; otherwise slow lease
    # visibility makes the harness time out its own providers before the
    # coordinator can release them (macOS CI #30404587111).
    coordinator_release_bound=$((barrier_startup_timeout + barrier_timeout))
  fi
  review_timeout=$((coordinator_release_bound + SIX_CHILD_PROVIDER_SETTLE_BUDGET))
  if [ "$name" = 3 ]; then
    git_mutation_stress=1
    expect_unprotected_probe=1
  fi
  printf 'case-start name=%s\n' "$name"
  env -i HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
    SIX_CHILD_REAL_GIT="$REAL_GIT" SIX_CHILD_GIT_COLLISION_LOG="$runtime/git-collisions.log" \
    SIX_CHILD_GIT_ARRIVAL_LOG="$runtime/git-arrivals.log" \
    SIX_CHILD_GIT_PREACQUIRE_DIR="$runtime/git-preacquire" \
    SIX_CHILD_GIT_MUTATION_STRESS="$git_mutation_stress" \
    SIX_CHILD_GIT_EXPECT_UNPROTECTED_PROBE="$expect_unprotected_probe" \
    SIX_CHILD_GIT_NEGATIVE_RESULT="$runtime/unprotected-probe.result" \
    SIX_CHILD_CASE_TAG="$name" \
    PLUGIN_ROOT="$RUNTIME_ROOT" WORKTREE_ROOT="$repo" \
    UBERDEV_TMPDIR="$runtime" PRKIT_TMPDIR="$runtime" \
    CODEX_STUB_LOG="$codex_log" CLAUDE_STUB_LOG="$claude_log" \
    CODEX_STUB_READY_DIR="$ready_dir" CODEX_STUB_RELEASE_DIR="$release_dir" \
    CODEX_STUB_BARRIER_REPORT="$runtime/readiness-report.txt" \
    CODEX_STUB_FAIL_INSTANCE="$fail_instance" CODEX_STUB_HANG_INSTANCE="$timeout_instance" \
    CODEX_STUB_SKIP_READY_INSTANCE="$skip_ready_instance" \
    CODEX_STUB_PRE_READY_FAIL_INSTANCE="$pre_ready_fail_instance" \
    REVIEW_BARRIER_TIMEOUT_OVERRIDE="$barrier_timeout" \
    REVIEW_BARRIER_STARTUP_TIMEOUT_OVERRIDE="$barrier_startup_timeout" \
    REVIEW_BARRIER_LEASE_VISIBILITY_DELAY_OVERRIDE="$lease_visibility_delay" \
    REVIEW_PR_TIMEOUT_OVERRIDE="$review_timeout" \
    RUN_ID="20260716-00000${name}-abcdef0" \
    PR_NUMBER=335 ARGUMENTS='' SOLVE_TIMEOUT=120 UBERDEV_AGENT_CAPACITY=6 PRKIT_AGENT_CAPACITY=6 \
    bash "$RUN_CASE_SCRIPT" "$name" "$repo" "$TMP/setup.sh" \
      "$TMP/post-setup.sh" "$TMP/post-boundary.sh" "$fail_instance" "$timeout_instance" \
      "$skip_ready_instance" "$pre_ready_fail_instance" "$TMP/readiness-deadline.sh"
  printf 'case-complete name=%s\n' "$name"
}

case "${SIX_CHILD_CASE:-all}" in
  1) run_case 1 ;;
  2) run_case 2 post-review-20260716-000002-abcdef0-r3-iter1-attempt01 ;;
  3) run_case 3 '' post-review-20260716-000003-abcdef0-r4-iter1-attempt01 ;;
  4) run_case 4 '' '' post-review-20260716-000004-abcdef0-r2-iter1-attempt01 ;;
  5) run_case 5 '' '' '' post-review-20260716-000005-abcdef0-r5-iter1-attempt01 ;;
  all)
    run_readiness_progress_deadline_regression
    run_case 1
    run_case 2 post-review-20260716-000002-abcdef0-r3-iter1-attempt01
    run_case 3 '' post-review-20260716-000003-abcdef0-r4-iter1-attempt01
    run_case 4 '' '' post-review-20260716-000004-abcdef0-r2-iter1-attempt01
    run_case 5 '' '' '' post-review-20260716-000005-abcdef0-r5-iter1-attempt01
    ;;
  *) echo "unknown SIX_CHILD_CASE=$SIX_CHILD_CASE" >&2; exit 2 ;;
esac

echo "review-pr Codex six-child integration tests passed"

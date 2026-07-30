#!/usr/bin/env bash
# tests/secret-scan.test.sh — behavioral lock for lib/secret-scan.sh regex-fallback
# grep exit-code handling (#189).
#
# `grep` is TRI-STATE and the three cases are NOT interchangeable:
#   0  -> one or more patterns matched -> secret found -> return 1 (fail-CLOSED)
#   1  -> no line matched              -> clean        -> return 0
#   >=2 -> grep itself failed (a malformed pattern, I/O error, …) -> the SCANNER
#         is broken, NOT a secret match. It must fail-CLOSED on a non-zero code
#         that is DISTINCT from the plain match code 1, and emit a diagnostic
#         that names the scanner failure (never a silent "clean" nor a false
#         "secret found"). A broken scanner must be distinguishable from a real
#         match.
#
# Pre-#189 the fallback was `if printf | grep …; then return 1; fi; return 0`,
# which returned 0 (clean) on grep rc=2 — a broken scanner reported clean, with
# no diagnostic (fail-OPEN). S3 is the regression that locks the fix.
#
# Runtime tests source the lib inside a bash -c subshell (mirrors the
# finish-branch.test.sh F6 idiom) and drive the function via the SKILL.md caller
# contract: SCAN_DIAG=$(… | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
set -u
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/uberdev"

PASS=0; FAIL=0
echo "## secret-scan grep rc tri-state suite (#189)"

# S1 — clean input (regex fallback grep no-match, rc=1) -> return 0.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s" "just a clean line of code" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 1
    ' ); then
  echo "  PASS  S1 clean input -> rc=0 (no secret)"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S1 clean input must return 0 (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S2 — genuine match (canonical AWS example key) -> return EXACTLY 1 via whichever
# layer fires first: gitleaks (rc=1, when installed) takes precedence, else the
# regex fallback (grep rc=0 -> return 1). Either way the result is 1 and the
# diagnostic is a real match, NOT a scanner-failure message. The key is assembled
# at runtime ("AKIA" + the rest) so this fixture file does not itself trip the
# secret scanner — the flaggable token never appears contiguously in the source,
# yet the full key still reaches the function at runtime.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      example_key="AKIA""IOSFODNN7EXAMPLE"
      SCAN_DIAG=$(printf "%s" "$example_key" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 1 ] || exit 1
      case "$SCAN_DIAG" in *"scanner failure"*) exit 2;; esac
    ' ); then
  echo "  PASS  S2 genuine match -> rc=1 (secret found), not a scanner-failure msg"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S2 genuine match must return exactly 1 and not be a scanner-failure msg (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S3 — scanner error: grep exits 2 on EVERY call (as a malformed future pattern
# would). The fallback MUST NOT silently pass NOR claim a secret. It must
# fail-CLOSED on a non-zero code DISTINCT from the plain match code 1, and emit a
# diagnostic that names the scanner failure (not "secret found"). This is the
# #189 regression lock.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      # Force every grep invocation to exit 2 (regex/I-O error). Shadows the
      # external grep only inside this subshell; the assertions below use case
      # (no grep) so they are unaffected by the shadow.
      grep() { return 2; }
      SCAN_DIAG=$(printf "%s" "plain text no secrets here" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      # (a) fail-CLOSED: must NOT be reported clean
      [ "$SCAN_RC" -ne 0 ] || exit 1
      # (b) distinct from a real match: must NOT be the plain match code 1
      [ "$SCAN_RC" -ne 1 ] || exit 2
      # (c) diagnostic names the scanner failure
      case "$SCAN_DIAG" in *"scanner failure"*) : ;; *) exit 3;; esac
      # (d) diagnostic surfaces the offending grep exit code
      case "$SCAN_DIAG" in *"grep exited"*) : ;; *) exit 4;; esac
      # (e) diagnostic must NOT falsely claim a secret was found
      case "$SCAN_DIAG" in *"secret found"*) exit 5;; esac
    ' ); then
  echo "  PASS  S3 grep rc>=2 -> distinct scanner-failure diagnostic + fail-CLOSED (not clean, not match)"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S3 scanner error must surface a distinct diagnostic and fail-CLOSED (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# S4-S7 — repo gitleaks config + line-level allowlist (#303).
#
# `gitleaks stdin` used to run with neither `--config` nor an inherited
# `GITLEAKS_CONFIG`, so a repo `.gitleaks.toml` allowlist was silently ignored
# and a false positive had NO escape hatch: the regex fallback fired regardless
# and the push aborted with no way to proceed short of editing the library.
#
# S4/S6 pin the two layers to ONE exemption token. The gitleaks stub below
# always exits 0 (i.e. "gitleaks says clean"), so those assertions are decided
# purely by the regex fallback and hold identically on a host with gitleaks
# installed and on CI where it is not — no conditional skips, no flake.
# ---------------------------------------------------------------------------
STUB_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
STUB_REPO="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUB_DIR" "$STUB_REPO"' EXIT INT TERM

cat > "$STUB_DIR/gitleaks" <<'STUB'
#!/usr/bin/env bash
# Records its argv, drains stdin, and reports CLEAN. Draining first keeps the
# producing `printf` from taking an EPIPE.
cat >/dev/null
if [ -n "${GITLEAKS_ARGV_FILE:-}" ]; then
  printf '%s\n' "$*" > "$GITLEAKS_ARGV_FILE"
fi
exit 0
STUB
chmod +x "$STUB_DIR/gitleaks"

# The canonical AWS example key is assembled at runtime so this fixture never
# carries the flaggable token contiguously (same rule as S2).
EXAMPLE_KEY_HEAD='AKIA'
EXAMPLE_KEY_TAIL='IOSFODNN7EXAMPLE'

# S4 — line-level allowlist: a marked line is exempt, the identical unmarked
# line still aborts. Both directions are asserted so the exemption cannot be
# "passing" because the scanner stopped detecting anything at all.
if ( PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     EXAMPLE_KEY="$EXAMPLE_KEY_HEAD$EXAMPLE_KEY_TAIL" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      [ -n "${UBERDEV_SECRET_SCAN_ALLOW_MARKER:-}" ] || exit 1
      marked="aws_key = \"$EXAMPLE_KEY\" # $UBERDEV_SECRET_SCAN_ALLOW_MARKER"
      SCAN_DIAG=$(printf "%s\n" "$marked" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 2
      plain="aws_key = \"$EXAMPLE_KEY\""
      SCAN_DIAG=$(printf "%s\n" "$plain" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 1 ] || exit 3
      # A marked line must not launder its NEIGHBOURS: an unmarked secret in the
      # same payload still aborts.
      SCAN_DIAG=$(printf "%s\n%s\n" "$marked" "$plain" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 1 ] || exit 4
    ' ); then
  echo "  PASS  S4 line-level allowlist exempts only the marked line"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S4 line-level allowlist contract broken (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S5 — the repo `.gitleaks.toml` reaches gitleaks as `--config`. Without this
# the repo's own allowlist was silently ignored.
git -C "$STUB_REPO" init -q 2>/dev/null || { echo "FATAL: git init failed" >&2; exit 2; }
printf '%s\n' 'title = "fixture"' > "$STUB_REPO/.gitleaks.toml"
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     GITLEAKS_ARGV_FILE="$STUB_DIR/argv-repo" bash -c '
      set -u
      unset GITLEAKS_CONFIG
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || exit 1
      [ -f "$GITLEAKS_ARGV_FILE" ] || exit 2
      argv=$(cat "$GITLEAKS_ARGV_FILE")
      grep -q -- "--config " <<<"$argv" || exit 3
      grep -q -- "/.gitleaks.toml" <<<"$argv" || exit 4
    ' ); then
  echo "  PASS  S5 repo .gitleaks.toml is passed to gitleaks as --config"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S5 repo .gitleaks.toml is not honoured (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S6 — $GITLEAKS_CONFIG is the operator override and outranks the repo file;
# with neither present no --config is invented (gitleaks keeps its defaults).
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      export GITLEAKS_CONFIG="$PWD/override.toml"
      export GITLEAKS_ARGV_FILE="$PWD/argv-override"
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || exit 1
      grep -qF -- "--config $GITLEAKS_CONFIG" "$GITLEAKS_ARGV_FILE" || exit 2
    ' ) \
   && ( mkdir -p "$STUB_DIR/norepo" && cd "$STUB_DIR/norepo" \
     && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        GITLEAKS_ARGV_FILE="$STUB_DIR/argv-none" \
        GIT_CEILING_DIRECTORIES="$STUB_DIR" bash -c '
      set -u
      unset GITLEAKS_CONFIG
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || exit 1
      [ -f "$GITLEAKS_ARGV_FILE" ] || exit 2
      grep -q -- "--config" "$GITLEAKS_ARGV_FILE" && exit 3
      exit 0
    ' ); then
  echo "  PASS  S6 GITLEAKS_CONFIG outranks the repo file; no config -> no --config"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S6 gitleaks config precedence broken (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S7 — every abort names the escape hatch. A fail-CLOSED scanner with an
# undiscoverable exemption is an unrecoverable stop for the caller.
if ( PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     EXAMPLE_KEY="$EXAMPLE_KEY_HEAD$EXAMPLE_KEY_TAIL" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "$EXAMPLE_KEY" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 1 ] || exit 1
      case "$SCAN_DIAG" in *"$UBERDEV_SECRET_SCAN_ALLOW_MARKER"*) : ;; *) exit 2;; esac
      case "$SCAN_DIAG" in *".gitleaks.toml"*) : ;; *) exit 3;; esac
      # The hint must not masquerade as a scanner failure (S3 distinguishes them).
      case "$SCAN_DIAG" in *"scanner failure"*) exit 4;; esac
    ' ); then
  echo "  PASS  S7 match diagnostic names the line marker and .gitleaks.toml"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S7 abort diagnostic does not name the escape hatch (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi

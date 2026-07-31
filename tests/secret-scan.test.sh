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
# S4-S12 — gitleaks ruleset governance + line-level allowlist (#303).
#
# `gitleaks stdin` used to run with neither an explicit `--config` nor an
# inspected one, so a repo `.gitleaks.toml` allowlist was ignored unless the
# caller happened to stand in the repo root, and a false positive had NO escape
# hatch: the regex fallback fired regardless and the push aborted with no way to
# proceed short of editing the library.
#
# The counterweight is that `--config` REPLACES gitleaks' built-in ruleset, so
# honouring a config naively turns the primary layer OFF for any repo that
# carries a rules-less `.gitleaks.toml` — and that file is itself part of the
# diff being scanned, so a leaking change could ship its own disarm. S5/S8/S9
# lock the resolution: a config may only ADD to the built-ins, never replace
# them, unless it declares `[extend] useDefault = true`.
#
# S4/S7 pin the two layers to ONE exemption token. The gitleaks stub below
# reports CLEAN by default (i.e. "gitleaks says clean"), so those assertions are
# decided purely by the regex fallback and hold identically on a host with
# gitleaks installed and on CI where it is not — no conditional skips, no flake.
# ---------------------------------------------------------------------------
STUB_DIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
STUB_REPO="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUB_DIR" "$STUB_REPO"' EXIT INT TERM

cat > "$STUB_DIR/gitleaks" <<'STUB'
#!/usr/bin/env bash
# Records its argv (APPEND — the library legitimately runs more than one pass)
# and the CONTENT of whatever config it was handed, drains stdin, and reports
# CLEAN. Draining first keeps the producing `printf` from taking an EPIPE.
#
#   GITLEAKS_STUB_RC                 force this exit code (crash simulation)
#   GITLEAKS_STUB_DETECT_ON_DEFAULT  report a MATCH when — and only when — the
#                                    resolved config extends the built-in
#                                    ruleset, i.e. simulate "the built-ins found
#                                    what the repo config could not see".
cat >/dev/null
stub_config=''
stub_prev=''
for stub_arg in "$@"; do
  [ "$stub_prev" = '--config' ] && stub_config="$stub_arg"
  stub_prev="$stub_arg"
done
if [ -n "${GITLEAKS_ARGV_FILE:-}" ]; then
  printf '%s\n' "$*" >> "$GITLEAKS_ARGV_FILE"
fi
if [ -n "${GITLEAKS_CONFIG_DUMP:-}" ] && [ -n "$stub_config" ] && [ -f "$stub_config" ]; then
  cat "$stub_config" >> "$GITLEAKS_CONFIG_DUMP"
fi
if [ -n "${GITLEAKS_STUB_RC:-}" ]; then
  printf 'stub: forced exit %s\n' "$GITLEAKS_STUB_RC" >&2
  exit "$GITLEAKS_STUB_RC"
fi
if [ -n "${GITLEAKS_STUB_DETECT_ON_DEFAULT:-}" ] && [ -n "$stub_config" ] \
   && [ -f "$stub_config" ] && grep -qi 'usedefault' "$stub_config"; then
  printf 'stub: built-in ruleset match\n'
  exit 1
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

# S5 — the repo `.gitleaks.toml` reaches gitleaks as `--config` (without this the
# repo's own allowlist was ignored unless the caller stood in the repo root),
# AND — because that config carries no rules and does not extend the built-ins —
# the clean verdict from it is NOT trusted on its own: a second pass runs with a
# config that pins gitleaks' built-in ruleset, and the downgrade is announced.
git -C "$STUB_REPO" init -q 2>/dev/null || { echo "FATAL: git init failed" >&2; exit 2; }
printf '%s\n' 'title = "fixture"' > "$STUB_REPO/.gitleaks.toml"
: > "$STUB_DIR/argv-repo"
: > "$STUB_DIR/dump-repo"
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     GITLEAKS_ARGV_FILE="$STUB_DIR/argv-repo" GITLEAKS_CONFIG_DUMP="$STUB_DIR/dump-repo" bash -c '
      set -u
      unset GITLEAKS_CONFIG
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 1
      [ -f "$GITLEAKS_ARGV_FILE" ] || exit 2
      argv=$(cat "$GITLEAKS_ARGV_FILE")
      grep -q -- "--config " <<<"$argv" || exit 3
      grep -q -- "/.gitleaks.toml" <<<"$argv" || exit 4
      # Exactly two passes: the repo config, then the built-in-ruleset floor.
      [ "$(grep -c -- "--config" "$GITLEAKS_ARGV_FILE")" -eq 2 ] || exit 5
      # The floor pass really is pinned to the built-ins.
      grep -qi "usedefault" "$GITLEAKS_CONFIG_DUMP" || exit 6
      # …and the operator is told why, by name.
      case "$SCAN_DIAG" in *".gitleaks.toml"*) : ;; *) exit 7;; esac
      case "$SCAN_DIAG" in *"useDefault"*) : ;; *) exit 8;; esac
    ' ); then
  echo "  PASS  S5 repo .gitleaks.toml is honoured but cannot replace the built-in ruleset"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S5 repo .gitleaks.toml resolution/floor contract broken (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S6 — $GITLEAKS_CONFIG is the operator override and outranks the repo file;
# with neither present the built-in ruleset is PINNED with an explicit --config
# rather than left to gitleaks' own resolution. That last part is not cosmetic:
# gitleaks binds $GITLEAKS_CONFIG natively and auto-discovers a `.gitleaks.toml`
# from the CURRENT WORKING DIRECTORY, so "pass no flag" means the ruleset that
# governed the scan is whatever the caller happened to be standing next to.
printf '[extend]\nuseDefault = true\n' > "$STUB_REPO/override.toml"
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -c '
      set -u
      export GITLEAKS_CONFIG="$PWD/override.toml"
      export GITLEAKS_ARGV_FILE="$PWD/argv-override"
      : > "$GITLEAKS_ARGV_FILE"
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || exit 1
      grep -qF -- "--config $GITLEAKS_CONFIG" "$GITLEAKS_ARGV_FILE" || exit 2
      grep -q -- "/.gitleaks.toml" "$GITLEAKS_ARGV_FILE" && exit 3
      exit 0
    ' ) \
   && ( mkdir -p "$STUB_DIR/norepo" && cd "$STUB_DIR/norepo" \
     && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        GITLEAKS_ARGV_FILE="$STUB_DIR/argv-none" \
        GITLEAKS_CONFIG_DUMP="$STUB_DIR/dump-none" \
        GIT_CEILING_DIRECTORIES="$STUB_DIR" bash -c '
      set -u
      unset GITLEAKS_CONFIG
      : > "$GITLEAKS_ARGV_FILE"
      : > "$GITLEAKS_CONFIG_DUMP"
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || exit 1
      [ -s "$GITLEAKS_ARGV_FILE" ] || exit 2
      grep -q -- "--config" "$GITLEAKS_ARGV_FILE" || exit 3
      grep -qi "usedefault" "$GITLEAKS_CONFIG_DUMP" || exit 4
      exit 0
    ' ); then
  echo "  PASS  S6 GITLEAKS_CONFIG outranks the repo file; no config -> built-ins pinned explicitly"; PASS=$((PASS+1))
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

# S8 — a rules-less repo `.gitleaks.toml` CANNOT disarm the primary layer. This
# is the fail-OPEN lock: `--config` replaces gitleaks' built-in ruleset, so a
# repo that merely contains a config with no rules would otherwise downgrade the
# primary scanner to nothing — and since that config is part of the very diff
# being scanned, a leaking change could ship its own disarm.
#
# The stub reports a match only when the config it received extends the
# built-ins, and the payload is deliberately invisible to the regex fallback, so
# the ONLY way this scan can come back non-clean is a genuine built-ins pass.
: > "$STUB_DIR/argv-disarm"
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     GITLEAKS_ARGV_FILE="$STUB_DIR/argv-disarm" GITLEAKS_STUB_DETECT_ON_DEFAULT=1 bash -c '
      set -u
      unset GITLEAKS_CONFIG
      printf "%s\n" "title = \"fixture\"" > "$PWD/.gitleaks.toml"
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "a line the regex fallback cannot see" \
        | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      # The built-ins pass found it -> a real match, not a scanner failure.
      [ "$SCAN_RC" -eq 1 ] || exit 1
      case "$SCAN_DIAG" in *"scanner failure"*) exit 2;; esac
      # Sanity: the same payload IS clean when the built-ins do not fire, so the
      # assertion above cannot be passing on an unconditional stub match.
      unset GITLEAKS_STUB_DETECT_ON_DEFAULT
      SCAN_RC=0
      printf "%s\n" "a line the regex fallback cannot see" \
        | uberdev_run_secret_scan_stdin >/dev/null 2>&1 || SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 3
    ' ); then
  echo "  PASS  S8 rules-less repo config cannot disarm the gitleaks layer"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S8 rules-less repo config still downgrades the primary scanner (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S9 — the counterpart: a config that DOES declare `[extend] useDefault = true`
# governs the whole scan on its own. Exactly one pass runs (no redundant
# re-scan) and no downgrade warning is emitted — so S5/S8 cannot be "passing"
# because the library blindly double-scans everything.
: > "$STUB_DIR/argv-extend"
if ( cd "$STUB_REPO" && PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     GITLEAKS_ARGV_FILE="$STUB_DIR/argv-extend" bash -c '
      set -u
      unset GITLEAKS_CONFIG
      printf "[extend]\nuseDefault = true\n" > "$PWD/.gitleaks.toml"
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -eq 0 ] || exit 1
      [ "$(grep -c -- "--config" "$GITLEAKS_ARGV_FILE")" -eq 1 ] || exit 2
      grep -q -- "/.gitleaks.toml" "$GITLEAKS_ARGV_FILE" || exit 3
      case "$SCAN_DIAG" in *"WARNING"*) exit 4;; esac
    ' ); then
  echo "  PASS  S9 a useDefault-declaring config governs the scan in a single pass"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S9 useDefault config handling broken (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi
printf '%s\n' 'title = "fixture"' > "$STUB_REPO/.gitleaks.toml"

# S10 — a CRASHED gitleaks must read as a broken scanner, never as a match. The
# allowlist hint is actively harmful advice here: following it strips the line
# from the regex fallback too (see the filter in the library), removing the
# SECOND layer while the first stays broken. S3 establishes this principle for
# the fallback grep; the gitleaks layer must obey it identically.
if ( PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" GITLEAKS_STUB_RC=2 bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -ne 0 ] || exit 1
      [ "$SCAN_RC" -ne 1 ] || exit 2
      case "$SCAN_DIAG" in *"scanner failure"*) : ;; *) exit 3;; esac
      case "$SCAN_DIAG" in *"gitleaks exited 2"*) : ;; *) exit 4;; esac
      # Must NOT tell the operator to allowlist a line that was never scanned.
      case "$SCAN_DIAG" in *"false positive"*) exit 5;; esac
    ' ); then
  echo "  PASS  S10 crashed gitleaks -> scanner-failure diagnostic, not the allowlist hint"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S10 crashed gitleaks is mis-reported (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S11 — a configured-but-MISSING ruleset fails CLOSED with a distinct
# diagnostic, decided BEFORE gitleaks runs. Leaving it to gitleaks is not good
# enough: gitleaks answers a missing `--config` with exit 1, which is
# byte-for-byte indistinguishable from "leak found", so the operator would be
# told to allowlist a line while the real cause is an unreadable config.
: > "$STUB_DIR/argv-missing"
if ( PATH="$STUB_DIR:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
     GITLEAKS_ARGV_FILE="$STUB_DIR/argv-missing" \
     GITLEAKS_CONFIG="$STUB_DIR/definitely-absent.toml" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      SCAN_DIAG=$(printf "%s\n" "clean line" | uberdev_run_secret_scan_stdin 2>&1 >/dev/null); SCAN_RC=$?
      [ "$SCAN_RC" -ge 2 ] || exit 1
      case "$SCAN_DIAG" in *"scanner failure"*) : ;; *) exit 2;; esac
      case "$SCAN_DIAG" in *"definitely-absent.toml"*) : ;; *) exit 3;; esac
      case "$SCAN_DIAG" in *"false positive"*) exit 4;; esac
      # Decided before the scanner ran at all.
      [ -s "$GITLEAKS_ARGV_FILE" ] && exit 5
      exit 0
    ' ); then
  echo "  PASS  S11 missing configured ruleset fails CLOSED before gitleaks runs"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S11 missing configured ruleset is not a distinct fail-CLOSED (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S12 — truth table for the useDefault detector itself. The whole floor rests on
# it, and it must be wrong only in the direction that costs an extra pass: a
# `useDefault` key OUTSIDE `[extend]` is ignored by gitleaks, so it must not be
# read as an extension here either.
if ( CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" TOML_DIR="$STUB_DIR" bash -c '
      set -u
      source "$CLAUDE_PLUGIN_ROOT/lib/secret-scan.sh" >/dev/null 2>&1 || exit 99
      d="$TOML_DIR/toml"; mkdir -p "$d"
      printf "[extend]\nuseDefault = true\n"              > "$d/plain.toml"
      printf "  [Extend]\r\n  UseDefault   =   true  # x\r\n" > "$d/messy.toml"
      printf "title = \"x\"\n"                            > "$d/rulesless.toml"
      printf "useDefault = true\n[extend]\n"              > "$d/outside.toml"
      printf "[[rules]]\nuseDefault = true\n"             > "$d/inrules.toml"
      printf "[extend]\nuseDefault = false\n"             > "$d/disabled.toml"
      _uberdev_secret_scan_config_extends_default "$d/plain.toml"     || exit 1
      _uberdev_secret_scan_config_extends_default "$d/messy.toml"     || exit 2
      _uberdev_secret_scan_config_extends_default "$d/rulesless.toml" && exit 3
      _uberdev_secret_scan_config_extends_default "$d/outside.toml"   && exit 4
      _uberdev_secret_scan_config_extends_default "$d/inrules.toml"   && exit 5
      _uberdev_secret_scan_config_extends_default "$d/disabled.toml"  && exit 6
      _uberdev_secret_scan_config_extends_default "$d/absent.toml"    && exit 7
      exit 0
    ' ); then
  echo "  PASS  S12 useDefault detector accepts only an in-[extend] true declaration"; PASS=$((PASS+1))
else
  rc=$?; echo "  FAIL  S12 useDefault detector truth table broken (sub-rc=$rc)"; FAIL=$((FAIL+1))
fi

# S13 — no library function may declare a local named after a zsh-TIED
# parameter. zsh ties `path` to `PATH`, `fpath` to `FPATH`, and so on, so
# `local path` empties the command search path for that whole function body and
# every external it calls (mktemp, tr, git, gitleaks) silently stops resolving.
# This library is sourced by the finish-branch fences, which run under /bin/zsh.
#
# bash has no such tie, so no bash suite — including every assertion above —
# can observe the breakage; this static check is the portable lock, and
# finish-branch-zsh.test.sh F6 is its behavioural counterpart.
SCAN_LIB="$PLUGIN_ROOT/lib/secret-scan.sh"
ZSH_TIED_HITS=''
for tied in path cdpath fpath manpath mailpath module_path psvar prompt status \
            argv options signals watch histchars fignore; do
  if grep -qE "^[[:space:]]*(local|typeset)([[:space:]]+[^[:space:]]+)*[[:space:]]+$tied([[:space:]=]|\$)" "$SCAN_LIB"; then
    ZSH_TIED_HITS="$ZSH_TIED_HITS $tied"
  fi
done
if [ -z "$ZSH_TIED_HITS" ]; then
  echo "  PASS  S13 no local shadows a zsh-tied parameter (PATH-clobber class)"; PASS=$((PASS+1))
else
  echo "  FAIL  S13 zsh-tied local(s) in lib/secret-scan.sh:$ZSH_TIED_HITS"; FAIL=$((FAIL+1))
fi

echo
echo "## Summary"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi

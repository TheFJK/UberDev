: << 'CMDBLOCK'
@echo off
REM Cross-platform polyglot wrapper for hook scripts.
REM On Windows: cmd.exe runs the batch portion, which finds and calls bash.
REM On Unix: the shell interprets this as a script (: is a no-op in bash).
REM
REM Hook scripts use extensionless filenames (e.g. "session-start" not
REM "session-start.sh") so Claude Code's Windows auto-detection -- which
REM prepends "bash" to any command containing .sh -- doesn't interfere.
REM
REM Usage: run-hook.cmd <script-name> [args...]

if "%~1"=="" (
    echo run-hook.cmd: missing script name >&2
    exit /b 1
)

set "HOOK_DIR=%~dp0"
set "HOOK_SCRIPT=%~1"

REM Forward every argument after the script name to bash, mirroring the Unix
REM arm's `exec bash ... "$@"` contract. The bare `%2 %3 ... %9` form was wrong
REM twice over: it dropped any 10th+ argument and re-split/mis-quoted args that
REM contain spaces. SHIFT past %1 (the script name) and accumulate the rest as
REM individually de-quoted-then-re-quoted tokens so each survives as one arg.
REM A goto-loop (not a parenthesised block) reads %HOOK_ARGS% fresh each pass,
REM so no delayed expansion is needed.
set "HOOK_ARGS="
shift
:collect_hook_args
if "%~1"=="" goto run_hook
set HOOK_ARGS=%HOOK_ARGS% "%~1"
shift
goto collect_hook_args

:run_hook
REM Try Git for Windows bash in standard locations
if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" "%HOOK_DIR%%HOOK_SCRIPT%"%HOOK_ARGS%
    exit /b %ERRORLEVEL%
)
if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOK_DIR%%HOOK_SCRIPT%"%HOOK_ARGS%
    exit /b %ERRORLEVEL%
)

REM Try bash on PATH (e.g. user-installed Git Bash, MSYS2, Cygwin)
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%HOOK_DIR%%HOOK_SCRIPT%"%HOOK_ARGS%
    exit /b %ERRORLEVEL%
)

REM No bash found - exit silently rather than error
REM (plugin still works, just without SessionStart context injection)
exit /b 0
CMDBLOCK

# Unix: run the named script directly
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$1"
shift
exec bash "${SCRIPT_DIR}/${SCRIPT_NAME}" "$@"

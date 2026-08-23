# Orchestrator — the Phase 2 visual companion

Reference for `skills/orchestrator/SKILL.md`, Phase 2. Interactive runs only — `--turbo` bypasses this whole flow and must never start the server. Read this before offering the browser companion; the consent wording, the signal test, and the threat model are all binding.

## The offer

**Visual companion (interactive only).** The brainstorm skill ships a browser-based visual companion (`skills/brainstorm/scripts/server.cjs` + `start-server.sh`, full protocol in `skills/brainstorm/visual-companion.md`). When `/solve` invokes the orchestrator instead of the brainstorm skill directly, Phase 2 inherits the same affordance — visual questions belong in the browser, conceptual questions in the terminal.

**When to offer.** At Phase 2 start, BEFORE the first clarifying question, if any of these visual signals fire:

- Research bundle (`research-codebase` / `research-patterns` summaries) mentions frontend/UI files: globs `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.css`, `*.scss`, OR directory names `components/`, `ui/`, `design/`, `screens/`, `pages/`, `views/`.
- Issue body contains visual keywords: `layout`, `design`, `mockup`, `screen`, `component`, `color`, `theme`, `look`, `feel`, `visual`, `wireframe`, `palette`, `typography`, `spacing`, `hierarchy`, `UI`, `UX`.

If neither signal fires, skip the offer entirely — proceed text-only.

**How to offer.** ONE message, on its own. Do NOT combine with a clarifying question. Verbatim text (mirrors `skills/brainstorm/SKILL.md:166`):

> Some of what we're working on might be easier to explain if I can show it to you in a web browser. I can put together mockups, diagrams, comparisons, and other visuals as we go. This feature is still new and can be token-intensive. Want to try it? (Requires opening a local URL)

Use `AskUserQuestion` with 2 options (`Yes` / `No`) so the consent is structurally captured. On `No`, proceed text-only — no further visual prompts in this Phase 2.

**Per-question decision.** Even after consent, decide PER QUESTION whether browser or terminal fits — the test is *would the user understand this better by seeing it than reading it?* Visual: UI mockups, layout comparisons, color/theme choices, architecture diagrams, spatial relationships. Terminal: scope/requirements, A/B/C text choices, tradeoff lists, technical decisions. The 3-5 Phase 2 questions may mix freely.

## Running it

**Starting the server (first visual question only).** Resolve the plugin scripts dir from the host-provided plugin-root variables, then invoke `start-server.sh`:

```bash
PLUGIN_SCRIPTS_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-}}}"
PLUGIN_SCRIPTS="${PLUGIN_SCRIPTS_ROOT:+$PLUGIN_SCRIPTS_ROOT/skills/brainstorm/scripts}"
if [[ -z "$PLUGIN_SCRIPTS_ROOT" ]]; then
  echo "uberdev plugin root unavailable (set PLUGIN_ROOT, CLAUDE_PLUGIN_ROOT, or CURSOR_PLUGIN_ROOT) — falling back to terminal-only Phase 2" >&2
  # continue without visual companion; AskUserQuestion path still works
elif [[ ! -d "$PLUGIN_SCRIPTS" ]]; then
  echo "uberdev brainstorm scripts not found — falling back to terminal-only Phase 2" >&2
  # continue without visual companion; AskUserQuestion path still works
else
  if SERVER_INFO="$("$PLUGIN_SCRIPTS/start-server.sh" --project-dir "$(git rev-parse --show-toplevel)")" \
     && URL="$(printf '%s' "$SERVER_INFO" | jq -er '.url')" \
     && SCREEN_DIR="$(printf '%s' "$SERVER_INFO" | jq -er '.screen_dir')" \
     && STATE_DIR="$(printf '%s' "$SERVER_INFO" | jq -er '.state_dir')"; then
    : # server up; URL / SCREEN_DIR / STATE_DIR set
  else
    echo "uberdev visual companion failed to start — falling back to terminal-only Phase 2 (server_info: ${SERVER_INFO:-<empty>})" >&2
    unset URL SCREEN_DIR STATE_DIR
  fi
fi
```

Tell the user the URL ONCE on first use. The server stays alive across turns — do NOT restart per question. Visual companion is enrichment, not a hard requirement: if resolution fails, log to stderr and degrade to terminal-only (do NOT abort Phase 2). If `URL` is unset after this block, the visual companion is unavailable for this Phase 2 run — skip all browser-path branches below and route every question through `AskUserQuestion`.

**The loop (browser path).** For each visual question: `Write` a semantic-named HTML content fragment (e.g. `q1-layout.html`, `q2-theme.html`, never reuse filenames) to `$SCREEN_DIR`, give a 1-2 sentence text summary ("Showing 3 layout options for the dashboard"), tell the user to *click an option, press LOCK IN, then switch back here and hit enter — any input even `.` works*, and end your turn. The plugin's `inject-brainstorm-answers` hook auto-prepends `<uberdev-brainstorm-answers>` to their next prompt with the locked-in `type:"submit"` event. Treat that block as authoritative — do NOT ask the user to repeat their choice in chat. Full protocol (CSS classes, frame template, event format, content-fragment vs full-document rule, design tips) lives in `skills/brainstorm/visual-companion.md`.

**Merging into `qa_answers`.** Whether the answer came from `AskUserQuestion` (terminal) or the `<uberdev-brainstorm-answers>` injection (browser), normalize into the same `qa_answers` shape that Phase 3 spec-writer consumes. Suggested fields: `{question, answer, source: "terminal" | "browser"}`. Browser-path authoritative answer is the `type:"submit"` event's `choice` (or full `selections[]` for multi-select); earlier `type:"click"` events are exploration signal only.

**Dispatching to `spec-writer`.** The structured `qa_answers` shape is orchestrator-internal bookkeeping; when dispatched to `spec-writer`, serialise to markdown bullets matching `agents/spec-writer.md:30`'s input contract (the `source` field is advisory and not consumed by spec-writer today).

**Unloading between visual and terminal questions.** When the next question is conceptual (terminal), `Write` a `waiting.html` (or `waiting-2.html`, etc.) fragment to `$SCREEN_DIR` BEFORE switching to `AskUserQuestion`, so the user does not stare at a stale resolved mockup. Verbatim fragment from the "Unload when returning to terminal" step of `skills/brainstorm/visual-companion.md`:

```html
<!-- filename: waiting.html (or waiting-2.html, etc.) -->
<div style="display:flex;align-items:center;justify-content:center;min-height:60vh">
  <p class="subtitle">Continuing in terminal...</p>
</div>
```

**Cleanup.** No explicit stop required — `server.cjs` auto-exits after 30 minutes of inactivity, and `--project-dir` mode persists mockups under `<repo>/.uberdev/brainstorm/<session-id>/` for later inspection. The `inject-brainstorm-answers` hook truncates `$STATE_DIR/events` after delivery, so answers are not replayed. If you want to free the port between Phase 2 and Phase 3, invoke `"$PLUGIN_SCRIPTS/stop-server.sh" "$(dirname "$STATE_DIR")"` — otherwise let it idle out.

**Turbo skip.** Visual companion is interactive-only. The `if [[ "$TURBO" == "1" ]]` branch below bypasses the entire flow — turbo synthesises `questions.md` from research without `AskUserQuestion` AND without `start-server.sh`. Do NOT invoke `start-server.sh` from a turbo-mode orchestrator run, even speculatively.

## Threat model

**Threat model.** Localhost-only bind, no auth, single-user assumption — see `skills/brainstorm/SKILL.md:206-214` for the full statement. Never override `--host` to a non-loopback interface (`0.0.0.0`, external IP) in CI/shared-host contexts. The orchestrator inherits the same trust model verbatim.

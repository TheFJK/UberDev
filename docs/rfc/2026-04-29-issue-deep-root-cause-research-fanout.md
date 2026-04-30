# RFC — `/uberdev:issue` Deep Root-Cause Research Fanout

> **Status update (2026-04-30):** Partially superseded by issue #14 — the 8-agent fanout at `/issue` creation is replaced by a 2-agent Sonnet fanout (`uberdev:codebase-scout` + `uberdev:triage-scout`). Solve-time research in `/uberdev:orchestrator` is unchanged and remains the deep-research engine for medium/large tier issues. See `docs/uberdev/specs/2026-04-30-slim-issue-2-sonnet-scouts-design.md`.

**Date:** 2026-04-29
**Status:** Partially superseded by #14 (was: Implemented v0.9.0)
**Issue:** #11

## Summary

Phase 2-4 of `/uberdev:issue` grows from 4 → 8 parallel research Task agents, adding `research-prior-art`, `research-constraints`, `research-security` (Semgrep + awesome-secure-defaults), and `research-test-coverage`. Issue templates gain `## Current ecosystem`, `## Constraints`, and conditional `## Security signals` sections.

## Motivation

The 4-agent fanout left blind spots in three areas: external prior art, hard architectural constraints from CLAUDE.md/RFC/ADR history, and security posture. Issues drafted without these surfaces produced spec/plan suggestions that ignored prior decisions or missed common vulnerability classes.

## Design

- 8-agent parallel dispatch in a single Task message (no Phase 2/3/4 sequencing — all run concurrently).
- `NO_EXPLORE=1` env var narrows fanout to in-repo only (skips web/Context7).
- Per-topic short-circuit against `.uberdev/research/issue-<N>/` cache mirrors the brainstorm pattern.

## Trade-offs

- Token usage scales linearly with fanout count; offset by Haiku 4.5 for detail agents.
- Wall-clock time bounded by slowest agent — security scan dominates when Semgrep runs on large codebases.

## See also

- `plugins/uberdev/commands/issue.md` for the dispatch implementation.
- `plugins/uberdev/skills/post-impl-review/SKILL.md` for the related per-wave reviewer fanout.

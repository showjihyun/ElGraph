# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## TDD (mandatory)

All changes to `apps/*/lib/` follow the Elixir TDD spec in `docs/TDD-SPEC.md`. Non-negotiable summary:

1. **Red first**: write a failing test before any implementation, run it (`mix test <file>:LINE --trace`), and confirm it fails for the intended reason — not a compile error.
2. **Green**: minimum code to pass, then run the **full suite** (`mix test`) to catch regressions.
3. **Refactor**: `mix format`, re-run full suite. Never leave a step with failing tests.
4. Report test results in detail: pass/fail counts and the actual assertion output on failures — never just "tests pass".
5. Bug fixes start with a test that reproduces the bug.
6. All tests `async: true`; pattern-matching assertions; public API only; no `Process.sleep`. Full rules and ElGraph-specific conventions (TestNodes MFA, event_sink, :telemetry_test): `docs/TDD-SPEC.md`.

Note: `mix` is not on PATH in pre-existing shells — prepend `$env:USERPROFILE\scoop\apps\elixir\current\bin` (see `docs/ENVIRONMENT.md`).

Note (umbrella): `mix test` from the repo root runs both apps. To run a single test file, `cd apps/<app>` first (`mix cmd --cd` fails to spawn `mix.bat` on Windows). Each app's tests run with the **app dir** as CWD — code that reads repo-root files (e.g. `docs/`) must resolve paths independent of CWD.

## Agent skills

### Issue tracker

GitHub Issues at showjihyun/Mousike, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical names (`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`CONTEXT.md` + `docs/adr/` at the repo root). See `docs/agents/domain.md`.

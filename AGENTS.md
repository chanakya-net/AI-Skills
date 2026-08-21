# AGENTS.md

Repo-level instructions for any agent working in this repository. Applies to Claude Code, Codex, Copilot, Gemini/Antigravity, and anything else reading `AGENTS.md`.

## What this repo is

An installable collection of agent skills plus the `run-with-it` orchestration runtime. The product is **markdown that a model executes**, not markdown a person reads. `skills/*/SKILL.md` and `assets/*.md` are source code; `tests/*.test.sh` are their contract tests.

## Editing agent-facing documents

Any change to `skills/*/SKILL.md`, `assets/*.md`, this file, or `CLAUDE.md` goes through the **`writing-agent-docs`** skill. Invoke it by name before the first edit — it carries the standard for context pointers, information hierarchy, completion criteria, leading words, and pruning, and its `SKILL-MECHANICS.md` branch carries frontmatter and the invocation choice.

Two rules bind every such edit, and both are failure modes this repo has already paid for.
They are stated here as well as in the skill because they must fire even when the skill is never invoked:

<!-- SYNC: the two rules below are intentionally duplicated from skills/writing-agent-docs/SKILL.md, which is authoritative. Edit both twins in the same commit — tests/skill-authoring-contract.test.sh asserts key tokens match. -->

1. **Grep `tests/` for the strings you are about to change.** The suite asserts exact substrings in exact files. Move the assertion in the same commit as the prose. A test asserting a deleted sentence is a red build; a behavioural rule with no assertion is unenforced.
2. **Respect the declared twins.** `skills/run-with-it/SKILL.md` ↔ `assets/main-orchestrator-rules.md` and `assets/sub-coordinator-prompt.md` ↔ `assets/coordinator-rules.md` are duplicated on purpose so the rules survive context compaction. Edit both halves together; `tests/markdown-contract-consistency.test.sh` asserts the shared tokens match.

## Editing human-facing documents

`README.md`, `docs/*.md`, PR bodies, and release notes are read by people. Apply [`docs/prose-checklist.md`](docs/prose-checklist.md) to those, and to nothing else. It never runs on `SKILL.md` or `assets/*.md`, where deterministic repetition is the contract the tests assert.

## Adding a skill

1. `skills/<name>/SKILL.md`, frontmatter `name` matching the directory and a `description` carrying trigger branches.
2. Mirror it into `.agents/skills/<name>/SKILL.md` for repo-local discovery by spec-compliant agents. `tools/sync-agent-skills.sh` does this and `tests/skill-authoring-contract.test.sh` asserts the mirror matches.
3. Supporting prompts and scripts under `assets/`.
4. A contract test under `tests/` asserting the boundaries the skill claims.
5. A row in the `README.md` skills table.

## Running tests

```bash
for test_file in tests/*.test.sh; do bash "$test_file"; done
```

Run the full suite before publishing. Prose changes break contract tests as readily as code changes do.

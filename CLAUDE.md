@AGENTS.md

## Claude Code

`AGENTS.md` above is the cross-agent entry point; Claude Code reads this file instead, so the import carries the same instructions rather than duplicating them.

- Invoke the `writing-agent-docs` skill by name before the first edit to any `skills/*/SKILL.md`, `assets/*.md`, `AGENTS.md`, or this file. The agent does not reliably reach it on its own for a change that looks like a one-line prose tweak, and prose here is what the contract tests assert.
- Use plan mode for changes under `assets/` — those prompts drive live multi-agent runs, and a wrong edit is discovered hours into a run rather than at the next test.

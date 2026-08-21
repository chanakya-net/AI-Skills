# Skill mechanics

The skill-specific branch of [`writing-agent-docs`](SKILL.md): what changes when the document is a skill. Frontmatter, the invocation choice, router skills, and how a skill in this repo reaches the shared `assets/` prompts. Everything else about writing it is the universal reference in `SKILL.md`.

Adapted from [mattpocock/skills](https://github.com/mattpocock/skills) `writing-for-agents` (MIT).

## Frontmatter

Every `SKILL.md` in `skills/<name>/` opens with YAML carrying two required keys:

| Key | Rule |
|-----|------|
| `name` | Matches the directory name exactly. The installer and `skills-lock.json` key off it. |
| `description` | The skill's top-level context pointer. Written for the model on a model-invoked skill, for the human on a user-invoked one. |

Keep the description on one logical line or a `>` folded block. Both parse; pick whichever reads better at the length you need.

## Invocation

Two choices, trading the two loads.

**Model-invoked** keeps a `description` in the agent's reach, so the agent can fire the skill autonomously and other skills can reach it. You can still type its name: model-invocation always *includes* user reach; a description only ever adds agent discovery, never removes yours. The description is forced to stay loaded at all times — permanent context load in exchange for discoverability. A model-invoked skill whose content is all reference is also one home for shared reference, since another skill can invoke it.

Mechanics: omit `disable-model-invocation`, and write a description carrying the trigger branches. The pointer-writing rules in `SKILL.md` apply in full.

**User-invoked** strips the description from the agent's reach: only you, typing its name, can invoke it, and no other skill can. Zero context load, but it spends cognitive load — you are the index that must remember it exists.

Mechanics: set `disable-model-invocation: true`; the `description` becomes human-facing, a one-line summary with trigger lists stripped.

Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load.

Shared reference that two user-invoked skills both need can live in neither: with no descriptions, neither can fire the other. Push it to a plain file under `assets/` — external reference any skill or prompt can point at.

### Which skills here are which

Every skill in this repo is model-invoked today, and each carries a real reason to be:

- `run-with-it`, `break-req`, `create-git-issue`, `tdd-implementation` chain into each other and are dispatched by the `assets/` worker prompts, so the agent must reach them without you.
- `save-tokens` and `tdd-implementation` are bootstrapped together by the `run-with-it` worker prompts.
- `help-me-debug` fires on a symptom the user reports rather than a name they type.
- `writing-agent-docs` fires when an agent edits a document in this repo, which is the moment it is needed and the moment nobody remembers to type it.

Before adding an eighth always-loaded description, check the skill against that bar. A skill only you ever invoke should be user-invoked.

## Splitting by invocation

The invocation cut of splitting; the sequence cut lives in `SKILL.md`.

Split off a model-invoked skill when you have a distinct leading word that should trigger it on its own — a trigger word you actually use in your prompts — or when another skill must reach it. You pay context load for the new always-loaded description, so that independent reach has to be worth it.

## Router skills

When user-invoked skills multiply past what you can remember, that piled-up cognitive load is cured by a **router skill**: one user-invoked skill naming the others and when to reach for each, so you have one skill to remember instead of many. It can only hint, never fire them: user-invoked skills have no description, so nothing but you can reach them.

This repo has no router yet, and does not need one at seven skills. The `README.md` skills table is doing that job for the human, and `AGENTS.md` is doing it for the agent.

## Reaching the shared assets

A skill in `skills/` and a prompt in `assets/` are the same kind of document with different delivery. The skill installs to the user's agent; the asset is read at runtime by a dispatched worker.

- A skill points at an asset by path (`assets/coordinator-rules.md`). That pointer follows every rule in `SKILL.md`: front-load the leading word, name the branches that should reach it.
- An asset never points back at a skill's internals. It may name a skill to invoke (`save-tokens`, `tdd-implementation`), which is host-native skill activation, not a document read.
- Where a rule must hold in both places after compaction, make it a declared twin — `<!-- SYNC: -->` comment plus a row in `tests/markdown-contract-consistency.test.sh`. See **Deliberate twins** in `SKILL.md`.

## Done when

- `name` matches the directory, and `description` matches the invocation choice.
- A model-invoked description carries trigger branches; a user-invoked one carries a summary and sets `disable-model-invocation: true`.
- The skill earns its invocation mode against the bar above.
- Pointers into `assets/` name their branches, and any cross-file rule is a declared twin.
- `tests/skill-authoring-contract.test.sh` passes.

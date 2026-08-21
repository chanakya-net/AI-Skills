---
name: writing-agent-docs
description: Repository-scoped authoring standard for agent instructions. Use when working in the `chanakya-net/Maestro-AI` repository (AI-Skills) and creating or changing a SKILL.md, an orchestration prompt under assets/, AGENTS.md, or CLAUDE.md.
---

## Skill Isolation

Sole active authority once invoked. Other skills run only when explicitly activated by name from this skill's own workflow or from the governing prompt that activated it (the `run-with-it` implementation and modifier prompts reach this skill that way when the assigned work edits agent-facing markdown). Suppress spontaneous third-party activations for the whole run, until explicit termination or handoff.

# Writing Agent Docs

## Purpose

Reference for every document in `chanakya-net/Maestro-AI` whose reader is a model: a `SKILL.md`, an orchestration prompt under `assets/`, `AGENTS.md`, or `CLAUDE.md`. The packaging differs; the writing does not. The same levers make each one predictable, because the agent takes the same *process* every run rather than producing the same output.

When the document is a skill, also read [`SKILL-MECHANICS.md`](SKILL-MECHANICS.md) for frontmatter, invocation choice, and router skills.

Adapted from [mattpocock/skills](https://github.com/mattpocock/skills) `writing-for-agents` (MIT).

## Context pointers

A **context pointer** is a reference held in the agent's context that names out-of-context material and encodes the condition for reaching it. A skill's `description` is one. A line in `AGENTS.md` naming a doc is the same object. So is a row in the sub-coordinator prompt naming an asset file.

The pointer's *wording*, not its target, decides when the agent reaches the material and how reliably. A must-have target behind a weakly worded pointer is a variance bug: sharpen the wording first, inline the material only if sharpening fails.

A pointer does two jobs: state what the material is, and list the **branches** that should trigger reaching it. A branch is a distinct case the document handles, so different runs take different paths through it. Every word of an always-loaded pointer costs on every turn, so it earns harder pruning than the body:

- **Front-load the leading word.** The pointer is where it does its triggering work.
- **One trigger per branch.** Synonyms renaming a single branch are one branch written twice. Collapse them; keep only genuinely distinct branches.
- **Cut identity the body already carries.**

A description that states only what a skill *is* ("Requirements discovery, dependency mapping, and technical constraint capture") gives the model nothing to match against. Add the branches that should fire it.

## The two loads

Every document and pointer spends one of two budgets:

- **Context load** is the cost of always-loaded material on the agent's window: a skill description, an `AGENTS.md` line, anything sitting in context every turn, spending tokens and attention whether or not it fires.
- **Cognitive load** is the cost on you: which documents exist and when to reach for each. You are the index. Not a cost to minimise — it is the price of human agency. Spend it where your judgement matters, remove it where it does not.

Material reached only through a pointer escapes context load at the price of the pointer's own line. Material with no pointer at all rides entirely on cognitive load.

## Information hierarchy

A document is built from two content types: **steps** (the ordered actions the agent performs) and **reference** (definitions, rules, facts consulted on demand). The two mix freely. `tdd-implementation` is nearly all steps; `coordinator-rules.md` is nearly all reference; `run-with-it` is both.

The core decision is where each piece sits on the **information hierarchy**, a ladder ranked by how immediately the agent needs the material:

1. **In-file step** — what the agent does, in order. The primary tier.
2. **In-file reference** — consulted on demand. Often a legitimately flat peer-set (every routing rule on one rung), which is a fine arrangement, not a smell.
3. **Disclosed reference** — pushed into a separate file, reached by a context pointer, loaded only when the pointer fires. Spans a sibling file in the same skill folder through a shared file under `assets/` that any prompt can point at.

Push too little down and the top bloats. Push too much and you hide material the agent needs. That tension is the whole decision.

**Progressive disclosure** is the move down the ladder so the top stays legible. Not primarily a token optimisation — it is how the hierarchy is protected. Branching is the cleanest disclosure test: inline what every branch needs, push behind a pointer what only some branches reach. When a document has steps, in-file reference that should be disclosed buries them and turns attending to them into a coin-flip.

**Co-location** is the within-file companion. Where the ladder decides *how far down* a piece sits, co-location decides *what sits beside it* once there. Keep a concept's definition, rules, and caveats under one heading rather than scattered, so reading one part brings its neighbours with it. Grouped material reads like documentation written for the agent; scattered material does not.

**Sprawl** is the failure mode here: a document simply too long, even when every line is live and unique. Attention thins across the excess, and every extra line is one more to keep relevant. The cure is the ladder: disclose reference behind pointers, and split by branch or sequence so each path carries only what it needs.

Guardrails that must survive context compaction are the exception. A rule the orchestrator has to obey after its memory is gone belongs inline and early, never behind a pointer — see **Deliberate twins** below.

## Steps and completion criteria

Every step ends on a **completion criterion**: the condition telling the agent the work is done. Two properties make it a lever.

**Clarity** — can the agent tell done from not-done? A vague bound ("understanding reached") invites **premature completion**: ending the step before it is genuinely done, attention slipping to *being done*. The visible steps still ahead supply the pull; the criterion's clarity is the resistance. Defend in order: sharpen the bound first (local and cheap); only if it is irreducibly fuzzy *and* you observe the rush, hide the later steps by splitting the sequence. Hiding works only across a real context boundary — a Sub-Coordinator dispatch clears context, inline skill activation does not.

**Demand** — how much it requires. "Every modified model accounted for" forces thorough work where "produce a change list" does not. Demand drives **legwork**: the digging the agent does within the work, latent in the wording rather than written as its own step. It is not step-bound. "Every routing rule applied" binds a body of flat reference just as "every step done" binds a sequence, which is how an all-reference document still carries an exhaustiveness bar.

The strongest criteria are both checkable and exhaustive. In this repo the checkable half often has a machine behind it — a done sentinel, a result artifact, a status event. Name it.

## When to split

Splitting one document into two spends one of the two loads, so split only when the cut earns it.

**By sequence** — split a run of steps where the post-completion steps tempt the agent to rush the one in front of it. Keeping them out of view drives more legwork on the current task. Beware the reverse: merging sequences exposes each step to what follows, inviting premature completion.

**By invocation** — skill-specific; see [`SKILL-MECHANICS.md`](SKILL-MECHANICS.md).

## Leading words

A **leading word** is a compact concept already living in the model's pretraining that the agent thinks with while running the document. This repo already owns several: *tracer bullet*, *rolling pool*, *twin*, *sentinel*, *vertical slice*, *red-green-refactor*. Repeated as a token, never as a sentence, a leading word accumulates a distributed definition and anchors a whole region of behaviour in the fewest tokens, by recruiting priors the model already holds.

Coining your own works if you define it clearly, but a made-up word recruits no priors: you pay in definition tokens what a pretrained word gives free. Reach for an existing word first.

It anchors twice. In the body, *execution*: the agent reaches for the same behaviour every time the word appears. In a pointer, *invocation*: when the same word lives in your prompts, your docs, and your code, the agent links that shared language to the material and reaches it more reliably.

Hunt for passages begging to collapse into a single token. A triad spelled out at three sites. A pointer spending a sentence to gesture at one idea.

- "fast, deterministic, low-overhead" → *tight* (a *tight* loop).
- "a loop you believe in" → *red*, turning a fuzzy gate into a binary observable state.

You win twice: fewer tokens, and a sharper hook for the agent to hang its thinking on.

**Negation** is the failure mode beside this lever. Steering by prohibition drags the forbidden behaviour into context and makes it *more* available, not less. The negation is a weak modifier the strongly-activated concept overruns, so the ban half-reads as an instruction to do the thing. Prompt the **positive**: state the target behaviour so the banned one is never spoken.

A prohibition earns its place only as a hard guardrail you cannot phrase positively — and this repo has real ones. "The Main Orchestrator never implements work directly" is load-bearing, because the positive form ("delegate all work to Sub-Coordinators") leaves the implement-here option unnamed and reachable. Keep those. Pair each with its positive target so attention lands on what to do, and convert the rest. A file where negations outnumber its steps is steering by prohibition, not by design.

## Pruning

- **Single source of truth.** Keep each meaning in one authoritative place, so changing the behaviour is a one-place edit. Duplication costs maintenance and tokens, and inflates a meaning's prominence on the ladder past its real rank. It is the accidental inverse of a leading word, which repeats a token on purpose, never the meaning.

- **Deliberate twins are the exception.** A rule that must survive context compaction lives in two files on purpose: `skills/run-with-it/SKILL.md` ↔ `assets/main-orchestrator-rules.md`, `assets/sub-coordinator-prompt.md` ↔ `assets/coordinator-rules.md`, and this file ↔ `AGENTS.md` for the two rules that must fire before this skill is ever invoked. A twin is legitimate only when it carries a `<!-- SYNC: -->` comment naming its partner and the authoritative copy, and a row in `tests/markdown-contract-consistency.test.sh` asserting the shared tokens match. Duplication without both of those is not a twin; it is drift waiting to happen.

- **The environment is a source of truth too** — `agent-registry.json`, the installer's flags, the directory layout, `--help` output. A document restating it is a **cache**: a copy of a lookup, earning its load only when the lookup is expensive. Cache what the agent cannot find by looking: the unwritten convention, the reason behind a choice, the gotcha no config confesses. Leave one-file, one-command lookups to the environment, where they cannot go stale.

- **Relevance.** Does each line still bear on what the document does? A line loses relevance by never bearing on the task, or by going stale as the behaviour it describes changes. Without a pruning discipline the default fate is **sediment**: stale layers settling because adding feels safe and removing feels risky.

- **No-ops.** Hunt them sentence by sentence: an instruction the model already obeys by default pays load to say nothing. The test — does it change behaviour versus the default? — is model-relative, not reader-relative. Two people disagreeing about a no-op disagree about the default, and settle it by running the document, not by debate. When a sentence fails, delete the whole sentence rather than trim words from it. The test also grades leading words: a word too weak to beat the default (*be thorough*, when the agent is already thorough-ish) is a no-op, and the fix is a stronger word (*relentless*), not a different technique.

## Contract tests are the completion criterion

This repo binds its agent docs with contract tests under `tests/`, which assert exact strings in exact files. That makes them the checkable half of a completion criterion for the document itself — and it makes every prose edit a code change.

- Before editing any `SKILL.md` or `assets/*.md`, grep `tests/` for the strings you are about to change.
- Move the assertion in the same commit as the prose. A test asserting a sentence that no longer exists is a red build; a sentence with no assertion behind it is an unguarded contract.
- When you add a behavioural rule that matters, add its assertion. The rule is not enforced until a test fails without it.

## Done when

- Every model-invoked description states what the material is and lists its trigger branches, one per branch.
- Reference only some branches reach sits behind a pointer; reference every branch needs is inline.
- Compaction-critical guardrails are inline and early, never disclosed.
- Every step ends on a criterion the agent can check, named against a real artifact where one exists.
- Each meaning has one authoritative home, or is a declared twin with a `<!-- SYNC: -->` comment and a consistency-test row.
- Prohibitions that survive are hard guardrails, each paired with its positive target.
- Every string the contract tests assert still exists, and every new behavioural rule has an assertion.

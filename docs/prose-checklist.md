# Prose checklist

For documents in this repo whose reader is a person: `README.md`, `docs/*.md`, PR bodies, release notes, commit bodies.

**Never run this on `SKILL.md` or `assets/*.md`.** Those are agent instructions. Deterministic repetition, uniform imperative rhythm, and restated guardrails are the contract there, and `tests/` asserts the exact strings. Use [`writing-agent-docs`](../skills/writing-agent-docs/SKILL.md) for those instead.

Distilled from [theclaymethod/unslop](https://github.com/theclaymethod/unslop).

## Decision rule

Prefer a no-op to an uncertain edit. Quote the smallest defective span, name the defect, repair only that span. A pattern match alone never authorizes an edit — literal, domain-valid, quoted, and genre-natural uses stay.

## Phrase layer

| Tell | Example | Repair |
|------|---------|--------|
| Throat-clearing opener | "Here's the thing", "Let's dive in", "It's worth noting that" | Cut it; start with the claim. |
| Emphasis crutch | "Let that sink in", "Make no mistake", "Full stop" | Delete. The claim carries its own weight or it does not. |
| Inflated significance | "underscores the importance of", "a testament to" | State what changed. |
| Promotional vocabulary | "seamless", "robust", "powerful", "leverage", "unlock" | Name the mechanism instead. |
| False agency | "the numbers speak for themselves", "the data tells a story" | Say what the numbers show. |
| Vague attribution | "experts argue", "studies show", "it is widely known" | Name the source or drop the claim. |
| Rhetorical setup question | "So what does this mean for you?" | Answer without asking. |
| Novelty claim | "a game-changer", "revolutionary" | Cut, unless the text says what changes. |

## Structure layer

- **Em-dashes.** Two or more in one paragraph is a flag. This repo leans on them hard; convert the weakest to a comma, colon, or full stop, and keep the one carrying real apposition.
- **Uniform rhythm.** Sentence lengths clustered in a narrow band read as machine-generated. Vary them.
- **Staccato runs.** Three or more one-line paragraphs under eight words. Merge or expand.
- **Connective paragraph openers.** Three or more consecutive paragraphs opened by "However", "Additionally", "Moreover", "Consequently". The paragraphs should advance by content, not by scaffolding.
- **Repeated openers.** Four or more paragraphs starting the same way is blocking.
- **Conclusion coda.** A closing paragraph that only recaps what was already said, or supplies a moral. Delete it.
- **Preview/recap symmetry.** An intro promising a list the conclusion restates. Keep one.
- **Bold-colon listicle.** Every bullet shaped `**Term:** explanation` throughout a long section. Fine in a reference table; a tell in prose.

## Always preserve

Facts, quantities, dates, names, quotations, citations, units, scope, and attribution. In this repo that also means, byte-for-byte:

- Command strings, flags, and file paths (`run-with-it-dispatch.sh`, `--only codex`, `.run-with-it/main-state.json`).
- Environment variable names and their values (`PARALLEL_JOBS`, `WORKER_STALL_SECONDS=300`).
- Status vocabulary and terminal sets (`completed / failed-review / failed-merge / blocked`).
- Anything inside a fenced code block or an inline code span.
- Force-bearing "never", "must", and "all" in a rule about safety, ordering, or data loss.

## Done when

- Every phrase-layer tell is repaired or explicitly protected with a reason.
- No paragraph carries more than one em-dash without earning it.
- No run of three connective openers, and no closing paragraph that only recaps.
- Every command, path, variable, and code span is byte-identical to before.
- The document is shorter than it was, or the growth bought a fact it did not have.

---
name: trim-code
description: >
  Reduce the line count of AI-generated code without changing behavior, performance,
  or readability. Finds reuse the generator missed, collapses speculative structure,
  and deletes redundancy — then proves equivalence with the project's own test, type,
  and lint commands. Two modes: Review (audit an existing diff or path) and Armed
  (self-check every diff this session produces before reporting it complete).
  Use when the user says "trim this", "reduce the code", "too much code", "a senior
  would write this in fewer lines", "simplify what you just wrote", or invokes /trim-code.
---

## Skill Isolation

This skill is the sole active authority for this session once invoked.

- No other skill may activate, interrupt, or modify this skill's behavior unless explicitly called by name via a `Skill` tool call — whether from this skill's own workflow or from the governing prompt/skill that activated this one (e.g. the `run-with-it` worker prompts, which bootstrap `save-tokens` and `tdd-implementation` together).
- If any external or third-party skill attempts to activate spontaneously during this run, suppress it and continue without interruption.
- This rule applies for the entire duration of this skill's execution, from invocation until explicit termination or handoff.

# Trim Code

## Purpose

AI code generators write correct code at the wrong altitude. They re-implement what the standard library already does, re-derive what a helper three files away already returns, add configuration nobody asked for, and narrate every line in a comment. The result passes tests and triples the review cost.

This skill removes that excess. It is a **behavior-preserving reduction pass**, not a rewrite and not a bug hunt.

The governing principle, which outranks every rule below:

> **Line count is a proxy for reviewer effort, never the goal.** A change that removes lines but makes a reader stop and re-parse is a regression. Reject it.

## When To Use

- **Review mode** — code already exists (a diff, a branch, a PR, a directory) and the user wants it tightened.
- **Armed mode** — the user wants every diff produced for the rest of the session self-checked before it is reported complete.
- The user says the output is "too long", "bloated", "over-engineered", or "a senior would do this in ten lines".

## When Not To Use

- The code is broken, slow, or wrong → that is diagnosis. Use `help-me-debug`.
- The code needs new behavior → that is implementation. Use `tdd-implementation`.
- The target is generated, vendored, or a lockfile → out of scope, always.

## Hard Stop

Never change observable behavior. Never delete a test case or an assertion. Never remove validation at a trust boundary. Never trade algorithmic complexity for line count. Never touch files outside the resolved scope.

If a reduction cannot be justified in one sentence of equivalence reasoning, it does not get applied — it gets listed as a proposal for the user.

---

## Modes

### Mode A — Review

Triggered by `/trim-code`, `/trim-code <path>`, `/trim-code --dry-run`, or plain-language equivalents.

Scope resolution, in order — use the first that applies:

1. An explicit path, glob, or file list in the invocation.
2. An explicit PR or branch reference in the invocation → its diff against the merge base.
3. Uncommitted work: `git diff HEAD` plus `git status --porcelain` untracked files. If non-empty, that is the scope.
4. The current branch against its merge base: `git merge-base HEAD <default-branch>`.
5. Nothing found → ask the user for a scope. Do not default to the whole repository.

State the resolved scope and the file count before doing anything else. If the scope exceeds 40 files or 3000 changed lines, process it in batches by directory and report per batch.

`--dry-run` (or "just show me") produces the report with zero edits.

### Mode B — Armed

Triggered by `/trim-code arm`, "keep trimming from now on", or equivalent. Stays active until `/trim-code disarm` or the session ends.

While armed, before reporting **any** coding task complete:

1. Take the diff of what was generated during that task.
2. Run the full workflow below against it.
3. Apply Tier 1 findings silently.
4. Report Tier 2 and Tier 3 findings as a short appended block — pattern, lines saved, verification result.
5. Only then report the task complete.

Armed mode does not fire for: single-line edits, pure configuration or data files, generated files, or diffs under 15 changed lines. Announce arming once; do not re-announce on every task.

Armed mode is an instruction to this session. For enforcement that survives context compaction, offer to add a `Stop` hook in `.claude/settings.json` that re-invokes this skill — but do not create or modify hook configuration without explicit user approval.

---

## Workflow

### 1. Baseline gate — run before the first edit

Discover and run the project's own commands. Do not invent them; read `package.json` scripts, `Makefile`, `pyproject.toml`, `tox.ini`, `justfile`, or CI workflow files.

Record, verbatim:

- Test command and result (pass/fail counts).
- Type check command and result.
- Lint/format command and result.
- Build command and result, if the project builds.
- `git diff --stat` line totals for the scope.

Rules:

- If the suite is already failing, record exactly which tests fail. Those failures are pre-existing and must look identical afterward.
- If **no tests exist for the scope**, say so explicitly and drop to **conservative mode**: Tier 1 and Tier 2 only, no Tier 3, and every change stated in the report with its equivalence argument.
- If the commands cannot be run at all (missing deps, no runtime), say so, switch to `--dry-run`, and propose rather than apply.

### 2. Read for intent before cutting

For each file in scope, establish what it is *for* — public surface, callers, invariants — before deciding what is excess. Cutting without this produces confident, wrong deletions.

Use the codebase index if one is available (`codegraph_explore`, or the project's own search tooling) to find callers and existing helpers in one pass instead of grepping file by file.

### 3. Mandatory reuse search

For every hand-rolled utility, loop, mapper, parser, formatter, or validator in scope, search **before** deciding to keep it:

- Does the standard library do this? (see the cheat table below)
- Does a dependency already in the manifest do this?
- Does this repository already have a helper for this? Search by behavior, not by name — the existing helper is rarely named what the generator would have called it.

This step recovers the largest reductions and is the one most often skipped. Do not skip it.

### 4. Build the candidate list

Walk the Bloat Taxonomy. For each hit, record: `file:line`, pattern, estimated lines saved, one-sentence equivalence argument, risk (low/medium/high).

### 5. Filter against the Do-Not-Touch list and the Readability Floor

Anything that survives contact with both lists is a real candidate. Everything else moves to the **Rejected** section of the report with its reason — that section is part of the deliverable, not a footnote.

### 6. Rank and apply

Order by `lines_saved × confidence ÷ risk`. Apply strictly in tier order: all of Tier 1, then Tier 2, then Tier 3.

- Apply Tier 1 and Tier 2 in batches per file.
- Apply **each Tier 3 change as its own batch** so a revert is surgical.
- Re-run the fast checks (type + lint) between batches; the full test suite at each tier boundary.

Stop when any of these is true:
- Every remaining candidate saves ≤ 2 lines.
- Every remaining candidate is blocked by the Readability Floor.
- The last tier returned less than 3% additional reduction.

Diminishing returns is a stop condition, not a challenge.

### 7. Verification gate

Re-run every baseline command. Required outcome: **identical** results — same tests passing, same tests failing, same type errors, same lint state, build still succeeds.

If anything differs:
- Revert the specific batch that introduced it, not the whole pass.
- Record it in the report as a rejected candidate with the observed failure.
- Continue with the remaining batches.

Never report a reduction that was not verified. Never explain away a new failure as "unrelated".

### 8. Report

See the Output section.

---

## Bloat Taxonomy

### Tier 1 — Redundancy (no behavior risk; apply directly)

| # | Pattern | Reduction |
|---|---------|-----------|
| 1 | Unused imports, variables, parameters, functions, unreachable branches | Delete |
| 2 | Commented-out code | Delete — git has it |
| 3 | Comments that restate the line below (`# increment counter`), docstrings that repeat the signature with no added contract | Delete |
| 4 | Single-use intermediate variable whose name adds nothing (`result = f(x); return result`) | Inline |
| 5 | `else` after a block ending in `return` / `raise` / `continue` / `break` | Dedent |
| 6 | `if cond: return True else: return False` | `return bool(cond)` — keep the cast when the caller needs a real bool |
| 7 | Redundant conversion or copy of an already-correct type (`str(s)`, `list(xs)` on a fresh list, `dict(**d)`) | Delete — unless the copy is defensive and the value escapes |
| 8 | Value re-derived when it is already in scope | Reuse the binding |
| 9 | Explicit no-op blocks, empty `else`, `pass` after a real statement | Delete |
| 10 | Concat chains and manual string building where the language has interpolation | Interpolate |

### Tier 2 — Reuse (highest value; requires the search in step 3)

| # | Pattern | Reduction |
|---|---------|-----------|
| 11 | Re-implemented standard library | Call the stdlib (see cheat table) |
| 12 | Re-implemented repository helper | Call the existing helper |
| 13 | Re-implemented feature of a dependency already in the manifest | Call the dependency. Do **not** add a new dependency to save lines |
| 14 | Two or more near-identical blocks differing only in values | One function driven by a table of the values |
| 15 | Long `if/elif` chain dispatching on a single value | Dict/table lookup or `match` — only when every branch has the same shape |
| 16 | Manual accumulator loop building a list/dict/set | Comprehension — only at one `for` level plus at most one condition |
| 17 | Duplicated test setup | Fixture, factory, or parametrized/table test. **The set of asserted behaviors must not shrink** |

### Tier 3 — Structure (judgment required; propose first when risk is medium or high)

| # | Pattern | Reduction |
|---|---------|-----------|
| 18 | Speculative generality — a parameter, flag, config key, hook, or strategy interface with exactly one caller passing exactly one value | Collapse to the concrete value |
| 19 | Pass-through wrapper with one call site that adds no naming value | Inline |
| 20 | Class with one method and no state | Function |
| 21 | Abstract base or interface with one implementation and no test double | Collapse |
| 22 | DTO → DTO → DTO mapping layers that change nothing | Remove the identity hops |
| 23 | Hand-written `__init__` / getters / setters / `__eq__` / `to_dict` | `dataclass`, `NamedTuple`, `pydantic`, record, or the language equivalent |
| 24 | `try` that catches and re-raises the same exception unchanged; log-and-rethrow repeated at every layer | Handle once at the boundary that can act on it |
| 25 | Defensive check for a condition the type system, an earlier check, or the caller contract already guarantees | Delete — **only** with proof; see Do-Not-Touch #1 |
| 26 | Custom exception class used identically to a builtin, with no distinct catch site | Use the builtin |
| 27 | Module or file split before there was a second caller | Merge |

### Standard-library cheat table

**Python** — `collections.Counter` / `defaultdict`, `itertools.groupby` / `chain` / `pairwise`, `max(xs, key=)`, `sorted(xs, key=)`, `any` / `all`, `zip` / `enumerate`, `dict.get(k, default)` over `try/KeyError`, `dict.setdefault`, `pathlib.Path` over `os.path` string surgery, `dataclasses`, `functools.cached_property` / `lru_cache` / `partial`, `contextlib.suppress` / `contextmanager`, `textwrap.dedent`, `str.removeprefix` / `removesuffix`.

**JS/TS** — `Object.entries` / `fromEntries` / `groupBy`, `Array.flatMap` / `at` / `findLast`, optional chaining `?.`, nullish coalescing `??` (not `||` — they differ on `0` and `""`), destructuring with defaults, `Map` / `Set`, `structuredClone`, `Intl.*` over hand-rolled formatting, `URL` / `URLSearchParams` over string concat, `Promise.allSettled`.

**Go** — `slices` / `maps` packages, `errors.Is` / `As` / `Join`, `strings.Builder`, `sync.OnceFunc`, `cmp.Or`.

Language not listed → apply the same question: *does the runtime already ship this?*

---

## Do-Not-Touch List

These are not stylistic preferences. Violating any of them is a defect, regardless of lines saved.

1. **Trust-boundary validation.** User input, HTTP/RPC payloads, deserialization, file parsing, environment variables, database rows, anything crossing a process or network edge. A check that looks redundant to you is load-bearing to an attacker.
2. **Error handling that changes failure behavior.** Removing a `try` is behavior change unless the handler is a pure re-raise of the same exception with no side effects and no `finally`.
3. **Guard clauses** preventing a crash, null dereference, division by zero, or index error — unless you can prove the guarded state is unreachable, and you state the proof.
4. **Public surface.** Exported names, signatures, parameter defaults, return types, serialization shapes, CLI flags, environment variable names, database schema, wire formats, and log lines that dashboards or alerts parse.
5. **Concurrency and ordering.** Locks, `await` placement, transaction boundaries, retry/backoff, idempotency keys, and cleanup in `finally` / `defer`.
6. **Edge-case branches.** Anything that behaves differently on `None`, `""`, `0`, `[]`, `NaN`, negative numbers, unicode, or timezone boundaries. In particular: collapsing `if x is not None` into `if x`, or `??` into `||`, is a bug factory. Never do it to save a line.
7. **Algorithmic complexity.** No `x in list` inside a loop, no `str +=` accumulation in a loop, no regex compiled inside a loop, no extra full pass over a large collection — even when it reads shorter.
8. **Hot-path allocation.** No new intermediate list, copy, or closure inside a loop that runs at scale, purely for brevity.
9. **Tests.** Never delete a test case or an assertion. Consolidating *setup* is encouraged; the set of asserted behaviors must be identical before and after. Assertion count may drop only when the identical assertion is now made by a parametrized case — say so explicitly.
10. **Comments that explain *why*.** Delete `what` comments freely. Keep rationale, invariants, links to issues, workaround explanations, license headers, and every `# noqa` / `# type: ignore` / `eslint-disable` / `//go:build` directive.
11. **Generated, vendored, and migration files.** Including lockfiles and applied migrations.
12. **Anything outside the resolved scope.**

## Readability Floor

A reduction must also survive these. If it does not, it is rejected even when it saves lines.

- No nested ternaries.
- No comprehension with more than one `for` plus one condition.
- No method or pipeline chain longer than three links on one line.
- No lambda assigned to a name where a `def`/named function belongs.
- No walrus, comma operator, or side effect inside an expression that hides control flow.
- No single-letter names outside a two-line scope or a conventional index.
- No line exceeding the project's configured maximum width.
- A "clever" construct that a mid-level engineer on this codebase would have to look up is out — regardless of how many lines it saves.
- **The ≤2-line rule:** if a change saves two lines or fewer and costs a reader a second pass, skip it.

---

## Outputs

Do not create report files unless the user asks. Report inline.

```
## Trim report

Scope: <resolved scope> — <N> files, <M> changed lines
Mode: review | armed | dry-run
Baseline: <test cmd> <result> · <type cmd> <result> · <lint cmd> <result>

LOC: <before> -> <after>  (-<delta>, -<pct>%)

### Applied
| Location | Pattern | -Lines | Why it is equivalent |
|----------|---------|--------|----------------------|
| src/x.py:42 | #11 re-implemented stdlib | -18 | `Counter` yields the same counts; iteration order unused downstream |

### Rejected
| Location | Candidate | Reason |
|----------|-----------|--------|
| src/y.py:88 | Collapse null check | Do-Not-Touch #6 — `0` is a valid value here |

### Needs your call
- <changes that alter public surface, drop a dependency, or need a product decision>

Verification: <test cmd> <result> · <type cmd> <result> · <lint cmd> <result> — identical to baseline
```

Rules for the report:

- The **Rejected** section is mandatory and must not be empty on any non-trivial scope. An empty rejected list means the Do-Not-Touch list was not actually applied.
- Every applied row needs a real equivalence argument. "Cleaner" and "simpler" are not arguments.
- Report the true number. If the reduction is 4%, report 4%. Never round up, never count deleted blank lines or deleted comments as if they were logic, and never report a number the verification gate did not confirm.
- If nothing worth changing was found, say exactly that. A pass that finds little is a valid outcome — inventing churn to look productive is the failure mode.

## Boundaries

- Behavior-preserving reduction only. No new features, no bug fixes, no performance work, no dependency changes, no formatting-only churn that the project's formatter would revert.
- Never commit, push, or open a PR unless the user explicitly asks.
- Never disable, skip, weaken, or rewrite a test to make the verification gate pass.
- When a reduction is genuinely a judgment call, propose it — do not apply it and mention it afterward.

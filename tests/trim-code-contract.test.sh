#!/usr/bin/env bash
# Contract test: trim-code must stay a behavior-preserving reduction pass —
# verified against the project's own commands, bounded by an explicit
# do-not-touch list, and honest about what it rejected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKILL_FILE="${ROOT_DIR}/skills/trim-code/SKILL.md"
MIRROR_FILE="${ROOT_DIR}/.agents/skills/trim-code/SKILL.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local message="$2"

  if ! grep -Fq -- "$needle" "$SKILL_FILE"; then
    fail "${message} (missing: ${needle})"
  fi
}

[[ -f "$SKILL_FILE" ]] || fail "trim-code skill file exists"
[[ -f "$MIRROR_FILE" ]] || fail "trim-code .agents mirror exists"
diff -q "$SKILL_FILE" "$MIRROR_FILE" >/dev/null || fail "skills/ and .agents/skills/ copies are identical"

# --- Front matter -----------------------------------------------------------

assert_contains 'name: trim-code' "declares skill name"
assert_contains 'Use when the user says "trim this", "reduce the code", "too much code"' \
  "description carries invocation triggers"

# --- Governing principle: LOC is a proxy, not the goal -----------------------

assert_contains '**Line count is a proxy for reviewer effort, never the goal.** A change that removes lines but makes a reader stop and re-parse is a regression. Reject it.' \
  "states the proxy principle that outranks every other rule"
assert_contains 'It is a **behavior-preserving reduction pass**, not a rewrite and not a bug hunt.' \
  "scopes the skill to behavior-preserving reduction"

# --- Both modes exist and are distinct --------------------------------------

assert_contains '### Mode A — Review' "defines review mode"
assert_contains '### Mode B — Armed' "defines armed self-check mode"
assert_contains 'before reporting **any** coding task complete' \
  "armed mode gates task completion"
assert_contains 'Stays active until `/trim-code disarm` or the session ends.' \
  "armed mode has an explicit exit"
assert_contains 'do not create or modify hook configuration without explicit user approval' \
  "hook enforcement requires user approval"

# --- Scope resolution is bounded --------------------------------------------

assert_contains 'Nothing found → ask the user for a scope. Do not default to the whole repository.' \
  "refuses to default to whole-repo scope"
assert_contains 'State the resolved scope and the file count before doing anything else.' \
  "announces scope before editing"

# --- Baseline gate ----------------------------------------------------------

assert_contains '### 1. Baseline gate — run before the first edit' \
  "requires a baseline before the first edit"
assert_contains 'Do not invent them; read `package.json` scripts' \
  "discovers project commands instead of inventing them"
assert_contains 'If the suite is already failing, record exactly which tests fail.' \
  "records pre-existing failures"
assert_contains 'drop to **conservative mode**: Tier 1 and Tier 2 only, no Tier 3' \
  "degrades to conservative mode when the scope has no tests"

# --- Reuse search is mandatory ----------------------------------------------

assert_contains '### 3. Mandatory reuse search' "requires a reuse search"
assert_contains 'Search by behavior, not by name' "searches existing helpers by behavior"
assert_contains 'This step recovers the largest reductions and is the one most often skipped. Do not skip it.' \
  "flags the reuse search as non-skippable"

# --- Tiered taxonomy --------------------------------------------------------

assert_contains '### Tier 1 — Redundancy (no behavior risk; apply directly)' "defines tier 1"
assert_contains '### Tier 2 — Reuse (highest value; requires the search in step 3)' "defines tier 2"
assert_contains '### Tier 3 — Structure (judgment required; propose first when risk is medium or high)' "defines tier 3"
assert_contains 'Apply strictly in tier order' "applies changes in tier order"
assert_contains 'Apply **each Tier 3 change as its own batch** so a revert is surgical.' \
  "isolates high-risk changes for surgical revert"
assert_contains 'Do **not** add a new dependency to save lines' \
  "forbids adding dependencies for line count"

# --- Stop conditions --------------------------------------------------------

assert_contains 'Diminishing returns is a stop condition, not a challenge.' \
  "treats diminishing returns as a stop condition"

# --- Do-not-touch rails -----------------------------------------------------

assert_contains '## Do-Not-Touch List' "carries an explicit do-not-touch list"
assert_contains '**Trust-boundary validation.**' "protects trust-boundary validation"
assert_contains 'Removing a `try` is behavior change unless the handler is a pure re-raise of the same exception with no side effects and no `finally`.' \
  "defines when error handling may be removed"
assert_contains 'collapsing `if x is not None` into `if x`, or `??` into `||`, is a bug factory' \
  "protects falsy-value edge cases"
assert_contains '**Algorithmic complexity.**' "forbids complexity regressions"
assert_contains 'Never delete a test case or an assertion.' "protects test coverage"
assert_contains 'the set of asserted behaviors must be identical before and after' \
  "requires assertion parity after test consolidation"
assert_contains 'Delete `what` comments freely. Keep rationale, invariants, links to issues' \
  "distinguishes what-comments from why-comments"

# --- Readability floor ------------------------------------------------------

assert_contains '## Readability Floor' "carries a readability floor"
assert_contains 'No nested ternaries.' "bans nested ternaries"
assert_contains '**The ≤2-line rule:** if a change saves two lines or fewer and costs a reader a second pass, skip it.' \
  "bans low-value readability trades"

# --- Verification gate ------------------------------------------------------

assert_contains '### 7. Verification gate' "requires a verification gate"
assert_contains 'Required outcome: **identical** results' "requires identical baseline results"
assert_contains 'Revert the specific batch that introduced it, not the whole pass.' \
  "reverts surgically on regression"
assert_contains 'Never report a reduction that was not verified. Never explain away a new failure as "unrelated".' \
  "forbids unverified or excused results"
assert_contains 'Never disable, skip, weaken, or rewrite a test to make the verification gate pass.' \
  "forbids weakening tests to pass the gate"

# --- Honest reporting -------------------------------------------------------

assert_contains 'The **Rejected** section is mandatory and must not be empty on any non-trivial scope.' \
  "requires a rejected-candidates section"
assert_contains '"Cleaner" and "simpler" are not arguments.' "requires real equivalence arguments"
assert_contains 'Report the true number. If the reduction is 4%, report 4%.' \
  "requires honest reduction numbers"
assert_contains 'inventing churn to look productive is the failure mode' \
  "names the churn failure mode"

# --- Boundaries -------------------------------------------------------------

assert_contains 'Never commit, push, or open a PR unless the user explicitly asks.' \
  "forbids unrequested publishing"
assert_contains 'When a reduction is genuinely a judgment call, propose it — do not apply it and mention it afterward.' \
  "requires proposal-before-apply for judgment calls"

echo "PASS: trim-code behavior-preserving reduction contract"

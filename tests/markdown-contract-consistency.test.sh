#!/usr/bin/env bash
# Documentation contract test: asserts the skill/asset Markdown matches the
# behavior enforced by the runtime scripts and validators, and that the
# compaction-safe twin files stay synchronized on key tokens.
# Twins: skills/run-with-it/SKILL.md <-> assets/main-orchestrator-rules.md
#        assets/sub-coordinator-prompt.md <-> assets/coordinator-rules.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILURES=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_contains() {  # file token message
  grep -Fq -- "$2" "$ROOT_DIR/$1" || fail "$1: $3"
}

assert_not_contains() {  # file token message
  if grep -Fq -- "$2" "$ROOT_DIR/$1"; then fail "$1: $3"; fi
}

assert_twins_contain() {  # fileA fileB token message
  assert_contains "$1" "$3" "$4 (missing in $1)"
  assert_contains "$2" "$3" "$4 (missing in $2)"
}

# --- Verified no-op contract (run-with-it-artifacts.py accepts no_op:true) ---

assert_contains "assets/sub-coordinator-prompt.md" '"no_op": true' \
  "sub-coordinator must document no-op artifact acceptance"
assert_contains "assets/coordinator-rules.md" 'verified no-op' \
  "coordinator-rules must carve out the verified no-op exception"
assert_contains "assets/prompt.md" 'or the verified no-op result artifact' \
  "implementer done-file gates must allow the verified no-op"
assert_contains "assets/modifier-prompt.md" 'or the verified no-op result artifact' \
  "modifier done-file gates must allow the verified no-op"

# --- Iteration limit (no script reads MAX_ITERATIONS; cap is prompt-enforced) ---

assert_contains "skills/run-with-it/SKILL.md" 'hardcoded to 8 cycles' \
  "MAX_ITERATIONS row must state the 8-cycle cap is hardcoded and the variable inactive"

# --- Complexity fallback band (medium-hard, score=25) ---

assert_not_contains "assets/coordinator-rules.md" 'default to medium and continue' \
  "complexity fallback must be medium-hard, not medium"
assert_contains "assets/coordinator-rules.md" 'medium-hard' \
  "coordinator-rules must state the medium-hard fallback"
assert_contains "assets/sub-coordinator-prompt.md" 'fallback=medium-hard' \
  "sub-coordinator STATUS contract keeps fallback=medium-hard"

# --- Stall threshold (snippets pass 300 explicitly; 600 is the env fallback) ---

assert_contains "assets/coordinator-rules.md" 'WORKER_STALL_SECONDS=300' \
  "coordinator-rules must document the effective 300s snippet value"

# --- Terminal sets: orchestrator issue statuses include failed-merge... ---

assert_twins_contain "skills/run-with-it/SKILL.md" "assets/main-orchestrator-rules.md" \
  'completed / failed-review / failed-merge / blocked' \
  "orchestrator terminal enumerations must include failed-merge"
assert_not_contains "skills/run-with-it/SKILL.md" 'completed / failed-review / blocked' \
  "stale three-status orchestrator enumeration must be gone"
assert_not_contains "assets/main-orchestrator-rules.md" 'completed / failed-review / blocked' \
  "stale three-status orchestrator enumeration must be gone"
assert_not_contains "assets/main-orchestrator-rules.md" 'completed/failed-review/blocked' \
  "stale compact three-status enumeration must be gone"

# --- ...while sub-coordinator REPORT outcomes use merge_failed, never failed-merge ---

assert_contains "assets/sub-coordinator-prompt.md" 'completed | failed-review | merge_failed | blocked' \
  "Appendix E outcome enum must include merge_failed"
assert_not_contains "assets/sub-coordinator-prompt.md" 'failed-merge' \
  "failed-merge is an orchestrator issue status and must not leak into sub-coordinator outcomes"

# --- Auto-fail stalled roles (script default: complexity,impl,modify,plan) ---

assert_contains "assets/sub-coordinator-prompt.md" 'complexity,impl,modify,plan' \
  "auto-fail role default must match run-with-it-dispatch.sh"
assert_twins_contain "skills/run-with-it/SKILL.md" "assets/coordinator-rules.md" \
  'complexity,impl,modify,plan' "auto-fail role default must match in twins"
assert_not_contains "assets/sub-coordinator-prompt.md" '(Bash default: `complexity`)' \
  "stale single-role auto-fail default must be gone"

# --- Worker-watch ownership (pool runner/dispatcher own it, not the orchestrator) ---

assert_contains "assets/main-orchestrator-rules.md" 'never runs worker-watch itself' \
  "Main Orchestrator must not be told to run worker-watch directly"

# --- Plan template must satisfy valid_plan_payload (non-empty slices) ---

assert_not_contains "assets/plan-prompt.md" '"slices": [],' \
  "Bash plan example must not produce an invalid empty slices array"
assert_not_contains "assets/plan-prompt.md" 'slices = @()' \
  "PowerShell plan example must not produce an invalid empty slices array"

# --- Review schema includes every required coverage row ---

assert_contains "assets/review-prompt.md" 'plan_conformance | maintainability' \
  "review schema area enum must include plan_conformance"

# --- Complexity prompt acceptance checks describe the file truthfully ---

assert_not_contains "assets/complexity-prompt.md" 'Contains CodeGraph tool instructions' \
  "acceptance check must not claim CodeGraph instructions exist"

# --- Merge-recovery bootstrap copy-paste leftovers ---

assert_not_contains "assets/merge-recovery-prompt.md" 'tdd-implementation' \
  "merge recovery never bootstraps tdd-implementation"
assert_not_contains "assets/merge-recovery-prompt.md" 'both activations' \
  "merge recovery bootstraps a single skill"

# --- Modifier verification scoped to change-caused failures (implementer policy untouched) ---

assert_contains "assets/modifier-prompt.md" 'caused by the reviewed change before reporting completion' \
  "modifier verification must be scoped to change-caused failures"
assert_contains "assets/prompt.md" 'If tests outside your assigned scope are failing, fix them' \
  "implementer out-of-scope policy must remain unchanged"

# --- Reviewer band bump owned by the router; manual table scoped to fallback ---

assert_contains "assets/sub-coordinator-prompt.md" 'REVIEW_BUMP' \
  "route-helper inputs must name the router's internal review bump"
assert_contains "assets/sub-coordinator-prompt.md" 'prompt fallback router only' \
  "manual reviewer band table must be scoped to the fallback router"

# --- Review-skip keys documented in the compact report schema ---

assert_contains "assets/sub-coordinator-prompt.md" '"review_skipped": false' \
  "Appendix E schema must include the review_skipped key"
assert_contains "skills/run-with-it/SKILL.md" 'Review: skipped' \
  "Appendix D must define the terminal-comment line for skipped review"

# --- Skill isolation permits the governing-prompt bootstrap ---

assert_contains "skills/save-tokens/SKILL.md" 'governing prompt' \
  "save-tokens isolation must allow the worker-prompt bootstrap"
assert_contains "skills/tdd-implementation/SKILL.md" 'governing prompt' \
  "tdd-implementation isolation must allow the worker-prompt bootstrap"

# --- No-Git support claims scoped to what actually works without git ---

assert_contains "skills/run-with-it/SKILL.md" 'asset discovery and local-issue intake' \
  "no-git support claim must be scoped; branches/worktrees/merges require git"

# --- Stale references and typos ---

assert_not_contains "skills/run-with-it/SKILL.md" 'Preflight Check 14' \
  "stale preflight cross-reference must be corrected"
assert_not_contains "skills/create-git-issue/SKILL.md" 'outsise' "typo: outsise"
assert_not_contains "skills/create-git-issue/SKILL.md" 'requirment in detils' "typo: requirment in detils"

# --- Review skip still merges back to the shared feature branch ---

assert_twins_contain "assets/sub-coordinator-prompt.md" "assets/coordinator-rules.md" \
  'or a Step 0 review skip' \
  "merge trigger must cover the review-skip path"

# --- Modifier no-op: dedicated variant, correct pre-spawn head ---

assert_contains "assets/modifier-prompt.md" 'Verified no-op variant' \
  "modifier must have a no-op payload variant (git show NONE breaks the builder)"
assert_contains "assets/modifier-prompt.md" '--pre-spawn-head "${REVIEW_HEAD_SHA:-}"' \
  "modifier validation must use the modify-cycle pre-spawn head"
assert_not_contains "assets/modifier-prompt.md" '--pre-spawn-head "${ISSUE_BASE_SHA:-}"' \
  "modifier must not validate no-ops against the issue baseline"

# --- Verification exception uses a validator-supported representation ---

assert_contains "assets/modifier-prompt.md" 'applies only to failures outside those required commands' \
  "pre-existing-failure path must not conflict with the passed=true validator requirement"

# --- Stall env fallback scoped by platform (Bash 600, PowerShell 300) ---

assert_contains "assets/coordinator-rules.md" '600 on Bash, 300 on PowerShell' \
  "stall env fallback must be scoped by platform"

# --- failed-merge in the remaining enumerations (Resume Flow, final summary) ---

assert_contains "skills/run-with-it/SKILL.md" 'Completed / failed-review / failed-merge / blocked counts' \
  "final summary counts must include failed-merge"
assert_contains "skills/run-with-it/SKILL.md" '`"failed-merge"`, or `"blocked"`' \
  "Resume Flow terminal-skip enumeration must include failed-merge"

# --- Task 7A: baseline confirm anchored to the issue worktree ---

assert_contains "assets/sub-coordinator-prompt.md" 'ISSUE_BASE_SHA:-$(git -C "$ISSUE_WORKTREE_PATH" rev-parse HEAD)' \
  "baseline confirm must read the issue worktree, not ambient HEAD"

# --- Task 7B: review-skip gate rows must be mutually exclusive ---

assert_not_contains "assets/sub-coordinator-prompt.md" 'or `files_changed` 2–4' \
  "overlapping gray-zone file-count range must be gone"

# --- Out-of-scope gate attribution (shared repo-global gates) ---
# Slices that split one repo-global gate each fail it alone. Reporting every
# slice as failed-review terminates all of them and strands their dependents
# even though the scoped work was sound, so attribution is required first.

assert_twins_contain "assets/sub-coordinator-prompt.md" "assets/coordinator-rules.md" \
  'out-of-scope-gate-failure' \
  "gate-attribution blocking reason must be documented in both twins"
assert_contains "assets/sub-coordinator-prompt.md" 'Out-of-Scope Gate Rule' \
  "sub-coordinator must carry the gate attribution rule"
assert_contains "assets/sub-coordinator-prompt.md" 'STATUS|type=gate-attribution' \
  "gate attribution must be observable on the status bus"
assert_contains "assets/sub-coordinator-prompt.md" 'fail closed' \
  "unclear gate attribution must fail closed onto this issue"
assert_contains "assets/coordinator-rules.md" 'Out-of-Scope Gate Rule' \
  "coordinator-rules must carry the gate attribution rule"

# --- Compaction handoff is unattended-safe and separately budgeted ---

assert_contains "assets/sub-coordinator-prompt.md" '"compaction_requested": true' \
  "compaction handoff must persist the flag the control plane keys on"
assert_contains "assets/sub-coordinator-prompt.md" 'MAX_SUB_COORD_COMPACTION_HANDOFFS' \
  "compaction handoff must document its own budget"
assert_not_contains "assets/sub-coordinator-prompt.md" '**Stop** and wait for the user.' \
  "unattended runs have no user to wait for; the pool recovers the handoff"

# --- Unreachable-issue reporting reaches the operator ---

assert_twins_contain "skills/run-with-it/SKILL.md" "assets/main-orchestrator-rules.md" \
  'pool-unreachable' \
  "stranded-dependent reporting must be documented in both twins"
assert_contains "skills/run-with-it/SKILL.md" 'MAX_WORKER_WAIT_SECONDS' \
  "skill must document the in-flight worker wait ceiling"
assert_contains "skills/run-with-it/SKILL.md" 'RUN_WITH_IT_WORKER_STALE_SECONDS' \
  "skill must document the worker staleness bound"

# --- pair-colleague: docs must match the runtime contract ---
# The coordinator is the invoking agent, agents launch only through run-agent.sh,
# and the round bounds/exit codes documented here are the ones the script enforces.

assert_contains "skills/pair-colleague/SKILL.md" 'never guess' \
  "pair-colleague skill must forbid guessing harness/model/effort"
assert_contains "skills/pair-colleague/SKILL.md" 'one question at a time' \
  "pair-colleague skill must ask for missing configuration one question at a time"
assert_contains "skills/pair-colleague/SKILL.md" 'COORDINATOR_ACTION: CONTINUE' \
  "pair-colleague skill must carry the coordinator action contract"
assert_contains "assets/pair-colleague-agent-prompt.md" 'DISCUSSION_STATUS: READY' \
  "pair-colleague agent prompt must carry both advisory status values"
assert_contains "assets/pair-colleague.sh" 'MIN_ROUNDS:-3' \
  "pair-colleague default minimum rounds must stay 3"
assert_contains "assets/pair-colleague.sh" 'MAX_ROUNDS:-8' \
  "pair-colleague default maximum rounds must stay 8"
assert_contains "README.md" '| `MIN_ROUNDS` / `--min-rounds` | `3` |' \
  "README must document the enforced minimum-round default"
assert_contains "README.md" '| `MAX_ROUNDS` / `--max-rounds` | `8` |' \
  "README must document the enforced maximum-round default"
assert_contains "assets/pair-colleague.sh" 'TIMEOUT_SECONDS:-3600' \
  "pair-colleague default agent timeout must stay 3600s (60 min)"
assert_contains "README.md" '| `TIMEOUT_SECONDS` / `--timeout-seconds` | `3600` (60 min) |' \
  "README must document the enforced agent-timeout default"
assert_contains "skills/pair-colleague/SKILL.md" 'default 3600' \
  "pair-colleague skill must document the enforced agent-timeout default"
assert_contains "README.md" 'Bash only' \
  "README must scope pair-colleague to Bash for v1"
assert_not_contains "skills/pair-colleague/SKILL.md" 'AGENT_1_CMD' \
  "pair-colleague must not document an arbitrary command escape hatch"
assert_not_contains "README.md" 'pair-colleague.ps1' \
  "no PowerShell pair-colleague runner exists in v1"

# The supported-platform claim, the busy exit code, and the safe-mode contract
# must say the same thing in the runtime, the skill, and the README.
assert_contains "assets/pair-colleague.sh" 'EXIT_BUSY=4' \
  "pair-colleague must reserve exit code 4 for a busy run"
assert_contains "skills/pair-colleague/SKILL.md" '| `4` |' \
  "pair-colleague skill must document the busy exit code"
assert_contains "skills/pair-colleague/SKILL.md" 'macOS, Linux, and WSL' \
  "pair-colleague skill must scope v1 to macOS, Linux, and WSL"
assert_contains "README.md" 'macOS, Linux, and WSL' \
  "README must scope pair-colleague to macOS, Linux, and WSL"
assert_not_contains "skills/pair-colleague/SKILL.md" 'Git Bash, and WSL' \
  "pair-colleague skill must not advertise Git Bash as supported"
assert_not_contains "README.md" 'Git Bash, and WSL' \
  "README must not advertise Git Bash as supported"
assert_contains "assets/pair-colleague.sh" 'PAIR_COLLEAGUE_UNAME_OVERRIDE' \
  "pair-colleague must guard the platform at runtime, not only in prose"
assert_contains "assets/run-agent.sh" 'read_only_permission' \
  "safe permission mode must resolve to the registry read-only profile"
assert_contains "assets/agent-registry.json" '"read_only": "--sandbox=read-only"' \
  "the registry must record a real read-only profile for Codex"
assert_contains "README.md" 'permission_modes.read_only' \
  "README must document how safe mode resolves"

# --- Result ---

if [ "$FAILURES" -gt 0 ]; then
  printf '%d markdown contract failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'markdown contract consistency: OK\n'

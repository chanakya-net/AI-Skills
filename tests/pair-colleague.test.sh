#!/usr/bin/env bash
# Contract tests for the pair-colleague two-agent solution coordinator.
#
# These tests never touch the network and never require an installed AI
# harness: every agent launch is routed through an injected fake run-agent
# runner and an isolated temporary run root.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_PATH="${ROOT_DIR}/assets/pair-colleague.sh"
HELPER_PATH="${ROOT_DIR}/assets/pair-colleague-process.py"
PROMPT_TEMPLATE="${ROOT_DIR}/assets/pair-colleague-agent-prompt.md"
REGISTRY_PATH="${ROOT_DIR}/assets/agent-registry.json"
SKILL_PATH="${ROOT_DIR}/skills/pair-colleague/SKILL.md"

FAILURES=0
CURRENT_CASE=""

fail() {
  printf 'FAIL: %s: %s\n' "${CURRENT_CASE}" "$1" >&2
  FAILURES=$((FAILURES + 1))
}

hard_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail "$3 (expected: $1, actual: $2)"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3 (unexpected: $2)"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$3 (missing '$2' in $1)"
}

assert_file_not_contains() {
  if grep -Fq -- "$2" "$1"; then fail "$3 (unexpected '$2' in $1)"; fi
}

start_case() {
  CURRENT_CASE="$1"
}

# ── Sandbox ────────────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d -t pair-colleague-tests.XXXXXX)"
cleanup() {
  rm -rf "${SANDBOX}"
}
trap cleanup EXIT

[[ -f "${SCRIPT_PATH}" ]] || hard_fail "assets/pair-colleague.sh exists"
[[ -x "${SCRIPT_PATH}" ]] || hard_fail "assets/pair-colleague.sh is executable"
[[ -f "${HELPER_PATH}" ]] || hard_fail "assets/pair-colleague-process.py exists"
[[ -f "${PROMPT_TEMPLATE}" ]] || hard_fail "assets/pair-colleague-agent-prompt.md exists"
[[ -f "${SKILL_PATH}" ]] || hard_fail "skills/pair-colleague/SKILL.md exists"

# ── Fake runner ────────────────────────────────────────────────────────────
FAKE_RUNNER="${SANDBOX}/fake-run-agent.sh"
cat > "${FAKE_RUNNER}" <<'FAKEEOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${FAKE_STATE_DIR:?FAKE_STATE_DIR is required}"
mkdir -p "${STATE_DIR}"

if [[ "${1:-}" == "--list-agents" ]]; then
  if [[ "${FAKE_UNDETECTED:-}" == "codex" ]]; then
    printf 'claude\tClaude Code\tdetected\tdetected\n'
  else
    printf 'codex\tCodex CLI\tdetected\tdetected\n'
    printf 'claude\tClaude Code\tdetected\tdetected\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "--list-models" ]]; then
  case "${2:-}" in
    codex) printf 'gpt-5.6-terra\ngpt-5.6\n' ;;
    claude) printf 'claude-sonnet-5\nclaude-opus-5\n' ;;
    *) echo "error: unknown agent: ${2:-}" >&2; exit 1 ;;
  esac
  exit 0
fi

AGENT="" MODEL="" EFFORT="" CONTEXT_FILE="" PROMPT_FILE="" PERMISSION_MODE=""
ARGV_LINE=""
for arg in "$@"; do ARGV_LINE+="${arg}"$'\x1f'; done
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --context-file) CONTEXT_FILE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --permission-mode) PERMISSION_MODE="$2"; shift 2 ;;
    *) echo "fake runner: unexpected argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "${AGENT}" ]] || { echo "fake runner: missing --agent" >&2; exit 64; }
[[ -n "${MODEL}" ]] || { echo "fake runner: missing --model" >&2; exit 64; }
[[ -n "${EFFORT}" ]] || { echo "fake runner: missing --effort" >&2; exit 64; }
[[ -f "${CONTEXT_FILE}" ]] || { echo "fake runner: missing --context-file" >&2; exit 64; }
[[ -f "${PROMPT_FILE}" ]] || { echo "fake runner: missing --prompt-file" >&2; exit 64; }

SLOT_DIR="${STATE_DIR}/${MODEL}"
mkdir -p "${SLOT_DIR}"
printf '%s\n' "${ARGV_LINE}" >> "${SLOT_DIR}/invocations.log"

context_hash="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${CONTEXT_FILE}")"
touch "${SLOT_DIR}/hashes"
round="$(grep -n -F -x "${context_hash}" "${SLOT_DIR}/hashes" | head -n1 | cut -d: -f1 || true)"
if [[ -z "${round}" ]]; then
  printf '%s\n' "${context_hash}" >> "${SLOT_DIR}/hashes"
  round="$(wc -l < "${SLOT_DIR}/hashes" | tr -d ' ')"
fi

cp "${CONTEXT_FILE}" "${SLOT_DIR}/round-${round}-context.md"
cp "${PROMPT_FILE}" "${SLOT_DIR}/round-${round}-prompt.md"
printf '%s\n' "${PERMISSION_MODE}" > "${SLOT_DIR}/round-${round}-permission-mode"
printf '%s\n' "${PWD}" > "${SLOT_DIR}/round-${round}-cwd"
printf '%s\n' "${REPO_ROOT:-}" > "${SLOT_DIR}/round-${round}-repo-root"

attempt_file="${SLOT_DIR}/round-${round}-attempts"
attempts=0
[[ -f "${attempt_file}" ]] && attempts="$(cat "${attempt_file}")"
attempts=$((attempts + 1))
printf '%s\n' "${attempts}" > "${attempt_file}"

if [[ "${FAKE_HANG_MODEL:-}" == "${MODEL}" ]]; then
  sleep 120 &
  child=$!
  printf '%s\n' "${child}" > "${STATE_DIR}/hang-child.pid"
  wait "${child}"
  exit 0
fi

# A slow-but-healthy agent: long enough for the coordinator to be killed or
# invoked a second time while the agent is still doing paid work.
if [[ -n "${FAKE_SLEEP_SECONDS:-}" ]]; then
  sleep "${FAKE_SLEEP_SECONDS}" &
  slow_child=$!
  printf '%s\n' "${slow_child}" > "${STATE_DIR}/slow-child-${MODEL}.pid"
  wait "${slow_child}"
fi

if [[ "${FAKE_FAIL_MODEL:-}" == "${MODEL}" && "${attempts}" -le "${FAKE_FAIL_TIMES:-999}" ]]; then
  echo "fake runner diagnostic: simulated harness failure for ${MODEL}" >&2
  echo "partial output before failure"
  exit 7
fi

status="CONTINUE"
if [[ "${FAKE_READY_MODEL:-}" == "${MODEL}" || "${FAKE_READY_MODEL:-}" == "all" ]]; then
  status="READY"
fi

emit_body() {
  cat <<BODY
# Candidate analysis
MARKER-R${round}-${MODEL} candidate A and candidate B remain credible.

# Preferred solution
MARKER-R${round}-${MODEL} prefers candidate A with the B cache boundary.

# Improvements and implementation detail
MARKER-R${round}-${MODEL} adds a write-through path and a bounded queue.

# Agreements
MARKER-R${round}-${MODEL} agrees the boundary belongs at the edge.

# Disagreements
MARKER-R${round}-${MODEL} disputes the eviction policy.

# Risks and unresolved questions
MARKER-R${round}-${MODEL} flags cold-start latency.

# Suggested next step
MARKER-R${round}-${MODEL} suggests measuring eviction cost.
BODY
}

case "${FAKE_BAD_OUTPUT_MODE:-}" in
  trailing)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      emit_body
      printf '\nDISCUSSION_STATUS: CONTINUE\n'
      printf 'trailing chatter that must be rejected\n'
      exit 0
    fi
    ;;
  duplicate-status)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      emit_body
      printf '\nDISCUSSION_STATUS: CONTINUE\nDISCUSSION_STATUS: READY\n'
      exit 0
    fi
    ;;
  missing-section)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      printf '# Candidate analysis\nonly one section\n\nDISCUSSION_STATUS: CONTINUE\n'
      exit 0
    fi
    ;;
  bad-status)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      emit_body
      printf '\nDISCUSSION_STATUS: MAYBE\n'
      exit 0
    fi
    ;;
  duplicate-section)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      emit_body
      printf '\n# Agreements\nduplicated heading\n'
      printf '\nDISCUSSION_STATUS: CONTINUE\n'
      exit 0
    fi
    ;;
  empty)
    if [[ "${FAKE_BAD_OUTPUT_MODEL:-}" == "${MODEL}" ]]; then
      exit 0
    fi
    ;;
esac

emit_body
printf '\nDISCUSSION_STATUS: %s\n' "${status}"
FAKEEOF
chmod +x "${FAKE_RUNNER}"

# ── Shared fixtures ────────────────────────────────────────────────────────
TASK_FILE="${SANDBOX}/task.md"
cat > "${TASK_FILE}" <<'EOF'
Design a caching strategy for our public API.

# Constraints and success criteria

- p99 latency under 120ms
- no stale reads longer than 30 seconds
EOF

new_env_dir() {
  # Each case gets a fully isolated run root and fake-runner state directory.
  local dir
  dir="$(mktemp -d "${SANDBOX}/env-XXXXXX")"
  mkdir -p "${dir}/runs" "${dir}/fake-state"
  printf '%s\n' "${dir}"
}

# pc <env-dir> <args...>
pc() {
  local env_dir="$1"; shift
  RUN_AGENT_PATH="${FAKE_RUNNER}" \
  AGENT_REGISTRY_FILE="${TEST_REGISTRY_OVERRIDE:-${REGISTRY_PATH}}" \
  PAIR_COLLEAGUE_PROCESS_HELPER="${HELPER_PATH}" \
  PAIR_COLLEAGUE_PROMPT_FILE="${PROMPT_TEMPLATE}" \
  PAIR_COLLEAGUE_RUN_ROOT="${env_dir}/runs" \
  FAKE_STATE_DIR="${env_dir}/fake-state" \
    bash "${SCRIPT_PATH}" "$@"
}

# pc_bg <env-dir> <log-file> <args...> -> PC_BG_PID is the control-plane pid
PC_BG_PID=""
pc_bg() {
  local env_dir="$1" log="$2"; shift 2
  RUN_AGENT_PATH="${FAKE_RUNNER}" \
  AGENT_REGISTRY_FILE="${REGISTRY_PATH}" \
  PAIR_COLLEAGUE_PROCESS_HELPER="${HELPER_PATH}" \
  PAIR_COLLEAGUE_PROMPT_FILE="${PROMPT_TEMPLATE}" \
  PAIR_COLLEAGUE_RUN_ROOT="${env_dir}/runs" \
  FAKE_STATE_DIR="${env_dir}/fake-state" \
    bash "${SCRIPT_PATH}" "$@" > "${log}" 2>&1 &
  PC_BG_PID=$!
}

start_default() {
  local env_dir="$1"; shift
  pc "${env_dir}" start "${TASK_FILE}" \
    --agent-1-harness codex \
    --agent-1-model gpt-5.6-terra \
    --agent-1-effort high \
    --agent-2-harness claude \
    --agent-2-model claude-sonnet-5 \
    --agent-2-effort high \
    "$@"
}

field() {  # field <output> <KEY>
  printf '%s\n' "$1" | grep -E "^$2=" | head -n1 | cut -d= -f2-
}

write_decision() {  # write_decision <path> <action> [focus]
  local path="$1" action="$2" focus="${3:-Compare eviction policies with measurements.}"
  cat > "${path}" <<EOF
# Round assessment
Both colleagues sharpened the cache boundary question.

# Candidate-solution ledger
- C1 edge cache — active
- C2 origin cache — active

# Current synthesis or preferred direction
C1 with a bounded write-through path.

# Agreements
The boundary belongs at the edge.

# Disagreements
Eviction policy is unresolved.

# Rejected candidates
- C3 client-only cache — rejected: cannot bound staleness.

# Unresolved questions and risks
Cold-start latency is unmeasured.

# Focus for next round
${focus}

# Decision rationale
Another round can still resolve eviction.

COORDINATOR_ACTION: ${action}
EOF
}

write_dossier() {  # write_dossier <path> <completed-rounds> <completion-reason> <run-dir> [min] [max]
  local path="$1" rounds="$2" reason="$3" run_dir="$4" min="${5:-3}" max="${6:-8}"
  cat > "${path}" <<EOF
# Final Solution Decision

## Executive summary
Adopt the edge cache with a bounded write-through path.

## Problem and success criteria
Serve the public API under 120ms p99 without stale reads beyond 30 seconds.

## Constraints and assumptions
Existing origin capacity is fixed; the CDN contract is already in place.

## Candidate solutions considered
- C1 edge cache
- C2 origin cache
- C3 client-only cache

## Trade-off comparison
C1 costs more at the edge but bounds staleness; C2 is cheaper but slower.

## Selected or synthesized solution
C1 with the write-through path taken from C2.

## Detailed design and operation
Requests hit the edge cache, misses fall through to origin, writes invalidate.

## How this solves the problem
Edge hits meet the latency target; invalidation bounds staleness at 30 seconds.

## Implementation approach
Ship the edge cache first, add invalidation, then enable write-through.

## Decision rationale
Both colleagues converged on the boundary; the remaining gap was eviction cost.

## Agent agreement
Both agreed the cache boundary belongs at the edge.

## Remaining disagreement and coordinator resolution
Eviction policy remained open; the coordinator selected TTL plus size bound.

## Rejected alternatives
C3 was rejected because staleness cannot be bounded from the client.

## Risks and mitigations
Cold-start latency is mitigated by warm-up on deploy.

## Open questions and human decisions
None

## Discussion record

- Coordinator: current invoking agent
- Agent 1: Agent 1, codex, gpt-5.6-terra, high
- Agent 2: Agent 2, claude, claude-sonnet-5, high
- Completed rounds: ${rounds}
- Minimum rounds: ${min}
- Maximum rounds: ${max}
- Completion reason: ${reason}
- Run directory: ${run_dir}
EOF
}

# advance_round <env-dir> <run-dir> <action> -> runs a full round and records a decision
advance_round() {
  local env_dir="$1" run_dir="$2" action="$3"
  pc "${env_dir}" run-round --run-dir "${run_dir}" > /dev/null
  local decision="${env_dir}/decision-$(basename "${run_dir}")-$RANDOM.md"
  write_decision "${decision}" "${action}"
  pc "${env_dir}" record-decision --run-dir "${run_dir}" --decision-file "${decision}"
}

# ───────────────────────────────────────────────────────────────────────────
start_case "1a. start accepts a problem file"
env1="$(new_env_dir)"
out="$(start_default "${env1}")"
assert_contains "${out}" "STATUS=initialized" "start reports initialized"
assert_contains "${out}" "ROUND=1" "start reports round 1"
run1="$(field "${out}" RUN_DIR)"
[[ -d "${run1}" ]] || fail "run directory created"
[[ "${run1}" == /* ]] || fail "run directory path is absolute"
assert_file_contains "${run1}/task.md" "Design a caching strategy" "task persisted verbatim"
snapshot1="$(field "${out}" SNAPSHOT)"
[[ -f "${snapshot1}" ]] || fail "round-1 snapshot created"

start_case "1b. start accepts a problem on stdin"
env2="$(new_env_dir)"
out="$(printf '%s\n' 'Design a caching strategy for our API' | pc "${env2}" start - \
  --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort high \
  --agent-2-harness claude --agent-2-model claude-sonnet-5 --agent-2-effort high)"
assert_contains "${out}" "STATUS=initialized" "stdin start reports initialized"
run2="$(field "${out}" RUN_DIR)"
assert_file_contains "${run2}/task.md" "Design a caching strategy for our API" "stdin task persisted"

start_case "2. missing configuration fails clearly"
env3="$(new_env_dir)"
set +e
out="$(pc "${env3}" start "${TASK_FILE}" --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort high 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "missing agent-2 configuration exits non-zero"
assert_contains "${out}" "agent 2" "error names the unconfigured agent"
assert_contains "${out}" "--list-agents --detected-only" "error explains how to inspect valid agents"
assert_contains "${out}" "--list-models" "error explains how to inspect valid models"

set +e
out="$(pc "${env3}" start "${TASK_FILE}" \
  --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort high \
  --agent-2-harness claude --agent-2-effort high 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "missing model exits non-zero"
assert_contains "${out}" "model" "missing model is named"

set +e
out="$(printf '' | pc "${env3}" start - \
  --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort high \
  --agent-2-harness claude --agent-2-model claude-sonnet-5 --agent-2-effort high 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "empty task exits non-zero"
assert_contains "${out}" "empty" "empty task error explains the problem"

start_case "3. invalid effort, timeout, and round values fail"
env4="$(new_env_dir)"
set +e
out="$(pc "${env4}" start "${TASK_FILE}" \
  --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort turbo \
  --agent-2-harness claude --agent-2-model claude-sonnet-5 --agent-2-effort high 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "invalid effort exits non-zero"
assert_contains "${out}" "low|medium|high|xhigh|max|maximum" "effort error lists allowed values"

set +e
out="$(start_default "${env4}" --timeout-seconds 0 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "zero timeout exits non-zero"
set +e
out="$(start_default "${env4}" --timeout-seconds abc 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "non-numeric timeout exits non-zero"

start_case "4. round bounds 2 <= MIN_ROUNDS <= MAX_ROUNDS <= 8 enforced"
env5="$(new_env_dir)"
for bad in "--min-rounds 1" "--max-rounds 9" "--min-rounds 5 --max-rounds 4" "--min-rounds x"; do
  set +e
  out="$(start_default "${env5}" ${bad} 2>&1)"; rc=$?; set -e
  [[ "${rc}" -ne 0 ]] || fail "rejects bounds: ${bad}"
done
out="$(start_default "${env5}" --min-rounds 2 --max-rounds 8)"
assert_contains "${out}" "STATUS=initialized" "accepts valid bounds"

start_case "5. detection and model compatibility delegate to the injected runner"
env6="$(new_env_dir)"
set +e
out="$(FAKE_UNDETECTED=codex start_default "${env6}" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "undetected harness exits non-zero"
assert_contains "${out}" "codex" "undetected harness is named"
assert_contains "${out}" "--list-agents --detected-only" "undetected error points at the runner listing"

set +e
out="$(pc "${env6}" start "${TASK_FILE}" \
  --agent-1-harness codex --agent-1-model not-a-model --agent-1-effort high \
  --agent-2-harness claude --agent-2-model claude-sonnet-5 --agent-2-effort high 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "unregistered model exits non-zero"
assert_contains "${out}" "not-a-model" "unregistered model is named"

start_case "6. both invocations use the runner interface with safe permission mode"
env7="$(new_env_dir)"
out="$(start_default "${env7}")"
run7="$(field "${out}" RUN_DIR)"
out="$(pc "${env7}" run-round --run-dir "${run7}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "complete round awaits the coordinator"
inv1="$(cat "${env7}/fake-state/gpt-5.6-terra/invocations.log")"
inv2="$(cat "${env7}/fake-state/claude-sonnet-5/invocations.log")"
for inv in "${inv1}" "${inv2}"; do
  assert_contains "${inv}" "--agent" "runner invoked with --agent"
  assert_contains "${inv}" "--model" "runner invoked with --model"
  assert_contains "${inv}" "--effort" "runner invoked with --effort"
  assert_contains "${inv}" "--context-file" "runner invoked with --context-file"
  assert_contains "${inv}" "--prompt-file" "runner invoked with --prompt-file"
  assert_contains "${inv}" "--permission-mode" "runner invoked with --permission-mode"
done
assert_contains "${inv1}" "codex" "agent 1 harness forwarded"
assert_contains "${inv1}" "gpt-5.6-terra" "agent 1 model forwarded"
assert_contains "${inv2}" "claude" "agent 2 harness forwarded"
assert_contains "${inv2}" "claude-sonnet-5" "agent 2 model forwarded"
assert_equals "safe" "$(cat "${env7}/fake-state/gpt-5.6-terra/round-1-permission-mode")" "agent 1 uses safe permission mode"
assert_equals "safe" "$(cat "${env7}/fake-state/claude-sonnet-5/round-1-permission-mode")" "agent 2 uses safe permission mode"

start_case "6b. maximum effort is normalized to max"
env7b="$(new_env_dir)"
out="$(pc "${env7b}" start "${TASK_FILE}" \
  --agent-1-harness codex --agent-1-model gpt-5.6-terra --agent-1-effort maximum \
  --agent-2-harness claude --agent-2-model claude-sonnet-5 --agent-2-effort high)"
run7b="$(field "${out}" RUN_DIR)"
assert_file_contains "${run7b}/config.json" '"effort": "max"' "maximum normalized to max in config"
pc "${env7b}" run-round --run-dir "${run7b}" > /dev/null
inv="$(cat "${env7b}/fake-state/gpt-5.6-terra/invocations.log")"
assert_contains "${inv}" "max" "normalized effort forwarded to the runner"
assert_not_contains "${inv}" "maximum" "raw maximum is not forwarded"

start_case "7. no direct provider CLI invocation or arbitrary-command escape hatch"
script_src="$(cat "${SCRIPT_PATH}")"
helper_src="$(cat "${HELPER_PATH}")"
for token in "AGENT_1_CMD" "AGENT_2_CMD" "SECONDARY_CMD" "--agent-cmd" "eval " "bash -c" "shell=True"; do
  assert_not_contains "${script_src}" "${token}" "control plane has no escape hatch"
  assert_not_contains "${helper_src}" "${token}" "process helper has no escape hatch"
done
for provider in "codex " "claude " "opencode " "gemini " "ollama " "agy "; do
  assert_not_contains "${script_src}" "\"${provider}" "no direct provider launch in the control plane"
done
assert_contains "${script_src}" "run-agent.sh" "agents launch through the unified runner"

start_case "8. round 1 gives both agents byte-identical, agent-free context"
env8="$(new_env_dir)"
out="$(start_default "${env8}")"
run8="$(field "${out}" RUN_DIR)"
pc "${env8}" run-round --run-dir "${run8}" > /dev/null
ctx_a="${env8}/fake-state/gpt-5.6-terra/round-1-context.md"
ctx_b="${env8}/fake-state/claude-sonnet-5/round-1-context.md"
cmp -s "${ctx_a}" "${ctx_b}" || fail "round-1 contexts are byte-identical"
cmp -s "${ctx_a}" "${run8}/rounds/round-01/snapshot.md" || fail "agents receive the recorded snapshot"
recorded_sha="$(cat "${run8}/rounds/round-01/snapshot.sha256")"
actual_sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${run8}/rounds/round-01/snapshot.md")"
assert_contains "${recorded_sha}" "${actual_sha}" "snapshot digest recorded"
assert_file_not_contains "${ctx_a}" "MARKER-R1" "round-1 snapshot carries no agent output"
assert_file_not_contains "${ctx_a}" "Previous round" "round-1 snapshot has no previous-round section"
assert_file_contains "${ctx_a}" "Original problem" "round-1 snapshot states the problem"
assert_file_contains "${ctx_a}" "Constraints and success criteria" "round-1 snapshot states constraints"
assert_file_contains "${ctx_a}" "p99 latency under 120ms" "round-1 snapshot carries user constraints"
assert_equals "1" "$(grep -c '^# Constraints and success criteria$' "${ctx_a}" | tr -d ' ')" \
  "round-1 snapshot states constraints exactly once even when the task carries its own heading"
assert_equals "1" "$(grep -c 'p99 latency under 120ms' "${ctx_a}" | tr -d ' ')" \
  "round-1 snapshot does not duplicate the constraint text"
assert_file_contains "${ctx_a}" "Design a caching strategy" "round-1 snapshot keeps the problem statement"

start_case "9. neither agent sees the other's current-round response"
assert_file_not_contains "${ctx_a}" "claude-sonnet-5" "agent 1 context excludes agent 2 output"
assert_file_not_contains "${ctx_b}" "gpt-5.6-terra" "agent 2 context excludes agent 1 output"
prompt_a="${env8}/fake-state/gpt-5.6-terra/round-1-prompt.md"
prompt_b="${env8}/fake-state/claude-sonnet-5/round-1-prompt.md"
assert_file_not_contains "${prompt_a}" "MARKER-R1" "agent 1 prompt excludes agent output"
assert_file_not_contains "${prompt_b}" "MARKER-R1" "agent 2 prompt excludes agent output"

start_case "12. rendered prompts contain no unresolved variables"
for f in "${prompt_a}" "${prompt_b}"; do
  assert_file_not_contains "${f}" "{{" "rendered prompt has no unresolved variables"
done
assert_file_contains "${prompt_a}" "Round 1" "prompt states the round number"
assert_file_contains "${prompt_a}" "high" "prompt states the effort level"
orig_template="$(cat "${PROMPT_TEMPLATE}")"
assert_contains "${orig_template}" "{{AGENT_NAME}}" "installed template is left untouched"

start_case "15. a round cannot reach awaiting-coordinator until both outputs are valid"
env9="$(new_env_dir)"
out="$(start_default "${env9}")"
run9="$(field "${out}" RUN_DIR)"
set +e
out="$(FAKE_FAIL_MODEL=claude-sonnet-5 FAKE_FAIL_TIMES=1 pc "${env9}" run-round --run-dir "${run9}" 2>/dev/null)"
rc=$?; set -e
assert_equals "1" "${rc}" "incomplete round exits with the retry code"
assert_contains "${out}" "STATUS=awaiting-agents" "incomplete round stays awaiting agents"
assert_file_contains "${run9}/state.json" '"phase": "awaiting-agents"' "phase unchanged after partial round"
[[ ! -f "${run9}/rounds/round-01/coordinator-decision-template.md" ]] || fail "no decision template before both outputs"

start_case "16. only the failed agent is retried against the unchanged snapshot"
sha_before="$(cat "${run9}/rounds/round-01/snapshot.sha256")"
a1_before="$(cat "${run9}/rounds/round-01/agent-1-output.md")"
a1_attempts_before="$(cat "${env9}/fake-state/gpt-5.6-terra/round-1-attempts")"
out="$(pc "${env9}" run-round --run-dir "${run9}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "retry completes the round"
assert_equals "${a1_attempts_before}" "$(cat "${env9}/fake-state/gpt-5.6-terra/round-1-attempts")" "successful agent not re-launched"
assert_equals "2" "$(cat "${env9}/fake-state/claude-sonnet-5/round-1-attempts")" "failed agent retried once"
assert_equals "${sha_before}" "$(cat "${run9}/rounds/round-01/snapshot.sha256")" "snapshot unchanged across retry"
assert_equals "${a1_before}" "$(cat "${run9}/rounds/round-01/agent-1-output.md")" "successful output preserved"
ls "${run9}/rounds/round-01/" | grep -q "attempt-01" || fail "failed attempt preserved under an attempt path"
assert_file_contains "${run9}/rounds/round-01/agent-2-attempt-01-stderr.log" "simulated harness failure" "failed attempt diagnostics preserved"
assert_file_not_contains "${env9}/fake-state/claude-sonnet-5/round-1-context.md" "MARKER-R1-gpt-5.6-terra" \
  "retrying agent never sees the other agent's response"

start_case "10 & 11. snapshots carry the previous round plus a bounded coordinator ledger"
env10="$(new_env_dir)"
out="$(start_default "${env10}")"
run10="$(field "${out}" RUN_DIR)"
advance_round "${env10}" "${run10}" CONTINUE > /dev/null
snap2="${run10}/rounds/round-02/snapshot.md"
[[ -f "${snap2}" ]] || fail "round-2 snapshot generated"
assert_file_contains "${snap2}" "MARKER-R1-gpt-5.6-terra" "round-2 snapshot carries agent 1 round-1 response"
assert_file_contains "${snap2}" "MARKER-R1-claude-sonnet-5" "round-2 snapshot carries agent 2 round-1 response"
assert_file_contains "${snap2}" "C1 with a bounded write-through path." "round-2 snapshot carries the coordinator synthesis"
assert_file_contains "${snap2}" "Coordinator focus for this round" "round-2 snapshot carries the coordinator focus"
assert_file_contains "${snap2}" "Compare eviction policies with measurements." "round-2 focus comes from the coordinator"
assert_file_contains "${snap2}" "Candidate-solution ledger" "round-2 snapshot carries the ledger"
assert_file_contains "${snap2}" "Rejected candidates" "round-2 snapshot carries rejected candidates"
assert_file_contains "${snap2}" "Original problem" "round-2 snapshot restates the immutable problem"
assert_equals "1" "$(grep -c '^# Constraints and success criteria$' "${snap2}" | tr -d ' ')" \
  "round-2 snapshot states constraints exactly once"
for heading in "# Original problem" "# Candidate-solution ledger" "# Coordinator focus for this round" \
               "# Previous round: Agent 1" "# Previous round: Agent 2"; do
  assert_equals "1" "$(grep -c "^${heading}\$" "${snap2}" | tr -d ' ')" \
    "round-2 snapshot has exactly one '${heading}' section"
done

advance_round "${env10}" "${run10}" CONTINUE > /dev/null
snap3="${run10}/rounds/round-03/snapshot.md"
[[ -f "${snap3}" ]] || fail "round-3 snapshot generated"
assert_file_contains "${snap3}" "MARKER-R2-gpt-5.6-terra" "round-3 snapshot carries the previous round"
assert_file_not_contains "${snap3}" "MARKER-R1-gpt-5.6-terra" "round-3 snapshot drops unbounded raw history"
assert_file_not_contains "${snap3}" "MARKER-R1-claude-sonnet-5" "round-3 snapshot drops unbounded raw history"
[[ -f "${run10}/rounds/round-01/agent-1-output.md" ]] || fail "full history preserved on disk"

start_case "13. run directories and attempt artifacts never overwrite prior data"
env11="$(new_env_dir)"
outa="$(start_default "${env11}")"
outb="$(start_default "${env11}")"
dir_a="$(field "${outa}" RUN_DIR)"
dir_b="$(field "${outb}" RUN_DIR)"
[[ "${dir_a}" != "${dir_b}" ]] || fail "concurrent starts produce distinct run directories"
[[ -d "${dir_a}" && -d "${dir_b}" ]] || fail "both run directories survive"

start_case "14. exact status parsing rejects malformed or trailing output"
for mode in trailing duplicate-status missing-section bad-status duplicate-section empty; do
  env_bad="$(new_env_dir)"
  out="$(start_default "${env_bad}")"
  run_bad="$(field "${out}" RUN_DIR)"
  set +e
  out="$(FAKE_BAD_OUTPUT_MODE="${mode}" FAKE_BAD_OUTPUT_MODEL=claude-sonnet-5 \
    MAX_AGENT_ATTEMPTS=1 pc "${env_bad}" run-round --run-dir "${run_bad}" 2>/dev/null)"
  rc=$?; set -e
  [[ "${rc}" -ne 0 ]] || fail "malformed output rejected (${mode})"
  assert_not_contains "${out}" "STATUS=awaiting-coordinator" "malformed output does not complete the round (${mode})"
  [[ ! -f "${run_bad}/rounds/round-01/agent-2-output.md" ]] || fail "malformed output not promoted to canonical (${mode})"
done

start_case "17. timeout terminates the process group and preserves diagnostics"
env12="$(new_env_dir)"
out="$(start_default "${env12}" --timeout-seconds 2)"
run12="$(field "${out}" RUN_DIR)"
set +e
out="$(FAKE_HANG_MODEL=claude-sonnet-5 MAX_AGENT_ATTEMPTS=1 pc "${env12}" run-round --run-dir "${run12}" 2>/dev/null)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "timeout does not complete the round"
hang_pid="$(cat "${env12}/fake-state/hang-child.pid" 2>/dev/null || true)"
[[ -n "${hang_pid}" ]] || fail "hanging child recorded a pid"
if [[ -n "${hang_pid}" ]] && kill -0 "${hang_pid}" 2>/dev/null; then
  kill -9 "${hang_pid}" 2>/dev/null || true
  fail "timeout terminated the whole process group"
fi
assert_file_contains "${run12}/rounds/round-01/agent-2-attempt-01-run.json" '"timed_out": true' "timeout recorded in the attempt result"
[[ -f "${run12}/rounds/round-01/agent-2-attempt-01-stderr.log" ]] || fail "timeout preserves stderr diagnostics"
assert_file_contains "${run12}/state.json" '"phase":' "state remains readable JSON after timeout"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "${run12}/state.json" || fail "state.json is valid JSON after timeout"
assert_file_contains "${run12}/rounds/round-01/agent-1-output.md" "MARKER-R1" "successful agent preserved across the failed round"

start_case "17b. exhausted attempts stop the run as blocked, not falsely conclusive"
env13="$(new_env_dir)"
out="$(start_default "${env13}")"
run13="$(field "${out}" RUN_DIR)"
set +e
out="$(FAKE_FAIL_MODEL=claude-sonnet-5 MAX_AGENT_ATTEMPTS=2 pc "${env13}" run-round --run-dir "${run13}" 2>/dev/null)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "blocked run exits non-zero"
set +e
out="$(FAKE_FAIL_MODEL=claude-sonnet-5 MAX_AGENT_ATTEMPTS=2 pc "${env13}" run-round --run-dir "${run13}" 2>/dev/null)"
rc=$?; set -e
assert_contains "${out}" "COMPLETION_REASON=blocked" "exhausted retries report blocked"
dossier13="${env13}/final.md"
write_dossier "${dossier13}" 1 "coordinator-accepted" "${run13}"
set +e
out="$(pc "${env13}" finalize --run-dir "${run13}" --final-file "${dossier13}" 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "blocked run cannot be finalized"

start_case "18. ACCEPT is rejected before the minimum completed rounds"
env14="$(new_env_dir)"
out="$(start_default "${env14}")"
run14="$(field "${out}" RUN_DIR)"
pc "${env14}" run-round --run-dir "${run14}" > /dev/null
decision="${env14}/d1.md"
write_decision "${decision}" ACCEPT
state_before="$(cat "${run14}/state.json")"
set +e
out="$(pc "${env14}" record-decision --run-dir "${run14}" --decision-file "${decision}" 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "early ACCEPT is rejected"
assert_contains "${out}" "minimum" "early ACCEPT error explains the minimum"
assert_equals "${state_before}" "$(cat "${run14}/state.json")" "rejected ACCEPT leaves state unchanged"

start_case "19. CONTINUE works after the minimum and before the maximum"
out="$(pc "${env14}" record-decision --run-dir "${run14}" --decision-file "${env14}/c1.md" 2>/dev/null || true)"
write_decision "${env14}/c1.md" CONTINUE
out="$(pc "${env14}" record-decision --run-dir "${run14}" --decision-file "${env14}/c1.md")"
assert_contains "${out}" "STATUS=continue" "CONTINUE advances the run"
assert_contains "${out}" "ROUND=2" "CONTINUE advances the round counter"
advance_round "${env14}" "${run14}" CONTINUE > /dev/null   # round 2 -> 3
pc "${env14}" run-round --run-dir "${run14}" > /dev/null   # round 3 complete
write_decision "${env14}/c3.md" CONTINUE
out="$(pc "${env14}" record-decision --run-dir "${run14}" --decision-file "${env14}/c3.md")"
assert_contains "${out}" "STATUS=continue" "CONTINUE valid at the minimum"

start_case "21. the coordinator may accept despite advisory agent disagreement"
env15="$(new_env_dir)"
out="$(FAKE_READY_MODEL=all start_default "${env15}" --min-rounds 2 --max-rounds 4)"
run15="$(field "${out}" RUN_DIR)"
set +e
out="$(FAKE_READY_MODEL=all pc "${env15}" run-round --run-dir "${run15}")"; set -e
write_decision "${env15}/r1.md" ACCEPT
set +e
out="$(pc "${env15}" record-decision --run-dir "${run15}" --decision-file "${env15}/r1.md" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "agent READY cannot bypass the minimum"
write_decision "${env15}/r1c.md" CONTINUE
pc "${env15}" record-decision --run-dir "${run15}" --decision-file "${env15}/r1c.md" > /dev/null
FAKE_READY_MODEL=all pc "${env15}" run-round --run-dir "${run15}" > /dev/null
# Agents still disagree in their advisory sections; the coordinator accepts anyway.
write_decision "${env15}/r2.md" ACCEPT
out="$(pc "${env15}" record-decision --run-dir "${run15}" --decision-file "${env15}/r2.md")"
assert_contains "${out}" "STATUS=awaiting-final" "coordinator accepts after the minimum"
assert_contains "${out}" "COMPLETION_REASON=coordinator-accepted" "acceptance reason recorded"

start_case "20. CONTINUE is rejected after the maximum round"
env16="$(new_env_dir)"
out="$(start_default "${env16}" --min-rounds 2 --max-rounds 2)"
run16="$(field "${out}" RUN_DIR)"
advance_round "${env16}" "${run16}" CONTINUE > /dev/null
pc "${env16}" run-round --run-dir "${run16}" > /dev/null
write_decision "${env16}/max.md" CONTINUE
state_before="$(cat "${run16}/state.json")"
set +e
out="$(pc "${env16}" record-decision --run-dir "${run16}" --decision-file "${env16}/max.md" 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "CONTINUE at the maximum round is rejected"
assert_contains "${out}" "maximum" "max-round error explains the hard stop"
assert_equals "${state_before}" "$(cat "${run16}/state.json")" "rejected CONTINUE leaves state unchanged"
write_decision "${env16}/max-accept.md" ACCEPT
out="$(pc "${env16}" record-decision --run-dir "${run16}" --decision-file "${env16}/max-accept.md")"
assert_contains "${out}" "COMPLETION_REASON=maximum-rounds" "final-round acceptance reports maximum-rounds"

start_case "23. the final dossier validator requires every section and consistent metadata"
final16="${env16}/final.md"
write_dossier "${final16}" 3 "maximum-rounds" "${run16}" 2 2
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "inconsistent round count rejected"
assert_contains "${out}" "Completed rounds" "round-count mismatch is named"

write_dossier "${final16}" 2 "coordinator-accepted" "${run16}" 2 2
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "conflicting completion reason rejected"
assert_contains "${out}" "Completion reason" "completion-reason mismatch is named"

write_dossier "${final16}" 2 "maximum-rounds" "${run16}" 2 2
grep -v '^## Risks and mitigations$' "${final16}" > "${final16}.missing"
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}.missing" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "missing section rejected"
assert_contains "${out}" "Risks and mitigations" "missing section is named"

write_dossier "${final16}" 2 "maximum-rounds" "${run16}" 2 2
printf '\n## Executive summary\nduplicate\n' >> "${final16}.dup"
cat "${final16}" "${final16}.dup" > "${final16}.dup2" 2>/dev/null || cp "${final16}" "${final16}.dup2"
printf '\n## Executive summary\nduplicate heading\n' >> "${final16}.dup2"
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}.dup2" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "duplicate heading rejected"

write_dossier "${final16}" 2 "maximum-rounds" "${run16}" 2 2
sed 's|^Adopt the edge cache with a bounded write-through path.$|<selected solution and outcome>|' "${final16}" > "${final16}.placeholder"
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}.placeholder" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "placeholder text rejected"
assert_contains "${out}" "placeholder" "placeholder rejection is explained"

write_dossier "${final16}" 2 "maximum-rounds" "${run16}" 2 2
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}")"
assert_contains "${out}" "STATUS=complete" "valid dossier finalizes the run"
assert_contains "${out}" "FINAL=" "finalize reports the dossier path"
[[ -f "${run16}/final-solution.md" ]] || fail "final dossier persisted"
assert_file_contains "${run16}/final-solution.md" "Executive summary" "persisted dossier content"

start_case "22. a completed run cannot be advanced or finalized twice"
set +e
out="$(pc "${env16}" run-round --run-dir "${run16}" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "completed run rejects run-round"
set +e
out="$(pc "${env16}" record-decision --run-dir "${run16}" --decision-file "${env16}/max-accept.md" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "completed run rejects record-decision"
final_before="$(cat "${run16}/final-solution.md")"
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}" 2>&1)"; rc=$?; set -e
assert_equals "0" "${rc}" "re-finalizing with identical bytes converges instead of failing"
assert_equals "${final_before}" "$(cat "${run16}/final-solution.md")" "an idempotent finalize does not rewrite the dossier"
printf '\nA different closing sentence.\n' >> "${final16}.conflict" 2>/dev/null || true
cat "${final16}" > "${final16}.conflict"
sed -i.bak 's|^Adopt the edge cache with a bounded write-through path.$|Adopt the origin cache instead.|' "${final16}.conflict"
set +e
out="$(pc "${env16}" finalize --run-dir "${run16}" --final-file "${final16}.conflict" 2>&1)"; rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "a conflicting second finalize is rejected"
assert_contains "${out}" "already finalized" "the conflicting finalize names the existing dossier"
assert_equals "${final_before}" "$(cat "${run16}/final-solution.md")" "a rejected finalize leaves the dossier untouched"
out="$(pc "${env16}" status --run-dir "${run16}")"
assert_contains "${out}" "STATUS=complete" "status reports the completed run"
assert_contains "${out}" "COMPLETION_REASON=maximum-rounds" "status reports the completion reason"

start_case "24. coordinator decision template is generated for the coordinator"
env17="$(new_env_dir)"
out="$(start_default "${env17}")"
run17="$(field "${out}" RUN_DIR)"
out="$(pc "${env17}" run-round --run-dir "${run17}")"
tmpl="$(field "${out}" DECISION_TEMPLATE)"
[[ -f "${tmpl}" ]] || fail "decision template generated"
assert_file_contains "${tmpl}" "COORDINATOR_ACTION: CONTINUE" "template carries the action contract"
assert_file_contains "${tmpl}" "# Candidate-solution ledger" "template carries the ledger section"
a1_out="$(field "${out}" AGENT_1_OUTPUT)"
a2_out="$(field "${out}" AGENT_2_OUTPUT)"
[[ -f "${a1_out}" && -f "${a2_out}" ]] || fail "run-round reports both output paths"

start_case "24b. the default agent timeout is 60 minutes and is persisted"
env_t="$(new_env_dir)"
out="$(start_default "${env_t}")"
run_t="$(field "${out}" RUN_DIR)"
assert_file_contains "${run_t}/config.json" '"timeout_seconds": 3600' "default timeout persisted to config"
assert_file_contains "${run_t}/state.json" '"timeout_seconds": 3600' "default timeout persisted to state"
out="$(start_default "${env_t}" --timeout-seconds 5400)"
run_t2="$(field "${out}" RUN_DIR)"
assert_file_contains "${run_t2}/config.json" '"timeout_seconds": 5400' "explicit timeout overrides the default"

start_case "25. config persists only non-secret effective configuration"
cfg="$(cat "${run17}/config.json")"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "${run17}/config.json" || fail "config.json is valid JSON"
assert_contains "${cfg}" "codex" "config records agent 1 harness"
assert_not_contains "${cfg}" "PATH" "config carries no environment dump"
assert_not_contains "${cfg}" "TOKEN" "config carries no credentials"
assert_not_contains "${cfg}" "FAKE_STATE_DIR" "config carries no unrelated environment"

start_case "26. help and status are side-effect free"
out="$(pc "${env17}" --help)"
assert_contains "${out}" "start" "help documents start"
assert_contains "${out}" "run-round" "help documents run-round"
assert_contains "${out}" "record-decision" "help documents record-decision"
assert_contains "${out}" "finalize" "help documents finalize"
assert_contains "${out}" "status" "help documents status"
state_before="$(cat "${run17}/state.json")"
pc "${env17}" status --run-dir "${run17}" > /dev/null
assert_equals "${state_before}" "$(cat "${run17}/state.json")" "status does not mutate state"

start_case "27. missing assets are reported with the exact missing files"
empty_dir="${SANDBOX}/empty-assets"
mkdir -p "${empty_dir}"
cp "${SCRIPT_PATH}" "${empty_dir}/pair-colleague.sh"
isolated_cwd="${SANDBOX}/isolated-cwd"
mkdir -p "${isolated_cwd}"
set +e
out="$(cd "${isolated_cwd}" && PAIR_COLLEAGUE_ASSETS_DIR="${empty_dir}" ASSETS_DEST="${empty_dir}" \
  HOME="${SANDBOX}/nohome" bash "${empty_dir}/pair-colleague.sh" status --run-dir "${empty_dir}" 2>&1)"
rc=$?; set -e
[[ "${rc}" -ne 0 ]] || fail "incomplete asset root fails"
assert_contains "${out}" "run-agent.sh" "missing asset list names the runner"
assert_contains "${out}" "agent-registry.json" "missing asset list names the registry"

start_case "28. skill and prompt contracts"
skill_src="$(cat "${SKILL_PATH}")"
assert_contains "${skill_src}" "one question at a time" "skill asks for missing configuration one question at a time"
assert_contains "${skill_src}" "run-round" "skill documents run-round"
assert_contains "${skill_src}" "record-decision" "skill documents record-decision"
assert_contains "${skill_src}" "finalize" "skill documents finalize"
assert_contains "${skill_src}" "COORDINATOR_ACTION" "skill documents the decision contract"
assert_contains "${skill_src}" "never guess" "skill forbids guessing configuration"
assert_not_contains "${skill_src}" "AGENT_1_CMD" "skill has no arbitrary command escape hatch"
template_src="$(cat "${PROMPT_TEMPLATE}")"
for var in "{{AGENT_NAME}}" "{{OTHER_AGENT_NAME}}" "{{ROUND_NUMBER}}" "{{MIN_ROUNDS}}" "{{MAX_ROUNDS}}" "{{EFFORT_LEVEL}}"; do
  assert_contains "${template_src}" "${var}" "prompt template declares ${var}"
done
assert_contains "${template_src}" "DISCUSSION_STATUS: CONTINUE" "prompt template carries the status contract"
assert_contains "${template_src}" "equal solution colleague" "prompt template frames agents as equal colleagues"
assert_contains "${template_src}" "must not modify files" "prompt template forbids implementation"
assert_not_contains "${template_src}" "reviewer" "prompt template does not cast an agent as reviewer"
assert_not_contains "${template_src}" "score" "prompt template does not ask for scoring"

start_case "29. a second concurrent run-round never launches a duplicate agent"
env29="$(new_env_dir)"
out="$(start_default "${env29}")"
run29="$(field "${out}" RUN_DIR)"
FAKE_SLEEP_SECONDS=6 pc_bg "${env29}" "${env29}/first.out" run-round --run-dir "${run29}"
first_pid="${PC_BG_PID}"
# Wait until the first command has actually launched both agents.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${env29}/fake-state/gpt-5.6-terra/round-1-attempts" ]] && break
  sleep 0.5
done
set +e
out="$(pc "${env29}" run-round --run-dir "${run29}" 2>&1)"; rc=$?
set -e
assert_equals "4" "${rc}" "a concurrent run-round exits with the busy code"
assert_contains "${out}" "busy" "the concurrent run-round explains that the run is busy"
wait "${first_pid}" || true
assert_equals "1" "$(cat "${env29}/fake-state/gpt-5.6-terra/round-1-attempts")" \
  "the concurrent call did not launch a second agent 1"
assert_equals "1" "$(cat "${env29}/fake-state/claude-sonnet-5/round-1-attempts")" \
  "the concurrent call did not launch a second agent 2"
assert_file_contains "${env29}/first.out" "STATUS=awaiting-coordinator" "the first run-round still completed the round"

start_case "30. agents orphaned by a killed coordinator are recovered, not relaunched"
env30="$(new_env_dir)"
out="$(start_default "${env30}")"
run30="$(field "${out}" RUN_DIR)"
FAKE_SLEEP_SECONDS=8 pc_bg "${env30}" "${env30}/orphan.out" run-round --run-dir "${run30}"
orphan_pid="${PC_BG_PID}"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${env30}/fake-state/gpt-5.6-terra/round-1-attempts" ]] && break
  sleep 0.5
done
# Kill only the coordinator. The supervisor and both agents keep working, which
# is exactly the state a lost terminal or cancelled tool call leaves behind.
kill -9 "${orphan_pid}" 2>/dev/null || true
wait "${orphan_pid}" 2>/dev/null || true
set +e
out="$(pc "${env30}" run-round --run-dir "${run30}" 2>&1)"; rc=$?
set -e
assert_equals "4" "${rc}" "run-round refuses while orphaned agents are still working"
assert_contains "${out}" "LAUNCH=busy" "the refusal reports LAUNCH=busy"
assert_contains "${out}" "still running" "the refusal explains that earlier agents are still running"
out="$(pc "${env30}" status --run-dir "${run30}")"
assert_contains "${out}" "LIVE_AGENTS=1 2" "status reports both colleagues as live without taking the lock"
assert_equals "1" "$(cat "${env30}/fake-state/gpt-5.6-terra/round-1-attempts")" "no relaunch while the orphan is alive"

# Let the orphaned agents finish, then collect their work without paying again.
for _ in $(seq 1 40); do
  out="$(pc "${env30}" status --run-dir "${run30}")"
  [[ "$(field "${out}" LIVE_AGENTS)" == "" ]] && break
  sleep 0.5
done
out="$(pc "${env30}" run-round --run-dir "${run30}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "the orphaned round completes from its recovered output"
assert_equals "1" "$(cat "${env30}/fake-state/gpt-5.6-terra/round-1-attempts")" "recovery reused agent 1 output instead of relaunching"
assert_equals "1" "$(cat "${env30}/fake-state/claude-sonnet-5/round-1-attempts")" "recovery reused agent 2 output instead of relaunching"
assert_file_contains "${run30}/rounds/round-01/agent-1-output.md" "MARKER-R1" "recovered output promoted to canonical"

start_case "31. a stale lock left by a dead process is cleared automatically"
env31="$(new_env_dir)"
out="$(start_default "${env31}")"
run31="$(field "${out}" RUN_DIR)"
mkdir -p "${run31}/.lock"
printf 'stale-token\n' > "${run31}/.lock/token"
printf '%s\n' "$(hostname)" > "${run31}/.lock/host"
printf '999999\n' > "${run31}/.lock/pid"
printf 'run-round\n' > "${run31}/.lock/command"
printf '1970-01-01T00:00:00Z\n' > "${run31}/.lock/started_at"
out="$(pc "${env31}" run-round --run-dir "${run31}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "a lock owned by a dead pid does not block the run"
[[ ! -d "${run31}/.lock" ]] || fail "the lock is released when the command finishes"

start_case "31b. a lock recorded on another host is refused until it is broken"
env31b="$(new_env_dir)"
out="$(start_default "${env31b}")"
run31b="$(field "${out}" RUN_DIR)"
mkdir -p "${run31b}/.lock"
printf 'foreign-token\n' > "${run31b}/.lock/token"
printf 'some-other-machine\n' > "${run31b}/.lock/host"
printf '4321\n' > "${run31b}/.lock/pid"
printf 'run-round\n' > "${run31b}/.lock/command"
printf '1970-01-01T00:00:00Z\n' > "${run31b}/.lock/started_at"
set +e
out="$(pc "${env31b}" run-round --run-dir "${run31b}" 2>&1)"; rc=$?
set -e
assert_equals "4" "${rc}" "a foreign-host lock is reported busy rather than assumed dead"
assert_contains "${out}" "--break-lock" "the foreign-host refusal explains how to override it"
out="$(pc "${env31b}" run-round --run-dir "${run31b}" --break-lock)"
assert_contains "${out}" "STATUS=awaiting-coordinator" "--break-lock takes the lock deliberately"

start_case "32. signalling the supervisor kills the whole agent process tree"
if command -v pgrep >/dev/null 2>&1; then
  env32="$(new_env_dir)"
  out="$(start_default "${env32}" --timeout-seconds 600)"
  run32="$(field "${out}" RUN_DIR)"
  FAKE_HANG_MODEL=claude-sonnet-5 pc_bg "${env32}" "${env32}/signal.out" run-round --run-dir "${run32}"
  sig_pid="${PC_BG_PID}"
  supervisor=""
  for _ in $(seq 1 40); do
    supervisor="$(pgrep -f 'pair-colleague-process.py run-pair' | head -n1 || true)"
    [[ -n "${supervisor}" && -f "${env32}/fake-state/hang-child.pid" ]] && break
    sleep 0.5
  done
  [[ -n "${supervisor}" ]] || fail "the agent supervisor was found"
  grandchild="$(cat "${env32}/fake-state/hang-child.pid" 2>/dev/null || true)"
  kill -TERM "${supervisor}" 2>/dev/null || true
  wait "${sig_pid}" 2>/dev/null || true
  sleep 1
  if [[ -n "${grandchild}" ]] && kill -0 "${grandchild}" 2>/dev/null; then
    kill -9 "${grandchild}" 2>/dev/null || true
    fail "a signalled supervisor terminates the agent's grandchild process"
  fi
  assert_file_contains "${run32}/rounds/round-01/agent-2-attempt-01-run.json" '"interrupted": true' \
    "the interrupted attempt is recorded as interrupted"
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "${run32}/state.json" ||
    fail "state.json remains valid JSON after an interrupted supervisor"
else
  note_skipped=1
fi

start_case "33. an interrupted transition converges on identical input and rejects a conflict"
env33="$(new_env_dir)"
out="$(start_default "${env33}" --min-rounds 2 --max-rounds 4)"
run33="$(field "${out}" RUN_DIR)"
pc "${env33}" run-round --run-dir "${run33}" > /dev/null
write_decision "${env33}/d.md" CONTINUE
# Simulate a crash between writing the decision and patching state.
cp "${env33}/d.md" "${run33}/rounds/round-01/coordinator-decision.md"
out="$(pc "${env33}" record-decision --run-dir "${run33}" --decision-file "${env33}/d.md")"
assert_contains "${out}" "STATUS=continue" "the interrupted decision transition completes on retry"
assert_contains "${out}" "ROUND=2" "the retried transition advances the round exactly once"
[[ -f "${run33}/rounds/round-02/snapshot.md" ]] || fail "the retried transition built the next snapshot"

env33b="$(new_env_dir)"
out="$(start_default "${env33b}" --min-rounds 2 --max-rounds 4)"
run33b="$(field "${out}" RUN_DIR)"
pc "${env33b}" run-round --run-dir "${run33b}" > /dev/null
write_decision "${env33b}/first.md" CONTINUE "Measure eviction cost precisely."
cp "${env33b}/first.md" "${run33b}/rounds/round-01/coordinator-decision.md"
write_decision "${env33b}/second.md" CONTINUE "A completely different focus."
state_before="$(cat "${run33b}/state.json")"
set +e
out="$(pc "${env33b}" record-decision --run-dir "${run33b}" --decision-file "${env33b}/second.md" 2>&1)"; rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "a conflicting decision is rejected"
assert_contains "${out}" "coordinator-decision.md" "the conflict names the artifact that already exists"
assert_equals "${state_before}" "$(cat "${run33b}/state.json")" "a rejected conflict leaves state untouched"

start_case "34. every round runs in the workspace the run was started in"
env34="$(new_env_dir)"
workspace_a="${env34}/workspace-a"
workspace_b="${env34}/workspace-b"
mkdir -p "${workspace_a}" "${workspace_b}"
workspace_a="$(cd "${workspace_a}" && pwd -P)"
workspace_b="$(cd "${workspace_b}" && pwd -P)"
out="$(cd "${workspace_a}" && start_default "${env34}")"
run34="$(field "${out}" RUN_DIR)"
assert_contains "${out}" "WORKSPACE_ROOT=${workspace_a}" "start records the workspace it was invoked in"
# Resume from a different directory, with a conflicting inherited REPO_ROOT.
out="$(cd "${workspace_b}" && REPO_ROOT="${workspace_b}" pc "${env34}" run-round --run-dir "${run34}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "the round runs after resuming elsewhere"
assert_equals "${workspace_a}" "$(cat "${env34}/fake-state/gpt-5.6-terra/round-1-cwd")" \
  "the agent is launched in the recorded workspace, not the resume directory"
assert_equals "${workspace_a}" "$(cat "${env34}/fake-state/gpt-5.6-terra/round-1-repo-root")" \
  "the inherited REPO_ROOT is overridden with the recorded workspace"

start_case "35. a run with no recorded workspace must be bound explicitly"
env35="$(new_env_dir)"
out="$(start_default "${env35}")"
run35="$(field "${out}" RUN_DIR)"
python3 - "${run35}/state.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
state.pop("workspace_root", None)
state["schema_version"] = 1
json.dump(state, open(path, "w"), indent=2)
PYEOF
set +e
out="$(pc "${env35}" run-round --run-dir "${run35}" 2>&1)"; rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "an unbound legacy run does not silently adopt the current directory"
assert_contains "${out}" "--bind-workspace" "the error explains how to bind the run"
assert_equals "0" "$(cat "${env35}/fake-state/gpt-5.6-terra/round-1-attempts" 2>/dev/null || echo 0)" \
  "no agent is launched before the workspace is bound"
env35_real="$(cd "${env35}" && pwd -P)"
out="$(pc "${env35}" run-round --run-dir "${run35}" --bind-workspace "${env35}")"
assert_contains "${out}" "STATUS=awaiting-coordinator" "an explicitly bound legacy run proceeds"
assert_contains "${out}" "WORKSPACE_ROOT=${env35_real}" "the binding is persisted"

start_case "36. native Windows is refused before anything is launched"
env36="$(new_env_dir)"
set +e
out="$(PAIR_COLLEAGUE_UNAME_OVERRIDE="MINGW64_NT-10.0" start_default "${env36}" 2>&1)"; rc=$?
set -e
assert_equals "2" "${rc}" "native Windows exits with the configuration error code"
assert_contains "${out}" "WSL" "the Windows refusal directs the user to WSL"
assert_contains "${out}" "not supported" "the Windows refusal is explicit"
[[ -z "$(ls -A "${env36}/runs" 2>/dev/null)" ]] || fail "no run directory is created on an unsupported platform"

start_case "37. validation treats fenced Markdown as an example, not as structure"
env37="$(new_env_dir)"
out="$(start_default "${env37}" --min-rounds 2 --max-rounds 2)"
run37="$(field "${out}" RUN_DIR)"
advance_round "${env37}" "${run37}" CONTINUE > /dev/null
pc "${env37}" run-round --run-dir "${run37}" > /dev/null
write_decision "${env37}/accept.md" ACCEPT
pc "${env37}" record-decision --run-dir "${run37}" --decision-file "${env37}/accept.md" > /dev/null

final37="${env37}/final.md"
write_dossier "${final37}" 2 "maximum-rounds" "${run37}" 2 2
# A dossier is allowed to quote the very template it was built from.
python3 - "${final37}" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
example = (
    "\nThe template each colleague filled in looks like this:\n\n"
    "```markdown\n"
    "# Candidate analysis\n\n"
    "<analysis of current candidates>\n\n"
    "# Preferred solution\n\n"
    "TODO: the colleague fills this in\n\n"
    "DISCUSSION_STATUS: CONTINUE\n"
    "```\n\n"
    "Rendering substitutes `{{AGENT_NAME}}` before launch.\n"
)
marker = "## Implementation approach\n"
text = text.replace(marker, marker + example, 1)
open(path, "w").write(text)
PYEOF
out="$(pc "${env37}" finalize --run-dir "${run37}" --final-file "${final37}" 2>&1)" ||
  fail "a dossier quoting the template inside a fence is accepted: ${out}"
assert_contains "${out}" "STATUS=complete" "the fenced example does not break finalization"

start_case "37b. an untouched coordinator template is rejected"
env37b="$(new_env_dir)"
out="$(start_default "${env37b}")"
run37b="$(field "${out}" RUN_DIR)"
out="$(pc "${env37b}" run-round --run-dir "${run37b}")"
tmpl37="$(field "${out}" DECISION_TEMPLATE)"
set +e
out="$(pc "${env37b}" record-decision --run-dir "${run37b}" --decision-file "${tmpl37}" 2>&1)"; rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "an unfilled decision template is rejected"
assert_contains "${out}" "placeholder" "the unfilled template is rejected as placeholder text"
[[ ! -f "${run37b}/rounds/round-01/coordinator-decision.md" ]] || fail "the unfilled template is not recorded"

start_case "38. an altered colleague response cannot be carried into the next round"
env38="$(new_env_dir)"
out="$(start_default "${env38}" --min-rounds 2 --max-rounds 4)"
run38="$(field "${out}" RUN_DIR)"
pc "${env38}" run-round --run-dir "${run38}" > /dev/null
printf '\nInjected sentence that the colleague never wrote.\n' >> "${run38}/rounds/round-01/agent-1-output.md"
write_decision "${env38}/d.md" CONTINUE
set +e
out="$(pc "${env38}" record-decision --run-dir "${run38}" --decision-file "${env38}/d.md" 2>&1)"; rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "an altered colleague response is rejected"
assert_contains "${out}" "changed after" "the integrity failure explains what changed"
[[ ! -f "${run38}/rounds/round-02/snapshot.md" ]] || fail "no next snapshot is built from altered context"

start_case "39. a harness with no read-only profile is refused at start"
registry39="${SANDBOX}/registry-no-read-only.json"
python3 - "${REGISTRY_PATH}" "${registry39}" <<'PYEOF'
import json, sys
registry = json.load(open(sys.argv[1]))
registry["agents"]["codex"]["permission_modes"].pop("read_only", None)
json.dump(registry, open(sys.argv[2], "w"), indent=2)
PYEOF
env39="$(new_env_dir)"
set +e
out="$(TEST_REGISTRY_OVERRIDE="${registry39}" start_default "${env39}" 2>&1)"; rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "a harness without a read-only profile is refused"
assert_contains "${out}" "read-only" "the refusal names the missing read-only profile"
assert_contains "${out}" "codex" "the refusal names the harness"
[[ -z "$(ls -A "${env39}/runs" 2>/dev/null)" ]] || fail "no run is created for an unsafe harness"
out="$(TEST_REGISTRY_OVERRIDE="${registry39}" PAIR_COLLEAGUE_ALLOW_UNVERIFIED_SAFE=1 start_default "${env39}" 2>&1)"
assert_contains "${out}" "STATUS=initialized" "the documented opt-in allows an unverified harness"
run39="$(field "${out}" RUN_DIR)"
assert_file_contains "${run39}/config.json" '"safety_profile": "unverified"' \
  "the run records that the harness safety profile is unverified"

start_case "39b. the registry resolves safe mode to a real write-denying flag"
for agent in codex claude; do
  mode="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["agents"][sys.argv[2]]["permission_modes"].get("read_only",""))' "${REGISTRY_PATH}" "${agent}")"
  [[ -n "${mode}" ]] || fail "${agent} declares a read-only permission mode"
  assert_not_contains "${mode}" "dangerously" "${agent} read-only mode is not a bypass flag"
  assert_not_contains "${mode}" "workspace-write" "${agent} read-only mode does not grant workspace writes"
done
runner_src="$(cat "${ROOT_DIR}/assets/run-agent.sh")"
assert_contains "${runner_src}" "read_only_permission" "the runner resolves safe mode from the registry"
assert_not_contains "${runner_src}" 'AGENT_PERMISSION_MODE=""
fi' "safe mode no longer resolves to an empty permission argument"

start_case "40. repository integration stays consistent"
mirror="${ROOT_DIR}/.agents/skills/pair-colleague/SKILL.md"
[[ -f "${mirror}" ]] || fail "the agent skill mirror exists"
cmp -s "${SKILL_PATH}" "${mirror}" || fail "both skill copies are byte-identical"
assert_file_contains "${ROOT_DIR}/.gitignore" ".pair-colleague/" "generated run artifacts are ignored"
assert_file_contains "${ROOT_DIR}/uninstall.sh" "pair-colleague" "uninstall.sh removes the skill"
assert_file_contains "${ROOT_DIR}/uninstall.ps1" "pair-colleague" "uninstall.ps1 removes the skill"
assert_file_contains "${ROOT_DIR}/install.sh" "pair-colleague.sh" "install.sh ships the control plane"
assert_file_not_contains "${ROOT_DIR}/install.ps1" "pair-colleague.sh" "install.ps1 does not ship the Bash control plane"
assert_file_contains "${ROOT_DIR}/install.ps1" "WSL" "install.ps1 points Windows users at WSL"
[[ ! -f "${ROOT_DIR}/pair-colleague-implementation-prompt.md" ]] || fail "the implementation prompt is not left in the repository root"
assert_file_contains "${SKILL_PATH}" "uname -s" "the skill checks the platform before running"
assert_file_contains "${SKILL_PATH}" "WSL" "the skill directs Windows users to WSL"
assert_file_contains "${SKILL_PATH}" "reap" "the skill documents deliberate recovery"

# ── Result ─────────────────────────────────────────────────────────────────
if [[ "${FAILURES}" -gt 0 ]]; then
  printf '%d pair-colleague contract failure(s)\n' "${FAILURES}" >&2
  exit 1
fi
echo "PASS: pair-colleague contract"

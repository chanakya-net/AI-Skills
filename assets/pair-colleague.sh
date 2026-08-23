#!/usr/bin/env bash
# pair-colleague.sh — control plane for the two-agent solution coordinator.
#
# The invoking AI agent is the coordinator. This script owns run state, the
# frozen per-round context, agent launching through the unified runner, and the
# mechanical parts of the round policy. It never builds a provider command line
# and never executes a user-supplied command string: every agent launch goes
# through run-agent.sh with the registry as the single source of truth.
#
# Every mutating command holds an exclusive per-run lock and reconciles the
# liveness of previously launched agents before spending money on a new one.
# Repeating a mutating command with identical input converges on the same
# committed state; repeating it with different input fails and names the
# conflicting artifact.
#
# Exit codes:
#   0  command succeeded
#   1  round incomplete; call run-round again to retry the failed colleague
#   2  usage, configuration, validation, or invalid-state-transition error
#   3  run is blocked by unrecoverable infrastructure failures
#   4  the run is busy: another command holds the lock, or launched agents are
#      still working. Nothing was changed; wait, or use reap deliberately.
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd -P)"

EXIT_OK=0
EXIT_RETRY=1
EXIT_ERROR=2
EXIT_BLOCKED=3
EXIT_BUSY=4

REQUIRED_ASSETS=(
  "pair-colleague.sh"
  "pair-colleague-process.py"
  "pair-colleague-agent-prompt.md"
  "run-agent.sh"
  "agent-registry.json"
)

VALID_EFFORTS="low|medium|high|xhigh|max|maximum"

# The supported v1 platforms. The process helper depends on POSIX sessions,
# process groups, and signal semantics that native Windows does not provide.
SUPPORTED_PLATFORMS="macOS, Linux, and WSL"

# ── Configuration (environment defaults; CLI flags override) ───────────────
AGENT_1_NAME="${AGENT_1_NAME:-Agent 1}"
AGENT_1_HARNESS="${AGENT_1_HARNESS:-}"
AGENT_1_MODEL="${AGENT_1_MODEL:-}"
AGENT_1_EFFORT="${AGENT_1_EFFORT:-}"

AGENT_2_NAME="${AGENT_2_NAME:-Agent 2}"
AGENT_2_HARNESS="${AGENT_2_HARNESS:-}"
AGENT_2_MODEL="${AGENT_2_MODEL:-}"
AGENT_2_EFFORT="${AGENT_2_EFFORT:-}"

MIN_ROUNDS="${MIN_ROUNDS:-3}"
MAX_ROUNDS="${MAX_ROUNDS:-8}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"
MAX_AGENT_ATTEMPTS_ENV="${MAX_AGENT_ATTEMPTS:-}"
MAX_AGENT_ATTEMPTS="${MAX_AGENT_ATTEMPTS:-3}"
PAIR_COLLEAGUE_RUN_ROOT="${PAIR_COLLEAGUE_RUN_ROOT:-.pair-colleague/runs}"

# Seconds a launched agent may overrun its recorded deadline before the
# control plane is willing to terminate it as hung rather than wait.
TERMINATION_GRACE_SECONDS="${PAIR_COLLEAGUE_TERMINATION_GRACE_SECONDS:-60}"

# Opt-in for harnesses whose registry entry declares no read-only profile.
ALLOW_UNVERIFIED_SAFE="${PAIR_COLLEAGUE_ALLOW_UNVERIFIED_SAFE:-0}"

# Dependency injection points (tests and non-default installs).
RUN_AGENT_PATH="${RUN_AGENT_PATH:-}"
AGENT_REGISTRY_FILE="${AGENT_REGISTRY_FILE:-}"
PAIR_COLLEAGUE_PROCESS_HELPER="${PAIR_COLLEAGUE_PROCESS_HELPER:-}"
PAIR_COLLEAGUE_PROMPT_FILE="${PAIR_COLLEAGUE_PROMPT_FILE:-}"

RUN_DIR=""
DECISION_FILE=""
FINAL_FILE=""
BIND_WORKSPACE=""
BREAK_LOCK=0
REAP_FORCE=0

WORKSPACE_ROOT=""
EMIT_LIVE_AGENTS=""

# ── Diagnostics ────────────────────────────────────────────────────────────
note() { printf 'pair-colleague: %s\n' "$1" >&2; }

die() {
  printf 'pair-colleague: error: %s\n' "$1" >&2
  exit "${2:-${EXIT_ERROR}}"
}

runner_hint() {
  cat >&2 <<'HINT'
  Inspect the available agents and models with:
    assets/run-agent.sh --list-agents --detected-only
    assets/run-agent.sh --list-models <agent>
HINT
}

usage() {
  cat <<'EOF'
Usage:
  pair-colleague.sh start <task-file|-> [options]
  pair-colleague.sh run-round --run-dir <dir> [--bind-workspace <dir>] [--break-lock]
  pair-colleague.sh record-decision --run-dir <dir> --decision-file <file>
  pair-colleague.sh finalize --run-dir <dir> --final-file <file>
  pair-colleague.sh status --run-dir <dir>
  pair-colleague.sh reap --run-dir <dir> [--force] [--break-lock]

Commands:
  start             initialize a run and create the isolated round-1 snapshot
  run-round         launch any pending solution agents for the current round
  record-decision   persist the coordinator's assessment and continue or accept
  finalize          validate and persist the coordinator's final decision dossier
  status            print the current phase and paths without changing state
  reap              terminate agents still running from an interrupted command

start options (CLI values override the matching environment variables):
  --agent-1-harness <registered-agent-or-alias>
  --agent-1-model <model>
  --agent-1-effort <low|medium|high|xhigh|max|maximum>
  --agent-1-name <display-name>
  --agent-2-harness <registered-agent-or-alias>
  --agent-2-model <model>
  --agent-2-effort <low|medium|high|xhigh|max|maximum>
  --agent-2-name <display-name>
  --min-rounds <integer>          default 3   (2 <= min <= max <= 8)
  --max-rounds <integer>          default 8
  --timeout-seconds <integer>     default 3600 (60 min, per agent per attempt)
  --run-root <directory>          default .pair-colleague/runs
  --help

Recovery options:
  --bind-workspace <dir>   bind a run created before workspace pinning to the
                           repository it must keep reviewing (one time, run-round)
  --break-lock             take a lock whose owner cannot be verified on this
                           host; refuses while any launched agent is still alive
  --force                  reap: terminate live agents instead of refusing

Exit codes:
  0 success   1 round incomplete, retry run-round   2 error
  3 blocked   4 busy (another command or a live agent owns this run)

Both solution agents are launched only through run-agent.sh using the shared
agent registry, in the harness's registered read-only profile. There is no
per-harness command builder and no arbitrary command override.
EOF
}

# ── JSON string escaping for hand-built payloads ───────────────────────────
json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "${value}"
}

# ── Platform boundary ──────────────────────────────────────────────────────
require_supported_platform() {
  local kernel="${PAIR_COLLEAGUE_UNAME_OVERRIDE:-}"
  if [[ -z "${kernel}" ]]; then
    kernel="$(uname -s 2>/dev/null || printf 'unknown')"
  fi
  case "${kernel}" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT|windows*)
      printf 'pair-colleague: error: native Windows (Git Bash, MSYS, Cygwin) is not supported.\n' >&2
      printf 'pair-colleague depends on POSIX sessions, process groups, and signal delivery to\n' >&2
      printf 'terminate agent process trees reliably. Supported platforms: %s.\n' "${SUPPORTED_PLATFORMS}" >&2
      printf 'On Windows, run this from WSL: install a distribution, run bash install.sh inside\n' >&2
      printf 'it, and start the run from the WSL shell.\n' >&2
      exit "${EXIT_ERROR}"
      ;;
  esac
}

# ── Asset discovery ────────────────────────────────────────────────────────
asset_injection_var() {
  case "$1" in
    "run-agent.sh") printf '%s' "${RUN_AGENT_PATH}" ;;
    "agent-registry.json") printf '%s' "${AGENT_REGISTRY_FILE}" ;;
    "pair-colleague-process.py") printf '%s' "${PAIR_COLLEAGUE_PROCESS_HELPER}" ;;
    "pair-colleague-agent-prompt.md") printf '%s' "${PAIR_COLLEAGUE_PROMPT_FILE}" ;;
    *) printf '' ;;
  esac
}

candidate_missing_assets() {
  local dir="$1" asset injected missing=""
  for asset in "${REQUIRED_ASSETS[@]}"; do
    injected="$(asset_injection_var "${asset}")"
    if [[ -n "${injected}" ]]; then
      [[ -f "${injected}" ]] || missing+="${asset} (injected: ${injected}) "
      continue
    fi
    [[ -f "${dir}/${asset}" ]] || missing+="${asset} "
  done
  printf '%s' "${missing}"
}

resolve_assets() {
  local candidates=() report="" dir missing

  if [[ -n "${PAIR_COLLEAGUE_ASSETS_DIR:-}" ]]; then candidates+=("${PAIR_COLLEAGUE_ASSETS_DIR}"); fi
  if [[ -n "${ASSETS_DEST:-}" ]]; then candidates+=("${ASSETS_DEST}"); fi
  candidates+=("${SCRIPT_DIR}")
  candidates+=("${HOME:-}/.ai-skill-collections/assets")
  candidates+=("${PWD}/assets")
  if command -v git >/dev/null 2>&1; then
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "${top}" ]]; then candidates+=("${top}/assets"); fi
  fi

  for dir in "${candidates[@]}"; do
    [[ -d "${dir}" ]] || continue
    missing="$(candidate_missing_assets "${dir}")"
    if [[ -z "${missing}" ]]; then
      ASSET_DIR="$(cd -- "${dir}" && pwd -P)"
      [[ -n "${RUN_AGENT_PATH}" ]] || RUN_AGENT_PATH="${ASSET_DIR}/run-agent.sh"
      [[ -n "${AGENT_REGISTRY_FILE}" ]] || AGENT_REGISTRY_FILE="${ASSET_DIR}/agent-registry.json"
      [[ -n "${PAIR_COLLEAGUE_PROCESS_HELPER}" ]] || PAIR_COLLEAGUE_PROCESS_HELPER="${ASSET_DIR}/pair-colleague-process.py"
      [[ -n "${PAIR_COLLEAGUE_PROMPT_FILE}" ]] || PAIR_COLLEAGUE_PROMPT_FILE="${ASSET_DIR}/pair-colleague-agent-prompt.md"
      return 0
    fi
    report+="  ${dir}: missing ${missing}"$'\n'
  done

  printf 'pair-colleague: error: no complete asset directory found.\n' >&2
  printf 'Required files: %s\n' "${REQUIRED_ASSETS[*]}" >&2
  printf 'Checked:\n%s' "${report}" >&2
  printf 'Re-run the installer (bash install.sh) or set PAIR_COLLEAGUE_ASSETS_DIR.\n' >&2
  exit "${EXIT_ERROR}"
}

helper() {
  python3 "${PAIR_COLLEAGUE_PROCESS_HELPER}" "$@"
}

file_digest() {
  helper sha256 --file "$1" 2>/dev/null || printf ''
}

# ── Validation ─────────────────────────────────────────────────────────────
require_positive_int() {
  local value="$1" label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be a positive integer; got '${value}'"
  [[ "${value}" -gt 0 ]] || die "${label} must be a positive integer; got '${value}'"
}

normalize_effort() {
  local value="$1" label="$2"
  case "${value}" in
    low|medium|high|xhigh|max) printf '%s' "${value}" ;;
    maximum) printf 'max' ;;
    *) die "${label} must be one of ${VALID_EFFORTS}; got '${value}'" ;;
  esac
}

validate_display_name() {
  local value="$1" label="$2"
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ ]] ||
    die "${label} must be 1-64 characters of letters, digits, spaces, dot, underscore, or hyphen"
}

require_agent_config() {
  local slot="$1" harness="$2" model="$3" effort="$4"
  local missing=""
  [[ -n "${harness}" ]] || missing+="harness "
  [[ -n "${model}" ]] || missing+="model "
  [[ -n "${effort}" ]] || missing+="effort "
  if [[ -n "${missing}" ]]; then
    printf 'pair-colleague: error: agent %s is missing required configuration: %s\n' \
      "${slot}" "${missing% }" >&2
    printf 'Set --agent-%s-harness / --agent-%s-model / --agent-%s-effort (or AGENT_%s_HARNESS / AGENT_%s_MODEL / AGENT_%s_EFFORT).\n' \
      "${slot}" "${slot}" "${slot}" "${slot}" "${slot}" "${slot}" >&2
    printf 'These values are never guessed and registry defaults are never substituted.\n' >&2
    runner_hint
    exit "${EXIT_ERROR}"
  fi
}

DETECTED_AGENTS_CACHE=""
load_detected_agents() {
  if [[ -n "${DETECTED_AGENTS_CACHE}" ]]; then return 0; fi
  DETECTED_AGENTS_CACHE="$("${RUN_AGENT_PATH}" --list-agents --detected-only 2>/dev/null || true)"
  [[ -n "${DETECTED_AGENTS_CACHE}" ]] || {
    printf 'pair-colleague: error: the unified runner reports no detected agents.\n' >&2
    runner_hint
    exit "${EXIT_ERROR}"
  }
}

verify_harness_available() {
  local slot="$1" harness="$2" canonical
  canonical="$(helper normalize-agent --registry "${AGENT_REGISTRY_FILE}" --agent "${harness}")" ||
    die "could not read the agent registry: ${AGENT_REGISTRY_FILE}"
  load_detected_agents
  if ! printf '%s\n' "${DETECTED_AGENTS_CACHE}" | cut -f1 | grep -Fxq "${canonical}"; then
    printf 'pair-colleague: error: agent %s harness "%s" is not installed, enabled, configured, or detectable.\n' \
      "${slot}" "${harness}" >&2
    printf 'Detected agents:\n%s\n' "${DETECTED_AGENTS_CACHE}" >&2
    runner_hint
    exit "${EXIT_ERROR}"
  fi
  printf '%s' "${canonical}"
}

verify_model_registered() {
  local slot="$1" harness="$2" model="$3" models_output
  if ! models_output="$("${RUN_AGENT_PATH}" --list-models "${harness}" 2>&1)"; then
    printf 'pair-colleague: error: agent %s harness "%s" is unavailable: %s\n' \
      "${slot}" "${harness}" "${models_output}" >&2
    runner_hint
    exit "${EXIT_ERROR}"
  fi
  if ! printf '%s\n' "${models_output}" | grep -Fxq "${model}"; then
    printf 'pair-colleague: error: model "%s" is not registered for agent %s harness "%s".\n' \
      "${model}" "${slot}" "${harness}" >&2
    printf 'Registered models:\n%s\n' "${models_output}" >&2
    runner_hint
    exit "${EXIT_ERROR}"
  fi
}

registry_read_only_mode() {  # registry_read_only_mode <canonical-agent>
  python3 - "${AGENT_REGISTRY_FILE}" "$1" <<'PY'
import json, sys
registry = json.load(open(sys.argv[1]))
agent = registry.get("agents", {}).get(sys.argv[2], {})
print(agent.get("permission_modes", {}).get("read_only", "") or "")
PY
}

# Sets READ_ONLY_PROFILE rather than printing it: the refusal below must exit
# the script, and an exit inside a command substitution only ends the subshell.
READ_ONLY_PROFILE=""
verify_read_only_profile() {  # verify_read_only_profile <slot> <canonical-agent>
  local slot="$1" canonical="$2" mode
  READ_ONLY_PROFILE=""
  mode="$(registry_read_only_mode "${canonical}")" || mode=""
  if [[ -n "${mode}" ]]; then
    READ_ONLY_PROFILE="${mode}"
    return 0
  fi
  if [[ "${ALLOW_UNVERIFIED_SAFE}" == "1" ]]; then
    note "agent ${slot} harness \"${canonical}\" declares no read-only profile; PAIR_COLLEAGUE_ALLOW_UNVERIFIED_SAFE=1 is set, so it runs with the harness default and MAY MODIFY this repository."
    READ_ONLY_PROFILE="unverified"
    return 0
  fi
  printf 'pair-colleague: error: agent %s harness "%s" has no registered read-only profile.\n' \
    "${slot}" "${canonical}" >&2
  printf 'Solution colleagues must not modify the repository they are reviewing, so a harness\n' >&2
  printf 'without a verified write-denying mode is refused before any run is created.\n' >&2
  printf 'Choose a harness whose agent-registry.json entry declares permission_modes.read_only,\n' >&2
  printf 'or accept the risk explicitly with PAIR_COLLEAGUE_ALLOW_UNVERIFIED_SAFE=1.\n' >&2
  exit "${EXIT_ERROR}"
}

# ── State access ───────────────────────────────────────────────────────────
state_get() {
  helper state-get --run-dir "${RUN_DIR}" --key "$1" --default "${2:-}"
}

state_apply() {
  printf '%s' "$1" | helper state-apply --run-dir "${RUN_DIR}" --patch -
}

require_run_dir() {
  [[ -n "${RUN_DIR}" ]] || die "--run-dir is required"
  [[ -d "${RUN_DIR}" ]] || die "run directory not found: ${RUN_DIR}"
  RUN_DIR="$(cd -- "${RUN_DIR}" && pwd -P)"
  [[ -f "${RUN_DIR}/state.json" ]] || die "not a pair-colleague run directory: ${RUN_DIR}"
}

round_dir_for() {
  printf '%s/rounds/round-%02d' "${RUN_DIR}" "$1"
}

attempt_prefix() {  # attempt_prefix <round-dir> <slot> <attempt>
  printf '%s/agent-%s-attempt-%02d' "$1" "$2" "$3"
}

# ── Exclusive per-run lock ─────────────────────────────────────────────────
# Two coordinators (or one coordinator invoked twice) must never allocate the
# same attempt number, launch duplicate paid agents, or interleave state
# patches. mkdir is the only atomic primitive available on every supported
# shell and filesystem, so the lock is a directory whose owner is recorded
# inside it.

LOCK_DIR=""
LOCK_TOKEN=""
LOCK_HELD=0

release_lock() {
  if [[ "${LOCK_HELD}" != "1" || -z "${LOCK_DIR}" ]]; then return 0; fi
  local owner=""
  if [[ -f "${LOCK_DIR}/token" ]]; then
    owner="$(cat "${LOCK_DIR}/token" 2>/dev/null || true)"
  fi
  if [[ "${owner}" == "${LOCK_TOKEN}" ]]; then
    rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
  fi
  LOCK_HELD=0
}

on_signal() {
  release_lock
  trap - INT TERM HUP
  exit 130
}

trap release_lock EXIT
trap on_signal INT TERM HUP

lock_owner_field() {  # lock_owner_field <name>
  if [[ -f "${LOCK_DIR}/$1" ]]; then
    cat "${LOCK_DIR}/$1" 2>/dev/null || printf ''
  else
    printf ''
  fi
}

report_busy_lock() {
  local host pid cmd started
  host="$(lock_owner_field host)"
  pid="$(lock_owner_field pid)"
  cmd="$(lock_owner_field command)"
  started="$(lock_owner_field started_at)"
  printf 'pair-colleague: error: this run is busy; nothing was changed.\n' >&2
  printf '  lock owner: %s on %s (pid %s) since %s\n' "${cmd:-unknown}" "${host:-unknown}" "${pid:-unknown}" "${started:-unknown}" >&2
  printf '  Wait for it to finish, or inspect it with: pair-colleague.sh status --run-dir %s\n' "${RUN_DIR}" >&2
  if [[ -n "${host}" && "${host}" != "$(hostname)" ]]; then
    printf '  The owner recorded a different host, so its liveness cannot be checked here.\n' >&2
    printf '  Once you are sure nothing is running, retry with --break-lock.\n' >&2
  fi
  exit "${EXIT_BUSY}"
}

acquire_lock() {
  LOCK_DIR="${RUN_DIR}/.lock"
  local attempt owner_host owner_pid
  for attempt in 1 2 3; do
    if mkdir -- "${LOCK_DIR}" 2>/dev/null; then
      LOCK_TOKEN="$$-${RANDOM}-$(date -u +%s)"
      LOCK_HELD=1
      printf '%s\n' "${LOCK_TOKEN}" > "${LOCK_DIR}/token"
      printf '%s\n' "$(hostname)" > "${LOCK_DIR}/host"
      printf '%s\n' "$$" > "${LOCK_DIR}/pid"
      printf '%s\n' "${COMMAND}" > "${LOCK_DIR}/command"
      printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${LOCK_DIR}/started_at"
      return 0
    fi

    owner_host="$(lock_owner_field host)"
    owner_pid="$(lock_owner_field pid)"

    if [[ "${BREAK_LOCK}" == "1" ]]; then
      note "breaking the lock held by ${owner_host:-unknown} pid ${owner_pid:-unknown} as requested"
      rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
      continue
    fi

    # A different host's pid means nothing here; refuse rather than guess.
    if [[ -n "${owner_host}" && "${owner_host}" != "$(hostname)" ]]; then
      report_busy_lock
    fi

    if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" 2>/dev/null; then
      report_busy_lock
    fi

    # The owner is gone. Breaking the lock does not authorize a relaunch: the
    # caller still reconciles per-attempt liveness before spending money.
    note "clearing a lock left behind by dead pid ${owner_pid:-unknown}"
    rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
  done
  report_busy_lock
}

# ── Workspace identity ─────────────────────────────────────────────────────
# Every round must review the same repository, whatever directory the
# coordinator happens to resume from and whatever REPO_ROOT it inherited.

resolve_workspace_root() {
  local recorded
  recorded="$(state_get workspace_root)"

  if [[ -n "${recorded}" ]]; then
    if [[ -n "${BIND_WORKSPACE}" ]]; then
      local requested
      requested="$(cd -- "${BIND_WORKSPACE}" 2>/dev/null && pwd -P || printf '%s' "${BIND_WORKSPACE}")"
      [[ "${requested}" == "${recorded}" ]] ||
        die "this run is already bound to ${recorded}; --bind-workspace ${requested} would change the repository under review"
    fi
    [[ -d "${recorded}" ]] ||
      die "the workspace this run reviews no longer exists: ${recorded}"
    WORKSPACE_ROOT="${recorded}"
    return 0
  fi

  # Runs created before workspace pinning carry no recorded root. Binding is
  # explicit and one-time: silently adopting the current directory is how a
  # resumed run starts reviewing the wrong repository.
  if [[ -z "${BIND_WORKSPACE}" ]]; then
    printf 'pair-colleague: error: this run predates workspace pinning and records no workspace root.\n' >&2
    printf 'Bind it once to the repository it must keep reviewing:\n' >&2
    printf '  pair-colleague.sh %s --run-dir %s --bind-workspace <repository-root>\n' "${COMMAND}" "${RUN_DIR}" >&2
    exit "${EXIT_ERROR}"
  fi
  [[ -d "${BIND_WORKSPACE}" ]] || die "--bind-workspace directory not found: ${BIND_WORKSPACE}"
  WORKSPACE_ROOT="$(cd -- "${BIND_WORKSPACE}" && pwd -P)"
  state_apply "{\"workspace_root\": $(json_string "${WORKSPACE_ROOT}"), \"schema_version\": 2}"
  note "bound this run to workspace ${WORKSPACE_ROOT}"
}

report_asset_drift() {
  local recorded actual
  recorded="$(state_get assets.prompt_template_sha256)"
  [[ -n "${recorded}" ]] || return 0
  actual="$(file_digest "${PAIR_COLLEAGUE_PROMPT_FILE}")"
  if [[ -n "${actual}" && "${actual}" != "${recorded}" ]]; then
    note "the colleague prompt template changed since this run started (recorded ${recorded:0:12}, found ${actual:0:12}); later rounds are not byte-comparable with earlier ones"
  fi
}

phase_to_status() {
  case "$1" in
    blocked) printf 'error' ;;
    *) printf '%s' "$1" ;;
  esac
}

emit_lines() {  # emit_lines <status> <round>
  local status="$1" round="$2" dir reason final
  dir="$(round_dir_for "${round}")"
  reason="$(state_get completion_reason)"
  final="${RUN_DIR}/final-solution.md"
  printf 'STATUS=%s\n' "${status}"
  printf 'RUN_DIR=%s\n' "${RUN_DIR}"
  printf 'ROUND=%s\n' "${round}"
  printf 'MIN_ROUNDS=%s\n' "$(state_get min_rounds)"
  printf 'MAX_ROUNDS=%s\n' "$(state_get max_rounds)"
  printf 'COMPLETED_ROUNDS=%s\n' "$(state_get completed_rounds 0)"
  printf 'SNAPSHOT=%s\n' "${dir}/snapshot.md"
  printf 'AGENT_1_OUTPUT=%s\n' "${dir}/agent-1-output.md"
  printf 'AGENT_2_OUTPUT=%s\n' "${dir}/agent-2-output.md"
  printf 'DECISION_TEMPLATE=%s\n' "${dir}/coordinator-decision-template.md"
  if [[ -f "${final}" ]]; then
    printf 'FINAL=%s\n' "${final}"
  else
    printf 'FINAL=\n'
  fi
  printf 'WORKSPACE_ROOT=%s\n' "$(state_get workspace_root)"
  printf 'LIVE_AGENTS=%s\n' "${EMIT_LIVE_AGENTS}"
  printf 'COMPLETION_REASON=%s\n' "${reason}"
}

# ── Argument parsing ───────────────────────────────────────────────────────
COMMAND=""
TASK_SOURCE=""
RUN_ROOT_FLAG=""

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit "${EXIT_ERROR}"; }

  case "$1" in
    -h|--help) usage; exit "${EXIT_OK}" ;;
    start|run-round|record-decision|finalize|status|reap) COMMAND="$1"; shift ;;
    *) printf 'pair-colleague: error: unknown command: %s\n' "$1" >&2; usage >&2; exit "${EXIT_ERROR}" ;;
  esac

  if [[ "${COMMAND}" == "start" ]]; then
    [[ $# -gt 0 ]] || die "start requires a task file path or '-' for stdin"
    case "$1" in
      -h|--help) usage; exit "${EXIT_OK}" ;;
      --*) die "start requires a task file path or '-' for stdin" ;;
      *) TASK_SOURCE="$1"; shift ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent-1-harness) [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_1_HARNESS="$2"; shift 2 ;;
      --agent-1-model)   [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_1_MODEL="$2"; shift 2 ;;
      --agent-1-effort)  [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_1_EFFORT="$2"; shift 2 ;;
      --agent-1-name)    [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_1_NAME="$2"; shift 2 ;;
      --agent-2-harness) [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_2_HARNESS="$2"; shift 2 ;;
      --agent-2-model)   [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_2_MODEL="$2"; shift 2 ;;
      --agent-2-effort)  [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_2_EFFORT="$2"; shift 2 ;;
      --agent-2-name)    [[ $# -ge 2 ]] || die "$1 requires a value"; AGENT_2_NAME="$2"; shift 2 ;;
      --min-rounds)      [[ $# -ge 2 ]] || die "$1 requires a value"; MIN_ROUNDS="$2"; shift 2 ;;
      --max-rounds)      [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_ROUNDS="$2"; shift 2 ;;
      --timeout-seconds) [[ $# -ge 2 ]] || die "$1 requires a value"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      --run-root)        [[ $# -ge 2 ]] || die "$1 requires a value"; RUN_ROOT_FLAG="$2"; shift 2 ;;
      --run-dir)         [[ $# -ge 2 ]] || die "$1 requires a value"; RUN_DIR="$2"; shift 2 ;;
      --decision-file)   [[ $# -ge 2 ]] || die "$1 requires a value"; DECISION_FILE="$2"; shift 2 ;;
      --final-file)      [[ $# -ge 2 ]] || die "$1 requires a value"; FINAL_FILE="$2"; shift 2 ;;
      --bind-workspace)  [[ $# -ge 2 ]] || die "$1 requires a value"; BIND_WORKSPACE="$2"; shift 2 ;;
      --break-lock)      BREAK_LOCK=1; shift ;;
      --force)           REAP_FORCE=1; shift ;;
      -h|--help)         usage; exit "${EXIT_OK}" ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

# ── start ──────────────────────────────────────────────────────────────────
cmd_start() {
  local task_text run_root timestamp canonical_1 canonical_2 profile_1 profile_2

  if [[ "${TASK_SOURCE}" == "-" ]]; then
    task_text="$(cat)"
  else
    [[ -f "${TASK_SOURCE}" ]] || die "task file not found: ${TASK_SOURCE}"
    task_text="$(cat -- "${TASK_SOURCE}")"
  fi
  [[ -n "${task_text//[[:space:]]/}" ]] || die "the task is empty; provide the problem to work on"

  require_agent_config 1 "${AGENT_1_HARNESS}" "${AGENT_1_MODEL}" "${AGENT_1_EFFORT}"
  require_agent_config 2 "${AGENT_2_HARNESS}" "${AGENT_2_MODEL}" "${AGENT_2_EFFORT}"

  AGENT_1_EFFORT="$(normalize_effort "${AGENT_1_EFFORT}" "agent 1 effort")"
  AGENT_2_EFFORT="$(normalize_effort "${AGENT_2_EFFORT}" "agent 2 effort")"
  validate_display_name "${AGENT_1_NAME}" "agent 1 name"
  validate_display_name "${AGENT_2_NAME}" "agent 2 name"

  [[ "${MIN_ROUNDS}" =~ ^[0-9]+$ ]] || die "--min-rounds must be an integer; got '${MIN_ROUNDS}'"
  [[ "${MAX_ROUNDS}" =~ ^[0-9]+$ ]] || die "--max-rounds must be an integer; got '${MAX_ROUNDS}'"
  [[ "${MIN_ROUNDS}" -ge 2 ]] || die "--min-rounds must be at least 2 (got ${MIN_ROUNDS}); the discussion period is mandatory"
  [[ "${MAX_ROUNDS}" -le 8 ]] || die "--max-rounds must be at most 8 (got ${MAX_ROUNDS})"
  [[ "${MIN_ROUNDS}" -le "${MAX_ROUNDS}" ]] || die "--min-rounds (${MIN_ROUNDS}) must not exceed --max-rounds (${MAX_ROUNDS})"
  require_positive_int "${TIMEOUT_SECONDS}" "--timeout-seconds"
  require_positive_int "${MAX_AGENT_ATTEMPTS}" "MAX_AGENT_ATTEMPTS"

  canonical_1="$(verify_harness_available 1 "${AGENT_1_HARNESS}")"
  canonical_2="$(verify_harness_available 2 "${AGENT_2_HARNESS}")"
  verify_model_registered 1 "${AGENT_1_HARNESS}" "${AGENT_1_MODEL}"
  verify_model_registered 2 "${AGENT_2_HARNESS}" "${AGENT_2_MODEL}"

  # Refuse a harness that cannot be held to the no-modification contract
  # before any run directory or paid work exists.
  verify_read_only_profile 1 "${canonical_1}"
  profile_1="${READ_ONLY_PROFILE}"
  verify_read_only_profile 2 "${canonical_2}"
  profile_2="${READ_ONLY_PROFILE}"

  if [[ "${canonical_1}" == "${canonical_2}" && "${AGENT_1_MODEL}" == "${AGENT_2_MODEL}" ]]; then
    note "both colleagues use ${canonical_1}/${AGENT_1_MODEL}; harness or model diversity usually widens the initial solution set."
  fi

  WORKSPACE_ROOT="$(pwd -P)"

  run_root="${RUN_ROOT_FLAG:-${PAIR_COLLEAGUE_RUN_ROOT}}"
  mkdir -p "${run_root}"
  run_root="$(cd -- "${run_root}" && pwd -P)"
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  RUN_DIR="$(helper create-run --run-root "${run_root}" --timestamp "${timestamp}")"

  printf '%s\n' "${task_text}" | helper write-file --path "${RUN_DIR}/task.md"

  local created_at prompt_digest runner_digest helper_digest
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  prompt_digest="$(file_digest "${PAIR_COLLEAGUE_PROMPT_FILE}")"
  runner_digest="$(file_digest "${RUN_AGENT_PATH}")"
  helper_digest="$(file_digest "${PAIR_COLLEAGUE_PROCESS_HELPER}")"

  helper write-file --path "${RUN_DIR}/config.json" <<CONFIG
{
  "schema_version": 2,
  "created_at": $(json_string "${created_at}"),
  "coordinator": "current invoking agent",
  "workspace_root": $(json_string "${WORKSPACE_ROOT}"),
  "agents": {
    "1": {
      "name": $(json_string "${AGENT_1_NAME}"),
      "harness": $(json_string "${canonical_1}"),
      "harness_requested": $(json_string "${AGENT_1_HARNESS}"),
      "model": $(json_string "${AGENT_1_MODEL}"),
      "effort": $(json_string "${AGENT_1_EFFORT}"),
      "safety_profile": $(json_string "${profile_1}")
    },
    "2": {
      "name": $(json_string "${AGENT_2_NAME}"),
      "harness": $(json_string "${canonical_2}"),
      "harness_requested": $(json_string "${AGENT_2_HARNESS}"),
      "model": $(json_string "${AGENT_2_MODEL}"),
      "effort": $(json_string "${AGENT_2_EFFORT}"),
      "safety_profile": $(json_string "${profile_2}")
    }
  },
  "min_rounds": ${MIN_ROUNDS},
  "max_rounds": ${MAX_ROUNDS},
  "timeout_seconds": ${TIMEOUT_SECONDS},
  "max_agent_attempts": ${MAX_AGENT_ATTEMPTS},
  "permission_mode": "safe",
  "runner": $(json_string "${RUN_AGENT_PATH}"),
  "prompt_template": $(json_string "${PAIR_COLLEAGUE_PROMPT_FILE}"),
  "assets": {
    "runner_sha256": $(json_string "${runner_digest}"),
    "process_helper_sha256": $(json_string "${helper_digest}"),
    "prompt_template_sha256": $(json_string "${prompt_digest}")
  }
}
CONFIG

  helper state-init --run-dir "${RUN_DIR}" --patch - <<STATE
{
  "schema_version": 2,
  "run_dir": $(json_string "${RUN_DIR}"),
  "workspace_root": $(json_string "${WORKSPACE_ROOT}"),
  "phase": "awaiting-agents",
  "round": 1,
  "completed_rounds": 0,
  "min_rounds": ${MIN_ROUNDS},
  "max_rounds": ${MAX_ROUNDS},
  "timeout_seconds": ${TIMEOUT_SECONDS},
  "max_agent_attempts": ${MAX_AGENT_ATTEMPTS},
  "completion_reason": "",
  "created_at": $(json_string "${created_at}"),
  "updated_at": $(json_string "${created_at}"),
  "assets": {
    "prompt_template_sha256": $(json_string "${prompt_digest}")
  },
  "rounds": {}
}
STATE

  local digest
  digest="$(helper snapshot --run-dir "${RUN_DIR}" --round 1)"
  state_apply "{\"rounds\": {\"1\": {\"snapshot_sha256\": $(json_string "${digest}"), \"agents\": {\"1\": {\"status\": \"pending\", \"attempts\": 0}, \"2\": {\"status\": \"pending\", \"attempts\": 0}}}}}"

  emit_lines "initialized" 1
}

# ── run-round ──────────────────────────────────────────────────────────────
agent_field() {  # agent_field <slot> <field>
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["agents"][sys.argv[2]].get(sys.argv[3],""))' \
    "${RUN_DIR}/config.json" "$1" "$2"
}

json_field() {  # json_field <file> <key>
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

render_agent_prompt() {  # render_agent_prompt <slot> <round> <output>
  local slot="$1" round="$2" output="$3" name other effort min max
  if [[ -f "${output}" ]]; then return 0; fi
  name="$(agent_field "${slot}" name)"
  if [[ "${slot}" == "1" ]]; then other="$(agent_field 2 name)"; else other="$(agent_field 1 name)"; fi
  effort="$(agent_field "${slot}" effort)"
  min="$(state_get min_rounds)"
  max="$(state_get max_rounds)"
  helper render \
    --template "${PAIR_COLLEAGUE_PROMPT_FILE}" \
    --output "${output}" \
    --var "AGENT_NAME=${name}" \
    --var "OTHER_AGENT_NAME=${other}" \
    --var "ROUND_NUMBER=${round}" \
    --var "MIN_ROUNDS=${min}" \
    --var "MAX_ROUNDS=${max}" \
    --var "EFFORT_LEVEL=${effort}"
}

write_decision_template() {  # write_decision_template <path>
  helper write-file --path "$1" <<'TEMPLATE'
# Round assessment

<what materially changed or was learned>

# Candidate-solution ledger

<unique candidate IDs, summaries, and status: active, preferred, merged, or rejected>

# Current synthesis or preferred direction

<best current solution direction, or "Not selected">

# Agreements

<established common ground>

# Disagreements

<remaining substantive disagreement>

# Rejected candidates

<candidate IDs and evidence-based rejection reasons>

# Unresolved questions and risks

<items still affecting the decision>

# Focus for next round

<targeted questions for both agents; use "None" when accepting>

# Decision rationale

<why another round is or is not likely to improve the result>

COORDINATOR_ACTION: CONTINUE
TEMPLATE
}

promote_atomic() {  # promote_atomic <source> <destination>
  local source="$1" destination="$2" staged
  staged="$(dirname -- "${destination}")/.$(basename -- "${destination}").staged.$$"
  cp -- "${source}" "${staged}"
  mv -f -- "${staged}" "${destination}"
}

verify_snapshot_frozen() {  # verify_snapshot_frozen <round-dir> <round>
  local dir="$1" round="$2" recorded actual
  recorded="$(state_get "rounds.${round}.snapshot_sha256")"
  actual="$(helper sha256 --file "${dir}/snapshot.md")"
  [[ "${recorded}" == "${actual}" ]] ||
    die "the round ${round} snapshot changed after it was frozen (recorded ${recorded}, found ${actual})"
}

verify_recorded_artifact() {  # verify_recorded_artifact <path> <state-key> <label>
  local path="$1" key="$2" label="$3" recorded
  recorded="$(state_get "${key}")"
  [[ -n "${recorded}" ]] || return 0
  helper verify --file "${path}" --sha256 "${recorded}" >/dev/null ||
    die "${label} changed after this run recorded it; the discussion cannot continue from altered context (${path})"
}

# collect_attempt <round> <round-dir> <slot> <attempt>
# Turns a finished attempt into either a promoted canonical response or a
# recorded failure. It never launches anything, so it is safe to call while
# reconciling a run whose supervisor died.
collect_attempt() {
  local round="$1" dir="$2" slot="$3" attempt="$4"
  local prefix attempt_out exit_code timed_out validation_ok=0 digest
  prefix="$(attempt_prefix "${dir}" "${slot}" "${attempt}")"
  attempt_out="${prefix}-output.md"

  if [[ ! -f "${prefix}-run.json" ]]; then
    note "agent ${slot} attempt ${attempt} left no result manifest for round ${round}; treating it as failed"
    state_apply "{\"rounds\": {\"${round}\": {\"agents\": {\"${slot}\": {\"status\": \"failed\"}}}}}"
    return 0
  fi

  exit_code="$(json_field "${prefix}-run.json" exit_code)"
  timed_out="$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1])).get("timed_out",False)).lower())' "${prefix}-run.json")"

  if [[ "${exit_code}" == "0" && "${timed_out}" == "false" && -f "${attempt_out}" ]]; then
    if helper validate --kind agent-output --file "${attempt_out}" 2>"${prefix}-validation.log"; then
      validation_ok=1
    fi
  fi

  if [[ "${validation_ok}" == "1" ]]; then
    promote_atomic "${attempt_out}" "${dir}/agent-${slot}-output.md"
    if [[ -f "${prefix}-stderr.log" ]]; then
      promote_atomic "${prefix}-stderr.log" "${dir}/agent-${slot}-stderr.log"
    fi
    promote_atomic "${prefix}-run.json" "${dir}/agent-${slot}-run.json"
    digest="$(helper sha256 --file "${dir}/agent-${slot}-output.md")"
    state_apply "{\"rounds\": {\"${round}\": {\"agents\": {\"${slot}\": {\"status\": \"complete\", \"output_sha256\": $(json_string "${digest}")}}}}}"
    return 0
  fi

  note "agent ${slot} attempt ${attempt} did not produce a valid response for round ${round} (exit ${exit_code}, timed_out ${timed_out}); diagnostics in ${dir}"
  if [[ -s "${prefix}-validation.log" ]]; then
    sed 's/^/  /' "${prefix}-validation.log" >&2
  fi
  state_apply "{\"rounds\": {\"${round}\": {\"agents\": {\"${slot}\": {\"status\": \"failed\"}}}}}"
}

# reconcile_attempts <round> <round-dir>
# Sets RECONCILE_LIVE to the slots whose previously launched agents are still
# running. Anything that has finished is collected here so a crashed supervisor
# never causes the same work to be paid for twice.
RECONCILE_LIVE=""
reconcile_attempts() {
  local round="$1" dir="$2" slot slot_status attempt prefix probe state alive exceeded
  RECONCILE_LIVE=""
  for slot in 1 2; do
    slot_status="$(state_get "rounds.${round}.agents.${slot}.status" pending)"
    if [[ "${slot_status}" == "complete" && -f "${dir}/agent-${slot}-output.md" ]]; then
      continue
    fi
    attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
    [[ "${attempt}" -gt 0 ]] || continue
    [[ "${slot_status}" == "running" ]] || continue

    prefix="$(attempt_prefix "${dir}" "${slot}" "${attempt}")"
    probe="$(helper probe-attempt --result "${prefix}-run.json" --grace "${TERMINATION_GRACE_SECONDS}")"
    state="$(printf '%s\n' "${probe}" | grep '^STATE=' | cut -d= -f2-)"
    alive="$(printf '%s\n' "${probe}" | grep '^ALIVE=' | cut -d= -f2-)"
    exceeded="$(printf '%s\n' "${probe}" | grep '^DEADLINE_EXCEEDED=' | cut -d= -f2-)"

    if [[ "${alive}" == "true" ]]; then
      if [[ "${exceeded}" == "true" ]]; then
        note "agent ${slot} attempt ${attempt} outlived its deadline; terminating its process group"
        helper reap-attempt --result "${prefix}-run.json" --reason timeout >/dev/null
        collect_attempt "${round}" "${dir}" "${slot}" "${attempt}"
        continue
      fi
      RECONCILE_LIVE+="${slot} "
      continue
    fi

    if [[ "${state}" == "missing" ]]; then
      note "agent ${slot} attempt ${attempt} was recorded but never produced a manifest; treating it as failed"
      state_apply "{\"rounds\": {\"${round}\": {\"agents\": {\"${slot}\": {\"status\": \"failed\"}}}}}"
      continue
    fi

    note "recovering agent ${slot} attempt ${attempt} from an interrupted command; no new agent is launched"
    collect_attempt "${round}" "${dir}" "${slot}" "${attempt}"
  done
  RECONCILE_LIVE="${RECONCILE_LIVE% }"
}

report_live_agents() {  # report_live_agents <status> <round>
  EMIT_LIVE_AGENTS="${RECONCILE_LIVE}"
  emit_lines "$1" "$2"
  printf 'LAUNCH=busy\n'
  printf 'pair-colleague: error: agents launched by an earlier command are still running (slots: %s).\n' "${RECONCILE_LIVE}" >&2
  printf 'Nothing was changed and no second agent was launched. Wait for them to finish and re-run\n' >&2
  printf 'run-round to collect their output, or terminate them deliberately with:\n' >&2
  printf '  pair-colleague.sh reap --run-dir %s --force\n' "${RUN_DIR}" >&2
  exit "${EXIT_BUSY}"
}

cmd_run_round() {
  require_run_dir
  acquire_lock
  local phase round dir attempt attempt_label
  phase="$(state_get phase)"
  round="$(state_get round)"
  dir="$(round_dir_for "${round}")"

  case "${phase}" in
    awaiting-coordinator)
      emit_lines "awaiting-coordinator" "${round}"
      return "${EXIT_OK}"
      ;;
    awaiting-agents) ;;
    awaiting-final) die "round ${round} is already accepted; write the dossier and run finalize" ;;
    complete) die "this run is complete; start a new run to continue the discussion" ;;
    blocked)
      emit_lines "error" "${round}"
      die "this run is blocked by unrecoverable agent failures; inspect ${dir} and start a new run" "${EXIT_BLOCKED}"
      ;;
    *) die "unexpected run phase: ${phase}" ;;
  esac

  resolve_workspace_root
  report_asset_drift

  [[ -f "${dir}/snapshot.md" ]] || die "missing frozen snapshot for round ${round}"
  verify_snapshot_frozen "${dir}" "${round}"

  # Anything an earlier command launched is either still working (refuse) or
  # finished (collect). Either way it is never launched a second time.
  reconcile_attempts "${round}" "${dir}"
  if [[ -n "${RECONCILE_LIVE}" ]]; then
    report_live_agents "awaiting-agents" "${round}"
  fi

  local attempts_cap
  if [[ -n "${MAX_AGENT_ATTEMPTS_ENV}" ]]; then
    attempts_cap="${MAX_AGENT_ATTEMPTS_ENV}"
  else
    attempts_cap="$(state_get max_agent_attempts 3)"
  fi
  require_positive_int "${attempts_cap}" "MAX_AGENT_ATTEMPTS"

  # The persisted timeout is authoritative on resume: an agent must not get a
  # different budget just because the environment changed between rounds.
  local timeout_seconds
  timeout_seconds="$(state_get timeout_seconds 3600)"

  # Determine which colleagues still owe a valid response for this snapshot.
  local pending=() slot slot_status
  for slot in 1 2; do
    slot_status="$(state_get "rounds.${round}.agents.${slot}.status" pending)"
    if [[ "${slot_status}" == "complete" && -f "${dir}/agent-${slot}-output.md" ]]; then
      continue
    fi
    pending+=("${slot}")
  done

  if [[ "${#pending[@]}" -gt 0 ]]; then
    local spec="${dir}/.launch-spec.json" jobs="" snapshot_sha
    snapshot_sha="$(state_get "rounds.${round}.snapshot_sha256")"
    for slot in "${pending[@]}"; do
      attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
      attempt=$((attempt + 1))
      if [[ "${attempt}" -gt "${attempts_cap}" ]]; then
        state_apply "{\"phase\": \"blocked\", \"completion_reason\": \"blocked\"}"
        emit_lines "error" "${round}"
        die "agent ${slot} exhausted ${attempts_cap} attempts for round ${round}" "${EXIT_BLOCKED}"
      fi
      attempt_label="$(printf '%02d' "${attempt}")"
      render_agent_prompt "${slot}" "${round}" "${dir}/agent-${slot}-prompt.md"
      if [[ -n "${jobs}" ]]; then jobs+=","; fi
      jobs+="$(cat <<JOB
    {
      "id": "${slot}",
      "argv": [
        $(json_string "${RUN_AGENT_PATH}"),
        "--agent", $(json_string "$(agent_field "${slot}" harness)"),
        "--model", $(json_string "$(agent_field "${slot}" model)"),
        "--effort", $(json_string "$(agent_field "${slot}" effort)"),
        "--context-file", $(json_string "${dir}/snapshot.md"),
        "--prompt-file", $(json_string "${dir}/agent-${slot}-prompt.md"),
        "--permission-mode", "safe"
      ],
      "cwd": $(json_string "${WORKSPACE_ROOT}"),
      "env": {"REPO_ROOT": $(json_string "${WORKSPACE_ROOT}")},
      "meta": {
        "round": ${round},
        "slot": "${slot}",
        "attempt": ${attempt},
        "snapshot_sha256": $(json_string "${snapshot_sha}"),
        "workspace_root": $(json_string "${WORKSPACE_ROOT}")
      },
      "stdout": $(json_string "${dir}/agent-${slot}-attempt-${attempt_label}-output.md"),
      "stderr": $(json_string "${dir}/agent-${slot}-attempt-${attempt_label}-stderr.log"),
      "result": $(json_string "${dir}/agent-${slot}-attempt-${attempt_label}-run.json")
    }
JOB
)"
      # The attempt number is committed before the launch, so a supervisor that
      # dies mid-launch leaves a recoverable record instead of a free slot.
      state_apply "{\"rounds\": {\"${round}\": {\"agents\": {\"${slot}\": {\"attempts\": ${attempt}, \"status\": \"running\"}}}}}"
    done

    printf '{\n  "timeout_seconds": %s,\n  "jobs": [\n%s\n  ]\n}\n' "${timeout_seconds}" "${jobs}" \
      | helper write-file --path "${spec}"
    local launch_rc=0
    helper run-pair --spec "${spec}" > "${dir}/.launch-result.json" || launch_rc=$?
    rm -f "${spec}"
    if [[ "${launch_rc}" -ne 0 ]]; then
      note "the agent supervisor exited with status ${launch_rc}; collecting whatever each attempt left behind"
    fi

    # Re-verify the frozen context after the agents exit: a snapshot that
    # changed while they ran invalidates both responses.
    verify_snapshot_frozen "${dir}" "${round}"

    for slot in "${pending[@]}"; do
      attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
      collect_attempt "${round}" "${dir}" "${slot}" "${attempt}"
    done
  fi

  local complete_count=0
  for slot in 1 2; do
    slot_status="$(state_get "rounds.${round}.agents.${slot}.status" pending)"
    if [[ "${slot_status}" == "complete" ]]; then complete_count=$((complete_count + 1)); fi
  done

  if [[ "${complete_count}" -eq 2 ]]; then
    write_decision_template "${dir}/coordinator-decision-template.md"
    state_apply "{\"phase\": \"awaiting-coordinator\", \"completed_rounds\": ${round}}"
    emit_lines "awaiting-coordinator" "${round}"
    return "${EXIT_OK}"
  fi

  for slot in 1 2; do
    slot_status="$(state_get "rounds.${round}.agents.${slot}.status" pending)"
    if [[ "${slot_status}" == "complete" ]]; then continue; fi
    attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
    if [[ "${attempt}" -ge "${attempts_cap}" ]]; then
      state_apply "{\"phase\": \"blocked\", \"completion_reason\": \"blocked\"}"
      emit_lines "error" "${round}"
      printf 'pair-colleague: error: agent %s exhausted %s attempts for round %s; the run is blocked and must not produce a conclusive dossier.\n' \
        "${slot}" "${attempts_cap}" "${round}" >&2
      return "${EXIT_BLOCKED}"
    fi
  done

  emit_lines "awaiting-agents" "${round}"
  note "round ${round} is incomplete; re-run run-round to retry only the failed colleague against the unchanged snapshot"
  return "${EXIT_RETRY}"
}

# ── reap ───────────────────────────────────────────────────────────────────
cmd_reap() {
  require_run_dir
  acquire_lock
  local round dir slot attempt prefix probe alive reaped=0
  round="$(state_get round)"
  dir="$(round_dir_for "${round}")"

  for slot in 1 2; do
    [[ "$(state_get "rounds.${round}.agents.${slot}.status" pending)" == "running" ]] || continue
    attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
    [[ "${attempt}" -gt 0 ]] || continue
    prefix="$(attempt_prefix "${dir}" "${slot}" "${attempt}")"
    probe="$(helper probe-attempt --result "${prefix}-run.json" --grace "${TERMINATION_GRACE_SECONDS}")"
    alive="$(printf '%s\n' "${probe}" | grep '^ALIVE=' | cut -d= -f2-)"

    if [[ "${alive}" == "true" && "${REAP_FORCE}" != "1" ]]; then
      printf 'pair-colleague: error: agent %s attempt %s is still running.\n' "${slot}" "${attempt}" >&2
      printf 'Reaping it discards paid work in progress. Re-run with --force to terminate it.\n' >&2
      exit "${EXIT_BUSY}"
    fi
    if [[ "${alive}" == "true" ]]; then
      helper reap-attempt --result "${prefix}-run.json" --reason reaped >/dev/null
      note "terminated agent ${slot} attempt ${attempt}"
      reaped=$((reaped + 1))
    fi
    collect_attempt "${round}" "${dir}" "${slot}" "${attempt}"
  done

  note "reap finished; ${reaped} live agent(s) terminated"
  emit_lines "$(phase_to_status "$(state_get phase)")" "${round}"
}

# ── record-decision ────────────────────────────────────────────────────────
cmd_record_decision() {
  require_run_dir
  acquire_lock
  [[ -n "${DECISION_FILE}" ]] || die "--decision-file is required"
  [[ -f "${DECISION_FILE}" ]] || die "decision file not found: ${DECISION_FILE}"

  local phase round min max dir action recorded
  phase="$(state_get phase)"
  round="$(state_get round)"
  min="$(state_get min_rounds)"
  max="$(state_get max_rounds)"
  dir="$(round_dir_for "${round}")"

  case "${phase}" in
    awaiting-coordinator) ;;
    awaiting-agents) die "round ${round} is not complete; run run-round until both colleagues respond" ;;
    awaiting-final)
      # A retry of the transition that already committed: identical input is
      # the same decision, anything else is a conflict.
      recorded="${dir}/coordinator-decision.md"
      if [[ -f "${recorded}" ]] && helper identical --left "${recorded}" --right "${DECISION_FILE}"; then
        emit_lines "awaiting-final" "$(state_get round)"
        return "${EXIT_OK}"
      fi
      die "a decision is already recorded for round ${round}; write the dossier and run finalize"
      ;;
    complete) die "this run is complete; a recorded decision cannot be replaced" ;;
    blocked) die "this run is blocked; no decision can be recorded" "${EXIT_BLOCKED}" ;;
    *) die "unexpected run phase: ${phase}" ;;
  esac

  if ! helper validate --kind coordinator-decision --file "${DECISION_FILE}"; then
    die "the coordinator decision does not satisfy the required contract (see the problems above)"
  fi
  action="$(helper action --file "${DECISION_FILE}" --key COORDINATOR_ACTION)"

  if [[ "${action}" == "ACCEPT" && "${round}" -lt "${min}" ]]; then
    die "COORDINATOR_ACTION: ACCEPT is not allowed before the minimum of ${min} completed rounds (this is round ${round}); record CONTINUE with a useful focus for the next round"
  fi
  if [[ "${action}" == "CONTINUE" && "${round}" -ge "${max}" ]]; then
    die "round ${max} is the maximum; CONTINUE is invalid and the coordinator must record ACCEPT with the best evidence-backed decision available"
  fi

  # An interrupted transition may have written the decision but not the state
  # that follows it. Re-running with the same bytes must finish the job.
  if [[ -f "${dir}/coordinator-decision.md" ]]; then
    helper identical --left "${dir}/coordinator-decision.md" --right "${DECISION_FILE}" ||
      die "a different decision is already recorded at ${dir}/coordinator-decision.md; compare the two files and remove the conflict deliberately"
    note "the decision for round ${round} was already written; completing the interrupted transition"
  else
    helper write-file --path "${dir}/coordinator-decision.md" < "${DECISION_FILE}"
  fi

  local decision_digest
  decision_digest="$(helper sha256 --file "${dir}/coordinator-decision.md")"

  if [[ "${action}" == "ACCEPT" ]]; then
    local reason="coordinator-accepted"
    if [[ "${round}" -ge "${max}" ]]; then reason="maximum-rounds"; fi
    state_apply "{\"phase\": \"awaiting-final\", \"completion_reason\": $(json_string "${reason}"), \"rounds\": {\"${round}\": {\"decision\": \"ACCEPT\", \"decision_sha256\": $(json_string "${decision_digest}")}}}"
    emit_lines "awaiting-final" "${round}"
    return "${EXIT_OK}"
  fi

  # The next snapshot is built from artifacts this run already recorded. Verify
  # them first: a changed response would silently rewrite the shared context.
  local slot
  for slot in 1 2; do
    verify_recorded_artifact "${dir}/agent-${slot}-output.md" \
      "rounds.${round}.agents.${slot}.output_sha256" "the round ${round} agent ${slot} response"
  done

  local next digest
  next=$((round + 1))
  digest="$(helper snapshot --run-dir "${RUN_DIR}" --round "${next}")"
  state_apply "{\"phase\": \"awaiting-agents\", \"round\": ${next}, \"rounds\": {\"${round}\": {\"decision\": \"CONTINUE\", \"decision_sha256\": $(json_string "${decision_digest}")}, \"${next}\": {\"snapshot_sha256\": $(json_string "${digest}"), \"agents\": {\"1\": {\"status\": \"pending\", \"attempts\": 0}, \"2\": {\"status\": \"pending\", \"attempts\": 0}}}}}"
  emit_lines "continue" "${next}"
}

# ── finalize ───────────────────────────────────────────────────────────────
cmd_finalize() {
  require_run_dir
  acquire_lock
  [[ -n "${FINAL_FILE}" ]] || die "--final-file is required"
  [[ -f "${FINAL_FILE}" ]] || die "final dossier file not found: ${FINAL_FILE}"

  local phase round reason completed min max
  phase="$(state_get phase)"
  round="$(state_get round)"
  reason="$(state_get completion_reason)"
  completed="$(state_get completed_rounds 0)"
  min="$(state_get min_rounds)"
  max="$(state_get max_rounds)"

  case "${phase}" in
    awaiting-final) ;;
    blocked) die "this run is blocked by unrecoverable agent failures; a conclusive solution dossier must not be produced" "${EXIT_BLOCKED}" ;;
    complete)
      if helper identical --left "${RUN_DIR}/final-solution.md" --right "${FINAL_FILE}"; then
        emit_lines "complete" "${round}"
        return "${EXIT_OK}"
      fi
      die "this run is already finalized at ${RUN_DIR}/final-solution.md"
      ;;
    *) die "the coordinator has not accepted a solution yet (phase: ${phase})" ;;
  esac

  if ! helper validate --kind final-dossier --file "${FINAL_FILE}" \
      --expect-completed-rounds "${completed}" \
      --expect-min-rounds "${min}" \
      --expect-max-rounds "${max}" \
      --expect-completion-reason "${reason}" \
      --expect-run-dir "${RUN_DIR}" \
      --config "${RUN_DIR}/config.json"; then
    die "the final decision dossier does not satisfy the required contract (see the problems above)"
  fi

  if [[ -f "${RUN_DIR}/final-solution.md" ]]; then
    helper identical --left "${RUN_DIR}/final-solution.md" --right "${FINAL_FILE}" ||
      die "a different final dossier already exists at ${RUN_DIR}/final-solution.md; compare the two files and remove the conflict deliberately"
    note "the dossier was already written; completing the interrupted transition"
  else
    helper write-file --path "${RUN_DIR}/final-solution.md" < "${FINAL_FILE}"
  fi

  local final_digest
  final_digest="$(helper sha256 --file "${RUN_DIR}/final-solution.md")"
  state_apply "{\"phase\": \"complete\", \"final_sha256\": $(json_string "${final_digest}")}"
  emit_lines "complete" "${round}"
}

# ── status ─────────────────────────────────────────────────────────────────
cmd_status() {
  require_run_dir
  local phase round dir slot attempt prefix probe alive live=""
  phase="$(state_get phase)"
  round="$(state_get round)"
  dir="$(round_dir_for "${round}")"

  # status never mutates and never takes the lock, so it stays usable while
  # another command is working.
  for slot in 1 2; do
    [[ "$(state_get "rounds.${round}.agents.${slot}.status" pending)" == "running" ]] || continue
    attempt="$(state_get "rounds.${round}.agents.${slot}.attempts" 0)"
    [[ "${attempt}" -gt 0 ]] || continue
    prefix="$(attempt_prefix "${dir}" "${slot}" "${attempt}")"
    probe="$(helper probe-attempt --result "${prefix}-run.json" --grace "${TERMINATION_GRACE_SECONDS}" 2>/dev/null || true)"
    alive="$(printf '%s\n' "${probe}" | grep '^ALIVE=' | cut -d= -f2- || true)"
    if [[ "${alive}" == "true" ]]; then live+="${slot} "; fi
  done
  EMIT_LIVE_AGENTS="${live% }"
  emit_lines "$(phase_to_status "${phase}")" "${round}"
}

# ── main ───────────────────────────────────────────────────────────────────
parse_args "$@"
require_supported_platform
resolve_assets
[[ -x "${RUN_AGENT_PATH}" || -f "${RUN_AGENT_PATH}" ]] || die "unified runner not found: ${RUN_AGENT_PATH}"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

case "${COMMAND}" in
  start) cmd_start ;;
  run-round) cmd_run_round ;;
  record-decision) cmd_record_decision ;;
  finalize) cmd_finalize ;;
  status) cmd_status ;;
  reap) cmd_reap ;;
esac

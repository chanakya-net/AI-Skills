# Implementation Prompt: Two-Agent Solution Coordinator Skill

You are a senior software engineer working in the current `AI-Skills` repository.

Implement a local skill that acts as a semantic coordinator between two user-configured AI solution agents. The user invokes the skill with a problem and explicit harness/model/effort configuration for Agent 1 and Agent 2. The coordinator runs a bounded, multi-round collaboration, decides when the discussion has converged, and writes a detailed final decision document.

This is a local CLI/skill integration. Do not add an API integration.

## Inspect and follow the repository first

Before editing, inspect the current repository conventions, tests, installers, and runtime assets. If `.codegraph/` exists, use CodeGraph for exploration as required by `AGENTS.md`.

The implementation must reuse:

- `assets/run-agent.sh`
- `assets/agent-registry.json`

These are the single supported mechanism for detecting and launching both solution agents.

Do not invoke provider CLIs directly from the new orchestrator. Do not add per-harness command builders. Do not add an arbitrary command override or evaluate user-provided shell commands. The new code must not contain special invocation branches for Claude, Codex, Agy, OpenCode, Ollama, or any other provider.

Each solution agent must be invoked through the existing runner interface, equivalent to:

```bash
"$RUN_AGENT_PATH" \
  --agent "$AGENT_HARNESS" \
  --model "$AGENT_MODEL" \
  --effort "$AGENT_EFFORT" \
  --context-file "$ROUND_SNAPSHOT_FILE" \
  --prompt-file "$RENDERED_AGENT_PROMPT_FILE" \
  --permission-mode safe
```

Build process arguments as quoted arrays. Never use `eval`, `bash -c`, or a user-provided command string.

The existing registry remains responsible for agent aliases, executable detection, invocation templates, model flags, effort/reasoning settings, permissions, and supported-model metadata.

If another harness is needed later, it must be added through the existing registry/runner mechanism. Adding an unregistered harness is outside this v1.

## Roles

### Coordinator

The coordinator is the current invoking AI agent running `skills/pair-colleague/SKILL.md`.

The coordinator:

- receives the user's problem and configuration;
- initializes and resumes runs;
- launches Agent 1 and Agent 2 through the deterministic helper;
- reads both responses after each complete round;
- maintains the candidate-solution ledger and discussion state;
- identifies agreements, disagreements, risks, assumptions, and unanswered questions;
- decides what both agents should examine next;
- decides when the solution is acceptable after the mandatory discussion period;
- may select one proposal or synthesize compatible parts of several proposals;
- writes the final decision dossier.

The coordinator is not a third separately launched model. Do not add coordinator harness/model configuration.

### Agent 1 and Agent 2

Agent 1 and Agent 2 are equal solution colleagues selected explicitly by the user.

They explore possible solutions, develop and improve candidate designs, compare trade-offs, surface assumptions and failure modes, combine compatible ideas, explain substantive disagreement, and converge where justified.

Neither solution agent is a reviewer, judge, grader, adversary, or subordinate of the other. Process completion order must not give either agent privileged context.

## Product behavior

The collaboration should resemble:

```text
Two senior colleagues exploring alternatives on the same whiteboard,
with a coordinator keeping the discussion focused and deciding when enough
evidence exists to produce a solution.
```

It must not resemble:

```text
Writer + reviewer
Proposer + judge
Solver + critic
Debater + opponent
```

Constructive disagreement is useful, but adversarial debate, scoring, empty praise, and repetition are not.

## Files to add or update

Follow the repository's existing `skills/`, `assets/`, and `tests/` layout.

Add:

```text
skills/pair-colleague/SKILL.md
assets/pair-colleague.sh
assets/pair-colleague-process.py
assets/pair-colleague-agent-prompt.md
tests/pair-colleague.test.sh
```

`pair-colleague.sh` is the Bash control plane. `pair-colleague-process.py` is a small Python 3 helper for concurrent process execution, timeouts, process-group termination, and atomic JSON/file operations where Bash would be unsafe or non-portable. Do not grow it into a second orchestration framework.

Update as required:

```text
README.md
install.sh
tests/install-assets-contract.test.sh
```

If another existing Bash installer or documentation contract test needs a corresponding change, make the smallest consistent update.

Do not create a nested standalone project. Do not duplicate or replace `run-agent.sh` or `agent-registry.json`.

Version 1 is Bash-only and supports macOS, Linux, Git Bash, and WSL. Native PowerShell parity is out of scope. Do not add a partial PowerShell implementation and do not make `install.ps1` install a Bash feature whose required Bash runner assets it does not install. Document this limitation.

## Asset discovery

Resolve assets in this order:

1. `PAIR_COLLEAGUE_ASSETS_DIR`, when explicitly set and complete.
2. `$ASSETS_DEST`, when set and complete.
3. The directory containing `pair-colleague.sh`, when complete.
4. `$HOME/.ai-skill-collections/assets`.
5. `./assets` relative to the current repository.

The selected directory must contain:

```text
pair-colleague.sh
pair-colleague-process.py
pair-colleague-agent-prompt.md
run-agent.sh
agent-registry.json
```

Fail with a clear list of missing files if no candidate is complete.

Allow explicit dependency injection for tests:

```text
RUN_AGENT_PATH
AGENT_REGISTRY_FILE
PAIR_COLLEAGUE_PROCESS_HELPER
PAIR_COLLEAGUE_PROMPT_FILE
PAIR_COLLEAGUE_RUN_ROOT
```

Production defaults must resolve to installed or repository assets.

## Required user configuration

The user must explicitly supply harness, model, and effort for both solution agents. Never guess them and never silently use registry default models.

Support environment variables:

```bash
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
PAIR_COLLEAGUE_RUN_ROOT="${PAIR_COLLEAGUE_RUN_ROOT:-.pair-colleague/runs}"
```

Support these `start` flags, with CLI values overriding environment variables:

```text
--agent-1-harness <registered-agent-or-alias>
--agent-1-model <model>
--agent-1-effort <low|medium|high|xhigh|max|maximum>
--agent-1-name <display-name>

--agent-2-harness <registered-agent-or-alias>
--agent-2-model <model>
--agent-2-effort <low|medium|high|xhigh|max|maximum>
--agent-2-name <display-name>

--min-rounds <integer>
--max-rounds <integer>
--timeout-seconds <positive-integer>
--run-root <directory>
--help
```

Normalize `maximum` to `max` before invoking `run-agent.sh` and record normalized values.

Do not support `AGENT_1_CMD`, `AGENT_2_CMD`, `SECONDARY_CMD`, `--agent-cmd`, or another arbitrary shell escape hatch.

The two agents may use the same harness or model if explicitly selected. Warn in documentation that model/harness diversity usually produces a broader initial solution set, but do not forbid identical configurations.

## Configuration validation

Before creating a run:

1. Reject an empty task.
2. Reject any missing harness, model, or effort value for either agent.
3. Validate effort against the allowed values.
4. Require `2 <= MIN_ROUNDS <= MAX_ROUNDS <= 8`.
5. Require `TIMEOUT_SECONDS` to be a positive integer.
6. Use `run-agent.sh --list-agents --detected-only` to confirm both selected harnesses are installed, configured, enabled, and detectable.
7. Use `run-agent.sh --list-models <harness>` to confirm each requested model is registered for that harness.
8. Fail clearly when an agent is disabled, unknown, unavailable, or incompatible with its model.

Error output must explain how to inspect valid values:

```bash
assets/run-agent.sh --list-agents --detected-only
assets/run-agent.sh --list-models <agent>
```

In `SKILL.md`, if configuration is missing, instruct the coordinator to ask the user for missing values one question at a time. Never infer values from installed commands or registry defaults.

## CLI/state-machine contract

Implement these commands:

```text
start             initialize a run and create the isolated round-1 snapshot
run-round         launch any pending solution agents for the current round
record-decision   persist the coordinator's assessment and either continue or accept
finalize          validate and persist the coordinator's final decision dossier
status            print the current phase and relevant paths without changing state
```

### Start from a file

```bash
assets/pair-colleague.sh start task.md \
  --agent-1-harness codex \
  --agent-1-model gpt-5.6-terra \
  --agent-1-effort high \
  --agent-2-harness claude \
  --agent-2-model claude-sonnet-5 \
  --agent-2-effort high
```

### Start from stdin

```bash
printf '%s\n' 'Design a caching strategy for our API' | \
  assets/pair-colleague.sh start - \
    --agent-1-harness codex \
    --agent-1-model gpt-5.6-terra \
    --agent-1-effort high \
    --agent-2-harness claude \
    --agent-2-model claude-sonnet-5 \
    --agent-2-effort high
```

### Run the current round

```bash
assets/pair-colleague.sh run-round --run-dir .pair-colleague/runs/<run-id>
```

### Record the coordinator decision

```bash
assets/pair-colleague.sh record-decision \
  --run-dir .pair-colleague/runs/<run-id> \
  --decision-file /path/to/coordinator-round-3-decision.md
```

### Finalize

```bash
assets/pair-colleague.sh finalize \
  --run-dir .pair-colleague/runs/<run-id> \
  --final-file /path/to/final-solution-draft.md
```

All commands print concise machine-readable result lines to stdout and diagnostics to stderr. At minimum:

```text
STATUS=initialized | awaiting-agents | awaiting-coordinator | continue | awaiting-final | complete | error
RUN_DIR=<absolute-path>
ROUND=<integer>
SNAPSHOT=<absolute-path>
AGENT_1_OUTPUT=<absolute-path>
AGENT_2_OUTPUT=<absolute-path>
DECISION_TEMPLATE=<absolute-path>
FINAL=<absolute-path>
COMPLETION_REASON=<coordinator-accepted|maximum-rounds|blocked>
```

Never mix model output into the command contract on stdout.

## Run directory

Create a unique run directory atomically. A timestamp alone is insufficient because multiple starts in one second must not collide.

Use a structure similar to:

```text
.pair-colleague/runs/20260823-092500-a1b2c3/
  task.md
  config.json
  state.json
  rounds/
    round-01/
      snapshot.md
      snapshot.sha256
      agent-1-prompt.md
      agent-1-output.md
      agent-1-stderr.log
      agent-1-run.json
      agent-2-prompt.md
      agent-2-output.md
      agent-2-stderr.log
      agent-2-run.json
      coordinator-decision-template.md
      coordinator-decision.md
    round-02/
      snapshot.md
      ...
  final-solution.md
```

Requirements:

- Never overwrite a prior run or completed attempt.
- Save every snapshot, rendered prompt, stdout, stderr, runner result, coordinator decision, and final artifact.
- Write `state.json` and canonical artifacts atomically.
- `state.json` is the source of truth for phase, round, completed agents, retry counts, decisions, and completion reason.
- Store only non-secret effective configuration. Never persist environment dumps, authentication values, tokens, or unrelated environment variables.
- Resolve emitted paths to absolute paths.
- Preserve failed attempts under unique attempt-numbered paths.
- Keep the last committed state unchanged if a command fails before its atomic transition.

## Frozen-context rule

Within a round, Agent 1 and Agent 2 must receive the exact same immutable `snapshot.md` bytes. Record its SHA-256 digest.

Neither agent may see the other agent's current-round response before both have completed. Process launch order and completion order must not affect context. The coordinator reads both responses only after the round is complete.

### Round 1: independent exploration

Round 1 contains the original problem, user-provided constraints/success criteria, and instructions to develop multiple candidate solutions independently. It must not contain either agent's output or a coordinator-preferred solution.

Each agent should propose at least two materially distinct credible solutions when the problem admits alternatives. If only one credible approach exists, the agent must explain why alternatives are not viable.

The purpose is to reduce anchoring and start from genuinely different ideas.

### Round 2 and later: shared discussion snapshot

After each complete round, the coordinator writes a structured decision. The helper uses that decision plus the two completed responses to build the next frozen snapshot.

Each later snapshot contains:

```markdown
# Original problem

<immutable task>

# Constraints and success criteria

<stable known constraints>

# Candidate-solution ledger

<candidate IDs, descriptions, current status>

# Current synthesis or preferred direction

<current best combined direction, or "Not selected">

# Agreements

<points supported by both agents or established by evidence>

# Disagreements

<substantive unresolved differences>

# Rejected candidates

<candidate IDs and current rejection reasons>

# Unresolved questions and risks

<items that still matter>

# Coordinator focus for this round

<specific questions or work requested from both agents>

# Previous round: Agent 1

<verbatim prior response>

# Previous round: Agent 2

<verbatim prior response>
```

Do not append every historical raw response to every snapshot. Preserve full history on disk, but include only the previous round verbatim plus the coordinator's compact cumulative ledger and synthesis. This keeps context bounded without losing traceability.

## Agent prompt template

Create `assets/pair-colleague-agent-prompt.md` with variables:

```text
{{AGENT_NAME}}
{{OTHER_AGENT_NAME}}
{{ROUND_NUMBER}}
{{MIN_ROUNDS}}
{{MAX_ROUNDS}}
{{EFFORT_LEVEL}}
```

Render a separate prompt file for each agent and round. Never modify the installed template in place and never pass unresolved `{{...}}` variables to `run-agent.sh`.

The prompt must tell each agent:

- You are an equal solution colleague.
- Build useful candidate solutions rather than review or grade the other agent.
- Constructively compare alternatives, assumptions, trade-offs, risks, and failure modes.
- Improve or combine ideas when that produces a stronger result.
- Refer to candidate IDs from the shared ledger when available.
- Clearly identify genuine agreement and disagreement.
- Avoid adversarial language, scoring, repetition, and empty praise.
- Do not claim consensus merely to finish.
- You may inspect the repository read-only if the problem requires it, but must not modify files or implement the solution during this discussion.
- Return only the required structured response.

Use this output contract:

```markdown
# Candidate analysis

<analysis of current candidates or new candidates worth adding>

# Preferred solution

<preferred or synthesized direction and why>

# Improvements and implementation detail

<concrete refinements that make the solution actionable>

# Agreements

<points supported from the shared discussion>

# Disagreements

<remaining disagreement and its technical basis, or "None">

# Risks and unresolved questions

<remaining material issues, or "None">

# Suggested next step

<what the next discussion round should resolve, or why the solution is sufficient>

DISCUSSION_STATUS: CONTINUE
```

The final non-empty line must be exactly one of:

```text
DISCUSSION_STATUS: CONTINUE
DISCUSSION_STATUS: READY
```

Agent statuses are advisory evidence. They do not automatically stop the run and do not override the coordinator.

## Parallel round execution

Launch Agent 1 and Agent 2 as separate child process groups against the same snapshot. Prefer concurrent execution so neither is conceptually treated as responding second.

The repository already requires Python 3. Use `pair-colleague-process.py` with `subprocess.Popen(..., start_new_session=True)` or the appropriate platform equivalent to:

- invoke both `run-agent.sh` commands without a shell;
- capture stdout and stderr separately;
- enforce `TIMEOUT_SECONDS` independently;
- terminate an agent's whole process group on timeout;
- record exit status and timeout state;
- preserve partial diagnostics;
- wait for both processes before reporting the round outcome.

Do not depend on GNU `timeout`, which is not installed by default on macOS.

A round is complete only when both agent outputs come from the recorded frozen snapshot, exit successfully, are non-empty, contain every required section exactly once, end with exactly one valid `DISCUSSION_STATUS` line, and contain no unexpected text after the status.

If one agent succeeds and the other fails, preserve the successful result and retry only the failed agent against the same snapshot. Do not expose the successful response to the retrying agent and do not advance to coordinator review until both valid results exist.

## Coordinator decision contract

After a complete round, generate this decision template for the coordinator:

```markdown
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
```

The final non-empty line must be exactly one of:

```text
COORDINATOR_ACTION: CONTINUE
COORDINATOR_ACTION: ACCEPT
```

`record-decision` validates the file and enforces the round policy mechanically.

## Mandatory discussion and stopping policy

Defaults:

```text
MIN_ROUNDS=3
MAX_ROUNDS=8
```

One round is complete only after both solution agents have produced valid responses to the same snapshot.

Rules:

1. The coordinator must not accept before `MIN_ROUNDS` complete rounds.
2. Agent `READY` statuses do not bypass the minimum.
3. Before the minimum, `record-decision` rejects `ACCEPT` without changing state.
4. After the minimum, the coordinator may accept or continue.
5. The coordinator may accept a solution supported by both agents, select one when they disagree, or synthesize compatible ideas.
6. Any unresolved disagreement must appear in the coordinator decision and final dossier.
7. The coordinator may request targeted additional analysis when another round is likely to change the decision materially.
8. Round `MAX_ROUNDS` is a hard stop. After it, `CONTINUE` is invalid and the coordinator must produce the best evidence-backed final decision available.
9. If infrastructure failures prevent both agents from completing enough rounds, stop as `blocked`; do not pretend the discussion threshold was reached.

Completion reasons are deterministic:

- `ACCEPT` recorded after the minimum and before the maximum produces `coordinator-accepted`.
- `ACCEPT` recorded for the maximum round produces `maximum-rounds`, even if the final round also achieved agreement.
- An unrecoverable infrastructure failure before the required discussion completes produces `blocked` and must not generate a falsely conclusive solution dossier.

Suggested progression, without making it rigid:

```text
Round 1: independent candidate generation
Round 2: comparison, constraints, and trade-offs
Round 3: stress testing and initial synthesis
Rounds 4-7: targeted resolution and refinement when needed
Round 8: mandatory final decision if still unresolved
```

## Coordinator acceptance rubric

After the minimum round count, the coordinator may accept only after checking:

- The problem and success criteria are understood.
- Multiple credible solutions were considered when alternatives exist.
- The preferred or synthesized solution is internally coherent.
- The solution is detailed enough to explain how it works.
- Important constraints and assumptions are explicit.
- Trade-offs and failure modes have been examined.
- Material risks have mitigations or are clearly disclosed.
- Rejected alternatives have evidence-based reasons.
- Agent agreement and disagreement are accurately represented.
- Remaining uncertainty is acceptable or requires explicit human input.
- Another round is unlikely to improve the decision materially, or the maximum has been reached.

The coordinator's semantic judgment is authoritative. Agent agreement is useful evidence, not an automatic stop condition.

## Final decision dossier

After `ACCEPT`, the skill writes a complete Markdown dossier and passes it to `finalize`. The helper validates required sections and saves it atomically as `final-solution.md`.

Required structure:

```markdown
# Final Solution Decision

## Executive summary

<selected solution and outcome>

## Problem and success criteria

<problem, desired outcome, and measurable success criteria>

## Constraints and assumptions

<known constraints and assumptions>

## Candidate solutions considered

<all material candidates with stable IDs and summaries>

## Trade-off comparison

<benefits, costs, complexity, risks, and fit>

## Selected or synthesized solution

<the complete chosen solution>

## Detailed design and operation

<components, workflow, data/control flow, boundaries, and important behavior>

## How this solves the problem

<mapping from solution elements to requirements and success criteria>

## Implementation approach

<ordered strategy, dependencies, validation, and rollout>

## Decision rationale

<why the coordinator accepted this solution>

## Agent agreement

<where both agents agreed and why>

## Remaining disagreement and coordinator resolution

<unresolved positions and the coordinator's resolution, or "None" only when accurate>

## Rejected alternatives

<alternatives, rejection reasons, and when they might be preferable>

## Risks and mitigations

<material risks and mitigations>

## Open questions and human decisions

<remaining questions or approvals, or "None">

## Discussion record

- Coordinator: current invoking agent
- Agent 1: <name, harness, model, effort>
- Agent 2: <name, harness, model, effort>
- Completed rounds: <n>
- Minimum rounds: <n>
- Maximum rounds: <n>
- Completion reason: coordinator-accepted | maximum-rounds
- Run directory: <path>
```

Do not falsely claim agreement. If the coordinator decides despite disagreement, document both positions and the decision basis.

Generate the dossier from the immutable problem, validated round artifacts, and recorded coordinator decisions. Do not copy unchecked raw output wholesale as the final answer.

`finalize` rejects a dossier with missing or duplicate required headings, placeholder text, inconsistent round count, or a completion reason that conflicts with state.

## `SKILL.md` workflow

The skill must instruct the current invoking agent to:

1. Receive the user's problem.
2. Ask for any missing Agent 1/Agent 2 harness, model, or effort one question at a time.
3. Resolve the asset root and run `start`.
4. Call `run-round` for the current round.
5. Wait until both valid outputs exist or handle a reported retry/blocker.
6. Read the frozen snapshot and both outputs.
7. Write the coordinator decision using the required contract.
8. Before `MIN_ROUNDS`, always choose `CONTINUE` and provide useful next-round focus.
9. Call `record-decision`.
10. When continuing, repeat from `run-round` with the generated next snapshot.
11. When accepting, write the complete final decision dossier.
12. Call `finalize` and present `final-solution.md` to the user.
13. Include the run directory path so the full discussion remains inspectable.

The coordinator must remain engaged for the entire run. It must not delegate semantic acceptance to a grep check, readiness counter, or one of the solution agents.

## Security and safety

- Use `#!/usr/bin/env bash` and `set -euo pipefail` in the new Bash script.
- Quote all paths and values.
- Use argument arrays for child processes.
- Never use `eval` or execute a user-provided command string.
- Launch both agents through `run-agent.sh` with safe permission mode.
- Agent prompts allow read-only repository inspection when relevant but forbid implementation and file modification.
- Do not automatically include `.env` files, credentials, tokens, private keys, or unrelated repository files in context.
- Pass only the frozen snapshot and rendered role prompt through the runner interface.
- Use atomic state/file transitions.
- Reject invalid state transitions and attempts to advance completed runs.
- Do not delete material user data.
- Preserve diagnostics without leaking them into another agent's context.

## Tests

Use test-first development. Tests must not require network access or installed AI harnesses.

Use an injected fake `run-agent` and isolated temporary run root to verify:

1. File and stdin problem input work.
2. Missing configuration for either agent fails clearly.
3. Invalid effort, timeout, and round bounds fail.
4. `2 <= MIN_ROUNDS <= MAX_ROUNDS <= 8` is enforced.
5. Detection and model compatibility are delegated to the injected runner interface.
6. Both invocations receive the selected harness, model, effort, context, rendered prompt, and safe permission mode.
7. There is no direct provider CLI invocation or arbitrary-command path.
8. Round 1 gives both agents byte-identical snapshots with no other-agent output.
9. Neither agent receives the other's current-round response.
10. Round 2 contains both round-1 responses plus the coordinator synthesis.
11. Later snapshots contain only the previous responses plus compact cumulative coordinator state, not unbounded raw history.
12. Rendered prompts contain no unresolved variables.
13. Unique run directories and attempt artifacts never overwrite prior data.
14. Exact status parsing rejects malformed or trailing output.
15. A round cannot reach `awaiting-coordinator` until both valid outputs exist.
16. If one agent fails, only that agent is retried against the unchanged snapshot.
17. Timeout terminates the failed process group, preserves diagnostics, and does not corrupt state.
18. `ACCEPT` is rejected before the minimum completed rounds.
19. `CONTINUE` works after the minimum and before the maximum.
20. `CONTINUE` is rejected after the maximum round.
21. The coordinator may accept despite advisory agent disagreement after the minimum.
22. A completed run cannot be advanced or finalized twice.
23. The final dossier validator requires every section and consistent metadata.
24. The Bash installer dry run includes the new shell, Python helper, and prompt assets.
25. The native PowerShell installer remains unchanged for this Bash-only v1.
26. Existing tests continue to pass.

At minimum, run:

```bash
bash tests/pair-colleague.test.sh
bash tests/run-agent.test.sh
bash tests/install-assets-contract.test.sh
```

Then run the repository's established complete test suite. Report exact commands and results.

## README requirements

Document:

- coordinator/Agent 1/Agent 2 roles;
- that the current invoking AI is the coordinator;
- explicit configuration for both agents;
- unified runner/registry launching;
- isolated round-1 proposals;
- identical frozen context from round 2 onward;
- default and valid round bounds;
- coordinator acceptance authority;
- disagreement and maximum-round handling;
- run artifacts and resumption;
- final dossier contents;
- Bash-only scope;
- file and stdin examples;
- that installed harnesses may still use remote models although orchestration is local.

## Acceptance criteria

Implementation is complete when:

1. A user can invoke the skill with a problem and explicit configuration for two solution agents.
2. The current invoking AI acts as semantic coordinator.
3. Both agents launch only through the existing runner and registry.
4. There are no direct provider launch commands or arbitrary command overrides.
5. Missing harness/model/effort values are never guessed.
6. Round 1 produces independent multiple-solution exploration.
7. Every later round gives both agents the same immutable context snapshot.
8. Neither sees the other's current-round response before both finish.
9. The configured minimum rounds complete before acceptance.
10. The configured maximum, never above eight, is enforced.
11. The coordinator can continue, select, synthesize, or accept using semantic judgment.
12. Agent readiness is advisory and cannot bypass coordinator policy.
13. Disagreement is preserved accurately.
14. Runs are persistent, inspectable, resumable, and atomically updated.
15. All prompts, contexts, responses, decisions, errors, and metadata are saved.
16. `final-solution.md` explains the solution, operation, problem fit, rationale, alternatives, agreements, disagreements, risks, and implementation approach.
17. Tests use a fake runner and pass without network access or real AI CLIs.
18. Installer and README cover the skill and assets.
19. Existing repository behavior and tests remain green.

## Design priorities

Prioritize, in order:

```text
correct reuse of the existing unified runner
independent and symmetric agent participation
meaningful multi-solution exploration
coordinator-controlled semantic convergence
bounded cost and runtime
inspectable decision history
safe process execution
resumability
clear final rationale
simplicity and maintainability
```

Do not build a second agent-launch framework. Do not reduce coordinator judgment to exact status matching. Do not over-engineer beyond these requirements.

Implement the change in the current repository, verify it, and summarize the files changed and test evidence.

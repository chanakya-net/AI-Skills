#!/usr/bin/env bash
# Authoring contract test: asserts every SKILL.md meets the standard in
# skills/writing-agent-docs/SKILL.md — valid frontmatter, a context pointer that
# carries trigger branches, bounded context load, the compressed isolation
# block, declared twins, and an .agents/skills/ mirror that has not drifted.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILURES=0
DESCRIPTION_MAX_CHARS=500

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_contains() {  # file token message
  grep -Fq -- "$2" "$ROOT_DIR/$1" || fail "$1: $3"
}

assert_not_contains() {  # file token message
  if grep -Fq -- "$2" "$ROOT_DIR/$1"; then fail "$1: $3"; fi
}

# --- Frontmatter, pointer wording, and context load ---------------------------
# A model-invoked description is a context pointer: it must name the branches
# that should trigger the skill, not only state what the skill is.

while IFS= read -r report; do
  [[ -z "$report" ]] && continue
  fail "$report"
done < <(cd "$ROOT_DIR" && python3 - "$DESCRIPTION_MAX_CHARS" <<'PYEOF'
import pathlib, re, sys

max_chars = int(sys.argv[1])
trigger_re = re.compile(
    r"\bUse (?:when|this skill when|for)\b|\bTriggers? on\b|\bwhen (?:the )?user says\b",
    re.IGNORECASE,
)

for skill_dir in sorted(pathlib.Path("skills").iterdir()):
    if not skill_dir.is_dir():
        continue
    name = skill_dir.name
    path = skill_dir / "SKILL.md"
    if not path.is_file():
        print(f"skills/{name}: SKILL.md is missing")
        continue

    text = path.read_text()
    if not text.startswith("---\n"):
        print(f"skills/{name}/SKILL.md: frontmatter must open the file")
        continue

    end = text.find("\n---", 4)
    if end == -1:
        print(f"skills/{name}/SKILL.md: frontmatter is not terminated")
        continue
    front = text[4:end]

    declared = re.search(r"^name:\s*(\S+)", front, re.M)
    if not declared:
        print(f"skills/{name}/SKILL.md: frontmatter has no name")
    elif declared.group(1) != name:
        print(f"skills/{name}/SKILL.md: name '{declared.group(1)}' must match the directory")

    match = re.search(r"^description:(.*?)(?=^[A-Za-z][\w-]*:|\Z)", front, re.S | re.M)
    if not match:
        print(f"skills/{name}/SKILL.md: frontmatter has no description")
        continue

    description = " ".join(match.group(1).replace(">", " ", 1).split())
    if not description:
        print(f"skills/{name}/SKILL.md: description is empty")
        continue
    if len(description) > max_chars:
        print(f"skills/{name}/SKILL.md: description is {len(description)} chars, over the {max_chars} context-load bound")

    user_invoked = re.search(r"^disable-model-invocation:\s*true\s*$", front, re.M)
    if user_invoked:
        if trigger_re.search(description):
            print(f"skills/{name}/SKILL.md: user-invoked description must strip trigger lists")
    elif not trigger_re.search(description):
        print(f"skills/{name}/SKILL.md: model-invoked description states identity but no trigger branches")
PYEOF
)

# --- Isolation block: one compressed form, positive-first ---------------------

for skill in break-req create-git-issue help-me-debug run-with-it save-tokens tdd-implementation writing-agent-docs; do
  assert_contains "skills/${skill}/SKILL.md" '## Skill Isolation' \
    "every skill declares its isolation boundary"
  assert_not_contains "skills/${skill}/SKILL.md" 'No other skill may activate, interrupt, or modify' \
    "isolation block must use the compressed positive-first form"
done

# The worker-prompt bootstrap carve-out survives the compression.
assert_contains "skills/save-tokens/SKILL.md" 'governing prompt' \
  "save-tokens isolation must allow the worker-prompt bootstrap"
assert_contains "skills/tdd-implementation/SKILL.md" 'governing prompt' \
  "tdd-implementation isolation must allow the worker-prompt bootstrap"

# --- Declared twins carry their SYNC marker ----------------------------------
# Duplication is legitimate here only when both halves name each other.

for twin in \
  "skills/run-with-it/SKILL.md" \
  "assets/main-orchestrator-rules.md" \
  "assets/sub-coordinator-prompt.md" \
  "assets/coordinator-rules.md" \
  "assets/prompt.md" \
  "assets/modifier-prompt.md" \
  "AGENTS.md"; do
  assert_contains "$twin" '<!-- SYNC:' \
    "declared twin must carry a SYNC comment naming its partner"
done

# --- The authoring standard is reachable -------------------------------------

assert_contains "skills/writing-agent-docs/SKILL.md" 'SKILL-MECHANICS.md' \
  "writing-agent-docs must point at its mechanics branch"
assert_contains "skills/writing-agent-docs/SKILL.md" 'Use when working in the `chanakya-net/Maestro-AI` repository' \
  "repo-specific authoring contracts must not auto-activate in unrelated repositories"
[[ -f "$ROOT_DIR/skills/writing-agent-docs/SKILL-MECHANICS.md" ]] \
  || fail "skills/writing-agent-docs/SKILL-MECHANICS.md: mechanics branch is missing"

assert_contains "AGENTS.md" 'writing-agent-docs' \
  "AGENTS.md must route document edits through the authoring skill"

# Claude Code reads CLAUDE.md, never AGENTS.md, so the import is what wires the
# entry point into a Claude Code session. Without it the routing silently no-ops.
assert_contains "CLAUDE.md" '@AGENTS.md' \
  "CLAUDE.md must import AGENTS.md so Claude Code loads the entry point"
assert_contains "AGENTS.md" 'docs/prose-checklist.md' \
  "AGENTS.md must route human-facing prose through the prose checklist"
assert_contains "AGENTS.md" 'for the strings you are about to change' \
  "AGENTS.md must require the contract-test grep before prose edits"

assert_contains "docs/prose-checklist.md" 'Never run this on `SKILL.md` or `assets/*.md`.' \
  "prose checklist must state the agent-facing files it never runs on"

# --- The checked-in skills lock matches every source skill -------------------
# npx skills hashes each skill folder as sorted relative path bytes followed by
# file-content bytes. A stale lock silently breaks update/change detection.

while IFS= read -r report; do
  [[ -z "$report" ]] && continue
  fail "$report"
done < <(cd "$ROOT_DIR" && python3 - <<'PYEOF'
import hashlib
import json
import pathlib

skills_root = pathlib.Path("skills")
lock_path = pathlib.Path("skills-lock.json")

try:
    locked = json.loads(lock_path.read_text())["skills"]
except (FileNotFoundError, KeyError, json.JSONDecodeError) as exc:
    print(f"skills-lock.json: invalid lock file: {exc}")
    raise SystemExit

source_names = sorted(path.name for path in skills_root.iterdir() if path.is_dir())
locked_names = sorted(locked)
if locked_names != source_names:
    missing = sorted(set(source_names) - set(locked_names))
    extra = sorted(set(locked_names) - set(source_names))
    if missing:
        print(f"skills-lock.json: missing skills: {', '.join(missing)}")
    if extra:
        print(f"skills-lock.json: unknown skills: {', '.join(extra)}")

for name in source_names:
    skill_dir = skills_root / name
    digest = hashlib.sha256()
    files = sorted(
        (
            path
            for path in skill_dir.rglob("*")
            if path.is_file()
            and ".git" not in path.relative_to(skill_dir).parts
            and "node_modules" not in path.relative_to(skill_dir).parts
        ),
        key=lambda path: path.relative_to(skill_dir).as_posix(),
    )
    for path in files:
        relative = path.relative_to(skill_dir).as_posix()
        digest.update(relative.encode())
        digest.update(path.read_bytes())

    entry = locked.get(name)
    if entry is None:
        continue
    expected_path = f"skills/{name}/SKILL.md"
    if entry.get("skillPath") != expected_path:
        print(f"skills-lock.json: {name} skillPath must be {expected_path}")
    if entry.get("computedHash") != digest.hexdigest():
        print(f"skills-lock.json: {name} computedHash is stale")
PYEOF
)

# --- Skill activation language is host-neutral ------------------------------

skill_label='`Skill`'
tool_label='tool'
forbidden_activation_pattern="(${skill_label}[[:space:]]+(${tool_label}|call)|Skill[[:space:]]+${tool_label}|skill-${tool_label})"

while IFS= read -r -d '' markdown_file; do
  relative_path="${markdown_file#"$ROOT_DIR"/}"
  if grep -Eiq "$forbidden_activation_pattern" "$markdown_file"; then
    fail "$relative_path: describe native skill activation without assuming one literal tool name"
  fi
done < <(
  find "$ROOT_DIR" \
    \( -path "$ROOT_DIR/.git" -o -path "$ROOT_DIR/.codegraph" \) -prune -o \
    -type f -name '*.md' -print0
)

# --- The .agents/skills/ mirror has not drifted ------------------------------

if ! bash "$ROOT_DIR/tools/sync-agent-skills.sh" --check >/dev/null 2>&1; then
  bash "$ROOT_DIR/tools/sync-agent-skills.sh" --check >/dev/null || true
  fail ".agents/skills: mirror has drifted from skills/ (run tools/sync-agent-skills.sh)"
fi

if (( FAILURES > 0 )); then
  printf '%d skill authoring failure(s)\n' "$FAILURES" >&2
  exit 1
fi

printf 'skill authoring contract: OK\n'

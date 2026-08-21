#!/usr/bin/env bash
# Mirrors skills/ into .agents/skills/ for repo-local discovery by agents that
# follow the Agent Skills convention (Codex, Antigravity, and friends read
# .agents/skills/ when the repo is the workspace).
#
# The mirror is a declared twin: tests/skill-authoring-contract.test.sh fails the
# build when the two trees diverge. Run this after any change under skills/.
#
# Usage:
#   tools/sync-agent-skills.sh          # write the mirror
#   tools/sync-agent-skills.sh --check  # report drift, change nothing (exit 1 on drift)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC="${ROOT_DIR}/skills"
DEST="${ROOT_DIR}/.agents/skills"
CHECK_ONLY=0

[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

drift=0

# Every skill directory under skills/ must exist identically under .agents/skills/.
while IFS= read -r skill_dir; do
  name="$(basename "$skill_dir")"
  if (( CHECK_ONLY )); then
    if ! diff -r -q "$skill_dir" "${DEST}/${name}" >/dev/null 2>&1; then
      printf 'DRIFT: skills/%s does not match .agents/skills/%s\n' "$name" "$name" >&2
      drift=1
    fi
  else
    rm -rf "${DEST:?}/${name}"
    mkdir -p "${DEST}"
    cp -R "$skill_dir" "${DEST}/${name}"
  fi
done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d | sort)

# A directory in the mirror with no source is a leftover from a rename or removal.
if [[ -d "$DEST" ]]; then
  while IFS= read -r mirror_dir; do
    name="$(basename "$mirror_dir")"
    if [[ ! -d "${SRC}/${name}" ]]; then
      if (( CHECK_ONLY )); then
        printf 'DRIFT: .agents/skills/%s has no source under skills/\n' "$name" >&2
        drift=1
      else
        rm -rf "$mirror_dir"
      fi
    fi
  done < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d | sort)
fi

if (( CHECK_ONLY )); then
  (( drift == 0 )) && printf 'agent-skills mirror: in sync\n'
  exit "$drift"
fi

printf 'agent-skills mirror: synced from skills/\n'

#!/usr/bin/env python3
"""Process and file primitives for the pair-colleague coordinator.

`pair-colleague.sh` owns the CLI, the configuration policy, and the state
machine. This helper owns only the pieces Bash cannot do safely or portably:

* concurrent child execution with independent timeouts and process-group
  termination (no dependency on GNU ``timeout``);
* atomic JSON and file writes;
* deterministic Markdown section parsing and contract validation;
* unique run-directory creation.

It deliberately does not orchestrate rounds, choose agents, or build agent
command lines.
"""

from __future__ import annotations

import argparse
import binascii
import datetime
import errno
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Any, Iterable


# ── Contracts ──────────────────────────────────────────────────────────────

AGENT_SECTIONS = [
    "Candidate analysis",
    "Preferred solution",
    "Improvements and implementation detail",
    "Agreements",
    "Disagreements",
    "Risks and unresolved questions",
    "Suggested next step",
]

DECISION_SECTIONS = [
    "Round assessment",
    "Candidate-solution ledger",
    "Current synthesis or preferred direction",
    "Agreements",
    "Disagreements",
    "Rejected candidates",
    "Unresolved questions and risks",
    "Focus for next round",
    "Decision rationale",
]

DOSSIER_SECTIONS = [
    "Executive summary",
    "Problem and success criteria",
    "Constraints and assumptions",
    "Candidate solutions considered",
    "Trade-off comparison",
    "Selected or synthesized solution",
    "Detailed design and operation",
    "How this solves the problem",
    "Implementation approach",
    "Decision rationale",
    "Agent agreement",
    "Remaining disagreement and coordinator resolution",
    "Rejected alternatives",
    "Risks and mitigations",
    "Open questions and human decisions",
    "Discussion record",
]

AGENT_STATUS_VALUES = ("CONTINUE", "READY")
DECISION_ACTION_VALUES = ("CONTINUE", "ACCEPT")

PLACEHOLDER_LINE = re.compile(r"^<[^<>]{3,}>$")
PLACEHOLDER_WORDS = re.compile(r"\b(TODO|TBD|FIXME)\b")
UNRESOLVED_TEMPLATE = re.compile(r"\{\{[A-Za-z0-9_]+\}\}")
INLINE_CODE = re.compile(r"`+[^`]*`+")

DISCUSSION_RECORD_SECTION = "Discussion record"

DOSSIER_RUN_LABELS = (
    ("Completed rounds", "completed_rounds"),
    ("Minimum rounds", "min_rounds"),
    ("Maximum rounds", "max_rounds"),
    ("Completion reason", "completion_reason"),
    ("Run directory", "run_dir"),
)


class HelperError(Exception):
    """A user-facing failure; the message is printed without a traceback."""


# ── Small file utilities ───────────────────────────────────────────────────


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write_bytes_atomic(path: str, payload: bytes) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    tmp_path = os.path.join(directory, f".{os.path.basename(path)}.tmp.{os.getpid()}")
    with open(tmp_path, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, path)


def write_text_atomic(path: str, text: str) -> None:
    write_bytes_atomic(path, text.encode("utf-8"))


def write_json_atomic(path: str, value: Any) -> None:
    write_text_atomic(path, json.dumps(value, indent=2) + "\n")


def read_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def read_patch(source: str) -> dict[str, Any]:
    text = sys.stdin.read() if source == "-" else read_text(source)
    value = json.loads(text)
    if not isinstance(value, dict):
        raise HelperError("patch must be a JSON object")
    return value


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def deep_merge(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


# ── Markdown section parsing ───────────────────────────────────────────────


def normalize_lines(text: str) -> list[str]:
    return [line.rstrip("\r") for line in text.replace("\r\n", "\n").split("\n")]


FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def fence_mask(lines: list[str]) -> list[bool]:
    """Mark every line that belongs to a fenced code block.

    Markdown inside a fence is an example, not document structure: a template
    shown in a ```markdown block must never satisfy — or violate — a heading,
    status-line, metadata, or placeholder rule.
    """
    mask = [False] * len(lines)
    fence_char = ""
    fence_len = 0
    for index, line in enumerate(lines):
        match = FENCE_OPEN.match(line)
        token = match.group(1) if match else ""
        if not fence_char:
            if token:
                fence_char, fence_len = token[0], len(token)
                mask[index] = True
            continue
        mask[index] = True
        if token and token[0] == fence_char and len(token) >= fence_len and line.strip() == token:
            fence_char, fence_len = "", 0
    return mask


def structural(text: str) -> tuple[list[str], list[bool]]:
    lines = normalize_lines(text)
    return lines, fence_mask(lines)


def heading_occurrences(
    lines: list[str], level: int, title: str, mask: list[bool] | None = None
) -> list[int]:
    marker = "#" * level + " " + title
    if mask is None:
        mask = fence_mask(list(lines))
    return [
        index
        for index, line in enumerate(lines)
        if not mask[index] and line.strip() == marker
    ]


def extract_section(text: str, level: int, title: str) -> str:
    """Return the body under the first `title` heading at `level`."""
    lines, mask = structural(text)
    positions = heading_occurrences(lines, level, title, mask)
    if not positions:
        return ""
    start = positions[0] + 1
    prefix = "#" * level + " "
    end = len(lines)
    for index in range(start, len(lines)):
        if mask[index]:
            continue
        stripped = lines[index].strip()
        if stripped.startswith(prefix) or re.match(r"^#{1,%d} \S" % level, stripped):
            end = index
            break
    return "\n".join(lines[start:end]).strip("\n")


def trailing_status(lines: list[str], key: str) -> tuple[str, list[str]]:
    """Return (value, errors) for the trailing `KEY: VALUE` contract line."""
    errors: list[str] = []
    mask = fence_mask(list(lines))
    status_indexes = [
        index
        for index, line in enumerate(lines)
        if not mask[index] and line.strip().startswith(f"{key}:")
    ]
    if not status_indexes:
        errors.append(f"missing required final line '{key}: <value>'")
        return "", errors
    if len(status_indexes) > 1:
        errors.append(f"found {len(status_indexes)} '{key}' lines; exactly one is allowed")
        return "", errors

    index = status_indexes[0]
    raw = lines[index].strip()
    value = raw[len(key) + 1 :].strip()
    for tail in lines[index + 1 :]:
        if tail.strip():
            errors.append(
                f"unexpected text after the '{key}' line: {tail.strip()[:80]!r}"
            )
            break
    return value, errors


def section_errors(text: str, level: int, titles: list[str]) -> list[str]:
    lines, mask = structural(text)
    errors: list[str] = []
    last_position = -1
    for title in titles:
        positions = heading_occurrences(lines, level, title, mask)
        if not positions:
            errors.append(f"missing required section '{'#' * level} {title}'")
            continue
        if len(positions) > 1:
            errors.append(
                f"section '{'#' * level} {title}' appears {len(positions)} times; "
                "exactly one is required"
            )
            continue
        if positions[0] < last_position:
            errors.append(f"section '{'#' * level} {title}' is out of order")
        last_position = positions[0]
    return errors


def empty_section_errors(text: str, level: int, titles: list[str]) -> list[str]:
    errors = []
    for title in titles:
        if not extract_section(text, level, title).strip():
            errors.append(f"section '{'#' * level} {title}' is empty")
    return errors


def placeholder_errors(text: str) -> list[str]:
    """Flag unfilled template text outside fenced examples.

    Fenced blocks are excluded so a document may legitimately quote the
    template it was built from, and marker words are matched on word
    boundaries so ordinary technical prose is not rejected.
    """
    errors = []
    lines, mask = structural(text)
    for index, line in enumerate(lines):
        if mask[index]:
            continue
        stripped = line.strip()
        if PLACEHOLDER_LINE.match(stripped):
            errors.append(f"unfilled placeholder text: {stripped[:80]!r}")
        # An inline code span quotes syntax rather than leaving it unfilled, so
        # prose may discuss `{{AGENT_NAME}}` or a `TODO` marker by name.
        prose = INLINE_CODE.sub(" ", stripped)
        match = PLACEHOLDER_WORDS.search(prose)
        if match:
            errors.append(f"placeholder marker {match.group(1)!r} in: {stripped[:80]!r}")
        if UNRESOLVED_TEMPLATE.search(prose):
            errors.append(f"unresolved template variable in: {stripped[:80]!r}")
    return errors


# ── Validators ─────────────────────────────────────────────────────────────


def validate_agent_output(path: str) -> list[str]:
    text = read_text(path)
    if not text.strip():
        return ["agent produced no output"]
    errors = section_errors(text, 1, AGENT_SECTIONS)
    errors += empty_section_errors(text, 1, AGENT_SECTIONS)
    errors += placeholder_errors(text)
    value, status_errors = trailing_status(normalize_lines(text), "DISCUSSION_STATUS")
    errors += status_errors
    if value and value not in AGENT_STATUS_VALUES:
        errors.append(
            f"DISCUSSION_STATUS must be one of {', '.join(AGENT_STATUS_VALUES)}; got {value!r}"
        )
    return errors


def validate_decision(path: str) -> list[str]:
    text = read_text(path)
    if not text.strip():
        return ["coordinator decision is empty"]
    errors = section_errors(text, 1, DECISION_SECTIONS)
    errors += empty_section_errors(text, 1, DECISION_SECTIONS)
    errors += placeholder_errors(text)
    value, status_errors = trailing_status(normalize_lines(text), "COORDINATOR_ACTION")
    errors += status_errors
    if value and value not in DECISION_ACTION_VALUES:
        errors.append(
            f"COORDINATOR_ACTION must be one of {', '.join(DECISION_ACTION_VALUES)}; got {value!r}"
        )
    return errors


def metadata_values(text: str, label: str) -> list[str]:
    """Every `- Label: value` line in `text`, outside fenced examples."""
    pattern = re.compile(r"^\s*[-*]\s*" + re.escape(label) + r"\s*:\s*(.+?)\s*$")
    lines, mask = structural(text)
    found = []
    for index, line in enumerate(lines):
        if mask[index]:
            continue
        match = pattern.match(line)
        if match:
            found.append(match.group(1).strip())
    return found


def agent_identity_errors(record: str, slot: str, agent: dict[str, str]) -> list[str]:
    """The dossier must name each colleague's real configuration, not a guess."""
    label = f"Agent {slot}"
    values = metadata_values(record, label)
    if not values:
        return [f"Discussion record is missing the '{label}' line"]
    if len(values) > 1:
        return [
            f"Discussion record has {len(values)} '{label}' lines; exactly one is required"
        ]

    expected = [agent.get(key, "") for key in ("name", "harness", "model", "effort")]
    fields = [field.strip() for field in values[0].split(",") if field.strip()]
    if sorted(fields) != sorted(expected):
        return [
            f"Discussion record '{label}' is {values[0]!r} but the run configured "
            + ", ".join(expected)
        ]
    return []


def validate_dossier(
    path: str, expected: dict[str, str], config: dict[str, Any] | None = None
) -> list[str]:
    text = read_text(path)
    if not text.strip():
        return ["final dossier is empty"]

    lines, mask = structural(text)
    errors: list[str] = []
    if not heading_occurrences(lines, 1, "Final Solution Decision", mask):
        errors.append("missing required title '# Final Solution Decision'")
    errors += section_errors(text, 2, DOSSIER_SECTIONS)
    errors += empty_section_errors(text, 2, DOSSIER_SECTIONS)
    errors += placeholder_errors(text)

    # Provenance lives inside the Discussion record and nowhere else, so a
    # matching line quoted in an example elsewhere cannot satisfy the contract.
    record = extract_section(text, 2, DISCUSSION_RECORD_SECTION)

    for label, key in DOSSIER_RUN_LABELS:
        values = metadata_values(record, label)
        if not values:
            errors.append(f"Discussion record is missing the '{label}' line")
        elif len(values) > 1:
            errors.append(
                f"Discussion record has {len(values)} '{label}' lines; exactly one is required"
            )
        elif values[0] != expected[key]:
            errors.append(
                f"Discussion record '{label}' is {values[0]!r} but the run recorded "
                f"{expected[key]!r}"
            )

    if len(metadata_values(record, "Coordinator")) != 1:
        errors.append("Discussion record must carry exactly one 'Coordinator' line")

    agents = (config or {}).get("agents", {}) if isinstance(config, dict) else {}
    for slot in ("1", "2"):
        agent = agents.get(slot)
        if isinstance(agent, dict):
            errors += agent_identity_errors(record, slot, agent)
        elif len(metadata_values(record, f"Agent {slot}")) != 1:
            errors.append(
                f"Discussion record must carry exactly one 'Agent {slot}' line"
            )

    return errors


# ── Concurrent execution ───────────────────────────────────────────────────


TERMINATION_GRACE_SECONDS = 5

_LIVE_LOCK = threading.Lock()
_LIVE: dict[int, subprocess.Popen] = {}
_INTERRUPT_SIGNAL: list[int] = []


def host_id() -> str:
    return socket.gethostname()


def group_alive(pgid: int | None) -> bool:
    """True when a recorded process group still has members on this host."""
    if not pgid or pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The group exists but is owned elsewhere; refuse to assume it is gone.
        return True
    except OSError as error:
        return error.errno != errno.ESRCH
    return True


def kill_group(pgid: int | None, process: subprocess.Popen | None = None) -> None:
    """Terminate a whole process group, escalating SIGTERM to SIGKILL."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if process is not None and process.poll() is not None:
            return
        if process is None and not group_alive(pgid):
            return
        try:
            if pgid:
                os.killpg(pgid, sig)
            elif process is not None:
                process.send_signal(sig)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        if process is not None:
            try:
                process.wait(timeout=TERMINATION_GRACE_SECONDS)
                return
            except subprocess.TimeoutExpired:
                continue
        else:
            deadline = time.time() + TERMINATION_GRACE_SECONDS
            while time.time() < deadline:
                if not group_alive(pgid):
                    return
                time.sleep(0.1)


def _terminate_live() -> None:
    with _LIVE_LOCK:
        entries = list(_LIVE.items())
    for pgid, process in entries:
        kill_group(pgid, process)


def _handle_signal(signum: int, _frame: Any) -> None:
    """Never leave paid agent processes running after the supervisor dies."""
    if not _INTERRUPT_SIGNAL:
        _INTERRUPT_SIGNAL.append(signum)
    _terminate_live()


def run_job(job: dict[str, Any], timeout_seconds: int, results: dict[str, Any]) -> None:
    job_id = str(job["id"])
    argv = list(job["argv"])
    result_path = job.get("result")
    started = time.time()
    record: dict[str, Any] = {
        "id": job_id,
        "argv": argv,
        "started_at": utc_now(),
        "state": "starting",
        "host": host_id(),
        "supervisor_pid": os.getpid(),
        "pid": None,
        "pgid": None,
        "cwd": job.get("cwd") or "",
        "timeout_seconds": timeout_seconds,
        "deadline_epoch": int(started + timeout_seconds),
        "timed_out": False,
        "interrupted": False,
        "exit_code": None,
        "launch_error": "",
    }
    record.update(job.get("meta") or {})

    def persist() -> None:
        if result_path:
            write_json_atomic(result_path, record)

    stdout_path = job["stdout"]
    stderr_path = job["stderr"]
    for path in (stdout_path, stderr_path):
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)

    # The manifest exists before the child does, so an interrupted supervisor
    # always leaves a record that names the attempt it was about to own.
    persist()

    environment = dict(os.environ)
    for key, value in (job.get("env") or {}).items():
        environment[str(key)] = str(value)

    pgid: int | None = None
    process: subprocess.Popen | None = None
    try:
        with open(stdout_path, "wb") as out_handle, open(stderr_path, "wb") as err_handle:
            process = subprocess.Popen(  # noqa: S603 - argv list, never a command string
                argv,
                stdout=out_handle,
                stderr=err_handle,
                stdin=subprocess.DEVNULL,
                cwd=job.get("cwd") or None,
                env=environment,
                start_new_session=True,
            )
            # start_new_session makes the child its own group leader, so the
            # group id is the child pid even if the child exits immediately.
            pgid = process.pid
            record["pid"] = process.pid
            record["pgid"] = pgid
            record["state"] = "running"
            persist()
            with _LIVE_LOCK:
                _LIVE[pgid] = process

            try:
                record["exit_code"] = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                record["timed_out"] = True
                kill_group(pgid, process)
                record["exit_code"] = process.poll()
                if record["exit_code"] is None:
                    record["exit_code"] = -1
    except OSError as error:
        record["launch_error"] = str(error)
        record["exit_code"] = 127
    finally:
        if pgid is not None:
            with _LIVE_LOCK:
                _LIVE.pop(pgid, None)

    if _INTERRUPT_SIGNAL and not record["timed_out"]:
        record["interrupted"] = True
    record["state"] = "finished"
    record["ended_at"] = utc_now()
    persist()
    results[job_id] = record


def run_pair(spec_path: str) -> dict[str, Any]:
    spec = read_json(spec_path)
    timeout_seconds = int(spec.get("timeout_seconds", 3600))
    jobs = spec.get("jobs", [])
    if not jobs:
        raise HelperError("no jobs to run")

    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            previous[signum] = signal.signal(signum, _handle_signal)
        except (ValueError, OSError, AttributeError):
            pass

    results: dict[str, Any] = {}
    threads = [
        threading.Thread(target=run_job, args=(job, timeout_seconds, results), daemon=False)
        for job in jobs
    ]
    try:
        for thread in threads:
            thread.start()
        # Short joins keep the main thread responsive to signals so the
        # handler can terminate every live process group.
        while any(thread.is_alive() for thread in threads):
            for thread in threads:
                thread.join(timeout=0.2)
    except KeyboardInterrupt:
        _handle_signal(signal.SIGINT, None)
        for thread in threads:
            thread.join(timeout=TERMINATION_GRACE_SECONDS)
    finally:
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except (ValueError, OSError):
                pass

    if _INTERRUPT_SIGNAL:
        raise HelperError(
            f"interrupted by signal {_INTERRUPT_SIGNAL[0]}; every launched agent "
            "process group was terminated and its attempt manifest marked interrupted"
        )

    return {"jobs": [results[str(job["id"])] for job in jobs if str(job["id"]) in results]}


# ── Attempt liveness and recovery ──────────────────────────────────────────


def probe_attempt(result_path: str, grace_seconds: int) -> dict[str, Any]:
    """Report whether a previously launched attempt is still doing paid work."""
    if not os.path.exists(result_path):
        return {"state": "missing", "alive": False, "deadline_exceeded": False}

    try:
        record = read_json(result_path)
    except (json.JSONDecodeError, OSError):
        return {"state": "unreadable", "alive": False, "deadline_exceeded": False}

    state = str(record.get("state") or "finished")
    pgid = record.get("pgid")
    recorded_host = str(record.get("host") or "")
    same_host = not recorded_host or recorded_host == host_id()

    if state == "finished":
        alive = False
    elif not same_host:
        # A foreign host's pid means nothing here. Report it as live rather
        # than risk launching a second paid agent for the same attempt.
        alive = True
    else:
        alive = group_alive(pgid if isinstance(pgid, int) else None)

    deadline = record.get("deadline_epoch")
    exceeded = bool(
        alive and isinstance(deadline, int) and time.time() > deadline + grace_seconds
    )

    return {
        "state": state,
        "alive": alive,
        "deadline_exceeded": exceeded,
        "same_host": same_host,
        "host": recorded_host,
        "pgid": pgid if isinstance(pgid, int) else "",
        "pid": record.get("pid") or "",
        "exit_code": record.get("exit_code"),
        "timed_out": bool(record.get("timed_out")),
        "interrupted": bool(record.get("interrupted")),
    }


def reap_attempt(result_path: str, reason: str) -> dict[str, Any]:
    """Terminate an orphaned attempt group and close out its manifest."""
    if not os.path.exists(result_path):
        raise HelperError(f"no attempt manifest to reap: {result_path}")
    record = read_json(result_path)
    pgid = record.get("pgid")
    recorded_host = str(record.get("host") or "")
    if recorded_host and recorded_host != host_id():
        raise HelperError(
            f"attempt was launched on host {recorded_host!r}; it cannot be reaped from "
            f"{host_id()!r}. Recover it there, or delete the run directory deliberately."
        )
    if isinstance(pgid, int):
        kill_group(pgid)
    record["state"] = "finished"
    record["reaped_reason"] = reason
    record["reaped_at"] = utc_now()
    if reason == "timeout":
        record["timed_out"] = True
    else:
        record["interrupted"] = True
    if record.get("exit_code") is None:
        record["exit_code"] = -1
    write_json_atomic(result_path, record)
    return record


# ── Snapshot construction ──────────────────────────────────────────────────


def round_dir(run_dir: str, number: int) -> str:
    return os.path.join(run_dir, "rounds", f"round-{number:02d}")


CONSTRAINTS_HEADING = re.compile(
    r"^#{1,6}\s+.*(constraint|success criteri|acceptance criteri)", re.I
)

NO_CONSTRAINTS_BLOCK = (
    "As stated in the original problem above. No separate constraint or "
    "success-criteria block was supplied."
)


def split_task(task_text: str) -> tuple[str, str]:
    """Split the task into (problem, constraints).

    When the task carries its own constraints/success-criteria heading, that
    block moves into the snapshot's constraints section instead of being
    repeated under both headings. task.md on disk is never modified.
    """
    lines = normalize_lines(task_text)
    for index, line in enumerate(lines):
        if not CONSTRAINTS_HEADING.match(line.strip()):
            continue
        level = len(line) - len(line.lstrip("#"))
        end = len(lines)
        for offset, tail in enumerate(lines[index + 1 :], start=index + 1):
            stripped = tail.strip()
            if stripped.startswith("#"):
                tail_level = len(stripped) - len(stripped.lstrip("#"))
                if tail_level <= level:
                    end = offset
                    break
        constraints = "\n".join(lines[index + 1 : end]).strip("\n")
        problem = "\n".join(lines[:index] + lines[end:]).strip("\n")
        if constraints.strip() and problem.strip():
            return problem, constraints
    return task_text.strip("\n"), NO_CONSTRAINTS_BLOCK


def build_round_one_snapshot(run_dir: str) -> str:
    problem, constraints = split_task(read_text(os.path.join(run_dir, "task.md")))
    return "\n".join(
        [
            "# Original problem",
            "",
            problem,
            "",
            "# Constraints and success criteria",
            "",
            constraints,
            "",
            "# Coordinator focus for this round",
            "",
            "This is independent exploration. Develop your own candidate solutions from the "
            "problem alone. Propose at least two materially distinct credible solutions when "
            "the problem admits alternatives, and explain why alternatives are not viable when "
            "only one credible approach exists. There is no prior discussion, no shared ledger, "
            "and no preferred direction yet.",
            "",
        ]
    )


def build_next_snapshot(run_dir: str, target_round: int) -> str:
    previous = target_round - 1
    previous_dir = round_dir(run_dir, previous)
    decision_path = os.path.join(previous_dir, "coordinator-decision.md")
    if not os.path.exists(decision_path):
        raise HelperError(f"missing coordinator decision for round {previous}")

    decision = read_text(decision_path)
    problem, constraints = split_task(read_text(os.path.join(run_dir, "task.md")))

    def decided(title: str, fallback: str = "None") -> str:
        body = extract_section(decision, 1, title).strip("\n")
        return body if body.strip() else fallback

    agent_1 = read_text(os.path.join(previous_dir, "agent-1-output.md")).strip("\n")
    agent_2 = read_text(os.path.join(previous_dir, "agent-2-output.md")).strip("\n")

    return "\n".join(
        [
            "# Original problem",
            "",
            problem,
            "",
            "# Constraints and success criteria",
            "",
            constraints,
            "",
            "# Candidate-solution ledger",
            "",
            decided("Candidate-solution ledger"),
            "",
            "# Current synthesis or preferred direction",
            "",
            decided("Current synthesis or preferred direction", "Not selected"),
            "",
            "# Agreements",
            "",
            decided("Agreements"),
            "",
            "# Disagreements",
            "",
            decided("Disagreements"),
            "",
            "# Rejected candidates",
            "",
            decided("Rejected candidates"),
            "",
            "# Unresolved questions and risks",
            "",
            decided("Unresolved questions and risks"),
            "",
            "# Coordinator focus for this round",
            "",
            decided("Focus for next round"),
            "",
            "# Previous round: Agent 1",
            "",
            agent_1,
            "",
            "# Previous round: Agent 2",
            "",
            agent_2,
            "",
        ]
    )


# ── Run directory creation ─────────────────────────────────────────────────


def create_run_dir(run_root: str, timestamp: str) -> str:
    os.makedirs(run_root, exist_ok=True)
    for _ in range(64):
        suffix = binascii.hexlify(os.urandom(3)).decode("ascii")
        candidate = os.path.join(run_root, f"{timestamp}-{suffix}")
        try:
            os.mkdir(candidate)
        except FileExistsError:
            continue
        return os.path.abspath(candidate)
    raise HelperError(f"could not create a unique run directory under {run_root}")


# ── Template rendering ─────────────────────────────────────────────────────


def render_template(template_path: str, output_path: str, variables: list[str]) -> None:
    text = read_text(template_path)
    for pair in variables:
        if "=" not in pair:
            raise HelperError(f"--var expects NAME=value, got {pair!r}")
        name, value = pair.split("=", 1)
        text = text.replace("{{" + name + "}}", value)
    leftover = sorted(set(re.findall(r"\{\{[A-Za-z0-9_]+\}\}", text)))
    if leftover:
        raise HelperError(
            "unresolved template variables would be sent to the runner: "
            + ", ".join(leftover)
        )
    write_text_atomic(output_path, text)


# ── State access ───────────────────────────────────────────────────────────


def state_path(run_dir: str) -> str:
    return os.path.join(run_dir, "state.json")


def load_state(run_dir: str) -> dict[str, Any]:
    path = state_path(run_dir)
    if not os.path.exists(path):
        raise HelperError(f"not a pair-colleague run directory (no state.json): {run_dir}")
    return read_json(path)


def dotted_get(value: Any, key: str) -> Any:
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


# ── Command dispatch ───────────────────────────────────────────────────────


def cmd_create_run(args: argparse.Namespace) -> int:
    print(create_run_dir(args.run_root, args.timestamp))
    return 0


def cmd_state_init(args: argparse.Namespace) -> int:
    write_json_atomic(state_path(args.run_dir), read_patch(args.patch))
    return 0


def cmd_state_apply(args: argparse.Namespace) -> int:
    state = load_state(args.run_dir)
    patch = read_patch(args.patch)
    patch.setdefault("updated_at", utc_now())
    write_json_atomic(state_path(args.run_dir), deep_merge(state, patch))
    return 0


def cmd_state_get(args: argparse.Namespace) -> int:
    value = dotted_get(load_state(args.run_dir), args.key)
    if value is None:
        value = args.default
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print("" if value is None else value)
    return 0


def cmd_write_file(args: argparse.Namespace) -> int:
    write_bytes_atomic(args.path, sys.stdin.buffer.read())
    return 0


def cmd_sha256(args: argparse.Namespace) -> int:
    print(sha256_file(args.file))
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    render_template(args.template, args.output, args.var or [])
    return 0


def cmd_run_pair(args: argparse.Namespace) -> int:
    print(json.dumps(run_pair(args.spec)))
    return 0


def cmd_snapshot(args: argparse.Namespace) -> int:
    if args.round == 1:
        text = build_round_one_snapshot(args.run_dir)
    else:
        text = build_next_snapshot(args.run_dir, args.round)
    target_dir = round_dir(args.run_dir, args.round)
    os.makedirs(target_dir, exist_ok=True)
    snapshot = os.path.join(target_dir, "snapshot.md")
    payload = text.encode("utf-8")
    if os.path.exists(snapshot):
        # A retried transition must converge, not fail: an identical rebuild is
        # the same snapshot. A different one means the inputs changed underneath
        # the run and the coordinator has to resolve it.
        with open(snapshot, "rb") as handle:
            existing = handle.read()
        if existing != payload:
            raise HelperError(
                f"the round {args.round} snapshot already exists with different content: "
                f"{snapshot}. Its inputs changed after it was built; inspect the run "
                "directory instead of overwriting it."
            )
        digest = sha256_file(snapshot)
        write_text_atomic(os.path.join(target_dir, "snapshot.sha256"), digest + "\n")
        print(digest)
        return 0
    write_bytes_atomic(snapshot, payload)
    digest = sha256_file(snapshot)
    write_text_atomic(os.path.join(target_dir, "snapshot.sha256"), digest + "\n")
    print(digest)
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    """Fail loudly when a recorded artifact no longer matches its digest."""
    if not os.path.exists(args.file):
        raise HelperError(f"artifact recorded by this run is missing: {args.file}")
    actual = sha256_file(args.file)
    if actual != args.sha256:
        raise HelperError(
            f"artifact changed after the run recorded it: {args.file} "
            f"(recorded {args.sha256}, found {actual})"
        )
    print(actual)
    return 0


def cmd_probe_attempt(args: argparse.Namespace) -> int:
    info = probe_attempt(args.result, args.grace)
    for key in (
        "state",
        "alive",
        "deadline_exceeded",
        "same_host",
        "host",
        "pgid",
        "pid",
        "exit_code",
        "timed_out",
        "interrupted",
    ):
        value = info.get(key, "")
        if isinstance(value, bool):
            value = "true" if value else "false"
        print(f"{key.upper()}={'' if value is None else value}")
    return 0


def cmd_reap_attempt(args: argparse.Namespace) -> int:
    record = reap_attempt(args.result, args.reason)
    print(record.get("pgid") or "")
    return 0


def cmd_identical(args: argparse.Namespace) -> int:
    """Exit 0 when two files are byte-identical, 1 otherwise."""
    if not os.path.exists(args.left) or not os.path.exists(args.right):
        return 1
    return 0 if sha256_file(args.left) == sha256_file(args.right) else 1


def cmd_validate(args: argparse.Namespace) -> int:
    if args.kind == "agent-output":
        errors = validate_agent_output(args.file)
    elif args.kind == "coordinator-decision":
        errors = validate_decision(args.file)
    else:
        config = None
        if args.config and os.path.exists(args.config):
            config = read_json(args.config)
        errors = validate_dossier(
            args.file,
            {
                "completed_rounds": args.expect_completed_rounds or "",
                "min_rounds": args.expect_min_rounds or "",
                "max_rounds": args.expect_max_rounds or "",
                "completion_reason": args.expect_completion_reason or "",
                "run_dir": args.expect_run_dir or "",
            },
            config,
        )
    if errors:
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    return 0


def cmd_action(args: argparse.Namespace) -> int:
    """Print the trailing contract value of a validated document."""
    lines = normalize_lines(read_text(args.file))
    value, errors = trailing_status(lines, args.key)
    if errors:
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(value)
    return 0


def cmd_normalize_agent(args: argparse.Namespace) -> int:
    registry = read_json(args.registry)
    aliases = registry.get("aliases", {}) if isinstance(registry, dict) else {}
    print(aliases.get(args.agent, args.agent))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("create-run")
    p.add_argument("--run-root", required=True)
    p.add_argument("--timestamp", required=True)
    p.set_defaults(func=cmd_create_run)

    p = sub.add_parser("state-init")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--patch", required=True)
    p.set_defaults(func=cmd_state_init)

    p = sub.add_parser("state-apply")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--patch", required=True)
    p.set_defaults(func=cmd_state_apply)

    p = sub.add_parser("state-get")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--default", default="")
    p.set_defaults(func=cmd_state_get)

    p = sub.add_parser("write-file")
    p.add_argument("--path", required=True)
    p.set_defaults(func=cmd_write_file)

    p = sub.add_parser("sha256")
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_sha256)

    p = sub.add_parser("render")
    p.add_argument("--template", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--var", action="append")
    p.set_defaults(func=cmd_render)

    p = sub.add_parser("run-pair")
    p.add_argument("--spec", required=True)
    p.set_defaults(func=cmd_run_pair)

    p = sub.add_parser("snapshot")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--round", type=int, required=True)
    p.set_defaults(func=cmd_snapshot)

    p = sub.add_parser("validate")
    p.add_argument("--kind", required=True,
                   choices=["agent-output", "coordinator-decision", "final-dossier"])
    p.add_argument("--file", required=True)
    p.add_argument("--expect-completed-rounds")
    p.add_argument("--expect-min-rounds")
    p.add_argument("--expect-max-rounds")
    p.add_argument("--expect-completion-reason")
    p.add_argument("--expect-run-dir")
    p.add_argument("--config")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("verify")
    p.add_argument("--file", required=True)
    p.add_argument("--sha256", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("probe-attempt")
    p.add_argument("--result", required=True)
    p.add_argument("--grace", type=int, default=60)
    p.set_defaults(func=cmd_probe_attempt)

    p = sub.add_parser("reap-attempt")
    p.add_argument("--result", required=True)
    p.add_argument("--reason", default="reaped", choices=["reaped", "timeout"])
    p.set_defaults(func=cmd_reap_attempt)

    p = sub.add_parser("identical")
    p.add_argument("--left", required=True)
    p.add_argument("--right", required=True)
    p.set_defaults(func=cmd_identical)

    p = sub.add_parser("action")
    p.add_argument("--file", required=True)
    p.add_argument("--key", required=True)
    p.set_defaults(func=cmd_action)

    p = sub.add_parser("normalize-agent")
    p.add_argument("--registry", required=True)
    p.add_argument("--agent", required=True)
    p.set_defaults(func=cmd_normalize_agent)

    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except HelperError as error:
        print(f"pair-colleague-process.py: {error}", file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as error:
        print(f"pair-colleague-process.py: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # noqa: BLE001 - an unexpected fault is still an error exit
        # The control plane distinguishes "the command failed" from "the agent
        # failed" by exit code, so an unexpected exception must never surface
        # as an uncaught traceback with a different status.
        print(
            f"pair-colleague-process.py: internal error: {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

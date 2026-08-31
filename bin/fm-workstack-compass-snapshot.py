#!/usr/bin/env python3
"""Produce one private, read-only Workstack Compass upstream snapshot.

The executable model at the operator-supplied Workstack Compass root is the
sole owner of ``workstack-compass.snapshot.v1``.  This producer loads that
model, projects only exact identities exposed by Firstmate and explicitly
bound read-only project roots, asks the model to validate the complete
projection, and then atomically replaces one mode-0600 private file.

Mechanics and safety boundaries:

* ``FM_HOME`` selects the only Firstmate home read by this process.  When it is
  unset, the tracked code root containing this script is the active home.
* ``--project-root NAME=PATH`` is an explicit identity binding.  NAME must be
  present in that home's existing project registry; paths and repository
  resemblance are never used as joins.
* The default output is ``$FM_HOME/data/workstack-compass/snapshot.json``.
  A custom output must use an owner-private subdirectory below
  ``$FM_HOME/data``.  Symlinks, special
  files, hard-linked destinations, unsafe parents, source changes, malformed
  or oversized inputs, and oversized model output are refused.
* The command is local-only and network-free.  It never retains or emits
  transcripts or status prose, launches or controls a worker, changes a source,
  acknowledges an event, opens a connection, launches Workstack Compass, or
  publishes data.
* Firstmate project identity, bounded tasks-axi backlog identity, and task
  incarnation metadata are projected.  Missing typed producers leave plans,
  stages, work units, commands, lifecycle evidence, worker telemetry, and
  retained decisions unavailable rather than inferred.

Usage:
  FM_HOME=/path/to/firstmate bin/fm-workstack-compass-snapshot.py \
    --workstack-root /path/to/workstack-compass \
    --project-root data-team-management=/read/only/data-team-management \
    --project-root gl-data-team-tickets=/read/only/gl-data-team-tickets

On success the command prints the private snapshot path and the exact local
Workstack Compass launch command.  It never prints snapshot contents.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import threading
import types
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

sys.dont_write_bytecode = True

MAX_REGISTRY_BYTES = 128 * 1024
MAX_BACKLOG_BYTES = 512 * 1024
MAX_META_BYTES = 64 * 1024
MAX_META_TOTAL_BYTES = 2 * 1024 * 1024
MAX_META_RECORDS = 10_000
MAX_REGISTERED_PROJECTS = 1_000
MAX_PROJECT_SOURCE_BYTES = 512 * 1024
MAX_MODEL_BYTES = 512 * 1024
MAX_READER_OUTPUT_BYTES = 2 * 1024 * 1024
MAX_TASK_RECORDS = 10_000
TASKS_AXI_TIMEOUT_SECONDS = 10
IDENTITY_RE = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
REGISTRY_LINE_RE = re.compile(
    r"^- ([A-Za-z0-9._-]{1,160})(?: \[[^\]\r\n]+\])? - \S.*$"
)
META_KEY_RE = re.compile(r"^[a-z_][a-z0-9_]*$")
BUSY_GEN_RE = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
DTM_NODE_RE = re.compile(r"^[A-Za-z0-9_-]{1,180}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


class ProducerError(RuntimeError):
    """A bounded operator-facing refusal with no source bytes or private path."""


class SourceChanged(ProducerError):
    """One observed source changed before the observation completed."""


@dataclass(frozen=True)
class Fingerprint:
    device: int
    inode: int
    mode_type: int
    size: int
    mtime_ns: int
    ctime_ns: int
    links: int


@dataclass(frozen=True)
class BacklogTask:
    identity: str
    state: str
    kind: str | None
    project_name: str | None


@dataclass(frozen=True)
class ProjectBinding:
    name: str
    root: Path


class Observation:
    """Capture bounded source bytes and prove every capture stayed unchanged."""

    def __init__(self) -> None:
        self._observed: dict[Path, Fingerprint] = {}
        self._absent: set[Path] = set()
        self._inventories: dict[tuple[Path, str], tuple[str, ...]] = {}

    @staticmethod
    def _fingerprint(info: os.stat_result) -> Fingerprint:
        return Fingerprint(
            info.st_dev,
            info.st_ino,
            stat.S_IFMT(info.st_mode),
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
            info.st_nlink,
        )

    def observe_directory(self, path: Path) -> Path:
        reject_control_path(path)
        try:
            before = os.stat(path, follow_symlinks=False)
        except OSError as exc:
            raise ProducerError("required source directory is unavailable") from exc
        if not stat.S_ISDIR(before.st_mode):
            raise ProducerError("required source directory is not an ordinary directory")
        resolved = resolve_existing_directory(path)
        self._remember(resolved, self._fingerprint(before))
        return resolved

    def observe_inventory(self, directory: Path, pattern: str) -> list[Path]:
        root = resolve_existing_directory(directory)
        paths = sorted(root.glob(pattern), key=lambda item: item.name)
        names = tuple(path.name for path in paths)
        self._inventories[(root, pattern)] = names
        return paths

    def read_file(self, path: Path, cap: int, *, missing_ok: bool = False) -> bytes | None:
        reject_control_path(path)
        try:
            before = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            if missing_ok:
                self._absent.add(path)
                return None
            raise ProducerError("required source file is unavailable")
        except OSError as exc:
            raise ProducerError("required source file is unavailable") from exc
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ProducerError("source input is not a single ordinary file")
        if before.st_size > cap:
            raise ProducerError("source input exceeds its bounded size")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError as exc:
            raise ProducerError("source input could not be opened safely") from exc
        try:
            opened = os.fstat(descriptor)
            if self._fingerprint(opened) != self._fingerprint(before):
                raise SourceChanged("source changed during observation")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(64 * 1024, cap + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > cap:
                    raise ProducerError("source input exceeds its bounded size")
            after = os.fstat(descriptor)
            if self._fingerprint(after) != self._fingerprint(opened):
                raise SourceChanged("source changed during observation")
        finally:
            os.close(descriptor)
        resolved = path.resolve(strict=True)
        self._remember(resolved, self._fingerprint(after))
        return b"".join(chunks)

    def read_under(self, path: Path, root: Path, cap: int) -> bytes:
        try:
            relative = path.relative_to(root)
        except ValueError as exc:
            raise ProducerError("source path escapes its approved root") from exc
        current = root
        for part in relative.parts:
            current = current / part
            try:
                info = os.stat(current, follow_symlinks=False)
            except OSError as exc:
                raise ProducerError("required source path is unavailable") from exc
            if stat.S_ISLNK(info.st_mode):
                raise ProducerError("source path contains a symlink")
        try:
            path.resolve(strict=True).relative_to(root.resolve(strict=True))
        except (OSError, RuntimeError, ValueError) as exc:
            raise ProducerError("source path escapes its approved root") from exc
        payload = self.read_file(path, cap)
        assert payload is not None
        return payload

    def _remember(self, path: Path, fingerprint: Fingerprint) -> None:
        if path in self._absent:
            raise SourceChanged("source changed during observation")
        prior = self._observed.get(path)
        if prior is not None and prior != fingerprint:
            raise SourceChanged("source changed during observation")
        self._observed[path] = fingerprint

    def prove_unchanged(self) -> None:
        for path in self._absent:
            try:
                os.stat(path, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            raise SourceChanged("source changed during observation")
        for path, expected in self._observed.items():
            try:
                current = os.stat(path, follow_symlinks=False)
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            if self._fingerprint(current) != expected:
                raise SourceChanged("source changed during observation")
        for (directory, pattern), expected in self._inventories.items():
            current = tuple(
                path.name
                for path in sorted(directory.glob(pattern), key=lambda item: item.name)
            )
            if current != expected:
                raise SourceChanged("source inventory changed during observation")


def reject_control_path(path: Path) -> None:
    if CONTROL_RE.search(os.fspath(path)):
        raise ProducerError("a supplied path contains a control character")


def resolve_existing_directory(path: Path) -> Path:
    reject_control_path(path)
    try:
        unresolved = os.stat(path, follow_symlinks=False)
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ProducerError("required directory is unavailable") from exc
    if not stat.S_ISDIR(unresolved.st_mode) or path.is_symlink() or not resolved.is_dir():
        raise ProducerError("required directory is unsafe")
    return resolved


def decode_utf8(payload: bytes, label: str) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProducerError(f"{label} is not valid UTF-8") from exc


def load_json(payload: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(decode_utf8(payload, label))
    except json.JSONDecodeError as exc:
        raise ProducerError(f"{label} is malformed JSON") from exc
    if not isinstance(value, Mapping):
        raise ProducerError(f"{label} must contain one JSON object")
    return value


def active_home(script_root: Path) -> Path:
    configured = os.environ.get("FM_HOME")
    candidate = Path(configured).expanduser() if configured else script_root
    home = resolve_existing_directory(candidate)
    for child in ("data", "state"):
        path = home / child
        try:
            info = os.stat(path, follow_symlinks=False)
        except OSError as exc:
            raise ProducerError("active Firstmate home is incomplete") from exc
        if not stat.S_ISDIR(info.st_mode) or path.is_symlink():
            raise ProducerError("active Firstmate home is unsafe")
    return home


def parse_registry(payload: bytes | None) -> list[str]:
    if payload is None:
        return []
    text = decode_utf8(payload, "project registry")
    names: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        if not line.startswith("- "):
            continue
        match = REGISTRY_LINE_RE.fullmatch(line)
        if match is None:
            raise ProducerError("project registry contains a malformed record")
        name = match.group(1)
        if name in seen:
            raise ProducerError("project registry contains a duplicate exact identity")
        seen.add(name)
        names.append(name)
        if len(names) > MAX_REGISTERED_PROJECTS:
            raise ProducerError("project registry exceeds its record bound")
    return names


def parse_project_root(argument: str) -> tuple[str, Path]:
    if "=" not in argument:
        raise ProducerError("--project-root must use NAME=PATH")
    name, raw_path = argument.split("=", 1)
    if not IDENTITY_RE.fullmatch(name) or not raw_path:
        raise ProducerError("--project-root contains an invalid exact identity")
    return name, Path(raw_path).expanduser()


def validate_git_marker(root: Path) -> None:
    marker = root / ".git"
    try:
        info = os.stat(marker, follow_symlinks=False)
    except OSError as exc:
        raise ProducerError("explicit project root is not a repository") from exc
    if marker.is_symlink() or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
        raise ProducerError("explicit project repository marker is unsafe")


def bind_project_roots(
    values: Sequence[str], registered: set[str], observation: Observation
) -> dict[str, ProjectBinding]:
    bindings: dict[str, ProjectBinding] = {}
    roots_seen: set[Path] = set()
    for value in values:
        name, requested = parse_project_root(value)
        if name not in registered:
            raise ProducerError("explicit project root is not present in the Firstmate registry")
        if name in bindings:
            raise ProducerError("duplicate explicit project-root identity")
        root = observation.observe_directory(requested)
        validate_git_marker(root)
        if root in roots_seen:
            raise ProducerError("one project root cannot represent multiple exact project identities")
        roots_seen.add(root)
        bindings[name] = ProjectBinding(name, root)
    return bindings


def prepare_output(home: Path, requested: str | None) -> tuple[Path, int]:
    data_root = resolve_existing_directory(home / "data")
    default_parent = data_root / "workstack-compass"
    if requested is None:
        if not default_parent.exists():
            try:
                os.mkdir(default_parent, 0o700)
                os.chmod(default_parent, 0o700, follow_symlinks=False)
            except OSError as exc:
                raise ProducerError("private snapshot directory could not be created") from exc
        output = default_parent / "snapshot.json"
    else:
        output = Path(requested).expanduser()
        reject_control_path(output)
        if not output.is_absolute():
            output = Path.cwd() / output
    try:
        parent = output.parent.resolve(strict=True)
        canonical_data = data_root.resolve(strict=True)
        parent.relative_to(canonical_data)
    except (OSError, RuntimeError, ValueError) as exc:
        raise ProducerError("snapshot output must stay below the active FM_HOME data directory") from exc
    parent_info = os.stat(parent, follow_symlinks=False)
    if parent == canonical_data:
        raise ProducerError("snapshot output requires a private subdirectory below FM_HOME data")
    if not stat.S_ISDIR(parent_info.st_mode) or output.parent.is_symlink():
        raise ProducerError("snapshot output parent is unsafe")
    current = canonical_data
    for part in parent.relative_to(canonical_data).parts:
        current = current / part
        component = os.stat(current, follow_symlinks=False)
        if stat.S_ISLNK(component.st_mode) or not stat.S_ISDIR(component.st_mode):
            raise ProducerError("snapshot output parent contains an unsafe component")
    if parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) & 0o077:
        raise ProducerError("snapshot output parent has unsafe ownership or permissions")
    output = parent / output.name
    reject_control_path(output)
    existing: os.stat_result | None
    try:
        existing = os.stat(output, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    except OSError as exc:
        raise ProducerError("snapshot destination could not be inspected safely") from exc
    if existing is not None:
        if (
            not stat.S_ISREG(existing.st_mode)
            or existing.st_nlink != 1
            or stat.S_IMODE(existing.st_mode) != 0o600
        ):
            raise ProducerError("snapshot destination is not one private ordinary file")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_descriptor = os.open(parent, flags)
    except OSError as exc:
        raise ProducerError("snapshot output parent could not be opened safely") from exc
    return output, parent_descriptor


def write_private_temp(parent_descriptor: int, prefix: str, payload: bytes) -> str:
    for _ in range(64):
        name = f".{prefix}.{os.getpid()}.{os.urandom(8).hex()}"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=parent_descriptor)
        except FileExistsError:
            continue
        except OSError as exc:
            raise ProducerError("private temporary file could not be created") from exc
        try:
            os.fchmod(descriptor, 0o600)
            view = memoryview(payload)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise ProducerError("private temporary file write was incomplete")
                view = view[written:]
            os.fsync(descriptor)
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size != len(payload)
            ):
                raise ProducerError("private temporary file failed its safety check")
        except Exception:
            try:
                os.unlink(name, dir_fd=parent_descriptor)
            except OSError:
                pass
            raise
        finally:
            os.close(descriptor)
        return name
    raise ProducerError("private temporary file name allocation failed")


def run_bounded(
    argv: Sequence[str],
    env: Mapping[str, str],
    *,
    timeout: int = TASKS_AXI_TIMEOUT_SECONDS,
    cap: int = MAX_READER_OUTPUT_BYTES,
) -> bytes:
    try:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=dict(env),
            shell=False,
            start_new_session=True,
        )
    except OSError as exc:
        raise ProducerError("authoritative local reader could not be started") from exc
    chunks: list[bytes] = []
    total = 0
    oversized = False

    def kill_reader() -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                process.kill()
            except OSError:
                pass

    def drain() -> None:
        nonlocal total, oversized
        assert process.stdout is not None
        while True:
            chunk = process.stdout.read(64 * 1024)
            if not chunk:
                return
            room = cap + 1 - total
            if room > 0:
                kept = chunk[:room]
                chunks.append(kept)
                total += len(kept)
            if len(chunk) > max(room, 0) or total > cap:
                oversized = True
                kill_reader()
                return

    reader = threading.Thread(target=drain, name="workstack-source-reader", daemon=True)
    reader.start()
    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        kill_reader()
        process.wait()
        reader.join(timeout=1)
        raise ProducerError("authoritative local reader exceeded its time bound") from exc
    reader.join(timeout=1)
    if process.stdout is not None:
        process.stdout.close()
    if reader.is_alive():
        kill_reader()
        raise ProducerError("authoritative local reader did not close its output")
    if oversized:
        raise ProducerError("authoritative local reader exceeded its output bound")
    if return_code != 0:
        raise ProducerError("authoritative local reader rejected the captured source")
    return b"".join(chunks)


def parse_tasks_axi(payload: bytes) -> list[BacklogTask]:
    text = decode_utf8(payload, "tasks-axi output")
    lines = text.splitlines()
    if len(lines) < 2:
        raise ProducerError("authoritative local reader returned malformed output")
    count_match = re.fullmatch(r"count: (\d+)(?: of (\d+) total)?", lines[0])
    header_match = re.fullmatch(r"tasks\[(\d+)\]\{([^}]+)\}:", lines[1])
    if count_match is None or header_match is None:
        raise ProducerError("authoritative local reader returned malformed output")
    shown = int(count_match.group(1))
    total = int(count_match.group(2) or shown)
    declared = int(header_match.group(1))
    if shown != total or shown != declared or shown > MAX_TASK_RECORDS:
        raise ProducerError("authoritative local reader returned incomplete output")
    fields = header_match.group(2).split(",")
    expected = ["id", "state", "kind", "repo", "title"]
    if fields != expected:
        raise ProducerError("authoritative local reader contract is unsupported")
    rows: list[BacklogTask] = []
    seen: set[str] = set()
    for line in lines[2:]:
        if line.startswith("help["):
            break
        if not line.strip():
            continue
        if not line.startswith("  "):
            raise ProducerError("authoritative local reader returned malformed output")
        try:
            values = next(csv.reader([line[2:]], strict=True))
        except (csv.Error, StopIteration) as exc:
            raise ProducerError("authoritative local reader returned malformed output") from exc
        if len(values) != len(fields):
            raise ProducerError("authoritative local reader returned malformed output")
        record = dict(zip(fields, values))
        identity = record["id"]
        if not IDENTITY_RE.fullmatch(identity):
            raise ProducerError("backlog contains a broken exact identity")
        if identity in seen:
            raise ProducerError("backlog contains a duplicate exact identity")
        seen.add(identity)
        state = record["state"]
        if state not in {"queued", "in_flight", "done", "held"}:
            raise ProducerError("backlog reader returned an unsupported task state")
        kind = None if record["kind"] in {"", "-", "none"} else record["kind"]
        project_name = None if record["repo"] in {"", "-", "none"} else record["repo"]
        if kind is not None and not IDENTITY_RE.fullmatch(kind):
            raise ProducerError("backlog contains a broken kind identity")
        if project_name is not None and not IDENTITY_RE.fullmatch(project_name):
            raise ProducerError("backlog contains a broken project relation")
        rows.append(BacklogTask(identity, state, kind, project_name))
    if len(rows) != shown:
        raise ProducerError("authoritative local reader returned incomplete output")
    return rows


def read_backlog_tasks(
    payload: bytes | None, parent_descriptor: int, output_parent: Path
) -> list[BacklogTask]:
    if payload is None:
        return []
    temp_name = write_private_temp(parent_descriptor, "workstack-backlog", payload)
    temp_path = output_parent / temp_name
    path = os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin")
    environment = {
        "PATH": path,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "NO_COLOR": "1",
        "HOME": os.fspath(output_parent),
    }
    try:
        output = run_bounded(
            (
                "tasks-axi",
                "list",
                "--file",
                os.fspath(temp_path),
                "--limit",
                str(MAX_TASK_RECORDS),
            ),
            environment,
        )
        return parse_tasks_axi(output)
    finally:
        try:
            os.unlink(temp_name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise ProducerError("private captured-source cleanup failed") from exc


def parse_meta(payload: bytes) -> dict[str, str]:
    text = decode_utf8(payload, "task metadata")
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        if "=" not in line:
            raise ProducerError("task metadata contains a malformed record")
        key, value = line.split("=", 1)
        if not META_KEY_RE.fullmatch(key):
            raise ProducerError("task metadata contains a broken field identity")
        if CONTROL_RE.search(value):
            raise ProducerError("task metadata contains a forbidden control value")
        # bin/fm-backend.sh's fm_meta_get contract makes the last value
        # authoritative because task producers append some later fields.
        result[key] = value
    return result


def project_identity(name: str) -> str:
    return f"firstmate-project:{name}"


def collect_workers(
    home: Path,
    observation: Observation,
    backlog_tasks: Iterable[BacklogTask],
    registered: set[str],
) -> tuple[list[dict[str, Any]], bool, int]:
    paths = observation.observe_inventory(home / "state", "*.meta")
    if len(paths) > MAX_META_RECORDS:
        raise ProducerError("task metadata inventory exceeds its record bound")
    tasks = {record.identity: record for record in backlog_tasks}
    workers: list[dict[str, Any]] = []
    total_bytes = 0
    omitted = 0
    for path in paths:
        identity = path.name[:-5]
        if not IDENTITY_RE.fullmatch(identity):
            raise ProducerError("task metadata filename contains a broken exact identity")
        payload = observation.read_file(path, MAX_META_BYTES)
        assert payload is not None
        total_bytes += len(payload)
        if total_bytes > MAX_META_TOTAL_BYTES:
            raise ProducerError("task metadata inventory exceeds its total byte bound")
        meta = parse_meta(payload)
        generation = meta.get("busy_gen")
        if generation is None:
            omitted += 1
            continue
        if not BUSY_GEN_RE.fullmatch(generation):
            raise ProducerError("task metadata contains a broken incarnation identity")
        kind = meta.get("kind", "ship")
        roles = {
            "ship": "Ship worker",
            "scout": "Scout",
            "secondmate": "Second mate",
        }
        if kind not in roles:
            raise ProducerError("task metadata contains an unsupported worker role")
        task = tasks.get(identity)
        related_project: str | None = None
        if task is not None and task.project_name in registered:
            assert task.project_name is not None
            related_project = project_identity(task.project_name)
        row = {
            "worker_incarnation_identity": f"firstmate-worker-incarnation:{identity}:{generation}",
            "worker_identity": f"firstmate-worker:{identity}",
            "role": roles[kind],
            "status": "unavailable",
            "liveness": "unavailable",
            "live_proof_identity": None,
            "project_identity": related_project,
            "work_unit_identities": [],
            "context_percent": None,
            "duration_seconds": None,
            "source_identity": "source:firstmate-task-identities",
        }
        workers.append(row)
        omitted += 1
    workers.sort(key=lambda row: row["worker_incarnation_identity"])
    return workers, bool(paths), omitted


def inspect_project_sources(
    registered: Sequence[str],
    bindings: Mapping[str, ProjectBinding],
    observation: Observation,
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    sources: list[dict[str, Any]] = []
    project_sources: dict[str, str] = {}
    for name in sorted(registered):
        binding = bindings.get(name)
        if binding is None:
            identity = f"source:project-root:{name}"
            sources.append(
                {
                    "source_identity": identity,
                    "label": f"{name} local upstream",
                    "completeness": "unavailable",
                    "detail": "No explicit read-only root was supplied for this registered project.",
                }
            )
            project_sources[name] = "source:firstmate-project-registry"
            continue
        if name == "data-team-management":
            payload = observation.read_under(
                binding.root / "config" / "board.json",
                binding.root,
                MAX_PROJECT_SOURCE_BYTES,
            )
            board = load_json(payload, "Data Team Management board contract")
            project = board.get("project")
            node_identity = project.get("id") if isinstance(project, Mapping) else None
            number = project.get("number") if isinstance(project, Mapping) else None
            repository = board.get("issue_repo")
            if (
                not isinstance(node_identity, str)
                or not DTM_NODE_RE.fullmatch(node_identity)
                or isinstance(number, bool)
                or not isinstance(number, int)
                or number < 1
                or not isinstance(repository, str)
                or not REPOSITORY_RE.fullmatch(repository)
            ):
                raise ProducerError("Data Team Management board contract is malformed")
            identity = f"source:data-team-management-board:{node_identity}"
            sources.append(
                {
                    "source_identity": identity,
                    "label": "Data Team Management board identity",
                    "completeness": "partial",
                    "detail": "The local board identity contract is available; current board rows and typed execution relations are not exported locally.",
                }
            )
            project_sources[name] = identity
        elif name == "gl-data-team-tickets":
            payload = observation.read_under(
                binding.root / "README.md", binding.root, MAX_PROJECT_SOURCE_BYTES
            )
            if not decode_utf8(payload, "Data Team Tickets repository contract").strip():
                raise ProducerError("Data Team Tickets repository contract is malformed")
            identity = "source:gl-data-team-tickets-artifacts"
            sources.append(
                {
                    "source_identity": identity,
                    "label": "Data Team Tickets artifact repository",
                    "completeness": "partial",
                    "detail": "The explicit artifact repository is available; it publishes no typed plan, stage, work-unit, delivery, or acceptance relation for this snapshot.",
                }
            )
            project_sources[name] = identity
        else:
            identity = f"source:project-root:{name}"
            sources.append(
                {
                    "source_identity": identity,
                    "label": f"{name} explicit project root",
                    "completeness": "partial",
                    "detail": "The registered read-only root is available; no typed Workstack relation producer is published there.",
                }
            )
            project_sources[name] = identity
    return sources, project_sources


def load_workstack_model(root: Path, observation: Observation) -> tuple[types.ModuleType, Path]:
    workstack = observation.observe_directory(root)
    validate_git_marker(workstack)
    model_path = workstack / "src" / "workstack_compass" / "model.py"
    launcher = workstack / "bin" / "workstack-compass"
    model_payload = observation.read_under(model_path, workstack, MAX_MODEL_BYTES)
    launcher_payload = observation.read_under(launcher, workstack, MAX_MODEL_BYTES)
    if not launcher_payload.startswith(b"#!"):
        raise ProducerError("Workstack Compass launcher is malformed")
    source = decode_utf8(model_payload, "Workstack Compass executable model")
    module_name = f"_fm_workstack_model_{os.getpid()}_{id(source)}"
    module = types.ModuleType(module_name)
    module.__file__ = "<workstack-compass-model>"
    sys.modules[module_name] = module
    try:
        code = compile(source, module.__file__, "exec")
        exec(code, module.__dict__)
    except Exception as exc:
        raise ProducerError("Workstack Compass executable model could not be loaded") from exc
    finally:
        sys.modules.pop(module_name, None)
    if (
        not isinstance(getattr(module, "SCHEMA_VERSION", None), str)
        or not callable(getattr(module, "snapshot_from_mapping", None))
        or not isinstance(getattr(module, "MAX_SNAPSHOT_BYTES", None), int)
        or module.MAX_SNAPSHOT_BYTES < 1
    ):
        raise ProducerError("Workstack Compass executable model contract is unsupported")
    return module, workstack


def validate_document(model: types.ModuleType, document: Mapping[str, Any]) -> None:
    try:
        snapshot = model.snapshot_from_mapping(document)
        issues = snapshot.integrity_issues()
    except Exception as exc:
        raise ProducerError("Workstack Compass executable model rejected the snapshot") from exc
    if not isinstance(issues, tuple) or issues:
        raise ProducerError("Workstack Compass executable model reported broken exact relations")


def unique_identities(records: Iterable[Mapping[str, Any]], field: str, label: str) -> None:
    values = [record[field] for record in records]
    if len(values) != len(set(values)):
        raise ProducerError(f"projection contains duplicate {label} exact identities")


def build_document(
    model: types.ModuleType,
    registered: Sequence[str],
    workers: list[dict[str, Any]],
    registry_present: bool,
    backlog_present: bool,
    meta_present: bool,
    omitted_task_evidence: int,
    project_sources: list[dict[str, Any]],
    project_source_by_name: Mapping[str, str],
) -> dict[str, Any]:
    registry_source = {
        "source_identity": "source:firstmate-project-registry",
        "label": "Firstmate registered projects",
        "completeness": "complete" if registry_present else "unavailable",
        "detail": (
            "The active Firstmate project registry was observed without inferred project joins."
            if registry_present
            else "The active Firstmate project registry is unavailable."
        ),
    }
    if backlog_present and meta_present:
        task_completeness = "partial" if omitted_task_evidence else "complete"
        task_detail = (
            "Exact task and worker-incarnation identities were observed; worker current state is unavailable, records without exact incarnation identity are omitted, and untyped telemetry remains unavailable."
            if omitted_task_evidence
            else "Exact task and worker-incarnation identities were observed; no worker current-state evidence was available, and untyped telemetry remains unavailable."
        )
    elif backlog_present or meta_present:
        task_completeness = "partial"
        task_detail = "Only part of the exact task identity evidence is available; worker telemetry and untyped relations remain unavailable."
    else:
        task_completeness = "unavailable"
        task_detail = "No local task identity evidence is available."
    task_source = {
        "source_identity": "source:firstmate-task-identities",
        "label": "Firstmate task identity records",
        "completeness": task_completeness,
        "detail": task_detail,
    }
    sources = [registry_source, task_source, *project_sources]
    sources.sort(key=lambda row: row["source_identity"])
    unique_identities(sources, "source_identity", "source")

    projects = [
        {
            "project_identity": project_identity(name),
            "source_identity": project_source_by_name.get(
                name, "source:firstmate-project-registry"
            ),
            "label": name,
            "outcome": None,
        }
        for name in sorted(registered)
    ]

    exact_status = "partial" if projects else "unavailable"
    exact_detail = (
        "Registered project identities are available; typed plan, stage, work-unit, command, next-action, delivery, and acceptance producers are unavailable."
        if projects
        else "Exact project and work hierarchy identities are unavailable."
    )
    worker_status = "partial" if workers else "unavailable"
    if workers:
        worker_detail = "Exact worker incarnations are available; current status, liveness, context, duration, and typed work-unit relations are unavailable."
    else:
        worker_detail = "No exact worker incarnation with an authoritative generation identity is available."
    interfaces = [
        {
            "name": "exact-work-identity",
            "status": exact_status,
            "source_identity": "source:firstmate-project-registry" if projects else None,
            "detail": exact_detail,
        },
        {
            "name": "worker-context-duration",
            "status": worker_status,
            "source_identity": "source:firstmate-task-identities" if workers else None,
            "detail": worker_detail,
        },
        {
            "name": "decision-history",
            "status": "unavailable",
            "source_identity": None,
            "detail": "No authoritative retained-decision exporter is available.",
        },
    ]
    interfaces.sort(key=lambda row: row["name"])

    observed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    document: dict[str, Any] = {
        "schema_version": model.SCHEMA_VERSION,
        "observation_identity": "observation:pending",
        "observed_at": observed_at,
        "data_classification": "authoritative" if projects or workers else "unavailable",
        "sources": sources,
        "interfaces": interfaces,
        "projects": projects,
        "plans": [],
        "stages": [],
        "work_units": [],
        "commands": [],
        "worker_incarnations": workers,
        "next_actions": [],
        "deliveries": [],
        "acceptances": [],
        "decisions": [],
    }
    digest_input = dict(document)
    digest_input.pop("observation_identity")
    canonical = json.dumps(
        digest_input, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    document["observation_identity"] = (
        "observation:sha256:" + hashlib.sha256(canonical).hexdigest()
    )
    return document


def publish_snapshot(
    output: Path,
    parent_descriptor: int,
    payload: bytes,
    max_snapshot_bytes: int,
    observation: Observation,
) -> None:
    if len(payload) > max_snapshot_bytes:
        raise ProducerError("validated snapshot exceeds the application model size bound")
    temp_name = write_private_temp(parent_descriptor, "workstack-snapshot", payload)
    try:
        observation.prove_unchanged()
        try:
            existing = os.stat(output.name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and (
            not stat.S_ISREG(existing.st_mode)
            or existing.st_nlink != 1
            or stat.S_IMODE(existing.st_mode) != 0o600
        ):
            raise ProducerError("snapshot destination became unsafe before replacement")
        os.replace(
            temp_name,
            output.name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        os.fsync(parent_descriptor)
        published = os.stat(output.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(published.st_mode)
            or published.st_nlink != 1
            or stat.S_IMODE(published.st_mode) != 0o600
            or published.st_size != len(payload)
        ):
            raise ProducerError("published snapshot failed its final safety check")
    finally:
        try:
            os.unlink(temp_name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="fm-workstack-compass-snapshot.py",
        description=(
            "Generate, validate, and atomically publish one local read-only "
            "Workstack Compass snapshot, then print (but do not run) its launch command."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "The Workstack executable model owns the snapshot schema. Project roots "
            "are explicit NAME=PATH identity bindings and are never discovered. "
            "The default output is $FM_HOME/data/workstack-compass/snapshot.json; "
            "custom outputs require an owner-private subdirectory below FM_HOME data."
        ),
    )
    result.add_argument(
        "--workstack-root",
        required=True,
        metavar="PATH",
        help="read-only local Workstack Compass repository containing its executable model",
    )
    result.add_argument(
        "--project-root",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="explicit read-only root for one exactly registered project (repeatable)",
    )
    result.add_argument(
        "--output",
        metavar="PATH",
        help="snapshot path in an owner-private subdirectory below active FM_HOME data",
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    script_root = Path(__file__).resolve().parent.parent
    parent_descriptor: int | None = None
    try:
        home = active_home(script_root)
        output, parent_descriptor = prepare_output(home, arguments.output)
        observation = Observation()
        model, workstack_root = load_workstack_model(
            Path(arguments.workstack_root).expanduser(), observation
        )
        registry_payload = observation.read_file(
            home / "data" / "projects.md", MAX_REGISTRY_BYTES, missing_ok=True
        )
        registered = parse_registry(registry_payload)
        bindings = bind_project_roots(
            arguments.project_root, set(registered), observation
        )
        project_sources, project_source_by_name = inspect_project_sources(
            registered, bindings, observation
        )
        backlog_payload = observation.read_file(
            home / "data" / "backlog.md", MAX_BACKLOG_BYTES, missing_ok=True
        )
        backlog_tasks = read_backlog_tasks(
            backlog_payload, parent_descriptor, output.parent
        )
        workers, meta_present, omitted_task_evidence = collect_workers(
            home, observation, backlog_tasks, set(registered)
        )
        document = build_document(
            model,
            registered,
            workers,
            registry_payload is not None,
            backlog_payload is not None,
            meta_present,
            omitted_task_evidence,
            project_sources,
            project_source_by_name,
        )
        unique_identities(document["projects"], "project_identity", "project")
        unique_identities(
            document["worker_incarnations"],
            "worker_incarnation_identity",
            "worker incarnation",
        )
        validate_document(model, document)
        observation.prove_unchanged()
        payload = (
            json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        ).encode("utf-8")
        publish_snapshot(
            output,
            parent_descriptor,
            payload,
            model.MAX_SNAPSHOT_BYTES,
            observation,
        )
        launch = (
            f"cd {shlex.quote(os.fspath(workstack_root))} && "
            f"./bin/workstack-compass --snapshot {shlex.quote(os.fspath(output))} "
            "--color --reduced-motion"
        )
        print(f"Snapshot: {output}")
        print(f"Launch: {launch}")
        return 0
    except ProducerError as exc:
        print(f"fm-workstack-compass-snapshot: {exc}", file=sys.stderr)
        return 1
    finally:
        if parent_descriptor is not None:
            os.close(parent_descriptor)


if __name__ == "__main__":
    raise SystemExit(main())

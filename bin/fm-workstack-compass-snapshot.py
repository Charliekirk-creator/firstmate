#!/usr/bin/env python3
"""Produce one private, read-only Workstack Compass upstream snapshot.

The executable model at the operator-supplied Workstack Compass root is the
sole owner of ``workstack-compass.snapshot.v1``.  This producer loads that
model, collects sanitized exact-identity evidence from Firstmate and explicitly
bound read-only project roots, projects that evidence through this shipped
adapter, asks the model to validate the complete candidate, and then atomically
replaces one mode-0600 private file.

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
* The command is local-only and network-free.  Its model, backlog-reader,
  staging, cleanup, and publication subprocesses use the built-in macOS sandbox,
  and the command refuses when that boundary is unavailable.  It never retains
  or emits transcripts or status prose, launches or controls a worker, changes a source,
  acknowledges an event, opens a connection, launches Workstack Compass, or
  publishes data.
* Firstmate project identity, bounded tasks-axi backlog identity, and task
  incarnation metadata are projected by this producer and accepted only when
  the supplied model's existing mapping interface validates the candidate.
  Missing typed producers remain unavailable rather than being inferred.

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
import ctypes
import errno
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import sysconfig
import threading
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
MAX_STATE_ENTRIES = 10_000
MAX_REGISTERED_PROJECTS = 1_000
MAX_PROJECT_SOURCE_BYTES = 512 * 1024
MAX_MODEL_BYTES = 512 * 1024
MAX_READER_OUTPUT_BYTES = 2 * 1024 * 1024
MAX_READER_PACKAGE_BYTES = 32 * 1024 * 1024
MAX_READER_PACKAGE_ENTRIES = 4_000
MAX_READER_STAGING_BYTES = 256 * 1024 * 1024
MAX_RUNTIME_DEPENDENCIES = 256
MAX_TASK_RECORDS = 10_000
TASKS_AXI_TIMEOUT_SECONDS = 10
READER_STAGING_TIMEOUT_SECONDS = 60
MODEL_TIMEOUT_SECONDS = 10
MAX_MODEL_RESPONSE_BYTES = 64 * 1024
MAX_MODEL_SNAPSHOT_BYTES = 16 * 1024 * 1024
MAX_SUBPROCESS_MEMORY_BYTES = 256 * 1024 * 1024
MAX_SUBPROCESS_GROUP_PROCESSES = 512
REQUIRED_SCHEMA_VERSION = "workstack-compass.snapshot.v1"
EVIDENCE_VERSION = "firstmate.workstack-compass-evidence.v1"
IDENTITY_RE = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
TASK_ID_RE = re.compile(r"^(?!\.)[A-Za-z0-9._-]+$")
REGISTRY_LINE_RE = re.compile(
    r"^- ([A-Za-z0-9._-]{1,160})(?: \[[^\]\r\n]+\])? - \S.*$"
)
META_KEY_RE = re.compile(r"^[a-z_][a-z0-9_]*$")
SPAWN_GEN_RE = re.compile(r"^(?!\.)[A-Za-z0-9._-]+$")
DTM_NODE_RE = re.compile(r"^[A-Za-z0-9_-]{1,180}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


class ProducerError(RuntimeError):
    """A bounded operator-facing refusal with no source bytes or private path."""


class SourceChanged(ProducerError):
    """One observed source changed before the observation completed."""


class RusageInfoV2(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
    ]


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
class AnchoredDirectory:
    path: Path
    descriptor: int
    fingerprint: Fingerprint


@dataclass(frozen=True)
class ProjectBinding:
    name: str
    root: AnchoredDirectory


@dataclass(frozen=True)
class ModelContract:
    source: bytes
    schema_version: str
    max_snapshot_bytes: int


@dataclass(frozen=True)
class WorkerEvidence:
    task_identity: str
    generation_identity: str
    kind: str
    project_name: str | None


@dataclass(frozen=True)
class ProjectSourceEvidence:
    project_name: str
    evidence_kind: str
    board_node_identity: str | None = None


@dataclass(frozen=True)
class ReaderAsset:
    relative: tuple[str, ...]
    payload: bytes | None
    executable: bool
    descriptor: int | None = None
    fingerprint: Fingerprint | None = None


@dataclass(frozen=True)
class ReaderBoundary:
    assets: tuple[ReaderAsset, ...]
    runtime_descriptor: int
    runtime_authority: Path
    runtime_relative: tuple[str, ...] | None
    executable_relative: tuple[str, ...]
    dependency_directories: tuple[tuple[str, ...], ...]
    cwd: Path
    source_roots: tuple[AnchoredDirectory, ...]
    retained_entries: tuple[tuple[int, Fingerprint], ...]


class Observation:
    """Capture bounded source bytes beneath retained directory authorities."""

    def __init__(self) -> None:
        self._anchors: list[AnchoredDirectory] = []
        self._retained_entries: list[int] = []
        self._observed: dict[tuple[int, tuple[str, ...]], Fingerprint] = {}
        self._absent: set[tuple[int, tuple[str, ...]]] = set()
        self._inventories: dict[
            tuple[int, tuple[str, ...], str, int], tuple[str, ...]
        ] = {}
        self._aliases: dict[Path, Fingerprint] = {}

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

    @staticmethod
    def _parts(
        anchor: AnchoredDirectory, relative: str | Path | Sequence[str]
    ) -> tuple[str, ...]:
        if isinstance(relative, Sequence) and not isinstance(relative, (str, Path)):
            parts = tuple(relative)
        else:
            candidate = Path(relative)
            if candidate.is_absolute():
                try:
                    candidate = candidate.relative_to(anchor.path)
                except ValueError as exc:
                    raise ProducerError("source path escapes its approved root") from exc
            parts = candidate.parts
        if not parts or any(
            part in {"", ".", ".."} or "/" in part for part in parts
        ):
            raise ProducerError("source path escapes its approved root")
        for part in parts:
            reject_control_path(Path(part))
        return parts

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )

    def _open_directory(
        self, anchor: AnchoredDirectory, parts: Sequence[str]
    ) -> int:
        descriptor = os.dup(anchor.descriptor)
        try:
            for part in parts:
                child = os.open(
                    part,
                    self._directory_flags(),
                    dir_fd=descriptor,
                )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except OSError:
            os.close(descriptor)
            raise

    def _open_entry(
        self,
        anchor: AnchoredDirectory,
        parts: Sequence[str],
        *,
        expected_type: str = "file",
    ) -> int:
        parent = self._open_directory(anchor, parts[:-1])
        flags = self._directory_flags() if expected_type == "directory" else (
            os.O_RDONLY
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )

        def expected(info: os.stat_result) -> bool:
            if expected_type == "file":
                return stat.S_ISREG(info.st_mode)
            if expected_type == "directory":
                return stat.S_ISDIR(info.st_mode)
            return stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)

        try:
            before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode):
                raise OSError(errno.ELOOP, "source entry is a symlink")
            if not expected(before):
                raise OSError(errno.EINVAL, "source entry has an unsafe type")
            descriptor = os.open(parts[-1], flags, dir_fd=parent)
            opened = os.fstat(descriptor)
            if (
                not expected(opened)
                or opened.st_dev != before.st_dev
                or opened.st_ino != before.st_ino
                or stat.S_IFMT(opened.st_mode) != stat.S_IFMT(before.st_mode)
            ):
                os.close(descriptor)
                raise SourceChanged("source changed during observation")
            return descriptor
        finally:
            os.close(parent)

    def observe_directory(self, path: Path) -> AnchoredDirectory:
        reject_control_path(path)
        try:
            before = os.stat(path, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
                raise ProducerError(
                    "required source directory is not an ordinary directory"
                )
            descriptor = os.open(path, self._directory_flags())
        except ProducerError:
            raise
        except OSError as exc:
            raise ProducerError("required source directory is unavailable") from exc
        try:
            opened = os.fstat(descriptor)
            if self._fingerprint(opened) != self._fingerprint(before):
                raise SourceChanged("source changed during observation")
            resolved = path.resolve(strict=True)
            resolved_info = os.stat(resolved, follow_symlinks=False)
            if self._fingerprint(resolved_info) != self._fingerprint(opened):
                raise SourceChanged("source changed during observation")
        except (OSError, RuntimeError) as exc:
            os.close(descriptor)
            raise SourceChanged("source changed during observation") from exc
        except Exception:
            os.close(descriptor)
            raise
        anchor = AnchoredDirectory(resolved, descriptor, self._fingerprint(opened))
        self._anchors.append(anchor)
        return anchor

    def observe_subdirectory(
        self, anchor: AnchoredDirectory, relative: str | Path | Sequence[str]
    ) -> AnchoredDirectory:
        parts = self._parts(anchor, relative)
        try:
            descriptor = self._open_directory(anchor, parts)
            info = os.fstat(descriptor)
        except OSError as exc:
            if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                raise ProducerError("source path contains a symlink or unsafe component") from exc
            raise ProducerError("required source directory is unavailable") from exc
        fingerprint = self._fingerprint(info)
        child = AnchoredDirectory(anchor.path.joinpath(*parts), descriptor, fingerprint)
        self._anchors.append(child)
        return child

    def observe_entry(
        self, anchor: AnchoredDirectory, relative: str | Path | Sequence[str]
    ) -> os.stat_result:
        parts = self._parts(anchor, relative)
        try:
            descriptor = self._open_entry(anchor, parts, expected_type="entry")
        except OSError as exc:
            if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                raise ProducerError("source path contains a symlink or unsafe component") from exc
            raise ProducerError("required source path is unavailable") from exc
        try:
            info = os.fstat(descriptor)
            self._remember(anchor, parts, self._fingerprint(info))
            return info
        finally:
            os.close(descriptor)

    @staticmethod
    def _bounded_inventory(
        descriptor: int,
        pattern: str,
        max_entries: int,
        overflow_message: str,
    ) -> tuple[str, ...]:
        names: list[str] = []
        entries_seen = 0
        with os.scandir(descriptor) as entries:
            for entry in entries:
                entries_seen += 1
                if entries_seen > max_entries:
                    raise ProducerError(overflow_message)
                if fnmatch.fnmatchcase(entry.name, pattern):
                    names.append(entry.name)
        return tuple(sorted(names))

    def observe_inventory(
        self,
        anchor: AnchoredDirectory,
        relative: str | Path | Sequence[str],
        pattern: str,
        *,
        max_entries: int,
        overflow_message: str,
    ) -> list[str]:
        parts = self._parts(anchor, relative)
        try:
            descriptor = self._open_directory(anchor, parts)
            info = os.fstat(descriptor)
            names = self._bounded_inventory(
                descriptor, pattern, max_entries, overflow_message
            )
        except OSError as exc:
            raise ProducerError("required source directory is unavailable") from exc
        finally:
            if "descriptor" in locals():
                os.close(descriptor)
        self._remember(anchor, parts, self._fingerprint(info))
        self._inventories[(anchor.descriptor, parts, pattern, max_entries)] = names
        return list(names)

    def capture_tree(self, anchor: AnchoredDirectory) -> tuple[ReaderAsset, ...]:
        pending: list[tuple[str, ...]] = [()]
        assets: list[ReaderAsset] = []
        entries = 0
        total_bytes = 0
        while pending:
            parts = pending.pop()
            if parts:
                names = self.observe_inventory(
                    anchor,
                    parts,
                    "*",
                    max_entries=MAX_READER_PACKAGE_ENTRIES,
                    overflow_message=(
                        "authoritative local reader package exceeds its entry bound"
                    ),
                )
            else:
                try:
                    descriptor = os.dup(anchor.descriptor)
                    info = os.fstat(descriptor)
                    names = list(
                        self._bounded_inventory(
                            descriptor,
                            "*",
                            MAX_READER_PACKAGE_ENTRIES,
                            "authoritative local reader package exceeds its entry bound",
                        )
                    )
                except OSError as exc:
                    raise ProducerError(
                        "authoritative local reader package is unsafe"
                    ) from exc
                finally:
                    if "descriptor" in locals():
                        os.close(descriptor)
                        del descriptor
                self._inventories[
                    (anchor.descriptor, (), "*", MAX_READER_PACKAGE_ENTRIES)
                ] = tuple(names)
                if self._fingerprint(info) != anchor.fingerprint:
                    raise SourceChanged("source changed during observation")
            for name in names:
                child = (*parts, name)
                entry = self.observe_entry(anchor, child)
                entries += 1
                if entries > MAX_READER_PACKAGE_ENTRIES:
                    raise ProducerError(
                        "authoritative local reader package exceeds its entry bound"
                    )
                if stat.S_ISDIR(entry.st_mode):
                    pending.append(child)
                    continue
                payload = self.read_under(anchor, child, MAX_READER_PACKAGE_BYTES)
                assert payload is not None
                total_bytes += len(payload)
                if total_bytes > MAX_READER_PACKAGE_BYTES:
                    raise ProducerError(
                        "authoritative local reader package exceeds its size bound"
                    )
                assets.append(
                    ReaderAsset(child, payload, executable_by_current_user(entry))
                )
        assets.sort(key=lambda asset: asset.relative)
        return tuple(assets)

    def read_under(
        self,
        anchor: AnchoredDirectory,
        relative: str | Path | Sequence[str],
        cap: int,
        *,
        missing_ok: bool = False,
    ) -> bytes | None:
        parts = self._parts(anchor, relative)
        key = (anchor.descriptor, parts)
        try:
            descriptor = self._open_entry(anchor, parts)
        except FileNotFoundError:
            if missing_ok:
                self._absent.add(key)
                return None
            raise ProducerError("required source file is unavailable")
        except OSError as exc:
            if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                raise ProducerError("source path contains a symlink or unsafe component") from exc
            raise ProducerError("source input could not be opened safely") from exc
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
                raise ProducerError("source input is not a single ordinary file")
            if opened.st_size > cap:
                raise ProducerError("source input exceeds its bounded size")
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
        self._remember(anchor, parts, self._fingerprint(after))
        return b"".join(chunks)

    def retain_under(
        self,
        anchor: AnchoredDirectory,
        relative: str | Path | Sequence[str],
    ) -> tuple[int, Fingerprint]:
        parts = self._parts(anchor, relative)
        try:
            descriptor = self._open_entry(anchor, parts)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ProducerError("source input is not a single ordinary file")
            self._remember(anchor, parts, self._fingerprint(info))
        except Exception:
            if "descriptor" in locals():
                os.close(descriptor)
            raise
        fingerprint = self._fingerprint(info)
        self._retained_entries.append(descriptor)
        return descriptor, fingerprint

    def prove_retained(
        self, entries: Iterable[tuple[int, Fingerprint]]
    ) -> None:
        for descriptor, expected in entries:
            try:
                current = os.fstat(descriptor)
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            if self._fingerprint(current) != expected:
                raise SourceChanged("source changed during observation")

    def _remember(
        self,
        anchor: AnchoredDirectory,
        parts: tuple[str, ...],
        fingerprint: Fingerprint,
    ) -> None:
        key = (anchor.descriptor, parts)
        if key in self._absent:
            raise SourceChanged("source changed during observation")
        prior = self._observed.get(key)
        if prior is not None and prior != fingerprint:
            raise SourceChanged("source changed during observation")
        self._observed[key] = fingerprint

    def observe_alias(self, path: Path, expected: Fingerprint) -> None:
        try:
            current = self._fingerprint(os.stat(path))
        except OSError as exc:
            raise ProducerError("runtime dependency authority is unavailable") from exc
        if current != expected:
            raise SourceChanged("source changed during observation")
        prior = self._aliases.get(path)
        if prior is not None and prior != expected:
            raise SourceChanged("source changed during observation")
        self._aliases[path] = expected

    def prove_unchanged(self) -> None:
        anchors = {anchor.descriptor: anchor for anchor in self._anchors}
        for anchor in self._anchors:
            try:
                retained = os.fstat(anchor.descriptor)
                current = os.stat(anchor.path, follow_symlinks=False)
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            if any(
                info.st_dev != anchor.fingerprint.device
                or info.st_ino != anchor.fingerprint.inode
                or stat.S_IFMT(info.st_mode) != anchor.fingerprint.mode_type
                for info in (retained, current)
            ):
                raise SourceChanged("source changed during observation")
        for descriptor, parts in self._absent:
            anchor = anchors[descriptor]
            try:
                present = self._open_entry(anchor, parts, expected_type="entry")
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            else:
                os.close(present)
                raise SourceChanged("source changed during observation")
        for (descriptor, parts), expected in self._observed.items():
            anchor = anchors[descriptor]
            try:
                current_descriptor = self._open_entry(
                    anchor,
                    parts,
                    expected_type=(
                        "directory" if stat.S_ISDIR(expected.mode_type) else "file"
                    ),
                )
                current = os.fstat(current_descriptor)
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            finally:
                if "current_descriptor" in locals():
                    os.close(current_descriptor)
                    del current_descriptor
            if self._fingerprint(current) != expected:
                raise SourceChanged("source changed during observation")
        for path, expected in self._aliases.items():
            try:
                current = self._fingerprint(os.stat(path))
            except OSError as exc:
                raise SourceChanged("source changed during observation") from exc
            if current != expected:
                raise SourceChanged("source changed during observation")
        for (
            descriptor,
            parts,
            pattern,
            max_entries,
        ), expected in self._inventories.items():
            anchor = anchors[descriptor]
            try:
                directory = self._open_directory(anchor, parts)
                current = self._bounded_inventory(
                    directory,
                    pattern,
                    max_entries,
                    "source inventory exceeds its entry bound",
                )
            except (OSError, ProducerError) as exc:
                raise SourceChanged("source inventory changed during observation") from exc
            finally:
                if "directory" in locals():
                    os.close(directory)
                    del directory
            if current != expected:
                raise SourceChanged("source inventory changed during observation")

    def close(self) -> None:
        while self._retained_entries:
            descriptor = self._retained_entries.pop()
            try:
                os.close(descriptor)
            except OSError:
                pass
        while self._anchors:
            anchor = self._anchors.pop()
            try:
                os.close(anchor.descriptor)
            except OSError:
                pass


def reject_control_path(path: Path) -> None:
    if CONTROL_RE.search(os.fspath(path)):
        raise ProducerError("a supplied path contains a control character")


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


def active_home(
    script_root: Path, observation: Observation
) -> AnchoredDirectory:
    configured = os.environ.get("FM_HOME")
    candidate = Path(configured).expanduser() if configured else script_root
    home = observation.observe_directory(candidate)
    for child in ("data", "state"):
        directory = observation.observe_subdirectory(home, child)
        if not stat.S_ISDIR(os.fstat(directory.descriptor).st_mode):
            raise ProducerError("active Firstmate home is incomplete")
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


def validate_git_marker(
    root: AnchoredDirectory, observation: Observation
) -> None:
    try:
        info = observation.observe_entry(root, ".git")
    except ProducerError as exc:
        raise ProducerError("explicit project root is not a repository") from exc
    if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
        raise ProducerError("explicit project repository marker is unsafe")


def bind_project_roots(
    values: Sequence[str], registered: set[str], observation: Observation
) -> dict[str, ProjectBinding]:
    bindings: dict[str, ProjectBinding] = {}
    roots_seen: set[Path] = set()
    for value in values:
        name, requested = parse_project_root(value)
        if name not in registered:
            raise ProducerError(
                "explicit project root is not present in the Firstmate registry"
            )
        if name in bindings:
            raise ProducerError("duplicate explicit project-root identity")
        root = observation.observe_directory(requested)
        validate_git_marker(root, observation)
        if root.path in roots_seen:
            raise ProducerError(
                "one project root cannot represent multiple exact project identities"
            )
        roots_seen.add(root.path)
        bindings[name] = ProjectBinding(name, root)
    return bindings


def reject_source_repository_parent(
    parent_descriptor: int, source_roots: Iterable[AnchoredDirectory]
) -> None:
    source_identities = {
        (info.st_dev, info.st_ino)
        for info in (os.fstat(root.descriptor) for root in source_roots)
    }
    current = os.dup(parent_descriptor)
    visited: set[tuple[int, int]] = set()
    try:
        while True:
            info = os.fstat(current)
            identity = (info.st_dev, info.st_ino)
            if identity in source_identities:
                raise ProducerError(
                    "snapshot output must not be inside a source repository"
                )
            if identity in visited:
                raise ProducerError("snapshot output parent ancestry is unsafe")
            visited.add(identity)
            ancestor = os.open("..", Observation._directory_flags(), dir_fd=current)
            ancestor_info = os.fstat(ancestor)
            if (ancestor_info.st_dev, ancestor_info.st_ino) == identity:
                os.close(ancestor)
                return
            os.close(current)
            current = ancestor
    except ProducerError:
        raise
    except OSError as exc:
        raise ProducerError("snapshot output parent ancestry is unsafe") from exc
    finally:
        os.close(current)


def prepare_output(
    home: AnchoredDirectory,
    requested: str | None,
    source_roots: Iterable[AnchoredDirectory],
    observation: Observation,
) -> tuple[Path, int]:
    data = observation.observe_subdirectory(home, "data")
    canonical_data = data.path
    retained_source_roots = tuple(source_roots)
    if requested is None:
        parent_parts = ("workstack-compass",)
        output_name = "snapshot.json"
        parent = canonical_data.joinpath(*parent_parts)
    else:
        requested_output = Path(requested).expanduser()
        reject_control_path(requested_output)
        if not requested_output.is_absolute():
            requested_output = Path.cwd() / requested_output
        output_name = requested_output.name
        try:
            parent = requested_output.parent.resolve(strict=True)
            parent_parts = parent.relative_to(canonical_data).parts
        except (OSError, RuntimeError, ValueError) as exc:
            raise ProducerError(
                "snapshot output must stay below the active FM_HOME data directory"
            ) from exc
    if not parent_parts:
        raise ProducerError(
            "snapshot output requires a private subdirectory below FM_HOME data"
        )
    if output_name in {"", ".", ".."} or "/" in output_name:
        raise ProducerError("snapshot destination name is unsafe")
    output = canonical_data.joinpath(*parent_parts, output_name)
    reject_control_path(output)
    for source_root in retained_source_roots:
        try:
            output.relative_to(source_root.path)
        except ValueError:
            continue
        raise ProducerError("snapshot output must not be inside a source repository")

    if requested is None:
        create_default_output_parent(
            data,
            parent_parts[0],
            retained_source_roots,
        )
    try:
        parent_anchor = observation.observe_subdirectory(data, parent_parts)
    except ProducerError as exc:
        raise ProducerError("snapshot output parent contains an unsafe component") from exc
    parent_descriptor = os.dup(parent_anchor.descriptor)
    try:
        parent_info = os.fstat(parent_descriptor)
        reject_source_repository_parent(parent_descriptor, retained_source_roots)
        if (
            not stat.S_ISDIR(parent_info.st_mode)
            or parent_info.st_uid != os.getuid()
            or stat.S_IMODE(parent_info.st_mode) & 0o077
        ):
            raise ProducerError("snapshot output parent has unsafe ownership or permissions")
        try:
            existing = os.stat(
                output_name, dir_fd=parent_descriptor, follow_symlinks=False
            )
        except FileNotFoundError:
            existing = None
        except OSError as exc:
            raise ProducerError("snapshot destination could not be inspected safely") from exc
        if existing is not None and (
            not stat.S_ISREG(existing.st_mode)
            or existing.st_nlink != 1
            or stat.S_IMODE(existing.st_mode) != 0o600
        ):
            raise ProducerError("snapshot destination is not one private ordinary file")
    except Exception:
        os.close(parent_descriptor)
        raise
    return output, parent_descriptor


_LIBPROC: Any | None = None


def libproc() -> Any:
    global _LIBPROC
    if _LIBPROC is None:
        try:
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            library.proc_listpgrppids.argtypes = (
                ctypes.c_int,
                ctypes.c_void_p,
                ctypes.c_int,
            )
            library.proc_listpgrppids.restype = ctypes.c_int
            library.proc_pid_rusage.argtypes = (
                ctypes.c_int,
                ctypes.c_int,
                ctypes.POINTER(RusageInfoV2),
            )
            library.proc_pid_rusage.restype = ctypes.c_int
        except (AttributeError, OSError) as exc:
            raise ProducerError("a supported subprocess memory boundary is unavailable") from exc
        _LIBPROC = library
    return _LIBPROC


def process_group_footprint(process_group: int) -> int | None:
    library = libproc()
    identifiers = (ctypes.c_int * MAX_SUBPROCESS_GROUP_PROCESSES)()
    size = ctypes.sizeof(identifiers)
    count = library.proc_listpgrppids(process_group, identifiers, size)
    if count < 0 or count >= MAX_SUBPROCESS_GROUP_PROCESSES:
        return None
    total = 0
    for process_id in identifiers[:count]:
        if process_id <= 0:
            continue
        usage = RusageInfoV2()
        if library.proc_pid_rusage(process_id, 2, ctypes.byref(usage)) == 0:
            total += usage.ri_phys_footprint
    return total


def paused_subprocess_argv(argv: Sequence[str]) -> list[str]:
    return [
        "/bin/sh",
        "-c",
        'kill -STOP $$ || exit 70; exec "$@"',
        "fm-memory-boundary",
        *argv,
    ]


def run_bounded(
    argv: Sequence[str],
    env: Mapping[str, str],
    *,
    timeout: int = TASKS_AXI_TIMEOUT_SECONDS,
    cap: int = MAX_READER_OUTPUT_BYTES,
    pass_descriptors: Sequence[int] = (),
    input_payload: bytes | None = None,
    discard_stderr: bool = False,
    cwd: Path | None = None,
) -> bytes:
    libproc()
    try:
        process = subprocess.Popen(
            paused_subprocess_argv(argv),
            stdin=subprocess.PIPE if input_payload is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL if discard_stderr else subprocess.STDOUT,
            env=dict(env),
            shell=False,
            start_new_session=True,
            pass_fds=tuple(pass_descriptors),
            cwd=os.fspath(cwd) if cwd is not None else None,
        )
    except OSError as exc:
        raise ProducerError("authoritative local reader could not be started") from exc
    chunks: list[bytes] = []
    total = 0
    oversized = False
    memory_refused = False
    memory_ready = threading.Event()
    memory_stop = threading.Event()

    def kill_reader() -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                process.kill()
            except OSError:
                pass

    def watch_memory() -> None:
        nonlocal memory_refused
        memory_ready.set()
        while not memory_stop.is_set():
            try:
                os.kill(process.pid, signal.SIGCONT)
            except OSError:
                if process.poll() is not None:
                    return
            footprint = process_group_footprint(process.pid)
            if footprint is None:
                if process.poll() is None:
                    memory_refused = True
                    kill_reader()
                return
            if footprint > MAX_SUBPROCESS_MEMORY_BYTES:
                memory_refused = True
                kill_reader()
                return
            if process.poll() is not None or memory_stop.wait(0.005):
                return

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

    memory_watcher = threading.Thread(
        target=watch_memory,
        name="workstack-source-memory-boundary",
        daemon=True,
    )
    reader = threading.Thread(target=drain, name="workstack-source-reader", daemon=True)

    def supply_input() -> None:
        if input_payload is None or process.stdin is None:
            return
        try:
            process.stdin.write(input_payload)
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    writer = threading.Thread(target=supply_input, name="workstack-source-input", daemon=True)
    memory_watcher.start()
    if not memory_ready.wait(timeout=1):
        kill_reader()
        process.wait()
        memory_stop.set()
        memory_watcher.join(timeout=1)
        raise ProducerError("authoritative local reader memory boundary failed")
    try:
        os.kill(process.pid, signal.SIGCONT)
    except OSError as exc:
        kill_reader()
        process.wait()
        memory_stop.set()
        memory_watcher.join(timeout=1)
        raise ProducerError("authoritative local reader memory boundary failed") from exc
    reader.start()
    writer.start()
    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        kill_reader()
        process.wait()
        memory_stop.set()
        memory_watcher.join(timeout=1)
        reader.join(timeout=1)
        writer.join(timeout=1)
        raise ProducerError("authoritative local reader exceeded its time bound") from exc
    memory_stop.set()
    memory_watcher.join(timeout=1)
    reader.join(timeout=1)
    writer.join(timeout=1)
    if process.stdout is not None:
        process.stdout.close()
    if memory_watcher.is_alive() or reader.is_alive() or writer.is_alive():
        kill_reader()
        raise ProducerError("authoritative local reader did not close its bounded streams")
    if memory_refused:
        raise ProducerError("authoritative local reader exceeded its memory bound")
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
    if count_match is None:
        raise ProducerError("authoritative local reader returned malformed output")
    shown = int(count_match.group(1))
    total = int(count_match.group(2) or shown)
    if shown != total or shown > MAX_TASK_RECORDS:
        raise ProducerError("authoritative local reader returned incomplete output")
    expected = ["id", "state", "kind", "repo", "title"]
    if shown == 0:
        if lines[1] != "tasks: 0 tasks in this backlog":
            raise ProducerError("authoritative local reader returned malformed output")
        fields = expected
    else:
        header_match = re.fullmatch(r"tasks\[(\d+)\]\{([^}]+)\}:", lines[1])
        if header_match is None:
            raise ProducerError("authoritative local reader returned malformed output")
        declared = int(header_match.group(1))
        fields = header_match.group(2).split(",")
        if declared != shown:
            raise ProducerError("authoritative local reader returned incomplete output")
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
        if not TASK_ID_RE.fullmatch(identity):
            raise ProducerError("backlog contains a broken exact identity")
        if identity in seen:
            raise ProducerError("backlog contains a duplicate exact identity")
        seen.add(identity)
        state = record["state"]
        if state not in {"queued", "in_flight", "done", "held"}:
            raise ProducerError("backlog reader returned an unsupported task state")
        kind = None if record["kind"] == "-" else record["kind"]
        project_name = None if record["repo"] == "-" else record["repo"]
        if kind is not None and not IDENTITY_RE.fullmatch(kind):
            raise ProducerError("backlog contains a broken kind identity")
        if project_name is not None and not IDENTITY_RE.fullmatch(project_name):
            raise ProducerError("backlog contains a broken project relation")
        rows.append(BacklogTask(identity, state, kind, project_name))
    if len(rows) != shown:
        raise ProducerError("authoritative local reader returned incomplete output")
    return rows


def inspect_runtime_dependencies(
    runtime: Path,
    runtime_anchor: AnchoredDirectory,
    observation: Observation,
) -> tuple[
    tuple[Path, ...],
    tuple[tuple[Path, tuple[str, ...]], ...],
    tuple[AnchoredDirectory, ...],
]:
    tool = next(
        (
            candidate
            for candidate in (
                Path("/Library/Developer/CommandLineTools/usr/bin/otool-classic"),
                Path("/Library/Developer/CommandLineTools/usr/bin/otool"),
                Path(
                    "/Applications/Xcode.app/Contents/Developer/Toolchains/"
                    "XcodeDefault.xctoolchain/usr/bin/otool-classic"
                ),
                Path(
                    "/Applications/Xcode.app/Contents/Developer/Toolchains/"
                    "XcodeDefault.xctoolchain/usr/bin/otool"
                ),
                Path("/usr/bin/otool"),
            )
            if candidate.is_file() and os.access(candidate, os.X_OK)
        ),
        None,
    )
    if tool is None:
        raise ProducerError("runtime dependency inspector is unavailable")
    tool_root = tool.parent
    for ancestor in tool.parents:
        if ancestor.name in {"CommandLineTools", "Xcode.app"}:
            tool_root = ancestor
            break

    def inspect(candidate: Path, option: str) -> str:
        argv = sandboxed_command_argv(
            (tool, option, candidate),
            read_paths=(tool_root, candidate),
            executable=tool,
        )
        output = run_bounded(
            argv,
            {"LANG": "C", "LC_ALL": "C"},
            cap=MAX_READER_OUTPUT_BYTES,
            discard_stderr=True,
            cwd=Path("/var/empty"),
        )
        return decode_utf8(output, "runtime dependency metadata")

    def metadata(candidate: Path) -> tuple[list[str], list[str]]:
        dependencies = []
        for line in inspect(candidate, "-L").splitlines():
            stripped = line.strip()
            marker = " (compatibility version "
            if line[:1].isspace() and marker in stripped:
                dependencies.append(stripped.split(marker, 1)[0])
        rpaths: list[str] = []
        awaiting_path = False
        for line in inspect(candidate, "-l").splitlines():
            stripped = line.strip()
            if stripped == "cmd LC_RPATH":
                awaiting_path = True
            elif awaiting_path and stripped.startswith("path "):
                value = stripped[5:].rsplit(" (offset ", 1)[0]
                rpaths.append(value)
                awaiting_path = False
        return dependencies, rpaths

    def expand(value: str, loader: Path, rpaths: Sequence[str]) -> list[Path]:
        if value.startswith("@loader_path/"):
            return [loader.parent / value.removeprefix("@loader_path/")]
        if value.startswith("@executable_path/"):
            return [runtime.parent / value.removeprefix("@executable_path/")]
        if value.startswith("@rpath/"):
            suffix = value.removeprefix("@rpath/")
            expanded: list[Path] = []
            for rpath in rpaths:
                if rpath == "@loader_path":
                    expanded.append(loader.parent / suffix)
                elif rpath.startswith("@loader_path/"):
                    expanded.append(
                        loader.parent / rpath.removeprefix("@loader_path/") / suffix
                    )
                elif rpath == "@executable_path":
                    expanded.append(runtime.parent / suffix)
                elif rpath.startswith("@executable_path/"):
                    expanded.append(
                        runtime.parent
                        / rpath.removeprefix("@executable_path/")
                        / suffix
                    )
                elif Path(rpath).is_absolute():
                    expanded.append(Path(rpath) / suffix)
            return expanded
        if Path(value).is_absolute():
            return [Path(value)]
        raise ProducerError("runtime dependency authority is unsupported")

    runtime_dependencies, runtime_rpaths = metadata(runtime)
    pending: list[tuple[Path, list[str]]] = [(runtime, runtime_rpaths)]
    dependencies_by_path: dict[Path, tuple[Path, ...]] = {}
    anchors_by_parent: dict[Path, AnchoredDirectory] = {
        runtime_anchor.path: runtime_anchor
    }
    visited: set[Path] = set()
    first = True
    while pending:
        loader, inherited_rpaths = pending.pop()
        if loader in visited:
            continue
        visited.add(loader)
        if first:
            load_values = runtime_dependencies
            loader_rpaths = runtime_rpaths
            first = False
        else:
            load_values, loader_rpaths = metadata(loader)
        search_rpaths = [*loader_rpaths, *inherited_rpaths, *runtime_rpaths]
        for value in load_values:
            if value.startswith("/usr/lib/") or value.startswith("/System/Library/"):
                continue
            candidates = expand(value, loader, search_rpaths)
            selected: Path | None = None
            for candidate in candidates:
                try:
                    selected = candidate.resolve(strict=True)
                except (OSError, RuntimeError):
                    continue
                break
            if selected is None:
                raise ProducerError("runtime dependency authority is unavailable")
            if selected.is_relative_to(Path("/usr/lib")) or selected.is_relative_to(
                Path("/System/Library")
            ):
                continue
            if selected not in dependencies_by_path:
                if len(dependencies_by_path) >= MAX_RUNTIME_DEPENDENCIES:
                    raise ProducerError("runtime dependency inventory exceeds its bound")
                requested = candidates[0]
                for candidate in candidates:
                    try:
                        if candidate.resolve(strict=True) == selected:
                            requested = candidate
                            break
                    except (OSError, RuntimeError):
                        continue
                parent = selected.parent
                anchor = anchors_by_parent.get(parent)
                if anchor is None:
                    anchor = observation.observe_directory(parent)
                    anchors_by_parent[parent] = anchor
                info = observation.observe_entry(anchor, selected.name)
                expected = observation._fingerprint(info)
                try:
                    aliases = [
                        requested,
                        requested.parent.resolve(strict=True) / requested.name,
                    ]
                    current = aliases[-1]
                    while current.is_symlink():
                        target = Path(os.readlink(current))
                        current = (
                            target
                            if target.is_absolute()
                            else current.parent / target
                        )
                        aliases.append(current)
                except (OSError, RuntimeError) as exc:
                    raise SourceChanged("source changed during observation") from exc
                aliases.append(selected)
                authorities = tuple(dict.fromkeys(aliases))
                for alias in authorities:
                    observation.observe_alias(alias, expected)
                dependencies_by_path[selected] = authorities
                pending.append((selected, search_rpaths))
    read_paths = tuple(
        dict.fromkeys(
            path
            for authorities in dependencies_by_path.values()
            for path in authorities
        )
    )
    return (
        read_paths,
        tuple(
            (
                dependency,
                tuple(dict.fromkeys(path.name for path in authorities)),
            )
            for dependency, authorities in dependencies_by_path.items()
        ),
        tuple(anchors_by_parent.values()),
    )


def tasks_axi_boundary(
    path: str, observation: Observation, output_root: Path
) -> ReaderBoundary:
    selected = shutil.which("tasks-axi", path=path)
    if selected is None:
        raise ProducerError("authoritative local reader is unavailable")
    try:
        executable = Path(selected).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ProducerError("authoritative local reader is unsafe") from exc
    source_root = executable.parent
    for candidate in executable.parents:
        if candidate.name == "tasks-axi" and candidate.parent.name == "node_modules":
            source_root = candidate
            break
    try:
        source_anchor = observation.observe_directory(source_root)
        executable_relative = executable.relative_to(source_root).parts
        executable_info = observation.observe_entry(
            source_anchor, executable_relative
        )
        executable_payload = observation.read_under(
            source_anchor, executable_relative, MAX_READER_PACKAGE_BYTES
        )
        package_assets = observation.capture_tree(source_anchor)
        assert executable_payload is not None
        shebang = executable_payload[:4096].splitlines(keepends=True)[0]
    except (OSError, RuntimeError, IndexError, ValueError, ProducerError) as exc:
        raise ProducerError("authoritative local reader is unsafe") from exc
    if not stat.S_ISREG(executable_info.st_mode) or not executable_by_current_user(
        executable_info
    ):
        raise ProducerError("authoritative local reader is unsafe")
    if not shebang.startswith(b"#!") or len(shebang) == 4096:
        raise ProducerError("authoritative local reader has an unsupported runtime")
    try:
        words = shebang[2:].decode("utf-8", errors="strict").strip().split()
    except UnicodeDecodeError as exc:
        raise ProducerError("authoritative local reader has an unsupported runtime") from exc
    runtime_name: str
    runtime_selected: str | None
    if len(words) == 2 and words[0] == "/usr/bin/env":
        runtime_name = words[1]
        runtime_selected = shutil.which(runtime_name, path=path)
    elif len(words) == 1 and Path(words[0]).is_absolute():
        runtime_name = Path(words[0]).name
        runtime_selected = words[0]
    else:
        raise ProducerError("authoritative local reader has an unsupported runtime")
    if runtime_name not in {"bash", "node"}:
        raise ProducerError("authoritative local reader has an unsupported runtime")
    if runtime_selected is None:
        raise ProducerError("authoritative local reader runtime is unavailable")
    try:
        runtime = Path(runtime_selected).resolve(strict=True)
        runtime_anchor = observation.observe_directory(runtime.parent)
        runtime_info = observation.observe_entry(runtime_anchor, runtime.name)
    except (OSError, RuntimeError, ProducerError) as exc:
        raise ProducerError("authoritative local reader runtime is unsafe") from exc
    if not stat.S_ISREG(runtime_info.st_mode) or not executable_by_current_user(runtime_info):
        raise ProducerError("authoritative local reader runtime is unsafe")
    try:
        empty_home = Path("/var/empty").resolve(strict=True)
        empty_info = empty_home.stat()
        if (
            not stat.S_ISDIR(empty_info.st_mode)
            or empty_info.st_uid != 0
            or stat.S_IMODE(empty_info.st_mode) & 0o022
            or any(empty_home.iterdir())
        ):
            raise ProducerError("authoritative local reader empty home is unsafe")
    except (OSError, RuntimeError) as exc:
        raise ProducerError("authoritative local reader empty home is unsafe") from exc
    _dependency_paths, dependencies, dependency_anchors = inspect_runtime_dependencies(
        runtime, runtime_anchor, observation
    )
    assets = list(package_assets)
    runtime_descriptor, runtime_fingerprint = observation.retain_under(
        runtime_anchor, runtime.name
    )
    if runtime_fingerprint.size > MAX_READER_STAGING_BYTES:
        raise ProducerError("reader staging image exceeds its size bound")
    runtime_relative: tuple[str, ...] | None = None
    if not any(
        runtime.is_relative_to(root) for root in (Path("/bin"), Path("/usr/bin"))
    ):
        runtime_relative = ("runtime", runtime.name)
        assets.append(
            ReaderAsset(
                runtime_relative,
                None,
                True,
                runtime_descriptor,
                runtime_fingerprint,
            )
        )
    dependency_directories: list[tuple[str, ...]] = []
    dependency_names: set[str] = set()
    for index, (dependency, names) in enumerate(dependencies):
        if dependency_names.intersection(names):
            raise ProducerError("runtime dependency authority is ambiguous")
        dependency_names.update(names)
        anchor = next(
            (
                candidate
                for candidate in dependency_anchors
                if candidate.path == dependency.parent
            ),
            None,
        )
        if anchor is None:
            raise ProducerError("runtime dependency authority is unavailable")
        descriptor, dependency_fingerprint = observation.retain_under(
            anchor, dependency.name
        )
        if dependency_fingerprint.size > MAX_READER_STAGING_BYTES:
            raise ProducerError("reader staging image exceeds its size bound")
        directory = ("dependencies", str(index))
        dependency_directories.append(directory)
        assets.extend(
            ReaderAsset(
                (*directory, name),
                None,
                False,
                descriptor,
                dependency_fingerprint,
            )
            for name in names
        )
    retained_entries = {runtime_descriptor: runtime_fingerprint}
    for asset in assets:
        if asset.descriptor is None:
            continue
        if asset.fingerprint is None:
            raise ProducerError("reader staging image contains an unsafe retained asset")
        prior = retained_entries.setdefault(asset.descriptor, asset.fingerprint)
        if prior != asset.fingerprint:
            raise SourceChanged("source changed during observation")
    staging_size = sum(
        len(asset.payload) for asset in assets if asset.payload is not None
    ) + sum(fingerprint.size for fingerprint in retained_entries.values())
    if staging_size > MAX_READER_STAGING_BYTES:
        raise ProducerError("reader staging image exceeds its size bound")
    executable_staged_relative = ("package", *executable_relative)
    assets = [
        ReaderAsset(("package", *asset.relative), asset.payload, asset.executable)
        for asset in assets[: len(package_assets)]
    ] + assets[len(package_assets) :]
    authorities = list(dict.fromkeys((source_anchor, runtime_anchor, *dependency_anchors)))
    authorities_by_path = {authority.path: authority for authority in authorities}
    for authority in tuple(authorities):
        try:
            relative = authority.path.relative_to(output_root)
        except ValueError:
            continue
        if relative.parts:
            container_path = output_root / relative.parts[0]
            container = authorities_by_path.get(container_path)
            if container is None:
                container = observation.observe_directory(container_path)
                authorities_by_path[container.path] = container
                authorities.append(container)
        for candidate in (authority.path, *authority.path.parents):
            if candidate == output_root.parent:
                break
            try:
                marker = os.stat(candidate / ".git", follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise ProducerError("reader source repository authority is unsafe") from exc
            if not (stat.S_ISDIR(marker.st_mode) or stat.S_ISREG(marker.st_mode)):
                raise ProducerError("reader source repository authority is unsafe")
            repository = observation.observe_directory(candidate)
            observation.observe_entry(repository, ".git")
            authorities.append(repository)
            break
    return ReaderBoundary(
        tuple(assets),
        runtime_descriptor,
        runtime,
        runtime_relative,
        executable_staged_relative,
        tuple(dependency_directories),
        empty_home,
        tuple(dict.fromkeys(authorities)),
        tuple(retained_entries.items()),
    )


STAGE_READER_PROGRAM = r'''
import json
import os
import stat
import sys

parent_descriptor = int(sys.argv[1])
expected_device = int(sys.argv[2])
expected_inode = int(sys.argv[3])
stage_name = sys.argv[4]
os.umask(0)
header_size = int.from_bytes(sys.stdin.buffer.read(8), "big")
if header_size < 2 or header_size > 1024 * 1024:
    raise SystemExit(2)
manifest = json.loads(sys.stdin.buffer.read(header_size))
parent = os.fstat(parent_descriptor)
if (
    parent.st_dev != expected_device
    or parent.st_ino != expected_inode
    or not stat.S_ISDIR(parent.st_mode)
    or parent.st_uid != os.getuid()
    or stat.S_IMODE(parent.st_mode) & 0o077
):
    raise SystemExit(2)
os.mkdir(stage_name, 0o700, dir_fd=parent_descriptor)
stage = os.open(
    stage_name,
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    dir_fd=parent_descriptor,
)
try:
    directories = {() : stage}
    for record in manifest:
        parts = tuple(record["path"])
        size = record["size"]
        if (
            not parts
            or any(not isinstance(part, str) or part in {"", ".", ".."} or "/" in part for part in parts)
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size < 0
            or not isinstance(record["executable"], bool)
        ):
            raise SystemExit(2)
        parent_parts = parts[:-1]
        for depth in range(1, len(parent_parts) + 1):
            current = parent_parts[:depth]
            if current in directories:
                continue
            owner = directories[current[:-1]]
            try:
                os.mkdir(current[-1], 0o700, dir_fd=owner)
            except FileExistsError:
                pass
            directories[current] = os.open(
                current[-1],
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=owner,
            )
        owner = directories[parent_parts]
        source_descriptor = record.get("descriptor")
        if source_descriptor is not None:
            if isinstance(source_descriptor, bool) or not isinstance(source_descriptor, int):
                raise SystemExit(2)
            if not record["executable"]:
                os.symlink(
                    f"/dev/fd/{source_descriptor}", parts[-1], dir_fd=owner
                )
                continue
            descriptor = os.open(
                parts[-1],
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=owner,
            )
            os.lseek(source_descriptor, 0, os.SEEK_SET)
            remaining = size
            while remaining:
                chunk = os.read(source_descriptor, min(65536, remaining))
                if not chunk:
                    raise SystemExit(2)
                view = memoryview(chunk)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise SystemExit(2)
                    view = view[written:]
                remaining -= len(chunk)
            try:
                os.fchmod(descriptor, 0o500)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            continue
        descriptor = os.open(
            parts[-1],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=owner,
        )
        remaining = size
        while remaining:
            chunk = sys.stdin.buffer.read(min(65536, remaining))
            if not chunk:
                raise SystemExit(2)
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise SystemExit(2)
                view = view[written:]
            remaining -= len(chunk)
        try:
            os.fchmod(descriptor, 0o500 if record["executable"] else 0o400)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    if sys.stdin.buffer.read(1):
        raise SystemExit(2)
    for parts, descriptor in sorted(directories.items(), reverse=True):
        if parts:
            os.fsync(descriptor)
            os.close(descriptor)
    os.fsync(stage)
    os.fsync(parent_descriptor)
finally:
    os.close(stage)
'''


REMOVE_READER_STAGE_PROGRAM = r'''
import os
import stat
import sys

parent_descriptor = int(sys.argv[1])
expected_device = int(sys.argv[2])
expected_inode = int(sys.argv[3])
stage_name = sys.argv[4]
parent = os.fstat(parent_descriptor)
if (
    parent.st_dev != expected_device
    or parent.st_ino != expected_inode
    or not stat.S_ISDIR(parent.st_mode)
):
    raise SystemExit(2)

def remove_tree(owner, name):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=owner,
    )
    try:
        for child in os.listdir(descriptor):
            info = os.stat(child, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                remove_tree(descriptor, child)
            else:
                os.unlink(child, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=owner)

try:
    remove_tree(parent_descriptor, stage_name)
except FileNotFoundError:
    pass
os.fsync(parent_descriptor)
'''


def reader_stage_payload(assets: Sequence[ReaderAsset]) -> bytes:
    manifest: list[dict[str, Any]] = []
    for asset in assets:
        if asset.payload is not None:
            if asset.descriptor is not None or asset.fingerprint is not None:
                raise ProducerError("reader staging image contains an unsafe asset")
            size = len(asset.payload)
        else:
            if asset.descriptor is None or asset.fingerprint is None:
                raise ProducerError("reader staging image contains an unsafe retained asset")
            size = asset.fingerprint.size
        manifest.append(
            {
                "path": list(asset.relative),
                "size": size,
                "executable": asset.executable,
                "descriptor": asset.descriptor,
            }
        )
    header = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
    if len(header) > 1024 * 1024:
        raise ProducerError("reader staging image exceeds its metadata bound")
    return len(header).to_bytes(8, "big") + header + b"".join(
        asset.payload for asset in assets if asset.payload is not None
    )


def remove_reader_stage(
    parent_descriptor: int,
    parent_path: Path,
    stage_name: str,
    source_roots: Sequence[AnchoredDirectory],
) -> None:
    parent_info = os.fstat(parent_descriptor)
    stage_path = parent_path / stage_name
    argv = sandboxed_python_argv(
        REMOVE_READER_STAGE_PROGRAM,
        read_paths=(parent_path, stage_path),
        write_paths=(parent_path,),
        write_subpaths=(stage_path,),
        denied_write_roots=(root.path for root in source_roots),
    )
    argv.extend(
        (
            str(parent_descriptor),
            str(parent_info.st_dev),
            str(parent_info.st_ino),
            stage_name,
        )
    )
    run_bounded(
        argv,
        {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"},
        timeout=MODEL_TIMEOUT_SECONDS,
        cap=1,
        pass_descriptors=(parent_descriptor,),
        discard_stderr=True,
    )


def read_backlog_tasks(
    payload: bytes | None,
    boundary: ReaderBoundary | None,
    output: Path,
    parent_descriptor: int,
    source_roots: Sequence[AnchoredDirectory],
    observation: Observation,
) -> list[BacklogTask]:
    if payload is None:
        return []
    if boundary is None:
        raise ProducerError("authoritative local reader is unavailable")
    parent_info = os.fstat(parent_descriptor)
    stage_name = f".workstack-reader.{os.getpid()}.{os.urandom(8).hex()}"
    stage_path = output.parent / stage_name
    observation.prove_retained(boundary.retained_entries)
    staging_payload = reader_stage_payload(boundary.assets)
    try:
        stage_argv = sandboxed_python_argv(
            STAGE_READER_PROGRAM,
            read_paths=(output.parent, *(root.path for root in source_roots)),
            write_paths=(output.parent,),
            write_subpaths=(stage_path,),
            denied_write_roots=(root.path for root in source_roots),
        )
        stage_argv.extend(
            (
                str(parent_descriptor),
                str(parent_info.st_dev),
                str(parent_info.st_ino),
                stage_name,
            )
        )
        try:
            run_bounded(
                stage_argv,
                {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"},
                timeout=READER_STAGING_TIMEOUT_SECONDS,
                cap=1,
                pass_descriptors=(
                    parent_descriptor,
                    *(
                        asset.descriptor
                        for asset in boundary.assets
                        if asset.descriptor is not None
                    ),
                ),
                input_payload=staging_payload,
                discard_stderr=True,
            )
        except ProducerError as exc:
            raise ProducerError(f"reader staging boundary failed: {exc}") from exc
        observation.prove_retained(boundary.retained_entries)
        runtime = (
            stage_path.joinpath(*boundary.runtime_relative)
            if boundary.runtime_relative is not None
            else boundary.runtime_authority
        )
        executable = stage_path.joinpath(*boundary.executable_relative)
        dependency_paths = [
            stage_path.joinpath(*relative)
            for relative in boundary.dependency_directories
        ]
        reader_command = (
            runtime,
            executable,
            "list",
            "--file",
            "/dev/fd/0",
            "--limit",
            str(MAX_TASK_RECORDS),
        )
        sandbox_executable = runtime
        process_executables: tuple[Path, ...] = ()
        reader_paths = [stage_path, boundary.cwd]
        if dependency_paths:
            environment_tool = Path("/usr/bin/env")
            reader_command = (
                environment_tool,
                "DYLD_LIBRARY_PATH="
                + os.pathsep.join(os.fspath(path) for path in dependency_paths),
                *reader_command,
            )
            sandbox_executable = environment_tool
            process_executables = (runtime,)
            reader_paths.append(environment_tool)
        argv = sandboxed_command_argv(
            reader_command,
            read_paths=reader_paths,
            executable=sandbox_executable,
            process_executables=process_executables,
        )
        environment = {
            "HOME": os.fspath(boundary.cwd),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "NO_COLOR": "1",
            "OPENSSL_CONF": "/dev/null",
        }
        try:
            output_payload = run_bounded(
                argv,
                environment,
                input_payload=payload,
                discard_stderr=True,
                cwd=boundary.cwd,
                pass_descriptors=(
                    boundary.runtime_descriptor,
                    *(
                        asset.descriptor
                        for asset in boundary.assets
                        if asset.descriptor is not None
                    ),
                ),
            )
        except ProducerError as exc:
            raise ProducerError(f"captured backlog reader failed: {exc}") from exc
    finally:
        remove_reader_stage(
            parent_descriptor,
            output.parent,
            stage_name,
            source_roots,
        )
    return parse_tasks_axi(output_payload)


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


def collect_workers(
    home: AnchoredDirectory,
    observation: Observation,
    backlog_tasks: Iterable[BacklogTask],
    registered: set[str],
) -> tuple[list[WorkerEvidence], bool, int]:
    names = observation.observe_inventory(
        home,
        "state",
        "*.meta",
        max_entries=MAX_STATE_ENTRIES,
        overflow_message="Firstmate state inventory exceeds its entry bound",
    )
    if len(names) > MAX_META_RECORDS:
        raise ProducerError("task metadata inventory exceeds its record bound")
    tasks = {record.identity: record for record in backlog_tasks}
    workers: list[WorkerEvidence] = []
    total_bytes = 0
    omitted_identities: set[str] = set()
    generation_identities: set[str] = set()
    for name in names:
        identity = name[:-5]
        if not TASK_ID_RE.fullmatch(identity):
            raise ProducerError("task metadata filename contains a broken exact identity")
        payload = observation.read_under(home, ("state", name), MAX_META_BYTES)
        assert payload is not None
        total_bytes += len(payload)
        if total_bytes > MAX_META_TOTAL_BYTES:
            raise ProducerError("task metadata inventory exceeds its total byte bound")
        meta = parse_meta(payload)
        spawn_generation_count = sum(
            1 for line in decode_utf8(payload, "task metadata").splitlines()
            if line.startswith("spawn_gen=")
        )
        if spawn_generation_count == 0:
            omitted_identities.add(identity)
            continue
        if spawn_generation_count != 1:
            raise ProducerError(
                "task metadata must contain exactly one incarnation identity"
            )
        generation = meta["spawn_gen"]
        if not SPAWN_GEN_RE.fullmatch(generation):
            raise ProducerError("task metadata contains a broken incarnation identity")
        kind = meta.get("kind", "ship")
        if kind not in {"ship", "scout", "secondmate"}:
            raise ProducerError("task metadata contains an unsupported worker role")
        task = tasks.get(identity)
        related_project: str | None = None
        if task is not None and task.project_name in registered:
            assert task.project_name is not None
            related_project = task.project_name
        workers.append(WorkerEvidence(identity, generation, kind, related_project))
        generation_identities.add(identity)
    omitted_identities.update(
        task.identity
        for task in tasks.values()
        if task.state == "in_flight" and task.identity not in generation_identities
    )
    workers.sort(key=lambda row: (row.task_identity, row.generation_identity))
    return workers, True, len(omitted_identities)


def inspect_project_sources(
    registered: Sequence[str],
    bindings: Mapping[str, ProjectBinding],
    observation: Observation,
) -> list[ProjectSourceEvidence]:
    sources: list[ProjectSourceEvidence] = []
    for name in sorted(registered):
        binding = bindings.get(name)
        if binding is None:
            sources.append(ProjectSourceEvidence(name, "unbound"))
            continue
        if name == "data-team-management":
            payload = observation.read_under(
                binding.root,
                ("config", "board.json"),
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
            sources.append(
                ProjectSourceEvidence(
                    name, "data_team_management_board", node_identity
                )
            )
        elif name == "gl-data-team-tickets":
            payload = observation.read_under(
                binding.root, "README.md", MAX_PROJECT_SOURCE_BYTES
            )
            if not decode_utf8(payload, "Data Team Tickets repository contract").strip():
                raise ProducerError("Data Team Tickets repository contract is malformed")
            sources.append(
                ProjectSourceEvidence(name, "data_team_tickets_artifacts")
            )
        else:
            sources.append(ProjectSourceEvidence(name, "explicit_untyped_root"))
    return sources


MODEL_BOUNDARY_PROGRAM = r'''
import json
import resource
import sys
import types

resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
request = json.loads(sys.stdin.buffer.read())
source = request["source"]
module_name = "_fm_workstack_model_boundary"
module = types.ModuleType(module_name)
module.__file__ = "<workstack-compass-model>"
sys.modules[module_name] = module
try:
    exec(compile(source, module.__file__, "exec"), module.__dict__)
    schema_version = getattr(module, "SCHEMA_VERSION", None)
    max_snapshot_bytes = getattr(module, "MAX_SNAPSHOT_BYTES", None)
    validator = getattr(module, "snapshot_from_mapping", None)
    if (
        schema_version != "workstack-compass.snapshot.v1"
        or isinstance(max_snapshot_bytes, bool)
        or not isinstance(max_snapshot_bytes, int)
        or max_snapshot_bytes < 1
        or not callable(validator)
    ):
        raise ValueError("unsupported contract")
    operation = request["operation"]
    response = {
        "schema_version": schema_version,
        "max_snapshot_bytes": max_snapshot_bytes,
        "valid": True,
    }
    if operation == "validate":
        document = json.loads(
            json.dumps(
                request["document"],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
        )
        snapshot = validator(document)
        issues = snapshot.integrity_issues()
        if not isinstance(issues, tuple) or issues:
            raise ValueError("integrity failure")
    elif operation != "contract":
        raise ValueError("unsupported operation")
    sys.stdout.write(
        json.dumps(
            response,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    )
finally:
    sys.modules.pop(module_name, None)
'''


def _sandbox_literal(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def sandboxed_command_argv(
    command: Sequence[str | Path],
    *,
    read_paths: Iterable[Path] = (),
    write_paths: Iterable[Path] = (),
    write_subpaths: Iterable[Path] = (),
    denied_write_roots: Iterable[Path] = (),
    executable: Path,
    process_executables: Iterable[Path] = (),
) -> list[str]:
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        raise ProducerError("a supported local-only sandbox is unavailable")
    try:
        executable = executable.resolve(strict=True)
        allowed_executables = {
            executable,
            *(path.resolve(strict=True) for path in process_executables),
        }
    except (OSError, RuntimeError) as exc:
        raise SourceChanged("source changed during observation") from exc
    read_roots = {
        Path("/usr/lib"),
        Path("/System/Library"),
        Path("/private/var/db/dyld"),
        *read_paths,
    }
    readable_rules: list[str] = [
        '(literal "/")',
        '(literal "/dev/null")',
        '(subpath "/dev/fd")',
    ]
    ancestors: set[Path] = set()
    for root in read_roots:
        literal = _sandbox_literal(os.fspath(root))
        readable_rules.extend((f'(literal "{literal}")', f'(subpath "{literal}")'))
        ancestors.update(root.parents)
    for ancestor in sorted(ancestors, key=lambda path: (len(path.parts), os.fspath(path))):
        readable_rules.append(f'(literal "{_sandbox_literal(os.fspath(ancestor))}")')
    profile_parts = [
        "(version 1)",
        "(deny default)",
        '(import "system.sb")',
        "(deny network*)",
        "(allow process-exec "
        + " ".join(
            f'(literal "{_sandbox_literal(os.fspath(path))}")'
            for path in sorted(allowed_executables, key=os.fspath)
        )
        + ")",
        "(allow process-info* (target self))",
        f"(allow file-read* {' '.join(readable_rules)})",
    ]
    writable = tuple(write_paths)
    writable_subpaths = tuple(write_subpaths)
    if writable or writable_subpaths:
        write_rules = [
            f'(literal "{_sandbox_literal(os.fspath(path))}")'
            for path in writable
        ]
        write_rules.extend(
            f'(subpath "{_sandbox_literal(os.fspath(path))}")'
            for path in writable_subpaths
        )
        profile_parts.append(f"(allow file-write* {' '.join(write_rules)})")
        for root in denied_write_roots:
            profile_parts.append(
                f'(deny file-write* (subpath "{_sandbox_literal(os.fspath(root))}"))'
            )
    else:
        profile_parts.append("(deny file-write*)")
    return [
        "/usr/bin/sandbox-exec",
        "-p",
        " ".join(profile_parts),
        *(os.fspath(value) for value in command),
    ]


def sandboxed_python_argv(
    program: str,
    *,
    read_paths: Iterable[Path] = (),
    write_paths: Iterable[Path] = (),
    write_subpaths: Iterable[Path] = (),
    denied_write_roots: Iterable[Path] = (),
) -> list[str]:
    try:
        executable = Path(sys.executable).resolve(strict=True)
        version_root = executable.parent.parent
        base_prefix = Path(sys.base_prefix).resolve(strict=True)
        stdlib = Path(sysconfig.get_path("stdlib")).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SourceChanged("source changed during observation") from exc
    framework_executable = (
        version_root / "Resources" / "Python.app" / "Contents" / "MacOS" / "Python"
    )
    process_executables = (
        (framework_executable,) if framework_executable.is_file() else ()
    )
    return sandboxed_command_argv(
        (executable, "-I", "-S", "-B", "-c", program),
        read_paths=(
            executable.parent,
            base_prefix,
            stdlib,
            *read_paths,
        ),
        write_paths=write_paths,
        write_subpaths=write_subpaths,
        denied_write_roots=denied_write_roots,
        executable=executable,
        process_executables=process_executables,
    )


def model_boundary_argv() -> list[str]:
    try:
        return sandboxed_python_argv(MODEL_BOUNDARY_PROGRAM)
    except ProducerError as exc:
        raise ProducerError(
            "a supported network-free executable-model sandbox is unavailable"
        ) from exc


def run_model_boundary(
    source: bytes,
    operation: str,
    document: Mapping[str, Any] | None = None,
) -> Mapping[str, Any]:
    request: dict[str, Any] = {
        "operation": operation,
        "source": decode_utf8(source, "Workstack Compass executable model"),
    }
    if document is not None:
        request["document"] = document
    payload = json.dumps(
        request,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    environment = {
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    boundary_argv = model_boundary_argv()
    try:
        output = run_bounded(
            boundary_argv,
            environment,
            timeout=MODEL_TIMEOUT_SECONDS,
            cap=MAX_MODEL_RESPONSE_BYTES,
            input_payload=payload,
            discard_stderr=True,
        )
        response = json.loads(decode_utf8(output, "executable-model response"))
    except (ProducerError, json.JSONDecodeError) as exc:
        raise ProducerError("Workstack Compass executable model boundary failed") from exc
    expected_keys = {"schema_version", "max_snapshot_bytes", "valid"}
    if not isinstance(response, Mapping) or set(response) != expected_keys:
        raise ProducerError("Workstack Compass executable model returned a malformed result")
    return response


def load_workstack_model(
    root: Path, observation: Observation
) -> tuple[ModelContract, AnchoredDirectory]:
    workstack = observation.observe_directory(root)
    validate_git_marker(workstack, observation)
    model_payload = observation.read_under(
        workstack, ("src", "workstack_compass", "model.py"), MAX_MODEL_BYTES
    )
    launcher_relative = ("bin", "workstack-compass")
    launcher_info = observation.observe_entry(workstack, launcher_relative)
    launcher_payload = observation.read_under(
        workstack, launcher_relative, MAX_MODEL_BYTES
    )
    if not launcher_payload.startswith(b"#!") or not executable_by_current_user(
        launcher_info
    ):
        raise ProducerError("Workstack Compass launcher is malformed or not executable")
    try:
        response = run_model_boundary(model_payload, "contract")
    except ProducerError as exc:
        if "sandbox" in str(exc) and "unavailable" in str(exc):
            raise
        raise ProducerError(
            "Workstack Compass executable model contract is unsupported"
        ) from exc
    max_snapshot_bytes = response.get("max_snapshot_bytes")
    if (
        response.get("schema_version") != REQUIRED_SCHEMA_VERSION
        or response.get("valid") is not True
        or isinstance(max_snapshot_bytes, bool)
        or not isinstance(max_snapshot_bytes, int)
        or max_snapshot_bytes < 1
        or max_snapshot_bytes > MAX_MODEL_SNAPSHOT_BYTES
    ):
        raise ProducerError("Workstack Compass executable model contract is unsupported")
    return (
        ModelContract(model_payload, REQUIRED_SCHEMA_VERSION, max_snapshot_bytes),
        workstack,
    )


def executable_by_current_user(info: os.stat_result) -> bool:
    mode = info.st_mode
    if os.geteuid() == 0:
        return bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
    if info.st_uid == os.geteuid():
        return bool(mode & stat.S_IXUSR)
    if info.st_gid == os.getegid() or info.st_gid in os.getgroups():
        return bool(mode & stat.S_IXGRP)
    return bool(mode & stat.S_IXOTH)


def build_evidence(
    registered: Sequence[str],
    workers: Sequence[WorkerEvidence],
    registry_present: bool,
    backlog_present: bool,
    meta_present: bool,
    omitted_task_evidence: int,
    project_sources: Sequence[ProjectSourceEvidence],
) -> dict[str, Any]:
    worker_identities = [
        (worker.task_identity, worker.generation_identity) for worker in workers
    ]
    if len(worker_identities) != len(set(worker_identities)):
        raise ProducerError("evidence contains duplicate worker incarnation identities")
    source_projects = [source.project_name for source in project_sources]
    if len(source_projects) != len(set(source_projects)) or set(source_projects) != set(
        registered
    ):
        raise ProducerError("evidence contains broken project source identities")
    observed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    return {
        "evidence_version": EVIDENCE_VERSION,
        "observed_at": observed_at,
        "registry": {
            "available": registry_present,
            "project_names": sorted(registered),
        },
        "tasks": {
            "backlog_available": backlog_present,
            "metadata_inventory_available": meta_present,
            "current_state_available": False,
            "omitted_incarnation_count": omitted_task_evidence,
            "incarnations": [
                {
                    "task_identity": worker.task_identity,
                    "generation_identity": worker.generation_identity,
                    "kind": worker.kind,
                    "project_name": worker.project_name,
                }
                for worker in workers
            ],
        },
        "project_roots": [
            {
                "project_name": source.project_name,
                "evidence_kind": source.evidence_kind,
                "board_node_identity": source.board_node_identity,
            }
            for source in project_sources
        ],
    }


def project_document(
    model: ModelContract, evidence: Mapping[str, Any]
) -> Mapping[str, Any]:
    registry = evidence["registry"]
    tasks = evidence["tasks"]
    incarnations = tasks["incarnations"]
    registry_source = {
        "source_identity": "source:firstmate-project-registry",
        "label": "Firstmate registered projects",
        "completeness": "complete" if registry["available"] else "unavailable",
        "detail": (
            "The active Firstmate project registry was observed without inferred project joins."
            if registry["available"]
            else "The active Firstmate project registry is unavailable."
        ),
    }
    backlog_present = tasks["backlog_available"]
    meta_present = tasks["metadata_inventory_available"]
    omitted = tasks["omitted_incarnation_count"]
    current_state_unavailable = bool(incarnations) and not tasks[
        "current_state_available"
    ]
    if backlog_present and meta_present:
        task_completeness = (
            "partial" if omitted or current_state_unavailable else "complete"
        )
        if omitted and incarnations:
            task_detail = "Exact task and worker-incarnation identities were observed; worker current state is unavailable, records without exact incarnation identity are omitted, and untyped telemetry remains unavailable."
        elif omitted:
            task_detail = "Exact task evidence and task metadata were observed; records without exact incarnation identity are omitted, so no exact worker incarnation is available, and untyped telemetry remains unavailable."
        elif current_state_unavailable:
            task_detail = "Exact task and worker-incarnation identities were observed; no worker current-state evidence was available, and untyped telemetry remains unavailable."
        else:
            task_detail = "Exact task and worker-incarnation identity sources were observed completely."
    elif backlog_present or meta_present:
        task_completeness = "partial"
        task_detail = "Only part of the exact task identity evidence is available; worker telemetry and untyped relations remain unavailable."
    else:
        task_completeness = "unavailable"
        task_detail = "No local task identity evidence is available."
    sources = [
        registry_source,
        {
            "source_identity": "source:firstmate-task-identities",
            "label": "Firstmate task identity records",
            "completeness": task_completeness,
            "detail": task_detail,
        },
    ]
    project_source_by_name: dict[str, str] = {}
    for source in evidence["project_roots"]:
        name = source["project_name"]
        kind = source["evidence_kind"]
        if kind == "unbound":
            identity = f"source:project-root:{name}"
            row = {
                "source_identity": identity,
                "label": f"{name} local upstream",
                "completeness": "unavailable",
                "detail": "No explicit read-only root was supplied for this registered project.",
            }
            project_source_by_name[name] = "source:firstmate-project-registry"
        elif kind == "data_team_management_board":
            identity = (
                "source:data-team-management-board:"
                + source["board_node_identity"]
            )
            row = {
                "source_identity": identity,
                "label": "Data Team Management board identity",
                "completeness": "partial",
                "detail": "The local board identity contract is available; current board rows and typed execution relations are not exported locally.",
            }
            project_source_by_name[name] = identity
        elif kind == "data_team_tickets_artifacts":
            identity = "source:gl-data-team-tickets-artifacts"
            row = {
                "source_identity": identity,
                "label": "Data Team Tickets artifact repository",
                "completeness": "partial",
                "detail": "The explicit artifact repository is available; it publishes no typed plan, stage, work-unit, delivery, or acceptance relation for this snapshot.",
            }
            project_source_by_name[name] = identity
        else:
            identity = f"source:project-root:{name}"
            row = {
                "source_identity": identity,
                "label": f"{name} explicit project root",
                "completeness": "partial",
                "detail": "The registered read-only root is available; no typed Workstack relation producer is published there.",
            }
            project_source_by_name[name] = identity
        sources.append(row)
    sources.sort(key=lambda row: row["source_identity"])
    projects = [
        {
            "project_identity": f"firstmate-project:{name}",
            "source_identity": project_source_by_name.get(
                name, "source:firstmate-project-registry"
            ),
            "label": name,
            "outcome": None,
        }
        for name in registry["project_names"]
    ]
    roles = {
        "ship": "Ship worker",
        "scout": "Scout",
        "secondmate": "Second mate",
    }
    workers = [
        {
            "worker_incarnation_identity": f"firstmate-worker-incarnation:{row['task_identity']}:{row['generation_identity']}",
            "worker_identity": f"firstmate-worker:{row['task_identity']}",
            "role": roles[row["kind"]],
            "status": "unavailable",
            "liveness": "unavailable",
            "live_proof_identity": None,
            "project_identity": (
                f"firstmate-project:{row['project_name']}"
                if row["project_name"]
                else None
            ),
            "work_unit_identities": [],
            "context_percent": None,
            "duration_seconds": None,
            "source_identity": "source:firstmate-task-identities",
        }
        for row in incarnations
    ]
    exact_status = "partial" if projects else "unavailable"
    worker_status = "partial" if workers else "unavailable"
    interfaces = [
        {
            "name": "decision-history",
            "status": "unavailable",
            "source_identity": None,
            "detail": "No authoritative retained-decision exporter is available.",
        },
        {
            "name": "exact-work-identity",
            "status": exact_status,
            "source_identity": (
                "source:firstmate-project-registry" if projects else None
            ),
            "detail": (
                "Registered project identities are available; typed plan, stage, work-unit, command, next-action, delivery, and acceptance producers are unavailable."
                if projects
                else "Exact project and work hierarchy identities are unavailable."
            ),
        },
        {
            "name": "worker-context-duration",
            "status": worker_status,
            "source_identity": (
                "source:firstmate-task-identities" if workers else None
            ),
            "detail": (
                "Exact worker incarnations are available; current status, liveness, context, duration, and typed work-unit relations are unavailable."
                if workers
                else "No exact worker incarnation with an authoritative generation identity is available."
            ),
        },
    ]
    document: dict[str, Any] = {
        "schema_version": model.schema_version,
        "observation_identity": "observation:pending",
        "observed_at": evidence["observed_at"],
        "data_classification": (
            "authoritative" if projects or workers else "unavailable"
        ),
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
        digest_input,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    document["observation_identity"] = (
        "observation:sha256:" + hashlib.sha256(canonical).hexdigest()
    )
    try:
        response = run_model_boundary(model.source, "validate", document)
    except ProducerError as exc:
        raise ProducerError(
            "Workstack Compass executable model rejected the snapshot"
        ) from exc
    if (
        response.get("schema_version") != model.schema_version
        or response.get("max_snapshot_bytes") != model.max_snapshot_bytes
        or response.get("valid") is not True
    ):
        raise ProducerError("Workstack Compass executable model rejected the snapshot")
    return document


CREATE_OUTPUT_PARENT_PROGRAM = r'''
import os
import stat
import sys

data_descriptor = int(sys.argv[1])
expected_device = int(sys.argv[2])
expected_inode = int(sys.argv[3])
name = sys.argv[4]
data = os.fstat(data_descriptor)
if (
    data.st_dev != expected_device
    or data.st_ino != expected_inode
    or not stat.S_ISDIR(data.st_mode)
):
    raise SystemExit(2)
try:
    existing = os.stat(name, dir_fd=data_descriptor, follow_symlinks=False)
except FileNotFoundError:
    previous_umask = os.umask(0)
    try:
        os.mkdir(name, 0o700, dir_fd=data_descriptor)
    finally:
        os.umask(previous_umask)
    os.fsync(data_descriptor)
    existing = os.stat(name, dir_fd=data_descriptor, follow_symlinks=False)
if (
    not stat.S_ISDIR(existing.st_mode)
    or existing.st_uid != os.getuid()
    or stat.S_IMODE(existing.st_mode) & 0o077
):
    raise SystemExit(2)
'''


def create_default_output_parent(
    data: AnchoredDirectory,
    name: str,
    source_roots: Iterable[AnchoredDirectory],
) -> None:
    data_info = os.fstat(data.descriptor)
    parent_path = data.path / name
    try:
        argv = sandboxed_python_argv(
            CREATE_OUTPUT_PARENT_PROGRAM,
            read_paths=(data.path,),
            write_paths=(data.path, parent_path),
            denied_write_roots=(root.path for root in source_roots),
        )
        argv.extend(
            (
                str(data.descriptor),
                str(data_info.st_dev),
                str(data_info.st_ino),
                name,
            )
        )
        run_bounded(
            argv,
            {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"},
            timeout=MODEL_TIMEOUT_SECONDS,
            cap=1,
            pass_descriptors=(data.descriptor,),
            discard_stderr=True,
        )
    except ProducerError as exc:
        raise ProducerError("private snapshot directory could not be created safely") from exc


PUBLISH_BOUNDARY_PROGRAM = r'''
import os
import stat
import sys

parent_descriptor = int(sys.argv[1])
expected_device = int(sys.argv[2])
expected_inode = int(sys.argv[3])
output_name = sys.argv[4]
temp_name = sys.argv[5]
expected_size = int(sys.argv[6])
payload = sys.stdin.buffer.read(expected_size + 1)
if len(payload) != expected_size:
    raise SystemExit(2)
parent = os.fstat(parent_descriptor)
if (
    parent.st_dev != expected_device
    or parent.st_ino != expected_inode
    or not stat.S_ISDIR(parent.st_mode)
    or parent.st_uid != os.getuid()
    or stat.S_IMODE(parent.st_mode) & 0o077
):
    raise SystemExit(2)
try:
    existing = os.stat(output_name, dir_fd=parent_descriptor, follow_symlinks=False)
except FileNotFoundError:
    existing = None
if existing is not None and (
    not stat.S_ISREG(existing.st_mode)
    or existing.st_nlink != 1
    or stat.S_IMODE(existing.st_mode) != 0o600
):
    raise SystemExit(2)
descriptor = None
try:
    descriptor = os.open(
        temp_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent_descriptor,
    )
    os.fchmod(descriptor, 0o600)
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("incomplete write")
        view = view[written:]
    os.fsync(descriptor)
    written_info = os.fstat(descriptor)
    if (
        not stat.S_ISREG(written_info.st_mode)
        or written_info.st_nlink != 1
        or stat.S_IMODE(written_info.st_mode) != 0o600
        or written_info.st_size != expected_size
    ):
        raise OSError("unsafe temporary")
    os.close(descriptor)
    descriptor = None
    os.replace(
        temp_name,
        output_name,
        src_dir_fd=parent_descriptor,
        dst_dir_fd=parent_descriptor,
    )
    os.fsync(parent_descriptor)
    published = os.stat(output_name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        not stat.S_ISREG(published.st_mode)
        or published.st_nlink != 1
        or stat.S_IMODE(published.st_mode) != 0o600
        or published.st_size != expected_size
    ):
        raise OSError("unsafe publication")
finally:
    if descriptor is not None:
        os.close(descriptor)
    try:
        os.unlink(temp_name, dir_fd=parent_descriptor)
    except FileNotFoundError:
        pass
'''


def publish_snapshot(
    output: Path,
    parent_descriptor: int,
    payload: bytes,
    max_snapshot_bytes: int,
    source_roots: Iterable[AnchoredDirectory],
    observation: Observation,
) -> None:
    if len(payload) > max_snapshot_bytes:
        raise ProducerError("validated snapshot exceeds the application model size bound")
    retained_source_roots = tuple(source_roots)
    observation.prove_unchanged()
    reject_source_repository_parent(parent_descriptor, retained_source_roots)
    parent_info = os.fstat(parent_descriptor)
    temp_name = f".workstack-snapshot.{os.getpid()}.{os.urandom(8).hex()}"
    parent_path = output.parent
    try:
        argv = sandboxed_python_argv(
            PUBLISH_BOUNDARY_PROGRAM,
            read_paths=(parent_path,),
            write_paths=(parent_path, parent_path / temp_name, output),
            denied_write_roots=(root.path for root in retained_source_roots),
        )
        argv.extend(
            (
                str(parent_descriptor),
                str(parent_info.st_dev),
                str(parent_info.st_ino),
                output.name,
                temp_name,
                str(len(payload)),
            )
        )
        run_bounded(
            argv,
            {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"},
            timeout=MODEL_TIMEOUT_SECONDS,
            cap=1,
            pass_descriptors=(parent_descriptor,),
            input_payload=payload,
            discard_stderr=True,
        )
    except ProducerError as exc:
        raise ProducerError("private snapshot publication boundary failed") from exc
    published = os.stat(output.name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        not stat.S_ISREG(published.st_mode)
        or published.st_nlink != 1
        or stat.S_IMODE(published.st_mode) != 0o600
        or published.st_size != len(payload)
    ):
        raise ProducerError("published snapshot failed its final safety check")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="fm-workstack-compass-snapshot.py",
        description=(
            "Collect and project sanitized local evidence, ask Workstack Compass to "
            "validate it, then atomically publish without running the application."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "The Workstack executable model owns schema validation. "
            "Project roots are explicit NAME=PATH identity bindings and are never discovered. "
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
    observation = Observation()
    try:
        home = active_home(script_root, observation)
        model, workstack_root = load_workstack_model(
            Path(arguments.workstack_root).expanduser(), observation
        )
        registry_payload = observation.read_under(
            home, ("data", "projects.md"), MAX_REGISTRY_BYTES, missing_ok=True
        )
        registered = parse_registry(registry_payload)
        bindings = bind_project_roots(
            arguments.project_root, set(registered), observation
        )
        project_sources = inspect_project_sources(registered, bindings, observation)
        backlog_payload = observation.read_under(
            home, ("data", "backlog.md"), MAX_BACKLOG_BYTES, missing_ok=True
        )
        reader_boundary = (
            tasks_axi_boundary(
                os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                observation,
                home.path / "data",
            )
            if backlog_payload is not None
            else None
        )
        source_roots = [
            workstack_root,
            *(binding.root for binding in bindings.values()),
            *(reader_boundary.source_roots if reader_boundary is not None else ()),
        ]
        output, parent_descriptor = prepare_output(
            home,
            arguments.output,
            source_roots,
            observation,
        )
        backlog_tasks = read_backlog_tasks(
            backlog_payload,
            reader_boundary,
            output,
            parent_descriptor,
            source_roots,
            observation,
        )
        workers, meta_present, omitted_task_evidence = collect_workers(
            home, observation, backlog_tasks, set(registered)
        )
        evidence = build_evidence(
            registered,
            workers,
            registry_payload is not None,
            backlog_payload is not None,
            meta_present,
            omitted_task_evidence,
            project_sources,
        )
        document = project_document(model, evidence)
        observation.prove_unchanged()
        payload = (
            json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        ).encode("utf-8")
        publish_snapshot(
            output,
            parent_descriptor,
            payload,
            model.max_snapshot_bytes,
            source_roots,
            observation,
        )
        launch = (
            f"cd {shlex.quote(os.fspath(workstack_root.path))} && "
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
        observation.close()


if __name__ == "__main__":
    raise SystemExit(main())

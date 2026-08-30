#!/usr/bin/env python3
import ctypes
import errno
import fcntl
import hashlib
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import time


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def valid_name(name):
    return bool(name) and name not in (".", "..") and "/" not in name and "\0" not in name


def valid_token(token):
    return bool(token) and len(token) <= 256 and all(char.isalnum() or char in ".:_-" for char in token)


def open_owned_dir(path, expected):
    flags = os.O_RDONLY | os.O_DIRECTORY
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open owned directory {path}: {exc.strerror}")
    info = os.fstat(fd)
    actual = f"{info.st_dev}:{info.st_ino}"
    if actual != expected:
        os.close(fd)
        fail(f"owned directory was replaced: {path}")
    return fd


def open_source(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open publication source {path}: {exc.strerror}")
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(fd)
        fail(f"publication source is unsafe: {path}")
    return fd, info


def snapshot_path(path, maximum):
    parent, name = os.path.split(path)
    if not valid_name(name):
        fail(f"publication source name is unsafe: {path}")
    parent = parent or "."
    parent_flags = os.O_RDONLY | os.O_DIRECTORY
    parent_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_fd = os.open(parent, parent_flags)
    except OSError as exc:
        fail(f"cannot open publication source parent {parent}: {exc.strerror}")
    source_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_fd = os.open(name, source_flags, dir_fd=parent_fd)
    except OSError as exc:
        os.close(parent_fd)
        fail(f"cannot open publication source {path}: {exc.strerror}")
    source_info = os.fstat(source_fd)
    if not stat.S_ISREG(source_info.st_mode) or source_info.st_nlink != 1:
        os.close(source_fd)
        os.close(parent_fd)
        fail(f"publication source is unsafe: {path}")
    if source_info.st_size > maximum:
        os.close(source_fd)
        os.close(parent_fd)
        fail(f"publication source exceeds {maximum} bytes: {path}")
    before = state_from_info(source_info)
    try:
        with tempfile.SpooledTemporaryFile(max_size=1048576) as payload:
            total = 0
            while True:
                chunk = os.read(source_fd, 131072)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    fail(f"publication source exceeds {maximum} bytes: {path}")
                payload.write(chunk)
            if state_from_info(os.fstat(source_fd)) != before:
                fail(f"publication source changed during snapshot: {path}")
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                fail(f"publication source changed during snapshot: {path}")
            if state_from_info(current) != before:
                fail(f"publication source changed during snapshot: {path}")
            payload.seek(0)
            while True:
                chunk = payload.read(131072)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    finally:
        os.close(source_fd)
        os.close(parent_fd)


def copy_to_new(source, directory_fd, name):
    source_fd, source_info = open_source(source)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        target_fd = os.open(name, flags, stat.S_IMODE(source_info.st_mode), dir_fd=directory_fd)
    except OSError as exc:
        os.close(source_fd)
        raise exc
    try:
        while True:
            chunk = os.read(source_fd, 131072)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(target_fd, view)
                view = view[written:]
        os.fchmod(target_fd, stat.S_IMODE(source_info.st_mode))
        os.fsync(target_fd)
    finally:
        os.close(target_fd)
        os.close(source_fd)


def remove(directory_fd, name):
    try:
        os.unlink(name, dir_fd=directory_fd)
    except FileNotFoundError:
        pass


def raw_entry_state(directory_fd, name):
    try:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "absent"
    kind = "regular" if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 else "unsafe"
    return ":".join([
        kind,
        str(info.st_dev),
        str(info.st_ino),
        str(info.st_mode),
        str(info.st_nlink),
        str(info.st_size),
        str(info.st_mtime_ns),
        str(info.st_ctime_ns),
    ])


def entry_state(directory_fd, name):
    state = raw_entry_state(directory_fd, name)
    if state.startswith("unsafe:"):
        fail(f"owned destination entry is unsafe: {name}")
    return state


def entry_digest(directory_fd, name, allowed_links=(1,)):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink not in allowed_links:
            fail(f"owned destination entry is unsafe: {name}")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 131072)
            if not chunk:
                break
            digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(fd)


def file_digest(directory_fd, name):
    return entry_digest(directory_fd, name)


def state_from_info(info):
    kind = "regular" if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 else "unsafe"
    return ":".join([
        kind,
        str(info.st_dev),
        str(info.st_ino),
        str(info.st_mode),
        str(info.st_nlink),
        str(info.st_size),
        str(info.st_mtime_ns),
        str(info.st_ctime_ns),
    ])


def exact_entry_matches(directory_fd, name, expected_state, expected_digest):
    if entry_state(directory_fd, name) != expected_state:
        return False
    return expected_state != "absent" and file_digest(directory_fd, name) == expected_digest


def read_exact(directory_fd, name, expected_state, expected_digest):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        before = state_from_info(os.fstat(fd))
        if before != expected_state or not before.startswith("regular:"):
            fail(f"owned source changed before snapshot: {name}")
        digest = hashlib.sha256()
        with tempfile.SpooledTemporaryFile(max_size=1048576) as payload:
            while True:
                chunk = os.read(fd, 131072)
                if not chunk:
                    break
                payload.write(chunk)
                digest.update(chunk)
            if digest.hexdigest() != expected_digest:
                fail(f"owned source content changed before snapshot: {name}")
            if state_from_info(os.fstat(fd)) != expected_state:
                fail(f"owned source changed during snapshot: {name}")
            payload.seek(0)
            while True:
                chunk = payload.read(131072)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    finally:
        os.close(fd)


def conditional_remove(directory_fd, name, expected_state, expected_digest=None, allow_hardlink=False):
    actual = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if actual != expected_state:
        fail(f"owned destination changed before removal: {name}")
    if actual == "absent":
        return
    if allow_hardlink:
        fields = actual.split(":")
        if fields[0] not in ("regular", "unsafe") or not stat.S_ISREG(int(fields[3])):
            fail(f"owned removal staging entry is unsafe: {name}")
    elif expected_digest is not None and file_digest(directory_fd, name) != expected_digest:
        fail(f"owned destination content changed before removal: {name}")
    current = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if current != expected_state:
        fail(f"owned destination changed before removal: {name}")
    os.unlink(name, dir_fd=directory_fd)
    os.fsync(directory_fd)


def read_remove_journal(directory_fd, journal, name):
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2048:
        os.close(fd)
        fail(f"owned removal journal is unsafe: {journal}")
    try:
        payload = os.read(fd, 2049).decode("ascii", "strict")
    except UnicodeError:
        fail(f"owned removal journal is malformed: {journal}")
    finally:
        os.close(fd)
    lines = payload.splitlines()
    retired_prefix = f".{name}.remove-retired."
    if len(lines) != 3 or lines[0] != "v1" or not valid_name(lines[1]) \
            or not lines[1].startswith(retired_prefix) \
            or len(lines[1]) <= len(retired_prefix):
        fail(f"owned removal journal is malformed: {journal}")
    commitment = lines[2].split("\t")
    if len(commitment) != 2:
        fail(f"owned removal journal is malformed: {journal}")
    expected_state, expected_digest = commitment
    state_fields = expected_state.split(":")
    retired_token = lines[1][len(retired_prefix):]
    if len(state_fields) != 8 or state_fields[0] not in ("regular", "unsafe") \
            or any(not field.isdigit() for field in state_fields[1:]) \
            or not stat.S_ISREG(int(state_fields[3])) \
            or int(state_fields[4]) not in (1, 2) \
            or (state_fields[0] == "regular") != (int(state_fields[4]) == 1) \
            or len(retired_token) not in (16, 32) \
            or any(char not in "0123456789abcdef" for char in retired_token):
        fail(f"owned removal journal is malformed: {journal}")
    if len(expected_digest) != 64 or any(char not in "0123456789abcdef" for char in expected_digest):
        fail(f"owned removal journal is malformed: {journal}")
    return lines[1], expected_state, expected_digest


def publish_remove_journal(directory_fd, journal, retired, expected_state, expected_digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v1\n{retired}\n{expected_state}\t{expected_digest}\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short removal journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def retired_entry_matches(directory_fd, retired, expected_state, expected_digest):
    expected_links = int(expected_state.split(":")[4])
    return state_matches(raw_entry_state(directory_fd, retired), expected_state) \
        and entry_digest(directory_fd, retired, (expected_links,)) == expected_digest


def recover_remove(directory_fd, name):
    journal = f".{name}.remove-journal"
    loaded = read_remove_journal(directory_fd, journal, name)
    if loaded is None:
        return
    retired, expected_state, expected_digest = loaded
    target_state = raw_entry_state(directory_fd, name)
    retired_state = raw_entry_state(directory_fd, retired)
    if retired_state == "absent":
        if target_state != "absent" and target_state != expected_state:
            fail(f"owned destination changed during removal: {name}")
        remove(directory_fd, journal)
        os.fsync(directory_fd)
        return
    if target_state != "absent":
        fail(f"owned destination changed during removal: {name}")
    if retired_entry_matches(directory_fd, retired, expected_state, expected_digest):
        remove(directory_fd, retired)
        remove(directory_fd, journal)
        os.fsync(directory_fd)
        return
    atomic_rename(directory_fd, retired, name, False)
    remove(directory_fd, journal)
    os.fsync(directory_fd)
    fail(f"owned destination changed before removal: {name}")


def remove_entry(directory_fd, name, expected_state, expected_digest, allow_hardlink=False):
    recover_remove(directory_fd, name)
    actual_state = raw_entry_state(directory_fd, name) if allow_hardlink else entry_state(directory_fd, name)
    if actual_state != expected_state:
        fail(f"owned destination changed before removal: {name}")
    if expected_state == "absent":
        return
    expected_links = int(expected_state.split(":")[4])
    if expected_links != 1 and not allow_hardlink:
        fail(f"owned destination entry is unsafe: {name}")
    if entry_digest(directory_fd, name, (expected_links,)) != expected_digest:
        fail(f"owned destination content changed before removal: {name}")
    retired = f".{name}.remove-retired.{secrets.token_hex(16)}"
    journal = f".{name}.remove-journal"
    publish_remove_journal(directory_fd, journal, retired, expected_state, expected_digest)
    atomic_rename(directory_fd, name, retired, False)
    os.fsync(directory_fd)
    recover_remove(directory_fd, name)


def read_teardown_journal(directory_fd, name):
    journal = f".{name}.teardown-journal"
    quarantine = f".{name}.teardown-quarantine"
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2048:
        os.close(fd)
        fail(f"owned teardown journal is unsafe: {journal}")
    try:
        payload = os.read(fd, 2049).decode("ascii", "strict")
    except UnicodeError:
        fail(f"owned teardown journal is malformed: {journal}")
    finally:
        os.close(fd)
    lines = payload.splitlines()
    if len(lines) != 3 or lines[0] != "v1" or lines[1] != quarantine:
        fail(f"owned teardown journal is malformed: {journal}")
    commitment = lines[2].split("\t")
    if len(commitment) != 2:
        fail(f"owned teardown journal is malformed: {journal}")
    expected_state, expected_digest = commitment
    fields = expected_state.split(":")
    if len(fields) != 8 or fields[0] != "regular" \
            or any(not field.isdigit() for field in fields[1:]) \
            or int(fields[4]) != 1 \
            or len(expected_digest) != 64 \
            or any(char not in "0123456789abcdef" for char in expected_digest):
        fail(f"owned teardown journal is malformed: {journal}")
    return journal, quarantine, expected_state, expected_digest


def publish_teardown_journal(directory_fd, name, expected_state, expected_digest):
    journal = f".{name}.teardown-journal"
    quarantine = f".{name}.teardown-quarantine"
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v1\n{quarantine}\n{expected_state}\t{expected_digest}\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short teardown journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)
    return journal, quarantine, expected_state, expected_digest


def teardown_quarantine(directory_fd, name, expected_state, expected_digest):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        if entry_state(directory_fd, name) != expected_state \
                or file_digest(directory_fd, name) != expected_digest:
            fail(f"owned teardown receipt changed before quarantine: {name}")
        quarantine = f".{name}.teardown-quarantine"
        if raw_entry_state(directory_fd, quarantine) != "absent":
            fail(f"owned teardown quarantine conflicts: {quarantine}")
        loaded = publish_teardown_journal(
            directory_fd, name, expected_state, expected_digest
        )
    journal, quarantine, journal_state, journal_digest = loaded
    if journal_state != expected_state or journal_digest != expected_digest:
        fail(f"owned teardown receipt does not match retained authorization: {name}")
    target_state = raw_entry_state(directory_fd, name)
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if target_state != "absent":
        if not retired_entry_matches(
                directory_fd, name, expected_state, expected_digest
        ) or quarantine_state != "absent":
            fail(f"owned teardown receipt changed during quarantine: {name}")
        atomic_rename(directory_fd, name, quarantine, False)
        os.fsync(directory_fd)
    elif not retired_entry_matches(
            directory_fd, quarantine, expected_state, expected_digest
    ):
        fail(f"owned teardown quarantine changed: {quarantine}")
    return journal, quarantine, expected_state, expected_digest


def teardown_restore(directory_fd, name):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        return
    journal, quarantine, expected_state, expected_digest = loaded
    target_state = raw_entry_state(directory_fd, name)
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if target_state == "absent":
        if not retired_entry_matches(
                directory_fd, quarantine, expected_state, expected_digest
        ):
            fail(f"owned teardown quarantine changed before restore: {quarantine}")
        atomic_rename(directory_fd, quarantine, name, False)
        os.fsync(directory_fd)
    elif not retired_entry_matches(
            directory_fd, name, expected_state, expected_digest
    ) or quarantine_state != "absent":
        fail(f"owned teardown receipt changed before restore: {name}")
    remove(directory_fd, journal)
    os.fsync(directory_fd)


def teardown_finalize(directory_fd, name):
    loaded = read_teardown_journal(directory_fd, name)
    if loaded is None:
        fail(f"owned teardown authorization is absent: {name}")
    journal, quarantine, expected_state, expected_digest = loaded
    if raw_entry_state(directory_fd, name) != "absent":
        fail(f"owned teardown receipt was recreated before commit: {name}")
    quarantine_state = raw_entry_state(directory_fd, quarantine)
    if quarantine_state != "absent":
        if not retired_entry_matches(
                directory_fd, quarantine, expected_state, expected_digest
        ):
            fail(f"owned teardown quarantine changed before commit: {quarantine}")
        quarantine_current = entry_state(directory_fd, quarantine)
        conditional_remove(
            directory_fd, quarantine, quarantine_current, expected_digest
        )
    remove(directory_fd, journal)
    os.fsync(directory_fd)


def operation_lock(directory_fd, name):
    del name
    fd = os.dup(directory_fd)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def atomic_rename(directory_fd, first, second, exchange):
    libc = ctypes.CDLL(None, use_errno=True)
    first_b = os.fsencode(first)
    second_b = os.fsencode(second)
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        function = libc.renameatx_np
        flag = 0x00000002 if exchange else 0x00000004
    elif hasattr(libc, "renameat2"):
        function = libc.renameat2
        flag = 0x2 if exchange else 0x1
    else:
        fail("conditional destination rename is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(directory_fd, first_b, directory_fd, second_b, flag) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def state_matches(actual, expected):
    return actual.rsplit(":", 1)[0] == expected.rsplit(":", 1)[0]


def read_replace_journal(directory_fd, journal):
    try:
        fd = os.open(
            journal,
            os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            fail(f"owned replacement journal is unsafe: {journal}")
        raise
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 2048:
        os.close(fd)
        fail(f"owned replacement journal is unsafe: {journal}")
    try:
        payload = os.read(fd, 2049).decode("ascii", "strict")
    except UnicodeError:
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    lines = payload.splitlines()
    if len(lines) != 5:
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    header = lines[0].split("\t")
    if len(header) != 3 or header[0] != "v3" or not valid_name(header[1]) or not valid_name(header[2]):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    expected_state = lines[1]
    expected_digest = lines[2]
    if expected_state == "absent":
        if expected_digest != "-":
            os.close(fd)
            fail(f"owned replacement journal is malformed: {journal}")
    elif not expected_state.startswith("regular:") \
            or len(expected_digest) != 64 \
            or any(char not in "0123456789abcdef" for char in expected_digest):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    candidate_state = lines[3]
    candidate_digest = lines[4]
    if not candidate_state.startswith("regular:"):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    if len(candidate_digest) != 64 or any(char not in "0123456789abcdef" for char in candidate_digest):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    return (
        fd, header[1], header[2], expected_state, expected_digest,
        candidate_state, candidate_digest,
    )


def publish_replace_journal(
        directory_fd, journal, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = (
            f"v3\t{stage}\t{previous}\n{expected_state}\n{expected_digest}\n"
            f"{candidate_state}\n{candidate_digest}\n"
        ).encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short replacement journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def recover_replace(directory_fd, name):
    journal = f".{name}.replace-journal"
    stage = f".{name}.replace-candidate"
    previous = f".{name}.replace-previous"
    loaded = read_replace_journal(directory_fd, journal)
    if loaded is None:
        stage_state = raw_entry_state(directory_fd, stage)
        if stage_state != "absent":
            if not stage_state.startswith("regular:"):
                fail(f"owned replacement candidate is unsafe: {stage}")
            remove(directory_fd, stage)
            os.fsync(directory_fd)
        if raw_entry_state(directory_fd, previous) != "absent":
            fail(f"owned replacement predecessor has no journal: {previous}")
        return
    (
        journal_fd, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest,
    ) = loaded
    try:
        target_state = raw_entry_state(directory_fd, name)
        stage_state = raw_entry_state(directory_fd, stage)
        previous_state = raw_entry_state(directory_fd, previous)
        if previous_state == "absent" and stage_state == "absent" \
                and state_matches(target_state, candidate_state) \
                and file_digest(directory_fd, name) == candidate_digest:
            os.close(journal_fd)
            journal_fd = None
            remove(directory_fd, journal)
            os.fsync(directory_fd)
            return
        if previous_state != "absent" \
                and (not state_matches(previous_state, expected_state)
                     or file_digest(directory_fd, previous) != expected_digest):
            if target_state == "absent":
                atomic_rename(directory_fd, previous, name, False)
            elif stage_state == "absent" \
                    and state_matches(target_state, candidate_state) \
                    and file_digest(directory_fd, name) == candidate_digest:
                atomic_rename(directory_fd, name, stage, False)
                atomic_rename(directory_fd, previous, name, False)
            fail(f"owned destination changed during publication: {name}")
        if expected_state != "absent" and previous_state == "absent":
            if target_state != expected_state \
                    or file_digest(directory_fd, name) != expected_digest:
                fail(f"owned destination changed during publication: {name}")
            atomic_rename(directory_fd, name, previous, False)
            previous_state = raw_entry_state(directory_fd, previous)
            target_state = "absent"
            if not state_matches(previous_state, expected_state) \
                    or file_digest(directory_fd, previous) != expected_digest:
                atomic_rename(directory_fd, previous, name, False)
                fail(f"owned destination changed during publication: {name}")
        if target_state == "absent":
            if not state_matches(stage_state, candidate_state) \
                    or file_digest(directory_fd, stage) != candidate_digest:
                fail(f"owned replacement candidate changed during publication: {stage}")
            atomic_rename(directory_fd, stage, name, False)
            target_state = raw_entry_state(directory_fd, name)
            stage_state = "absent"
        if not state_matches(target_state, candidate_state) or stage_state != "absent" \
                or file_digest(directory_fd, name) != candidate_digest:
            fail(f"owned destination changed during publication: {name}")
        if previous_state != "absent":
            if not state_matches(raw_entry_state(directory_fd, previous), expected_state) \
                    or file_digest(directory_fd, previous) != expected_digest:
                atomic_rename(directory_fd, name, stage, False)
                atomic_rename(directory_fd, previous, name, False)
                fail(f"owned destination changed during publication: {name}")
            remove(directory_fd, previous)
            os.fsync(directory_fd)
        if not state_matches(raw_entry_state(directory_fd, name), candidate_state) \
                or file_digest(directory_fd, name) != candidate_digest:
            fail(f"owned destination changed before publication commit: {name}")
        os.close(journal_fd)
        journal_fd = None
        remove(directory_fd, journal)
        os.fsync(directory_fd)
    finally:
        if journal_fd is not None:
            os.close(journal_fd)


def replace_entry(directory_fd, name, source, expected_state, expected_digest):
    recover_replace(directory_fd, name)
    if entry_state(directory_fd, name) != expected_state:
        fail(f"owned destination changed before publication: {name}")
    if expected_state == "absent":
        if expected_digest != "-":
            fail("absent replacement destination has a digest")
    elif file_digest(directory_fd, name) != expected_digest:
        fail(f"owned destination changed before publication: {name}")
    stage = f".{name}.replace-candidate"
    previous = f".{name}.replace-previous"
    journal = f".{name}.replace-journal"
    copy_to_new(source, directory_fd, stage)
    candidate_state = raw_entry_state(directory_fd, stage)
    if not candidate_state.startswith("regular:"):
        fail(f"owned replacement candidate is unsafe: {stage}")
    candidate_digest = file_digest(directory_fd, stage)
    publish_replace_journal(
        directory_fd, journal, stage, previous, expected_state, expected_digest,
        candidate_state, candidate_digest
    )
    recover_replace(directory_fd, name)


def allowed_no_clobber_staging(name, staging):
    return staging in (f"{name}.publishing", f".{name}.scaffold-publishing")


def read_no_clobber_journal(directory_fd, journal, name, staging=None):
    recover_remove(directory_fd, journal)
    try:
        fd = os.open(
            journal,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    info = os.fstat(fd)
    journal_state = state_from_info(info)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 1024:
        os.close(fd)
        fail(f"publication journal is unsafe: {journal}")
    try:
        payload_bytes = os.read(fd, 1025)
        payload = payload_bytes.decode("ascii", "strict")
        after = os.fstat(fd)
        current = os.stat(journal, dir_fd=directory_fd, follow_symlinks=False)
        if state_from_info(after) != journal_state or state_from_info(current) != journal_state:
            fail(f"publication journal changed during validation: {journal}")
    except UnicodeError:
        fail(f"publication journal is malformed: {journal}")
    finally:
        os.close(fd)
    journal_digest = hashlib.sha256(payload_bytes).hexdigest()
    lines = payload.splitlines()
    pin_prefix = f".{name}.no-clobber-pin."
    if len(lines) == 4 and lines[0] == "v1":
        phase = "publishing"
    elif len(lines) == 5 and lines[0] == "v2" and lines[4] in ("publishing", "conflict"):
        phase = lines[4]
    else:
        fail(f"publication journal is malformed: {journal}")
    if not valid_name(lines[1]) or not allowed_no_clobber_staging(name, lines[1]) \
            or (staging is not None and lines[1] != staging) \
            or not valid_name(lines[2]) or not lines[2].startswith(pin_prefix) \
            or len(lines[2]) <= len(pin_prefix) \
            or len(lines[3]) != 64 \
            or any(char not in "0123456789abcdef" for char in lines[3]):
        fail(f"publication journal is malformed: {journal}")
    return lines[1], lines[2], lines[3], phase, journal_state, journal_digest


def publish_no_clobber_journal(directory_fd, journal, name, staging, pin, digest):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v2\n{staging}\n{pin}\n{digest}\npublishing\n".encode("ascii")
        if os.write(fd, payload) != len(payload):
            raise OSError(errno.EIO, "short publication journal write")
        os.fsync(fd)
        atomic_rename(directory_fd, temporary, journal, False)
        published = True
        os.fsync(directory_fd)
    finally:
        os.close(fd)
        if not published:
            remove(directory_fd, temporary)


def opened_entry(directory_fd, name, digest, allowed_links):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink not in allowed_links:
            fail(f"publication entry is unsafe: {name}")
        actual_digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 131072)
            if not chunk:
                break
            actual_digest.update(chunk)
        after = os.fstat(fd)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino) \
                or (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino) \
                or not stat.S_ISREG(current.st_mode) \
                or current.st_nlink not in allowed_links \
                or actual_digest.hexdigest() != digest:
            fail(f"publication entry changed during validation: {name}")
        return before
    finally:
        os.close(fd)


def same_inode(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def rollback_no_clobber_conflict(
        directory_fd, name, staging, pin, digest, journal,
        journal_state, journal_digest):
    recover_remove(directory_fd, pin)
    recover_remove(directory_fd, staging)
    try:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        target_info = None
    try:
        pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pin_info = None
    try:
        staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        staging_info = None
    if pin_info is not None:
        pin_info = opened_entry(directory_fd, pin, digest, (1, 2))
        if target_info is not None and same_inode(target_info, pin_info):
            fail("publication conflict aliases its retained candidate")
    if staging_info is not None:
        staging_info = opened_entry(directory_fd, staging, digest, (1, 2))
        if (target_info is not None and same_inode(target_info, staging_info)) \
                or (pin_info is not None and not same_inode(pin_info, staging_info)):
            fail("publication conflict does not match its retained candidate")
    if pin_info is not None:
        remove_entry(
            directory_fd, pin, state_from_info(pin_info), digest,
            allow_hardlink=True
        )
    if staging_info is not None:
        staging_info = opened_entry(directory_fd, staging, digest, (1,))
        remove_entry(directory_fd, staging, state_from_info(staging_info), digest)
    remove_entry(directory_fd, journal, journal_state, journal_digest)
    os.fsync(directory_fd)


def recover_no_clobber(directory_fd, name, staging=None, source_digest=None,
                       conflict_is_error=False):
    journal = f".{name}.no-clobber-journal"
    loaded = read_no_clobber_journal(directory_fd, journal, name, staging)
    if loaded is None:
        return False
    staging, pin, source_journal_digest, phase, journal_state, journal_digest = loaded
    if source_digest is not None and source_journal_digest != source_digest:
        fail("publication source changed while recovering")
    source_digest = source_journal_digest
    if phase == "conflict":
        rollback_no_clobber_conflict(
            directory_fd, name, staging, pin, source_digest, journal,
            journal_state, journal_digest
        )
        if conflict_is_error:
            raise SystemExit(2)
        return False

    try:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        target_info = None
    try:
        pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pin_info = None
    try:
        staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        staging_info = None

    if target_info is not None and pin_info is None and staging_info is None:
        if not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink != 1:
            fail(f"publication target is unsafe: {name}")
        committed = file_digest(directory_fd, name) == source_digest
        remove_entry(directory_fd, journal, journal_state, journal_digest)
        os.fsync(directory_fd)
        if committed:
            return True
        if conflict_is_error:
            raise SystemExit(2)
        return False

    if target_info is not None \
            and ((pin_info is not None and not same_inode(target_info, pin_info))
                 or (staging_info is not None and not same_inode(target_info, staging_info))):
        rollback_no_clobber_conflict(
            directory_fd, name, staging, pin, source_digest, journal,
            journal_state, journal_digest
        )
        if conflict_is_error:
            raise SystemExit(2)
        return False

    if target_info is None:
        if pin_info is None:
            if staging_info is None:
                fail("publication journal lost its staged candidate")
            opened = opened_entry(directory_fd, staging, source_digest, (1,))
            try:
                os.link(staging, pin, src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd, follow_symlinks=False)
            except FileExistsError:
                fail("publication pin conflicts with another entry")
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
            current_fd = os.open(
                staging,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            try:
                current = os.fstat(current_fd)
            finally:
                os.close(current_fd)
            if not same_inode(opened, pin_info) or not same_inode(opened, current) \
                    or pin_info.st_nlink != 2 or current.st_nlink != 2:
                remove(directory_fd, pin)
                fail("publication staging entry changed while being pinned")
        else:
            if staging_info is None or not same_inode(pin_info, staging_info):
                fail("publication pin is not bound to its staging entry")
            opened_entry(directory_fd, pin, source_digest, (2,))
        try:
            atomic_rename(directory_fd, pin, name, False)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise
            rollback_no_clobber_conflict(
                directory_fd, name, staging, pin, source_digest, journal,
                journal_state, journal_digest
            )
            if conflict_is_error:
                raise SystemExit(2)
            return False
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        pin_info = None

    if not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink not in (1, 2):
        fail(f"publication target is unsafe: {name}")
    opened_entry(directory_fd, name, source_digest, (1, 2))

    if pin_info is None:
        try:
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pin_info = None
    if pin_info is None and staging_info is not None:
        try:
            atomic_rename(directory_fd, staging, pin, False)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
        try:
            pin_info = os.stat(pin, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pin_info = None
    if pin_info is not None:
        target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not same_inode(pin_info, target_info):
            try:
                atomic_rename(directory_fd, pin, staging, False)
            except OSError:
                pass
            fail("publication staging entry changed during commit")
        remove(directory_fd, pin)
    elif staging_info is not None:
        fail("publication staging entry changed during commit")

    opened_entry(directory_fd, name, source_digest, (1,))
    remove_entry(directory_fd, journal, journal_state, journal_digest)
    os.fsync(directory_fd)
    return True


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_start_identity(pid):
    if sys.platform.startswith("linux"):
        try:
            payload = open(f"/proc/{pid}/stat", "r", encoding="ascii").read()
            fields = payload.rsplit(")", 1)[1].split()
            return f"linux:{fields[19]}"
        except (OSError, IndexError, UnicodeError):
            return None
    try:
        output = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return f"ps:{output.replace(' ', '_')}" if output else None


def lock_owner(directory_fd, name):
    try:
        lock_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise SystemExit(3)
        raise
    try:
        lock_info = os.fstat(lock_fd)
        entries = os.listdir(lock_fd)
        try:
            owner_fd = os.open(
                "owner",
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=lock_fd,
            )
        except FileNotFoundError:
            return lock_info, None, None, None, entries
        try:
            owner_info = os.fstat(owner_fd)
            if not stat.S_ISREG(owner_info.st_mode) or owner_info.st_nlink != 1 or owner_info.st_size > 512:
                fail(f"owned lock owner is unsafe: {name}/owner")
            try:
                payload = os.read(owner_fd, 513).decode("ascii", "strict")
            except UnicodeError:
                fail(f"owned lock owner is malformed: {name}/owner")
        finally:
            os.close(owner_fd)
        fields = payload.rstrip("\n").split("\t")
        if len(fields) not in (2, 3) or not fields[0].isdigit() or not valid_token(fields[1]):
            fail(f"owned lock owner is malformed: {name}/owner")
        owner_start = fields[2] if len(fields) == 3 else None
        if owner_start is not None and not valid_token(owner_start):
            fail(f"owned lock owner is malformed: {name}/owner")
        if sorted(entries) != ["owner"]:
            fail(f"owned lock contains unexpected entries: {name}")
        return lock_info, int(fields[0]), fields[1], owner_start, entries
    finally:
        os.close(lock_fd)


def create_lock(directory_fd, name, pid, token):
    candidate = f".{name}.candidate.{os.getpid()}.{secrets.token_hex(8)}"
    os.mkdir(candidate, 0o700, dir_fd=directory_fd)
    lock_fd = os.open(
        candidate,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    published = False
    try:
        owner_fd = os.open(
            "owner",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=lock_fd,
        )
        try:
            start_identity = process_start_identity(pid)
            if start_identity is None or not valid_token(start_identity):
                raise OSError(errno.ESRCH, "cannot identify lock owner process")
            payload = f"{pid}\t{token}\t{start_identity}\n".encode("ascii")
            if os.write(owner_fd, payload) != len(payload):
                raise OSError(errno.EIO, "short lock owner write")
            os.fsync(owner_fd)
        finally:
            os.close(owner_fd)
        os.fsync(lock_fd)
        try:
            atomic_rename(directory_fd, candidate, name, False)
        except OSError as exc:
            if exc.errno in (errno.EEXIST, errno.ENOTEMPTY):
                raise FileExistsError(exc.errno, exc.strerror)
            raise
        published = True
        os.fsync(directory_fd)
    finally:
        if not published:
            try:
                os.unlink("owner", dir_fd=lock_fd)
            except OSError:
                pass
        os.close(lock_fd)
        if not published:
            try:
                os.rmdir(candidate, dir_fd=directory_fd)
            except OSError:
                pass


def retire_lock(directory_fd, name, quarantine, expected_info):
    current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (expected_info.st_dev, expected_info.st_ino):
        raise FileNotFoundError(name)
    os.rename(name, quarantine, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    retired = os.stat(quarantine, dir_fd=directory_fd, follow_symlinks=False)
    if (retired.st_dev, retired.st_ino) != (expected_info.st_dev, expected_info.st_ino):
        fail(f"owned lock changed during retirement: {name}")
    lock_fd = os.open(
        quarantine,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        entries = os.listdir(lock_fd)
        if entries not in (["owner"], []):
            fail(f"owned lock contains unexpected entries: {name}")
        if entries:
            os.unlink("owner", dir_fd=lock_fd)
    finally:
        os.close(lock_fd)
    os.rmdir(quarantine, dir_fd=directory_fd)


def lock_try(directory_fd, name, pid, token, stale_after):
    try:
        create_lock(directory_fd, name, pid, token)
        return
    except FileExistsError:
        pass
    details = lock_owner(directory_fd, name)
    if details is None:
        raise SystemExit(2)
    lock_info, owner_pid, owner_token, owner_start, entries = details
    if owner_pid == pid and owner_token == token:
        return
    owner_alive = owner_pid is not None and pid_alive(owner_pid)
    current_start = process_start_identity(owner_pid) if owner_alive else None
    if owner_alive and (owner_start is None or current_start is None or current_start == owner_start):
        raise SystemExit(2)
    if owner_pid is None and entries:
        raise SystemExit(2)
    age = time.time() - lock_info.st_mtime
    if age < stale_after:
        raise SystemExit(2)
    quarantine = f".{name}.retiring.{os.getpid()}.{secrets.token_hex(8)}"
    try:
        retire_lock(directory_fd, name, quarantine, lock_info)
    except FileNotFoundError:
        raise SystemExit(2)
    try:
        create_lock(directory_fd, name, pid, token)
    except FileExistsError:
        raise SystemExit(2)


def lock_held(directory_fd, name, pid, token):
    details = lock_owner(directory_fd, name)
    if details is None:
        fail(f"owned lock authorization is absent: {name}")
    _, owner_pid, owner_token, owner_start, _ = details
    if owner_pid != pid or owner_token != token:
        fail(f"owned lock authorization is mismatched: {name}")
    current_start = process_start_identity(owner_pid)
    if owner_start is None or current_start is None or current_start != owner_start:
        fail(f"owned lock authorization process is stale: {name}")


def lock_release(directory_fd, name, pid, token):
    details = lock_owner(directory_fd, name)
    if details is None:
        return
    _, owner_pid, owner_token, _, _ = details
    if owner_pid != pid or owner_token != token:
        return
    lock_fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        entries = os.listdir(lock_fd)
        if entries != ["owner"]:
            fail(f"owned lock contains unexpected entries: {name}")
        os.unlink("owner", dir_fd=lock_fd)
    finally:
        os.close(lock_fd)
    os.rmdir(name, dir_fd=directory_fd)
    os.fsync(directory_fd)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "snapshot-path":
        try:
            maximum = int(sys.argv[3])
        except ValueError:
            fail("snapshot-path maximum size is malformed")
        if maximum < 0:
            fail("snapshot-path maximum size is malformed")
        snapshot_path(sys.argv[2], maximum)
        return
    if len(sys.argv) < 5:
        fail("usage: fm-work-identity-fs.py COMMAND DIRECTORY INODE NAME [ARG]")
    command, directory, expected, name = sys.argv[1:5]
    if not valid_name(name):
        fail("unsafe owned entry name")
    directory_fd = open_owned_dir(directory, expected)
    try:
        if command == "mkdir":
            try:
                os.mkdir(name, 0o700, dir_fd=directory_fd)
            except FileExistsError:
                raise SystemExit(2)
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode):
                fail("created owned entry is not a directory")
            os.fsync(directory_fd)
            print(f"{info.st_dev}:{info.st_ino}")
        elif command == "probe":
            probe = f".{name}.{os.getpid()}.{secrets.token_hex(8)}"
            os.mkdir(probe, 0o700, dir_fd=directory_fd)
            os.rmdir(probe, dir_fd=directory_fd)
        elif command in ("describe", "describe-raw", "describe-digest", "describe-replace"):
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                if command == "describe":
                    print(entry_state(directory_fd, name))
                elif command == "describe-raw":
                    print(raw_entry_state(directory_fd, name))
                else:
                    state = entry_state(directory_fd, name)
                    if state == "absent":
                        if command == "describe-replace":
                            print("absent\t-")
                        else:
                            fail(f"owned destination is absent: {name}")
                    else:
                        print(f"{state}\t{file_digest(directory_fd, name)}")
            finally:
                os.close(mutex_fd)
        elif command == "snapshot":
            if len(sys.argv) != 7:
                fail("snapshot requires expected source state and SHA-256")
            expected_state, expected_digest = sys.argv[5:7]
            if len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest):
                fail("owned snapshot SHA-256 is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                read_exact(directory_fd, name, expected_state, expected_digest)
            finally:
                os.close(mutex_fd)
        elif command in ("remove", "remove-staging"):
            if len(sys.argv) not in (6, 7):
                fail(f"{command} requires expected destination state and optional SHA-256")
            expected_state = sys.argv[5]
            expected_digest = sys.argv[6] if len(sys.argv) == 7 else None
            if expected_digest is not None and (
                    len(expected_digest) != 64
                    or any(char not in "0123456789abcdef" for char in expected_digest)):
                fail("owned removal SHA-256 is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_no_clobber(directory_fd, name)
                recover_replace(directory_fd, name)
                if command == "remove-staging":
                    conditional_remove(
                        directory_fd,
                        name,
                        expected_state,
                        expected_digest,
                        allow_hardlink=True,
                    )
                else:
                    if expected_digest is None:
                        fail("owned removal requires a validated SHA-256")
                    remove_entry(directory_fd, name, expected_state, expected_digest)
            finally:
                os.close(mutex_fd)
        elif command in ("replace", "replace-if-peer"):
            if command == "replace" and len(sys.argv) != 8:
                fail("replace requires a source and exact destination identity")
            if command == "replace-if-peer" and len(sys.argv) != 13:
                fail("replace-if-peer requires source, destination identity, and exact peer identity")
            source, expected_state, expected_digest = sys.argv[5:8]
            if expected_state == "absent":
                if expected_digest != "-":
                    fail("absent replacement destination has a digest")
            elif len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest):
                fail("replacement destination SHA-256 is malformed")
            peer_fd = None
            peer_mutex_fd = None
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "replace-if-peer":
                    peer_directory, peer_inode, peer_name, peer_state, peer_digest = sys.argv[8:13]
                    if not valid_name(peer_name) or len(peer_digest) != 64 \
                            or any(char not in "0123456789abcdef" for char in peer_digest):
                        fail("replacement peer identity is malformed")
                    peer_fd = open_owned_dir(peer_directory, peer_inode)
                    peer_mutex_fd = operation_lock(peer_fd, peer_name)
                    recover_no_clobber(peer_fd, peer_name)
                    recover_replace(peer_fd, peer_name)
                    recover_remove(peer_fd, peer_name)
                    if not exact_entry_matches(peer_fd, peer_name, peer_state, peer_digest):
                        fail(f"owned replacement peer changed before publication: {peer_name}")
                recover_no_clobber(directory_fd, name)
                recover_remove(directory_fd, name)
                replace_entry(directory_fd, name, source, expected_state, expected_digest)
                if command == "replace-if-peer" \
                        and not exact_entry_matches(peer_fd, peer_name, peer_state, peer_digest):
                    fail(f"owned replacement peer changed during publication: {peer_name}")
            finally:
                if peer_mutex_fd is not None:
                    os.close(peer_mutex_fd)
                if peer_fd is not None:
                    os.close(peer_fd)
                os.close(mutex_fd)
        elif command == "no-clobber":
            if len(sys.argv) != 7:
                fail("no-clobber requires a source and staging name")
            source, staging = sys.argv[5:7]
            if not valid_name(staging) or not allowed_no_clobber_staging(name, staging):
                fail("unsafe publication staging name")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_replace(directory_fd, name)
                recover_remove(directory_fd, name)
                source_fd, source_info = open_source(source)
                try:
                    source_digest = hashlib.sha256()
                    while True:
                        chunk = os.read(source_fd, 131072)
                        if not chunk:
                            break
                        source_digest.update(chunk)
                    source_digest = source_digest.hexdigest()
                finally:
                    os.close(source_fd)
                if recover_no_clobber(
                        directory_fd, name, staging, source_digest,
                        conflict_is_error=True):
                    return
                try:
                    staging_info = os.stat(staging, dir_fd=directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    staging_info = None
                try:
                    target_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    target_info = None
                if staging_info is not None:
                    if target_info is not None:
                        if not stat.S_ISREG(staging_info.st_mode) \
                                or not stat.S_ISREG(target_info.st_mode) \
                                or staging_info.st_nlink != 2 \
                                or target_info.st_nlink != 2 \
                                or not same_inode(staging_info, target_info):
                            fail("publication target conflicts with retained staging")
                        opened_entry(directory_fd, staging, source_digest, (2,))
                        opened_entry(directory_fd, name, source_digest, (2,))
                        remove(directory_fd, staging)
                        os.fsync(directory_fd)
                        return
                    opened_entry(directory_fd, staging, source_digest, (1,))
                else:
                    if target_info is not None:
                        raise SystemExit(2)
                    candidate = f".{staging}.copy-candidate.{secrets.token_hex(16)}"
                    try:
                        copy_to_new(source, directory_fd, candidate)
                        atomic_rename(directory_fd, candidate, staging, False)
                    finally:
                        remove(directory_fd, candidate)
                    opened_entry(directory_fd, staging, source_digest, (1,))
                pin = f".{name}.no-clobber-pin.{secrets.token_hex(16)}"
                journal = f".{name}.no-clobber-journal"
                publish_no_clobber_journal(
                    directory_fd, journal, name, staging, pin, source_digest
                )
                recover_no_clobber(
                    directory_fd, name, staging, source_digest,
                    conflict_is_error=True
                )
            finally:
                os.close(mutex_fd)
        elif command == "lock-try":
            if len(sys.argv) != 8:
                fail("lock-try requires pid, token, and stale age")
            pid_text, token, stale_text = sys.argv[5:8]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            try:
                stale_after = float(stale_text)
            except ValueError:
                fail("owned lock stale age is malformed")
            if stale_after < 0:
                fail("owned lock stale age is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                lock_try(directory_fd, name, int(pid_text), token, stale_after)
            finally:
                os.close(mutex_fd)
        elif command == "teardown-quarantine":
            if len(sys.argv) != 7:
                fail("teardown-quarantine requires expected receipt state and SHA-256")
            expected_state, expected_digest = sys.argv[5:7]
            if len(expected_digest) != 64 \
                    or any(char not in "0123456789abcdef" for char in expected_digest):
                fail("teardown receipt SHA-256 is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                _, quarantine, _, _ = teardown_quarantine(
                    directory_fd, name, expected_state, expected_digest
                )
                print(
                    f"{entry_state(directory_fd, quarantine)}"
                    f"\t{file_digest(directory_fd, quarantine)}"
                )
            finally:
                os.close(mutex_fd)
        elif command in ("teardown-restore", "teardown-finalize"):
            if len(sys.argv) != 5:
                fail(f"{command} accepts no additional arguments")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "teardown-restore":
                    teardown_restore(directory_fd, name)
                else:
                    teardown_finalize(directory_fd, name)
            finally:
                os.close(mutex_fd)
        elif command in ("lock-held", "lock-release"):
            if len(sys.argv) != 7:
                fail(f"{command} requires pid and token")
            pid_text, token = sys.argv[5:7]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                if command == "lock-held":
                    lock_held(directory_fd, name, int(pid_text), token)
                else:
                    lock_release(directory_fd, name, int(pid_text), token)
            finally:
                os.close(mutex_fd)
        else:
            fail(f"unknown command: {command}")
    except OSError as exc:
        if exc.errno == errno.EEXIST and command == "no-clobber":
            raise SystemExit(2)
        fail(f"owned {command} failed for {directory}/{name}: {exc.strerror}")
    finally:
        os.close(directory_fd)


if __name__ == "__main__":
    main()

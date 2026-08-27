#!/usr/bin/env python3
import ctypes
import errno
import fcntl
import os
import secrets
import stat
import subprocess
import sys
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
    if len(lines) not in (2, 3):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    header = lines[0].split("\t")
    if len(header) != 3 or header[0] != "v1" or not valid_name(header[1]) or not valid_name(header[2]):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    expected = lines[1]
    if expected != "absent" and not expected.startswith("regular:"):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    candidate_state = lines[2] if len(lines) == 3 else None
    if candidate_state is not None and not candidate_state.startswith("regular:"):
        os.close(fd)
        fail(f"owned replacement journal is malformed: {journal}")
    return fd, header[1], header[2], expected, candidate_state


def publish_replace_journal(directory_fd, journal, stage, previous, expected_state, candidate_state):
    temporary = f".{journal}.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600, dir_fd=directory_fd)
    published = False
    try:
        payload = f"v1\t{stage}\t{previous}\n{expected_state}\n{candidate_state}\n".encode("ascii")
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
    journal_fd, stage, previous, expected_state, candidate_state = loaded
    try:
        target_state = raw_entry_state(directory_fd, name)
        stage_state = raw_entry_state(directory_fd, stage)
        previous_state = raw_entry_state(directory_fd, previous)
        if candidate_state is None:
            fail(f"owned replacement journal is incomplete for {name}")
        if previous_state != "absent" and not state_matches(previous_state, expected_state):
            if target_state == "absent":
                atomic_rename(directory_fd, previous, name, False)
            fail(f"owned destination changed during publication: {name}")
        if expected_state != "absent" and previous_state == "absent":
            if target_state != expected_state:
                fail(f"owned destination changed during publication: {name}")
            atomic_rename(directory_fd, name, previous, False)
            previous_state = raw_entry_state(directory_fd, previous)
            target_state = "absent"
            if not state_matches(previous_state, expected_state):
                atomic_rename(directory_fd, previous, name, False)
                fail(f"owned destination changed during publication: {name}")
        if target_state == "absent":
            if not state_matches(stage_state, candidate_state):
                fail(f"owned replacement candidate changed during publication: {stage}")
            atomic_rename(directory_fd, stage, name, False)
            target_state = raw_entry_state(directory_fd, name)
            stage_state = "absent"
        if not state_matches(target_state, candidate_state) or stage_state != "absent":
            fail(f"owned destination changed during publication: {name}")
        if previous_state != "absent":
            remove(directory_fd, previous)
        os.close(journal_fd)
        journal_fd = None
        remove(directory_fd, journal)
        os.fsync(directory_fd)
    finally:
        if journal_fd is not None:
            os.close(journal_fd)


def replace_entry(directory_fd, name, source, expected_state):
    recover_replace(directory_fd, name)
    if entry_state(directory_fd, name) != expected_state:
        fail(f"owned destination changed before publication: {name}")
    stage = f".{name}.replace-candidate"
    previous = f".{name}.replace-previous"
    journal = f".{name}.replace-journal"
    copy_to_new(source, directory_fd, stage)
    candidate_state = raw_entry_state(directory_fd, stage)
    if not candidate_state.startswith("regular:"):
        fail(f"owned replacement candidate is unsafe: {stage}")
    publish_replace_journal(
        directory_fd, journal, stage, previous, expected_state, candidate_state
    )
    recover_replace(directory_fd, name)


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
    current_start = process_start_identity(owner_pid) if owner_pid is not None and pid_alive(owner_pid) else None
    if owner_start is not None and current_start == owner_start:
        raise SystemExit(2)
    if owner_start is None and current_start is not None \
            and time.time() - lock_info.st_mtime < stale_after:
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
        elif command == "describe":
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_replace(directory_fd, name)
                print(entry_state(directory_fd, name))
            finally:
                os.close(mutex_fd)
        elif command == "remove":
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_replace(directory_fd, name)
                remove(directory_fd, name)
                os.fsync(directory_fd)
            finally:
                os.close(mutex_fd)
        elif command == "replace":
            if len(sys.argv) != 7:
                fail("replace requires a source and expected destination state")
            source, expected_state = sys.argv[5:7]
            mutex_fd = operation_lock(directory_fd, name)
            try:
                replace_entry(directory_fd, name, source, expected_state)
            finally:
                os.close(mutex_fd)
        elif command == "no-clobber":
            if len(sys.argv) != 7:
                fail("no-clobber requires a source and staging name")
            source, staging = sys.argv[5:7]
            if not valid_name(staging):
                fail("unsafe publication staging name")
            mutex_fd = operation_lock(directory_fd, name)
            try:
                recover_replace(directory_fd, name)
                try:
                    os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    raise SystemExit(2)
                except FileNotFoundError:
                    pass
                try:
                    copy_to_new(source, directory_fd, staging)
                    try:
                        os.link(staging, name, src_dir_fd=directory_fd,
                                dst_dir_fd=directory_fd, follow_symlinks=False)
                    except FileExistsError:
                        remove(directory_fd, staging)
                        raise SystemExit(2)
                    remove(directory_fd, staging)
                    os.fsync(directory_fd)
                except FileExistsError:
                    fail("publication staging entry already exists")
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
        elif command == "lock-release":
            if len(sys.argv) != 7:
                fail("lock-release requires pid and token")
            pid_text, token = sys.argv[5:7]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            mutex_fd = operation_lock(directory_fd, name)
            try:
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

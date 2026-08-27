#!/usr/bin/env python3
import errno
import os
import secrets
import stat
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


def entry_state(directory_fd, name):
    try:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "absent"
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"owned destination entry is unsafe: {name}")
    return ":".join([
        "regular",
        str(info.st_dev),
        str(info.st_ino),
        str(info.st_mode),
        str(info.st_size),
        str(info.st_mtime_ns),
        str(info.st_ctime_ns),
    ])


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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
            raise SystemExit(2)
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
            return lock_info, None, None, entries
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
        if len(fields) != 2 or not fields[0].isdigit() or not valid_token(fields[1]):
            fail(f"owned lock owner is malformed: {name}/owner")
        if entries != ["owner"]:
            fail(f"owned lock contains unexpected entries: {name}")
        return lock_info, int(fields[0]), fields[1], entries
    finally:
        os.close(lock_fd)


def create_lock(directory_fd, name, pid, token):
    os.mkdir(name, 0o700, dir_fd=directory_fd)
    lock_fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        owner_fd = os.open(
            "owner",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=lock_fd,
        )
        try:
            os.write(owner_fd, f"{pid}\t{token}\n".encode("ascii"))
            os.fsync(owner_fd)
        finally:
            os.close(owner_fd)
        os.fsync(lock_fd)
    except BaseException:
        try:
            os.unlink("owner", dir_fd=lock_fd)
        except OSError:
            pass
        os.close(lock_fd)
        try:
            os.rmdir(name, dir_fd=directory_fd)
        except OSError:
            pass
        raise
    os.close(lock_fd)
    os.fsync(directory_fd)


def retire_lock(directory_fd, name, quarantine):
    os.rename(name, quarantine, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
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
    lock_info, owner_pid, owner_token, entries = details
    if owner_pid == pid and owner_token == token:
        return
    if owner_pid is not None and pid_alive(owner_pid):
        raise SystemExit(2)
    if owner_pid is None and entries:
        raise SystemExit(2)
    age = time.time() - lock_info.st_mtime
    if age < stale_after:
        raise SystemExit(2)
    quarantine = f".{name}.retiring.{os.getpid()}.{secrets.token_hex(8)}"
    try:
        retire_lock(directory_fd, name, quarantine)
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
    _, owner_pid, owner_token, _ = details
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
            print(entry_state(directory_fd, name))
        elif command == "remove":
            remove(directory_fd, name)
            os.fsync(directory_fd)
        elif command == "replace":
            if len(sys.argv) != 7:
                fail("replace requires a source and expected destination state")
            source, expected_state = sys.argv[5:7]
            if entry_state(directory_fd, name) != expected_state:
                fail(f"owned destination changed before publication: {name}")
            stage = f".{name}.replacing.{os.getpid()}.{secrets.token_hex(8)}"
            try:
                copy_to_new(source, directory_fd, stage)
                if entry_state(directory_fd, name) != expected_state:
                    fail(f"owned destination changed during publication: {name}")
                os.replace(stage, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                os.fsync(directory_fd)
            finally:
                remove(directory_fd, stage)
        elif command == "no-clobber":
            if len(sys.argv) != 7:
                fail("no-clobber requires a source and staging name")
            source, staging = sys.argv[5:7]
            if not valid_name(staging):
                fail("unsafe publication staging name")
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
            lock_try(directory_fd, name, int(pid_text), token, stale_after)
        elif command == "lock-release":
            if len(sys.argv) != 7:
                fail("lock-release requires pid and token")
            pid_text, token = sys.argv[5:7]
            if not pid_text.isdigit() or not valid_token(token):
                fail("owned lock identity is malformed")
            lock_release(directory_fd, name, int(pid_text), token)
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

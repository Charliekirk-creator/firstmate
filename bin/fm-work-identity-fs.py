#!/usr/bin/env python3
import errno
import os
import secrets
import stat
import sys


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def valid_name(name):
    return bool(name) and name not in (".", "..") and "/" not in name and "\0" not in name


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
            print(f"{info.st_dev}:{info.st_ino}")
        elif command == "probe":
            probe = f".{name}.{os.getpid()}.{secrets.token_hex(8)}"
            os.mkdir(probe, 0o700, dir_fd=directory_fd)
            os.rmdir(probe, dir_fd=directory_fd)
        elif command == "remove":
            remove(directory_fd, name)
        elif command == "replace":
            if len(sys.argv) != 6:
                fail("replace requires a source")
            source = sys.argv[5]
            stage = f".{name}.replacing.{os.getpid()}.{secrets.token_hex(8)}"
            try:
                copy_to_new(source, directory_fd, stage)
                os.replace(stage, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
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
            except FileExistsError:
                fail("publication staging entry already exists")
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

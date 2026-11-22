#!/usr/bin/env python3
"""Install the optional OneSignal platform plugin into one existing Hermes profile.

Run as the gateway's Unix user, never with sudo. This does not enable the plugin,
change Hermes configuration, restart a service, or contact OneSignal.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import warnings

SOURCE = Path(__file__).resolve().parents[2] / "plugin" / "hermes_onesignal"
FILES = ("plugin.yaml", "__init__.py", "adapter.py")
MARKER = ".mobile-surfaces-onesignal.json"
NAMES = ("HERMES_ONESIGNAL_APP_ID", "HERMES_ONESIGNAL_API_KEY", "HERMES_ONESIGNAL_SUBSCRIPTION_ID")


class Refused(Exception):
    pass


def safe_dir(path: Path) -> None:
    """Reject links and directories writable by another untrusted user."""
    for directory in (path, *path.parents):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise Refused(f"not a real directory: {directory}")
        if info.st_uid not in (0, os.geteuid()):
            raise Refused(f"directory has another owner: {directory}")
        writable = info.st_mode & 0o022
        if writable and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
            raise Refused(f"directory is writable by others: {directory}")


def private_file(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise Refused(f"file must be regular, owned by this user and mode 0600 or stricter: {path}")


def read_secret_file(path: Path) -> None:
    private_file(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as f:
        info = os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise Refused("credentials file is not private")
        data = f.read(8193)
    try:
        values = json.loads(data)
    except (ValueError, UnicodeError):
        raise Refused("credentials file is invalid JSON") from None
    if len(data) > 8192 or not isinstance(values, dict) or any(not valid_value(values.get(k)) for k in NAMES):
        raise Refused("credentials file is invalid; repair it separately")


def valid_value(value: object) -> bool:
    return isinstance(value, str) and bool(value) and value == value.strip() and all(32 <= ord(c) != 127 for c in value)


def source_files(source: Path) -> dict[str, bytes]:
    result = {}
    for name in FILES:
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise Refused(f"missing or unsafe source file: {path}")
        result[name] = path.read_bytes()
    manifest = result["plugin.yaml"].decode("utf-8")
    if "name: onesignal" not in manifest.splitlines() or "kind: platform" not in manifest.splitlines():
        raise Refused("unexpected plugin manifest")
    return result


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inspect(home: Path, source: Path = SOURCE) -> tuple[Path, Path, dict[str, bytes], bool]:
    if not sys.platform.startswith("linux") or not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise Refused("Linux with O_NOFOLLOW and O_DIRECTORY is required")
    if os.getuid() != os.geteuid() or os.environ.get("SUDO_UID"):
        raise Refused("run directly as the Hermes gateway user, not through sudo")
    if not home.is_absolute():
        raise Refused("--hermes-home must be an absolute path")
    safe_dir(home)
    if home.lstat().st_uid != os.geteuid():
        raise Refused("Hermes home must be owned by the gateway user")
    files = source_files(source)
    plugins = home / "plugins"
    platforms = plugins / "platforms"
    target = platforms / "onesignal"
    backup = platforms / ".hermes_onesignal.previous"
    for directory in (plugins, platforms):
        if os.path.lexists(directory):
            safe_dir(directory)
            if directory.lstat().st_uid != os.geteuid():
                raise Refused(f"directory must be owned by the gateway user: {directory}")
    if os.path.lexists(backup):
        raise Refused(f"unfinished upgrade: inspect {backup}; no files were changed")
    unchanged = False
    if os.path.lexists(target):
        safe_dir(target)
        if target.lstat().st_uid != os.geteuid():
            raise Refused("plugin directory has another owner")
        marker = target / MARKER
        try:
            private_file(marker)
            record = json.loads(marker.read_text(encoding="utf-8"))
            if not isinstance(record, dict) or set(record) != set(FILES):
                raise ValueError()
            for name in FILES:
                path = target / name
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                    raise ValueError()
                if digest(path.read_bytes()) != record[name]:
                    raise ValueError()
            unchanged = all(record[name] == digest(files[name]) for name in FILES)
        except (OSError, ValueError, TypeError, Refused):
            raise Refused("existing plugin is unmanaged or locally modified; refusing to overwrite it") from None
    secret = home / "onesignal.json"
    if os.path.lexists(secret):
        read_secret_file(secret)
    return target, secret, files, unchanged


def prompt_credentials() -> bytes:
    values = {}
    for name in NAMES:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                value = getpass.getpass(f"{name}: ")
        except getpass.GetPassWarning:
            raise Refused("a terminal with hidden input is required") from None
        if not valid_value(value):
            raise Refused("empty or invalid credential; nothing was written")
        values[name] = value
    data = (json.dumps(values) + "\n").encode("utf-8")
    if len(data) > 8192:
        raise Refused("credentials too long; nothing was written")
    return data


def install(home: Path, source: Path = SOURCE) -> str:
    inspect(home, source)
    import fcntl
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _install_locked(home, source)
    finally:
        os.close(fd)


def _install_locked(home: Path, source: Path) -> str:
    target, secret, files, unchanged = inspect(home, source)
    data = None if os.path.lexists(secret) else prompt_credentials()
    # Recheck after interactive input, before any change.
    target, secret, files, unchanged = inspect(home, source)
    if data is not None and os.path.lexists(secret):
        raise Refused("credentials appeared while prompting; retry")
    if data is not None:
        fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
        except BaseException:
            secret.unlink(missing_ok=True)
            raise
    if unchanged:
        return "Plugin unchanged; existing credentials kept."
    for directory in (home / "plugins", home / "plugins" / "platforms"):
        directory.mkdir(mode=0o700, exist_ok=True)
        safe_dir(directory)
    backup = target.parent / ".hermes_onesignal.previous"
    stage = Path(tempfile.mkdtemp(prefix=".hermes_onesignal.stage-", dir=target.parent))
    moved = False
    try:
        if target.exists():
            # Preserve unrelated user files, including Python's bytecode cache.
            shutil.copytree(target, stage, dirs_exist_ok=True, symlinks=True)
        for name, contents in files.items():
            path = stage / name
            path.unlink(missing_ok=True)
            path.write_bytes(contents)
            path.chmod(0o600)
        marker = stage / MARKER
        marker.unlink(missing_ok=True)
        marker.write_text(json.dumps({name: digest(data) for name, data in files.items()}) + "\n", encoding="utf-8")
        marker.chmod(0o600)
        if target.exists():
            os.rename(target, backup)
            moved = True
        os.rename(stage, target)
        if moved:
            shutil.rmtree(backup)
        return "Plugin installed; credentials and existing enablement were not changed."
    except BaseException:
        if moved and not target.exists() and backup.exists():
            os.rename(backup, target)
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "apply"))
    parser.add_argument("--hermes-home", required=True, type=Path, help="absolute home of the target Hermes profile")
    args = parser.parse_args()
    try:
        target, secret, _, unchanged = inspect(args.hermes_home)
        print(f"Hermes home: {args.hermes_home}\nPlugin: {target} ({'unchanged' if unchanged else 'install or upgrade'})")
        print(f"Credentials: {secret} ({'keep existing' if os.path.lexists(secret) else 'prompt privately'})")
        print("No Hermes config, isolation, plugin enablement or service will be changed.")
        if args.command == "apply":
            print(install(args.hermes_home))
        return 0
    except (Refused, OSError, UnicodeError) as exc:
        print(f"Refused or failed: {exc}", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("Cancelled.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

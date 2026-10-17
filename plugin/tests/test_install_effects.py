"""Installer: the real `Fs`, `SubprocessRunner` and probes (below a tmp root; nothing outside it is touched)."""
from __future__ import annotations

import os
import socket
import stat
import sys
from pathlib import Path, PurePosixPath

import pytest

from mobile_surfaces.install.effects import (
    Fs, SubprocessRunner, detect_host, new_token, tail, tcp_listening, timestamp, tree_digest,
)

P = PurePosixPath
posix_only = pytest.mark.skipif(os.name == "nt", reason="POSIX permission bits")


def test_logical_paths_are_mapped_below_the_root(tmp_path):
    fs = Fs(tmp_path)
    assert fs.real(P("/etc/x/y")) == tmp_path / "etc" / "x" / "y"
    fs.write_text(P("/etc/x/y"), "hello", 0o600)
    assert fs.read_text(P("/etc/x/y")) == "hello" and (tmp_path / "etc" / "x" / "y").read_text() == "hello"
    assert fs.read_bytes(P("/nope")) is None and fs.read_text(P("/etc/x/y/z")) is None
    assert fs.exists(P("/etc/x/y")) and not fs.exists(P("/etc/x/other"))


def test_without_a_root_paths_are_the_real_ones():
    assert str(Fs().real(P("/opt/x"))).replace("\\", "/").endswith("/opt/x")


@posix_only
def test_secret_files_are_created_private_and_replaced_atomically(tmp_path):
    fs = Fs(tmp_path)
    fs.write_bytes(P("/etc/s/token"), b"one", 0o600)
    assert stat.S_IMODE((tmp_path / "etc/s/token").stat().st_mode) == 0o600
    fs.write_bytes(P("/etc/s/token"), b"two", 0o600)
    assert fs.read_bytes(P("/etc/s/token")) == b"two"
    assert [p.name for p in (tmp_path / "etc/s").iterdir()] == ["token"]  # no temp file left behind


@posix_only
def test_mkdir_sets_the_requested_mode_whatever_the_umask(tmp_path):
    old = os.umask(0o077)
    try:
        Fs(tmp_path).mkdir(P("/opt/pub"), 0o755)
    finally:
        os.umask(old)
    assert stat.S_IMODE((tmp_path / "opt/pub").stat().st_mode) == 0o755


def test_a_failed_write_leaves_no_temp_file(tmp_path, monkeypatch):
    fs = Fs(tmp_path)
    monkeypatch.setattr(os, "replace", lambda *a: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        fs.write_bytes(P("/etc/a"), b"x", 0o600)
    assert list((tmp_path / "etc").iterdir()) == []


def make_tree(base: Path, files: dict[str, str]) -> None:
    for rel, text in files.items():
        path = base / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")


def test_copytree_mirrors_the_source_and_keeps_excluded_names(tmp_path):
    src = tmp_path / "src"
    make_tree(src, {"a.txt": "A", "sub/b.txt": "B", "node_modules/m.js": "SOURCE-SIDE", "sub/node_modules/n.js": "x"})
    fs = Fs(tmp_path / "root")
    fs.copytree(src, P("/opt/t"), ("node_modules",))
    assert fs.read_text(P("/opt/t/a.txt")) == "A" and fs.read_text(P("/opt/t/sub/b.txt")) == "B"
    assert not fs.exists(P("/opt/t/node_modules")) and not fs.exists(P("/opt/t/sub/node_modules"))
    # an installed node_modules (made later by npm) must survive an update; stale files must not
    make_tree(tmp_path / "root" / "opt" / "t", {"node_modules/real/index.js": "installed", "stale.txt": "old", "sub/stale2.txt": "old"})
    (src / "a.txt").write_text("A2", encoding="utf-8")
    fs.copytree(src, P("/opt/t"), ("node_modules",))
    assert fs.read_text(P("/opt/t/a.txt")) == "A2"
    assert fs.read_text(P("/opt/t/node_modules/real/index.js")) == "installed"
    assert not fs.exists(P("/opt/t/stale.txt")) and not fs.exists(P("/opt/t/sub/stale2.txt"))


@posix_only
def test_copytree_gives_files_0644_and_directories_0755_even_under_a_strict_umask(tmp_path):
    src = tmp_path / "src"
    make_tree(src, {"d/f.txt": "x"})
    old = os.umask(0o077)
    try:
        Fs(tmp_path / "root").copytree(src, P("/opt/t"))
    finally:
        os.umask(old)
    assert stat.S_IMODE((tmp_path / "root/opt/t/d").stat().st_mode) == 0o755
    assert stat.S_IMODE((tmp_path / "root/opt/t/d/f.txt").stat().st_mode) == 0o644


def test_copytree_skips_symbolic_links(tmp_path):
    src = tmp_path / "src"
    make_tree(src, {"real.txt": "R"})
    secret = tmp_path / "outside.txt"
    secret.write_text("outside", encoding="utf-8")
    try:
        os.symlink(secret, src / "link.txt")
        os.symlink(tmp_path, src / "linkdir", target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symbolic links are not available here")
    fs = Fs(tmp_path / "root")
    fs.copytree(src, P("/opt/t"))
    assert fs.exists(P("/opt/t/real.txt")) and not fs.exists(P("/opt/t/link.txt")) and not fs.exists(P("/opt/t/linkdir"))


def test_tree_digest_ignores_excluded_names_and_detects_changes(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    make_tree(a, {"x.txt": "1", "d/y.txt": "2"})
    make_tree(b, {"x.txt": "1", "d/y.txt": "2", "node_modules/z.js": "3", ".work/w": "4"})
    assert tree_digest(a) != tree_digest(b)
    assert tree_digest(a, ("node_modules", ".work")) == tree_digest(b, ("node_modules", ".work"))
    (b / "d" / "y.txt").write_text("changed", encoding="utf-8")
    assert tree_digest(a, ("node_modules", ".work")) != tree_digest(b, ("node_modules", ".work"))
    assert tree_digest(tmp_path / "missing") is None


def test_the_digest_of_a_copy_equals_the_digest_of_the_source(tmp_path):
    src = tmp_path / "src"
    make_tree(src, {"a": "1", "s/b": "2", "node_modules/c": "3"})
    fs = Fs(tmp_path / "root")
    fs.copytree(src, P("/opt/t"), ("node_modules",))
    assert fs.tree_digest(P("/opt/t"), ("node_modules",)) == tree_digest(src, ("node_modules",))


def test_remove_deletes_files_directories_and_links(tmp_path):
    fs = Fs(tmp_path)
    make_tree(tmp_path, {"var/lib/app/data.db": "x", "etc/app/token": "t"})
    fs.remove(P("/var/lib/app"))
    fs.remove(P("/etc/app/token"))
    fs.remove(P("/etc/app/missing"))  # already gone: fine
    assert not fs.exists(P("/var/lib/app")) and not fs.exists(P("/etc/app/token")) and fs.exists(P("/etc/app"))


def test_listdir_and_is_dir(tmp_path):
    fs = Fs(tmp_path)
    make_tree(tmp_path, {"d/b": "", "d/a": ""})
    assert fs.listdir(P("/d")) == ["a", "b"] and fs.listdir(P("/nope")) == [] and fs.is_dir(P("/d"))


# -- subprocesses and probes -----------------------------------------------------------------------------


def test_runner_captures_output_and_exit_status():
    runner = SubprocessRunner()
    ok = runner.run([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"])
    assert (ok.returncode, ok.stdout.strip(), ok.stderr.strip()) == (0, "out", "err")
    assert runner.run([sys.executable, "-c", "raise SystemExit(7)"]).returncode == 7


def test_runner_reports_a_missing_program_and_a_timeout_without_raising():
    runner = SubprocessRunner()
    assert runner.run(["/definitely/not/a/program"]).returncode == 127
    slow = runner.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.5)
    assert slow.returncode == 124 and "timed out" in slow.stderr


def test_runner_does_not_inherit_stdin():
    result = SubprocessRunner().run([sys.executable, "-c", "import sys; print(repr(sys.stdin.read()))"], timeout=20)
    assert result.stdout.strip() == "''"


def test_runner_passes_only_the_given_environment():
    env = {**os.environ, "INSTALLER_TEST_VAR": "yes"}
    out = SubprocessRunner().run([sys.executable, "-c", "import os; print(os.environ.get('INSTALLER_TEST_VAR'))"], env=env)
    assert out.stdout.strip() == "yes"


def test_tail_keeps_the_last_lines():
    assert tail("a\n\nb\nc\nd\n", 2) == "c\nd" and tail("", 3) == ""


def test_tcp_probe_sees_a_listener_and_an_empty_port():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen(50)  # the probes connect and leave: the backlog must hold all of them
        port = server.getsockname()[1]
        assert tcp_listening("127.0.0.1", port) and tcp_listening("0.0.0.0", port) and tcp_listening("localhost", port)
    assert not tcp_listening("127.0.0.1", port)


def test_detect_host_describes_this_machine():
    host = detect_host({"USERNAME": "Some User", "PATH": "x"})
    assert host.python_version == sys.version_info[:2] and host.python == sys.executable
    assert (host.checkout / "plugin" / "pyproject.toml").is_file()
    assert str(host.home).startswith("/") and "\\" not in str(host.home) and " " not in str(host.home) or host.is_linux
    assert host.is_linux == sys.platform.startswith("linux")
    assert host.environ["PATH"] == "x"


def test_clock_and_token_helpers():
    assert len(timestamp()) == 15 and timestamp()[8] == "-"
    assert new_token() != new_token()

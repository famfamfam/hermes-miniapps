"""Fakes for the installer tests: a recording filesystem, a scripted command runner, a deps builder.

The installer logic only reaches the host through `Fs`, `Runner` and the callables of `Deps`; these
fakes record what was asked, so the tests can assert permissions, ordering and secret hygiene on any
OS (on Windows the real file modes are meaningless, so modes are recorded at the call instead).
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence

from mobile_surfaces.install.effects import Deps, Fs, RunResult, Runner
from mobile_surfaces.install.model import HostEnv

CHECKOUT = Path(__file__).resolve().parents[2]  # the real repository: read-only source of templates and sdk
SECRET_PREFIX = "s3cr3t-token"  # every generated token contains this, so tests can search outputs for it
COMMIT = "0123456789abcdef0123456789abcdef01234567"


GOLDEN_DIR = Path(__file__).resolve().parent / "golden" / "install"


def assert_golden(name: str, text: str) -> None:
    """Compare with tests/golden/install/<name>. Regenerate deliberately with UPDATE_GOLDEN=1 and review the diff."""
    path = GOLDEN_DIR / name
    if os.environ.get("UPDATE_GOLDEN") == "1":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.replace("\r\n", "\n").encode("utf-8"))
    assert path.is_file(), f"missing golden file {path}; run with UPDATE_GOLDEN=1 and review it"
    expected = path.read_bytes().decode("utf-8").replace("\r\n", "\n")  # tolerate autocrlf checkouts
    assert text.replace("\r\n", "\n") == expected, f"{name} differs from its golden file (UPDATE_GOLDEN=1 to regenerate)"


def make_checkout(base: Path) -> Path:
    """A small stand-in for the repository: same layout, a few bytes per file, so tests can change sources."""
    plugin = base / "plugin"
    files = {
        "plugin/pyproject.toml": (CHECKOUT / "plugin" / "pyproject.toml").read_text(encoding="utf-8"),
        "plugin/constraints.txt": "anyio==4.14.1\n",
        "plugin/devserver.py": "print('devserver')\n",
        "plugin/ms_admin.py": "print('ms_admin')\n",
        "plugin/mobile_surfaces/__init__.py": "",
        "plugin/mobile_surfaces_core/__init__.py": "",
        "plugin/skills/surfaces-author/SKILL.md": "---\nname: surfaces-author\n---\n",
        "plugin/skills/surfaces-connect-phone/SKILL.md": "---\nname: surfaces-connect-phone\n---\n",
        "plugin/.devhome/dev-token": "DEV-TOKEN-MUST-NOT-BE-COPIED\n",
        "plugin/.devhome/mcp-token": "DEV-MCP-TOKEN-MUST-NOT-BE-COPIED\n",
        "plugin/tests/test_x.py": "def test_x(): pass\n",
        "templates/starter-app/package.json": '{"name": "starter"}\n',
        "templates/starter-app/package-lock.json": '{"lockfileVersion": 3}\n',
        "templates/starter-app/index.html": "<html></html>\n",
        "templates/starter-app/src/main.tsx": "export {}\n",
        "templates/starter-app/node_modules/leftpad/index.js": "// must not be copied\n",
        "packages/mobile-sdk/src/index.ts": "export {}\n",
    }
    for rel, text in files.items():
        path = base / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    assert plugin.is_dir()
    return base


class RecordingFs(Fs):
    """Real files below `root` (a tmp dir), plus a log of the modes, owners and writes that were requested."""

    def __init__(self, root: Path, events: list | None = None) -> None:
        super().__init__(root)
        self.ops: list[tuple] = []
        self.events: list = events if events is not None else []  # shared with the runner: global ordering
        self.modes: dict[PurePosixPath, int] = {}
        self.owners: dict[PurePosixPath, str] = {}
        self.fake_ids: dict[PurePosixPath, tuple[int, int]] = {}  # (uid, gid) pretended for existing files
        self.restored: dict[PurePosixPath, tuple[int, int]] = {}  # what chown_ids was asked to restore

    def owner(self, path: PurePosixPath) -> tuple[int, int] | None:
        return self.fake_ids.get(path, super().owner(path))

    def owned_by(self, path: PurePosixPath, user: str) -> bool | None:
        # Only files the installer chowned (recorded in `owners`) have a known owner in the tests.
        return self.owners[path] == user if path in self.owners else None

    def chown_ids(self, path: PurePosixPath, uid: int, gid: int) -> None:  # never really chown in tests
        self.restored[path] = (uid, gid)
        self._log("chown_ids", path, uid, gid)

    def _log(self, *op) -> None:  # noqa: ANN002
        self.ops.append(op)
        self.events.append(("fs", *op))

    def mode(self, path: PurePosixPath) -> int | None:
        return self.modes.get(path, super().mode(path))

    def mkdir(self, path: PurePosixPath, mode: int) -> None:
        super().mkdir(path, mode)
        self.modes[path] = mode
        self._log("mkdir", path, mode)

    def write_bytes(self, path: PurePosixPath, data: bytes, mode: int) -> None:
        super().write_bytes(path, data, mode)
        self.modes[path] = mode
        self._log("write", path, mode)

    def chmod(self, path: PurePosixPath, mode: int) -> None:
        super().chmod(path, mode)
        self.modes[path] = mode
        self._log("chmod", path, mode)

    def chown(self, path: PurePosixPath, user: str) -> None:  # never really chown in tests
        self.owners[path] = user
        self._log("chown", path, user)

    def remove(self, path: PurePosixPath) -> None:
        super().remove(path)
        for known in [p for p in self.modes if p == path or path in p.parents]:
            del self.modes[known]
        self._log("remove", path)

    def writes(self) -> list[PurePosixPath]:
        return [op[1] for op in self.ops if op[0] == "write"]

    def clear_ops(self) -> None:
        self.ops.clear()


@dataclass
class Call:
    argv: tuple[str, ...]
    env: dict[str, str]
    cwd: str | None
    umask: int


class FakeRunner(Runner):
    """Records every command. With `fs` set it also leaves behind what the real command would have created
    (a venv's python, `node_modules`), so a second run sees an installed host."""

    def __init__(self, responder: Callable[[tuple[str, ...]], RunResult | None] | None = None) -> None:
        self.calls: list[Call] = []
        self.responder = responder
        self.fs: Fs | None = None
        self.events: list = []

    def run(self, argv: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: str | None = None,
            timeout: float | None = None) -> RunResult:
        argv = tuple(argv)
        previous = os.umask(0o077)
        os.umask(previous)  # what the installer set while this command ran
        self.calls.append(Call(argv, dict(env or {}), cwd, previous))
        self.events.append(("run", argv))
        if self.responder is not None:
            answer = self.responder(argv)
            if answer is not None:
                return answer
        if self.fs is not None:
            if argv[1:3] == ("-m", "venv"):
                python = self.fs.real(PurePosixPath(argv[3]) / "bin" / "python")
                python.parent.mkdir(parents=True, exist_ok=True)
                python.write_text("", encoding="utf-8")
            if argv[:2] == ("npm", "ci") and cwd:
                (Path(cwd) / "node_modules").mkdir(parents=True, exist_ok=True)
        name = Path(argv[0]).name
        if name in ("node", "node.exe") and argv[-1:] == ("--version",):
            return RunResult(0, "v22.12.0\n")
        if name == "git":
            return RunResult(0, COMMIT + "\n")
        if "sys.version_info" in " ".join(argv):
            return RunResult(0, "3.12\n")
        if name == "systemctl" or argv[:1] == ("systemctl",):
            if "--version" in argv:
                return RunResult(0, "systemd 255 (255.4-1ubuntu8)\n+PAM +AUDIT\n")
            if "is-active" in argv:
                return RunResult(3, "inactive\n")
            if "is-enabled" in argv:
                return RunResult(1, "disabled\n")
        return RunResult(0)

    def matching(self, *needles: str) -> list[Call]:
        return [c for c in self.calls if all(n in " ".join(c.argv) for n in needles)]

    def systemctl_verbs(self) -> list[str]:
        """The verb of every systemctl call that is not a read-only version probe."""
        out = []
        for call in self.calls:
            if Path(call.argv[0]).name == "systemctl":
                words = [w for w in call.argv[1:] if not w.startswith("--")]
                if words:
                    out.append(words[0])
        return out

    def mutating(self) -> list[Call]:
        """Commands that could change the host: everything except read-only probes (git, --version, id)."""
        return [c for c in self.calls if c.argv[0] != "git" and c.argv[-1:] != ("--version",) and c.argv[:2] != ("id", "-u")
                and not (c.argv[1:2] == ("-c",) and "sys.version_info" in " ".join(c.argv))]


class Capture:
    def __init__(self) -> None:
        self.out: list[str] = []
        self.err: list[str] = []

    @property
    def stdout(self) -> str:
        return "\n".join(self.out)

    @property
    def stderr(self) -> str:
        return "\n".join(self.err)

    @property
    def everything(self) -> str:
        return self.stdout + "\n" + self.stderr


@dataclass
class World:
    deps: Deps
    fs: RecordingFs
    runner: FakeRunner
    cap: Capture
    root: Path
    tokens: list[str] = field(default_factory=list)
    events: list = field(default_factory=list)
    listening: set[tuple[str, int]] = field(default_factory=set)
    http: dict[str, int | None] = field(default_factory=dict)
    http_requests: list[tuple[str, dict[str, str]]] = field(default_factory=list)

    def read(self, logical: str) -> str:
        return self.fs.real(PurePosixPath(logical)).read_text(encoding="utf-8")

    def exists(self, logical: str) -> bool:
        return self.fs.real(PurePosixPath(logical)).exists()

    def put(self, logical: str, text: str) -> None:
        real = self.fs.real(PurePosixPath(logical))
        real.parent.mkdir(parents=True, exist_ok=True)
        real.write_text(text, encoding="utf-8", newline="")


def new_world(tmp_path: Path, **kwargs) -> World:  # noqa: ANN003
    """A world whose checkout is a small copy under tmp_path, so sources can be edited by the test."""
    checkout = make_checkout(tmp_path / "repo")
    return make_world(tmp_path, checkout=checkout, **kwargs)


def make_world(
    tmp_path: Path, *, platform: str = "linux", euid: int | None = 0, home: str = "/home/alice",
    environ: Mapping[str, str] | None = None, which: Mapping[str, str] | None = None, staging: bool = False,
    responder: Callable[[tuple[str, ...]], RunResult | None] | None = None, python_version: tuple[int, int] = (3, 12),
    realpath: Mapping[str, str] | None = None, checkout: Path = CHECKOUT,
) -> World:
    root = tmp_path / "root"
    root.mkdir(exist_ok=True)
    found = {"systemctl": "/usr/bin/systemctl", "node": "/usr/bin/node", "npm": "/usr/bin/npm", "git": "/usr/bin/git"}
    found.update(which or {})
    links = dict(realpath or {})
    host = HostEnv(
        platform=platform, euid=euid, home=PurePosixPath(home), environ=dict(environ or {}),
        python="/usr/bin/python3", python_version=python_version, checkout=checkout,
        which=lambda name: found.get(name), realpath=lambda p: links.get(p, p),
    )
    events: list = []
    fs = RecordingFs(root, events)
    runner = FakeRunner(responder)
    runner.events = events
    runner.fs = fs
    cap = Capture()
    world = World(deps=None, fs=fs, runner=runner, cap=cap, root=root, events=events)  # type: ignore[arg-type]

    def new_token() -> str:
        world.tokens.append(f"{SECRET_PREFIX}-{len(world.tokens) + 1}-" + "Z" * 32)
        return world.tokens[-1]

    def listening(host_: str, port: int) -> bool:
        return (host_, port) in world.listening or ("*", port) in world.listening

    def http(url: str, headers: Mapping[str, str]) -> int | None:
        world.http_requests.append((url, dict(headers)))
        return world.http.get(url, 200)

    world.deps = Deps(
        host=host, fs=fs, runner=runner, token_factory=new_token, now=lambda: "20260101-120000",
        port_listening=listening, http_status=http, out=cap.out.append, err=cap.err.append, staging=staging,
    )
    return world

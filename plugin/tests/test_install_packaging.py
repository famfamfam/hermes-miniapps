"""Installer: the package metadata the install depends on, and a real offline wheel build."""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tomllib
import zipfile
from pathlib import Path

import pytest
from install_support import CHECKOUT

PLUGIN = CHECKOUT / "plugin"
PYPROJECT = tomllib.loads((PLUGIN / "pyproject.toml").read_text(encoding="utf-8"))


def test_the_package_is_installable_with_the_entry_points_the_unit_and_docs_use():
    assert PYPROJECT["build-system"]["build-backend"] == "setuptools.build_meta"
    assert PYPROJECT["project"]["scripts"] == {"mobile-surfaces-server": "devserver:main", "ms-admin": "ms_admin:main"}
    assert sorted(PYPROJECT["tool"]["setuptools"]["py-modules"]) == ["devserver", "ms_admin"]
    assert PYPROJECT["project"]["requires-python"] == ">=3.11"
    include = PYPROJECT["tool"]["setuptools"]["packages"]["find"]["include"]
    assert "mobile_surfaces*" in include and "mobile_surfaces_core*" in include


def test_every_template_is_declared_as_package_data():
    declared = PYPROJECT["tool"]["setuptools"]["package-data"]["mobile_surfaces.install"]
    assert declared == ["templates/*.tmpl"]
    templates = sorted((PLUGIN / "mobile_surfaces" / "install" / "templates").glob("*"))
    assert templates and all(t.suffix == ".tmpl" for t in templates)


def test_constraints_pin_every_declared_dependency():
    pins = {}
    for line in (PLUGIN / "constraints.txt").read_text(encoding="utf-8").splitlines():
        line = line.split("#")[0].strip()
        if line:
            name, _, version = line.partition("==")
            assert version and re.fullmatch(r"[0-9][0-9A-Za-z.]*", version), line
            pins[name.lower().replace("_", "-")] = version
    for dep in PYPROJECT["project"]["dependencies"]:
        name, _, version = dep.partition("==")
        assert name in pins, f"{name} is declared but not pinned in constraints.txt"
        if version:
            assert pins[name] == version  # the one hard pin in pyproject.toml must agree
    assert not {"colorama", "pywin32", "pywin32-ctypes"} & set(pins)  # Windows-only: the service runs on Linux


def test_the_skill_the_installer_copies_exists_and_names_itself():
    from mobile_surfaces.install.plan import SKILLS

    assert set(SKILLS) == {"surfaces-author", "surfaces-connect-phone"}
    for name in SKILLS:
        skill = (PLUGIN / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
        assert re.search(rf"^name: {name}$", skill, re.M), name


def test_the_connection_skill_never_asks_for_a_token_to_be_shown():
    skill = (PLUGIN / "skills" / "surfaces-connect-phone" / "SKILL.md").read_text(encoding="utf-8")
    assert "pair-code" in skill and "HAP1." in skill
    assert "Never print, quote or send the phone token" in skill
    assert "cat /etc/hermes-surfaces" not in skill


def test_the_template_and_sdk_the_installer_copies_exist():
    for rel in ("templates/starter-app/package.json", "templates/starter-app/package-lock.json",
                "templates/starter-app/index.html", "templates/starter-app/src/main.tsx",
                "packages/mobile-sdk/src/index.ts"):
        assert (CHECKOUT / rel).is_file(), rel


def test_dev_data_is_ignored_by_git_and_excluded_from_the_build_snapshot():
    from mobile_surfaces.install.plan import PLUGIN_EXCLUDE

    assert ".devhome" in PLUGIN_EXCLUDE and "tests" in PLUGIN_EXCLUDE
    gitignore = (CHECKOUT / ".gitignore").read_text(encoding="utf-8")
    assert "plugin/.devhome/" in gitignore
    assert "*.egg-info/" in (PLUGIN / ".gitignore").read_text(encoding="utf-8")


def _setuptools_can_build_wheels() -> bool:
    try:
        import setuptools  # noqa: F401
    except ImportError:
        return False
    return True


@pytest.mark.skipif(not _setuptools_can_build_wheels(), reason="setuptools is not installed here")
def test_a_wheel_built_offline_contains_everything_the_service_needs(tmp_path):
    """Builds in a throw-away copy (nothing is written into the checkout) with the local setuptools: no network."""
    src = tmp_path / "plugin"
    shutil.copytree(PLUGIN, src, ignore=shutil.ignore_patterns(".devhome", "tests", "__pycache__", ".pytest_cache", "build", "*.egg-info"))
    out = tmp_path / "wheels"
    result = subprocess.run(
        [sys.executable, "-m", "pip", "wheel", "--no-build-isolation", "--no-deps", "--no-index", "-w", str(out), str(src)],
        capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL,
    )
    if result.returncode != 0 and ("bdist_wheel" in result.stderr or "No module named 'wheel'" in result.stderr):
        pytest.skip("this setuptools cannot build wheels without the 'wheel' package")
    assert result.returncode == 0, result.stdout[-2000:] + result.stderr[-2000:]
    [wheel] = list(out.glob("mobile_surfaces-*.whl"))
    with zipfile.ZipFile(wheel) as archive:
        names = set(archive.namelist())
        entry_points = archive.read(next(n for n in names if n.endswith("entry_points.txt"))).decode()
    for required in (
        "devserver.py", "ms_admin.py", "mobile_surfaces/api.py", "mobile_surfaces/install/cli.py",
        "mobile_surfaces/install/__main__.py", "mobile_surfaces/install/templates/system.service.tmpl",
        "mobile_surfaces/install/templates/user.service.tmpl", "mobile_surfaces/install/templates/resources.conf.tmpl",
        "mobile_surfaces_core/store.py",
    ):
        assert required in names, required
    assert not any(n.startswith(("tests/", ".devhome/", "skills/")) or "/.devhome/" in n for n in names)
    assert "mobile-surfaces-server = devserver:main" in entry_points and "ms-admin = ms_admin:main" in entry_points


@pytest.mark.skipif(not _setuptools_can_build_wheels(), reason="setuptools is not installed here")
def test_the_installed_installer_renders_the_same_unit_as_the_checkout(tmp_path):
    """Install the built wheel into an empty directory (no dependencies) and run the installer from there."""
    src = tmp_path / "plugin"
    shutil.copytree(PLUGIN, src, ignore=shutil.ignore_patterns(".devhome", "tests", "__pycache__", ".pytest_cache", "build", "*.egg-info"))
    built = subprocess.run(
        [sys.executable, "-m", "pip", "wheel", "--no-build-isolation", "--no-deps", "--no-index", "-w", str(tmp_path / "w"), str(src)],
        capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL,
    )
    if built.returncode != 0:
        pytest.skip("cannot build a wheel here")
    [wheel] = (tmp_path / "w").glob("*.whl")
    target = tmp_path / "site"
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(target)
    code = (
        "import sys; sys.path.insert(0, sys.argv[1]);"
        "from pathlib import PurePosixPath;"
        "from mobile_surfaces.install.model import Options, make_layout;"
        "from mobile_surfaces.install.render import render_unit;"
        "o = Options(); l = make_layout(o, PurePosixPath('/home/a'), {});"
        "print(render_unit(l, o, None), end='')"
    )
    result = subprocess.run([sys.executable, "-I", "-c", code, str(target)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    golden = (Path(__file__).parent / "golden" / "install" / "system-default.service").read_bytes().decode().replace("\r\n", "\n")
    assert result.stdout.replace("\r\n", "\n") == golden

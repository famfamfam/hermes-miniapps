"""README.md is the install guide of the repository. Its commands must match the installer, its translations must keep
the same commands, headings and links, and no README may hold a server address or a secret."""
from __future__ import annotations

import re

import pytest

from install_support import CHECKOUT

from mobile_surfaces.install.cli import build_parser

README = CHECKOUT / "README.md"
ALL = [README, *sorted(CHECKOUT.glob("README.*.md"))]
IDS = [p.name for p in ALL]
# Flags of other programs that appear in the commands the README shows (flutter, systemctl, ms_admin).
FOREIGN = {"--release", "--build-number", "--user", "--token-file", "--clear", "--help", "--version"}


def read(path):
    return path.read_text(encoding="utf-8")


def code_blocks(text):
    return re.findall(r"```[a-z]*\n(.*?)```", text, re.S)


def headings(text):
    outside = re.sub(r"```.*?```", "", text, flags=re.S)
    return [len(m.group(1)) for m in re.finditer(r"^(#{1,6}) ", outside, re.M)]


def test_the_readme_has_translations():
    assert len(ALL) >= 2, "README.md needs at least one translation next to it"


@pytest.mark.parametrize("path", ALL, ids=IDS)
def test_every_installer_option_in_the_readme_exists(path):
    ours = {s for action in build_parser()._actions for s in action.option_strings}
    mentioned = set(re.findall(r"(?<![\w-])--[a-z][a-z-]*[a-z]", read(path)))
    unknown = sorted(mentioned - ours - FOREIGN)
    assert unknown == [], f"{path.name} mentions options the installer does not have: {unknown}"


def test_the_readme_covers_the_installer_surface():
    text = read(README)
    for needed in ("plan", "apply", "status", "uninstall", "--upgrade", "--wheelhouse", "--write-hermes-config",
                   "--limits small", "--with-authoring", "--host", "--purge", "--scope user", "pair-code",
                   "approvers --clear", "trust: untrusted", "trust: full", "approvals.timeout"):
        assert needed in text, needed


def test_the_numbers_in_the_readme_match_the_installer():
    from mobile_surfaces.install import model

    text = read(README)
    assert f"systemd {model.MIN_SYSTEMD}+" in text
    assert f"Python {model.MIN_PYTHON[0]}.{model.MIN_PYTHON[1]}+" in text
    assert f"Node.js {model.MIN_NODE_MAJOR}+" in text
    assert f"about {model.SMALL_WITH_BUILDS.memory_max.rstrip('M')} MiB" in text
    assert "127.0.0.1:8787" in text.replace("http://", "") or "8787" in text


@pytest.mark.parametrize("path", ALL[1:], ids=IDS[1:])
def test_a_translation_keeps_the_commands_of_the_english_readme(path):
    english, other = code_blocks(read(README)), code_blocks(read(path))
    assert len(other) == len(english), f"{path.name}: {len(other)} code blocks, the English README has {len(english)}"
    for index, (a, b) in enumerate(zip(english, other)):
        assert a == b, f"{path.name}: code block {index + 1} differs from the English README"


@pytest.mark.parametrize("path", ALL[1:], ids=IDS[1:])
def test_a_translation_keeps_the_structure_of_the_english_readme(path):
    assert headings(read(path)) == headings(read(README)), f"{path.name}: headings differ from the English README"


@pytest.mark.parametrize("path", ALL, ids=IDS)
def test_every_readme_links_to_all_the_others(path):
    text = read(path)
    for other in ALL:
        if other != path:
            assert f"({other.name})" in text, f"{path.name} does not link to {other.name}"


@pytest.mark.parametrize("path", ALL, ids=IDS)
def test_relative_links_resolve(path):
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", read(path)):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        assert (path.parent / target).exists(), f"{path.name}: {target}"


@pytest.mark.parametrize("path", ALL, ids=IDS)
def test_in_page_anchors_exist(path):
    text = read(path)
    anchors = set()
    for line in re.sub(r"```.*?```", "", text, flags=re.S).splitlines():
        m = re.match(r"^#{1,6} (.+)$", line)
        if m:
            slug = re.sub(r"[^\w\- ]", "", m.group(1).strip().lower(), flags=re.U).replace(" ", "-")
            anchors.add(slug)
    for anchor in re.findall(r"\]\(#([^)]+)\)", text):
        assert anchor in anchors, f"{path.name}: #{anchor} is not a heading"


@pytest.mark.parametrize("path", ALL, ids=IDS)
def test_no_readme_names_a_server_address_or_holds_a_secret(path):
    text = read(path)
    addresses = set(re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text))
    assert addresses <= {"127.0.0.1"}, addresses
    long_words = re.findall(r"\b[A-Za-z0-9_-]{32,}\b", re.sub(r"https?://\S+", "", text))
    # An all-capitals identifier (an Android error code) is not a secret; anything mixed is suspect.
    assert [w for w in long_words if not re.fullmatch(r"[A-Z0-9_]+", w)] == [], "a long random-looking string"
    assert not re.search(r"Bearer [A-Za-z0-9_-]{20,}", text)
    assert "<user>@<server>" in text and "<this repository>" in text  # placeholders, not real hosts

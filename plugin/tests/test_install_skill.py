"""skills/surfaces-install is what Hermes follows when the user says "install this": its commands must exist in the
installer, its numbers must match it, and its order and prohibitions must not drift."""
from __future__ import annotations

import re
import shlex

import pytest

from install_support import CHECKOUT

from mobile_surfaces.install import model
from mobile_surfaces.install.cli import build_parser

SKILL = CHECKOUT / "skills" / "surfaces-install" / "SKILL.md"
TEXT = SKILL.read_text(encoding="utf-8").replace("\r\n", "\n")
FRONT, BODY = TEXT.split("\n---\n", 1)
README = (CHECKOUT / "README.md").read_text(encoding="utf-8")


def commands():
    """Every `...install.py <sub> ...` or `... mobile_surfaces.install <sub> ...` command in backticks."""
    found = []
    for code in re.findall(r"`([^`\n]+)`", BODY):
        match = re.search(r"(?:tools/install/install\.py|-m mobile_surfaces\.install)\s+(.*)", code)
        if match:
            found.append(shlex.split(match.group(1)))
    return found


def test_the_front_matter_names_the_skill_and_its_folder():
    meta = dict(re.findall(r"^([a-z]+): (.+)$", FRONT, re.M))
    assert meta["name"] == SKILL.parent.name == "surfaces-install"
    assert meta["platforms"] == "[linux]" and len(meta["description"]) < 400
    assert "install" in meta["description"] and "asking the user" in meta["description"]


def test_the_skill_gives_the_installer_commands_it_really_has():
    cmds = commands()
    assert {c[0] for c in cmds} == {"plan", "apply", "status", "uninstall"}
    parser = build_parser()
    for argv in cmds:
        # a placeholder such as <user from step 1> is replaced by a plain word
        argv = [re.sub(r"<[^>]+>", "x", a) for a in argv if a != "…"]
        try:
            parser.parse_args(argv)
        except SystemExit as exc:  # argparse printed the reason to stderr
            raise AssertionError(f"the installer does not accept: {' '.join(argv)}") from exc


def test_the_minimums_match_the_installer():
    assert f"systemd {model.MIN_SYSTEMD}," in BODY
    assert f"Python {model.MIN_PYTHON[0]}.{model.MIN_PYTHON[1]}," in BODY
    assert f"Node.js {model.MIN_NODE_MAJOR} " in BODY


def test_hermes_is_let_in_only_after_the_phone_is_paired():
    steps = dict(re.findall(r"^(\d+)\. \*\*([^*]+)\*\*", BODY, re.M))
    order = list(steps.values())
    pair, give = order.index("Pair the phone."), order.index("Give Hermes access.")
    assert pair < give
    install = BODY.split("4. **Install.**", 1)[1].split("5. **Check.**", 1)[0]
    # the install itself must not write the Hermes entries; only the later upgrade does
    assert "Do not pass\n   `--write-hermes-config` yet" in install and "--write-hermes-config" in install
    write_calls = [c for c in commands() if "--write-hermes-config" in c]
    assert len(write_calls) == 1 and "--upgrade" in write_calls[0]
    assert "only **after** the phone is paired (step 7)" in BODY


def test_the_skill_asks_first_and_never_exposes_secrets_or_restarts_hermes():
    for rule in ("Ask before every change", "Never print, quote or send a token", "Do not restart the Hermes gateway yourself",
                 "Do not open ports", "Do not change the `trust` setting"):
        assert rule in BODY, rule
    # the only secret-bearing value allowed in the chat is the one-time line; a token is only read inside $(...)
    assert BODY.count("HAP1.") >= 2
    for line in BODY.splitlines():
        assert not re.search(r"\bcat\s+/etc/hermes-surfaces/(api|mcp)-token", line) or "$(sudo cat" in line, line
    assert not re.search(r"Bearer [A-Za-z0-9_-]{20,}", BODY)
    assert "--rotate-tokens" not in BODY and "--purge" in BODY and "in so many words" in BODY


def test_it_points_at_things_that_exist():
    for step in re.findall(r"README step (\d)", BODY):
        assert re.search(rf"^### {step}\. ", README, re.M), f"README has no step {step}"
    assert (CHECKOUT / "tools" / "edge" / "README.md").exists() and (CHECKOUT / "tools" / "install" / "install.py").exists()
    for name in re.findall(r"`(surfaces-[a-z]+(?:-[a-z]+)?)`", BODY):
        if name != "surfaces-install":
            assert (CHECKOUT / "plugin" / "skills" / name / "SKILL.md").exists(), name


def test_it_holds_no_address_or_secret():
    assert set(re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", TEXT)) <= {"127.0.0.1"}
    long_words = re.findall(r"\b[A-Za-z0-9_-]{32,}\b", re.sub(r"https?://\S+", "", TEXT))
    assert [w for w in long_words if not re.fullmatch(r"[A-Z0-9_]+", w)] == []

"""The release workflow holds the signing key's secrets: keep it from ever running for outsiders or printing them.

Read as text on purpose: the plugin's test environment has no YAML library, and a guard that is skipped guards nothing.
"""
import re
from pathlib import Path

import pytest

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
TEXT = (WORKFLOWS / "release.yml").read_text(encoding="utf-8").replace("\r\n", "\n")


def section(key):
    """The block of a top-level key, without the key line."""
    match = re.search(rf"^{key}:\n((?:[ #].*\n|\n)*)", TEXT, re.M)
    assert match, key
    return match.group(1)


def steps():
    """The steps of the job as text blocks; each one starts with `      - ` (six spaces)."""
    body = TEXT.split("\n    steps:\n", 1)[1]
    return [b.rstrip() for b in re.split(r"\n(?=      - )", body) if b.startswith("      - ")]


def step(name):
    found = [b for b in steps() if re.search(rf"^\s+(?:- )?name: {re.escape(name)}$", b, re.M)]
    assert len(found) == 1, name
    return found[0]


def names():
    return [m.group(1) for b in steps() if (m := re.search(r"^\s+(?:- )?name: (.+)$", b, re.M))]


def test_it_runs_only_on_a_tag_or_by_hand_never_for_a_pull_request():
    triggers = section("on")
    assert re.findall(r"^  ([a-z_]+):", triggers, re.M) == ["push", "workflow_dispatch"]
    # a tag, not a branch: a branch push by anyone with write access is not a release
    assert re.search(r'^  push:\n    tags: \["v\*"\]\n', triggers, re.M)
    assert "pull_request" not in TEXT


@pytest.mark.parametrize("name", sorted(p.name for p in WORKFLOWS.glob("*.yml")))
def test_every_action_is_pinned_to_a_commit_and_only_the_release_uses_secrets(name):
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    assert [u for u in re.findall(r"uses: (\S+)", text) if not re.search(r"@[0-9a-f]{40}$", u)] == []
    if name != "release.yml":
        assert "secrets." not in text, "CI runs for pull requests; it must not see the key"


def test_the_secrets_reach_one_step_through_its_environment_and_are_never_echoed():
    uses = [m.group(0) for m in re.finditer(r"\$\{\{\s*secrets\.[A-Z0-9_]+\s*\}\}", TEXT)]
    assert sorted(uses) == ["${{ secrets.ANDROID_KEYSTORE_BASE64 }}", "${{ secrets.ANDROID_KEYSTORE_PASSWORD }}"]
    holders = [b for b in steps() if "secrets." in b]
    assert len(holders) == 1 and "name: Install the signing key" in holders[0]
    run = holders[0]
    assert "umask 077" in run
    # the password is written into the properties file and nowhere else: no echo/printf of the variable to the log
    for line in run.splitlines():
        if "$KEYSTORE_PASSWORD" in line or "${KEYSTORE_PASSWORD" in line:  # a use of the value, not the name in a message
            assert line.strip() in ('echo "storePassword=$KEYSTORE_PASSWORD"', 'echo "keyPassword=$KEYSTORE_PASSWORD"',
                                    'if [ -z "$KEYSTORE_BASE64" ] || [ -z "$KEYSTORE_PASSWORD" ]; then'), line
    assert "set -x" not in TEXT and "ACTIONS_STEP_DEBUG" not in TEXT


def test_the_build_is_refused_unless_the_release_certificate_signed_it_and_the_key_is_removed_afterwards():
    expected = re.search(r"^  EXPECTED_CERT_SHA256: (\S+)$", TEXT, re.M).group(1)
    assert re.fullmatch(r"[0-9a-f]{64}", expected)
    check = step("Check who signed it")
    assert "EXPECTED_CERT_SHA256" in check and "exit 1" in check
    cleanup = step("Remove the signing key from the runner")
    assert re.search(r"^\s+if: always\(\)$", cleanup, re.M) and "key.properties" in cleanup and "release.p12" in cleanup
    assert names().index("Check who signed it") < names().index("Publish the release")


def test_only_a_tag_publishes_a_release():
    assert re.search(r"^\s+if: startsWith\(github\.ref, 'refs/tags/v'\)$", step("Publish the release"), re.M)

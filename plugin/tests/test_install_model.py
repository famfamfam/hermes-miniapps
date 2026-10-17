"""Installer: option validation and path layout. Pure functions, no filesystem."""
from __future__ import annotations

from pathlib import PurePosixPath

import pytest

from mobile_surfaces.install import model
from mobile_surfaces.install.model import InstallError, Limits, Options, make_layout, resolve_limits

HOME = PurePosixPath("/home/alice")


@pytest.mark.parametrize("name", ["hermes-surfaces", "ms", "a1-b2", "x" * 40])
def test_valid_names(name):
    assert model.check_name(name) == name


@pytest.mark.parametrize("name", ["", "A", "1abc", "has space", "a/b", "a..b", "-x", "x" * 41, "a;b", "ünï", "a_b"])
def test_invalid_names(name):
    with pytest.raises(InstallError):
        model.check_name(name)


@pytest.mark.parametrize("value", ["/opt/x", "/opt/hermes-surfaces", "/srv/a_b.c+d@e/f-g"])
def test_posix_dirs_accepted(value):
    assert str(model.check_posix_dir(value, "--prefix")) == value


@pytest.mark.parametrize("value", [
    "", "opt/x", "/", "/opt/../etc", "C:\\opt\\x", "C:/opt/x", "/opt/my dir", "/opt/x;rm", "/opt/%h", "/opt/$HOME",
    "/opt/x\nExecStartPre=/bin/evil", "\\\\server\\share", "/opt/x\"",
])
def test_posix_dirs_rejected(value):
    with pytest.raises(InstallError):
        model.check_posix_dir(value, "--prefix")


@pytest.mark.parametrize("host", ["127.0.0.1", "0.0.0.0", "::1", "::", "10.1.2.3", "host.example", "my-host"])
def test_hosts_accepted(host):
    assert model.check_host(host) == host


@pytest.mark.parametrize("host", ["", "a b", "127.0.0.1;x", "host/../x", "-bad", "host\nX=1", "a" * 300, "h%t"])
def test_hosts_rejected(host):
    with pytest.raises(InstallError):
        model.check_host(host)


def test_loopback_detection():
    assert model.is_loopback("127.0.0.1") and model.is_loopback("::1") and model.is_loopback("localhost")
    assert model.is_loopback("127.5.5.5")
    assert not model.is_loopback("0.0.0.0") and not model.is_loopback("10.0.0.2") and not model.is_loopback("example.org")


@pytest.mark.parametrize("port", [0, 80, 1023, 65536, -1])
def test_bad_ports(port):
    with pytest.raises(InstallError):
        model.check_port(port, "--api-port")


def test_ports_must_differ():
    with pytest.raises(InstallError, match="differ"):
        Options(api_port=9000, mcp_port=9000).validate()


@pytest.mark.parametrize("value,expected", [("450M", 450 * 2**20), ("1G", 2**30), ("64K", 65536), ("1000", 1000), ("infinity", None)])
def test_sizes(value, expected):
    model.check_size(value, "--memory-max")
    assert model.size_bytes(value) == expected


@pytest.mark.parametrize("value", ["", "0M", "1.5G", "M", "10 M", "-5M", "10MB", "1G;x", "%"])
def test_bad_sizes(value):
    with pytest.raises(InstallError):
        model.check_size(value, "--memory-max")


@pytest.mark.parametrize("value", ["", "0%", "100", "1e2%", "50 %", "%"])
def test_bad_cpu(value):
    with pytest.raises(InstallError):
        model.check_cpu(value)


def test_small_profile_depends_on_authoring():
    plain = resolve_limits("small", False, None, None, None)
    builds = resolve_limits("small", True, None, None, None)
    assert plain.memory_max == "192M" and plain.cpu_quota == "25%"
    assert builds.memory_max == "450M" and builds.memory_high == "320M" and builds.cpu_quota == "100%"
    assert model.size_bytes(builds.memory_max) >= model.BUILD_MEMORY_FLOOR


def test_limits_none_and_overrides():
    assert resolve_limits("none", False, None, None, None) is None
    only = resolve_limits(None, False, None, "600M", None)
    assert only.lines() == ["MemoryMax=600M"]
    over = resolve_limits("small", True, None, "700M", "50%")
    assert over.memory_max == "700M" and over.cpu_quota == "50%" and over.memory_high == "320M"
    with pytest.raises(InstallError):
        resolve_limits("huge", False, None, None, None)


def test_limits_keep_current_when_no_profile():
    current = Limits(memory_max="300M", cpu_quota="10%")
    assert resolve_limits(None, False, None, None, None, current) == current
    assert resolve_limits(None, False, None, "400M", None, current).lines() == ["MemoryMax=400M", "CPUQuota=10%"]
    assert resolve_limits("none", False, None, None, None, current) is None


def test_limits_roundtrip_dict():
    limits = model.SMALL_WITH_BUILDS
    assert Limits.from_dict(limits.as_dict()) == limits
    assert Limits.from_dict(None) is None and Limits.from_dict({}) is None


@pytest.mark.parametrize("kwargs,fragment", [
    ({"scope": "root"}, "scope"),
    ({"name": "Bad Name"}, "name"),
    ({"hermes_user": "hermes", "scope": "user"}, "--hermes-user"),
    ({"hermes_user": "Bad User"}, "hermes-user"),
    ({"hermes_token_mode": "file"}, "token-mode"),
    ({"build_timeout": 1}, "build-timeout"),
    ({"mcp_name": "bad name"}, "mcp-name"),
    ({"user_sandbox": True}, "user-sandbox"),
    ({"copy_node": True}, "copy-node"),
    ({"rotate_tokens": True}, "rotate-tokens"),
    ({"host": "a b"}, "host"),
])
def test_option_validation_errors(kwargs, fragment):
    with pytest.raises(InstallError, match=fragment):
        Options(**kwargs).validate()


def test_option_validation_accepts_sensible_combinations():
    Options(scope="user", user_sandbox=True).validate()
    Options(authoring=True, copy_node=True).validate()
    Options(upgrade=True, rotate_tokens=True).validate()
    Options(hermes_user="hermes").validate()


def test_system_layout():
    layout = make_layout(Options(), HOME, {})
    assert str(layout.prefix) == "/opt/hermes-surfaces"
    assert str(layout.state_dir) == "/var/lib/hermes-surfaces"
    assert str(layout.secrets_dir) == "/etc/hermes-surfaces"
    assert str(layout.unit) == "/etc/systemd/system/hermes-surfaces.service"
    assert str(layout.dropin) == "/etc/systemd/system/hermes-surfaces.service.d/resources.conf"
    assert str(layout.python) == "/opt/hermes-surfaces/venv/bin/python"
    assert str(layout.api_token) == "/etc/hermes-surfaces/api-token"
    assert layout.systemctl == ("systemctl",)
    assert PurePosixPath("/var/lib/private/hermes-surfaces") in layout.data_paths()


def test_system_layout_uses_the_name_everywhere():
    layout = make_layout(Options(name="other"), HOME, {})
    assert all("other" in str(p) for p in (layout.prefix, layout.state_dir, layout.secrets_dir, layout.unit))
    assert layout.unit_name == "other.service"


def test_user_layout_follows_xdg_when_absolute():
    env = {"XDG_DATA_HOME": "/data/alice", "XDG_STATE_HOME": "/state/alice", "XDG_CONFIG_HOME": "/cfg/alice"}
    layout = make_layout(Options(scope="user"), HOME, env)
    assert str(layout.prefix) == "/data/alice/hermes-surfaces"
    assert str(layout.state_dir) == "/state/alice/hermes-surfaces"
    assert str(layout.secrets_dir) == "/cfg/alice/hermes-surfaces"
    assert str(layout.unit) == "/cfg/alice/systemd/user/hermes-surfaces.service"
    assert layout.systemctl == ("systemctl", "--user")
    assert len(layout.data_paths()) == 2


def test_user_layout_defaults_and_ignores_relative_xdg():
    layout = make_layout(Options(scope="user"), HOME, {"XDG_DATA_HOME": "relative/dir"})
    assert str(layout.prefix) == "/home/alice/.local/share/hermes-surfaces"
    assert str(layout.state_dir) == "/home/alice/.local/state/hermes-surfaces"
    assert str(layout.secrets_dir) == "/home/alice/.config/hermes-surfaces"
    assert str(layout.unit) == "/home/alice/.config/systemd/user/hermes-surfaces.service"


def test_layout_is_posix_whatever_the_machine():
    """Planning on Windows must still describe a Linux target: no backslashes, no drive letters."""
    for scope in ("system", "user"):
        layout = make_layout(Options(scope=scope), HOME, {})
        for path in (layout.prefix, layout.venv, layout.state_dir, layout.secrets_dir, layout.unit, layout.dropin):
            assert "\\" not in str(path) and ":" not in str(path) and str(path).startswith("/")


def test_user_layout_refuses_unsafe_home():
    with pytest.raises(InstallError, match="user directories"):
        make_layout(Options(scope="user"), PurePosixPath("/home/a b"), {})


def test_custom_prefix():
    layout = make_layout(Options(prefix=PurePosixPath("/srv/ms")), HOME, {})
    assert str(layout.venv) == "/srv/ms/venv" and str(layout.manifest) == "/srv/ms/install.json"

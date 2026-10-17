"""Typed parameters (ADR-003 §3.2): a value SQLite cannot bind is refused before binding."""
import pytest

from mobile_surfaces_core import params as P
from mobile_surfaces_core.params import ParamError, bind_args


def one(kind, value, **spec):
    return bind_args({"x": {"type": kind, **spec}}, {"x": value})["x"]


@pytest.mark.parametrize("bad", [2**63, -(2**63) - 1, 10**30, 10**400, -(10**30)])
@pytest.mark.parametrize("kind", ["integer", "number"])
def test_integers_outside_sqlite_range_are_refused(kind, bad):
    with pytest.raises(ParamError, match="range"):
        one(kind, bad)


@pytest.mark.parametrize("ok", [0, -1, 2**63 - 1, -(2**63)])
@pytest.mark.parametrize("kind", ["integer", "number"])
def test_integers_inside_sqlite_range_pass(kind, ok):
    assert one(kind, ok) == ok


def test_floats_and_non_numbers_behave_as_before():
    assert one("number", 1e300) == 1e300 and one("number", 1.5) == 1.5
    for bad in (float("inf"), float("nan"), True, "1", [1]):
        with pytest.raises(ParamError):
            one("number", bad)
    for bad in (1.5, True, "1"):
        with pytest.raises(ParamError):
            one("integer", bad)


@pytest.mark.parametrize("bad", ["\ud800", "ab\udfffcd"])
def test_text_that_is_not_valid_unicode_is_refused(bad):
    with pytest.raises(ParamError, match="Unicode"):
        one("string", bad)


def test_ordinary_text_including_non_bmp_passes():
    for text in ("", "Привет", "emoji 😀", "line\nbreak"):
        assert one("string", text) == text


def test_enum_values_must_be_valid_text_and_a_lone_surrogate_is_not_a_member():
    with pytest.raises(ParamError, match="Unicode"):
        P.validate_param_specs({"x": {"type": "enum", "values": ["a", "\ud800"]}})
    P.validate_param_specs({"x": {"type": "enum", "values": ["a", "б"]}})
    with pytest.raises(ParamError):
        one("enum", "\ud800", values=["a", "b"])
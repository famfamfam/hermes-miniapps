"""Typed parameters for named queries and mutations (ADR-003, sections 3.2-3.3)."""
from __future__ import annotations

import math
import re
from datetime import date, datetime, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SERVICE_PARAMS = frozenset({"now", "today", "device_id"})
PARAM_TYPES = frozenset({"string", "integer", "number", "boolean", "date", "datetime", "enum"})
MAX_STRING = 2000
INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1  # SQLite INTEGER; a wider Python int cannot be bound
_NAME = re.compile(r"^[a-z][a-z0-9_]{0,39}$")


class ParamError(ValueError):
    """Argument rejected before binding."""


def _is_text(value: str) -> bool:
    """False for text SQLite cannot store (lone surrogates): binding it raises UnicodeEncodeError."""
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def validate_param_specs(specs: dict[str, Any]) -> None:
    for name, spec in specs.items():
        if not _NAME.match(name):
            raise ParamError(f"bad parameter name: {name!r}")
        if name in SERVICE_PARAMS:
            raise ParamError(f"{name!r} is a service parameter and cannot be declared")
        if not isinstance(spec, dict) or spec.get("type") not in PARAM_TYPES:
            raise ParamError(f"parameter {name!r}: unknown type")
        if spec["type"] == "enum":
            values = spec.get("values")
            if not isinstance(values, list) or not values or not all(isinstance(v, str) for v in values):
                raise ParamError(f"parameter {name!r}: enum needs a non-empty list of string values")
            if not all(_is_text(v) for v in values):
                raise ParamError(f"parameter {name!r}: enum values must be valid Unicode text")


def _coerce(name: str, spec: dict[str, Any], value: Any) -> Any:
    kind = spec["type"]
    if kind == "string":
        if not isinstance(value, str) or len(value) > MAX_STRING:
            raise ParamError(f"{name}: expected string up to {MAX_STRING} chars")
        if not _is_text(value):
            raise ParamError(f"{name}: text is not valid Unicode")
        return value
    if kind == "integer":
        if isinstance(value, bool) or not isinstance(value, int):
            raise ParamError(f"{name}: expected integer")
        if not INT64_MIN <= value <= INT64_MAX:
            raise ParamError(f"{name}: integer is out of range")
        return value
    if kind == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ParamError(f"{name}: expected finite number")
        # Range first: math.isfinite() itself raises OverflowError for an int beyond the float range.
        if isinstance(value, int) and not INT64_MIN <= value <= INT64_MAX:
            raise ParamError(f"{name}: number is out of range")
        if not math.isfinite(value):
            raise ParamError(f"{name}: expected finite number")
        return value
    if kind == "boolean":
        if not isinstance(value, bool):
            raise ParamError(f"{name}: expected boolean")
        return 1 if value else 0
    if kind == "date":
        if not isinstance(value, str):
            raise ParamError(f"{name}: expected date string")
        try:
            return date.fromisoformat(value).isoformat()
        except ValueError:
            raise ParamError(f"{name}: expected YYYY-MM-DD") from None
    if kind == "datetime":
        if not isinstance(value, str):
            raise ParamError(f"{name}: expected datetime string")
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ParamError(f"{name}: expected ISO 8601 datetime") from None
        return value
    if kind == "enum":
        if value not in spec["values"]:
            raise ParamError(f"{name}: must be one of {spec['values']}")
        return value
    raise ParamError(f"{name}: unsupported type {kind}")


def bind_args(specs: dict[str, Any], args: dict[str, Any] | None) -> dict[str, Any]:
    """Validate args against declared specs. Missing nullable params become NULL."""
    args = args or {}
    unknown = set(args) - set(specs)
    if unknown:
        raise ParamError(f"unknown arguments: {sorted(unknown)}")
    out: dict[str, Any] = {}
    for name, spec in specs.items():
        value = args.get(name)
        if value is None:
            if not spec.get("nullable"):
                raise ParamError(f"{name}: required")
            out[name] = None
        else:
            out[name] = _coerce(name, spec, value)
    return out


def service_bindings(*, device_id: str, tz_name: str | None, now: datetime | None = None) -> dict[str, Any]:
    """:now is UTC ISO 8601, :today is the date in the device time zone."""
    now = now or datetime.now(timezone.utc)
    try:
        tz = ZoneInfo(tz_name) if tz_name else timezone.utc
    except (ZoneInfoNotFoundError, ValueError):
        tz = timezone.utc
    return {
        "now": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "today": now.astimezone(tz).date().isoformat(),
        "device_id": device_id,
    }

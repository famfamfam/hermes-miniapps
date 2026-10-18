"""Errors the service reports to its callers. Every message is safe to return to the caller; `status` is
the HTTP status the phone API answers with."""
from __future__ import annotations


class StoreError(Exception):
    """Operation refused; message is safe to return to the caller."""

    status = 400
    # A stable word the phone can act on when the status alone is ambiguous (several kinds of 409).
    code: str | None = None


class NotFound(StoreError):
    status = 404


class Conflict(StoreError):
    status = 409


class RequestKeyReused(Conflict):
    """A mutation key that was already used for a different request."""

    code = "request_key_reused"


class OutcomeUnknown(Conflict):
    """An earlier attempt with this key may or may not have changed the data; trying again could write twice."""

    code = "outcome_unknown"


class ApprovalRefused(StoreError):
    # Not 401/403: the phone treats those as a bad token and would show the wrong problem.
    status = 422


class TooManyAttempts(StoreError):
    status = 429


class TooLarge(StoreError):
    status = 413


class InsufficientStorage(StoreError):
    status = 507

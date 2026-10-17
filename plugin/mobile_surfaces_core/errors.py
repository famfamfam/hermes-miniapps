"""Errors the service reports to its callers. Every message is safe to return to the caller; `status` is
the HTTP status the phone API answers with."""
from __future__ import annotations


class StoreError(Exception):
    """Operation refused; message is safe to return to the caller."""

    status = 400


class NotFound(StoreError):
    status = 404


class Conflict(StoreError):
    status = 409


class ApprovalRefused(StoreError):
    # Not 401/403: the phone treats those as a bad token and would show the wrong problem.
    status = 422


class TooManyAttempts(StoreError):
    status = 429


class TooLarge(StoreError):
    status = 413


class InsufficientStorage(StoreError):
    status = 507

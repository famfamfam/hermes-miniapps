"""Approval of a publication by the user's device (ADR-007 §5).

Why a signature: anything the server can check with a secret it holds, a process on the same host
can read. A phone keeps an Ed25519 private key; the server stores only the public key. An approval
is the phone's signature over a message that names the app, the build, the draft revision, the
bundle digest and a one-time nonce, so it cannot be replayed for another build, and nothing on the
server can produce it.

What this does not defend against: someone who can rewrite the server's own registry (it can replace
the stored public key). That is outside what a design on one host can promise; it does cover the
easy path, calling the phone API or the author tools with a token found on disk.
"""
from __future__ import annotations

import base64

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

MESSAGE_VERSION = "ms-approve-v1"


def canonical_message(
    app_id: str, build_id: str, draft_rev: int, bundle_id: str, base_revision: int, nonce: str
) -> str:
    """The exact text the phone signs. Fixed field order, one field per line, no trailing newline."""
    return "\n".join(
        [
            MESSAGE_VERSION,
            f"app:{app_id}",
            f"build:{build_id}",
            f"draftRev:{draft_rev}",
            f"bundle:{bundle_id}",
            f"base:{base_revision}",
            f"nonce:{nonce}",
        ]
    )


DELETE_MESSAGE_VERSION = "ms-delete-v1"


def canonical_delete_message(app_id: str, revision: int, bundle_id: str, nonce: str) -> str:
    """The exact text the phone signs to delete a published app. Its own version line keeps a signature
    made for a publication from being accepted as a deletion, and the other way round."""
    return "\n".join(
        [
            DELETE_MESSAGE_VERSION,
            f"app:{app_id}",
            f"revision:{revision}",
            f"bundle:{bundle_id}",
            f"nonce:{nonce}",
        ]
    )


def verify(public_key_b64: str, message: str, signature_b64: str) -> bool:
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64, validate=True))
        key.verify(base64.b64decode(signature_b64, validate=True), message.encode("utf-8"))
        return True
    except (InvalidSignature, ValueError):
        return False

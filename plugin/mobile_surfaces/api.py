"""HTTP routes of the plugin, base path /api/plugins/mobile-surfaces/v1 (ADR-002 §6).

Auth is not handled here: inside Hermes the dashboard's own middleware protects the
router; the dev server adds a bearer-token dependency. Unverified assumption (S0-4):
that the dashboard mounts a module-level `router` from dashboard/plugin_api.py.
"""
from __future__ import annotations

from typing import Any, Sequence
from urllib.parse import quote, unquote

import anyio
from fastapi import APIRouter, Header, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.bundle import FORMAT as BUNDLE_FORMAT
from mobile_surfaces_core.store import PAIR_CODE_TTL_S, Conflict, Store, StoreError

API_VERSION = "v1"
PLUGIN_VERSION = "0.0.1"
SUPPORTED_SDK_MAJORS = [1]


class QueryCall(BaseModel):
    name: str
    args: dict[str, Any] | None = None


class DataRequest(BaseModel):
    revision: int
    queries: list[QueryCall] = Field(min_length=1, max_length=16)
    timezone: str | None = None


class DownloadRequest(BaseModel):
    revision: int
    args: dict[str, Any] | None = None
    timezone: str | None = None


class MutationRequest(BaseModel):
    """A tap on a button that writes. The key makes a repeated request (a lost answer, a second tap that got
    through) change the data once; the phone creates it, one per user action."""

    revision: int
    args: dict[str, Any] | None = None
    idempotencyKey: str = Field(min_length=16, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    timezone: str | None = None


class Hello(BaseModel):
    hostVersion: str
    sdkMajor: int
    bundleFormat: int
    capabilities: list[str] = []
    timezone: str | None = None


class Pair(BaseModel):
    deviceId: str = Field(max_length=64)
    publicKey: str = Field(max_length=128)


class Rejection(BaseModel):
    buildId: str = Field(strict=True, min_length=1, max_length=64, pattern=r"^build_[A-Za-z0-9_-]+$")


class Approval(BaseModel):
    buildId: str = Field(max_length=64)
    nonce: str = Field(max_length=64)
    signature: str = Field(max_length=256)


class Deletion(BaseModel):
    nonce: str = Field(max_length=64)
    signature: str = Field(max_length=256)


class Claim(BaseModel):
    code: str = Field(max_length=200)
    deviceId: str = Field(max_length=64)
    publicKey: str = Field(max_length=128)


def _not_modified(request: Request, etag: str) -> bool:
    sent = request.headers.get("if-none-match", "")
    return any(part.strip() == etag for part in sent.split(","))


def _attachment(path: Any, name: str, mime: str, extra: dict[str, str] | None = None) -> FileResponse:
    """A file as a download. The name travels percent-encoded in `X-File-Name` as well, which is what the phone
    reads; the media type comes from the extension and the browser is told not to second-guess it."""
    return FileResponse(
        path, media_type=mime, filename=name, content_disposition_type="attachment",
        headers={"X-File-Name": quote(name, safe=""), "X-Content-Type-Options": "nosniff", **(extra or {})},
    )


def create_router(
    store: Store, dependencies: Sequence[Any] = (), authoring: Authoring | None = None
) -> APIRouter:
    router = APIRouter(dependencies=list(dependencies))

    @router.get("/health")
    def health() -> dict[str, Any]:
        return {
            "plugin": "mobile-surfaces",
            "version": PLUGIN_VERSION,
            "apiVersion": API_VERSION,
            "sdkMajors": SUPPORTED_SDK_MAJORS,
            "bundleFormats": [BUNDLE_FORMAT],
            "epoch": store.epoch(),
            "approverPaired": store.approver_count() > 0,
            "reviews": authoring is not None,
            "appDelete": authoring is not None,
            "pairCode": True,
            "files": True,
            "mutations": True,
        }

    @router.post("/admin/pair-code")
    def pair_code() -> dict[str, Any]:
        """A one-time code that hands a phone this server's token and pairs it as approver. It needs the
        phone token, so it grants nothing the token holder could not already do, and it cannot replace a
        paired approver (that stays an admin action on the database)."""
        return {"code": store.issue_pair_code(), "expiresIn": PAIR_CODE_TTL_S}

    @router.post("/devices/pair")
    def pair(body: Pair) -> dict[str, Any]:
        """Register this phone's public key as the approver of publications (first device only)."""
        store.register_approver(body.deviceId, body.publicKey)
        return {"paired": True}

    @router.post("/devices/hello")
    def hello(body: Hello) -> dict[str, Any]:
        problems = []
        if body.sdkMajor not in SUPPORTED_SDK_MAJORS:
            problems.append(f"sdkMajor {body.sdkMajor} is not supported")
        if body.bundleFormat != BUNDLE_FORMAT:
            problems.append(f"bundle format {body.bundleFormat} is not supported")
        return {"compatible": not problems, "problems": problems, "epoch": store.epoch()}

    @router.get("/apps")
    def list_apps(request: Request, response: Response) -> Any:
        etag = store.etag_for()
        if _not_modified(request, etag):
            return Response(status_code=304, headers={"ETag": etag})
        response.headers["ETag"] = etag
        return {"epoch": store.epoch(), "apps": store.list_apps()}

    @router.get("/apps/{app_id}")
    def get_app(app_id: str, request: Request, response: Response) -> Any:
        etag = store.etag_for(app_id)
        if _not_modified(request, etag):
            return Response(status_code=304, headers={"ETag": etag})
        manifest = store.get_manifest(app_id)
        response.headers["ETag"] = etag
        return {"epoch": store.epoch(), **manifest}

    @router.get("/apps/{app_id}/bundles/{bundle_id}")
    def get_bundle(app_id: str, bundle_id: str) -> FileResponse:
        path = store.bundle_path(app_id, bundle_id)
        return FileResponse(
            path,
            media_type="application/zip",
            headers={"ETag": f'"{bundle_id}"', "Cache-Control": "private, max-age=31536000, immutable"},
        )

    @router.post("/apps/{app_id}/data")
    def post_data(
        app_id: str, body: DataRequest, x_device_id: str = Header(default="unknown", max_length=64)
    ) -> Any:
        return store.run_queries(
            app_id,
            body.revision,
            [q.model_dump() for q in body.queries],
            device_id=x_device_id,
            tz_name=body.timezone,
        )

    @router.post("/apps/{app_id}/downloads/{name}")
    def download(
        app_id: str, name: str, body: DownloadRequest, x_device_id: str = Header(default="unknown", max_length=64)
    ) -> FileResponse:
        """The file one of the app's reviewed file locators names for these arguments (ADR-004 §6). The page
        gives the locator's name and typed arguments, never a path."""
        path, filename, mime, _size = store.locate_download(
            app_id, body.revision, name, body.args, device_id=x_device_id, tz_name=body.timezone
        )
        return _attachment(path, filename, mime, {"Cache-Control": "private, no-store"})

    @router.post("/apps/{app_id}/mutations/{name}")
    def mutate(
        app_id: str, name: str, body: MutationRequest, x_device_id: str = Header(default="unknown", max_length=64)
    ) -> Any:
        """Run one of the published app's reviewed mutations (ADR-004 §2-3). There is no such route for a draft
        under review: a preview never writes."""
        return store.run_mutation(
            app_id, body.revision, name, body.args, key=body.idempotencyKey, device_id=x_device_id,
            tz_name=body.timezone,
        )

    @router.get("/apps/{app_id}/files")
    def list_files(app_id: str) -> dict[str, Any]:
        return {"files": store.files.list_files(app_id)}

    @router.post("/apps/{app_id}/files")
    async def upload_file(
        app_id: str, request: Request, x_file_name: str = Header(default="", max_length=600)
    ) -> dict[str, Any]:
        """Store the request body as a file of the app. The body is the file itself, written to disk as it
        arrives (nothing is held in memory); the name is in `X-File-Name`, percent-encoded."""
        declared = request.headers.get("content-length", "")
        incoming, name, mime = await anyio.to_thread.run_sync(
            store.files.begin, app_id, unquote(x_file_name), int(declared) if declared.isdigit() else None
        )
        try:
            async for chunk in request.stream():
                if chunk:
                    await anyio.to_thread.run_sync(incoming.write, chunk)
            return await anyio.to_thread.run_sync(store.files.finish, app_id, incoming, name, mime)
        except BaseException:
            incoming.discard()
            raise

    @router.get("/apps/{app_id}/files/{file_id}")
    def get_file(app_id: str, file_id: str) -> FileResponse:
        path, record = store.files.get(app_id, file_id)
        return _attachment(
            path, record["name"], record["mime"],
            {"ETag": f'"{record["sha256"]}"', "Cache-Control": "private, max-age=31536000, immutable"},
        )

    @router.delete("/apps/{app_id}/files/{file_id}")
    def delete_file(app_id: str, file_id: str) -> dict[str, Any]:
        store.files.delete(app_id, file_id)
        return {"deleted": True}

    @router.get("/events")
    def events(since: int = 0, epoch: str | None = None) -> Any:
        # Polling mode of ADR-002 §6.3. SSE is added once S0-5 measures it through the dashboard.
        return store.events_since(since, epoch)

    if authoring is not None:
        # Review of a submitted draft (ADR-007 §5). A preview is the draft's own bundle and queries,
        # read-only; nothing here changes what other devices run except `approve`, which needs a
        # signature from the paired device.

        @router.get("/previews")
        def previews() -> dict[str, Any]:
            return {"previews": authoring.reviews(), "approverPaired": store.approver_count() > 0}

        @router.get("/previews/{app_id}")
        def preview_manifest(app_id: str) -> dict[str, Any]:
            return authoring.review_manifest(app_id)

        @router.get("/previews/{app_id}/bundles/{bundle_id}")
        def preview_bundle(app_id: str, bundle_id: str) -> FileResponse:
            return FileResponse(
                authoring.review_bundle_path(app_id, bundle_id),
                media_type="application/zip",
                headers={"ETag": f'"{bundle_id}"', "Cache-Control": "no-store"},
            )

        @router.post("/previews/{app_id}/data")
        def preview_data(
            app_id: str, body: DataRequest, x_device_id: str = Header(default="unknown", max_length=64)
        ) -> Any:
            return authoring.review_query(
                app_id, body.revision, [q.model_dump() for q in body.queries],
                device_id=x_device_id, tz_name=body.timezone,
            )

        @router.post("/previews/{app_id}/challenge")
        def preview_challenge(app_id: str) -> dict[str, Any]:
            return authoring.challenge(app_id)

        @router.post("/previews/{app_id}/approve")
        def preview_approve(app_id: str, body: Approval) -> dict[str, Any]:
            return authoring.approve(app_id, build_id=body.buildId, nonce=body.nonce, signature=body.signature)

        @router.post("/previews/{app_id}/reject")
        def preview_reject(app_id: str, body: Rejection) -> dict[str, Any]:
            return authoring.reject(app_id, expected_build_id=body.buildId)

        # Deleting a published app moves it to the server's trash; like publication it needs the paired
        # device's signature, over a message of its own (`ms-delete-v1`).

        @router.post("/apps/{app_id}/delete/challenge")
        def delete_challenge(app_id: str) -> dict[str, Any]:
            return authoring.delete_challenge(app_id)

        @router.post("/apps/{app_id}/delete")
        def delete_app(app_id: str, body: Deletion) -> dict[str, Any]:
            return authoring.delete_app(app_id, nonce=body.nonce, signature=body.signature)

    return router


def create_claim_router(store: Store, token: str) -> APIRouter:
    """The one route that needs no bearer: it is how a phone gets one. A valid one-time code is the
    credential; it is spent before anything is returned, and repeated misses lock the route for a minute."""
    router = APIRouter()

    @router.post("/devices/claim")
    def claim(body: Claim) -> dict[str, Any]:
        # Shape first, so a mistyped key cannot burn a good code.
        store.check_approver_fields(body.deviceId, body.publicKey)
        store.consume_pair_code(body.code)
        try:
            store.register_approver(body.deviceId, body.publicKey)
            paired = True
        except Conflict:  # another device is the approver: this one gets the token but cannot approve
            paired = False
        return {"token": token, "approverPaired": paired}

    return router


def mount(
    app: Any,
    store: Store,
    dependencies: Sequence[Any] = (),
    prefix: str = "/api/plugins/mobile-surfaces/v1",
    authoring: Authoring | None = None,
    claim_token: str | None = None,
) -> None:
    """Attach the router plus the StoreError -> JSON handler to a FastAPI app.

    `claim_token` is the bearer this server accepts; when given, connection codes can be exchanged for it
    on `/devices/claim`, the only route outside the bearer dependency.
    """

    @app.exception_handler(StoreError)
    async def _store_error(request: Request, exc: StoreError) -> JSONResponse:
        body: dict[str, Any] = {"error": str(exc)}
        if exc.code:
            body["code"] = exc.code
        return JSONResponse(body, status_code=exc.status)

    app.include_router(create_router(store, dependencies, authoring), prefix=prefix)
    if claim_token is not None:
        app.include_router(create_claim_router(store, claim_token), prefix=prefix)

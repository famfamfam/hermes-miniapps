"""Stage 0 dev server: phone API and MCP author tools in one process, behind a static bearer token.

Not for production. Binding is 127.0.0.1 by default; reach it from a USB-connected phone with
`adb reverse tcp:8787 tcp:8787`.

  :8787 /api/plugins/mobile-surfaces/v1/...   phone API (ADR-002), token in plugin/.devhome/dev-token
  :8788 /mcp                                  author tools for Hermes (MCP, Streamable HTTP),
                                              loopback only, its own token in .devhome/mcp-token

They are separate listeners with separate tokens on purpose: the phone API may have to be reachable
from outside, the MCP tools can run SQL writes and must not be. Both use the same Store, so a tool
call made by the agent is visible to the phone API at once. Hermes is configured with the MCP
endpoint in ~/.hermes/config.yaml:

  mcp_servers:
    surfaces:
      url: "http://127.0.0.1:8788/mcp"
      headers:
        Authorization: "Bearer <mcp token>"
"""
from __future__ import annotations

import argparse
import hmac
import os
import re
import secrets
import shlex
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Callable, Mapping

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException

from mobile_surfaces.api import mount
from mobile_surfaces.mcp_server import create_mcp
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.builder import Builder
from mobile_surfaces_core.store import Store


def load_token(home: Path, name: str = "dev-token") -> str:
    """Per-purpose token files. MS_DEV_TOKEN / MS_MCP_TOKEN override them (for scripted runs)."""
    env = os.environ.get("MS_DEV_TOKEN" if name == "dev-token" else "MS_MCP_TOKEN")
    if env:
        return env
    path = home / name
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(secrets.token_urlsafe(24))
    return path.read_text().strip()


MIN_TOKEN_CHARS = 24


def read_token_file(spec: str, environ: Mapping[str, str] | None = None) -> str:
    """Token from an existing file, or from a systemd credential (`credential:NAME`, found in
    $CREDENTIALS_DIRECTORY). Unlike `load_token` this never creates anything, and error messages never
    contain the value. This is how the installed service gets its tokens (see the README)."""
    env = os.environ if environ is None else environ
    if spec.startswith("credential:"):
        directory = env.get("CREDENTIALS_DIRECTORY")
        name = spec.partition(":")[2]
        if not directory:
            raise SystemExit(f"{spec}: systemd did not provide $CREDENTIALS_DIRECTORY (is LoadCredential= set?)")
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", name):
            raise SystemExit(f"{spec}: not a valid credential name")
        path = Path(directory) / name
    else:
        path = Path(spec)
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise SystemExit(f"cannot read token file {spec}: {exc.strerror or type(exc).__name__}") from None
    if len(value) < MIN_TOKEN_CHARS:
        raise SystemExit(f"token file {spec} holds fewer than {MIN_TOKEN_CHARS} characters; refusing to start")
    return value


class BearerGuard:
    """Pure ASGI middleware (it must not buffer streams): bearer token for everything under a prefix."""

    def __init__(self, app: Any, *, token: str, prefix: str) -> None:
        self.app = app
        self.token = token
        self.prefix = prefix

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        path = scope.get("path", "")
        if scope["type"] == "http" and (path == self.prefix or path.startswith(self.prefix + "/")):
            raw = dict(scope["headers"]).get(b"authorization", b"").decode("latin-1")
            scheme, _, value = raw.partition(" ")
            if scheme.lower() != "bearer" or not hmac.compare_digest(value, self.token):
                await send({
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [(b"content-type", b"application/json"), (b"www-authenticate", b"Bearer")],
                })
                await send({"type": "http.response.body", "body": b'{"detail":"unauthorized"}'})
                return
        await self.app(scope, receive, send)


def build_app(
    home: Path,
    token: str,
    *,
    allowed_hosts: list[str] | None = None,
    serve_api: bool = True,
    serve_mcp: bool = True,
    mcp_token: str | None = None,
    make_authoring: Callable[[Store], Authoring | None] | None = None,
) -> FastAPI:
    """One ASGI app. Tests use the combined form; `main()` runs two, so that the MCP write tools
    never share a listener (or a token) with the phone API.

    `make_authoring` receives the app's Store and returns the interface-authoring service (draft,
    build, publish) whose tools are then added to MCP; None leaves the data tools only.
    """
    store = Store(home)
    authoring = make_authoring(store) if make_authoring else None
    lifespan = None
    mcp_routes: list[Any] = []
    if serve_mcp:
        mcp = create_mcp(store, allowed_hosts=allowed_hosts, authoring=authoring)
        mcp_routes = list(mcp.streamable_http_app().routes)  # also creates mcp.session_manager

        @asynccontextmanager
        async def lifespan(_app: FastAPI):  # noqa: F811 - only defined when MCP is served
            async with mcp.session_manager.run():
                yield

    def require_token(authorization: str = Header(default="")) -> None:
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(value, token):
            raise HTTPException(status_code=401, detail="unauthorized")

    app = FastAPI(
        title="mobile-surfaces dev server", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan
    )
    if serve_api:
        mount(app, store, dependencies=[Depends(require_token)], authoring=authoring, claim_token=token)
    if serve_mcp:
        app.router.routes.extend(mcp_routes)  # serves /mcp
        app.add_middleware(BearerGuard, token=mcp_token or token, prefix="/mcp")
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", type=Path, default=Path(".devhome"))
    parser.add_argument("--host", default="127.0.0.1", help="phone API bind address")
    parser.add_argument("--port", type=int, default=8787, help="phone API port")
    parser.add_argument("--mcp-host", default="127.0.0.1", help="MCP bind address; keep it on loopback")
    parser.add_argument("--mcp-port", type=int, default=8788, help="MCP port (a separate listener)")
    parser.add_argument("--no-mcp", action="store_true", help="do not serve MCP at all")
    parser.add_argument(
        "--token-file",
        help="read the phone API token from this existing file (or `credential:NAME` under $CREDENTIALS_DIRECTORY); "
             "nothing is created and no token is printed",
    )
    parser.add_argument("--mcp-token-file", help="the same for the MCP token; required with --token-file unless --no-mcp")
    parser.add_argument("--no-authoring", action="store_true", help="never start interface authoring, whatever is installed")
    root = Path(__file__).resolve().parent.parent
    parser.add_argument(
        "--template",
        type=Path,
        default=root / "templates" / "starter-app",
        help="authoring template (dependencies installed with `npm ci`); interface tools are off without it",
    )
    parser.add_argument("--sdk", type=Path, default=root / "packages" / "mobile-sdk" / "src", help="SDK sources")
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="writable directory for throw-away build projects (needed when the template is read-only)",
    )
    parser.add_argument("--build-timeout", type=float, default=120.0, help="seconds allowed per interface build")
    parser.add_argument(
        "--build-prefix",
        default="",
        help='command placed before node in builds, e.g. "systemd-run --pipe --wait -p PrivateNetwork=yes"',
    )
    parser.add_argument(
        "--allow-host",
        action="append",
        default=[],
        help="extra Host header accepted on MCP, e.g. hermes.internal:8788 (repeatable)",
    )
    args = parser.parse_args()
    from_files = args.token_file is not None
    if from_files and not args.no_mcp and args.mcp_token_file is None:
        parser.error("--token-file needs --mcp-token-file as well (or --no-mcp); the two tokens must be separate")
    if args.mcp_token_file is not None and not from_files:
        parser.error("--mcp-token-file needs --token-file as well")
    if from_files:
        token = read_token_file(args.token_file)
        print(f"phone API  http://{args.host}:{args.port}  token: from {args.token_file}")
    else:
        token = load_token(args.home)
        print(f"phone API  http://{args.host}:{args.port}  token: {token}")
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("WARNING: the phone API is on a non-loopback address over plain HTTP; use demo data only,")
        print("         and put TLS or a private network (e.g. Tailscale) in front before real data.")

    if not args.no_mcp:
        mcp_token = read_token_file(args.mcp_token_file) if from_files else load_token(args.home, "mcp-token")
        if from_files and hmac.compare_digest(mcp_token, token):
            raise SystemExit("the phone API token and the MCP token must differ")
        allowed = ["127.0.0.1:*", "localhost:*", "[::1]:*", *args.allow_host]

        def make_authoring(store: Store) -> Authoring | None:
            if args.no_authoring:
                print("interface tools OFF: disabled with --no-authoring")
                return None
            builder = Builder(
                args.template, args.sdk, timeout_s=args.build_timeout, command_prefix=shlex.split(args.build_prefix),
                work_dir=args.work_dir,
            )
            reason = builder.available()
            if reason:
                print(f"interface tools OFF: {reason}")
                return None
            print(f"interface tools ON: template {args.template}, build limit {args.build_timeout:.0f}s")
            return Authoring(store, args.template, builder)

        mcp_app = build_app(
            args.home, token, serve_api=False, mcp_token=mcp_token, allowed_hosts=allowed,
            make_authoring=make_authoring,
        )
        mcp_server = uvicorn.Server(
            uvicorn.Config(mcp_app, host=args.mcp_host, port=args.mcp_port, log_level="warning", lifespan="on")
        )
        # Non-main thread: uvicorn then leaves signal handling to the main server.
        threading.Thread(target=mcp_server.run, name="mcp", daemon=True).start()
        shown = f"from {args.mcp_token_file}" if from_files else mcp_token
        print(f"MCP        http://{args.mcp_host}:{args.mcp_port}/mcp  token: {shown}")
        if args.mcp_host not in ("127.0.0.1", "localhost", "::1"):
            print("WARNING: MCP exposes SQL write tools; it should stay on loopback.")

    print(f"data in {args.home.resolve()}")

    def review_only(store: Store) -> Authoring:
        # The phone API only reviews and approves; builds happen in the MCP process.
        return Authoring(store, args.template, builder=None)

    phone_app = build_app(args.home, token, serve_mcp=False, make_authoring=review_only)
    uvicorn.run(phone_app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()

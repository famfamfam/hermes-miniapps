"""Canary for the S0-3 isolation probe: any connection or datagram it sees is a leak.

  python tools/canary.py                      # TCP+UDP on 0.0.0.0, ports 10000-10049
  python tools/canary.py --ports 9999-9999    # a single port

Every probe test uses its own port (base + index), and every line names the port, so a leak
is attributed to one channel. Over USB the phone reaches the PC with `adb reverse` (TCP only):

  for p in (10000..10049): adb reverse tcp:$p tcp:$p

UDP (WebRTC/STUN) is not carried by adb reverse. To exercise it, give the probe the PC's LAN
address instead and allow Python through the Windows firewall.

Silence means no channel reached the network. TLS never completes here, so the first bytes of a
connection are a handshake; that is still a leak, because the attempt left the page.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime
import re


def stamp() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


def describe(data: bytes) -> str:
    if data[:1] == b"\x16":
        return "TLS ClientHello (https/wss/preconnect)"
    text = data[:200].decode("latin-1", "replace")
    first = text.splitlines()[0] if text else ""
    m = re.search(r"ch=([\w%-]+)", first)
    is_http = first[:3] in ("GET", "POS", "PUT", "OPT", "HEA", "CON")
    label = f"HTTP {first[:90]}" if is_http else f"{len(data)} bytes {data[:16].hex()}"
    return label + (f"  [channel: {m.group(1)}]" if m else "")


class Udp(asyncio.DatagramProtocol):
    def __init__(self, port: int) -> None:
        self.port = port

    def datagram_received(self, data: bytes, addr) -> None:  # noqa: ANN001
        stun = len(data) >= 20 and data[4:8] == b"\x21\x12\xa4\x42"
        kind = "STUN binding request (WebRTC)" if stun else f"{len(data)} bytes"
        print(f"{stamp()}  LEAK  port {self.port}  UDP from {addr[0]}:{addr[1]}  {kind}", flush=True)


def tcp_handler(port: int):
    async def on_tcp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        try:
            data = await asyncio.wait_for(reader.read(512), timeout=2)
        except (asyncio.TimeoutError, ConnectionError):
            data = b""
        what = describe(data) if data else "connected, sent nothing"
        print(f"{stamp()}  LEAK  port {port}  TCP from {peer[0]}:{peer[1]}  {what}", flush=True)
        writer.close()

    return on_tcp


async def main(first: int, last: int) -> None:
    loop = asyncio.get_running_loop()
    servers = []
    for port in range(first, last + 1):
        servers.append(await asyncio.start_server(tcp_handler(port), "0.0.0.0", port))
        await loop.create_datagram_endpoint(lambda p=port: Udp(p), local_addr=("0.0.0.0", port))
    print(f"canary listening on 0.0.0.0:{first}-{last} (TCP+UDP). Any LEAK line below is an escape.", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ports", default="10000-10049", help="first-last")
    args = ap.parse_args()
    a, _, b = args.ports.partition("-")
    try:
        asyncio.run(main(int(a), int(b or a)))
    except KeyboardInterrupt:
        pass

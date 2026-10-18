import type { Rpc, Transport } from "./types";

/** Object injected by the Flutter host (WebMessageListener), only into frames of the app's own origin. */
interface HostObject {
  postMessage(message: string): void;
  onmessage: ((event: { data: string }) => void) | null;
}

declare global {
  interface Window {
    hermesHost?: HostObject;
  }
}

const CALL_TIMEOUT_MS = 20_000;

/**
 * Operations that wait for the person (a picker, a sheet, a confirmation) or move a whole file over a mobile link.
 * Twenty seconds would reject them while the phone is still doing what was asked.
 */
const LONG_CALL_TIMEOUT_MS = 10 * 60_000;
const LONG_OPS = new Set(["pickFile", "saveFile", "deleteFile", "askHermes", "mutate"]);

type Pending = {
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer: ReturnType<typeof setTimeout>;
};

export function hostAvailable(): boolean {
  return typeof window.hermesHost?.postMessage === "function";
}

let singleton: Transport | null = null;

function fail(code: string, message: string): Error {
  return Object.assign(new Error(message), { code });
}

/** Real transport: the only channel to the host. JS never gets an HTTP client or tokens. */
export function hostTransport(): Transport | null {
  if (singleton) return singleton;
  const host = window.hermesHost;
  if (!host || typeof host.postMessage !== "function") return null;
  const pending = new Map<number, Pending>();
  let seq = 0;

  host.onmessage = (event) => {
    let msg: { id?: number; ok?: boolean; value?: unknown; error?: { code: string; message: string } };
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    const entry = typeof msg.id === "number" ? pending.get(msg.id) : undefined;
    if (!entry) return;
    pending.delete(msg.id!);
    clearTimeout(entry.timer);
    if (msg.ok) entry.resolve(msg.value);
    else entry.reject(fail(msg.error?.code ?? "error", msg.error?.message ?? "host error"));
  };

  singleton = {
    call(rpc: Rpc) {
      return new Promise((resolve, reject) => {
        const id = ++seq;
        const timer = setTimeout(
          () => {
            pending.delete(id);
            reject(fail("timeout", "host did not answer"));
          },
          LONG_OPS.has(rpc.op) ? LONG_CALL_TIMEOUT_MS : CALL_TIMEOUT_MS,
        );
        pending.set(id, { resolve, reject, timer });
        host.postMessage(JSON.stringify({ id, rpc }));
      });
    },
  };
  return singleton;
}

import { DATA_CHANGED_EVENT } from "./events";
import { hostAvailable, hostTransport } from "./transport";
import type {
  FileAction,
  FileInfo,
  FileSource,
  GroupResult,
  HelloReply,
  HostState,
  MutationResult,
  QueryCall,
  QueryResult,
  Rpc,
  Transport,
} from "./types";

/** Where the host answers with a stored picture of this app, so a plain `<img>` can show it. */
const FILES_PATH = "/__hermes/files/";

let transport: Transport | null = null;
let mockFactory: (() => Transport) | null = null;

/** Browser dev server / tests register a mock; inside the host the real bridge always wins. */
export function installMockTransport(factory: () => Transport): void {
  mockFactory = factory;
}

function current(): Transport {
  if (!transport) transport = hostTransport() ?? mockFactory?.() ?? null;
  if (!transport) throw new Error("Hermes host bridge is not available");
  return transport;
}

export const hermes = {
  isHosted(): boolean {
    return hostAvailable();
  },

  hello(): Promise<HelloReply> {
    return current().call({ op: "hello" }) as Promise<HelloReply>;
  },

  hostState(): Promise<HostState> {
    return current().call({ op: "hostState" }) as Promise<HostState>;
  },

  /** Several queries answered from one consistent dataRev. */
  queryGroup(calls: QueryCall[]): Promise<GroupResult> {
    const rpc: Rpc = { op: "query", calls };
    return current().call(rpc) as Promise<GroupResult>;
  },

  /**
   * Opens the phone's own file picker (`accept`: media types such as "image/*" or "application/pdf"; none = any) and
   * stores the chosen file for this app. Resolves with the stored file, or null when the user closed the picker.
   * The file's bytes never pass through the page: only its name, type and size come back.
   * Rejects with `code`: too_large (over 20 MB), bad_file (not accepted: the message says why), server_full,
   * offline, preview_blocked, unsupported.
   */
  async pickFile(options?: { accept?: string[] }): Promise<FileInfo | null> {
    const rpc: Rpc = { op: "pickFile", ...(options?.accept ? { accept: options.accept } : {}) };
    return (await current().call(rpc)) as FileInfo | null;
  },

  /**
   * Gets a file onto the phone: from a stored file of this app (`{ fileId }`) or from a file locator of
   * definitions.json (`{ name, args }`, e.g. `{ name: "receipt_file", args: { id: 42 } }`). The phone then shows its own
   * sheet (save, open, share); nothing is saved until the user chooses. Resolves with what they chose.
   */
  async saveFile(source: FileSource): Promise<{ action: FileAction; name: string }> {
    const rpc: Rpc = { op: "saveFile", ...source } as Rpc;
    return (await current().call(rpc)) as { action: FileAction; name: string };
  },

  /**
   * Hands a message to Hermes as the user's own: the phone shows the whole text (plus where the attached files
   * are kept) and sends it only after the user taps Send, in a new chat. Build `prompt` from the form (at most 2400
   * characters); `fileIds` are files of this app. Resolves with `{ sent: false }` when the user declined.
   */
  async askHermes(prompt: string, fileIds: string[] = []): Promise<{ sent: boolean }> {
    return (await current().call({ op: "askHermes", prompt, fileIds })) as { sent: boolean };
  },

  /**
   * A button that writes: runs one of the app's mutations from definitions.json (`name`, typed `args`, e.g.
   * `mutate("mark_paid", { id: 42 })`). The page sends no SQL: the server runs the SQL that was reviewed and signed
   * with the app. The phone asks the user first when the mutation deletes (or the author asked for it), and it
   * never saves while offline or in a preview. On success the queries on screen are read again.
   *
   * Rejects with `code`: offline (nothing was saved), unknown_outcome (no answer: it may or may not have been saved;
   * calling again with the same arguments is safe, the server will not apply it twice), busy (the same call is already
   * running), too_many_requests, stale_revision (the app was updated: it reloads), unknown_mutation, rejected (the
   * server refused these values: the message says why), preview_blocked, unauthorized, server_old, server_error.
   */
  async mutate(name: string, args?: QueryCall["args"]): Promise<MutationResult> {
    const rpc: Rpc = { op: "mutate", name, ...(args ? { args } : {}) };
    const out = (await current().call(rpc)) as MutationResult;
    if (out.done) window.dispatchEvent(new Event(DATA_CHANGED_EVENT));
    return out;
  },

  /** The files kept for this app, newest first. */
  files: {
    async list(): Promise<FileInfo[]> {
      const reply = (await current().call({ op: "listFiles" })) as { files: FileInfo[] };
      return reply.files;
    },
    /** Asks the user first; resolves false when they said no. */
    async delete(fileId: string): Promise<boolean> {
      const reply = (await current().call({ op: "deleteFile", fileId })) as { deleted: boolean };
      return reply.deleted;
    },
  },

  /** The address to put in an `<img src>` to show a stored picture (png, jpg, webp, gif) of this app. */
  fileUrl(fileId: string): string {
    return `${FILES_PATH}${encodeURIComponent(fileId)}`;
  },

  async query<T = unknown>(name: string, args?: QueryCall["args"]): Promise<QueryResult<T>> {
    const group = await hermes.queryGroup([{ name, args }]);
    const one = group.results[name];
    return {
      data: one.data as T,
      completeness: one.completeness,
      dataRev: group.dataRev,
      fetchedAt: group.fetchedAt,
      freshness: group.freshness,
    };
  },
};

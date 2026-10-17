/** Shapes shared between the React SDK and the Flutter host bridge (ADR-005 §2). */

export type Completeness = "complete" | "bounded";
export type Freshness = "live" | "cached";

export interface QueryCall {
  name: string;
  args?: Record<string, string | number | boolean | null>;
}

export interface QueryMeta {
  dataRev: number;
  fetchedAt: string;
  freshness: Freshness;
  completeness: Completeness;
}

export interface QueryResult<T = unknown> extends QueryMeta {
  data: T;
}

export interface GroupResult {
  dataRev: number;
  fetchedAt: string;
  freshness: Freshness;
  results: Record<string, { data: unknown; completeness: Completeness }>;
}

export interface HostState {
  locale: string;
  theme: "light" | "dark";
  timezone: string;
  online: boolean;
  preview: boolean;
}

export interface HelloReply {
  bridgeVersion: number;
  sdkMajor: number;
  appId: string;
  revision: number;
}

/** Error the host returns for a rejected or failed RPC. */
export interface BridgeError {
  code: string;
  message: string;
}

/** A file the server keeps for this app (what a picked file becomes, and what the author's tools can import). */
export interface FileInfo {
  fileId: string;
  name: string;
  mime: string;
  size: number;
  createdAt: string;
  /** Only right after a pick: the server already had this exact content, so no second copy was made. */
  duplicate?: boolean;
}

/** What the user chose to do with a file that was offered to them. */
export type FileAction = "saved" | "opened" | "shared" | "cancelled";

/** Where a download comes from: a stored file of this app, or a file locator of definitions.json with its arguments. */
export type FileSource = { fileId: string } | { name: string; args?: QueryCall["args"] };

export type Rpc =
  | { op: "hello" }
  | { op: "hostState" }
  | { op: "query"; calls: QueryCall[] }
  | { op: "pickFile"; accept?: string[] }
  | { op: "listFiles" }
  | { op: "deleteFile"; fileId: string }
  | ({ op: "saveFile" } & FileSource)
  | { op: "askHermes"; prompt: string; fileIds?: string[] };

export interface Transport {
  call(rpc: Rpc): Promise<unknown>;
}

import { useCallback, useEffect, useRef, useState } from "react";
import { hermes } from "./client";
import { DATA_CHANGED_EVENT, FILES_CHANGED_EVENT } from "./events";
import type { BridgeError, FileInfo, GroupResult, HostState, MutationResult, QueryCall } from "./types";

export { DATA_CHANGED_EVENT, FILES_CHANGED_EVENT };

export interface GroupState {
  loading: boolean;
  error: string | null;
  group: GroupResult | null;
  refetch(): void;
}

/**
 * Reads several named queries in one request. A newer call always wins: a late answer to an
 * older argument set is discarded (ADR-002 §7, generation guard).
 */
export function useQueryGroup(calls: QueryCall[]): GroupState {
  const key = JSON.stringify(calls);
  const generation = useRef(0);
  const [state, setState] = useState<Omit<GroupState, "refetch">>({ loading: true, error: null, group: null });

  const run = useCallback(() => {
    const mine = ++generation.current;
    setState((s) => ({ ...s, loading: true }));
    hermes
      .queryGroup(JSON.parse(key) as QueryCall[])
      .then((group) => {
        if (mine === generation.current) setState({ loading: false, error: null, group });
      })
      .catch((e: unknown) => {
        if (mine === generation.current) {
          setState((s) => ({ ...s, loading: false, error: e instanceof Error ? e.message : String(e) }));
        }
      });
  }, [key]);

  useEffect(() => {
    run();
    window.addEventListener(DATA_CHANGED_EVENT, run);
    return () => window.removeEventListener(DATA_CHANGED_EVENT, run);
  }, [run]);

  return { ...state, refetch: run };
}

export interface FilesState {
  loading: boolean;
  error: string | null;
  files: FileInfo[];
  refetch(): void;
}

/** The files kept for this app, newest first; read again whenever the host says they changed. */
export function useFiles(): FilesState {
  const generation = useRef(0);
  const [state, setState] = useState<Omit<FilesState, "refetch">>({ loading: true, error: null, files: [] });

  const run = useCallback(() => {
    const mine = ++generation.current;
    setState((s) => ({ ...s, loading: true }));
    hermes.files
      .list()
      .then((files) => {
        if (mine === generation.current) setState({ loading: false, error: null, files });
      })
      .catch((e: unknown) => {
        if (mine === generation.current) {
          setState((s) => ({ ...s, loading: false, error: e instanceof Error ? e.message : String(e) }));
        }
      });
  }, []);

  useEffect(() => {
    run();
    window.addEventListener(FILES_CHANGED_EVENT, run);
    return () => window.removeEventListener(FILES_CHANGED_EVENT, run);
  }, [run]);

  return { ...state, refetch: run };
}

export function useHostState(): HostState | null {
  const [state, setState] = useState<HostState | null>(null);
  useEffect(() => {
    let alive = true;
    hermes.hostState().then((s) => alive && setState(s)).catch(() => undefined);
    return () => {
      alive = false;
    };
  }, []);
  return state;
}

export interface MutationState {
  /** A call is in flight: show it on the button. A second `run` is ignored meanwhile. */
  pending: boolean;
  /** Why the last call failed; null after a success, a decline, or `reset()`. */
  error: BridgeError | null;
  /** What the last call returned (`done: false` when the user declined the confirmation). */
  result: MutationResult | null;
  /** Resolves with the result, or null when it failed (see `error`) or another call was still running. Never rejects. */
  run(args?: QueryCall["args"]): Promise<MutationResult | null>;
  reset(): void;
}

/** A button that writes (see `hermes.mutate`): `const save = useMutation("mark_paid"); save.run({ id })`. */
export function useMutation(name: string): MutationState {
  const alive = useRef(true);
  const busy = useRef(false);
  const [state, setState] = useState<Pick<MutationState, "pending" | "error" | "result">>({
    pending: false,
    error: null,
    result: null,
  });

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const run = useCallback(
    async (args?: QueryCall["args"]) => {
      if (busy.current) return null;
      busy.current = true;
      if (alive.current) setState((s) => ({ ...s, pending: true, error: null }));
      try {
        const result = await hermes.mutate(name, args);
        if (alive.current) setState({ pending: false, error: null, result });
        return result;
      } catch (e: unknown) {
        const code = typeof (e as { code?: unknown })?.code === "string" ? (e as { code: string }).code : "error";
        const message = e instanceof Error ? e.message : String(e);
        if (alive.current) setState((s) => ({ ...s, pending: false, error: { code, message } }));
        return null;
      } finally {
        busy.current = false;
      }
    },
    [name],
  );

  const reset = useCallback(() => setState({ pending: false, error: null, result: null }), []);
  return { ...state, run, reset };
}
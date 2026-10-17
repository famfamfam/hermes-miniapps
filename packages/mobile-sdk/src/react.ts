import { useCallback, useEffect, useRef, useState } from "react";
import { hermes } from "./client";
import type { FileInfo, GroupResult, HostState, QueryCall } from "./types";

export interface GroupState {
  loading: boolean;
  error: string | null;
  group: GroupResult | null;
  refetch(): void;
}

/** Event the host dispatches on the window when a data.changed event or resume happens. */
export const DATA_CHANGED_EVENT = "hermes:data-changed";

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

/** Event the host dispatches on the window when the app's stored files change (another device, the author's tools). */
export const FILES_CHANGED_EVENT = "hermes:files-changed";

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

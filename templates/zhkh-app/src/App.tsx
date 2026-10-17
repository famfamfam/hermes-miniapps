import { useEffect, useState } from "react";
import { Overview, Receipts, ReceiptDetail } from "./screens";

const ROUTES = [
  { path: "/", label: "Обзор", view: Overview },
  { path: "/receipts", label: "Квитанции", view: Receipts },
] as const;

function currentPath(): string {
  const p = window.location.hash.replace(/^#/, "");
  if (ROUTES.some((r) => r.path === p)) {
    return p;
  }
  if (/^\/receipt\/\d+$/.test(p)) {
    return p;
  }
  return "/";
}

/** Hash routing: works from any virtual origin and gives the host a real history for Back. */
export default function App() {
  const [path, setPath] = useState(currentPath);
  useEffect(() => {
    const onHash = () => setPath(currentPath());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const detail = /^\/receipt\/(\d+)$/.exec(path);
  const route = ROUTES.find((r) => r.path === path);
  return (
    <div className="app">
      <main className="screen">
        {detail ? (
          <ReceiptDetail id={Number(detail[1])} />
        ) : route ? (
          <route.view />
        ) : null}
      </main>
      {!detail && (
        <nav className="tabs" aria-label="Разделы">
          {ROUTES.map((r) => (
            <a key={r.path} href={`#${r.path}`} aria-current={route?.path === r.path ? "page" : undefined}>
              {r.label}
            </a>
          ))}
        </nav>
      )}
    </div>
  );
}

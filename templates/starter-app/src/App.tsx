import { useEffect, useState } from "react";
import { Overview } from "./screens";
import { tr } from "./format";

// One entry per bottom tab. Add a screen: export it from screens.tsx and list it here.
const ROUTES = [{ path: "/", label: tr("Обзор", "Overview"), view: Overview }] as const;

function currentPath(): string {
  const p = window.location.hash.replace(/^#/, "");
  return ROUTES.some((r) => r.path === p) ? p : "/";
}

/** Hash routing: works from any virtual origin and gives the host a real history for Back. */
export default function App() {
  const [path, setPath] = useState(currentPath);
  useEffect(() => {
    const onHash = () => setPath(currentPath());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const View = ROUTES.find((r) => r.path === path)!.view;
  return (
    <div className="app">
      <main className="screen">
        <View />
      </main>
      {ROUTES.length > 1 && (
        <nav className="tabs" aria-label={tr("Разделы", "Sections")}>
          {ROUTES.map((r) => (
            <a key={r.path} href={`#${r.path}`} aria-current={r.path === path ? "page" : undefined}>
              {r.label}
            </a>
          ))}
        </nav>
      )}
    </div>
  );
}

import { useEffect, useState } from "react";
import { AddBill, Bills, Overview } from "./screens";

const ROUTES = [
  { path: "/", label: "Overview", view: Overview },
  { path: "/bills", label: "Bills", view: Bills },
  { path: "/add", label: "Add", view: AddBill },
] as const;

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
      <nav className="tabs" aria-label="Sections">
        {ROUTES.map((r) => (
          <a key={r.path} href={`#${r.path}`} aria-current={r.path === path ? "page" : undefined}>
            {r.label}
          </a>
        ))}
      </nav>
    </div>
  );
}

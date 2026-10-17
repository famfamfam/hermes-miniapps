import { tr } from "./format";

/** Replace this placeholder. The `reference` tool lists the SDK hooks and the component kit. */
export function Overview() {
  return (
    <section>
      <h1>{tr("Новое приложение", "New app")}</h1>
      <p className="muted">{tr("Экраны ещё не созданы.", "No screens yet.")}</p>
    </section>
  );
}

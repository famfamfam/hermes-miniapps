import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { hermes, installMockTransport } from "@hermes/mobile-sdk";
import App from "./App";
import "./styles.css";

async function start() {
  // Browser-only dev convenience; stripped from the production bundle.
  if (import.meta.env.DEV && !hermes.isHosted()) {
    const { createMockTransport } = await import("./dev-mock");
    installMockTransport(createMockTransport);
  }
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

void start();

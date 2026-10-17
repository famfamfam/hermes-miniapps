import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The bundle is served from a virtual origin by the Flutter host: relative asset URLs,
// no inline scripts, no remote resources (CSP script-src 'self').
export default defineConfig({
  base: "./",
  plugins: [react()],
  resolve: {
    // The SDK sits outside this project; make it use this project's single copy of React.
    dedupe: ["react", "react-dom"],
    alias: { "@hermes/mobile-sdk": path.resolve(import.meta.dirname, "../../packages/mobile-sdk/src/index.ts") },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    modulePreload: { polyfill: false },
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 600,
  },
  server: { fs: { allow: [path.resolve(import.meta.dirname, "../..")] } },
});

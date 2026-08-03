import { defineConfig } from "vitest/config";
import solidPlugin from "vite-plugin-solid";

// Standalone Vitest config (not the app's vite.config.ts) so the test run
// doesn't pull in the dev-only devtools/tailwind plugins. `vite-plugin-solid`
// provides the JSX transform; jsdom gives us `window`/`localStorage`/
// `EventSource`-adjacent globals for the DOM-touching helpers.
export default defineConfig({
  plugins: [solidPlugin()],
  resolve: {
    // Match @solidjs/testing-library guidance: load the browser build of
    // solid-js under test, not the server build.
    conditions: ["development", "browser"],
  },
  test: {
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
  },
});

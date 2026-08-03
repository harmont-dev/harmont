/* @refresh reload */
import "./index.css";
import { render } from "solid-js/web";
import "solid-devtools";
import App from "./App";

const root = document.getElementById("root");

if (import.meta.env.DEV && !(root instanceof HTMLElement)) {
  throw new Error(
    "Root element not found. Did you forget to add it to your index.html? Or maybe the id attribute got misspelled?",
  );
}

async function boot() {
  if (import.meta.env.VITE_MOCK === "true") {
    const { worker } = await import("./mocks/browser");
    await worker.start({ onUnhandledRequest: "bypass" });

    // Mock mode has no real login ceremony (passkey/OAuth need a real
    // authenticator or provider), so seed a session token when none exists.
    // The mock `/api/v0/user` returns the mock user for any token, landing
    // the reviewer logged in. Inert in prod (VITE_MOCK unset).
    const { hasToken, setToken } = await import("./auth/token");
    const { mockToken } = await import("./mocks/data");
    if (!hasToken()) setToken(mockToken);
  }
  render(() => <App />, root!);
}

boot();

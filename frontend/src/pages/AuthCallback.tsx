import { onMount } from "solid-js";

export function AuthCallbackPage() {
  onMount(() => {
    const params = new URLSearchParams(window.location.search);
    const code = params.get("code");
    const error = params.get("error");
    // Echo the provider's `state` back to the opener so it can verify the
    // nonce it minted (anti-CSRF). The opener — not this page — owns the check.
    const state = params.get("state");

    if (window.opener) {
      window.opener.postMessage(
        {
          type: "harmont_oauth",
          code: code ?? undefined,
          error: error ?? undefined,
          state: state ?? undefined,
        },
        window.location.origin,
      );
    }
    window.close();
  });

  return (
    <div class="flex items-center justify-center h-screen bg-bg">
      <p class="font-mono text-sm text-fg-muted">Completing sign-in...</p>
    </div>
  );
}

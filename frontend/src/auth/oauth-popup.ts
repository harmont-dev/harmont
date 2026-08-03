type OAuthResult =
  | { ok: true; code: string }
  | { ok: false; error: string };

// Mints a fresh CSRF `state` nonce for an OAuth authorize request. The same
// value is embedded in the authorize URL and passed to `openOAuthPopup` as the
// expected state; the popup rejects any callback that doesn't echo it back.
export function mintOAuthState(): string {
  return crypto.randomUUID();
}

// Opens the provider's authorize URL in a popup and resolves with the `code`
// the AuthCallback page posts back.
//
// `expectedState` is the CSRF `state` nonce minted by the caller and embedded
// in the authorize URL. The provider echoes it back; we require the popup's
// message to carry exactly that value before trusting the `code`. A missing or
// mismatched state is rejected — that is the anti-CSRF check (an attacker who
// can inject a callback can't forge a `state` they never saw).
export function openOAuthPopup(
  url: string,
  expectedState: string,
): Promise<OAuthResult> {
  return new Promise((resolve) => {
    const width = 500;
    const height = 600;
    const left = window.screenX + (window.innerWidth - width) / 2;
    const top = window.screenY + (window.innerHeight - height) / 2;

    const popup = window.open(
      url,
      "oauth-popup",
      `width=${width},height=${height},left=${left},top=${top},popup=yes`,
    );

    if (!popup) {
      resolve({ ok: false, error: "Popup blocked by browser" });
      return;
    }

    const handleMessage = (e: MessageEvent) => {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== "harmont_oauth") return;
      cleanup();
      if (e.data.error) {
        resolve({ ok: false, error: e.data.error });
        return;
      }
      if (typeof e.data.state !== "string" || e.data.state !== expectedState) {
        resolve({
          ok: false,
          error:
            "Sign-in could not be verified (state mismatch). Start the sign-in again.",
        });
        return;
      }
      resolve({ ok: true, code: e.data.code });
    };

    const pollClosed = setInterval(() => {
      if (popup.closed) {
        cleanup();
        resolve({ ok: false, error: "Popup closed" });
      }
    }, 500);

    const cleanup = () => {
      window.removeEventListener("message", handleMessage);
      clearInterval(pollClosed);
    };

    window.addEventListener("message", handleMessage);
  });
}

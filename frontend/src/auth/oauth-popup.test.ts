import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mintOAuthState, openOAuthPopup } from "./oauth-popup";

// A stand-in for the popup Window: never reports closed unless we say so, so
// the closed-poll doesn't resolve the promise out from under us.
function fakePopup() {
  return { closed: false } as unknown as Window;
}

// Post a message into the opener as the callback page would.
function postOAuthMessage(
  data: Record<string, unknown>,
  origin = window.location.origin,
) {
  window.dispatchEvent(new MessageEvent("message", { data, origin }));
}

describe("mintOAuthState", () => {
  it("produces distinct values", () => {
    expect(mintOAuthState()).not.toBe(mintOAuthState());
  });
});

describe("openOAuthPopup", () => {
  beforeEach(() => {
    vi.spyOn(window, "open").mockReturnValue(fakePopup());
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects when the browser blocks the popup", async () => {
    vi.spyOn(window, "open").mockReturnValue(null);
    const result = await openOAuthPopup("https://provider/authorize", "s1");
    expect(result).toEqual({ ok: false, error: "Popup blocked by browser" });
  });

  it("resolves with the code when origin and state match", async () => {
    const promise = openOAuthPopup("https://provider/authorize", "state-abc");
    postOAuthMessage({
      type: "harmont_oauth",
      code: "the-code",
      state: "state-abc",
    });
    expect(await promise).toEqual({ ok: true, code: "the-code" });
  });

  it("ignores messages from a foreign origin", async () => {
    vi.useFakeTimers();
    const promise = openOAuthPopup("https://provider/authorize", "state-abc");
    // Right shape, right state, WRONG origin → must be ignored, not trusted.
    postOAuthMessage(
      { type: "harmont_oauth", code: "evil", state: "state-abc" },
      "https://evil.example.com",
    );
    // Nothing resolved it; a foreign message is a no-op.
    const settled = vi.fn();
    void promise.then(settled);
    await Promise.resolve();
    expect(settled).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it("ignores messages without the harmont_oauth type", async () => {
    vi.useFakeTimers();
    const promise = openOAuthPopup("https://provider/authorize", "state-abc");
    postOAuthMessage({ type: "something_else", code: "x", state: "state-abc" });
    const settled = vi.fn();
    void promise.then(settled);
    await Promise.resolve();
    expect(settled).not.toHaveBeenCalled();
    vi.useRealTimers();
  });

  it("rejects on a state mismatch (CSRF guard)", async () => {
    const promise = openOAuthPopup("https://provider/authorize", "expected");
    postOAuthMessage({
      type: "harmont_oauth",
      code: "the-code",
      state: "forged",
    });
    const result = await promise;
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/state mismatch/i);
  });

  it("rejects when state is missing entirely", async () => {
    const promise = openOAuthPopup("https://provider/authorize", "expected");
    postOAuthMessage({ type: "harmont_oauth", code: "the-code" });
    const result = await promise;
    expect(result.ok).toBe(false);
  });

  it("surfaces a provider error before checking state", async () => {
    const promise = openOAuthPopup("https://provider/authorize", "expected");
    postOAuthMessage({ type: "harmont_oauth", error: "access_denied" });
    expect(await promise).toEqual({ ok: false, error: "access_denied" });
  });
});

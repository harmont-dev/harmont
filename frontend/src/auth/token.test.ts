import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { clearToken, getToken, hasToken, setToken } from "./token";

// These back the Bearer-attach middleware in api/client.ts: the middleware
// reads getToken() to attach `Authorization: Bearer <token>` and calls
// clearToken() on a 401. Exercise the store primitives directly.
describe("token store", () => {
  beforeEach(() => clearToken());
  afterEach(() => clearToken());

  it("round-trips a set token", () => {
    expect(getToken()).toBeNull();
    expect(hasToken()).toBe(false);

    setToken("tok_abc");
    expect(getToken()).toBe("tok_abc");
    expect(hasToken()).toBe(true);
  });

  it("clears the token", () => {
    setToken("tok_abc");
    clearToken();
    expect(getToken()).toBeNull();
    expect(hasToken()).toBe(false);
  });

  it("overwrites an existing token", () => {
    setToken("first");
    setToken("second");
    expect(getToken()).toBe("second");
  });

  it("treats an empty stored value as present (matches localStorage semantics)", () => {
    // hasToken keys off null, not emptiness; an empty string is still "set".
    setToken("");
    expect(getToken()).toBe("");
    expect(hasToken()).toBe(true);
  });
});

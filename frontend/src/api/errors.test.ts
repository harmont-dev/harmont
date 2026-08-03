import { describe, expect, it } from "vitest";
import {
  apiErrorCode,
  apiErrorDocUrl,
  apiErrorField,
  apiErrorMessage,
  isApiError,
  isWebauthnCancel,
} from "./errors";

// A well-formed API error envelope (Harmont's Error schema).
const envelope = {
  error: {
    code: "passkey_unknown_credential",
    type: "passkey_unknown_credential",
    message: "That passkey is not registered.",
    doc_url: "https://harmont.dev/docs/errors/passkey_unknown_credential",
    request_id: "req_123",
    email: "user@example.com",
  },
};

describe("isApiError", () => {
  const cases: Array<[string, unknown, boolean]> = [
    ["a valid envelope", envelope, true],
    ["null", null, false],
    ["a string", "boom", false],
    ["a plain Error", new Error("boom"), false],
    ["an object without `error`", { message: "x" }, false],
    ["an `error` that isn't an object", { error: "nope" }, false],
    ["an `error` with no string message", { error: { code: "x" } }, false],
  ];
  it.each(cases)("%s → %s", (_label, value, expected) => {
    expect(isApiError(value)).toBe(expected);
  });
});

describe("apiErrorMessage", () => {
  it("prefers the envelope message", () => {
    expect(apiErrorMessage(envelope)).toBe("That passkey is not registered.");
  });
  it("falls back to a JS Error message", () => {
    expect(apiErrorMessage(new Error("disk full"))).toBe("disk full");
  });
  it("accepts a non-empty string", () => {
    expect(apiErrorMessage("raw text")).toBe("raw text");
  });
  it("uses the fallback for unknown/empty values", () => {
    expect(apiErrorMessage(undefined)).toBe("Something went wrong.");
    expect(apiErrorMessage("", "custom")).toBe("custom");
    expect(apiErrorMessage({}, "custom")).toBe("custom");
  });
});

describe("apiErrorCode", () => {
  it("returns the envelope code", () => {
    expect(apiErrorCode(envelope)).toBe("passkey_unknown_credential");
  });
  it("returns a JS Error name", () => {
    expect(apiErrorCode(new TypeError("x"))).toBe("TypeError");
  });
  it("returns undefined for plain values", () => {
    expect(apiErrorCode("x")).toBeUndefined();
    expect(apiErrorCode(null)).toBeUndefined();
  });
});

describe("apiErrorDocUrl", () => {
  it("returns the envelope doc_url", () => {
    expect(apiErrorDocUrl(envelope)).toBe(
      "https://harmont.dev/docs/errors/passkey_unknown_credential",
    );
  });
  it("returns undefined for non-envelopes", () => {
    expect(apiErrorDocUrl(new Error("x"))).toBeUndefined();
  });
});

describe("apiErrorField", () => {
  it("reads an extra string field off the envelope", () => {
    expect(apiErrorField(envelope, "email")).toBe("user@example.com");
  });
  it("returns undefined for a missing field or non-envelope", () => {
    expect(apiErrorField(envelope, "nope")).toBeUndefined();
    expect(apiErrorField(new Error("x"), "email")).toBeUndefined();
  });
});

describe("isWebauthnCancel", () => {
  it("is true only for a NotAllowedError", () => {
    const e = new Error("cancelled");
    e.name = "NotAllowedError";
    expect(isWebauthnCancel(e)).toBe(true);
  });
  it("is false for other errors and non-errors", () => {
    expect(isWebauthnCancel(new Error("other"))).toBe(false);
    expect(isWebauthnCancel(envelope)).toBe(false);
    expect(isWebauthnCancel("NotAllowedError")).toBe(false);
  });
});

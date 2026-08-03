import { describe, it, expect } from "vitest";
import { safeRedirect } from "./redirect";

describe("safeRedirect", () => {
  it("returns the default '/' for missing input", () => {
    expect(safeRedirect(undefined)).toBe("/");
    expect(safeRedirect(null)).toBe("/");
    expect(safeRedirect("")).toBe("/");
  });

  it("passes through an internal absolute path with query intact", () => {
    expect(safeRedirect("/cli-login?port=53117&nonce=abc")).toBe(
      "/cli-login?port=53117&nonce=abc",
    );
    expect(safeRedirect("/foo/bar")).toBe("/foo/bar");
  });

  it("rejects protocol-relative URLs (//evil.com)", () => {
    expect(safeRedirect("//evil.com")).toBe("/");
    expect(safeRedirect("//evil.com/cli-login")).toBe("/");
  });

  it("rejects absolute URLs with a scheme", () => {
    expect(safeRedirect("https://evil.com")).toBe("/");
    expect(safeRedirect("http://evil.com/x")).toBe("/");
    expect(safeRedirect("javascript:alert(1)")).toBe("/");
  });

  it("rejects backslash and control-char host tricks", () => {
    expect(safeRedirect("/\\evil.com")).toBe("/");
    // The WHATWG URL parser strips \t \r \n rather than treating them as an
    // authority separator, so these aren't browser bypasses — but we reject
    // them anyway for non-browser redirect consumers (Location headers, etc).
    expect(safeRedirect("/\tfoo")).toBe("/");
    expect(safeRedirect("/\rfoo")).toBe("/");
    expect(safeRedirect("/\nfoo")).toBe("/");
  });

  it("allows percent-encoded internal paths (same-origin)", () => {
    expect(safeRedirect("/%2Fevil.com")).toBe("/%2Fevil.com");
  });

  it("rejects bare relative paths that don't start with '/'", () => {
    expect(safeRedirect("cli-login")).toBe("/");
  });
});

import { describe, expect, it } from "vitest";
import { shortRepoName } from "./format";

describe("shortRepoName", () => {
  it("returns the last path segment of an owner/repo name", () => {
    expect(shortRepoName("acme/core")).toBe("core");
  });

  it("returns a single-segment name unchanged", () => {
    expect(shortRepoName("core")).toBe("core");
  });

  it("returns the last segment of a deeper path", () => {
    expect(shortRepoName("group/sub/proj")).toBe("proj");
  });

  it("returns null for null", () => {
    expect(shortRepoName(null)).toBeNull();
  });

  it("returns null for undefined", () => {
    expect(shortRepoName(undefined)).toBeNull();
  });

  it("returns null for an empty string", () => {
    expect(shortRepoName("")).toBeNull();
  });
});

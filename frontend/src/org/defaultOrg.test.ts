import { describe, it, expect, beforeEach } from "vitest";
import { getDefaultOrg, setDefaultOrg } from "./defaultOrg";

describe("defaultOrg cookie", () => {
  beforeEach(() => {
    document.cookie = "harmont_org=; max-age=0; path=/";
  });

  it("returns undefined when unset", () => {
    expect(getDefaultOrg()).toBeUndefined();
  });

  it("round-trips a slug", () => {
    setDefaultOrg("acme");
    expect(getDefaultOrg()).toBe("acme");
  });

  it("ignores a malformed slug", () => {
    setDefaultOrg("not a slug!!");
    expect(getDefaultOrg()).toBeUndefined();
  });
});

import { describe, expect, it } from "vitest";
import { EXPIRY_OPTIONS, expiryToIso } from "./expiry";

describe("expiryToIso", () => {
  const now = new Date("2026-06-02T12:00:00.000Z");

  it("maps 'never' to null", () => {
    expect(expiryToIso("never", now)).toBeNull();
  });

  it("maps '30d' to 30 days from now, ISO-8601", () => {
    expect(expiryToIso("30d", now)).toBe("2026-07-02T12:00:00.000Z");
  });

  it("maps '90d' to 90 days from now, ISO-8601", () => {
    expect(expiryToIso("90d", now)).toBe("2026-08-31T12:00:00.000Z");
  });

  it("exposes the three options in display order", () => {
    expect(EXPIRY_OPTIONS.map((o) => o.value)).toEqual(["never", "30d", "90d"]);
  });
});

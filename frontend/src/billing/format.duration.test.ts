import { describe, it, expect } from "vitest";
import { renderDuration } from "./format";

describe("renderDuration", () => {
  it("renders seconds under a minute", () => {
    expect(renderDuration(47)).toBe("47s");
  });
  it("renders minutes and seconds", () => {
    expect(renderDuration(131)).toBe("2m 11s");
  });
  it("renders hours, minutes and seconds", () => {
    expect(renderDuration(3725)).toBe("1h 2m 5s");
  });
  it("renders zero", () => {
    expect(renderDuration(0)).toBe("0s");
  });
  it("renders a dash for null", () => {
    expect(renderDuration(null)).toBe("—");
  });
  it("renders an exact minute", () => {
    expect(renderDuration(60)).toBe("1m");
  });
  it("renders an exact hour", () => {
    expect(renderDuration(3600)).toBe("1h");
  });
});

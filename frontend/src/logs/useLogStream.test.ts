import { describe, expect, it } from "vitest";
import { LogAccumulator, type LogChunk } from "./useLogStream";

const chunk = (seq: number, content: string): LogChunk => ({ seq, content });

describe("LogAccumulator", () => {
  it("concatenates an initial history replay in seq order", () => {
    const acc = new LogAccumulator();
    const out = acc.apply([chunk(0, "a"), chunk(1, "b"), chunk(2, "c")]);
    expect(out).toBe("abc");
    expect(acc.text()).toBe("abc");
  });

  it("appends live chunks after history", () => {
    const acc = new LogAccumulator();
    acc.apply([chunk(0, "a"), chunk(1, "b")]);
    expect(acc.apply([chunk(2, "c")])).toBe("abc");
    expect(acc.apply([chunk(3, "d")])).toBe("abcd");
  });

  // The regression this whole change exists for: a resume `history` carries
  // only the post-cursor delta. It must APPEND, not overwrite — otherwise the
  // reconnect wipes everything the user already saw down to the delta.
  it("appends a resume history delta instead of truncating", () => {
    const acc = new LogAccumulator();
    acc.apply([chunk(0, "first\n"), chunk(1, "second\n"), chunk(2, "third\n")]);
    expect(acc.text()).toBe("first\nsecond\nthird\n");

    // Reconnect: server replays only seqs > 2.
    const resumed = acc.apply([chunk(3, "fourth\n")]);
    expect(resumed).toBe("first\nsecond\nthird\nfourth\n");
  });

  it("drops chunks already at or below the high-water-mark (no double-append)", () => {
    const acc = new LogAccumulator();
    acc.apply([chunk(0, "a"), chunk(1, "b"), chunk(2, "c")]);

    // A resume history that overlaps already-seen seqs must not re-append them.
    const out = acc.apply([chunk(1, "b"), chunk(2, "c"), chunk(3, "d")]);
    expect(out).toBe("abcd");
  });

  it("ignores a fully-redundant replay", () => {
    const acc = new LogAccumulator();
    acc.apply([chunk(0, "a"), chunk(1, "b")]);
    expect(acc.apply([chunk(0, "a"), chunk(1, "b")])).toBe("ab");
  });

  it("starts empty and tolerates an empty batch", () => {
    const acc = new LogAccumulator();
    expect(acc.text()).toBe("");
    expect(acc.apply([])).toBe("");
  });
});

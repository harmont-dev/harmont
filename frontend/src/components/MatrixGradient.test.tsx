import { render } from "@solidjs/testing-library";
import { describe, expect, it } from "vitest";
import { MatrixGradient } from "./MatrixGradient";

describe("MatrixGradient", () => {
  it("mounts a full-bleed canvas and forwards the class prop", () => {
    const { container } = render(() => <MatrixGradient class="opacity-80" />);
    const canvas = container.querySelector("canvas");
    expect(canvas).not.toBeNull();
    expect(canvas!.className).toContain("absolute inset-0 w-full h-full");
    expect(canvas!.className).toContain("opacity-80");
  });

  it("accepts a scale prop and degrades gracefully without a WebGL context", () => {
    // jsdom provides no WebGL context (canvas.getContext('webgl') returns null),
    // so onMount hits the `if (!gl) return` guard. The component must still
    // mount the <canvas> element and must accept the scale prop.
    const { container } = render(() => <MatrixGradient scale={0.45} />);
    expect(container.querySelector("canvas")).not.toBeNull();
  });
});

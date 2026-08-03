import { render } from "@solidjs/testing-library";
import { describe, expect, it } from "vitest";
import { CheckoutCancelPage } from "./CheckoutCancel";

describe("CheckoutCancelPage", () => {
  it("explains nothing was charged and links back to the app", () => {
    const { getByText, container } = render(() => <CheckoutCancelPage />);
    expect(getByText(/checkout canceled/i)).toBeTruthy();
    expect(getByText(/no charge/i)).toBeTruthy();
    const back = container.querySelector('a[href="/"]');
    expect(back).not.toBeNull();
  });
});

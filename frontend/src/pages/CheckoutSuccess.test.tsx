import { render } from "@solidjs/testing-library";
import { describe, expect, it } from "vitest";
import { CheckoutSuccessPage } from "./CheckoutSuccess";

describe("CheckoutSuccessPage", () => {
  it("confirms the payment and links back to the app", () => {
    const { getByText, container } = render(() => <CheckoutSuccessPage />);
    // Reassures the user payment landed even though the credit posts async.
    expect(getByText(/payment received/i)).toBeTruthy();
    expect(getByText(/credit will appear/i)).toBeTruthy();
    const back = container.querySelector('a[href="/"]');
    expect(back).not.toBeNull();
  });
});

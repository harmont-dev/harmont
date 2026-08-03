// Stripe redirects here when the user abandons the hosted checkout
// (cancel_url = <app_base>/billing/cancel). No charge was made; the
// stripe_checkout_sessions row stays :open until Stripe's
// checkout.session.expired event flips it to :expired.
export function CheckoutCancelPage() {
  return (
    <div class="mx-auto flex max-w-[560px] flex-col items-start gap-5 py-20">
      <div class="font-mono text-2xs font-medium uppercase tracking-[0.06em] text-fg-muted">
        Billing
      </div>
      <h1 class="text-xl font-semibold text-fg">Checkout canceled</h1>
      <p class="text-sm text-fg-secondary">
        No charge was made. You can start a new top-up any time from your usage
        page.
      </p>
      <a
        href="/"
        class="font-mono text-sm text-accent underline-offset-2 hover:underline"
      >
        Back to your dashboard
      </a>
    </div>
  );
}

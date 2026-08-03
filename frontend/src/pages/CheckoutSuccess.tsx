// Stripe redirects here after a completed hosted checkout
// (success_url = <app_base>/billing/success). The credit is posted
// asynchronously by the Stripe webhook, so this page only confirms the
// payment was taken and points the user back into the app, where the
// balance refetches.
export function CheckoutSuccessPage() {
  return (
    <div class="mx-auto flex max-w-[560px] flex-col items-start gap-5 py-20">
      <div class="font-mono text-2xs font-medium uppercase tracking-[0.06em] text-fg-muted">
        Billing
      </div>
      <h1 class="text-xl font-semibold text-fg">Payment received</h1>
      <p class="text-sm text-fg-secondary">
        Thanks — your payment went through. Your credit will appear on your
        balance within a few moments, once Stripe confirms the charge.
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

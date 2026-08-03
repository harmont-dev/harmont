import { createSignal, Show } from "solid-js";
import { useRedeemCoupon } from "../billing/queries";
import { useOrgSlug } from "../auth/context";
import { apiErrorMessage } from "../api/errors";
import { Panel } from "../components/Panel";
import { Button } from "../components/Button";
import { TextInput } from "../components/TextInput";
import { Collapsible } from "../components/Collapsible";
import { ExpandToggle } from "../components/ExpandToggle";
import { ErrorBanner } from "../components/ErrorBanner";
import { pushToast } from "../components/toast";
import { renderCents } from "../billing/format";

export function CouponSection() {
  const orgSlug = useOrgSlug();
  const redeem = useRedeemCoupon(orgSlug);
  const [open, setOpen] = createSignal(false);
  const [code, setCode] = createSignal("");
  const [error, setError] = createSignal<string | null>(null);

  const close = () => {
    setOpen(false);
    setCode("");
    setError(null);
  };
  const toggle = () => {
    if (open()) close();
    else {
      setCode("");
      setError(null);
      setOpen(true);
    }
  };

  const handleRedeem = async () => {
    const c = code().trim();
    if (!c || redeem.isPending) return;
    setError(null);
    try {
      const res = await redeem.mutateAsync(c);
      pushToast(`Redeemed — ${renderCents(res.credit_cents)} credited`, "info");
      close();
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to redeem coupon"));
    }
  };

  return (
    <Panel
      title="Redeem a Coupon"
      description="Apply a promo code to add credit to this organization."
      actions={<ExpandToggle open={open()} onToggle={toggle} label="Redeem a coupon" />}
    >
      <Collapsible open={open()}>
        <div class="pb-1 flex flex-col gap-4">
          <Show when={error()}><ErrorBanner message={error()!} /></Show>
          <TextInput
            label="Coupon code"
            value={code()}
            onInput={setCode}
            placeholder="e.g. WELCOME25"
            onKeyDown={(e: KeyboardEvent) => {
              if (e.key === "Enter") handleRedeem();
            }}
            autofocus
          />
          <div class="flex justify-end">
            <Button
              variant="primary"
              onClick={handleRedeem}
              mode={!code().trim() || redeem.isPending ? "inactive" : "active"}
            >
              {redeem.isPending ? "Redeeming..." : "Redeem"}
            </Button>
          </div>
        </div>
      </Collapsible>
      <Show when={!open()}>
        <p class="font-mono text-xs text-fg-dim">Have a promo code? Tap + to redeem it.</p>
      </Show>
    </Panel>
  );
}

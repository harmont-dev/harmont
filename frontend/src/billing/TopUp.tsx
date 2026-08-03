import { createMemo, createSignal, For, Show } from "solid-js";
import { Button } from "../components/Button";
import { useCheckout } from "./queries";

const MIN_CENTS = 100;
const MAX_CENTS = 1_000_000;
const PRESETS = [1000, 2500, 5000];

function renderPreset(cents: number): string {
  return `$${cents / 100}`;
}

// Parse a dollar string (e.g. "25", "25.50") into integer cents, or null if it
// isn't a clean money value.
function dollarsToCents(raw: string): number | null {
  const s = raw.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const cents = Math.round(Number(s) * 100);
  if (!Number.isFinite(cents)) return null;
  return cents;
}

// Inline credit top-up surfaced in the Usage header (no popover): a label,
// a row of preset amounts, then a custom field + submit. Each amount starts a
// Stripe Checkout Session and redirects to the hosted URL.
export function TopUp(props: { orgSlug: () => string | undefined }) {
  const checkout = useCheckout(props.orgSlug);
  const [custom, setCustom] = createSignal("");

  const customCents = createMemo(() => dollarsToCents(custom()));
  const customValid = () => {
    const c = customCents();
    return c !== null && c >= MIN_CENTS && c <= MAX_CENTS;
  };
  // Show the range hint only once the user has typed something out of range.
  const showHint = () => custom().trim() !== "" && !customValid();

  const start = async (amountCents: number) => {
    if (checkout.isPending) return;
    try {
      const data = await checkout.mutateAsync(amountCents);
      window.location.assign(data.checkout_url);
    } catch {
      // global mutationCache.onError already toasts; stop here.
    }
  };

  return (
    <div class="flex w-[300px] flex-col items-stretch gap-2.5">
      <div class="font-mono text-2xs font-medium uppercase tracking-[0.06em] text-fg-muted">
        Add credit
      </div>
      <div class="flex gap-2">
        <For each={PRESETS}>
          {(cents) => (
            <Button
              variant="default"
              size="md"
              class="flex-1"
              disabled={checkout.isPending}
              onClick={() => start(cents)}
            >
              {renderPreset(cents)}
            </Button>
          )}
        </For>
      </div>
      <div class="flex items-stretch gap-2">
        <div class="flex flex-1 items-center bg-bg border border-border-focus rounded-[2px] px-2 focus-within:border-accent">
          <span class="text-fg-dim text-sm select-none">$</span>
          <input
            type="text"
            inputmode="decimal"
            value={custom()}
            onInput={(e) => setCustom(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && customValid() && !checkout.isPending) {
                start(customCents()!);
              }
            }}
            placeholder="Custom amount"
            aria-label="Custom amount in dollars"
            disabled={checkout.isPending}
            class="w-full min-w-0 bg-transparent py-1.5 pl-1 font-mono text-sm text-fg outline-none placeholder:text-fg-dim"
          />
        </div>
        <Button
          variant={customValid() ? "primary" : "default"}
          size="md"
          disabled={!customValid() || checkout.isPending}
          onClick={() => start(customCents()!)}
        >
          Top up
        </Button>
      </div>
      <Show when={showHint()}>
        <div class="font-mono text-2xs text-err">{`Enter $${MIN_CENTS / 100}–$${(MAX_CENTS / 100).toLocaleString()}.`}</div>
      </Show>
    </div>
  );
}

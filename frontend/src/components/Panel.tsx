import { type JSX, Show } from "solid-js";

export type PanelProps = {
  /** Section title — rendered mono/uppercase like SectionHeading. */
  title?: string;
  /** One-line description under the title (sentence case, muted). */
  description?: string;
  /**
   * Header action list, pinned top-right of the card — e.g. an "add" (`+`)
   * icon button. Takes one or more buttons; laid out in a row.
   */
  actions?: JSX.Element;
  children: JSX.Element;
  /**
   * Optional action bar pinned to the bottom of the card. Laid out
   * space-between, so the convention is: helper text on the left, the
   * primary action button on the right. Sits on a recessed (`bg-bg-inset`)
   * strip with a top divider — the Vercel/Supabase settings-card footer.
   */
  footer?: JSX.Element;
  class?: string;
};

/**
 * A bordered settings card: header (title + description) / body / footer
 * action bar. Used to constrain and group form-style sections on the
 * Settings and Billing pages. Distinct from `Card` (the dashboard metric
 * tile with the colored accent strip).
 */
export function Panel(props: PanelProps) {
  return (
    <div
      class={`bg-bg-raise border border-border rounded-[4px] shadow-card overflow-hidden ${props.class ?? ""}`.trim()}
    >
      <Show when={props.title || props.description || props.actions}>
        <div class="flex items-start justify-between gap-3 px-6 py-4 border-b border-border-subtle bg-bg-inset">
          <div class="min-w-0">
            <Show when={props.title}>
              <h2 class="text-lg font-semibold text-fg">{props.title}</h2>
            </Show>
            <Show when={props.description}>
              <p class="text-xs text-fg-muted mt-1.5 leading-relaxed">
                {props.description}
              </p>
            </Show>
          </div>
          <Show when={props.actions}>
            <div class="shrink-0 flex items-center gap-1.5">{props.actions}</div>
          </Show>
        </div>
      </Show>
      <div class="p-6">{props.children}</div>
      <Show when={props.footer}>
        <div class="flex items-center justify-between gap-3 px-6 py-3 border-t border-border-subtle bg-bg-inset">
          {props.footer}
        </div>
      </Show>
    </div>
  );
}

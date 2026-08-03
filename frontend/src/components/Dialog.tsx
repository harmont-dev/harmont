import { Dialog as KDialog } from "@kobalte/core/dialog";
import type { JSX } from "solid-js";

// Accessible modal built on Kobalte's Dialog: focus trap, Esc-to-close,
// scroll-lock, and focus restoration to the trigger are handled for us. Styled
// to the design system (raised panel, sharp border, mono uppercase title).
// Controlled via `open` / `onOpenChange`.
export function Dialog(props: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: JSX.Element;
}) {
  return (
    <KDialog open={props.open} onOpenChange={props.onOpenChange}>
      <KDialog.Portal>
        <KDialog.Overlay class="fixed inset-0 z-50 bg-black/70 backdrop-blur-[1px]" />
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <KDialog.Content class="w-full max-w-md bg-bg-raise border border-border rounded-[2px] shadow-[var(--shadow-panel)] p-5 focus:outline-none">
            <div class="flex items-center justify-between mb-4">
              <KDialog.Title class="font-mono text-sm font-semibold text-fg uppercase tracking-[0.06em]">
                {props.title}
              </KDialog.Title>
              <KDialog.CloseButton
                class="text-fg-dim hover:text-fg cursor-pointer transition-colors"
                aria-label="Close"
              >
                <svg
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                  width="1em"
                  height="1em"
                  class="text-base"
                >
                  <path d="M4 4l8 8M12 4l-8 8" />
                </svg>
              </KDialog.CloseButton>
            </div>
            {props.children}
          </KDialog.Content>
        </div>
      </KDialog.Portal>
    </KDialog>
  );
}

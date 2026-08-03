import { For } from "solid-js";
import { toasts, dismissToast, type Toast } from "./toast";

// Global toast outlet. Rendered once at the app root; fed by pushToast() and
// the QueryClient MutationCache onError. Bottom-right, terse, monospace —
// matches ErrorBanner's status-failed palette.
export function Toaster() {
  return (
    <div class="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm" role="region" aria-label="Notifications">
      <For each={toasts()}>{(t) => <ToastItem toast={t} />}</For>
    </div>
  );
}

function ToastItem(props: { toast: Toast }) {
  const tone = () =>
    props.toast.kind === "error"
      ? "text-status-failed border-status-failed/30 bg-status-failed/10"
      : "text-fg border-border bg-bg";
  return (
    <div
      class={`text-sm font-mono py-2 px-3 border rounded-[2px] shadow-lg flex items-start gap-2 ${tone()}`}
      role="alert"
    >
      <span class="flex-1">{props.toast.message}</span>
      <button
        type="button"
        class="opacity-60 hover:opacity-100 leading-none"
        aria-label="Dismiss"
        onClick={() => dismissToast(props.toast.id)}
      >
        ×
      </button>
    </div>
  );
}

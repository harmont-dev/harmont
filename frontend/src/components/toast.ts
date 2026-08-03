import { createSignal } from "solid-js";

export type ToastKind = "error" | "info";
export interface Toast {
  id: number;
  message: string;
  kind: ToastKind;
}

const [toasts, setToasts] = createSignal<Toast[]>([]);
let seq = 0;

export { toasts };

export function dismissToast(id: number): void {
  setToasts((ts) => ts.filter((t) => t.id !== id));
}

/** Queue a transient toast. Auto-dismisses after `ttlMs` (default 6s). */
export function pushToast(message: string, kind: ToastKind = "error", ttlMs = 6000): void {
  const id = ++seq;
  setToasts((ts) => [...ts, { id, message, kind }]);
  if (ttlMs > 0) setTimeout(() => dismissToast(id), ttlMs);
}

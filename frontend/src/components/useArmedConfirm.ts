import { createSignal } from "solid-js";

/**
 * Two-step "armed" confirmation for destructive row actions: the first
 * `trigger(id)` arms that id (auto-disarming after `timeoutMs`); a second
 * `trigger(id)` within the window runs `onConfirm(id)`. `onConfirm` owns its
 * own error handling.
 *
 * Usage:
 *   const revoke = useArmedConfirm<string>((id) => doRevoke(id));
 *   <Button variant={revoke.isArmed(k.id) ? "danger" : "default"}
 *           onClick={() => revoke.trigger(k.id)}>
 *     {revoke.isArmed(k.id) ? "Confirm" : "Revoke"}
 *   </Button>
 */
export function useArmedConfirm<T>(
  onConfirm: (id: T) => void | Promise<void>,
  timeoutMs = 4000,
) {
  const [armed, setArmed] = createSignal<T | null>(null);

  return {
    isArmed: (id: T) => armed() === id,
    trigger: (id: T) => {
      if (armed() !== id) {
        setArmed(() => id);
        setTimeout(() => setArmed((prev) => (prev === id ? null : prev)), timeoutMs);
        return;
      }
      setArmed(null);
      void onConfirm(id);
    },
    disarm: () => setArmed(null),
  };
}

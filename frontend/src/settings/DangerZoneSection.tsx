import { createSignal, Show } from "solid-js";
import { useNavigate } from "@solidjs/router";
import { useQueryClient } from "@tanstack/solid-query";
import { useCurrentUser, useDeleteAccount } from "../auth/queries";
import { clearToken } from "../auth/token";
import { apiErrorMessage } from "../api/errors";
import { Panel } from "../components/Panel";
import { Button } from "../components/Button";
import { TextInput } from "../components/TextInput";
import { Collapsible } from "../components/Collapsible";
import { ErrorBanner } from "../components/ErrorBanner";

export function DangerZoneSection() {
  const user = useCurrentUser();
  const deleteAccount = useDeleteAccount();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [open, setOpen] = createSignal(false);
  const [confirm, setConfirm] = createSignal("");
  const [error, setError] = createSignal<string | null>(null);

  const close = () => {
    setOpen(false);
    setConfirm("");
    setError(null);
  };
  const matches = () =>
    confirm().trim().toLowerCase() === (user.data?.email ?? "").toLowerCase();

  const handleDelete = async () => {
    if (!matches() || deleteAccount.isPending) return;
    setError(null);
    try {
      await deleteAccount.mutateAsync();
      clearToken();
      qc.clear();
      navigate("/login", { replace: true });
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to delete account"));
    }
  };

  return (
    <Panel
      title="Delete account"
      description="Permanently delete your account and sign-in credentials. This cannot be undone."
    >
      <Show when={error()}>
        <div class="mb-4"><ErrorBanner message={error()!} /></div>
      </Show>
      <Collapsible
        open={open()}
        fallback={
          <div class="flex">
            <Button variant="danger" onClick={() => setOpen(true)}>
              Delete account
            </Button>
          </div>
        }
      >
        <div class="flex flex-col gap-4">
            <p class="text-sm text-fg-secondary">
              Type your email <span class="font-mono text-fg">{user.data?.email}</span> to confirm.
            </p>
            <TextInput
              label="Confirm email"
              value={confirm()}
              onInput={setConfirm}
              placeholder={user.data?.email ?? ""}
              autofocus
              onKeyDown={(e: KeyboardEvent) => {
                if (e.key === "Enter" && matches()) handleDelete();
              }}
            />
            <div class="flex justify-end gap-2">
              <Button variant="default" onClick={close}>
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDelete}
                mode={matches() && !deleteAccount.isPending ? "active" : "inactive"}
              >
                {deleteAccount.isPending ? "Deleting..." : "Delete my account"}
              </Button>
            </div>
        </div>
      </Collapsible>
    </Panel>
  );
}

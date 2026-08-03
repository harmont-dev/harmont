import { createSignal, createEffect, Show } from "solid-js";
import { useCurrentUser, useUpdateProfile } from "../auth/queries";
import { apiErrorMessage } from "../api/errors";
import { Panel } from "../components/Panel";
import { TextInput } from "../components/TextInput";
import { Button } from "../components/Button";
import { QueryGuard } from "../components/QueryGuard";
import { ErrorBanner } from "../components/ErrorBanner";
import { pushToast } from "../components/toast";

export function ProfileSection() {
  const user = useCurrentUser();
  const updateProfile = useUpdateProfile();
  const [name, setName] = createSignal("");
  const [error, setError] = createSignal<string | null>(null);

  // Seed the editable field from the server value; re-runs only when the
  // server name changes (e.g. after a successful save), so typing isn't clobbered.
  createEffect(() => setName(user.data?.name ?? ""));

  const dirty = () =>
    name().trim().length > 0 && name().trim() !== (user.data?.name ?? "");

  const handleSave = async () => {
    if (!dirty() || updateProfile.isPending) return;
    setError(null);
    try {
      await updateProfile.mutateAsync(name().trim());
      pushToast("Profile updated", "info");
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to update profile"));
    }
  };

  return (
    <Panel
      title="Profile"
      description="Your account identity."
      footer={
        <>
          <span class="text-xs text-fg-muted">Email is managed by your sign-in provider.</span>
          <Button
            variant="primary"
            onClick={handleSave}
            mode={dirty() && !updateProfile.isPending ? "active" : "inactive"}
          >
            {updateProfile.isPending ? "Saving..." : "Save"}
          </Button>
        </>
      }
    >
      <QueryGuard query={user} loadingRows={2}>
        <Show when={error()}>
          <div class="mb-4"><ErrorBanner message={error()!} /></div>
        </Show>
        <div class="flex flex-col gap-4">
          <TextInput
            label="Name"
            value={name()}
            onInput={setName}
            placeholder="Your name"
            onKeyDown={(e: KeyboardEvent) => {
              if (e.key === "Enter") handleSave();
            }}
          />
          <div class="flex flex-col gap-1">
            <span class="font-mono text-xs font-medium text-fg-secondary uppercase tracking-[0.04em]">
              Email
            </span>
            <div class="font-mono text-sm text-fg">{user.data?.email}</div>
          </div>
        </div>
      </QueryGuard>
    </Panel>
  );
}

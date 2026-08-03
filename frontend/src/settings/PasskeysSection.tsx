import { createSignal, For, Show } from "solid-js";
import { usePasskeys, useAddPasskey, useRevokePasskey } from "../auth/queries";
import {
  apiErrorMessage,
  apiErrorCode,
  apiErrorDocUrl,
  isWebauthnCancel,
} from "../api/errors";
import { Button } from "../components/Button";
import { Panel } from "../components/Panel";
import { QueryGuard } from "../components/QueryGuard";
import { PanelList, PanelRow } from "../components/PanelList";
import { EmptyState } from "../components/EmptyState";
import { ErrorBanner } from "../components/ErrorBanner";
import { TimeAgo } from "../components/TimeAgo";
import { PlusIcon } from "../components/icons/PlusIcon";
import { useArmedConfirm } from "../components/useArmedConfirm";

export function PasskeysSection() {
  const passkeys = usePasskeys();
  const addPasskey = useAddPasskey();
  const revokePasskey = useRevokePasskey();

  const [adding, setAdding] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [errorCode, setErrorCode] = createSignal<string | undefined>(undefined);
  const [errorDocUrl, setErrorDocUrl] = createSignal<string | undefined>(undefined);

  const handleAdd = async () => {
    setAdding(true);
    setError(null);
    try {
      await addPasskey.mutateAsync(undefined);
    } catch (e) {
      if (isWebauthnCancel(e)) return;
      setError(apiErrorMessage(e, "Failed to add passkey"));
      setErrorCode(apiErrorCode(e));
      setErrorDocUrl(apiErrorDocUrl(e));
    } finally {
      setAdding(false);
    }
  };

  const revoke = useArmedConfirm<string>(async (id) => {
    try {
      await revokePasskey.mutateAsync(id);
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to revoke passkey"));
      setErrorCode(apiErrorCode(e));
      setErrorDocUrl(apiErrorDocUrl(e));
    }
  });

  return (
    <Panel
      title="Passkeys"
      description="Sign in with your device biometrics or a security key. Add more than one so you always have a backup."
      actions={
        <Button
          variant="default"
          icon={<PlusIcon />}
          onClick={handleAdd}
          mode={adding() ? "inactive" : "active"}
          aria-label="Add passkey"
        />
      }
    >
      <Show when={error()}>
        <div class="mb-4">
          <ErrorBanner message={error()!} code={errorCode()} docUrl={errorDocUrl()} />
        </div>
      </Show>
      <QueryGuard query={passkeys} loadingRows={2}>
        <Show
          when={(passkeys.data?.passkeys ?? []).length > 0}
          fallback={<EmptyState>No passkeys yet. Add one to secure your account.</EmptyState>}
        >
          <PanelList>
            <For each={passkeys.data?.passkeys ?? []}>
              {(pk) => (
                <PanelRow>
                  <div class="flex-1 min-w-0">
                    <div class="font-mono text-sm text-fg truncate">
                      {pk.nickname || "Unnamed passkey"}
                    </div>
                    <div class="font-mono text-xs text-fg-dim mt-0.5">
                      Added <TimeAgo date={pk.created_at} />
                      <Show when={pk.last_used_at}>
                        {(d) => <> · Last used <TimeAgo date={d()} /></>}
                      </Show>
                    </div>
                  </div>
                  <Button
                    variant={revoke.isArmed(pk.uuid) ? "danger" : "default"}
                    onClick={() => revoke.trigger(pk.uuid)}
                  >
                    {revoke.isArmed(pk.uuid) ? "Confirm" : "Revoke"}
                  </Button>
                </PanelRow>
              )}
            </For>
          </PanelList>
        </Show>
      </QueryGuard>
    </Panel>
  );
}

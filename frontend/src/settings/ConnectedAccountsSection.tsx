import { createSignal, For, Show } from "solid-js";
import {
  useInstallations,
  useSyncInstallation,
  useDisconnectInstallation,
} from "../repos/queries";
import { useOrgSlug } from "../auth/context";
import { apiErrorMessage } from "../api/errors";
import { Panel } from "../components/Panel";
import { Button } from "../components/Button";
import { QueryGuard } from "../components/QueryGuard";
import { PanelList, PanelRow } from "../components/PanelList";
import { EmptyState } from "../components/EmptyState";
import { ErrorBanner } from "../components/ErrorBanner";
import { GithubIcon } from "../components/icons/GithubIcon";
import { TimeAgo } from "../components/TimeAgo";
import { pushToast } from "../components/toast";
import { useArmedConfirm } from "../components/useArmedConfirm";

const GITHUB_APP_SLUG = import.meta.env.VITE_GITHUB_APP_SLUG ?? "harmont-app";
const githubInstallUrl = (org?: string) => {
  const base = `https://github.com/apps/${GITHUB_APP_SLUG}/installations/new`;
  return org ? `${base}?state=${encodeURIComponent(org)}` : base;
};

export function ConnectedAccountsSection() {
  const orgSlug = useOrgSlug();
  const installations = useInstallations(orgSlug);
  const sync = useSyncInstallation(orgSlug);
  const disconnect = useDisconnectInstallation(orgSlug);
  const [error, setError] = createSignal<string | null>(null);

  const handleSync = async (id: number) => {
    setError(null);
    try {
      await sync.mutateAsync(id);
      pushToast("Repositories synced", "info");
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to sync"));
    }
  };

  const remove = useArmedConfirm<number>(async (id) => {
    setError(null);
    try {
      await disconnect.mutateAsync(id);
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to disconnect"));
    }
  });

  return (
    <Panel
      title="Connected Accounts"
      description="GitHub installations linked to this organization."
      actions={
        <Button
          variant="default"
          onClick={() => {
            window.location.href = githubInstallUrl(orgSlug());
          }}
        >
          Connect
        </Button>
      }
    >
      <Show when={error()}>
        <div class="mb-4"><ErrorBanner message={error()!} /></div>
      </Show>
      <QueryGuard query={installations} loadingRows={2}>
        <Show
          when={(installations.data?.data ?? []).length > 0}
          fallback={
            <EmptyState>No GitHub accounts connected. Use Connect to install the app.</EmptyState>
          }
        >
          <PanelList>
            <For each={installations.data?.data ?? []}>
              {(inst) => (
                <PanelRow>
                  <span class="shrink-0 text-fg-muted [&>svg]:h-4 [&>svg]:w-4">
                    <GithubIcon />
                  </span>
                  <div class="flex-1 min-w-0">
                    <div class="text-sm text-fg truncate">{inst.account_login}</div>
                    <div class="font-mono text-xs text-fg-dim mt-0.5">
                      {inst.account_type} · Added <TimeAgo date={inst.created_at} />
                    </div>
                  </div>
                  <Button
                    variant="default"
                    onClick={() => handleSync(inst.installation_id)}
                    mode={sync.isPending ? "inactive" : "active"}
                  >
                    Sync
                  </Button>
                  <Button
                    variant={remove.isArmed(inst.installation_id) ? "danger" : "default"}
                    onClick={() => remove.trigger(inst.installation_id)}
                  >
                    {remove.isArmed(inst.installation_id) ? "Confirm" : "Disconnect"}
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

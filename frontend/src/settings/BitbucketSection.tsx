import { createSignal, For, Show } from "solid-js";
import { useOrgSlug } from "../auth/context";
import {
  useBitbucketWorkspaces,
  useDisconnectBitbucket,
  fetchBitbucketOAuthUrl,
} from "../bitbucket/queries";
import { Panel } from "../components/Panel";
import { Button } from "../components/Button";
import { QueryGuard } from "../components/QueryGuard";
import { PanelList, PanelRow } from "../components/PanelList";
import { EmptyState } from "../components/EmptyState";
import { ErrorBanner } from "../components/ErrorBanner";
import { apiErrorMessage } from "../api/errors";
import { pushToast } from "../components/toast";
import { useArmedConfirm } from "../components/useArmedConfirm";

export function BitbucketSection() {
  const orgSlug = useOrgSlug();
  const workspaces = useBitbucketWorkspaces(orgSlug);
  const disconnect = useDisconnectBitbucket(orgSlug);
  const [error, setError] = createSignal<string | null>(null);

  const handleConnect = async () => {
    setError(null);
    const org = orgSlug();
    if (!org) {
      setError("No organization context. Reload the page and try again.");
      return;
    }
    try {
      // The oauth-url endpoint is org-scoped: it signs this org into the OAuth
      // `state` so the static `/bitbucket/setup` callback can recover it.
      const url = await fetchBitbucketOAuthUrl(org);
      window.location.href = url;
    } catch (e) {
      setError(apiErrorMessage(e, "Could not start Bitbucket connect"));
    }
  };

  const remove = useArmedConfirm<string>(async (slug) => {
    setError(null);
    try {
      await disconnect.mutateAsync(slug);
      pushToast("Workspace disconnected", "info");
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to disconnect"));
    }
  });

  return (
    <Panel
      title="Bitbucket"
      description="Connect a Bitbucket workspace to run CI on pushes and pull requests."
      actions={
        <Button variant="default" onClick={handleConnect}>
          Connect
        </Button>
      }
    >
      <Show when={error()}>
        <div class="mb-4">
          <ErrorBanner message={error()!} />
        </div>
      </Show>
      <QueryGuard query={workspaces} loadingRows={2}>
        <Show
          when={(workspaces.data ?? []).length > 0}
          fallback={
            <EmptyState>
              No Bitbucket workspaces connected. Use Connect to link a workspace.
            </EmptyState>
          }
        >
          <PanelList>
            <For each={workspaces.data ?? []}>
              {(ws) => (
                <PanelRow>
                  <div class="flex-1 min-w-0">
                    <div class="font-mono text-sm text-fg truncate">
                      {ws.name ?? ws.slug}
                    </div>
                    <div class="font-mono text-xs text-fg-dim mt-0.5">{ws.slug}</div>
                  </div>
                  <Button
                    variant={remove.isArmed(ws.slug) ? "danger" : "default"}
                    onClick={() => remove.trigger(ws.slug)}
                  >
                    {remove.isArmed(ws.slug) ? "Confirm" : "Disconnect"}
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

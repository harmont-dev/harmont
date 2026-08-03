import { For, Show } from "solid-js";
import { useOrganizations } from "../org/queries";
import { useOrgSlug } from "../auth/context";
import { Panel } from "../components/Panel";
import { QueryGuard } from "../components/QueryGuard";
import { PanelList, PanelRow } from "../components/PanelList";
import { EmptyState } from "../components/EmptyState";
import { Tag } from "../components/Tag";
import { TimeAgo } from "../components/TimeAgo";

export function OrganizationsListSection() {
  const currentSlug = useOrgSlug();
  const orgs = useOrganizations();

  return (
    <Panel title="Organizations" description="Organizations you belong to.">
      <QueryGuard query={orgs} loadingRows={2}>
        <Show
          when={(orgs.data?.data ?? []).length > 0}
          fallback={<EmptyState>You're not a member of any organizations.</EmptyState>}
        >
          <PanelList>
            <For each={orgs.data?.data ?? []}>
              {(o) => (
                <PanelRow class="justify-between">
                  <div class="min-w-0">
                    <div class="text-sm text-fg truncate">{o.name}</div>
                    <div class="font-mono text-xs text-fg-dim mt-0.5">
                      {o.slug} · Created <TimeAgo date={o.created_at} />
                    </div>
                  </div>
                  <Show when={o.slug === currentSlug()}>
                    <Tag variant="accent">Current</Tag>
                  </Show>
                </PanelRow>
              )}
            </For>
          </PanelList>
        </Show>
      </QueryGuard>
    </Panel>
  );
}

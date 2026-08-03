import { Show } from "solid-js";
import { useOrgSlug } from "../auth/context";
import { useOrganization } from "../org/queries";
import { Panel } from "../components/Panel";
import { QueryGuard } from "../components/QueryGuard";
import { DefRow } from "../components/DefRow";
import { TimeAgo } from "../components/TimeAgo";

/** http(s)-only guard for the user-set org website (prevents javascript: XSS). */
function safeHttpUrl(s?: string | null): string | undefined {
  try {
    const u = new URL(s ?? "");
    return u.protocol === "http:" || u.protocol === "https:" ? u.toString() : undefined;
  } catch {
    return undefined;
  }
}

export function OrganizationSection() {
  const orgSlug = useOrgSlug();
  const org = useOrganization(orgSlug);

  return (
    <Panel title="Organization" description="The organization this dashboard is scoped to.">
      <QueryGuard query={org} loadingRows={3}>
        <dl class="flex flex-col divide-y divide-border-subtle">
          <DefRow label="Name">{org.data?.name}</DefRow>
          <DefRow label="Organization ID">
            <code class="font-mono select-all">{org.data?.slug}</code>
          </DefRow>
          <Show when={safeHttpUrl(org.data?.url)}>
            {(u) => (
              <DefRow label="Website">
                <a
                  href={u()}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-accent hover:text-accent-hover"
                >
                  {u()}
                </a>
              </DefRow>
            )}
          </Show>
          <DefRow label="Created">
            <Show when={org.data?.created_at}>{(d) => <TimeAgo date={d()} />}</Show>
          </DefRow>
        </dl>
      </QueryGuard>
    </Panel>
  );
}

/* @refresh reload */
import { Show, For } from "solid-js";
import { Breadcrumb } from "../components/Breadcrumb";
import { GithubIcon } from "../components/icons/GithubIcon";
import { BitbucketIcon } from "../components/icons/BitbucketIcon";
import { CliIcon } from "../components/icons/CliIcon";
import { ArrowSquareOutIcon } from "../components/icons/ArrowSquareOutIcon";
import { QueryGuard } from "../components/QueryGuard";
import { Table, type Column } from "../components/Table";
import { RefBadge } from "../components/RefBadge";
import { Tag } from "../components/Tag";
import { Button } from "../components/Button";
import { LinkButton } from "../components/LinkButton";
import { RegistrationChip } from "../components/RegistrationChip";
import { TimeAgo } from "../components/TimeAgo";
import { useOrgSlug } from "../auth/context";
import { useOrgRepos, type RepoSummaryResponse } from "../repos/queries";

// GitHub App install entry point (unchanged from the prior design): send the
// user to the App's installations/new page; GitHub redirects back to
// /github/setup with installation_id, which GithubSetupPage binds to the org.
// The org rides in `state` so the post-install redirect can bind it.
const GITHUB_APP_SLUG = import.meta.env.VITE_GITHUB_APP_SLUG ?? "harmont-app";
const githubInstallUrl = (org?: string) => {
  const base = `https://github.com/apps/${GITHUB_APP_SLUG}/installations/new`;
  return org ? `${base}?state=${encodeURIComponent(org)}` : base;
};

// Strip the trailing `.git` so the clone URL doubles as a browsable web URL.
const webUrl = (cloneUrl: string | null | undefined) =>
  cloneUrl ? cloneUrl.replace(/\.git$/, "") : undefined;

// Leading provider icon for a repo row: the icon of its first registration, so
// the table reads provider-at-a-glance without a dedicated column.
function leadIcon(repo: RepoSummaryResponse) {
  const first = repo.registrations[0]?.provider;
  if (first === "bitbucket")
    return <BitbucketIcon size={16} class="text-fg-muted shrink-0" />;
  if (first === "cli") return <CliIcon size={16} class="text-fg-muted shrink-0" />;
  return <GithubIcon size={16} class="text-fg-muted shrink-0" />;
}

const columns: Column<RepoSummaryResponse>[] = [
  {
    key: "repo",
    label: "Repository",
    render: (r) => (
      <div class="flex items-center gap-2.5 py-1">
        {leadIcon(r)}
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="text-fg font-medium text-sm truncate">{r.name}</span>
          <span class="text-fg-muted text-2xs truncate">{r.full_name}</span>
        </div>
      </div>
    ),
  },
  {
    key: "branch",
    label: "Default branch",
    render: (r) => (
      <Show when={r.default_branch} fallback={<span class="text-fg-dim">—</span>}>
        {(b) => <RefBadge class="text-2xs">{b()}</RefBadge>}
      </Show>
    ),
  },
  {
    key: "visibility",
    label: "Visibility",
    render: (r) => (
      <Tag variant={r.private ? "muted" : "ok"}>
        {r.private ? "Private" : "Public"}
      </Tag>
    ),
  },
  {
    key: "registrations",
    label: "Registered via",
    render: (r) => (
      <div class="flex flex-wrap items-center gap-1.5">
        <For each={r.registrations}>
          {(reg) => <RegistrationChip provider={reg.provider} account={reg.account} />}
        </For>
      </div>
    ),
  },
  {
    key: "synced",
    label: "Last synced",
    render: (r) => (
      <Show when={r.last_synced_at} fallback={<span class="text-fg-dim">—</span>}>
        {(t) => <TimeAgo date={t()} />}
      </Show>
    ),
  },
  {
    key: "open",
    label: "",
    align: "right",
    render: (r) => (
      <Show when={webUrl(r.clone_url)} fallback={null}>
        {(url) => (
          <LinkButton href={url()} target="_blank" size="sm">
            Open
            <ArrowSquareOutIcon size={10} />
          </LinkButton>
        )}
      </Show>
    ),
  },
];

export function ReposPage() {
  const orgSlug = useOrgSlug();
  const repos = useOrgRepos(orgSlug);

  return (
    <div>
      <Breadcrumb crumbs={[{ label: "Repos" }]} />

      <div class="flex items-center justify-between gap-4 mb-5">
        <h1 class="text-xl font-semibold text-fg">Repositories</h1>
        <Button
          variant="default"
          size="md"
          icon={<GithubIcon size={14} />}
          onClick={() => {
            window.location.href = githubInstallUrl(orgSlug());
          }}
        >
          Connect GitHub
        </Button>
      </div>

      <QueryGuard query={repos} loadingRows={5}>
        <Show
          when={(repos.data ?? []).length > 0}
          fallback={<EmptyState orgSlug={orgSlug()} />}
        >
          <Table columns={columns} rows={repos.data ?? []} />
        </Show>
      </QueryGuard>
    </div>
  );
}

function EmptyState(props: { orgSlug?: string }) {
  return (
    <div class="flex flex-col items-center gap-4 py-16">
      <GithubIcon size={28} class="text-fg-dim" />
      <h2 class="text-lg font-semibold text-fg">No repositories yet</h2>
      <p class="text-fg-muted text-sm text-center max-w-[340px]">
        Connect GitHub to link your repositories. Bitbucket can be connected from
        Settings.
      </p>
      <Button
        variant="primary"
        size="md"
        onClick={() => {
          window.location.href = githubInstallUrl(props.orgSlug);
        }}
      >
        Connect GitHub
      </Button>
    </div>
  );
}

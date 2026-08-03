import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { createApiClient } from "../api/client";
import type { components } from "../api/v1";

export type BitbucketWorkspace = components["schemas"]["BitbucketWorkspace"];

const BB_KEYS = {
  workspaces: (org: string) => ["bitbucket", "workspaces", org] as const,
};

export function useBitbucketWorkspaces(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...BB_KEYS.workspaces(orgSlug() ?? "")],
    queryFn: async (): Promise<components["schemas"]["BitbucketWorkspace"][]> => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/bitbucket/workspaces",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!.workspaces;
    },
    enabled: !!orgSlug(),
  }));
}

export async function fetchBitbucketOAuthUrl(orgSlug: string): Promise<string> {
  const client = createApiClient();
  const { data, error } = await client.GET(
    "/api/v0/organizations/{org}/bitbucket/oauth-url",
    { params: { path: { org: orgSlug } } },
  );
  if (error) throw error;
  return data!.url;
}

// The org is recovered server-side from the signed `state`, so the static
// `/bitbucket/setup` callback doesn't pass an org slug. The response carries
// the org slug back so the SPA can navigate to the org-scoped repos view.
export async function connectBitbucket(
  code: string,
  state: string,
): Promise<components["schemas"]["ConnectBitbucketResponse"]> {
  const client = createApiClient();
  const { data, error } = await client.POST(
    "/api/v0/integrations/bitbucket/connect",
    { body: { code, state } },
  );
  if (error) throw error;
  return data!;
}

export function useDisconnectBitbucket(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (workspace: string) => {
      const client = createApiClient();
      const { error } = await client.DELETE(
        "/api/v0/organizations/{org}/bitbucket/workspaces/{id}",
        { params: { path: { org: orgSlug()!, id: workspace } } },
      );
      if (error) throw error;
    },
    meta: { silenceToast: true },
    onSuccess: () =>
      qc.invalidateQueries({
        queryKey: [...BB_KEYS.workspaces(orgSlug() ?? "")],
      }),
  }));
}

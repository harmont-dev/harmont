import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { createApiClient } from "../api/client";
import type { components } from "../api/v1";

// Spec-generated shapes for the GitHub integration endpoints. These were
// previously local placeholders (the Elixir API had not yet ported the GitHub
// endpoints); they are now the real `components["schemas"]` types so the UI
// stays in lockstep with the API contract.
export type GithubInstallationResponse =
  components["schemas"]["GithubInstallation"];
export type GithubRepoResponse = components["schemas"]["GithubRepo"];

export type InstallationList =
  components["schemas"]["GithubInstallationList"];

export type RepoSummaryResponse = components["schemas"]["RepoSummary"];

export const GITHUB_KEYS = {
  installations: (orgSlug: string) =>
    ["github", orgSlug, "installations"] as const,
};

export function useInstallations(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...GITHUB_KEYS.installations(orgSlug()!)],
    queryFn: async (): Promise<InstallationList> => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/github/installations",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useSyncInstallation(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (installationId: number) => {
      const client = createApiClient();
      const { data, error } = await client.POST(
        "/api/v0/organizations/{org}/github/installations/{id}/sync",
        { params: { path: { org: orgSlug()!, id: installationId } } },
      );
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () =>
      qc.invalidateQueries({ queryKey: [...GITHUB_KEYS.installations(orgSlug()!)] }),
  }));
}

export function useDisconnectInstallation(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (installationId: number) => {
      const client = createApiClient();
      const { error } = await client.DELETE(
        "/api/v0/organizations/{org}/github/installations/{id}",
        { params: { path: { org: orgSlug()!, id: installationId } } },
      );
      if (error) throw error;
    },
    meta: { silenceToast: true },
    onSuccess: () =>
      qc.invalidateQueries({ queryKey: [...GITHUB_KEYS.installations(orgSlug()!)] }),
  }));
}

// Bind a GitHub installation to the organization. Returns the connected
// installation; `GithubSetup` reads `account_login` to confirm to the user.
export async function connectInstallation(
  orgSlug: string,
  installationId: number,
): Promise<GithubInstallationResponse> {
  const client = createApiClient();
  const { data, error } = await client.POST(
    "/api/v0/organizations/{org}/github/installations",
    {
      params: { path: { org: orgSlug } },
      body: { installation_id: installationId },
    },
  );
  if (error) throw error;
  return data!;
}

// The unified, provider-agnostic repo listing that backs the redesigned /repos
// page. One row per logical repo (grouped server-side by canonical clone URL),
// each carrying every registration channel.
export function useOrgRepos(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: ["repos", orgSlug() ?? ""] as const,
    queryFn: async (): Promise<RepoSummaryResponse[]> => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/repos",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!.data;
    },
    enabled: !!orgSlug(),
  }));
}

import { createMutation, createQuery, useQueryClient } from "@tanstack/solid-query";
import { createApiClient } from "../api/client";

export const ORG_KEYS = {
  detail: (orgSlug: string) => ["organization", orgSlug] as const,
};

export const ORG_LIST_KEY = ["organizations"] as const;

export function useOrganizations() {
  return createQuery(() => ({
    queryKey: [...ORG_LIST_KEY],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET("/api/v0/organizations");
      if (error) throw error;
      return data!;
    },
  }));
}

export function useCreateOrg() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (params: { name: string; url?: string }) => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/organizations", {
        body: { name: params.name, url: params.url },
      });
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...ORG_LIST_KEY] }),
  }));
}

/** The organization the dashboard is scoped to, identified by its slug. */
export function useOrganization(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...ORG_KEYS.detail(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET("/api/v0/organizations/{org}", {
        params: { path: { org: orgSlug()! } },
      });
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export const MEMBER_KEYS = {
  list: (orgSlug: string) => ["org-members", orgSlug] as const,
  invites: (orgSlug: string) => ["org-invites", orgSlug] as const,
};

export function useOrgMembers(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...MEMBER_KEYS.list(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/members",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useUpdateMemberRole(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (params: { userId: string; role: "owner" | "admin" | "member" }) => {
      const client = createApiClient();
      const { data, error } = await client.PATCH(
        "/api/v0/organizations/{org}/members/{user_id}",
        {
          params: { path: { org: orgSlug()!, user_id: params.userId } },
          body: { role: params.role },
        },
      );
      if (error) throw error;
      return data!;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...MEMBER_KEYS.list(orgSlug()!)] }),
  }));
}

export function useRemoveMember(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (userId: string) => {
      const client = createApiClient();
      const { error } = await client.DELETE(
        "/api/v0/organizations/{org}/members/{user_id}",
        { params: { path: { org: orgSlug()!, user_id: userId } } },
      );
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...MEMBER_KEYS.list(orgSlug()!)] }),
  }));
}

export function useOrgInvites(orgSlug: () => string | undefined) {
  return createQuery(() => ({
    queryKey: [...MEMBER_KEYS.invites(orgSlug()!)],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET(
        "/api/v0/organizations/{org}/invites",
        { params: { path: { org: orgSlug()! } } },
      );
      if (error) throw error;
      return data!;
    },
    enabled: !!orgSlug(),
  }));
}

export function useCreateInvite(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (params: { email: string; role: "admin" | "member" }) => {
      const client = createApiClient();
      const { data, error } = await client.POST(
        "/api/v0/organizations/{org}/invites",
        {
          params: { path: { org: orgSlug()! } },
          body: { email: params.email, role: params.role },
        },
      );
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...MEMBER_KEYS.invites(orgSlug()!)] }),
  }));
}

export function useRevokeInvite(orgSlug: () => string | undefined) {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (id: string) => {
      const client = createApiClient();
      const { error } = await client.DELETE(
        "/api/v0/organizations/{org}/invites/{id}",
        { params: { path: { org: orgSlug()!, id } } },
      );
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...MEMBER_KEYS.invites(orgSlug()!)] }),
  }));
}

export function useAcceptInvite() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (token: string) => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/invites/accept", {
        body: { token },
      });
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...ORG_LIST_KEY] }),
  }));
}

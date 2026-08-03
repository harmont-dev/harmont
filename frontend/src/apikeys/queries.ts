import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import { createApiClient } from "../api/client";
import type { ApiKeyCreateRequest, ApiKeyCreateResponse } from "./types";

export const API_KEY_KEYS = {
  list: ["api-keys"] as const,
};

export function useApiKeys() {
  return createQuery(() => ({
    queryKey: [...API_KEY_KEYS.list],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET("/api/v0/user/api-tokens");
      if (error) throw error;
      return data!;
    },
  }));
}

export function useCreateApiKey() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (body: ApiKeyCreateRequest): Promise<ApiKeyCreateResponse> => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/user/api-tokens", {
        body,
      });
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...API_KEY_KEYS.list] });
    },
  }));
}

export function useRevokeApiKey() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (id: string) => {
      const client = createApiClient();
      const { error } = await client.DELETE("/api/v0/user/api-tokens/{id}", {
        params: { path: { id } },
      });
      if (error) throw error;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...API_KEY_KEYS.list] });
    },
  }));
}

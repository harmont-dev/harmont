import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import { createApiClient } from "../api/client";
import { setToken, clearToken, hasToken } from "./token";

export const AUTH_KEYS = {
  currentUser: ["auth", "currentUser"] as const,
};

export function useCurrentUser() {
  return createQuery(() => ({
    queryKey: [...AUTH_KEYS.currentUser],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET("/api/v0/user");
      if (error) throw error;
      return data;
    },
    // Logged-in/out state derives from token presence: with no token there's
    // nothing to fetch, and the query stays in a non-success state so the
    // auth guard sends the user to /login. A successful /user with a token
    // means authenticated.
    enabled: hasToken(),
  }));
}

export function useGoogleLogin() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (params: { code: string; redirect_uri: string }) => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/auth/google", {
        body: params,
      });
      if (error) throw error;
      setToken(data!.token);
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] });
    },
  }));
}

export function useGithubLogin() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (params: { code: string; redirect_uri: string }) => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/auth/github", {
        body: params,
      });
      if (error) throw error;
      setToken(data!.token);
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] });
    },
  }));
}

export function usePasskeyLogin() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async () => {
      const { startAuthentication } = await import("@simplewebauthn/browser");
      const client = createApiClient();

      const { data: opts, error: optsErr } = await client.POST(
        "/api/v0/auth/passkey/login/options",
        { body: {} },
      );
      if (optsErr) throw optsErr;
      if (!opts) throw new Error("No passkey options returned");

      const assertion = await startAuthentication({
        optionsJSON: opts.options as unknown as Parameters<
          typeof startAuthentication
        >[0]["optionsJSON"],
      });

      const { data, error } = await client.POST(
        "/api/v0/auth/passkey/login/finalize",
        {
          body: {
            challenge_id: opts.challenge_id,
            assertion: assertion as unknown as Record<string, unknown>,
          },
        },
      );
      if (error) throw error;
      setToken(data!.token);
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] });
    },
  }));
}

export function useSignupBegin() {
  return createMutation(() => ({
    mutationFn: async (params: { email: string; name: string }) => {
      const client = createApiClient();
      const { error } = await client.POST("/api/v0/auth/passkey/signup/begin", {
        body: params,
      });
      if (error) throw error;
    },
    meta: { silenceToast: true },
  }));
}

export function useSignupFinalize() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (token: string) => {
      const { startRegistration } = await import("@simplewebauthn/browser");
      const client = createApiClient();

      const { data: opts, error: optsErr } = await client.POST(
        "/api/v0/auth/passkey/signup/options",
        { body: { verification_token: token } },
      );
      if (optsErr) throw optsErr;
      if (!opts) throw new Error("No signup options returned");

      const attestation = await startRegistration({
        optionsJSON: opts.options as unknown as Parameters<
          typeof startRegistration
        >[0]["optionsJSON"],
      });

      const { data, error } = await client.POST(
        "/api/v0/auth/passkey/signup/finalize",
        {
          body: {
            challenge_id: opts.challenge_id,
            verification_token: token,
            attestation: attestation as unknown as Record<string, unknown>,
          },
        },
      );
      if (error) throw error;
      setToken(data!.token);
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] });
    },
  }));
}

export function useLogout() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async () => {
      const client = createApiClient();
      // Bearer-authed; ignore errors (e.g. already-expired token).
      await client.POST("/api/v0/auth/logout");
    },
    onSettled: () => {
      clearToken();
      qc.clear();
    },
  }));
}

export function useRecoverBegin() {
  return createMutation(() => ({
    mutationFn: async (params: { email: string }) => {
      const client = createApiClient();
      const { error } = await client.POST("/api/v0/auth/recover/begin", {
        body: params,
      });
      if (error) throw error;
    },
    meta: { silenceToast: true },
  }));
}

export function useRecoverFinalize() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (token: string) => {
      const { startRegistration } = await import("@simplewebauthn/browser");
      const client = createApiClient();

      const { data: opts, error: optsErr } = await client.POST(
        "/api/v0/auth/recover/options",
        { body: { magic_link_token: token } },
      );
      if (optsErr) throw optsErr;
      if (!opts) throw new Error("No recovery options returned");

      const attestation = await startRegistration({
        optionsJSON: opts.options as unknown as Parameters<
          typeof startRegistration
        >[0]["optionsJSON"],
      });

      const { data, error } = await client.POST("/api/v0/auth/recover/finalize", {
        body: {
          magic_link_token: token,
          challenge_id: opts.challenge_id,
          attestation: attestation as unknown as Record<string, unknown>,
        },
      });
      if (error) throw error;
      setToken(data!.token);
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] });
    },
  }));
}

export const PASSKEY_KEYS = {
  list: ["passkeys"] as const,
};

export function usePasskeys() {
  return createQuery(() => ({
    queryKey: [...PASSKEY_KEYS.list],
    queryFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.GET("/api/v0/user/passkeys");
      if (error) throw error;
      return data!;
    },
  }));
}

export function useAddPasskey() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (nickname?: string) => {
      const { startRegistration } = await import("@simplewebauthn/browser");
      const client = createApiClient();

      const { data: opts, error: optsErr } = await client.POST(
        "/api/v0/auth/passkey/register/options",
      );
      if (optsErr) throw optsErr;
      if (!opts) throw new Error("No options returned");

      const attestation = await startRegistration({
        optionsJSON: opts.options as unknown as Parameters<
          typeof startRegistration
        >[0]["optionsJSON"],
      });

      const { data, error } = await client.POST(
        "/api/v0/auth/passkey/register/finalize",
        {
          body: {
            challenge_id: opts.challenge_id,
            attestation: attestation as unknown as Record<string, unknown>,
            nickname,
          },
        },
      );
      if (error) throw error;
      return data;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...PASSKEY_KEYS.list] });
    },
  }));
}

export function useRevokePasskey() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (id: string) => {
      const client = createApiClient();
      const { error } = await client.DELETE(
        "/api/v0/user/passkeys/{uuid}",
        { params: { path: { uuid: id } } },
      );
      if (error) throw error;
    },
    meta: { silenceToast: true },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: [...PASSKEY_KEYS.list] });
    },
  }));
}

export function useCliTransfer() {
  return createMutation(() => ({
    mutationFn: async (params: { nonce: string }) => {
      const client = createApiClient();
      const { error } = await client.POST("/api/v0/auth/cli/transfer", {
        body: params,
      });
      if (error) throw error;
    },
    meta: { silenceToast: true },
  }));
}

export function useCliCodeCreate() {
  return createMutation(() => ({
    mutationFn: async () => {
      const client = createApiClient();
      const { data, error } = await client.POST("/api/v0/auth/cli/code");
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
  }));
}

export function useUpdateProfile() {
  const qc = useQueryClient();
  return createMutation(() => ({
    mutationFn: async (name: string) => {
      const client = createApiClient();
      const { data, error } = await client.PATCH("/api/v0/user", { body: { name } });
      if (error) throw error;
      return data!;
    },
    meta: { silenceToast: true },
    onSuccess: () => qc.invalidateQueries({ queryKey: [...AUTH_KEYS.currentUser] }),
  }));
}

export function useDeleteAccount() {
  return createMutation(() => ({
    mutationFn: async () => {
      const client = createApiClient();
      const { error } = await client.DELETE("/api/v0/user");
      if (error) throw error;
    },
    meta: { silenceToast: true },
  }));
}

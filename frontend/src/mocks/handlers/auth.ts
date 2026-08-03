import { http, HttpResponse } from "msw";
import { mockUser, mockToken, mockPasskeys } from "../data";

const BASE = "/api/v0";

const json = (body: Record<string, unknown>, opts?: { setCookie?: boolean }) =>
  HttpResponse.json(body, {
    headers: {
      "Content-Type": "application/json;charset=utf-8",
      ...(opts?.setCookie && { "Set-Cookie": "hm-logged-in=1; Path=/" }),
    },
  });

export const authHandlers = [
  http.post(`${BASE}/auth/google`, async () => {
    return json({ token: mockToken, user: mockUser }, { setCookie: true });
  }),

  http.post(`${BASE}/auth/github`, async () => {
    return json({ token: mockToken, user: mockUser }, { setCookie: true });
  }),

  http.post(`${BASE}/auth/passkey/login/options`, async () => {
    return json({
      challenge_id: "mock-challenge-id",
      options: {
        challenge: "bW9jay1jaGFsbGVuZ2U",
        timeout: 60000,
        rpId: "localhost",
        allowCredentials: [],
        userVerification: "preferred",
      },
    });
  }),

  http.post(`${BASE}/auth/passkey/login/finalize`, async () => {
    return json({ token: mockToken, user: mockUser }, { setCookie: true });
  }),

  http.post(`${BASE}/auth/passkey/signup/begin`, async () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.post(`${BASE}/auth/passkey/signup/options`, async () => {
    return json({
      challenge_id: "mock-signup-challenge-id",
      options: {
        challenge: "bW9jay1zaWdudXAtY2hhbGxlbmdl",
        rp: { name: "Harmont", id: "localhost" },
        user: {
          id: "bW9jay11c2VyLWlk",
          name: "ada@example.com",
          displayName: "Ada Lovelace",
        },
        pubKeyCredParams: [
          { alg: -7, type: "public-key" },
          { alg: -257, type: "public-key" },
        ],
        timeout: 60000,
        attestation: "none",
        authenticatorSelection: {
          residentKey: "required",
          userVerification: "preferred",
        },
      },
    });
  }),

  http.post(`${BASE}/auth/passkey/signup/finalize`, async () => {
    return json({ token: mockToken, user: mockUser }, { setCookie: true });
  }),

  http.post(`${BASE}/auth/logout`, async () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.post(`${BASE}/auth/recover/begin`, async () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.post(`${BASE}/auth/recover/finalize`, async () => {
    return json({ token: mockToken, user: mockUser }, { setCookie: true });
  }),

  http.get(`${BASE}/user`, async () => {
    return json(mockUser);
  }),

  http.patch(`${BASE}/user`, async ({ request }) => {
    const body = (await request.json()) as { name?: string };
    if (body.name !== undefined) mockUser.name = body.name;
    return json({
      uuid: mockUser.uuid,
      email: mockUser.email,
      name: mockUser.name,
      personal_org_slug: mockUser.personal_org_slug,
    });
  }),

  http.delete(`${BASE}/user`, async () => new HttpResponse(null, { status: 204 })),

  http.post(`${BASE}/auth/recover/options`, async () => {
    return json({
      challenge_id: "mock-recover-challenge",
      options: {
        challenge: "bW9jay1yZWNvdmVyLWNoYWxsZW5nZQ",
        rp: { name: "Harmont", id: "localhost" },
        user: {
          id: "bW9jay11c2VyLWlk",
          name: "marko@harmont.dev",
          displayName: "Marko Vejnovic",
        },
        pubKeyCredParams: [
          { alg: -7, type: "public-key" },
          { alg: -257, type: "public-key" },
        ],
        timeout: 60000,
        attestation: "none",
      },
    });
  }),

  http.get(`${BASE}/user/passkeys`, async () => {
    return json({ passkeys: mockPasskeys });
  }),

  http.post(`${BASE}/auth/passkey/register/options`, async () => {
    return json({
      challenge_id: "mock-register-challenge",
      options: {
        challenge: "bW9jay1yZWdpc3Rlci1jaGFsbGVuZ2U",
        rp: { name: "Harmont", id: "localhost" },
        user: { id: "bW9jay11c2VyLWlk", name: "marko@harmont.dev", displayName: "Marko Vejnovic" },
        pubKeyCredParams: [{ alg: -7, type: "public-key" }, { alg: -257, type: "public-key" }],
        timeout: 60000,
        attestation: "none",
        authenticatorSelection: { residentKey: "required", userVerification: "preferred" },
      },
    });
  }),

  http.post(`${BASE}/auth/passkey/register/finalize`, async () => {
    return json({
      uuid: "pk-" + Date.now(),
      nickname: null,
      created_at: new Date().toISOString(),
      last_used_at: null,
    });
  }),

  http.patch(`${BASE}/user/passkeys/:uuid`, async ({ params, request }) => {
    const body = await request.json() as { nickname: string };
    const pk = mockPasskeys.find((p) => p.uuid === params.uuid);
    return json({ ...pk, nickname: body.nickname });
  }),

  http.delete(`${BASE}/user/passkeys/:uuid`, async () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.post(`${BASE}/auth/cli/transfer`, async () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.post(`${BASE}/auth/cli/code`, async () => {
    return json({ code: "ABCD-1234-EFGH" });
  }),
];

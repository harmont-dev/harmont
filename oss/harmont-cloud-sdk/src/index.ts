// Public entrypoint for @harmont/cloud.
//
// The operation functions and types come from the generated surface
// (a gitignored build artifact regenerated from the OpenAPI spec). The HTTP
// client is generated (vendored) into ./generated/client, so the SDK has no
// runtime dependency on the hey-api packages — we re-export its helpers here
// so consumers configure auth/baseUrl from a single import.

// One function per operationId, plus all request/response types
// (including the ClientOptions type).
export * from "./generated";

// The default client instance (its baseUrl default comes from the generated client).
export { client } from "./generated/client.gen";

// Construct/override a client (e.g. to attach a bearer token).
export { createClient, createConfig } from "./generated/client";
export type { Client, Config } from "./generated/client";

// The api-key type seam, now backed by the generated OpenAPI client. Import
// sites (hooks, mocks, component) are unchanged from Phase 1 — only this file
// flipped from hand-written shapes to codegen aliases.
import type { components } from "../api/v1";

export type ApiKey = components["schemas"]["ApiToken"];
export type ApiKeyCreateRequest = components["schemas"]["ApiTokenCreateRequest"];
export type ApiKeyCreateResponse = components["schemas"]["ApiTokenCreateResponse"];

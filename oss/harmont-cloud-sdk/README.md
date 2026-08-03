# @harmont/cloud

A TypeScript SDK for the Harmont API, generated from the committed OpenAPI spec
using [hey-api](https://heyapi.dev/).

## Install

```bash
npm install @harmont/cloud
```

## Usage

Every function maps to one API operation. Construct a client with your bearer
token and pass it per call:

```ts
import { createClient, createConfig, listOrganizations, createBuild } from "@harmont/cloud";

const client = createClient(
  createConfig({
    baseUrl: "https://api.harmont.dev", // the default; override for self-host/dev
  }),
);
client.interceptors.request.use((req) => {
  req.headers.set("Authorization", `Bearer ${process.env.HARMONT_TOKEN}`);
  return req;
});

const { data: orgs } = await listOrganizations({ client });
const { data: build } = await createBuild({
  client,
  path: { org: "acme", pipeline: "ci" },
  body: { /* CreateBuildRequest — see types */ },
});
```

A default `client` (baseUrl `https://api.harmont.dev`) is also exported; call
`client.setConfig(...)` to configure it globally instead of threading a client
through every call.

## Releasing (maintainers)

Publishing is **manual**. Prerequisites: `npm login` as a member of the
`@harmont` org with publish rights (`npm org ls harmont` lists members and
their roles — you need `developer` or higher).

```bash
# 1. From repo root, regenerate the spec + SDK and verify.
make build-sdk
cd oss/harmont-cloud-sdk
npm test                       # pack-contents guard must pass

# 2. Bump the version (no git tag — we tag explicitly below).
npm version patch --no-git-tag-version   # or minor / major

# 3. Dry-run the publish and eyeball the file list.
npm publish --dry-run

# 4. Publish (prepack regenerates + rebuilds dist automatically).
npm publish --access public

# 5. Commit the version bump and tag the release (stage explicitly so a dirty
#    working tree isn't swept into the release commit).
git add package.json package-lock.json
git commit -m "release(sdk): @harmont/cloud vX.Y.Z"
git tag "sdk-v$(node -p "require('./package.json').version")"
git push && git push --tags
```

**Versioning policy:** the SDK mirrors the OpenAPI spec. Bump **minor** when the
spec adds operations/fields (additive), **major** when an operation is
removed/renamed or a field's type changes (breaking), **patch** for SDK-only
fixes (build, docs, metadata).

## How it works

`src/generated/` is a **gitignored build artifact** — it is regenerated from
`elixir/apps/harmont_api/priv/static/openapi.json` and is never committed.
The committed source of truth for the API shape is the OpenAPI spec; the SDK
surface always mirrors it exactly.

## Generating the SDK

```bash
# From this directory:
npm install
npm run codegen    # writes src/generated/ from the committed openapi.json
npm run typecheck  # tsc --noEmit — verifies the generated types are valid
```

Or from the repo root (does install + codegen in one shot):

```bash
make codegen-sdk
```

## SDK surface

The SDK exposes one function per `operationId` in the spec — the full set
mirrors the OpenAPI spec exactly (see `src/generated/sdk.gen.ts` after codegen,
or your editor's autocomplete). A few of the most common:

| Function | Description |
|---|---|
| `createBuild` | Create a new build for a pipeline |
| `getBuild` | Fetch a build by ID |
| `createPipeline` | Create a new pipeline in an organization |
| `listOrganizations` | List organizations accessible to the token |
| `getBuildLogToken` | Mint a short-lived token for SSE log streaming |
| `listJobs` | List jobs belonging to a build |

See `e2e/run.ts` for a complete, working example — it imports the generated functions (e.g. `createBuild`, `getBuild`) from `../src/generated/index.ts`, attaches a bearer token, and drives the full push-and-run flow.

## Known gaps

**Log streaming is not in the SDK.** The SSE log endpoint is intentionally
absent from `openapi.json` because it is a streaming transport, not a
request/response operation. To stream logs:

1. Call `getBuildLogToken` to mint a short-lived token for the job.
2. Open the SSE URL directly:
   ```
   GET /v0/jobs/{job_id}/logs?token=<log_token>
   ```
   See `e2e/run.ts` for a working example using Node's `fetch` + an async
   iterator over the response body.

**`env` is a server-side no-op today.** The `env` field on build steps is
accepted by the API but not yet forwarded to the job executor.

## Running the e2e harness

```bash
HARMONT_E2E=1 \
HARMONT_API_URL=http://localhost:4000 \
HARMONT_TOKEN=hmt_localdev_devseed \
  npm run e2e
```

The dev backend must be running before the local e2e — start it with
`scripts/dev-up.sh` in a separate terminal. Port **4000** is the Elixir/Phoenix
API server (`mix phx.server`); port 3000 is the frontend Vite dev server and
would not handle API requests.

- Omitting `HARMONT_E2E` (or setting it to any falsy value) makes the harness
  **no-op** (exit 0). This keeps CI green when the live backend is not
  available.
- You can point `HARMONT_API_URL` at `https://api.harmont.dev` with a real
  token to run against production.
- `HARMONT_E2E_EXPECT_SOURCE=1` asserts that the uploaded source archive was
  materialized into the job workdir. This is **only valid against a real-VM
  backend** — the local dev backend (`mix phx.server`) does not materialize
  source into the job workdir.

### Verifying the published package

Two tests gate publishability (run by `npm test`):

- `e2e/pack.test.ts` (always on, offline) — asserts the npm tarball ships the
  built `dist/` and excludes source/tests/configs.
- `e2e/install.test.ts` (opt-in, needs network) — packs the real tarball,
  installs it into a throwaway project, and imports it as a consumer would.
  Enable it with `HARMONT_SDK_INSTALL_TEST=1`:

  ```bash
  HARMONT_SDK_INSTALL_TEST=1 npm test
  ```

## Smoke-test against a live backend

`e2e/prod.test.ts` runs one named pass/fail per core capability (auth → create
pipeline → submit local code → run build → read jobs → read logs). It is skipped
unless pointed at a backend, so it is safe in a normal `npm test`.

```bash
HARMONT_E2E=1 \
HARMONT_API_URL=https://api.harmont.dev \
HARMONT_TOKEN=<your-bearer-token> \
  npm run test:prod
```

Optional env: `HARMONT_ORG` to pin the org slug (default: the token's first
org), `HARMONT_REPO_DIR` to upload a real repo instead of the bundled fixture,
`HARMONT_E2E_TIMEOUT_MS` for the build-poll budget (default 300000).

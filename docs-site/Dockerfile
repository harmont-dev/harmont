# syntax=docker/dockerfile:1.7

# ---- Stage 1: dependencies ----
FROM --platform=linux/amd64 node:20-bookworm-slim AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate
# fumadocs-mdx's postinstall hook detects Next vs Vite by probing for
# next.config.{js,mjs,mts,ts}; without it the Vite branch loads and
# fails on a missing `vite` import. Copy the config alongside the manifests.
COPY package.json pnpm-lock.yaml next.config.mjs source.config.ts ./
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# ---- Stage 2: build ----
FROM --platform=linux/amd64 node:20-bookworm-slim AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# openapi.json, error-catalog.json, dsl-api.json, and sdk-api.json are expected
# in the build context. The deploy script stages all four before `docker build`:
# openapi (PUBLIC spec) + error-catalog from the Elixir umbrella (OpenApiSpex),
# dsl-api.json from the harmont-cli submodule via griffe, and sdk-api.json from
# the public spec via extract-sdk-api.ts. They arrive here through `COPY . .`.
# (lib/error-catalog.ts imports ../error-catalog.json; lib/dsl-api.ts imports
# ../dsl-api.json; lib/sdk-api.ts imports ../sdk-api.json; generate reads openapi
# + emits the API/DSL/SDK reference.)
RUN test -f openapi.json || (echo "openapi.json missing; run 'make docs-site/openapi.json' to stage it" && exit 1)
RUN test -f error-catalog.json || (echo "error-catalog.json missing; run 'make docs-site/error-catalog.json'" && exit 1)
RUN test -f dsl-api.json || (echo "dsl-api.json missing; run 'make docs-site/dsl-api.json' (needs the harmont-cli submodule + uv)" && exit 1)
# sdk-api.json is the @harmont/cloud TS surface, derived from the public spec by
# scripts/extract-sdk-api.ts. lib/sdk-api.ts imports ../sdk-api.json; generate
# emits the SDK reference. Guard it here so a missing stage fails fast with this
# message instead of an opaque ERR_MODULE_NOT_FOUND deep in `pnpm run generate`.
RUN test -f sdk-api.json || (echo "sdk-api.json missing; run 'make docs-site/sdk-api.json' (needs npm to generate the SDK client)" && exit 1)
# Example projects live in the harmont-cli submodule. They must be staged
# into the build context at examples-vendor/ (they arrive via COPY . . at
# /app/examples-vendor); point the Tree/RemoteCode components there instead of
# resolving relative to the repo root, which doesn't exist in this image.
ENV HARMONT_EXAMPLES_DIR=/app/examples-vendor
ENV NEXT_TELEMETRY_DISABLED=1
RUN test -d examples-vendor || (echo "examples-vendor/ missing; stage it from harmont-cli/examples" && exit 1)
RUN pnpm run generate
RUN pnpm run build

# ---- Stage 3: runtime ----
FROM --platform=linux/amd64 node:20-bookworm-slim AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080 \
    HOSTNAME=0.0.0.0
# Cloud Run-friendly: non-root user, minimal copy.
RUN groupadd --system --gid 1001 nodejs && \
    useradd --system --uid 1001 --gid nodejs nextjs
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
USER nextjs
EXPOSE 8080
CMD ["node", "server.js"]

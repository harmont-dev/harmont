# docs-site

User-facing documentation for Harmont. Next.js 16 + Fumadocs.

## Quick start

```bash
make docs-install     # one-time pnpm install
make codegen          # regenerate the OpenAPI spec (Elixir OpenApiSpex)
make docs-generate    # generate content/docs/api from openapi.json
make docs-dev         # start the dev server on :4174
```

Production build:

```bash
make docs-build       # standalone build to docs-site/.next/standalone/
```

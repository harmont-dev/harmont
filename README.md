# Harmont

Headless CI platform that mirrors Buildkite's semantics. The core differentiator: developers push **local code** from their machine directly into CI pipelines via `hm run`, without committing or pushing to a remote first.

The product is **Harmont** (`harmont.dev`). `hm` is the binary prefix.

## Architecture

| Path | What it is |
|---|---|
| `elixir/` | Elixir umbrella backend over one Postgres DB — domain (`harmont_core`), REST API (`harmont_api`), build executor (`harmont_engine`), GitHub App (`harmont_gh_app`), serving edge (`harmont_web`) |
| `harmont-cli/` | Submodule (OSS `harmont-dev/harmont-cli`): the `hm` CLI + local `hm run` orchestrator, the Python + TypeScript pipeline DSLs, and the Rust pipeline IR |
| `frontend/` | Solid.js SPA dashboard (Vite, TanStack Query, Tailwind) |
| `agent/` | Rust agent injected into every job VM (command exec, log streaming, heartbeat) |
| `oss/` | Public SDK packages (`@harmont/cloud` TypeScript client; Rust cloud SDK) |
| `proto/` | Protobuf schema for the agent ↔ backend wire protocol |

## Examples

See [`harmont-cli/examples/`](./harmont-cli/examples) for the canonical, CI-tested starter projects (Rust, Go, Python + uv, JavaScript/TypeScript, C/C++, Zig, Elixir) — each wired to a Harmont CI pipeline. (The repo-root `examples/` is a build-time fetch of that same set and is gitignored.)

## Build & test

```sh
make build    # builds everything
make test     # tests everything
make services # starts PostgreSQL via docker compose
```

### Backend prerequisites

- **Oban Pro (commercial) is a required dependency.** `harmont_core` depends on
  `oban_pro`, fetched from the private Hex repo `https://repo.oban.pro`. Without
  a paid [Oban Pro](https://oban.pro) license configured for Hex, `mix deps.get`
  fails with `Unknown repository "oban"` and the backend will not compile.
- **Boot-critical environment variables.** `elixir/config/runtime.exs` reads a
  number of `HARMONT_*` / OAuth variables with `System.fetch_env!`, so the
  release **crashes on boot if they are unset**. At minimum:
  `HARMONT_OBAN_ENCRYPTION_KEY`, `HARMONT_OBAN_DASHBOARD_USER`,
  `HARMONT_OBAN_DASHBOARD_PASSWORD`, `HARMONT_LOG_TOKEN_SECRET`, plus the
  GitHub-App / OAuth secrets and the internal GitHub proxy token. The committed
  `dev`/`test` config values are local-only fixtures — production must supply
  real secrets via the environment.

## License

MIT — see [`LICENSE`](./LICENSE).

#!/bin/bash
# One-shot local dev stack: postgres + harmont-api + frontend dev server.
#
# Usage:
#   scripts/dev-up.sh                                # HARMONT_API_URL defaults to http://localhost:3000
#   scripts/dev-up.sh http://192.0.2.10:3000         # explicit URL (e.g. VPS accessed from laptop)
#   HARMONT_API_URL=http://host:3000 scripts/dev-up.sh
#
# Reuses an already-running postgres on :5432 if it exposes a `harmont` role;
# otherwise brings one up via `docker compose up -d`.
# Logs from harmont-api and dev.sh are tee'd into .dev-logs/ and streamed
# (prefixed) to the current terminal. Ctrl+C tears everything down.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Keep vendored repos (harmont-cli) on their branch HEAD so local hm matches
# upstream main — see scripts/sync-submodules.sh. Non-fatal: an offline dev keeps
# whatever is currently checked out.
"$ROOT/scripts/sync-submodules.sh" || echo "WARN: submodule sync failed; using current checkout" >&2

FRONTEND_PORT="${FRONTEND_PORT:-8765}"

# Default HARMONT_API_URL prefers the host's Tailscale IP (so a browser on another
# device in the tailnet can reach this API), falls back to localhost.
default_api_url() {
  if command -v tailscale >/dev/null 2>&1; then
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
    if [ -n "$ts_ip" ]; then
      echo "http://$ts_ip:3000"
      return
    fi
  fi
  echo "http://localhost:3000"
}

HARMONT_API_URL="${1:-${HARMONT_API_URL:-$(default_api_url)}}"

# Optional Honeycomb export. If HONEYCOMB_API_KEY is set in the
# developer's shell, propagate the OTEL_* contract to the api
# subprocess; otherwise stay silent (without OTEL_EXPORTER_OTLP_ENDPOINT
# the OTEL SDK becomes a noop tracer, which is what we want).
if [ -n "${HONEYCOMB_API_KEY:-}" ]; then
  export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-harmont-api-dev}"
  export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-https://api.honeycomb.io}"
  export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
  export OTEL_EXPORTER_OTLP_HEADERS="x-honeycomb-team=${HONEYCOMB_API_KEY}"
  export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=dev,developer=$(id -un)"
  echo "→ OpenTelemetry export → Honeycomb (service=$OTEL_SERVICE_NAME, env=dev)"
fi

mkdir -p .dev-logs
API_LOG="$ROOT/.dev-logs/api.log"
APP_LOG="$ROOT/.dev-logs/app.log"

API_PID=""
APP_PID=""
STARTED_COMPOSE=0

cleanup() {
  echo ""
  echo "→ Shutting down dev stack..."
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  if [ "$STARTED_COMPOSE" -eq 1 ]; then
    echo "→ (leaving docker compose running — stop with 'make dev-down' if you want)"
  fi
}
trap cleanup EXIT INT TERM

# --- Postgres: reuse if possible, else docker compose up ---
psql_probe() {
  docker compose exec -T postgres psql -U harmont -d harmont -tAc 'SELECT 1' >/dev/null 2>&1
}

if psql_probe; then
  echo "→ postgres already running via docker compose"
else
  # Check if something else is hogging port 5432
  if ss -tlnp 2>/dev/null | grep -q ':5432 '; then
    echo "⚠  Port 5432 is already in use by another process:"
    ss -tlnp 2>/dev/null | grep ':5432 ' | sed 's/^/    /'
    printf "Kill it and continue? [y/N] "
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
      # Kill whatever holds port 5432 (docker containers or bare processes)
      container_id=$(docker ps -q --filter "publish=5432" 2>/dev/null || true)
      if [ -n "$container_id" ]; then
        echo "→ stopping docker container(s) on :5432"
        docker stop $container_id
      fi
      # Also kill any non-docker process binding 5432
      fuser -k 5432/tcp 2>/dev/null || true
      sleep 1
    else
      echo "Aborted." >&2
      exit 1
    fi
  fi

  echo "→ starting postgres via docker compose"
  docker compose up -d postgres
  STARTED_COMPOSE=1
  echo "→ waiting for postgres to be ready..."
  for _ in $(seq 1 30); do
    psql_probe && break
    sleep 1
  done
  if ! psql_probe; then
    echo "✗ postgres did not become ready in 30s" >&2
    exit 1
  fi
fi

# --- Prepare the Elixir backend: deps + create/migrate the dev DB ---
# config/dev.exs points Harmont.Repo at the `harmont_dev` database; `mix
# ecto.create` is a no-op if it already exists and `ecto.migrate` is idempotent.
echo "→ preparing Elixir backend (deps + db)"
(
  cd elixir
  mix deps.get
  mix ecto.create
  mix ecto.migrate
) || { echo "✗ backend prep (deps/ecto) failed" >&2; exit 1; }

# --- Write .hm-dev-env so dev.sh knows which API URL to bake into config.js ---
# Preserve HARMONT_TOKEN, HARMONT_GOOGLE_CLIENT_ID, and the OAuth secret pair
# across restarts so users only configure them once.
EXISTING_TOKEN=""
EXISTING_GOOGLE_CLIENT_ID=""
EXISTING_GOOGLE_OAUTH_CLIENT_ID=""
EXISTING_GOOGLE_OAUTH_CLIENT_SECRET=""
EXISTING_GITHUB_APP_SLUG=""
if [ -f .hm-dev-env ]; then
  EXISTING_TOKEN=$(grep -E '^HARMONT_TOKEN=' .hm-dev-env | head -n1 | cut -d= -f2- || true)
  EXISTING_GOOGLE_CLIENT_ID=$(grep -E '^HARMONT_GOOGLE_CLIENT_ID=' .hm-dev-env | head -n1 | cut -d= -f2- || true)
  EXISTING_GOOGLE_OAUTH_CLIENT_ID=$(grep -E '^HARMONT_GOOGLE_OAUTH_CLIENT_ID=' .hm-dev-env | head -n1 | cut -d= -f2- || true)
  EXISTING_GOOGLE_OAUTH_CLIENT_SECRET=$(grep -E '^HARMONT_GOOGLE_OAUTH_CLIENT_SECRET=' .hm-dev-env | head -n1 | cut -d= -f2- || true)
  EXISTING_GITHUB_APP_SLUG=$(grep -E '^HARMONT_GITHUB_APP_SLUG=' .hm-dev-env | head -n1 | cut -d= -f2- || true)
fi
# If only HARMONT_GOOGLE_CLIENT_ID is set, default the backend client id to it
# (single OAuth client serves both layers in dev). The secret has no parallel
# default — user must set it explicitly.
if [ -z "$EXISTING_GOOGLE_OAUTH_CLIENT_ID" ] && [ -n "$EXISTING_GOOGLE_CLIENT_ID" ]; then
  EXISTING_GOOGLE_OAUTH_CLIENT_ID=$EXISTING_GOOGLE_CLIENT_ID
fi
cat > .hm-dev-env <<EOF
HARMONT_API_URL=$HARMONT_API_URL
HARMONT_ORG=default
HARMONT_TOKEN=$EXISTING_TOKEN
HARMONT_GOOGLE_CLIENT_ID=$EXISTING_GOOGLE_CLIENT_ID
HARMONT_GOOGLE_OAUTH_CLIENT_ID=$EXISTING_GOOGLE_OAUTH_CLIENT_ID
HARMONT_GOOGLE_OAUTH_CLIENT_SECRET=$EXISTING_GOOGLE_OAUTH_CLIENT_SECRET
HARMONT_GITHUB_APP_SLUG=${EXISTING_GITHUB_APP_SLUG:-harmont-app}
EOF
echo "→ wrote .hm-dev-env (HARMONT_API_URL=$HARMONT_API_URL)"
if [ -z "$EXISTING_GOOGLE_OAUTH_CLIENT_SECRET" ]; then
  echo "  ⚠ HARMONT_GOOGLE_OAUTH_CLIENT_SECRET is empty — /auth/google will return 400."
  echo "    Set it in .hm-dev-env and restart this script."
fi

# --- Launch the Elixir backend (the harmont_web umbrella endpoint) ---
# This is the whole backend now: harmont_web serves the REST API, GitHub
# webhooks, the agent WebSocket, and SSE logs. DEV_BIND_ALL=1 makes the endpoint
# bind all interfaces (config/dev.exs) so the laptop reaches it over Tailscale.
echo "→ starting Elixir backend (mix phx.server) on :4000 — logs: $API_LOG"
(
  cd elixir
  DEV_BIND_ALL=1 \
  GOOGLE_OAUTH_CLIENT_ID="$EXISTING_GOOGLE_OAUTH_CLIENT_ID" \
  GOOGLE_OAUTH_CLIENT_SECRET="$EXISTING_GOOGLE_OAUTH_CLIENT_SECRET" \
    mix phx.server 2>&1
) | tee "$API_LOG" | sed -u 's/^/[api] /' &
API_PID=$!

# Wait for API to answer ping before starting the frontend
echo "→ waiting for API at $HARMONT_API_URL/api/v0/ping..."
for _ in $(seq 1 60); do
  if curl -fs "$HARMONT_API_URL/api/v0/ping" >/dev/null 2>&1; then
    echo "  ✓ API is up"
    break
  fi
  sleep 1
done

# --- Launch the frontend dev server (Solid.js / Vite) ---
# The SPA reads the API base URL from VITE_API_URL (frontend/src/api/client.ts);
# `npm run dev` runs the openapi-typescript codegen (predev) then vite.
echo "→ starting frontend on :$FRONTEND_PORT — logs: $APP_LOG"
(
  cd frontend
  VITE_API_URL="$HARMONT_API_URL" npm run dev -- --port "$FRONTEND_PORT" --host 2>&1
) | tee "$APP_LOG" | sed -u 's/^/[app] /' &
APP_PID=$!

echo ""
echo "Dev stack up:"
echo "  API:      $HARMONT_API_URL"
echo "  Frontend: http://localhost:$FRONTEND_PORT   (bound on all interfaces)"
echo "  Logs:     $API_LOG  $APP_LOG"
echo ""
echo "First-time only, in another terminal:  make dev-seed"
echo "Ctrl+C to stop."

wait

#!/usr/bin/env bash
# Run the Freestyle Elixir integration suite against the LIVE api.freestyle.sh.
#
# Sources the API key from Google Secret Manager unless FREESTYLE_API_KEY is
# already exported. Requires gcloud auth'd to your project (set GCP_PROJECT)
# with access to the secret named by FREESTYLE_SECRET_NAME (default
# freestyle-api-key).
#
# Usage:
#   ./scripts/integration-test.sh                  # fetch key, run full suite
#   FREESTYLE_API_KEY=fs_... ./scripts/integration-test.sh   # use an explicit key
#   GCP_PROJECT=other ./scripts/integration-test.sh          # override project
#   ./scripts/integration-test.sh --trace                    # pass extra mix args
#
# The suite creates and then deletes real test repositories and identities on
# the account behind the key; each workflow cleans up after itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${FREESTYLE_API_KEY:-}" ]; then
  GCP_PROJECT="${GCP_PROJECT:?set GCP_PROJECT to your Google Cloud project}"
  FREESTYLE_SECRET_NAME="${FREESTYLE_SECRET_NAME:-freestyle-api-key}"
  echo "==> FREESTYLE_API_KEY unset; fetching from Secret Manager (project=$GCP_PROJECT)" >&2
  FREESTYLE_API_KEY="$(gcloud secrets versions access latest \
    --secret="$FREESTYLE_SECRET_NAME" \
    --project="$GCP_PROJECT")"
  export FREESTYLE_API_KEY
fi
: "${FREESTYLE_API_KEY:?need FREESTYLE_API_KEY (export it, or gcloud auth to the project)}"

cd "$PROJECT_DIR"
exec mix test --only integration "$@"

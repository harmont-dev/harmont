defmodule HarmontApi do
  @moduledoc """
  The user-facing REST authentication edge for Harmont.

  `HarmontApi` is a thin Phoenix layer (router + OpenApiSpex spec +
  controllers + plugs + external-IO adapters) over the pure `harmont_core`
  contexts. It owns no domain logic; it wires HTTP to `Harmont.Accounts`,
  `Harmont.Orgs`, and friends, rendering the stable error envelope from the
  `Harmont.Error` catalog.

  The HTTP surface is served by `harmont_web`'s single Phoenix endpoint, which
  mounts `HarmontApi.Router` at `/api/v0`. There is no separate listener.
  """
end

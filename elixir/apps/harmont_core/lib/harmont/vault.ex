defmodule Harmont.Vault do
  @moduledoc """
  Cloak vault for field-level encryption at rest (Bitbucket OAuth token bundles).
  The key is loaded at boot from application env (`:harmont_core, Harmont.Vault`),
  populated by config: a fixed dev/test key, and `HARMONT_CLOAK_KEY` in prod
  (runtime.exs). AES-256-GCM.
  """
  use Cloak.Vault, otp_app: :harmont_core
end

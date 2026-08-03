defmodule Harmont.Vcs.Encrypted.Binary do
  @moduledoc "Cloak-encrypted binary column type, backed by Harmont.Vault."
  use Cloak.Ecto.Binary, vault: Harmont.Vault
end

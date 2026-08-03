defmodule Harmont.Vcs.Installation do
  @moduledoc """
  Provider-agnostic installation/workspace row (`vcs_installation`). Replaces the
  GitHub-only `Harmont.Github.Installation`. `external_id` is the provider's id
  as a string (GitHub installation id, Bitbucket workspace slug); `provider`
  discriminates. `account_name`/`account_kind` are the provider-neutral display
  identity (GitHub login/account-type, Bitbucket workspace slug/"workspace");
  vendor-specific install metadata lives in the `provider_data` jsonb sidecar.
  `credentials_encrypted` is the credential store: a Cloak-encrypted
  bundle for providers that persist creds (Bitbucket OAuth access/refresh tokens);
  GitHub mints JIT tokens and leaves it nil. Read/write it only through
  `Harmont.Vcs.put_credentials/3` and `Harmont.Vcs.get_credentials/2` — never
  store credentials in the clear.

  Bigserial primary key — overrides the app-wide binary_id default.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vcs_installation" do
    field(:provider, :string)
    field(:external_id, :string)
    field(:organization_id, :binary_id)
    field(:account_name, :string)
    field(:account_kind, :string)
    field(:provider_data, :map, default: %{})
    field(:credentials_encrypted, Harmont.Vcs.Encrypted.Binary)
    field(:suspended_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc "Pure predicate: active when neither tombstone is set."
  def active?(%__MODULE__{deleted_at: nil, suspended_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Changeset for an installation's webhook-driven identity."
  def upsert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:provider, :external_id, :account_name, :account_kind, :provider_data])
    |> validate_required([:provider, :external_id, :account_name, :account_kind])
    |> unique_constraint([:provider, :external_id],
      name: :unique_vcs_installation_provider_external
    )
  end
end

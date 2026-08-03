defmodule Freestyle.Types.Identity do
  @moduledoc "Identity, token, and permission payload schemas."

  defmodule Identity do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            id: String.t(),
            managed: boolean() | nil,
            public_key: String.t() | nil
          }

    embedded_schema do
      field(:id, :string)
      field(:managed, :boolean)
      field(:public_key, :string)
    end
  end

  defmodule IdentityToken do
    use Freestyle.Schema
    @typedoc "`value` is present only on creation; nil on subsequent reads."
    @type t :: %__MODULE__{id: String.t(), value: String.t() | nil}

    embedded_schema do
      field(:id, :string)
      field(:value, :string)
    end
  end

  defmodule GitPermission do
    use Freestyle.Schema
    @type t :: %__MODULE__{repo: String.t(), permission: String.t()}

    embedded_schema do
      field(:repo, :string)
      field(:permission, :string)
    end

    @doc "Decode from both the single-permission and list-item shapes."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      repo = json["repo"] || json["id"]
      perm = json["accessLevel"] || json["permissions"] || json["permission"]
      {:ok, %__MODULE__{repo: repo, permission: perm}}
    end
  end

  defmodule VmPermission do
    use Freestyle.Schema
    @type t :: %__MODULE__{vm_id: String.t(), allowed_users: [String.t()] | nil}

    embedded_schema do
      field(:vm_id, :string)
      field(:allowed_users, {:array, :string})
    end
  end

  defmodule GrantGitPermissionOpts do
    use Freestyle.Schema
    @type t :: %__MODULE__{permission: String.t()}

    embedded_schema do
      field(:permission, :string)
    end
  end

  defmodule GrantVmPermissionOpts do
    use Freestyle.Schema
    @type t :: %__MODULE__{allowed_users: [String.t()] | nil}

    embedded_schema do
      field(:allowed_users, {:array, :string})
    end
  end
end

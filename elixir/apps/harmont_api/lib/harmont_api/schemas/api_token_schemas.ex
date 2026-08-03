defmodule HarmontApi.Schemas.ApiToken do
  @moduledoc "A personal API key as returned to the owning user (never the secret)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiToken",
    description: "A personal API key. The secret is returned only once, at creation.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Stable key id."},
      description: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Human label for the key."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the key was created."
      },
      expires_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the key expires, or null if it never expires."
      },
      last_used_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the key was last used to authenticate, if ever."
      }
    },
    required: [:id, :created_at]
  })
end

defmodule HarmontApi.Schemas.ApiTokenListResponse do
  @moduledoc "Response for `GET /api/v0/user/api-tokens`."
  require OpenApiSpex

  alias HarmontApi.Schemas.ApiToken

  OpenApiSpex.schema(%{
    title: "ApiTokenListResponse",
    description: "Every personal API key belonging to the current user.",
    type: :object,
    properties: %{
      api_tokens: %OpenApiSpex.Schema{
        type: :array,
        items: ApiToken,
        description: "The user's personal API keys."
      }
    },
    required: [:api_tokens]
  })
end

defmodule HarmontApi.Schemas.ApiTokenCreateRequest do
  @moduledoc "Request body for `POST /api/v0/user/api-tokens`."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiTokenCreateRequest",
    description: "Creates a personal API key.",
    type: :object,
    properties: %{
      description: %OpenApiSpex.Schema{
        type: :string,
        description: "Human label for the key."
      },
      expires_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "Optional expiry; null or omitted means the key never expires."
      }
    },
    required: [:description],
    example: %{"description" => "Laptop CLI", "expires_at" => nil}
  })
end

defmodule HarmontApi.Schemas.ApiTokenCreateResponse do
  @moduledoc "Response for `POST /api/v0/user/api-tokens`: the new key + its one-time secret."
  require OpenApiSpex

  alias HarmontApi.Schemas.ApiToken

  OpenApiSpex.schema(%{
    title: "ApiTokenCreateResponse",
    description: "The created key and its raw secret. The secret is shown only here, once.",
    type: :object,
    properties: %{
      token: %OpenApiSpex.Schema{
        type: :string,
        description: "The raw API key secret. Store it now; it is never shown again."
      },
      api_token: ApiToken
    },
    required: [:token, :api_token]
  })
end

defmodule HarmontApi.Schemas.BitbucketOAuthUrlResponse do
  @moduledoc "The Bitbucket authorize URL the SPA should open."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BitbucketOAuthUrlResponse",
    description: "The Bitbucket authorize URL the SPA should open.",
    type: :object,
    properties: %{
      url: %OpenApiSpex.Schema{type: :string, description: "Bitbucket OAuth authorize URL."}
    },
    required: [:url],
    example: %{
      "url" => "https://bitbucket.org/site/oauth2/authorize?client_id=...&response_type=code"
    }
  })
end

defmodule HarmontApi.Schemas.ConnectBitbucketRequest do
  @moduledoc "OAuth callback payload from the SPA."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ConnectBitbucketRequest",
    description: "OAuth callback payload from the SPA.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "Authorization code from Bitbucket."
      },
      state: %OpenApiSpex.Schema{
        type: :string,
        description:
          "The signed CSRF state nonce echoed back by Bitbucket on the callback. " <>
            "Issued by the `oauth-url` endpoint and bound to the authenticated user."
      }
    },
    required: [:code, :state],
    example: %{"code" => "abc123", "state" => "SFMyNTY..."}
  })
end

defmodule HarmontApi.Schemas.ConnectBitbucketResponse do
  @moduledoc "Result of a Bitbucket OAuth connect."
  require OpenApiSpex

  alias HarmontApi.Schemas.BitbucketWorkspace

  OpenApiSpex.schema(%{
    title: "ConnectBitbucketResponse",
    description: "The workspaces connected by the OAuth callback, plus the org slug.",
    type: :object,
    properties: %{
      workspaces: %OpenApiSpex.Schema{
        type: :array,
        items: BitbucketWorkspace,
        description: "The connected workspaces."
      },
      org: %OpenApiSpex.Schema{
        type: :string,
        description:
          "The org slug the workspaces were connected to, recovered from the " <>
            "signed OAuth state. The SPA navigates to this org's repos view."
      }
    },
    required: [:workspaces, :org],
    example: %{"workspaces" => [%{"slug" => "acme", "name" => "Acme Inc"}], "org" => "acme"}
  })
end

defmodule HarmontApi.Schemas.BitbucketWorkspace do
  @moduledoc "A connected Bitbucket workspace."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BitbucketWorkspace",
    description: "A connected Bitbucket workspace.",
    type: :object,
    properties: %{
      slug: %OpenApiSpex.Schema{type: :string, description: "Unique workspace slug."},
      name: %OpenApiSpex.Schema{type: :string, description: "Display name of the workspace."}
    },
    required: [:slug],
    example: %{"slug" => "acme", "name" => "Acme Inc"}
  })
end

defmodule HarmontApi.Schemas.BitbucketWorkspaceList do
  @moduledoc "List of connected Bitbucket workspaces."
  require OpenApiSpex

  alias HarmontApi.Schemas.BitbucketWorkspace

  OpenApiSpex.schema(%{
    title: "BitbucketWorkspaceList",
    description: "All Bitbucket workspaces the connected OAuth token can access.",
    type: :object,
    properties: %{
      workspaces: %OpenApiSpex.Schema{
        type: :array,
        items: BitbucketWorkspace,
        description: "The connected workspaces."
      }
    },
    required: [:workspaces],
    example: %{"workspaces" => [%{"slug" => "acme", "name" => "Acme Inc"}]}
  })
end

defmodule HarmontApi.Schemas.BitbucketRepo do
  @moduledoc "A synced Bitbucket repo."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BitbucketRepo",
    description: "A Bitbucket repository visible to the connected OAuth token.",
    type: :object,
    properties: %{
      full_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Workspace-qualified repo name, e.g. `acme/widget`."
      },
      name: %OpenApiSpex.Schema{type: :string, description: "Repository slug."},
      default_branch: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Default branch name."
      },
      private: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Whether the repository is private."
      },
      clone_url: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "HTTPS clone URL."
      }
    },
    required: [:full_name, :name],
    example: %{
      "full_name" => "acme/widget",
      "name" => "widget",
      "default_branch" => "main",
      "private" => true,
      "clone_url" => "https://bitbucket.org/acme/widget.git"
    }
  })
end

defmodule HarmontApi.Schemas.BitbucketRepoList do
  @moduledoc "List of synced Bitbucket repos for a workspace."
  require OpenApiSpex

  alias HarmontApi.Schemas.BitbucketRepo

  OpenApiSpex.schema(%{
    title: "BitbucketRepoList",
    description: "Bitbucket repositories visible within the requested workspace.",
    type: :object,
    properties: %{
      repos: %OpenApiSpex.Schema{
        type: :array,
        items: BitbucketRepo,
        description: "The repositories."
      }
    },
    required: [:repos],
    example: %{"repos" => []}
  })
end

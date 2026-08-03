defmodule HarmontApi.Schemas.OrgMember do
  @moduledoc "A member of an organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OrgMember",
    type: :object,
    properties: %{
      user_uuid: %OpenApiSpex.Schema{type: :string, format: :uuid},
      email: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string, nullable: true},
      role: %OpenApiSpex.Schema{type: :string, enum: ["owner", "admin", "member"]}
    },
    required: [:user_uuid, :email, :role]
  })
end

defmodule HarmontApi.Schemas.OrgMemberList do
  @moduledoc "All members of an organization."
  require OpenApiSpex
  alias HarmontApi.Schemas.OrgMember

  OpenApiSpex.schema(%{
    title: "OrgMemberList",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{type: :array, items: OrgMember}
    },
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.UpdateMemberRoleRequest do
  @moduledoc "Change a member's role."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateMemberRoleRequest",
    type: :object,
    properties: %{
      role: %OpenApiSpex.Schema{type: :string, enum: ["owner", "admin", "member"]}
    },
    required: [:role]
  })
end

defmodule HarmontApi.Schemas.CreateInviteRequest do
  @moduledoc "Invite an email to an organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateInviteRequest",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string},
      role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "member"]}
    },
    required: [:email, :role]
  })
end

defmodule HarmontApi.Schemas.Invite do
  @moduledoc "A pending organization invite."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Invite",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      email: %OpenApiSpex.Schema{type: :string},
      role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "member"]},
      expires_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      token: %OpenApiSpex.Schema{type: :string, nullable: true}
    },
    required: [:id, :email, :role, :expires_at]
  })
end

defmodule HarmontApi.Schemas.InviteList do
  @moduledoc "Pending invites for an organization."
  require OpenApiSpex
  alias HarmontApi.Schemas.Invite

  OpenApiSpex.schema(%{
    title: "InviteList",
    type: :object,
    properties: %{data: %OpenApiSpex.Schema{type: :array, items: Invite}},
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.AcceptInviteRequest do
  @moduledoc "Accept an invite by token."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AcceptInviteRequest",
    type: :object,
    properties: %{token: %OpenApiSpex.Schema{type: :string}},
    required: [:token]
  })
end

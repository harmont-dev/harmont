defmodule Freestyle.Api.Identity do
  @moduledoc "Identity, token, and permission endpoints."

  alias Freestyle.{Client, Error, Page, Pagination, Request, Types}

  alias Freestyle.Types.Identity.{
    GitPermission,
    GrantGitPermissionOpts,
    GrantVmPermissionOpts,
    Identity,
    IdentityToken,
    VmPermission
  }

  defp base, do: "/identity/v1/identities"
  defp ident(iid), do: "#{base()}/#{iid}"

  @doc "GET /identity/v1/identities — one page."
  @spec list_identities(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Identity.t())} | {:error, Error.t()}
  def list_identities(client, params \\ %{}) do
    Request.get(
      client,
      base(),
      [limit: Map.get(params, :limit, 50), offset: Map.get(params, :offset, 0)],
      &Page.decode(&1, fn item -> Identity.decode(item) end),
      "freestyle.identity.list_identities"
    )
  end

  @doc "Lazy stream over all identities."
  @spec stream_identities(Client.t()) :: Enumerable.t()
  def stream_identities(client), do: Pagination.stream(fn p -> list_identities(client, p) end)

  @doc "POST /identity/v1/identities (empty body)."
  @spec create_identity(Client.t()) :: {:ok, Identity.t()} | {:error, Error.t()}
  def create_identity(client) do
    Request.post(client, base(), %{}, &Identity.decode/1, "freestyle.identity.create_identity")
  end

  @doc "DELETE /identity/v1/identities/{id}."
  @spec delete_identity(Client.t(), Types.identity_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_identity(client, iid) do
    Request.delete(client, ident(iid), [], "freestyle.identity.delete_identity")
  end

  @doc "GET tokens (unwraps `{tokens:[...]}`)."
  @spec list_tokens(Client.t(), Types.identity_id()) ::
          {:ok, [IdentityToken.t()]} | {:error, Error.t()}
  def list_tokens(client, iid) do
    Request.get(
      client,
      ident(iid) <> "/tokens",
      [],
      fn body -> IdentityToken.decode_list(body["tokens"] || []) end,
      "freestyle.identity.list_tokens"
    )
  end

  @doc "POST a token (empty body); `value` is only present in this response."
  @spec create_token(Client.t(), Types.identity_id()) ::
          {:ok, IdentityToken.t()} | {:error, Error.t()}
  def create_token(client, iid) do
    Request.post(
      client,
      ident(iid) <> "/tokens",
      %{},
      &IdentityToken.decode/1,
      "freestyle.identity.create_token"
    )
  end

  @doc "DELETE a token."
  @spec revoke_token(Client.t(), Types.identity_id(), Types.token_id()) ::
          {:ok, :ok} | {:error, Error.t()}
  def revoke_token(client, iid, tid) do
    Request.delete(client, ident(iid) <> "/tokens/#{tid}", [], "freestyle.identity.revoke_token")
  end

  @doc "GET git permissions (unwraps `{repositories:[...]}`)."
  @spec list_git_permissions(Client.t(), Types.identity_id()) ::
          {:ok, [GitPermission.t()]} | {:error, Error.t()}
  def list_git_permissions(client, iid) do
    Request.get(
      client,
      ident(iid) <> "/permissions/git",
      [],
      fn body -> GitPermission.decode_list(body["repositories"] || []) end,
      "freestyle.identity.list_git_permissions"
    )
  end

  @doc "POST a git permission grant."
  @spec grant_git_permission(
          Client.t(),
          Types.identity_id(),
          Types.repo_id(),
          GrantGitPermissionOpts.t()
        ) ::
          {:ok, :ok} | {:error, Error.t()}
  def grant_git_permission(client, iid, rid, %GrantGitPermissionOpts{} = opts) do
    Request.post(
      client,
      ident(iid) <> "/permissions/git/#{rid}",
      GrantGitPermissionOpts.encode(opts),
      fn _ -> {:ok, :ok} end,
      "freestyle.identity.grant_git_permission"
    )
  end

  @doc "GET a specific git permission."
  @spec get_git_permission(Client.t(), Types.identity_id(), Types.repo_id()) ::
          {:ok, GitPermission.t()} | {:error, Error.t()}
  def get_git_permission(client, iid, rid) do
    Request.get(
      client,
      ident(iid) <> "/permissions/git/#{rid}",
      [],
      &GitPermission.decode/1,
      "freestyle.identity.get_git_permission"
    )
  end

  @doc "PUT (update) a git permission."
  @spec update_git_permission(
          Client.t(),
          Types.identity_id(),
          Types.repo_id(),
          GrantGitPermissionOpts.t()
        ) ::
          {:ok, :ok} | {:error, Error.t()}
  def update_git_permission(client, iid, rid, %GrantGitPermissionOpts{} = opts) do
    Request.put(
      client,
      ident(iid) <> "/permissions/git/#{rid}",
      GrantGitPermissionOpts.encode(opts),
      fn _ -> {:ok, :ok} end,
      "freestyle.identity.update_git_permission"
    )
  end

  @doc "DELETE a git permission."
  @spec revoke_git_permission(Client.t(), Types.identity_id(), Types.repo_id()) ::
          {:ok, :ok} | {:error, Error.t()}
  def revoke_git_permission(client, iid, rid) do
    Request.delete(
      client,
      ident(iid) <> "/permissions/git/#{rid}",
      [],
      "freestyle.identity.revoke_git_permission"
    )
  end

  @doc "GET VM permissions."
  @spec list_vm_permissions(Client.t(), Types.identity_id()) ::
          {:ok, [VmPermission.t()]} | {:error, Error.t()}
  def list_vm_permissions(client, iid) do
    Request.get(
      client,
      ident(iid) <> "/permissions/vm",
      [],
      fn body -> VmPermission.decode_list(List.wrap(body)) end,
      "freestyle.identity.list_vm_permissions"
    )
  end

  @doc "POST a VM permission grant."
  @spec grant_vm_permission(
          Client.t(),
          Types.identity_id(),
          Types.vm_id(),
          GrantVmPermissionOpts.t()
        ) ::
          {:ok, :ok} | {:error, Error.t()}
  def grant_vm_permission(client, iid, vid, %GrantVmPermissionOpts{} = opts) do
    Request.post(
      client,
      ident(iid) <> "/permissions/vm/#{vid}",
      GrantVmPermissionOpts.encode(opts),
      fn _ -> {:ok, :ok} end,
      "freestyle.identity.grant_vm_permission"
    )
  end

  @doc "PUT (update) a VM permission."
  @spec update_vm_permission(
          Client.t(),
          Types.identity_id(),
          Types.vm_id(),
          GrantVmPermissionOpts.t()
        ) ::
          {:ok, :ok} | {:error, Error.t()}
  def update_vm_permission(client, iid, vid, %GrantVmPermissionOpts{} = opts) do
    Request.put(
      client,
      ident(iid) <> "/permissions/vm/#{vid}",
      GrantVmPermissionOpts.encode(opts),
      fn _ -> {:ok, :ok} end,
      "freestyle.identity.update_vm_permission"
    )
  end

  @doc "DELETE a VM permission."
  @spec revoke_vm_permission(Client.t(), Types.identity_id(), Types.vm_id()) ::
          {:ok, :ok} | {:error, Error.t()}
  def revoke_vm_permission(client, iid, vid) do
    Request.delete(
      client,
      ident(iid) <> "/permissions/vm/#{vid}",
      [],
      "freestyle.identity.revoke_vm_permission"
    )
  end
end

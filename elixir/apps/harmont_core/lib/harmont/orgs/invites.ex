defmodule Harmont.Orgs.Invites do
  @moduledoc """
  Organization invitations.

  An invite carries a random token sent to the invitee; only its SHA-256 hash
  is stored (same discipline as API tokens). Accepting an invite — when the
  accepting user's email matches and the invite is unexpired/unaccepted — adds
  them as a member and stamps `accepted_at`, atomically.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Orgs
  alias Harmont.Orgs.Invite
  alias Harmont.Token

  # Invites are valid for 7 days.
  @ttl_seconds 7 * 24 * 3600

  @doc """
  Creates an invite for `email` to join `org` as `role`. Returns the persisted
  invite plus the raw token (shown once; never recoverable).
  """
  @spec create_invite(Orgs.Organization.t(), term(), String.t(), atom(), module()) ::
          {:ok, %{invite: Invite.t(), token: String.t()}} | {:error, Ecto.Changeset.t()}
  def create_invite(org, inviter, email, role, repo) do
    token = Token.generate()
    now = DateTime.utc_now()

    attrs = %{
      organization_id: org.id,
      invited_by_user_id: inviter.id,
      email: email,
      role: role,
      token_hash: Token.hash(token),
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    case repo.insert(Invite.changeset(%Invite{}, attrs)) do
      {:ok, invite} -> {:ok, %{invite: invite, token: token}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Lists pending (unaccepted) invites for `org`, newest first."
  @spec list_pending(Orgs.Organization.t(), module()) :: [Invite.t()]
  def list_pending(org, repo) do
    repo.all(
      from(i in Invite,
        where: i.organization_id == ^org.id and is_nil(i.accepted_at),
        order_by: [desc: i.inserted_at]
      )
    )
  end

  @doc "Revokes (deletes) a pending invite by id within `org`."
  @spec revoke(Orgs.Organization.t(), String.t(), module()) ::
          :ok | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(org, invite_id, repo) do
    case repo.get_by(Invite, id: invite_id, organization_id: org.id) do
      nil ->
        {:error, :not_found}

      invite ->
        case repo.delete(invite) do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end
    end
  end

  @doc """
  Accepts the invite identified by raw `token` for `user` at time `now`.

  Validates: token exists, not yet accepted, not expired, and the user's email
  matches the invite. On success, adds the membership and stamps `accepted_at`
  in one transaction, returning the joined org.
  """
  @spec accept_invite(term(), String.t(), DateTime.t(), module()) ::
          {:ok, Orgs.Organization.t()}
          | {:error,
             :not_found | :already_accepted | :expired | :email_mismatch | :already_member}
  def accept_invite(user, token, now, repo) do
    with {:ok, invite} <- fetch_by_token(token, repo),
         :ok <- check_unaccepted(invite),
         :ok <- check_unexpired(invite, now),
         :ok <- check_email(invite, user) do
      org = repo.get!(Orgs.Organization, invite.organization_id)
      repo.transaction(fn -> do_accept(org, user, invite, now, repo) end)
    end
  end

  defp do_accept(org, user, invite, now, repo) do
    case Orgs.add_member(org, user, invite.role, repo) do
      {:ok, _} -> :ok
      {:error, _changeset} -> repo.rollback(:already_member)
    end

    case invite |> Invite.changeset(%{accepted_at: now}) |> repo.update() do
      {:ok, _} -> :ok
      {:error, changeset} -> repo.rollback(changeset)
    end

    org
  end

  defp fetch_by_token(token, repo) do
    case repo.get_by(Invite, token_hash: Token.hash(token)) do
      nil -> {:error, :not_found}
      invite -> {:ok, invite}
    end
  end

  defp check_unaccepted(%Invite{accepted_at: nil}), do: :ok
  defp check_unaccepted(_), do: {:error, :already_accepted}

  defp check_unexpired(%Invite{expires_at: exp}, now) do
    if DateTime.compare(now, exp) == :gt, do: {:error, :expired}, else: :ok
  end

  defp check_email(%Invite{email: email}, user) do
    if String.downcase(user.email) == String.downcase(email),
      do: :ok,
      else: {:error, :email_mismatch}
  end
end

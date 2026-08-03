defmodule Harmont.Orgs do
  @moduledoc """
  Context module for the Orgs domain.

  Covers organization CRUD, membership management, tenancy enforcement
  (`require_member`, `fetch_org_scoped`), and sign-up attempt recording.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.OrgMember
  alias Harmont.Orgs.SignupAttempt
  alias Harmont.Orgs.Slug

  # ---------------------------------------------------------------------------
  # Organization CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new organization with the given `attrs` (`:name`, `:slug`, `:url`).
  """
  @spec create_org(map(), module()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def create_org(attrs, repo) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Persists `customer_id` as the org's Stripe customer id.

  Called the first time an org starts a Stripe checkout, so subsequent
  checkouts reuse one persistent Stripe Customer. Returns the updated org.
  """
  @spec set_stripe_customer_id(Organization.t(), String.t(), module()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def set_stripe_customer_id(%Organization{} = org, customer_id, repo) do
    org
    |> Organization.changeset(%{stripe_customer_id: customer_id})
    |> repo.update()
  end

  @doc """
  Resolves the org's Stripe customer id, minting one at most once across
  concurrent callers.

  Serializes on the org row with `SELECT ... FOR UPDATE`. Inside the lock we
  re-read the org: if it already carries a `stripe_customer_id` (the winner of
  a concurrent first-checkout got here first), we return that and `create_fun`
  is never called — so a second Stripe Customer is never minted. Otherwise we
  run `create_fun/0` (the external customer-creation call), persist its id, and
  return it.

  `create_fun` must return `{:ok, customer_id}` or `{:error, reason}`. Returns:

    * `{:ok, customer_id}` — an existing id was reused, or a fresh one minted
      and persisted.
    * `{:error, reason}` — `create_fun` failed (the reason is propagated); the
      caller decides whether to proceed without a customer.

  The lock is held across `create_fun`, so keep that call quick — it is a
  single Stripe customer create.
  """
  @spec ensure_stripe_customer_id(
          Organization.t(),
          (-> {:ok, String.t()} | {:error, term()}),
          module()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_stripe_customer_id(%Organization{} = org, create_fun, repo)
      when is_function(create_fun, 0) do
    result =
      repo.transaction(fn ->
        locked =
          repo.one(from(o in Organization, where: o.id == ^org.id, lock: "FOR UPDATE"))

        case locked do
          %Organization{stripe_customer_id: id} when is_binary(id) ->
            {:ok, id}

          %Organization{} = locked_org ->
            mint_and_persist_customer_id(locked_org, create_fun, repo)

          nil ->
            repo.rollback(:org_not_found)
        end
      end)

    case result do
      {:ok, {:ok, id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs inside the FOR UPDATE transaction: mints a fresh customer id via
  # `create_fun`, persists it, and returns it. A failure of either step rolls
  # the transaction back so nothing is persisted.
  defp mint_and_persist_customer_id(%Organization{} = org, create_fun, repo) do
    with {:ok, customer_id} <- create_fun.(),
         {:ok, _updated} <- set_stripe_customer_id(org, customer_id, repo) do
      {:ok, customer_id}
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  # We re-allocate and retry a bounded number of times; a few attempts is ample
  # because each retry walks past the slug the winner just took.
  @create_org_slug_attempts 5

  @doc """
  Creates a team organization and makes `user` its owner, atomically.

  `attrs` must contain `:name`; the slug is derived from the name and made
  unique. The creator is inserted as an `:owner` member in the same
  transaction, so a half-created org (no owner) can never exist.

  A bounded retry loop handles the check-then-insert slug race: if a
  concurrent insert steals the slug between `pick_free_slug` and our own
  insert, we re-pick and retry up to `@create_org_slug_attempts` times.
  On exhaustion or any non-slug changeset error, `{:error, changeset}` is
  returned.
  """
  @spec create_org_with_owner(term(), map(), module()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def create_org_with_owner(user, attrs, repo) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || ""
    url = attrs[:url] || attrs["url"]
    do_create_org_with_owner(user, name, url, repo, @create_org_slug_attempts)
  end

  defp do_create_org_with_owner(user, name, url, repo, attempts_left) do
    slug = Slug.pick_free_slug(Slug.normalize(name), repo)

    case repo.transaction(fn -> create_org_txn(user, name, slug, url, repo) end) do
      {:ok, org} ->
        {:ok, org}

      {:error, cs} when attempts_left > 1 ->
        if slug_unique_error?(cs) do
          do_create_org_with_owner(user, name, url, repo, attempts_left - 1)
        else
          {:error, cs}
        end

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp create_org_txn(user, name, slug, url, repo) do
    with {:ok, org} <- create_org(%{name: name, slug: slug, url: url}, repo),
         {:ok, _} <- add_member(org, user, :owner, repo) do
      org
    else
      {:error, cs} -> repo.rollback(cs)
    end
  end

  defp slug_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:slug, {_msg, kw}} -> Keyword.get(kw, :constraint) == :unique
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # Membership
  # ---------------------------------------------------------------------------

  @doc """
  Adds `user` to `org` with the given `role` (`:admin` or `:member`).
  """
  @spec add_member(Organization.t(), term(), atom(), module()) ::
          {:ok, OrgMember.t()} | {:error, Ecto.Changeset.t()}
  def add_member(org, user, role, repo) do
    %OrgMember{}
    |> OrgMember.changeset(%{organization_id: org.id, user_id: user.id, role: role})
    |> repo.insert()
  end

  @doc """
  Returns `:ok` if `user` is a member of `org`, `{:error, :not_found}` otherwise.

  Service users bypass the membership check entirely, hiding org existence from
  non-members.
  """
  @spec require_member(term(), Organization.t(), module()) :: :ok | {:error, :not_found}
  def require_member(user, org, repo) do
    if Harmont.Accounts.service_user?(user) do
      :ok
    else
      query =
        from(m in OrgMember,
          where: m.organization_id == ^org.id and m.user_id == ^user.id
        )

      if repo.exists?(query), do: :ok, else: {:error, :not_found}
    end
  end

  @doc """
  Lists `org`'s memberships with the associated user preloaded, ordered by
  role name (ascending) then user email. Because role is stored as a string,
  the sort order is alphabetical: admin < member < owner.
  """
  @spec list_members(Organization.t(), module()) :: [OrgMember.t()]
  def list_members(org, repo) do
    query =
      from(m in OrgMember,
        join: u in assoc(m, :user),
        where: m.organization_id == ^org.id,
        order_by: [asc: m.role, asc: u.email],
        preload: [user: u]
      )

    repo.all(query)
  end

  @doc """
  Changes `user`'s role in `org`. Refuses to demote the last `:owner`
  (`{:error, :last_owner}`) so an org can never be left ownerless.
  """
  @spec update_member_role(Organization.t(), term(), atom(), module()) ::
          {:ok, OrgMember.t()} | {:error, :not_found | :last_owner | Ecto.Changeset.t()}
  def update_member_role(org, user, role, repo) do
    with {:ok, member} <- fetch_membership(org, user, repo),
         :ok <- guard_last_owner(org, member, role, repo) do
      member
      |> OrgMember.changeset(%{role: role})
      |> repo.update()
    end
  end

  @doc """
  Removes `user` from `org`. Refuses to remove the last `:owner`
  (`{:error, :last_owner}`).
  """
  @spec remove_member(Organization.t(), term(), module()) ::
          :ok | {:error, :not_found | :last_owner}
  def remove_member(org, user, repo) do
    with {:ok, member} <- fetch_membership(org, user, repo),
         :ok <- guard_last_owner(org, member, :__removed__, repo) do
      {:ok, _} = repo.delete(member)
      :ok
    end
  end

  defp fetch_membership(org, user, repo) do
    case repo.get_by(OrgMember, organization_id: org.id, user_id: user.id) do
      nil -> {:error, :not_found}
      member -> {:ok, member}
    end
  end

  # Block any change that would drop the org's owner count to zero: if `member`
  # is currently the only owner and the new role is not `:owner`, refuse.
  defp guard_last_owner(org, member, new_role, repo) do
    if member.role == :owner and new_role != :owner and owner_count(org, repo) <= 1 do
      {:error, :last_owner}
    else
      :ok
    end
  end

  defp owner_count(org, repo) do
    query =
      from(m in OrgMember,
        where: m.organization_id == ^org.id and m.role == :owner,
        select: count(m.id)
      )

    repo.one(query)
  end

  @doc """
  Returns `{:ok, role}` for `user`'s role in `org`, or `{:error, :not_found}`
  when the user is not a member. Service users resolve to `:owner` so internal
  callers pass every authorization check.
  """
  @spec member_role(term(), Organization.t(), module()) ::
          {:ok, :owner | :admin | :member} | {:error, :not_found}
  def member_role(user, org, repo) do
    if Harmont.Accounts.service_user?(user) do
      {:ok, :owner}
    else
      query =
        from(m in OrgMember,
          where: m.organization_id == ^org.id and m.user_id == ^user.id,
          select: m.role
        )

      case repo.one(query) do
        nil -> {:error, :not_found}
        role -> {:ok, role}
      end
    end
  end

  @doc """
  Resolves `slug` to an organization and checks membership in one operation.

  Returns `{:ok, org}` only when the org exists AND the user is a member (or
  a service user). Returns `{:error, :not_found}` in all other cases — the
  same atom whether the slug is unknown or the user is not a member — so that
  non-members cannot enumerate org slugs.
  """
  @spec fetch_org_scoped(term(), String.t(), module()) ::
          {:ok, Organization.t()} | {:error, :not_found}
  def fetch_org_scoped(user, slug, repo) do
    case repo.get_by(Organization, slug: slug) do
      nil ->
        {:error, :not_found}

      org ->
        case require_member(user, org, repo) do
          :ok -> {:ok, org}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Lists the organizations `user` is a member of.

  Ordered by `inserted_at` then `id` so callers can paginate over a stable
  sequence. Returns `[]` when the user belongs to no organizations.
  """
  @spec list_for_user(term(), module()) :: [Organization.t()]
  def list_for_user(user, repo) do
    repo.all(list_for_user_query(user))
  end

  @doc """
  Returns the `Ecto.Query` backing `list_for_user/2`.

  Exposed so HTTP edges can paginate over the membership query without
  materializing every row. Ordered by `inserted_at` then `id`.
  """
  @spec list_for_user_query(term()) :: Ecto.Query.t()
  def list_for_user_query(user) do
    from(o in Organization,
      join: m in OrgMember,
      on: m.organization_id == o.id,
      where: m.user_id == ^user.id,
      order_by: [asc: o.inserted_at, asc: o.id]
    )
  end

  # ---------------------------------------------------------------------------
  # Sign-up attempts
  # ---------------------------------------------------------------------------

  @doc """
  Records the outcome of a sign-up attempt.
  """
  @spec record_signup_attempt(map(), module()) ::
          {:ok, SignupAttempt.t()} | {:error, Ecto.Changeset.t()}
  def record_signup_attempt(attrs, repo) do
    %SignupAttempt{}
    |> SignupAttempt.changeset(attrs)
    |> repo.insert()
  end
end

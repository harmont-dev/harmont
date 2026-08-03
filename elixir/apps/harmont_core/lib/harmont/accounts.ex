defmodule Harmont.Accounts do
  @moduledoc """
  Context module for the Accounts domain.

  Covers session-token lifecycle, bearer validation, OAuth identity upsert,
  service-user management, and email/magic-link token persistence.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks. No OAuth HTTP, no email
  delivery, no wax HTTP options — those belong in Plan 3 edges.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Accounts.ApiToken
  alias Harmont.Accounts.CliPasteCode
  alias Harmont.Accounts.CliTransferCode
  alias Harmont.Accounts.EmailVerification
  alias Harmont.Accounts.MagicLink
  alias Harmont.Accounts.User
  alias Harmont.Error
  alias Harmont.Orgs
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.Slug, as: OrgSlug
  alias Harmont.Settings
  alias Harmont.Token

  @service_user_email "service@harmont.local"

  # ---------------------------------------------------------------------------
  # Session tokens
  # ---------------------------------------------------------------------------

  @doc """
  Creates a session token for `user_id`.

  Returns `{raw, %ApiToken{}}` where `raw` is the plaintext token to hand to
  the client and `%ApiToken{}` is the persisted record (token stored as hash).
  The token expires 30 days from `now`.
  """
  @spec create_session_token(binary(), DateTime.t(), module()) :: {String.t(), ApiToken.t()}
  def create_session_token(user_id, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    raw = Token.generate()
    expires_at = DateTime.add(now, 30 * 24 * 60 * 60, :second)

    {:ok, api_token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: Token.hash(raw),
        token_type: :session,
        expires_at: expires_at,
        user_id: user_id
      })
      |> repo.insert()

    {raw, api_token}
  end

  # The personal-token prefix makes keys identifiable in logs and to secret
  # scanners. We hash and store the full prefixed string, and the client sends
  # it back verbatim as the bearer token.
  @personal_token_prefix "hm_"

  @doc """
  Creates a personal API token for `user_id`.

  Returns `{raw, %ApiToken{}}` where `raw` is the prefixed plaintext token to
  show the user exactly once. `expires_at` may be `nil` (never expires).
  """
  @spec create_personal_token(
          binary(),
          String.t() | nil,
          DateTime.t() | nil,
          DateTime.t(),
          module()
        ) :: {String.t(), ApiToken.t()}
  def create_personal_token(
        user_id,
        description,
        expires_at \\ nil,
        _now \\ DateTime.utc_now(),
        repo \\ Harmont.Repo
      ) do
    raw = @personal_token_prefix <> Token.generate()

    {:ok, api_token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: Token.hash(raw),
        token_type: :personal,
        description: description,
        expires_at: expires_at,
        user_id: user_id
      })
      |> repo.insert()

    {raw, api_token}
  end

  @doc """
  Lists `user_id`'s personal API tokens, newest first.

  Session tokens are excluded. The `token_hash` is present on the structs but
  callers (the API edge) must never render it.
  """
  @spec list_personal_tokens(binary(), module()) :: [ApiToken.t()]
  def list_personal_tokens(user_id, repo \\ Harmont.Repo) do
    from(t in ApiToken,
      where: t.user_id == ^user_id and t.token_type == :personal,
      order_by: [desc: t.inserted_at, desc: t.id]
    )
    |> repo.all()
  end

  @doc """
  Revokes one of `user_id`'s personal tokens by id.

  Scoped to the owner and to `:personal` tokens: another user's token, a
  session token, or a malformed id all report `{:error, :not_found}` (never
  leaking existence, never raising on a bad id).
  """
  @spec revoke_personal_token(String.t(), binary(), module()) ::
          {:ok, ApiToken.t()} | {:error, :not_found}
  def revoke_personal_token(id, user_id, repo \\ Harmont.Repo) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> do_revoke_personal_token(uuid, user_id, repo)
      :error -> {:error, :not_found}
    end
  end

  defp do_revoke_personal_token(uuid, user_id, repo) do
    case repo.get_by(ApiToken, id: uuid, user_id: user_id, token_type: :personal) do
      nil -> {:error, :not_found}
      token -> with {:ok, _} <- repo.delete(token), do: {:ok, token}
    end
  end

  @doc """
  Revokes a raw bearer token by deleting its `ApiToken` row.

  Hashes `raw` and deletes the matching row (if any). Idempotent: returns `:ok`
  whether or not a row existed, so logging out an already-expired or unknown
  token is never an error.
  """
  @spec revoke_token(String.t(), module()) :: :ok
  def revoke_token(raw, repo \\ Harmont.Repo) do
    hash = Token.hash(raw)

    case repo.get_by(ApiToken, token_hash: hash) do
      nil -> :ok
      token -> with {:ok, _} <- repo.delete(token), do: :ok
    end
  end

  @doc """
  Resolves the slug of `user`'s personal organization.

  Returns the slug string, or `nil` when the user has no personal org or the
  referenced org no longer exists.
  """
  @spec personal_org_slug(User.t(), module()) :: String.t() | nil
  def personal_org_slug(user, repo \\ Harmont.Repo)
  def personal_org_slug(%User{personal_org_id: nil}, _repo), do: nil

  def personal_org_slug(%User{personal_org_id: org_id}, repo) do
    case repo.get(Organization, org_id) do
      nil -> nil
      org -> org.slug
    end
  end

  @doc """
  Validates a raw bearer token.

  Hashes `raw`, looks up the `ApiToken`, checks expiry
  (`expires_at == nil OR now < expires_at`), then loads and returns the
  owning user.

  Returns `{:ok, %User{}}` or `{:error, :invalid}`.
  """
  @spec validate_bearer(String.t(), DateTime.t(), module()) ::
          {:ok, User.t()} | {:error, :invalid}
  def validate_bearer(raw, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    hash = Token.hash(raw)

    case repo.get_by(ApiToken, token_hash: hash) do
      nil -> {:error, :invalid}
      token -> check_token_expiry_and_load_user(token, now, repo)
    end
  end

  # Avoid a write on every authed request: only advance last_used_at when it's
  # unset or older than this many seconds.
  @last_used_throttle_seconds 60

  defp check_token_expiry_and_load_user(%ApiToken{} = token, now, repo) do
    expired? = token.expires_at != nil and DateTime.compare(now, token.expires_at) != :lt

    if expired? do
      {:error, :invalid}
    else
      maybe_touch_last_used(token, now, repo)
      load_user_or_invalid(token.user_id, repo)
    end
  end

  defp maybe_touch_last_used(%ApiToken{id: id, last_used_at: last}, now, repo) do
    stale? = is_nil(last) or DateTime.diff(now, last, :second) >= @last_used_throttle_seconds

    if stale? do
      from(t in ApiToken, where: t.id == ^id)
      |> repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  defp load_user_or_invalid(user_id, repo) do
    case repo.get(User, user_id) do
      nil -> {:error, :invalid}
      user -> {:ok, user}
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth / identity upsert (race-safe)
  # ---------------------------------------------------------------------------

  @doc """
  Returns `:ok` when the platform can accept another signup, or
  `{:error, :signup_cap_reached}` when the total user count has reached the
  runtime `signup_cap` setting.

  An unset cap (`Harmont.Settings.signup_cap/1` is `nil`) means unlimited.
  Enforced on the new-user insert path; existing-user logins are never gated.
  The count is unfiltered (`repo.aggregate(User, :count)`), so any seeded
  service/system user would also count toward the cap.
  """
  @spec signup_capacity(module()) :: :ok | {:error, :signup_cap_reached}
  def signup_capacity(repo \\ Harmont.Repo) do
    case Settings.signup_cap(repo) do
      nil ->
        :ok

      cap ->
        if repo.aggregate(User, :count) >= cap do
          {:error, :signup_cap_reached}
        else
          :ok
        end
    end
  end

  @doc """
  Finds or creates a user from an OAuth/passkey identity.

  `identity` must contain: `:provider` (`:google`, `:github`, or `:passkey`),
  `:email`, `:name`. For Google/GitHub: `:provider_id`.

  Resolution order:
  1. Find by provider-specific ID field (`google_id` / `github_id`).
  2. Find by email and link the provider ID.
  3. Insert new user + personal org + admin membership in one transaction.
     On unique-email violation, retry lookup once; if still missing, re-raise.

  Returns `{:ok, %User{}, created?}` where `created?` is `true` on new
  insertion and `false` on lookup.
  """
  @spec find_or_create_user_from_identity(map(), DateTime.t(), module()) ::
          {:ok, User.t(), boolean()} | {:error, any()}
  def find_or_create_user_from_identity(
        %{provider: provider, email: email, name: name} = identity,
        _now \\ DateTime.utc_now(),
        repo \\ Harmont.Repo
      ) do
    provider_id = Map.get(identity, :provider_id)
    normalized_email = email |> String.trim() |> String.downcase()
    existing_by_provider = find_by_provider_id(provider, provider_id, repo)

    if existing_by_provider != nil do
      {:ok, existing_by_provider, false}
    else
      find_or_insert_by_email(name, normalized_email, provider, provider_id, repo)
    end
  end

  defp find_or_insert_by_email(name, email, provider, provider_id, repo) do
    case repo.get_by(User, email: email) do
      %User{} = existing ->
        {:ok, linked} = link_provider_id(existing, provider, provider_id, repo)
        {:ok, linked, false}

      nil ->
        # Note: the count-then-insert is intentionally not serialized. A small
        # over-admit under concurrency is acceptable for this coarse early-access
        # guard — advisory locks are YAGNI here.
        case signup_capacity(repo) do
          :ok -> insert_user_with_org_and_handle_race(name, email, provider, provider_id, repo)
          {:error, :signup_cap_reached} = error -> error
        end
    end
  end

  defp insert_user_with_org_and_handle_race(name, email, provider, provider_id, repo) do
    case do_insert_user_with_org(name, email, provider, provider_id, repo) do
      {:ok, user} ->
        {:ok, user, true}

      {:error, {:changeset_error, changeset}} ->
        handle_unique_email_race(changeset, email, provider, provider_id, repo)

      {:error, other} ->
        {:error, other}
    end
  end

  defp handle_unique_email_race(changeset, email, provider, provider_id, repo) do
    if unique_email_error?(changeset) do
      case repo.get_by(User, email: email) do
        %User{} = existing ->
          {:ok, linked} = link_provider_id(existing, provider, provider_id, repo)
          {:ok, linked, false}

        nil ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp find_by_provider_id(:google, provider_id, repo) when is_binary(provider_id),
    do: repo.get_by(User, google_id: provider_id)

  defp find_by_provider_id(:github, provider_id, repo) when is_binary(provider_id),
    do: repo.get_by(User, github_id: provider_id)

  defp find_by_provider_id(_provider, _provider_id, _repo), do: nil

  defp link_provider_id(user, :google, provider_id, repo) when is_binary(provider_id) do
    user
    |> User.changeset(%{google_id: provider_id})
    |> repo.update()
  end

  defp link_provider_id(user, :github, provider_id, repo) when is_binary(provider_id) do
    user
    |> User.changeset(%{github_id: provider_id})
    |> repo.update()
  end

  defp link_provider_id(user, _provider, _provider_id, _repo), do: {:ok, user}

  defp do_insert_user_with_org(name, email, provider, provider_id, repo) do
    repo.transaction(fn ->
      user_attrs = Map.merge(%{name: name, email: email}, provider_fields(provider, provider_id))

      case repo.insert(User.changeset(%User{}, user_attrs)) do
        {:ok, user} -> attach_personal_org(user, name, email, repo)
        {:error, cs} -> repo.rollback({:changeset_error, cs})
      end
    end)
  end

  defp provider_fields(:google, id) when is_binary(id), do: %{google_id: id}
  defp provider_fields(:github, id) when is_binary(id), do: %{github_id: id}
  defp provider_fields(_provider, _id), do: %{}

  # Number of slug-allocation attempts before giving up. `pick_free_slug/2` is a
  # non-atomic check-then-insert, so two concurrent first-time signups can pick
  # the same free slug and the loser's `create_org` fails the unique constraint.
  # We re-allocate and retry a bounded number of times; a few attempts is ample
  # because each retry walks past the slug the winner just took.
  @personal_org_slug_attempts 5

  defp attach_personal_org(user, name, email, repo) do
    org = create_personal_org!(name, email, repo, @personal_org_slug_attempts)

    case Orgs.add_member(org, user, :admin, repo) do
      {:ok, _} ->
        case user |> User.changeset(%{personal_org_id: org.id}) |> repo.update() do
          {:ok, updated} -> updated
          {:error, cs} -> repo.rollback({:changeset_error, cs})
        end

      {:error, cs} ->
        repo.rollback({:changeset_error, cs})
    end
  end

  # Allocate a free slug and create the org, retrying on a slug unique-constraint
  # collision (a concurrent signup grabbed the same slug between our check and
  # insert). Rolls back the surrounding signup transaction once attempts are
  # exhausted rather than crashing with a MatchError.
  defp create_personal_org!(name, email, repo, attempts_left) do
    slug = OrgSlug.pick_free_slug(OrgSlug.email_to_slug(email), repo)

    case Orgs.create_org(%{name: name, slug: slug}, repo) do
      {:ok, org} ->
        org

      {:error, cs} when attempts_left > 1 ->
        if slug_unique_error?(cs) do
          create_personal_org!(name, email, repo, attempts_left - 1)
        else
          repo.rollback({:changeset_error, cs})
        end

      {:error, cs} ->
        repo.rollback({:changeset_error, cs})
    end
  end

  defp slug_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:slug, {_msg, kw}} -> Keyword.get(kw, :constraint) == :unique
      _ -> false
    end)
  end

  defp unique_email_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:email, {_msg, kw}} -> Keyword.get(kw, :constraint) == :unique
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # Service user
  # ---------------------------------------------------------------------------

  @doc """
  Idempotently upserts the Harmont service user and its API token.

  The service user has a fixed email of `"service@harmont.local"`.
  An `ApiToken` with `token_hash: Token.hash(raw_secret)` and
  `token_type: :session` (no expiry) is created if it does not already exist.

  This function is race-safe: concurrent calls converge to the same user row
  via an upsert on `email`.

  Returns the `%User{}` record.
  """
  @spec ensure_service_user(String.t(), module()) :: User.t()
  def ensure_service_user(raw_secret, repo \\ Harmont.Repo) do
    token_hash = Token.hash(raw_secret)

    {:ok, user} =
      repo.insert(
        User.changeset(%User{}, %{name: "Service", email: @service_user_email}),
        on_conflict: [set: [name: "Service"]],
        conflict_target: :email,
        returning: true
      )

    {:ok, _token} =
      repo.insert(
        ApiToken.changeset(%ApiToken{}, %{
          token_hash: token_hash,
          token_type: :session,
          user_id: user.id
        }),
        on_conflict: :nothing,
        conflict_target: :token_hash
      )

    user
  end

  @doc """
  Returns `true` if `user` is the Harmont service user.
  """
  @spec service_user?(User.t()) :: boolean()
  def service_user?(%User{email: @service_user_email}), do: true
  def service_user?(%User{}), do: false

  # ---------------------------------------------------------------------------
  # Email verification tokens
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new email verification token.

  Returns `{raw, %EmailVerification{}}` where `raw` is the plaintext token to
  include in the outbound email (Plan 3). The token expires 24 h from `now`.
  """
  @spec put_email_verification(String.t(), String.t(), DateTime.t(), module()) ::
          {String.t(), EmailVerification.t()}
  def put_email_verification(email, name, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    raw = Token.generate()
    expires_at = DateTime.add(now, 24 * 60 * 60, :second)

    {:ok, record} =
      %EmailVerification{}
      |> EmailVerification.changeset(%{
        token_hash: Token.hash(raw),
        email: email,
        name: name,
        purpose: :signup,
        expires_at: expires_at
      })
      |> repo.insert()

    {raw, record}
  end

  @doc """
  Redeems a raw email verification token.

  Hashes `raw`, loads the record, checks expiry, deletes it (single-use), and
  returns the record for the caller to act on (e.g. create a user or a
  WebAuthn challenge).

  Returns `{:ok, %EmailVerification{}}` or
  `{:error, %Harmont.Error{code: :passkey_token_invalid}}`.
  """
  @spec take_email_verification(String.t(), DateTime.t(), module()) ::
          {:ok, EmailVerification.t()} | {:error, Error.t()}
  def take_email_verification(raw, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    hash = Token.hash(raw)

    case repo.get_by(EmailVerification, token_hash: hash) do
      nil -> {:error, Error.new(:passkey_token_invalid)}
      record -> take_record_if_valid(record, now, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Magic-link tokens
  # ---------------------------------------------------------------------------

  @doc """
  Creates a magic-link token for `user_id`.

  Returns `{raw, %MagicLink{}}` where `raw` is the plaintext token to include
  in the outbound email (Plan 3). The token expires 15 minutes from `now`.
  """
  @spec put_magic_link(binary(), DateTime.t(), module()) :: {String.t(), MagicLink.t()}
  def put_magic_link(user_id, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    raw = Token.generate()
    expires_at = DateTime.add(now, 15 * 60, :second)

    {:ok, record} =
      %MagicLink{}
      |> MagicLink.changeset(%{
        token_hash: Token.hash(raw),
        expires_at: expires_at,
        user_id: user_id
      })
      |> repo.insert()

    {raw, record}
  end

  @doc """
  Redeems a raw magic-link token.

  Hashes `raw`, loads the record, checks expiry, deletes it (single-use), and
  returns the record.

  Returns `{:ok, %MagicLink{}}` or
  `{:error, %Harmont.Error{code: :passkey_token_invalid}}`.
  """
  @spec take_magic_link(String.t(), DateTime.t(), module()) ::
          {:ok, MagicLink.t()} | {:error, Error.t()}
  def take_magic_link(raw, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    hash = Token.hash(raw)

    case repo.get_by(MagicLink, token_hash: hash) do
      nil -> {:error, Error.new(:passkey_token_invalid)}
      record -> take_record_if_valid(record, now, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # CLI auth handoff (loopback transfer + paste code)
  # ---------------------------------------------------------------------------

  # A paste code's alphabet: Crockford-style base32 minus easily-confused
  # glyphs (no I, L, O, U) so it's safe for a human to read aloud / re-type.
  @paste_code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  # 16 chars * 5 bits = 80 bits of entropy.
  @paste_code_length 16

  @cli_transfer_ttl_seconds 60
  @cli_paste_ttl_seconds 300

  @doc """
  Stores a raw session token for the CLI loopback (transfer) flow, keyed by the
  hash of the CLI-generated `nonce`.

  This is the SPA, while logged in, handing a freshly minted session token to a
  locally-running CLI that generated `nonce` and is polling `take_cli_transfer`.
  The raw token is stored only for the short handoff window
  (`#{@cli_transfer_ttl_seconds}s`) and is single-use.

  Returns `:ok`.
  """
  @spec put_cli_transfer(String.t(), String.t(), DateTime.t(), module()) :: :ok
  def put_cli_transfer(raw_session_token, nonce, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    expires_at = DateTime.add(now, @cli_transfer_ttl_seconds, :second)

    {:ok, _record} =
      %CliTransferCode{}
      |> CliTransferCode.changeset(%{
        nonce_hash: Token.hash(nonce),
        token_raw: raw_session_token,
        expires_at: expires_at
      })
      |> repo.insert()

    :ok
  end

  @doc """
  Redeems a CLI transfer code by `nonce`.

  Hashes `nonce`, looks up the stored record, checks expiry, deletes it
  (single-use), and returns the stored raw session token.

  Returns `{:ok, raw_token}` or `{:error, :invalid}`.
  """
  @spec take_cli_transfer(String.t(), DateTime.t(), module()) ::
          {:ok, String.t()} | {:error, :invalid}
  def take_cli_transfer(nonce, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    hash = Token.hash(nonce)

    case repo.get_by(CliTransferCode, nonce_hash: hash) do
      nil -> {:error, :invalid}
      record -> take_cli_record(record, now, repo)
    end
  end

  @doc """
  Stores a raw session token for the CLI paste flow under a freshly generated,
  human-typeable paste code.

  This is the SPA, while logged in, showing a short code the user can re-type
  into a locally-running CLI. The raw token is stored only for the paste window
  (`#{@cli_paste_ttl_seconds}s`) and is single-use.

  Returns `{:ok, code}` with the plaintext code to display.
  """
  @spec put_cli_paste(String.t(), DateTime.t(), module()) :: {:ok, String.t()}
  def put_cli_paste(raw_session_token, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    code = generate_paste_code()
    expires_at = DateTime.add(now, @cli_paste_ttl_seconds, :second)

    {:ok, _record} =
      %CliPasteCode{}
      |> CliPasteCode.changeset(%{
        code_hash: Token.hash(code),
        token_raw: raw_session_token,
        expires_at: expires_at
      })
      |> repo.insert()

    {:ok, code}
  end

  @doc """
  Redeems a CLI paste code.

  Hashes `code`, looks up the stored record, checks expiry, deletes it
  (single-use), and returns the stored raw session token.

  Returns `{:ok, raw_token}` or `{:error, :invalid}`.
  """
  @spec take_cli_paste(String.t(), DateTime.t(), module()) ::
          {:ok, String.t()} | {:error, :invalid}
  def take_cli_paste(code, now \\ DateTime.utc_now(), repo \\ Harmont.Repo) do
    hash = Token.hash(code)

    case repo.get_by(CliPasteCode, code_hash: hash) do
      nil -> {:error, :invalid}
      record -> take_cli_record(record, now, repo)
    end
  end

  # Delete a CLI handoff record (single-use) and, if unexpired, return its raw
  # token; expired records still get deleted but yield :invalid.
  defp take_cli_record(record, now, repo) do
    repo.delete(record)

    if DateTime.compare(now, record.expires_at) == :gt do
      {:error, :invalid}
    else
      {:ok, record.token_raw}
    end
  end

  defp generate_paste_code do
    alphabet = @paste_code_alphabet
    size = length(alphabet)

    @paste_code_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(alphabet, rem(byte, size)) end)
    |> List.to_string()
  end

  # Shared helper: delete a timed record only if not expired, returning it.
  defp take_record_if_valid(record, now, repo) do
    if DateTime.compare(now, record.expires_at) == :gt do
      repo.delete(record)
      {:error, Error.new(:passkey_token_invalid)}
    else
      repo.delete(record)
      {:ok, record}
    end
  end

  # ---------------------------------------------------------------------------
  # Profile editing
  # ---------------------------------------------------------------------------

  @doc """
  Updates the user's editable profile fields (currently just `name`). Email is
  the OAuth identity key and is intentionally not editable here.
  """
  @spec update_user(User.t(), map(), module()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs, repo \\ Harmont.Repo) do
    user
    |> User.profile_changeset(attrs)
    |> repo.update()
  end

  # ---------------------------------------------------------------------------
  # Account deletion
  # ---------------------------------------------------------------------------

  @doc """
  Deletes the user's account. Auth + membership rows cascade; the three billing
  FKs (`coupons`, `coupon_redemptions`, `stripe_checkout_sessions`) are
  `on_delete: :restrict`, so a user with billing history is refused with a clean
  `account_has_billing_history` error instead of a DB crash.

  Note: the user's personal organization row is intentionally left in place
  (there is no user->org FK); orphan cleanup is out of scope for v1.
  """
  @spec delete_user(User.t(), module()) :: {:ok, User.t()} | {:error, Harmont.Error.t()}
  def delete_user(%User{} = user, repo \\ Harmont.Repo) do
    user
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: "coupons_created_by_user_id_fkey",
      message: "has billing history"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: "coupon_redemptions_redeemed_by_user_id_fkey",
      message: "has billing history"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: "stripe_checkout_sessions_initiated_by_user_id_fkey",
      message: "has billing history"
    )
    |> repo.delete()
    |> case do
      {:ok, deleted} -> {:ok, deleted}
      {:error, %Ecto.Changeset{}} -> {:error, Error.new(:account_has_billing_history)}
    end
  end
end

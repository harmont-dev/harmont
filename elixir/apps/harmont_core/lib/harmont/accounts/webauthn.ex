defmodule Harmont.Accounts.Webauthn do
  @moduledoc """
  Pure WebAuthn ceremony helpers.

  All functions deal with database persistence of challenges and credentials.
  The actual cryptographic verification of assertions is performed by the `wax`
  library (Plan 3). These helpers cover everything that can be done without
  making HTTP calls or loading wax options from config.

  Every function accepts an explicit `repo` module so they remain testable
  without process-dictionary tricks.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Accounts.WebauthnChallenge
  alias Harmont.Accounts.WebauthnCredential
  alias Harmont.Error

  # ---------------------------------------------------------------------------
  # Challenge lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Persists a new WebAuthn challenge from `attrs`.

  Required attrs: `:challenge` (binary), `:purpose`, `:expires_at`.
  Optional: `:user_id`, `:user_handle`, `:pending_signup_token_hash`,
  `:pending_magic_link_token_hash`.

  Returns `{:ok, %WebauthnChallenge{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec put_challenge(map(), module()) ::
          {:ok, WebauthnChallenge.t()} | {:error, Ecto.Changeset.t()}
  def put_challenge(attrs, repo) do
    %WebauthnChallenge{}
    |> WebauthnChallenge.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Loads the challenge with `challenge_id`, checks it has not expired relative
  to `now`, deletes it (single-use), and returns it.

  Returns `{:ok, %WebauthnChallenge{}}` on success or
  `{:error, %Harmont.Error{code: :passkey_challenge_invalid}}` when the
  challenge is unknown or expired.
  """
  @spec take_challenge(binary(), DateTime.t(), module()) ::
          {:ok, WebauthnChallenge.t()} | {:error, Error.t()}
  def take_challenge(nil, _now, _repo), do: {:error, Error.new(:passkey_challenge_invalid)}

  def take_challenge(challenge_id, now, repo) do
    case repo.get(WebauthnChallenge, challenge_id) do
      nil ->
        {:error, Error.new(:passkey_challenge_invalid)}

      challenge ->
        if DateTime.compare(now, challenge.expires_at) == :gt do
          # Expired — clean it up and reject
          repo.delete(challenge)
          {:error, Error.new(:passkey_challenge_invalid)}
        else
          repo.delete(challenge)
          {:ok, challenge}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Sign-counter rule
  # ---------------------------------------------------------------------------

  @doc """
  Applies the WebAuthn sign-counter policy.

  Rules (in priority order):
  1. `asserted == 0` → authenticator does not maintain a counter (Apple/Google
     passkeys). Keep the stored value unchanged.
  2. `asserted > stored` → normal counter increment. Use the asserted value.
  3. `asserted <= stored && asserted != 0` → possible credential clone.
     Return `{:error, :counter_cloned}`.

  Returns `{:ok, new_count}` or `{:error, :counter_cloned}`.
  """
  @spec apply_sign_counter(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :counter_cloned}
  def apply_sign_counter(stored, asserted) when is_integer(stored) and is_integer(asserted) do
    cond do
      asserted == 0 -> {:ok, stored}
      asserted > stored -> {:ok, asserted}
      true -> {:error, :counter_cloned}
    end
  end

  # ---------------------------------------------------------------------------
  # Credential CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Persists a new WebAuthn credential.

  Required attrs: `:credential_id` (binary), `:user_handle`, `:public_key`,
  `:sign_count`, `:user_id`.

  Returns `{:ok, %WebauthnCredential{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec store_credential(map(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def store_credential(attrs, repo) do
    %WebauthnCredential{}
    |> WebauthnCredential.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Looks up a stored credential by its raw `credential_id` binary.

  Returns the `%WebauthnCredential{}` or `nil` when no credential matches. The
  credential id is the stable handle the authenticator returns in an assertion,
  so this is how a discoverable-credential (passkey) login resolves which user
  is signing in.
  """
  @spec get_by_credential_id(binary(), module()) :: WebauthnCredential.t() | nil
  def get_by_credential_id(credential_id, repo) when is_binary(credential_id) do
    repo.get_by(WebauthnCredential, credential_id: credential_id)
  end

  @doc """
  Lists every credential registered to `user_id`.

  Used by the register (add-a-passkey) flow to build the `excludeCredentials`
  list so an authenticator the user already enrolled can't be double-registered.

  Returns a (possibly empty) list of `%WebauthnCredential{}`.
  """
  @spec list_credentials(binary(), module()) :: [WebauthnCredential.t()]
  def list_credentials(user_id, repo) when is_binary(user_id) do
    repo.all(from(c in WebauthnCredential, where: c.user_id == ^user_id))
  end

  @doc """
  Records a successful authentication against `cred`.

  Updates the stored `sign_count` to `new_sign_count` and stamps `last_used_at`
  with `now`. The counter policy itself lives in `apply_sign_counter/2`; this
  function just persists the agreed-upon new value.

  Returns `{:ok, %WebauthnCredential{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec touch_credential(WebauthnCredential.t(), non_neg_integer(), DateTime.t(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def touch_credential(%WebauthnCredential{} = cred, new_sign_count, now, repo) do
    cred
    |> WebauthnCredential.changeset(%{sign_count: new_sign_count, last_used_at: now})
    |> repo.update()
  end

  @doc """
  Deletes `cred` unless it is the user's only registered credential.

  Refuses with `{:error, %Harmont.Error{code: :passkey_last_credential}}` when
  deleting would leave the user with no credentials.
  """
  @spec delete_credential(WebauthnCredential.t(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, Error.t()}
  def delete_credential(%WebauthnCredential{} = cred, repo) do
    count =
      repo.one(
        from(c in WebauthnCredential,
          where: c.user_id == ^cred.user_id,
          select: count(c.id)
        )
      )

    if count <= 1 do
      {:error, Error.new(:passkey_last_credential)}
    else
      repo.delete(cred)
    end
  end

  @doc """
  Deletes the credential identified by `cred_uuid`, scoped to `user_id`.

  The credential is only deleted when it belongs to `user_id`, so a user can
  never touch another user's passkey. Enforces the last-credential guard:
  refuses with `{:error, %Harmont.Error{code: :passkey_last_credential}}` when
  deleting would leave the user with no credentials.

  Returns `{:ok, %WebauthnCredential{}}` on success, `{:error, :not_found}`
  when no credential with `cred_uuid` belongs to the user, or the last-credential
  error.
  """
  @spec delete_credential_for_user(binary(), binary(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, :not_found} | {:error, Error.t()}
  def delete_credential_for_user(user_id, cred_uuid, repo)
      when is_binary(user_id) and is_binary(cred_uuid) do
    case repo.get_by(WebauthnCredential, id: cred_uuid, user_id: user_id) do
      nil -> {:error, :not_found}
      cred -> delete_credential(cred, repo)
    end
  end

  @doc """
  Locks a credential so it cannot be used for authentication.

  Returns `{:ok, %WebauthnCredential{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec lock_credential(WebauthnCredential.t(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def lock_credential(%WebauthnCredential{} = cred, repo) do
    cred
    |> WebauthnCredential.changeset(%{locked: true})
    |> repo.update()
  end

  @doc """
  Unlocks a previously locked credential.

  Returns `{:ok, %WebauthnCredential{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec unlock_credential(WebauthnCredential.t(), module()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def unlock_credential(%WebauthnCredential{} = cred, repo) do
    cred
    |> WebauthnCredential.changeset(%{locked: false})
    |> repo.update()
  end
end

defmodule Harmont.Pipelines.RunnerTokens do
  @moduledoc """
  Context for managing runner tokens.

  Runner tokens are single-use, time-limited credentials issued to a build's
  agent.  `issue/3` generates a fresh token and stores its SHA-256 hash.
  `consume/3` is the single point of validation: it hashes the raw token,
  looks it up, checks expiry, deletes the row (making it single-use), and
  returns the `build_id`.

  All functions accept an explicit `repo` so they are pure/testable.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Builds.Build
  alias Harmont.Pipelines.RunnerToken
  alias Harmont.Token

  # Runner tokens are valid for 24 hours by default.
  @ttl_seconds 86_400

  @doc """
  Issues a new runner token for `build_id`.

  Returns `{raw_token, %RunnerToken{}}`.  The raw token is passed to the agent;
  only its hash is stored.

  `now` is a `DateTime` (utc) used to compute `expires_at`.
  """
  @spec issue(binary(), DateTime.t(), module()) ::
          {:ok, {String.t(), RunnerToken.t()}} | {:error, term()}
  def issue(build_id, now, repo) do
    raw = Token.generate()
    hash = Token.hash(raw)
    expires_at = DateTime.add(now, @ttl_seconds, :second)

    attrs = %{build_id: build_id, token_hash: hash, expires_at: expires_at}

    repo.transaction(fn ->
      case repo.insert(RunnerToken.changeset(%RunnerToken{}, attrs)) do
        {:ok, token} -> stamp_build_hash(repo, build_id, raw, token)
        {:error, cs} -> repo.rollback(cs)
      end
    end)
  end

  # Stamp the build's denormalized runner_token_hash NOW (raw sha256 — the form
  # SourceController/AgentSocket compare). It is otherwise only written by
  # Materialize, which runs AFTER render, which is too late for the render
  # sandbox's own source fetch (it authorizes against this column). The value is
  # identical to Materialize's later write. Runs inside `issue/3`'s transaction,
  # so a rollback here aborts the token insert too.
  defp stamp_build_hash(repo, build_id, raw, token) do
    case repo.update_all(
           from(b in Build, where: b.id == ^build_id),
           set: [runner_token_hash: :crypto.hash(:sha256, raw)]
         ) do
      {1, _} ->
        {raw, token}

      other ->
        # No (or multiple) build rows updated — a phantom/duplicate build_id.
        # Fail loudly rather than leak a build whose token hash is unset (which
        # would 401 the render source fetch with no trace back to this call site).
        repo.rollback({:runner_token_hash_update_unexpected, other})
    end
  end

  @doc """
  Consumes a runner token.

  Hashes `raw`, finds the row, checks expiry, deletes it (single-use), and
  returns `{:ok, build_id}`.  Returns `{:error, :invalid}` when the token
  is not found or has expired.
  """
  @spec consume(String.t(), DateTime.t(), module()) ::
          {:ok, binary()} | {:error, :invalid}
  def consume(raw, now, repo) do
    hash = Token.hash(raw)

    query = from(rt in RunnerToken, where: rt.token_hash == ^hash)

    case repo.one(query) do
      nil ->
        {:error, :invalid}

      %RunnerToken{} = token ->
        if DateTime.compare(now, token.expires_at) == :gt do
          {:error, :invalid}
        else
          repo.delete!(token)
          {:ok, token.build_id}
        end
    end
  end
end

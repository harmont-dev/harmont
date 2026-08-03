defmodule Harmont.Settings do
  @moduledoc """
  Runtime-tweakable platform settings, backed by the `system_settings` KV table.

  Values are read live on each call (no caching), so an operator can change a
  setting in prod via `iex` (`Harmont.Settings.put_signup_cap/1`) or `psql`
  and have it take effect on the next request without a redeploy.

  An absent row means "unset"; each typed accessor documents what unset means
  for that setting.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Settings.Setting

  @signup_cap_key "signup_cap"

  @doc "Returns the raw string value for `key`, or `nil` if no row exists."
  @spec get(String.t(), module()) :: String.t() | nil
  def get(key, repo \\ Harmont.Repo) when is_binary(key) do
    repo.one(from(s in Setting, where: s.key == ^key, select: s.value))
  end

  @doc """
  Upserts `key` to `value` (stringified). Returns `{:ok, %Setting{}}`.
  """
  @spec put(String.t(), term(), module()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value, repo \\ Harmont.Repo) when is_binary(key) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: to_string(value)})
    |> repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  @doc """
  The total-signup cap, or `nil` when unset or malformed.

  `nil` means "no limit" — the deliberate default so the platform is never
  locked out before the cap is configured, and a typo'd value fails open rather
  than rejecting everyone.
  """
  @spec signup_cap(module()) :: non_neg_integer() | nil
  def signup_cap(repo \\ Harmont.Repo) do
    case get(@signup_cap_key, repo) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end
    end
  end

  @doc "Sets the total-signup cap to a non-negative integer `n`."
  @spec put_signup_cap(non_neg_integer(), module()) ::
          {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put_signup_cap(n, repo \\ Harmont.Repo) when is_integer(n) and n >= 0 do
    put(@signup_cap_key, Integer.to_string(n), repo)
  end
end

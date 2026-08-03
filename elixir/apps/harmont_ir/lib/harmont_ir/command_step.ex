defmodule HarmontIr.CommandStep do
  @moduledoc """
  A single build command. Mirrors hm-pipeline-ir `CommandStep`, plus the
  flat-IR-only `builds_in` lineage hint (resolved into an edge by the planner).
  """
  use TypedStruct
  alias HarmontIr.Cache

  typedstruct enforce: true do
    field :key, String.t()
    field :cmd, String.t()
    field :label, String.t() | nil, enforce: false, default: nil
    field :builds_in, String.t() | nil, enforce: false, default: nil
    field :image, String.t() | nil, enforce: false, default: nil
    field :env, %{String.t() => String.t()}, enforce: false, default: %{}
    field :timeout_seconds, non_neg_integer() | nil, enforce: false, default: nil
    field :cache, Cache.t() | nil, enforce: false, default: nil
    field :runner, String.t() | nil, enforce: false, default: nil
    field :runner_args, term(), enforce: false, default: nil
  end

  @spec from_map(map()) ::
          {:ok, t()} | {:error, {:missing_field, String.t()} | {:bad_cache, term()}}
  def from_map(m) do
    with {:ok, key} <- fetch(m, "key"),
         {:ok, cmd} <- fetch(m, "cmd"),
         {:ok, cache} <- parse_cache(m["cache"]) do
      {:ok,
       %__MODULE__{
         key: key,
         cmd: cmd,
         label: m["label"],
         builds_in: m["builds_in"],
         image: m["image"],
         env: m["env"] || %{},
         timeout_seconds: m["timeout_seconds"],
         cache: cache,
         runner: m["runner"],
         runner_args: m["runner_args"]
       }}
    end
  end

  defp fetch(m, k) do
    case m do
      %{^k => v} when not is_nil(v) -> {:ok, v}
      _ -> {:error, {:missing_field, k}}
    end
  end

  defp parse_cache(nil), do: {:ok, nil}

  defp parse_cache(c) when is_map(c) do
    case Cache.from_map(c) do
      {:ok, cache} -> {:ok, cache}
      {:error, e} -> {:error, {:bad_cache, e}}
    end
  end

  defp parse_cache(v), do: {:error, {:bad_cache, {:not_a_map, v}}}
end

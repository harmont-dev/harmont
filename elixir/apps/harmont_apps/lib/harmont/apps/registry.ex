defmodule Harmont.Apps.Registry do
  @moduledoc """
  Resolves a provider id (atom or string, matching the `:provider` URL segment
  and the DB `provider` column) to its implementation module. Providers are
  registered in application env at boot:

      config :harmont_apps, :providers, github: Harmont.GhApp.Provider
  """

  @spec providers() :: keyword(module())
  def providers, do: Application.get_env(:harmont_apps, :providers, [])

  @doc "Resolve a provider impl module by id. Accepts atom or string."
  @spec fetch(atom() | String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_atom(id) do
    case Keyword.fetch(providers(), id) do
      {:ok, mod} -> {:ok, mod}
      :error -> :error
    end
  end

  def fetch(id) when is_binary(id) do
    case Enum.find(providers(), fn {k, _} -> Atom.to_string(k) == id end) do
      {_k, mod} -> {:ok, mod}
      nil -> :error
    end
  end
end

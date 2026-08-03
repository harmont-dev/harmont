defmodule Freestyle.Wire do
  @moduledoc """
  Translation between the API's camelCase JSON keys and our snake_case
  struct fields, plus request-body encoding that omits `nil` values.

  Schemas with irregular wire shapes bypass this and hand-roll their codec.
  """

  @doc "Lower-camel-case an atom field name into its wire key."
  @spec to_wire_key(atom()) :: String.t()
  def to_wire_key(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> lower_camelize()
  end

  @doc """
  Snake-case a camelCase wire key into an atom. Uses `String.to_atom/1`
  because field names come from our own schemas; callers translate keys
  immediately before `Ecto.Changeset.cast/3` against a known field set.
  """
  @spec from_wire_key(String.t()) :: atom()
  def from_wire_key(key) when is_binary(key) do
    key |> Macro.underscore() |> String.to_atom()
  end

  @doc """
  Encode a map of snake_case atom keys into a wire map: camelCase string
  keys, `nil` values dropped. Non-nil values are passed through as-is
  (already JSON-ready scalars, lists, or nested wire maps).
  """
  @spec encode(map()) :: map()
  def encode(map) when is_map(map) do
    for {k, v} <- map, not is_nil(v), into: %{} do
      {to_wire_key(k), v}
    end
  end

  @doc """
  Rewrite the *keys* of a decoded JSON object from camelCase to
  snake_case strings, leaving values untouched. Suitable input for
  `Ecto.Changeset.cast/3`, which accepts string keys.
  """
  @spec rekey_in(map()) :: map()
  def rekey_in(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {k |> Macro.underscore(), v}
    end
  end

  # "account_id" -> "accountId"; "id" -> "id"
  @spec lower_camelize(String.t()) :: String.t()
  defp lower_camelize(snake) do
    case Macro.camelize(snake) do
      "" -> ""
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
    end
  end
end

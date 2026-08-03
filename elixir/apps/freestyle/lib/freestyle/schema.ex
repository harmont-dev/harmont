defmodule Freestyle.Schema do
  @moduledoc false
  # Base for Freestyle payload schemas. `use Freestyle.Schema` brings in
  # Ecto.Schema (no primary key) and overridable default `decode/1`,
  # `decode_list/1`, and `encode/1` built on the camelCase wire codec.

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key false

      @doc "Decode a camelCase JSON object into this struct."
      @spec decode(map()) :: {:ok, struct()} | {:error, String.t()}
      def decode(json) when is_map(json) do
        Freestyle.Schema.cast_decode(__MODULE__, __schema__(:fields), json)
      end

      @doc "Decode a list of camelCase JSON objects."
      @spec decode_list([map()]) :: {:ok, [struct()]} | {:error, String.t()}
      def decode_list(list) when is_list(list) do
        Freestyle.Schema.decode_each(__MODULE__, list)
      end

      @doc "Encode this struct into a camelCase wire map (nils dropped)."
      @spec encode(struct()) :: map()
      def encode(struct) when is_struct(struct, __MODULE__) do
        struct
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Freestyle.Wire.encode()
      end

      defoverridable decode: 1, decode_list: 1, encode: 1
    end
  end

  @doc false
  @spec cast_decode(module(), [atom()], map()) :: {:ok, struct()} | {:error, String.t()}
  def cast_decode(module, fields, json) do
    params = Freestyle.Wire.rekey_in(json)

    module
    |> struct()
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.apply_action(:load)
    |> case do
      {:ok, struct} -> {:ok, struct}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  @doc false
  @spec decode_each(module(), [map()]) :: {:ok, [struct()]} | {:error, String.t()}
  def decode_each(module, list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case module.decode(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @spec changeset_error(Ecto.Changeset.t()) :: String.t()
  defp changeset_error(changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    "schema decode failed: #{inspect(errors)}"
  end
end

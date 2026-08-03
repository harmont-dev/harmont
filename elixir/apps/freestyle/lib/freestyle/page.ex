defmodule Freestyle.Page do
  @moduledoc """
  One page of an offset-paginated list, decoded as:
  items come from the first present of a set of known array keys, else the
  first array-valued key; `total` from `total`/`totalCount`/item-count;
  `offset` from `offset`/0.
  """

  @enforce_keys [:items, :total, :offset]
  defstruct [:items, :total, :offset]

  @type t(a) :: %__MODULE__{items: [a], total: non_neg_integer(), offset: non_neg_integer()}
  @type t :: t(term())

  @item_keys ~w(items repositories vms snapshots identities schedules executions)

  @doc """
  Decode a paginated response. `item_decoder` decodes one raw item object
  into `{:ok, item}` / `{:error, detail}`.
  """
  @spec decode(map(), (map() -> {:ok, a} | {:error, String.t()})) ::
          {:ok, t(a)} | {:error, String.t()}
        when a: var
  def decode(json, item_decoder) when is_map(json) do
    with {:ok, raw_items} <- find_items(json),
         {:ok, items} <- decode_items(raw_items, item_decoder) do
      total = json["total"] || json["totalCount"] || length(items)
      offset = json["offset"] || 0
      {:ok, %__MODULE__{items: items, total: total, offset: offset}}
    end
  end

  @spec find_items(map()) :: {:ok, [map()]} | {:error, String.t()}
  defp find_items(json) do
    case Enum.find_value(@item_keys, fn k -> match_list(json[k]) end) do
      nil -> first_array_value(json)
      list -> {:ok, list}
    end
  end

  defp first_array_value(json) do
    case Enum.find_value(json, fn {_k, v} -> match_list(v) end) do
      nil -> {:error, "no array key found in Page response"}
      list -> {:ok, list}
    end
  end

  defp match_list(v) when is_list(v), do: v
  defp match_list(_), do: nil

  @spec decode_items([map()], (map() -> {:ok, a} | {:error, String.t()})) ::
          {:ok, [a]} | {:error, String.t()}
        when a: var
  defp decode_items(raw_items, item_decoder) do
    Enum.reduce_while(raw_items, {:ok, []}, fn item, {:ok, acc} ->
      case item_decoder.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end
end

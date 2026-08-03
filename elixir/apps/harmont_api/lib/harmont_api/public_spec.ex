defmodule HarmontApi.PublicSpec do
  @moduledoc """
  Derives the **public** OpenAPI spec from the full one by removing every
  operation marked `"x-internal": true`.

  The full `priv/static/openapi.json` is the single source the frontend types
  against (it needs the app-only operations). The docs site and the spun-out
  CLI must only see the public surface, so they consume
  `priv/static/openapi.public.json`, written here.

  Wired as the umbrella `mix api.public_spec` alias (mirrors
  `HarmontApi.ErrorCatalog`). Pure JSON in / JSON out — no app boot needed.
  """

  @methods ~w(get put post delete options head patch trace)

  @doc "Read priv/static/openapi.json, filter it, write priv/static/openapi.public.json."
  @spec write!(Path.t()) :: :ok
  def write!(out \\ "priv/static/openapi.public.json") do
    public =
      "priv/static/openapi.json"
      |> File.read!()
      |> Jason.decode!()
      |> filter()

    File.write!(out, Jason.encode!(public, pretty: true) <> "\n")
  end

  @doc """
  Returns a copy of `spec` with all `x-internal` operations removed, empty path
  items pruned, the `x-internal` marker stripped from survivors, and the root
  `tags` list reduced to tags still referenced by a surviving operation.
  """
  @spec filter(map()) :: map()
  def filter(spec) do
    paths =
      spec
      |> Map.get("paths", %{})
      |> Enum.map(fn {path, item} -> {path, filter_path_item(item)} end)
      |> Enum.reject(fn {_path, item} -> path_item_empty?(item) end)
      |> Map.new()

    spec
    |> Map.put("paths", paths)
    |> recompute_tags(paths)
  end

  defp filter_path_item(item) do
    Enum.reduce(@methods, item, fn method, acc ->
      case Map.get(acc, method) do
        %{"x-internal" => true} -> Map.delete(acc, method)
        %{} = op -> Map.put(acc, method, Map.delete(op, "x-internal"))
        _ -> acc
      end
    end)
  end

  # A path item is empty once it carries no HTTP operations. Any leftover
  # "parameters"/"summary" keys are meaningless without operations, so drop it.
  defp path_item_empty?(item), do: not Enum.any?(@methods, &Map.has_key?(item, &1))

  defp recompute_tags(spec, paths) do
    used =
      for {_path, item} <- paths,
          method <- @methods,
          op = Map.get(item, method),
          op != nil,
          tag <- Map.get(op, "tags", []),
          into: MapSet.new(),
          do: tag

    case Map.get(spec, "tags") do
      tags when is_list(tags) ->
        kept =
          Enum.filter(tags, fn
            %{"name" => name} -> MapSet.member?(used, name)
            _ -> true
          end)

        Map.put(spec, "tags", kept)

      _ ->
        spec
    end
  end
end

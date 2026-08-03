defmodule Harmont.Pipelines.Discovery do
  @moduledoc """
  Parse a `.hm` render registry envelope (from `Harmont.Engine.Render.discover/2`,
  i.e. `hm.dump_registry_json()`) into discovered-pipeline maps the sync layer
  upserts. Pure: no DB, no network.

  Envelope shape:

      {"pipelines": [
        {"slug": "ci", "name": "CI", "allow_manual": true,
         "triggers": [{"event": "push", "branches": ["main"]}, ...],
         "definition": {...}}
      ]}

  Triggers are kept verbatim — `Harmont.Pipelines.Triggers` already reads the
  `"event"` discriminator, so they match without remapping.
  """

  @type discovered :: %{
          source_slug: String.t(),
          name: String.t(),
          allow_manual: boolean(),
          triggers: [map()]
        }

  @spec parse_envelope(String.t()) :: {:ok, [discovered()]} | {:error, term()}
  def parse_envelope(json) when is_binary(json) do
    with {:ok, %{"pipelines" => pipelines}} when is_list(pipelines) <- Jason.decode(json),
         {:ok, discovered} <- map_pipelines(pipelines) do
      {:ok, discovered}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_json, Exception.message(e)}}
      {:error, _} = err -> err
      {:ok, _not_a_pipelines_list} -> {:error, :no_pipelines_key}
    end
  end

  # Map each entry, short-circuiting on the first invalid one so the result
  # honors the {:ok, _} | {:error, _} contract (no raised FunctionClauseError).
  defp map_pipelines(pipelines) do
    pipelines
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
      case to_discovered(p) do
        {:ok, d} -> {:cont, {:ok, [d | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp to_discovered(%{"slug" => slug} = p) when is_binary(slug) and slug != "" do
    {:ok,
     %{
       source_slug: slug,
       name: Map.get(p, "name", slug),
       allow_manual: Map.get(p, "allow_manual", true),
       triggers: Map.get(p, "triggers", [])
     }}
  end

  defp to_discovered(p), do: {:error, {:missing_slug, p}}
end

defmodule Freestyle.Api.Observability do
  @moduledoc "Observability (log query) endpoint."

  alias Freestyle.{Client, Error, Request}
  alias Freestyle.Types.Observability.{LogQuery, ObsLogEntry}

  @doc ~S"GET /observability/v1/logs — query logs (unwraps `{logs:[...]}`)."
  @spec query_logs(Client.t(), LogQuery.t()) :: {:ok, [ObsLogEntry.t()]} | {:error, Error.t()}
  def query_logs(client, %LogQuery{} = query) do
    Request.get(
      client,
      "/observability/v1/logs",
      LogQuery.to_params(query),
      fn body -> ObsLogEntry.decode_list(body["logs"] || []) end,
      "freestyle.observability.query_logs"
    )
  end
end

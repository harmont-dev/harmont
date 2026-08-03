defmodule Freestyle.Api.Execute do
  @moduledoc "Script execution + deployment endpoints."

  alias Freestyle.{Client, Error, Page, Pagination, Request, Types}
  alias Freestyle.Types.Execute.{Deployment, ExecuteResult, ExecuteScriptOpts}

  @doc "POST /execute/v2/script."
  @spec execute_script_v2(Client.t(), ExecuteScriptOpts.t()) ::
          {:ok, ExecuteResult.t()} | {:error, Error.t()}
  def execute_script_v2(client, %ExecuteScriptOpts{} = opts) do
    Request.post(
      client,
      "/execute/v2/script",
      ExecuteScriptOpts.encode(opts),
      &ExecuteResult.decode/1,
      "freestyle.execute.execute_script_v2"
    )
  end

  @doc "POST /execute/v3/script."
  @spec execute_script_v3(Client.t(), ExecuteScriptOpts.t()) ::
          {:ok, ExecuteResult.t()} | {:error, Error.t()}
  def execute_script_v3(client, %ExecuteScriptOpts{} = opts) do
    Request.post(
      client,
      "/execute/v3/script",
      ExecuteScriptOpts.encode(opts),
      &ExecuteResult.decode/1,
      "freestyle.execute.execute_script_v3"
    )
  end

  @doc "GET /v1/deployments — one page."
  @spec list_deployments(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Deployment.t())} | {:error, Error.t()}
  def list_deployments(client, params \\ %{}) do
    Request.get(
      client,
      "/v1/deployments",
      [limit: Map.get(params, :limit, 50), offset: Map.get(params, :offset, 0)],
      &Page.decode(&1, fn item -> Deployment.decode(item) end),
      "freestyle.execute.list_deployments"
    )
  end

  @doc "Lazy stream over all deployments."
  @spec stream_deployments(Client.t()) :: Enumerable.t()
  def stream_deployments(client), do: Pagination.stream(fn p -> list_deployments(client, p) end)

  @doc "GET /v1/deployments/{id}."
  @spec get_deployment(Client.t(), Types.deployment_id()) ::
          {:ok, Deployment.t()} | {:error, Error.t()}
  def get_deployment(client, deployment_id) do
    Request.get(
      client,
      "/v1/deployments/#{deployment_id}",
      [],
      &Deployment.decode/1,
      "freestyle.execute.get_deployment"
    )
  end
end

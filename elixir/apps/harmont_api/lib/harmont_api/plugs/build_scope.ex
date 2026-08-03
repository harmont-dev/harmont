defmodule HarmontApi.Plugs.BuildScope do
  @moduledoc """
  Build-scoped tenancy plug.

  Reads the `:number` path parameter and resolves it to a build within the
  already-scoped pipeline (`conn.assigns.pipeline`) via
  `Harmont.Builds.get_by_pipeline_and_number/3`. On success it assigns the
  build to `conn.assigns.build`; otherwise it halts with `404 Not Found` and
  the Harmont error envelope.

  Build numbers are unique only within a pipeline, so a number that does not
  exist in this pipeline (or that exists only in another pipeline/org) is
  reported identically as `build_not_found` — 404-not-403, consistent with
  `OrgScope`/`PipelineScope`.

  MUST run after `HarmontApi.Plugs.PipelineScope` — it reads
  `conn.assigns.pipeline`.

      pipeline :build_scoped do
        plug HarmontApi.Plugs.Auth
        plug HarmontApi.Plugs.OrgScope
        plug HarmontApi.Plugs.PipelineScope
        plug HarmontApi.Plugs.BuildScope
      end
  """

  import Plug.Conn, only: [assign: 3]

  alias Harmont.Builds
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, number} <- parse_number(conn.params["number"]),
         {:ok, build} <-
           Builds.get_by_pipeline_and_number(conn.assigns.pipeline, number, Repo) do
      assign(conn, :build, build)
    else
      _ -> not_found(conn)
    end
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_number(_), do: :error

  defp not_found(conn) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "build_not_found",
      message: "No build with that number exists in this pipeline.",
      doc_url: "https://docs.harmont.dev/api/errors/build-not-found"
    )
  end
end

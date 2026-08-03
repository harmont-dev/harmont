defmodule Harmont.Engine.Api do
  @moduledoc """
  In-process entry point for starting and cancelling builds.

  Replaces the gRPC `RunPipeline` / `CancelBuild` RPCs (Plan 4 bridge collapse):
  the API edge calls these functions directly instead of dialling a gRPC server.
  The gRPC server is deleted in Plan 6.

  ## The single build row

  Every function here takes an EXISTING `%Harmont.Builds.Build{}` created by
  `Harmont.Builds.create_build` (core). `Harmont.Engine.Materialize.materialize_jobs/3`
  materialises the jobs + deps for that row and sets its exec fields — no second
  build row is created.

  ## Runner token issued once

  The raw runner token is issued exactly once per call. `render_and_start/3`
  issues it first (the in-sandbox render needs it to fetch the source), then
  threads the SAME raw token into `materialize_and_start`-equivalent logic via
  the private `start_with_token/4` helper, which is also what `materialize_and_start/3`
  uses after issuing its own token. The token's SHA-256 hash is stamped on the
  build's `runner_token_hash` eagerly by `RunnerTokens.issue/3` (so the render
  source fetch can authorize before materialize runs) and re-affirmed by
  `Materialize` — do not remove either write.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Harmont.Builds.Build
  alias Harmont.Engine.{Cancel, CI, Materialize, Render}
  alias Harmont.Pipelines.RunnerTokens
  alias HarmontIr.{Flat, Graph, Planner}

  @type opts :: keyword()

  @doc """
  Materialises + starts an existing build from pre-rendered v0 IR JSON.

  Issues a runner token, parses + plans the IR, materialises jobs+deps for
  `build`, then enqueues the root `CI.JobRunner` Oban jobs. On a plan/parse
  rejection the build's `error_code` / `error_message` / `state` are set and
  `{:error, {:plan_rejected, detail}}` is returned.

  Returns `{:ok, {build, raw_runner_token}}` on success.

  Opts: `:source_url` (string|nil) — the source archive URL stored on the build.
  """
  @spec materialize_and_start(Build.t(), String.t(), opts()) ::
          {:ok, {Build.t(), String.t()}} | {:error, term()}
  def materialize_and_start(%Build{} = build, ir_json, opts \\ []) do
    with {:ok, {raw, _token}} <- RunnerTokens.issue(build.id, DateTime.utc_now(), Harmont.Repo) do
      start_with_token(build, ir_json, raw, opts)
    end
  end

  @doc """
  Renders the build's pipeline IR in a short-lived sandbox, then materialises +
  starts the build.

  The runner token is issued first (the render's source-fetch step authenticates
  with it) and the SAME token is reused for materialisation + start. The render
  backend defaults to `HarmontVm.Backend.impl()`; tests override it via
  `Application.get_env(:harmont_engine, :render_backend, ...)`.

  `params` = `%{slug:, source_url:, source_sha256:}`.

  Returns `{:ok, {build, raw_runner_token}}`. A render failure sets the build's
  error fields and returns `{:error, {:plan_rejected, detail}}`.
  """
  @spec render_and_start(
          Build.t(),
          %{
            required(:slug) => String.t(),
            required(:source_url) => String.t(),
            required(:source_sha256) => String.t()
          },
          opts()
        ) :: {:ok, {Build.t(), String.t()}} | {:error, term()}
  def render_and_start(%Build{} = build, %{slug: slug} = params, opts \\ []) do
    backend = Application.get_env(:harmont_engine, :render_backend, HarmontVm.Backend.impl())

    with {:ok, {raw, _token}} <- RunnerTokens.issue(build.id, DateTime.utc_now(), Harmont.Repo),
         {:ok, ir_json} <-
           render_ir(backend, build, %{
             source_url: params.source_url,
             source_sha256: params.source_sha256,
             slug: slug,
             runner_token: raw
           }) do
      start_with_token(build, ir_json, raw, Keyword.put_new(opts, :source_url, params.source_url))
    end
  end

  @doc """
  Cancels an in-flight build by its `external_build_id`.

  Delegates to `Harmont.Engine.Cancel.request/1`. Returns `true` if the build was
  found and the cancel cascade ran, `false` if no such build exists.
  """
  @spec cancel(String.t()) :: boolean()
  def cancel(external_build_id), do: Cancel.request(external_build_id)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Plan the IR, materialise jobs+deps for the build, and enqueue root runners,
  # threading the already-issued raw runner token through. Shared by
  # materialize_and_start/3 and render_and_start/3 so the token is issued once.
  defp start_with_token(%Build{} = build, ir_json, raw, opts) do
    # `build.materialize` makes the otherwise-invisible "build materialized N
    # jobs" step queryable: a silent 0-job build (the recurring IR-format-mismatch
    # footgun) becomes a single BubbleUp on `build.job_count = 0`, and the IR form
    # (graph vs flat) + the stable rejection code are on the span. Wraps only the
    # plan+materialize step — render failures go through `reject/2` before this.
    Tracer.with_span "build.materialize", %{
      attributes:
        %{
          "harmont.build.id" => build.id,
          "harmont.build.external_id" => build.external_build_id,
          "harmont.pipeline.id" => build.pipeline_id
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
    } do
      with {:ok, {graph, form}} <- plan_ir(ir_json),
           counts = Materialize.graph_counts(graph),
           _ =
             Tracer.set_attributes(%{
               "ir.form" => form,
               "build.job_count" => counts.job_count,
               "build.dep_count" => counts.dep_count
             }),
           {:ok, build} <-
             Materialize.materialize_jobs(build, graph,
               source_url: opts[:source_url],
               runner_token: raw
             ) do
        :ok = CI.start_build(build.id, raw)
        {:ok, {build, raw}}
      else
        {:error, reason} ->
          # Set status on THIS span only (don't push it into the shared `reject/2`,
          # which also serves the render path with no `build.materialize` span open).
          {code, _detail} = rejection(reason)
          Tracer.set_attribute("harmont.error.code", code)
          Tracer.add_event("build.rejected", %{"harmont.error.code" => code})
          Tracer.set_status(OpenTelemetry.status(:error, code))
          reject(build, reason)
      end
    end
  end

  # The DSL (hm / hm-pipeline-ir) emits the canonical graph-form IR
  # (`{"version","graph":{nodes,edges}}`); the legacy flat steps-form
  # (`{"version","steps":[...]}`) is still accepted for the no-render path.
  # Returns the planned graph tagged with the IR form it came from so the
  # `build.materialize` span can record which parser path ran.
  defp plan_ir(ir_json) do
    case Jason.decode(ir_json) do
      {:ok, %{"graph" => g} = m} when is_map(g) ->
        with {:ok, graph} <- Graph.from_map(m), do: {:ok, {graph, "graph"}}

      {:ok, m} ->
        with {:ok, flat} <- Flat.from_map(m),
             {:ok, graph} <- Planner.plan(flat),
             do: {:ok, {graph, "flat"}}

      {:error, e} ->
        {:error, {:invalid_json, e}}
    end
  end

  defp render_ir(backend, %Build{} = build, params) do
    case Render.render(backend, params) do
      {:ok, ir_json} -> {:ok, ir_json}
      {:error, reason} -> reject(build, reason)
    end
  end

  # Record the rejection on the build row and surface a stable error tuple.
  defp reject(%Build{} = build, reason) do
    {code, detail} = rejection(reason)

    _ =
      build
      |> Build.changeset(%{state: "failed", error_code: code, error_message: detail})
      |> Harmont.Repo.update()

    {:error, {:plan_rejected, detail}}
  end

  defp rejection({:bad_version, v}),
    do: {"bad_version", "expected version \"0\", got #{inspect(v)}"}

  defp rejection({:duplicate_key, _} = e), do: {"duplicate_key", HarmontIr.PlanError.message(e)}

  defp rejection({:unknown_dependency, _, _} = e),
    do: {"unknown_dependency", HarmontIr.PlanError.message(e)}

  defp rejection({:cycle, _} = e), do: {"cycle", HarmontIr.PlanError.message(e)}
  defp rejection({:render_failed, detail}), do: {"render_failed", detail}

  # Surface a clean, human-readable JSON error instead of dumping the raw
  # `%Jason.DecodeError{}` struct into the customer's error envelope.
  defp rejection({:invalid_json, %Jason.DecodeError{} = e}),
    do: {"invalid_json", "the pipeline IR is not valid JSON: #{Exception.message(e)}"}

  defp rejection(other), do: {"invalid_ir", inspect(other)}
end

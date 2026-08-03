defmodule Freestyle.Telemetry do
  @moduledoc """
  `:telemetry` instrumentation for the Freestyle client.

  ## Events

    * `[:freestyle, :request, :start]` — measurements `%{system_time, monotonic_time}`,
      metadata `%{operation, method, path, client}` (and any caller-supplied keys).
    * `[:freestyle, :request, :stop]` — measurements `%{duration, monotonic_time}`,
      metadata as above plus `:result` (`:ok | :error`). On an error it also carries
      `:error_kind` (`:api | :decode | :transport`), `:status` (nil for transport
      errors), `:error_code` (the stable lowercase tag, nil when absent), and
      `:error_message` (the human reason, e.g. `"timeout"` for a transport timeout
      — the field that makes a timed-out provision diagnosable).
    * `[:freestyle, :request, :exception]` — measurements `%{duration, monotonic_time}`,
      metadata adds `:kind`, `:reason`, `:stacktrace`.
    * `[:freestyle, :request, :retry]` — measurements `%{delay}` (ms), metadata
      `%{operation, attempt, reason}`. Emitted once per retry decision.

  `operation` is the logical API operation name, e.g. `"freestyle.vm.exec_command"`.
  Differentiate client instances via the
  `:client` metadata key rather than renaming events. Attach with
  `:telemetry.attach_many/4`; bridge to OpenTelemetry with `opentelemetry_telemetry`.
  """

  @doc """
  Run `fun` inside a `[:freestyle, :request]` telemetry span. `fun` should
  return either a `{stop_metadata, result}` tuple to enrich the stop event,
  or a bare result (treated as `{%{}, result}`).
  """
  @spec span(map(), (-> term())) :: term()
  def span(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:freestyle, :request, :start],
      %{system_time: System.system_time(), monotonic_time: start_mono},
      metadata
    )

    try do
      case fun.() do
        {%{} = extra, result} -> {result, Map.merge(metadata, extra)}
        result -> {result, stop_meta(metadata, result)}
      end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:freestyle, :request, :exception],
          %{
            duration: System.monotonic_time() - start_mono,
            monotonic_time: System.monotonic_time()
          },
          metadata
          |> Map.put(:kind, kind)
          |> Map.put(:reason, reason)
          |> Map.put(:stacktrace, stacktrace)
        )

        :erlang.raise(kind, reason, stacktrace)
    else
      {result, stop_metadata} ->
        :telemetry.execute(
          [:freestyle, :request, :stop],
          %{
            duration: System.monotonic_time() - start_mono,
            monotonic_time: System.monotonic_time()
          },
          stop_metadata
        )

        result
    end
  end

  @doc "Emit a retry event for a single retry decision."
  @spec retry(map(), keyword()) :: :ok
  def retry(metadata, opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    delay = Keyword.fetch!(opts, :delay)
    reason = Keyword.fetch!(opts, :reason)

    :telemetry.execute(
      [:freestyle, :request, :retry],
      %{delay: delay},
      Map.merge(metadata, %{attempt: attempt, reason: reason})
    )
  end

  @spec stop_meta(map(), term()) :: map()
  defp stop_meta(metadata, {:ok, _}), do: Map.put(metadata, :result, :ok)

  defp stop_meta(metadata, {:error, %Freestyle.Error{} = err}) do
    metadata
    |> Map.put(:result, :error)
    |> Map.put(:status, err.status)
    |> Map.put(:error_kind, err.kind)
    |> Map.put(:error_code, err.code && Freestyle.Error.code_text(err.code))
    |> Map.put(:error_message, err.message)
  end

  defp stop_meta(metadata, _), do: metadata
end

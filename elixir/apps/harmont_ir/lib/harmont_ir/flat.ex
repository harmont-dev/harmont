defmodule HarmontIr.Flat do
  @moduledoc """
  The flat v0 IR sent by the API: an ordered list of `command` and
  `wait` steps. `wait` is represented as `{:wait, continue_on_failure?}`.
  The planner (HarmontIr.Planner) lowers this into a graph.
  """
  use TypedStruct
  alias HarmontIr.CommandStep

  @type step :: CommandStep.t() | {:wait, boolean()}

  typedstruct enforce: true do
    field :version, String.t()
    field :default_image, String.t() | nil, enforce: false, default: nil
    field :timeout_seconds, non_neg_integer() | nil, enforce: false, default: nil
    field :env, %{String.t() => String.t()}, enforce: false, default: %{}
    field :steps, [step()]
  end

  @spec parse(String.t()) ::
          {:ok, t()}
          | {:error,
             {:invalid_json, term()}
             | {:bad_version, String.t()}
             | {:unknown_step_type, String.t()}
             | {:missing_field, String.t()}}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> from_map(map)
      {:error, e} -> {:error, {:invalid_json, e}}
    end
  end

  @spec from_map(map()) ::
          {:ok, t()}
          | {:error,
             {:bad_version, String.t()}
             | {:unknown_step_type, String.t()}
             | {:missing_field, String.t()}
             | {:bad_cache, term()}}
  def from_map(%{"version" => "0"} = m) do
    with {:ok, steps} <- parse_steps(m["steps"] || []) do
      {:ok,
       %__MODULE__{
         version: "0",
         default_image: m["default_image"],
         timeout_seconds: m["timeout_seconds"],
         env: m["env"] || %{},
         steps: steps
       }}
    end
  end

  def from_map(%{"version" => v}), do: {:error, {:bad_version, v}}
  def from_map(_), do: {:error, {:missing_field, "version"}}

  defp parse_steps(steps), do: reduce_ok(steps, &parse_step/1)

  defp parse_step(%{"type" => "command"} = m), do: CommandStep.from_map(m)
  defp parse_step(%{"type" => "wait"} = m), do: {:ok, {:wait, m["continue_on_failure"] == true}}
  defp parse_step(%{"type" => t}), do: {:error, {:unknown_step_type, t}}
  defp parse_step(_), do: {:error, {:missing_field, "type"}}

  defp reduce_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end
end

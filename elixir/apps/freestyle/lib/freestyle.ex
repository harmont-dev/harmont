defmodule Freestyle do
  @moduledoc """
  Elixir client for the [Freestyle Sandboxes API](https://api.freestyle.sh).

  Build a client handle, then call API functions:

      client = Freestyle.Client.new(api_key: System.fetch_env!("FREESTYLE_API_KEY"))
      {:ok, who} = Freestyle.who_am_i(client)
      {:ok, %{status_code: 0} = result} =
        Freestyle.exec_command(client, "vm-1", %Freestyle.Types.Vm.ExecAwaitRequest{command: "true"})

  ## API surface

  The engine-critical Auth and VM operations are exposed directly on this
  module (with `!` bang variants that raise `Freestyle.Error`). Every section
  is also available under `Freestyle.Api.*`:

    * `Freestyle.Api.Auth`, `Freestyle.Api.Vm`, `Freestyle.Api.Execute`,
      `Freestyle.Api.Git`, `Freestyle.Api.Identity`, `Freestyle.Api.Domain`,
      `Freestyle.Api.Dns`, `Freestyle.Api.Cron`, `Freestyle.Api.Observability`.

  Wrap any `Freestyle.Api.*` call in `unwrap!/1` for bang-style behavior.

  ## Errors

  Functions return `{:ok, value}` or `{:error, %Freestyle.Error{}}`. See
  `Freestyle.Error` for the error shape.

  ## Telemetry

  Attach to `[:freestyle, :request, :start | :stop | :exception | :retry]`.
  See `Freestyle.Telemetry` for measurements and metadata.
  """

  alias Freestyle.Api
  alias Freestyle.Client

  @typedoc "Result of an API call."
  @type result(a) :: {:ok, a} | {:error, Freestyle.Error.t()}

  @doc "Build a client handle. See `Freestyle.Client.new/1`."
  @spec new(keyword()) :: Client.t()
  defdelegate new(opts), to: Client

  @doc "Unwrap an `{:ok, value}` result, raising the `Freestyle.Error` on `{:error, _}`."
  @spec unwrap!(result(a)) :: a when a: var
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Freestyle.Error{} = err}), do: raise(err)

  # ── Auth ─────────────────────────────────────────────────────────
  defdelegate who_am_i(client), to: Api.Auth
  defdelegate get_background_request(client, request_id), to: Api.Auth

  @doc "Bang variant of `who_am_i/1`."
  def who_am_i!(client), do: unwrap!(Api.Auth.who_am_i(client))

  def get_background_request!(client, request_id),
    do: unwrap!(Api.Auth.get_background_request(client, request_id))

  # ── VM (engine path) ───────────────────────────────────────────
  defdelegate list_vms(client, params \\ %{}), to: Api.Vm
  defdelegate create_vm(client, opts), to: Api.Vm
  defdelegate delete_vm(client, vm_id), to: Api.Vm
  defdelegate exec_command(client, vm_id, req), to: Api.Vm
  defdelegate put_file(client, vm_id, path, req), to: Api.Vm
  defdelegate snapshot_vm(client, vm_id, opts), to: Api.Vm
  defdelegate delete_snapshot(client, snapshot_id), to: Api.Vm

  def create_vm!(client, opts), do: unwrap!(Api.Vm.create_vm(client, opts))
  def delete_vm!(client, vm_id), do: unwrap!(Api.Vm.delete_vm(client, vm_id))
  def exec_command!(client, vm_id, req), do: unwrap!(Api.Vm.exec_command(client, vm_id, req))
  def put_file!(client, vm_id, path, req), do: unwrap!(Api.Vm.put_file(client, vm_id, path, req))
  def snapshot_vm!(client, vm_id, opts), do: unwrap!(Api.Vm.snapshot_vm(client, vm_id, opts))

  def delete_snapshot!(client, snapshot_id),
    do: unwrap!(Api.Vm.delete_snapshot(client, snapshot_id))

  @doc "Returns the library version string."
  @spec version() :: String.t()
  def version, do: "0.1.0"
end

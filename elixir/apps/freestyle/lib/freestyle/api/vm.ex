defmodule Freestyle.Api.Vm do
  @moduledoc "VM and snapshot endpoints."

  alias Freestyle.{Client, Error, Page, Pagination, Request}
  alias Freestyle.Types

  alias Freestyle.Types.Vm.{
    CreateSnapshotOpts,
    CreateVmOpts,
    ExecAwaitRequest,
    ExecAwaitResponse,
    Snapshot,
    SnapshotVmOpts,
    SnapshotVmResponse,
    UpdateSnapshotOpts,
    Vm,
    WriteFileRequest
  }

  @doc "GET /v1/vms — one page of VMs."
  @spec list_vms(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Vm.t())} | {:error, Error.t()}
  def list_vms(client, params \\ %{}) do
    {limit, offset} = page(params)

    Request.get(
      client,
      "/v1/vms",
      [limit: limit, offset: offset],
      &Page.decode(&1, fn item -> Vm.decode(item) end),
      "freestyle.vm.list_vms"
    )
  end

  @doc "Lazy stream over all VMs."
  @spec stream_vms(Client.t()) :: Enumerable.t()
  def stream_vms(client) do
    Pagination.stream(fn p -> list_vms(client, p) end)
  end

  @doc "POST /v1/vms — provision a VM."
  @spec create_vm(Client.t(), CreateVmOpts.t()) :: {:ok, Vm.t()} | {:error, Error.t()}
  def create_vm(client, %CreateVmOpts{} = opts) do
    Request.post(
      client,
      "/v1/vms",
      CreateVmOpts.encode(opts),
      &Vm.decode/1,
      "freestyle.vm.create_vm"
    )
  end

  @doc "DELETE /v1/vms/{id}."
  @spec delete_vm(Client.t(), Types.vm_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_vm(client, vm_id) do
    Request.delete(client, "/v1/vms/#{vm_id}", [], "freestyle.vm.delete_vm")
  end

  @doc "POST /v1/vms/{id}/exec-await — synchronous command exec. Returns stdout/stderr/exit."
  @spec exec_command(Client.t(), Types.vm_id(), ExecAwaitRequest.t()) ::
          {:ok, ExecAwaitResponse.t()} | {:error, Error.t()}
  def exec_command(client, vm_id, %ExecAwaitRequest{} = req) do
    Request.post(
      client,
      "/v1/vms/#{vm_id}/exec-await",
      ExecAwaitRequest.encode(req),
      &ExecAwaitResponse.decode/1,
      "freestyle.vm.exec_command"
    )
  end

  @doc """
  PUT /v1/vms/{id}/files/{path} — write a file. `/` in `path` is percent-encoded
  to `%2F` so the catch-all path param survives routing. Returns `{:ok, :ok}`.
  """
  @spec put_file(Client.t(), Types.vm_id(), String.t(), WriteFileRequest.t()) ::
          {:ok, :ok} | {:error, Error.t()}
  def put_file(client, vm_id, path, %WriteFileRequest{} = req) do
    encoded = encode_path(path)

    Request.put(
      client,
      "/v1/vms/#{vm_id}/files/#{encoded}",
      WriteFileRequest.encode(req),
      fn _ -> {:ok, :ok} end,
      "freestyle.vm.put_file"
    )
  end

  @doc "GET /v1/vms/snapshots — one page of snapshots."
  @spec list_snapshots(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Snapshot.t())} | {:error, Error.t()}
  def list_snapshots(client, params \\ %{}) do
    {limit, offset} = page(params)

    Request.get(
      client,
      "/v1/vms/snapshots",
      [limit: limit, offset: offset],
      &Page.decode(&1, fn item -> Snapshot.decode(item) end),
      "freestyle.vm.list_snapshots"
    )
  end

  @doc "Lazy stream over all snapshots."
  @spec stream_snapshots(Client.t()) :: Enumerable.t()
  def stream_snapshots(client), do: Pagination.stream(fn p -> list_snapshots(client, p) end)

  @doc "POST /v1/vms/snapshots — create a blank snapshot."
  @spec create_snapshot(Client.t(), CreateSnapshotOpts.t()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def create_snapshot(client, %CreateSnapshotOpts{} = opts) do
    Request.post(
      client,
      "/v1/vms/snapshots",
      CreateSnapshotOpts.encode(opts),
      &Snapshot.decode/1,
      "freestyle.vm.create_snapshot"
    )
  end

  @doc """
  POST /v1/vms/{id}/snapshot — snapshot a live VM's state. This is the
  cache-critical path Harmont uses after a successful job run.
  """
  @spec snapshot_vm(Client.t(), Types.vm_id(), SnapshotVmOpts.t()) ::
          {:ok, SnapshotVmResponse.t()} | {:error, Error.t()}
  def snapshot_vm(client, vm_id, %SnapshotVmOpts{} = opts) do
    Request.post(
      client,
      "/v1/vms/#{vm_id}/snapshot",
      SnapshotVmOpts.encode(opts),
      &SnapshotVmResponse.decode/1,
      "freestyle.vm.snapshot_vm"
    )
  end

  @doc "PATCH /v1/vms/snapshots/{id} — update snapshot metadata."
  @spec update_snapshot(Client.t(), Types.snapshot_id(), UpdateSnapshotOpts.t()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def update_snapshot(client, snapshot_id, %UpdateSnapshotOpts{} = opts) do
    Request.patch(
      client,
      "/v1/vms/snapshots/#{snapshot_id}",
      UpdateSnapshotOpts.encode(opts),
      &Snapshot.decode/1,
      "freestyle.vm.update_snapshot"
    )
  end

  @doc "DELETE /v1/vms/snapshots/{id}."
  @spec delete_snapshot(Client.t(), Types.snapshot_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_snapshot(client, snapshot_id) do
    Request.delete(client, "/v1/vms/snapshots/#{snapshot_id}", [], "freestyle.vm.delete_snapshot")
  end

  @spec page(Types.page_params()) :: {non_neg_integer(), non_neg_integer()}
  defp page(params), do: {Map.get(params, :limit, 50), Map.get(params, :offset, 0)}

  @spec encode_path(String.t()) :: String.t()
  defp encode_path(path), do: String.replace(path, "/", "%2F")
end

defmodule HarmontVm.Backend.Freestyle do
  @moduledoc """
  Production VM backend on the Freestyle Sandboxes API (elixir/freestyle).
  Handle = `%{vm_id: String.t()}`. Each operation builds its own client with a
  receive timeout scaled to the synchronous work it does (provision/snapshot:
  `provision_receive_timeout/0`; exec: `exec_receive_timeout/1` = the command's
  hard cap plus a margin), because the Freestyle client's 30s default is far
  shorter than a VM boot or a long `exec-await` — a too-short timeout turns a
  clean result into a retried transport timeout. Errors are rendered to the
  behaviour's `{:error, vm_error}` shape with a stable code.
  """
  @behaviour HarmontVm.Backend

  alias Freestyle.Api.Vm

  alias Freestyle.Types.Vm.{
    CpuSpec,
    CreateVmOpts,
    DiskSpec,
    ExecAwaitRequest,
    MemorySpec,
    SnapshotVmOpts
  }

  # A `create_vm` provisions and boots a VM from a snapshot, and `snapshot_vm`
  # freezes a live VM — both are long synchronous operations that routinely
  # exceed the Freestyle client's 30s default receive timeout. Wait up to this
  # long (overridable via
  # `config :harmont_vm, HarmontVm.Backend.Freestyle, provision_timeout_ms: …`)
  # before treating one as a transport timeout.
  @default_provision_timeout_ms 120_000

  # `exec-await` is synchronous: the SERVER enforces `timeout_ms` (the command's
  # hard cap) and only returns once it elapses. The HTTP receive timeout must
  # EXCEED that, or the client gives up first — turning a clean server-side
  # timeout result into a transport timeout that the retry policy then multiplies
  # 5x. Wait the hard cap plus this margin.
  @exec_timeout_margin_ms 60_000

  # Teardown / snapshot reaping are quick fire-and-forget calls; don't let a dead
  # connection hang them for the full provision window.
  @reap_timeout_ms 30_000

  @doc false
  # receive_timeout (ms) for an exec-await call: the server-side hard cap plus a
  # margin so the server's own timeout result wins over a client transport
  # timeout. Public for the timeout-policy regression test.
  @spec exec_receive_timeout(non_neg_integer()) :: pos_integer()
  def exec_receive_timeout(hard_cap_ms) when is_integer(hard_cap_ms) and hard_cap_ms >= 0,
    do: hard_cap_ms + @exec_timeout_margin_ms

  @doc false
  # receive_timeout (ms) for provision/snapshot — long synchronous VM operations.
  # Overridable per deploy via app env. Public for the timeout-policy test.
  @spec provision_receive_timeout() :: pos_integer()
  def provision_receive_timeout do
    :harmont_vm
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:provision_timeout_ms, @default_provision_timeout_ms)
  end

  @impl true
  def provision(spec) do
    client = client(provision_receive_timeout())

    opts = %CreateVmOpts{
      # parent_snapshot (cache fork) takes precedence over base_snapshot (agent-baked base)
      snapshot_id: spec[:parent_snapshot] || spec[:base_snapshot],
      name: spec[:name],
      disk: %DiskSpec{size_gb: spec.disk_gb},
      memory: %MemorySpec{size_gb: spec.memory_gb},
      cpu: %CpuSpec{count: spec.cpu_count}
    }

    case Vm.create_vm(client, opts) do
      {:ok, %{id: vm_id}} -> {:ok, %{vm_id: vm_id}}
      {:error, e} -> {:error, {:provision_failed, render(e)}}
    end
  end

  @impl true
  def await_ready(_handle, _timeout_ms), do: :ok

  # Freestyle exec-await is synchronous; readiness is implicit. Override if
  # Freestyle adds an async status API.

  @impl true
  def exec(%{vm_id: id}, %{command: cmd, hard_cap_ms: cap}) do
    req = %ExecAwaitRequest{command: cmd, terminal: nil, timeout_ms: cap}

    case Vm.exec_command(client(exec_receive_timeout(cap)), id, req) do
      {:ok, r} ->
        {:ok, %{exit_code: r.status_code, stdout: r.stdout || "", stderr: r.stderr || ""}}

      {:error, e} ->
        {:error, {:exec_failed, render(e)}}
    end
  end

  @impl true
  def snapshot(%{vm_id: id}) do
    case Vm.snapshot_vm(client(provision_receive_timeout()), id, %SnapshotVmOpts{name: nil}) do
      {:ok, %{snapshot_id: sid}} -> {:ok, sid}
      {:error, e} -> {:error, {:snapshot_failed, render(e)}}
    end
  end

  @impl true
  def delete_snapshot(snapshot_id) do
    _ = Vm.delete_snapshot(client(@reap_timeout_ms), snapshot_id)
    :ok
  end

  @impl true
  def teardown(%{vm_id: id}) do
    _ = Vm.delete_vm(client(@reap_timeout_ms), id)
    :ok
  end

  @impl true
  def handle_id(%{vm_id: id}), do: id

  # Build a client from config with the given receive timeout (scaled per
  # operation to the synchronous work it does). req_options lets tests inject
  # Req.Test.
  defp client(receive_timeout) do
    cfg = Application.fetch_env!(:harmont_vm, __MODULE__)

    Freestyle.Client.new(
      api_key: Keyword.fetch!(cfg, :api_key),
      receive_timeout: receive_timeout,
      req_options: Keyword.get(cfg, :req_options, [])
    )
  end

  # Render a %Freestyle.Error{} to a stable %{code, message} map.
  # code is an atom (e.g. :internal_server_error) — convert to string for the job error field.
  defp render(%Freestyle.Error{} = e) do
    code =
      case e.code do
        nil -> "freestyle_error"
        {_tag, raw} -> raw
        atom when is_atom(atom) -> Atom.to_string(atom)
      end

    %{code: code, message: e.message}
  end

  # Catch-all: a non-Error term (e.g. a transport exception that escaped the client)
  # must not crash the backend — render it to the same {code, message} shape.
  # Dialyzer flags this as unreachable because Freestyle.Error currently enumerates
  # all codes, but we keep it as defensive future-proofing against new client versions.
  @dialyzer {:nowarn_function, render: 1}
  defp render(other), do: %{code: "freestyle_error", message: inspect(other)}
end

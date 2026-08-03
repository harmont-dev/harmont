defmodule HarmontVm.Backend do
  @moduledoc """
  Pluggable VM/sandbox backend, built for the agent model:

    * NO log/heartbeat callbacks — the in-VM agent streams those over
      WebSocket directly to the engine.
    * timeout/cancel are raced OUTSIDE exec/2 by the Session; backends
      do not implement them.
    * handles are opaque; the Freestyle impl will wrap a VM-id string.

  A backend module is selected via this package's own app env (the consuming
  application configures it):
      config :harmont_vm, :backend, HarmontVm.Backend.Local
  """

  @type handle :: term()
  @type snapshot_id :: String.t()

  @type spec :: %{
          required(:cpu_count) => pos_integer(),
          required(:memory_gb) => float(),
          required(:disk_gb) => float(),
          required(:name) => String.t(),
          optional(:base_snapshot) => snapshot_id() | nil,
          optional(:parent_snapshot) => snapshot_id() | nil
        }

  @type exec_opts :: %{required(:command) => String.t(), required(:hard_cap_ms) => pos_integer()}
  @type exec_result :: %{exit_code: integer() | nil, stdout: String.t(), stderr: String.t()}

  @type error ::
          {:provision_failed, term()}
          | {:exec_failed, term()}
          | {:snapshot_failed, term()}
          | :timed_out
          | :canceled

  @doc "Create a VM from base/parent snapshot with the given resources."
  @callback provision(spec()) :: {:ok, handle()} | {:error, error()}

  @doc "Block until the VM accepts exec. Default impls may return :ok immediately."
  @callback await_ready(handle(), timeout_ms :: pos_integer()) :: :ok | {:error, error()}

  @doc "Run the agent-launch (or bash) command. Returns when the process exits."
  @callback exec(handle(), exec_opts()) :: {:ok, exec_result()} | {:error, error()}

  @doc "Snapshot the live VM working tree for the build cache."
  @callback snapshot(handle()) :: {:ok, snapshot_id()} | {:error, error()}

  @doc "Reap a cache snapshot. Fire-and-forget."
  @callback delete_snapshot(snapshot_id()) :: :ok

  @doc """
  List all disk snapshots the account holds. Used by the periodic sweeper to
  reap orphans. Returns the snapshot id + its creation time (epoch ms).
  """
  @callback list_snapshots() ::
              {:ok, [%{id: snapshot_id(), create_time_ms: non_neg_integer()}]} | {:error, error()}

  @doc """
  List every sandbox the provider holds that this platform owns, with its
  label-derived kind. Used by `SandboxReaper` on live-VM fork backends to
  reconcile against the registry. `kind` is `:job | :template | :template_pending
  | :unknown`; `snapshot_label` is the `harmont_snapshot` value (templates only).
  Sandboxes reported in a dead state (`"error"`/`"build_failed"`) are reaped
  immediately by the SandboxReaper regardless of age.
  """
  @callback list_managed_sandboxes() ::
              {:ok,
               [
                 %{
                   id: String.t(),
                   kind: :job | :template | :template_pending | :unknown,
                   snapshot_label: String.t() | nil,
                   create_time_ms: non_neg_integer(),
                   state: String.t() | nil
                 }
               ]}
              | {:error, error()}

  @doc "Destroy the VM. Must be idempotent; runs on every exit path."
  @callback teardown(handle()) :: :ok

  @doc "True if a snapshot/fork source IS the live VM (so the engine must keep it alive until reaped). Default false (Runloop)."
  @callback fork_source_is_live_vm?() :: boolean()

  @doc """
  A stable, human-readable id for a provisioned VM handle — the backend's own
  sandbox/devbox/vm identifier. Used to attribute usage to the exact VM that ran
  a job. Optional: backends that don't implement it simply contribute no handle.
  """
  @callback handle_id(handle()) :: String.t()

  @optional_callbacks await_ready: 2,
                      snapshot: 1,
                      delete_snapshot: 1,
                      list_snapshots: 0,
                      list_managed_sandboxes: 0,
                      fork_source_is_live_vm?: 0,
                      handle_id: 1

  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:harmont_vm, :backend)

  @doc """
  A stable provider string for the configured backend, used as the registry's
  `provider` column — e.g. `HarmontVm.Backend.Daytona` -> `"daytona"`.
  """
  @spec provider() :: String.t()
  def provider, do: impl() |> Module.split() |> List.last() |> Macro.underscore()
end

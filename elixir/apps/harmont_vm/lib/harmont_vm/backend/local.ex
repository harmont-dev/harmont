defmodule HarmontVm.Backend.Local do
  @moduledoc """
  Dev/test VM backend. Runs the command directly on the host in a temp dir.
  No real VM, no agent. Snapshots are no-ops. NEVER use in prod.
  """
  @behaviour HarmontVm.Backend

  @impl true
  def provision(spec) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "harmont-local-#{spec.name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, %{dir: dir, name: spec.name}}
  end

  @impl true
  def await_ready(_handle, _timeout_ms), do: :ok

  @impl true
  def exec(%{dir: dir}, %{command: cmd} = opts) do
    cap = Map.get(opts, :hard_cap_ms, 600_000)
    # stderr is merged into stdout (dev simplification); the stderr field stays "".
    task = Task.async(fn -> System.cmd("bash", ["-lc", cmd], cd: dir, stderr_to_stdout: true) end)

    case Task.yield(task, cap) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {:ok, %{exit_code: code, stdout: out, stderr: ""}}
      nil -> {:error, :timed_out}
    end
  rescue
    e -> {:error, {:exec_failed, e}}
  end

  @impl true
  def snapshot(%{name: name}), do: {:ok, "local-snapshot-#{name}"}

  @impl true
  def delete_snapshot(_id), do: :ok

  @impl true
  def teardown(%{dir: dir}) do
    _ = File.rm_rf(dir)
    :ok
  end

  @impl true
  def handle_id(%{name: name}), do: name
end

defmodule Harmont.CannedRenderBackend do
  @moduledoc """
  Cross-process-safe `HarmontVm.Backend` stub for `resolve_ir/1` tests.

  Unlike `Harmont.StubBackend` (which keys its recording Agent off the
  process dictionary of the *caller* of `new/1`), this backend reads its canned
  per-exec results from application env at `exec/2` time. That makes it safe to
  use through `resolve_ir/1` even if the render runs in a different process than
  the test — there is no process-dictionary affinity.

  Configure with:

      Application.put_env(:harmont_engine, :canned_render_execs, [
        %{exit_code: 0, stdout: "", stderr: ""},            # fetch
        %{exit_code: 0, stdout: ~s({"version":"0"}), ...}   # render
      ])

  Successive `exec/2` calls pop the head of that list (per provisioned handle,
  which carries an Agent pid for cursor state). `provision/1` reads
  `:canned_render_provision` (default `:ok`).
  """
  @behaviour HarmontVm.Backend

  defstruct [:cursor]

  @impl true
  def provision(_spec) do
    case Application.get_env(:harmont_engine, :canned_render_provision, :ok) do
      :ok ->
        {:ok, cursor} = Agent.start_link(fn -> 0 end)
        {:ok, %__MODULE__{cursor: cursor}}

      {:error, reason} ->
        {:error, {:provision_failed, reason}}
    end
  end

  @impl true
  def exec(%__MODULE__{cursor: cursor}, %{command: _cmd}) do
    execs = Application.get_env(:harmont_engine, :canned_render_execs, [])
    idx = Agent.get_and_update(cursor, fn i -> {i, i + 1} end)

    result =
      Enum.at(execs, idx, %{exit_code: 0, stdout: "", stderr: ""})

    {:ok, result}
  end

  @impl true
  def teardown(%__MODULE__{cursor: cursor}) do
    if Process.alive?(cursor), do: Agent.stop(cursor)
    :ok
  end

  @impl true
  def snapshot(_handle), do: {:error, {:snapshot_failed, :unsupported}}

  @impl true
  def delete_snapshot(_id), do: :ok
end

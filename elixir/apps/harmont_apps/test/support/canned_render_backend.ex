defmodule Harmont.Apps.CannedRenderBackend do
  @moduledoc """
  Cross-process-safe `HarmontVm.Backend` stub for the engine fan-out render path.

  A copy of the engine's `Harmont.CannedRenderBackend` (that module lives in the
  engine app's `test/support`, which is not compiled for this app's test suite).
  Reads its canned per-exec results from application env at `exec/2` time, so it
  is safe even when the render runs in a different process than the test.
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
    {:ok, Enum.at(execs, idx, %{exit_code: 0, stdout: "", stderr: ""})}
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

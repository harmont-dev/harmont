defmodule HarmontApi.CannedRenderBackend do
  @moduledoc """
  Cross-process-safe `HarmontVm.Backend` stub for the build-create render path.

  A copy of the engine's `Harmont.CannedRenderBackend` (that module lives in
  the engine app's `test/support`, which is not compiled into `harmont_api`'s
  standalone test run, so we keep an api-local twin under a distinct name to
  avoid a module-redefinition clash in the full umbrella `mix test`).

  Reads its canned per-exec results from application env at `exec/2` time, so it
  is safe to use through `Harmont.Engine.Render` even when the render runs in a
  different process than the test.

  Configure with:

      Application.put_env(:harmont_engine, :render_backend, HarmontApi.CannedRenderBackend)
      Application.put_env(:harmont_engine, :canned_render_execs, [
        %{exit_code: 0, stdout: "", stderr: ""},            # source fetch
        %{exit_code: 0, stdout: ~s({"version":"0", ...}), stderr: ""}   # render
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

    result = Enum.at(execs, idx, %{exit_code: 0, stdout: "", stderr: ""})

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

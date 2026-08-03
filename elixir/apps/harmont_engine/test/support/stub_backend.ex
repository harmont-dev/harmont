defmodule Harmont.StubBackend do
  @moduledoc """
  In-process `HarmontVm.Backend` stub for `Exec.Render` tests.

  `Exec.Render.render/2` dispatches against a backend *module* (prod passes
  `HarmontVm.Backend.impl()`). This stub is that module: tests call
  `Harmont.StubBackend` as the backend. Per-test recording state lives
  in an `Agent` whose pid travels inside the opaque `handle` returned by
  `provision/1`, so callbacks stay pure module functions while still recording.

  `new/1` returns the same handle struct the backend produces, so the test can
  pass `StubBackend` as the module and query the returned value for the recorded
  `commands/1` and `torn_down?/1`. Pure: no real VM, Python, or network.
  """
  @behaviour HarmontVm.Backend

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Pre-seed the recording state and return a handle. `:execs` is the list of
  canned `%{exit_code, stdout, stderr}` results returned by successive `exec/2`
  calls. `:provision` (default `:ok`) injects a provision failure via
  `{:error, reason}`.

  Stored in the process dictionary keyed by the calling process so the module's
  `provision/1` callback (which only receives a spec) can find it.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    execs = Keyword.get(opts, :execs, [])
    provision = Keyword.get(opts, :provision, :ok)

    {:ok, pid} =
      Agent.start_link(fn ->
        %{execs: execs, commands: [], torn_down?: false, provision: provision}
      end)

    Process.put(__MODULE__, pid)
    %__MODULE__{pid: pid}
  end

  @doc "Commands passed to `exec/2`, in call order."
  @spec commands(t()) :: [String.t()]
  def commands(%__MODULE__{pid: pid}),
    do: Agent.get(pid, fn s -> Enum.reverse(s.commands) end)

  @doc "Whether `teardown/1` ran."
  @spec torn_down?(t()) :: boolean()
  def torn_down?(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1.torn_down?)

  # --- HarmontVm.Backend callbacks ---

  @impl true
  def provision(_spec) do
    pid = Process.get(__MODULE__) || raise "StubBackend.new/1 must run before provision/1"

    case Agent.get(pid, & &1.provision) do
      :ok -> {:ok, %__MODULE__{pid: pid}}
      {:error, reason} -> {:error, {:provision_failed, reason}}
    end
  end

  @impl true
  def exec(%__MODULE__{pid: pid}, %{command: cmd}) do
    Agent.get_and_update(pid, fn s ->
      {result, rest} =
        case s.execs do
          [r | t] -> {r, t}
          [] -> {%{exit_code: 0, stdout: "", stderr: ""}, []}
        end

      {{:ok, result}, %{s | execs: rest, commands: [cmd | s.commands]}}
    end)
  end

  @impl true
  def teardown(%__MODULE__{pid: pid}) do
    Agent.update(pid, &%{&1 | torn_down?: true})
    :ok
  end

  @impl true
  def snapshot(_handle), do: {:error, {:snapshot_failed, :unsupported}}

  @impl true
  def delete_snapshot(_id), do: :ok
end

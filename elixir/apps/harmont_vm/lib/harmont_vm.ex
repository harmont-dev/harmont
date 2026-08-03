defmodule HarmontVm do
  @moduledoc """
  Pluggable VM/sandbox backend for the Harmont engine.

  `HarmontVm.Backend` is the behaviour every backend implements
  (`provision/1`, `await_ready/2`, `exec/2`, `snapshot/1`, `delete_snapshot/1`,
  `teardown/1`). Two implementations ship here:

    * `HarmontVm.Backend.Local` — dev/test backend that runs commands on the
      host in a temp dir. No real VM, no agent. NEVER use in prod.
    * `HarmontVm.Backend.Freestyle` — production backend on the Freestyle
      Sandboxes API (the `elixir/freestyle` client).
    * `HarmontVm.Backend.Runloop` — production backend on the Runloop Devbox
      API (https://api.runloop.ai), using `Req` directly. Selected in prod via
      `HARMONT_VM_BACKEND=runloop`.

  The active backend is selected via this package's own app env; the consuming
  application configures it:

      config :harmont_vm, :backend, HarmontVm.Backend.Local

      config :harmont_vm, HarmontVm.Backend.Freestyle, api_key: "..."

  Extracted from the engine's `Harmont.Engine.VmBackend*` modules
  (following the `elixir/freestyle` path-dep precedent).
  """
end

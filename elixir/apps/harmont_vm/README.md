# HarmontVm

Pluggable VM/sandbox backend for the Harmont executor.

`HarmontVm.Backend` is the behaviour every backend implements (`provision/1`,
`await_ready/2`, `exec/2`, `snapshot/1`, `delete_snapshot/1`, `teardown/1`).
Two implementations ship here:

- `HarmontVm.Backend.Local` — dev/test backend that runs commands on the host
  in a temp dir. No real VM, no agent. NEVER use in prod.
- `HarmontVm.Backend.Freestyle` — production backend on the Freestyle Sandboxes
  API (the `elixir/freestyle` client).

## Configuration

The active backend and the Freestyle client config are read from this package's
own app env; the consuming application sets them:

```elixir
config :harmont_vm, :backend, HarmontVm.Backend.Local

config :harmont_vm, HarmontVm.Backend.Freestyle, api_key: System.fetch_env!("FREESTYLE_API_KEY")
```

`HarmontVm.Backend.impl/0` returns the configured backend module.

Extracted from the executor's `Harmont.Engine.VmBackend*` modules
(following the `elixir/freestyle` path-dep precedent).

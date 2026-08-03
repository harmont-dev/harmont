import Config

# The Freestyle backend reads its client config from this package's own app
# env. In tests, inject a Req.Test plug so no network is hit.
config :harmont_vm, HarmontVm.Backend.Freestyle,
  api_key: "test-key",
  req_options: [plug: {Req.Test, FreestyleStub}]

# The Runloop backend reads its client config from this package's own app env.
# In tests, inject a Req.Test plug so no network is hit, and disable Req's
# transient retry so error-path tests are fast and deterministic.
config :harmont_vm, HarmontVm.Backend.Runloop,
  api_key: "test-key",
  req_options: [plug: {Req.Test, RunloopStub}, retry: false]

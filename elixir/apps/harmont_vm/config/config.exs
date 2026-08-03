import Config

# Default backend for this package's own test/dev runs. A real consumer (the
# engine) configures `:harmont_vm, :backend` itself.
config :harmont_vm, :backend, HarmontVm.Backend.Local

import_config "#{config_env()}.exs"

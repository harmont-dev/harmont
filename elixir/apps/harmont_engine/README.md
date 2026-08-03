# HarmontEngine

Materializes and runs each build: turns a planned pipeline into jobs on the job
VM and drives them via the in-VM `harmont-agent` over the WebSocket.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `harmont_engine` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:harmont_engine, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/harmont_engine>.

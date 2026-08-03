# HarmontWeb

The single serving edge: a Bandit/Phoenix endpoint that plugs the whole REST
API, receives GitHub webhooks, terminates the agent WebSocket, and streams job
logs over SSE.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `harmont_web` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:harmont_web, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/harmont_web>.


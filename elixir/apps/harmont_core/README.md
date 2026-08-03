# HarmontCore

The domain layer of the Harmont backend: the Ecto schema and `Harmont.Repo`,
accounts/orgs, pipelines, builds/jobs, billing, the GitHub mirror tables, Oban,
and `Phoenix.PubSub` — all owned by this app over the single Postgres database.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `harmont_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:harmont_core, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/harmont_core>.


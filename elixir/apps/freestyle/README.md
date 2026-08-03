# Freestyle (Elixir)

Production-grade Elixir client for the [Freestyle Sandboxes API](https://api.freestyle.sh).
Built on
[Req](https://hexdocs.pm/req); payloads modeled as Ecto embedded schemas;
observability via `:telemetry`.

## Install

```elixir
def deps do
  [{:freestyle, path: "../freestyle_ex"}]
end
```

## Usage

```elixir
client = Freestyle.Client.new(api_key: System.fetch_env!("FREESTYLE_API_KEY"))

{:ok, who} = Freestyle.who_am_i(client)

req = %Freestyle.Types.Vm.ExecAwaitRequest{command: "echo hi", timeout_ms: 30_000}
{:ok, result} = Freestyle.exec_command(client, "vm-123", req)
# result.stdout, result.status_code

# Bang variants raise Freestyle.Error:
vm = Freestyle.create_vm!(client, opts)

# Full API per section:
{:ok, repos_page} = Freestyle.Api.Git.list_repos(client)
repos = Freestyle.Api.Git.stream_repos(client) |> Enum.to_list()
```

## Configuration

`Freestyle.Client.new/1` options: `:api_key` (required), `:base_url`,
`:receive_timeout`, `:req_options` (inject a Finch pool or a `Req.Test` plug).
Config is explicit — the library never reads `Application` env, so multiple
independently-configured clients coexist.

### Injecting a Finch pool (optional)

```elixir
# your application.ex
children = [{Finch, name: MyApp.Finch, pools: %{default: [size: 50]}}]
# then:
client = Freestyle.Client.new(api_key: key, req_options: [finch: MyApp.Finch])
```

## Errors

Functions return `{:ok, value} | {:error, %Freestyle.Error{}}`. The error has
`:kind` (`:api | :decode | :transport`), `:status`, `:code`, `:message`, `:body`.

## Retries

Transient outcomes (HTTP 429/5xx and transport errors) are retried with
full-jitter exponential backoff (base 250 ms, cap 30 s), 4 retries — for all
methods (the executor relies on retried
`exec-await`/`snapshot`).

## Telemetry

Attach to:

  * `[:freestyle, :request, :start | :stop | :exception]`
  * `[:freestyle, :request, :retry]`

Metadata includes `:operation` (e.g. `"freestyle.vm.exec_command"`), `:method`,
`:path`, and on stop `:status`/`:error_code`. Bridge to OpenTelemetry with
`opentelemetry_telemetry`.

## Development

```bash
mix deps.get
mix check   # format --check-formatted, credo --strict, dialyzer, test
```

### Integration tests (live API)

`mix test` excludes the `:integration` tag, so it never touches the network.
The integration suite runs against the real `api.freestyle.sh` and is gated on
`FREESTYLE_API_KEY`. The helper script sources the key from Google Secret
Manager (set `GCP_PROJECT` and `FREESTYLE_SECRET_NAME`):

```bash
gcloud auth login                 # once, if your gcloud token has expired
./scripts/integration-test.sh     # fetches the key, runs `mix test --only integration`
```

Or supply the key yourself: `FREESTYLE_API_KEY=fs_... mix test --only integration`.
The suite creates and deletes real test repositories and identities; each
workflow cleans up after itself.

# GithubClient

A thin GitHub REST client for a GitHub App over Req. No application specifics —
this is a reusable library for any service that talks to the GitHub REST API as
a GitHub App.

`GithubClient` covers four endpoints, each with typed error classification:

- `create_check_run/2` — POST /repos/:owner/:repo/check-runs
- `update_check_run/2` — PATCH /repos/:owner/:repo/check-runs/:id
- `download_tarball/4` — GET /repos/:owner/:repo/tarball/:ref
- `get_file/5` — GET /repos/:owner/:repo/contents/:path?ref=…

All requests carry the GitHub v3 Accept header and `User-Agent: harmont-gh-app`.
Transient failures are retried automatically.

## Usage

```elixir
client = GithubClient.new(base_url: "https://api.github.com", token: token)
{:ok, id} = GithubClient.create_check_run(client, %{...})
```

## Testing

Pass `req_options: [plug: {Req.Test, StubName}]` to `new/1` and use
`Req.Test.stub/2` — no network required.

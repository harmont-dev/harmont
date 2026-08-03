defmodule HarmontApi.Plugs.RequestId do
  @moduledoc """
  Ensures every request carries a request id.

  In production the request flows through `harmont_web`'s endpoint, which runs
  `Plug.RequestId` before mounting `HarmontApi.Router`, so a request id and the
  `x-request-id` response header already exist. This plug is a thin guard for
  the cases where the router is exercised directly (tests, or any future
  standalone mount): if no `x-request-id` response header is present, it sets
  one and mirrors it into `Logger.metadata`.

  It is intentionally idempotent — it never overwrites an existing id.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_resp_header(conn, "x-request-id") do
      [_ | _] ->
        conn

      [] ->
        id = generate_request_id()
        Logger.metadata(request_id: id)
        put_resp_header(conn, "x-request-id", id)
    end
  end

  defp generate_request_id do
    binary = :crypto.strong_rand_bytes(15)
    Base.url_encode64(binary)
  end
end

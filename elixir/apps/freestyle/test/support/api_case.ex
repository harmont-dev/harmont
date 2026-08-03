defmodule Freestyle.ApiCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Freestyle.ApiCase
      alias Freestyle.{Client, Error}
    end
  end

  setup tags do
    stub_name = tags[:stub] || self()
    client = Freestyle.Client.new(api_key: "sk_test", req_options: [plug: {Req.Test, stub_name}])
    {:ok, client: client, stub: stub_name}
  end

  @doc "Stub the next request, asserting method/path and returning a JSON body."
  def expect_json(stub, assertions, status, body) when is_function(assertions, 1) do
    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assertions.(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  @doc "Stub a no-body 2xx (for DELETE-style endpoints)."
  def expect_empty(stub, assertions, status \\ 204) when is_function(assertions, 1) do
    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assertions.(conn)
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  @doc "Read and JSON-decode the request body inside a stub."
  def read_json(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end
end

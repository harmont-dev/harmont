defmodule Harmont.GhApp.GitHub.InstallationTokensTest do
  use ExUnit.Case, async: true
  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.GitHub.Jwt
  alias Harmont.TestSupport.Rsa

  test "caches a token until within 60s of expiry, then refreshes" do
    counter = :counters.new(1, [])

    mint = fn _inst_id ->
      :counters.add(counter, 1, 1)
      {:ok, "tok-#{:counters.get(counter, 1)}", DateTime.add(DateTime.utc_now(), 3600, :second)}
    end

    {:ok, pid} = InstallationTokens.start_link(name: nil, mint_fun: mint)

    assert {:ok, "tok-1"} = InstallationTokens.fetch(pid, 7)
    # cache hit
    assert {:ok, "tok-1"} = InstallationTokens.fetch(pid, 7)
    assert :counters.get(counter, 1) == 1
  end

  test "refreshes when cached token is near expiry" do
    counter = :counters.new(1, [])

    mint = fn _ ->
      :counters.add(counter, 1, 1)
      {:ok, "tok-#{:counters.get(counter, 1)}", DateTime.add(DateTime.utc_now(), 30, :second)}
    end

    {:ok, pid} = InstallationTokens.start_link(name: nil, mint_fun: mint)
    assert {:ok, "tok-1"} = InstallationTokens.fetch(pid, 1)
    # second fetch: cached exp is only 30s out (< 60s skew) -> must re-mint
    assert {:ok, "tok-2"} = InstallationTokens.fetch(pid, 1)
    assert :counters.get(counter, 1) == 2
  end

  describe "default production mint (App JWT -> token exchange)" do
    test "exchanges an App JWT for an installation token via the token endpoint" do
      pem = Rsa.private_pem()
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/app/installations/77/access_tokens"
        # the App JWT is sent as a Bearer token
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert {:ok, %{"iss" => "1234"}} = Jwt.peek_claims(jwt)
        Req.Test.json(conn, %{"token" => "ghs_abc", "expires_at" => expires_at})
      end)

      {:ok, pid} =
        InstallationTokens.start_link(
          name: nil,
          app_id: 1234,
          private_key_pem: pem,
          github_base_url: "https://api.github.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      # the mint runs inside the GenServer process; let it use this test's stub.
      Req.Test.allow(__MODULE__, self(), pid)

      assert {:ok, "ghs_abc"} = InstallationTokens.fetch(pid, 77)
    end

    test "returns {:error, {:http, ...}} when the token exchange fails" do
      pem = Rsa.private_pem()

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))
      end)

      {:ok, pid} =
        InstallationTokens.start_link(
          name: nil,
          app_id: 1234,
          private_key_pem: pem,
          github_base_url: "https://api.github.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      Req.Test.allow(__MODULE__, self(), pid)

      assert {:error, {:http, 401, _}} = InstallationTokens.fetch(pid, 77)
    end
  end
end

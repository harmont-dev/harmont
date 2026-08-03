defmodule Freestyle.ClientTest do
  use ExUnit.Case, async: true
  alias Freestyle.Client

  describe "new/1" do
    test "builds a client with defaults" do
      c = Client.new(api_key: "sk_test")
      assert c.api_key == "sk_test"
      assert c.base_url == "https://api.freestyle.sh"
      assert c.receive_timeout == 30_000
    end

    test "allows base_url and timeout overrides" do
      c = Client.new(api_key: "k", base_url: "http://localhost:9999", receive_timeout: 1000)
      assert c.base_url == "http://localhost:9999"
      assert c.receive_timeout == 1000
    end

    test "raises when api_key is missing" do
      assert_raise ArgumentError, ~r/api_key/, fn -> Client.new([]) end
    end
  end

  describe "req/2" do
    test "sets base_url and bearer auth" do
      c = Client.new(api_key: "sk_abc")
      req = Client.req(c, [])
      assert req.options.base_url == "https://api.freestyle.sh"
      assert req.options.auth == {:bearer, "sk_abc"}
    end

    test "merges per-request req_options" do
      c = Client.new(api_key: "k", req_options: [headers: [{"x-base", "1"}]])
      req = Client.req(c, plug: {Req.Test, :stub})
      assert req.options.plug == {Req.Test, :stub}
    end
  end
end

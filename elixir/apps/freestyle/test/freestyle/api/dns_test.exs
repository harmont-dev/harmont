defmodule Freestyle.Api.DnsTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Dns
  alias Freestyle.Types.Dns.{CreateRecordOpts, DnsRecord}

  @tag stub: __MODULE__
  test "list_records sends domain query and decodes records", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/dns/v1/records"
        assert conn.params["domain"] == "example.com"
      end,
      200,
      [%{"type" => "A", "name" => "www", "value" => "1.2.3.4", "ttl" => 3600}]
    )

    assert {:ok, [%DnsRecord{type: "A", name: "www", value: "1.2.3.4", ttl: 3600}]} =
             Dns.list_records(client, "example.com")
  end

  @tag stub: __MODULE__
  test "create_record posts {domain, record}", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        {body, _} = read_json(conn)

        assert body == %{
                 "domain" => "example.com",
                 "record" => %{"type" => "A", "name" => "www", "value" => "1.2.3.4"}
               }
      end,
      200,
      %{"type" => "A", "name" => "www", "value" => "1.2.3.4"}
    )

    record = %DnsRecord{type: "A", name: "www", value: "1.2.3.4"}

    assert {:ok, %DnsRecord{}} =
             Dns.create_record(client, %CreateRecordOpts{domain: "example.com", record: record})
  end

  @tag stub: __MODULE__
  test "delete_record sends domain + record name", %{client: client, stub: stub} do
    expect_empty(stub, fn conn ->
      assert conn.params["domain"] == "example.com"
      assert conn.params["record"] == "www"
    end)

    assert {:ok, :ok} =
             Dns.delete_record(client, "example.com", %DnsRecord{
               type: "A",
               name: "www",
               value: "x"
             })
  end
end

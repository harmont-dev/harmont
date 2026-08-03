defmodule Freestyle.Api.Dns do
  @moduledoc "DNS record endpoints."

  alias Freestyle.{Client, Error, Request, Types}
  alias Freestyle.Types.Dns.{CreateRecordOpts, DnsRecord}

  @doc "GET /dns/v1/records?domain=... — records for a domain."
  @spec list_records(Client.t(), Types.domain_name()) ::
          {:ok, [DnsRecord.t()]} | {:error, Error.t()}
  def list_records(client, domain) do
    Request.get(
      client,
      "/dns/v1/records",
      [domain: domain],
      fn body -> DnsRecord.decode_list(body) end,
      "freestyle.dns.list_records"
    )
  end

  @doc "POST /dns/v1/records — create a record."
  @spec create_record(Client.t(), CreateRecordOpts.t()) ::
          {:ok, DnsRecord.t()} | {:error, Error.t()}
  def create_record(client, %CreateRecordOpts{} = opts) do
    Request.post(
      client,
      "/dns/v1/records",
      CreateRecordOpts.encode(opts),
      &DnsRecord.decode/1,
      "freestyle.dns.create_record"
    )
  end

  @doc "DELETE /dns/v1/records?domain=...&record=<name>."
  @spec delete_record(Client.t(), Types.domain_name(), DnsRecord.t()) ::
          {:ok, :ok} | {:error, Error.t()}
  def delete_record(client, domain, %DnsRecord{name: name}) do
    Request.delete(
      client,
      "/dns/v1/records",
      [domain: domain, record: name],
      "freestyle.dns.delete_record"
    )
  end
end

defmodule Freestyle.Api.Domain do
  @moduledoc "Domain, verification, certificate, and mapping endpoints."

  alias Freestyle.{Client, Error, Request, Types}

  alias Freestyle.Types.Domain.{
    CreateMappingOpts,
    Domain,
    DomainMapping,
    Verification,
    VerifyResult
  }

  @doc "GET /domains/v1/domains."
  @spec list_domains(Client.t()) :: {:ok, [Domain.t()]} | {:error, Error.t()}
  def list_domains(client) do
    Request.get(
      client,
      "/domains/v1/domains",
      [],
      fn body -> Domain.decode_list(body) end,
      "freestyle.domain.list_domains"
    )
  end

  @doc "GET /domains/v1/verifications."
  @spec list_verifications(Client.t()) :: {:ok, [Verification.t()]} | {:error, Error.t()}
  def list_verifications(client) do
    Request.get(
      client,
      "/domains/v1/verifications",
      [],
      fn body -> Verification.decode_list(body) end,
      "freestyle.domain.list_verifications"
    )
  end

  @doc "POST /domains/v1/verifications — start verification."
  @spec create_verification(Client.t(), Types.domain_name()) ::
          {:ok, Verification.t()} | {:error, Error.t()}
  def create_verification(client, domain) do
    Request.post(
      client,
      "/domains/v1/verifications",
      %{"domain" => domain},
      &Verification.decode/1,
      "freestyle.domain.create_verification"
    )
  end

  @doc "PUT /domains/v1/verifications — check DNS config."
  @spec verify_domain(Client.t(), Types.domain_name()) ::
          {:ok, VerifyResult.t()} | {:error, Error.t()}
  def verify_domain(client, domain) do
    Request.put(
      client,
      "/domains/v1/verifications",
      %{"domain" => domain},
      &VerifyResult.decode/1,
      "freestyle.domain.verify_domain"
    )
  end

  @doc "DELETE /domains/v1/verifications?domain=..."
  @spec delete_verification(Client.t(), Types.domain_name()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_verification(client, domain) do
    Request.delete(
      client,
      "/domains/v1/verifications",
      [domain: domain],
      "freestyle.domain.delete_verification"
    )
  end

  @doc "POST /domains/v1/certs/{domain}/wildcard — provision a wildcard cert."
  @spec provision_wildcard_cert(Client.t(), Types.domain_name()) ::
          {:ok, :ok} | {:error, Error.t()}
  def provision_wildcard_cert(client, domain) do
    Request.post(
      client,
      "/domains/v1/certs/#{domain}/wildcard",
      %{},
      fn _ -> {:ok, :ok} end,
      "freestyle.domain.provision_wildcard_cert"
    )
  end

  @doc "GET /domains/v1/mappings."
  @spec list_mappings(Client.t()) :: {:ok, [DomainMapping.t()]} | {:error, Error.t()}
  def list_mappings(client) do
    Request.get(
      client,
      "/domains/v1/mappings",
      [],
      fn body -> DomainMapping.decode_list(body) end,
      "freestyle.domain.list_mappings"
    )
  end

  @doc "POST /domains/v1/mappings/{domain} — map to a deployment or VM."
  @spec create_mapping(Client.t(), Types.domain_name(), CreateMappingOpts.t()) ::
          {:ok, DomainMapping.t()} | {:error, Error.t()}
  def create_mapping(client, domain, opts) do
    Request.post(
      client,
      "/domains/v1/mappings/#{domain}",
      CreateMappingOpts.encode(opts),
      &DomainMapping.decode/1,
      "freestyle.domain.create_mapping"
    )
  end

  @doc "DELETE /domains/v1/mappings/{domain}."
  @spec delete_mapping(Client.t(), Types.domain_name()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_mapping(client, domain) do
    Request.delete(
      client,
      "/domains/v1/mappings/#{domain}",
      [],
      "freestyle.domain.delete_mapping"
    )
  end
end

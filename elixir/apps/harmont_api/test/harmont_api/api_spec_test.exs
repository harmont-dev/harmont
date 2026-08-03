defmodule HarmontApi.ApiSpecTest do
  @moduledoc """
  Structural validation of the OpenApiSpex spec.

  Proves the spec the router assembles is well-formed and codegen-friendly:
  it serializes to OpenAPI 3.0.x JSON without error, every operation carries a
  unique non-nil `operationId`, and the named schema modules (including the
  reusable `Error` envelope) are resolved into `components.schemas`. These are
  the invariants Plan 7's CLI (progenitor) + frontend (openapi-typescript)
  codegen depend on.
  """
  use ExUnit.Case, async: true

  alias OpenApiSpex.OpenApi

  setup_all do
    spec = HarmontApi.ApiSpec.spec()
    {:ok, spec: spec, map: OpenApi.to_map(spec)}
  end

  test "spec/0 returns an OpenApi struct", %{spec: spec} do
    assert %OpenApi{} = spec
  end

  test "serializes to OpenAPI 3.0.x JSON", %{map: map} do
    json = Jason.encode!(map)
    decoded = Jason.decode!(json)

    assert decoded["openapi"] =~ ~r/^3\.0\.\d+$/
    assert decoded["info"]["title"] == "Harmont API"
    assert decoded["info"]["version"] == "0"
    assert is_map(decoded["paths"]) and map_size(decoded["paths"]) > 0
    assert is_map(decoded["components"]["schemas"])
  end

  test "every operation has a present, unique operationId", %{map: map} do
    op_ids =
      for {_path, methods} <- map["paths"],
          {method, op} <- methods,
          method in ~w(get put post delete patch options head trace) do
        op_id = op["operationId"]
        assert is_binary(op_id) and op_id != "", "missing operationId on #{method} #{inspect(op)}"
        op_id
      end

    refute op_ids == []

    assert length(op_ids) == length(Enum.uniq(op_ids)),
           "operationIds are not unique: #{inspect(op_ids -- Enum.uniq(op_ids))}"
  end

  test "named schemas (including the Error envelope) land in components.schemas", %{map: map} do
    schemas = map["components"]["schemas"]

    for required <-
          ~w(Error AuthTokenResponse User CurrentUserResponse Passkey PasskeyListResponse) do
      assert Map.has_key?(schemas, required), "components.schemas missing #{required}"
    end

    # The Error envelope is the {error:{type,code,message,doc_url,request_id}} shape.
    error_props = schemas["Error"]["properties"]["error"]["properties"]

    for field <- ~w(type code message doc_url request_id) do
      assert Map.has_key?(error_props, field), "Error envelope missing #{field}"
    end
  end

  test "the Plan-4 domain schemas land in components.schemas", %{map: map} do
    schemas = map["components"]["schemas"]

    for required <-
          ~w(Organization OrganizationList Pipeline PipelineList CreatePipelineRequest
             Build BuildList CreateBuildRequest Job JobList
             LogTokenResponse) do
      assert Map.has_key?(schemas, required), "components.schemas missing #{required}"
    end
  end

  test "the Plan-4 domain operations are present with stable operationIds + tags", %{map: map} do
    op_index =
      for {_path, methods} <- map["paths"],
          {method, op} <- methods,
          method in ~w(get put post delete patch),
          into: %{} do
        {op["operationId"], op}
      end

    expected_tags = %{
      "listOrganizations" => "organizations",
      "getOrganization" => "organizations",
      "listPipelines" => "pipelines",
      "createPipeline" => "pipelines",
      "getPipeline" => "pipelines",
      "listBuilds" => "builds",
      "createBuild" => "builds",
      "getBuild" => "builds",
      "cancelBuild" => "builds",
      "getBuildLogToken" => "builds",
      "getBuildSource" => "builds",
      "listJobs" => "jobs",
      "getJob" => "jobs"
    }

    for {op_id, tag} <- expected_tags do
      assert op = op_index[op_id], "missing domain operation #{op_id}"
      assert tag in (op["tags"] || []), "#{op_id} missing tag #{tag}"
    end
  end

  test "bearer-authed domain operations declare the bearer security scheme", %{map: map} do
    op_index =
      for {_path, methods} <- map["paths"],
          {method, op} <- methods,
          method in ~w(get put post delete patch),
          into: %{} do
        {op["operationId"], op}
      end

    for op_id <- ~w(listOrganizations getOrganization listPipelines createPipeline getPipeline
                    listBuilds createBuild getBuild cancelBuild getBuildLogToken listJobs
                    getJob) do
      op = op_index[op_id]
      schemes = op["security"] |> List.flatten() |> Enum.flat_map(&Map.keys/1)
      assert "bearer" in schemes, "#{op_id} missing bearer security"
    end

    # The internal source endpoint is runner-token authed, not bearer.
    source_schemes =
      op_index["getBuildSource"]["security"] |> List.flatten() |> Enum.flat_map(&Map.keys/1)

    assert "runnerToken" in source_schemes
  end

  test "the bearer and runnerToken security schemes are declared", %{map: map} do
    schemes = map["components"]["securitySchemes"]
    assert schemes["bearer"]["type"] == "http"
    assert schemes["bearer"]["scheme"] == "bearer"
    assert schemes["runnerToken"]["type"] == "http"
    assert schemes["runnerToken"]["scheme"] == "bearer"
  end

  test "the Plan-5 billing operations are present, unique, and tagged billing", %{map: map} do
    op_index =
      for {_path, methods} <- map["paths"],
          {method, op} <- methods,
          method in ~w(get put post delete patch),
          into: %{} do
        {op["operationId"], op}
      end

    billing_op_ids =
      ~w(getBillingBalance listBillingTransactions getBillingUsage
         redeemCoupon createCheckout stripeWebhook)

    for op_id <- billing_op_ids do
      assert op = op_index[op_id], "missing billing operation #{op_id}"
      assert "billing" in (op["tags"] || []), "#{op_id} missing tag billing"
    end

    # The billing operationIds are unique among themselves (and, by the
    # whole-spec uniqueness test above, across the entire spec).
    assert length(billing_op_ids) == length(Enum.uniq(billing_op_ids))
  end

  test "billing bearer ops declare bearer; the Stripe webhook is signature-authed (no bearer)",
       %{map: map} do
    op_index =
      for {_path, methods} <- map["paths"],
          {method, op} <- methods,
          method in ~w(get put post delete patch),
          into: %{} do
        {op["operationId"], op}
      end

    for op_id <- ~w(getBillingBalance listBillingTransactions getBillingUsage
                    redeemCoupon createCheckout) do
      op = op_index[op_id]
      schemes = (op["security"] || []) |> List.flatten() |> Enum.flat_map(&Map.keys/1)
      assert "bearer" in schemes, "#{op_id} missing bearer security"
    end

    # The Stripe webhook is authenticated by the Stripe-Signature header, not a
    # Harmont bearer — its security MUST be the empty list, not a bearer scheme.
    webhook = op_index["stripeWebhook"]
    webhook_schemes = (webhook["security"] || []) |> List.flatten() |> Enum.flat_map(&Map.keys/1)

    assert webhook_schemes == [],
           "stripeWebhook must not require a bearer (Stripe-signature auth)"
  end

  test "the Plan-5 billing schemas land in components.schemas", %{map: map} do
    schemas = map["components"]["schemas"]

    for required <-
          ~w(BalanceResponse TransactionList Transaction UsageResponse
             RedeemCouponRequest RedeemCouponResponse CheckoutRequest
             CheckoutResponse StripeWebhookResponse) do
      assert Map.has_key?(schemas, required), "components.schemas missing #{required}"
    end
  end
end

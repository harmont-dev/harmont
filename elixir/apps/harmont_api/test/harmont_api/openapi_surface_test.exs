defmodule HarmontApi.OpenapiSurfaceTest do
  @moduledoc """
  Guards the public/internal split. Reads the committed specs and asserts which
  operationIds the PUBLIC spec exposes vs hides, and that the FULL spec still
  carries the hidden ops (the frontend types against it).
  """
  use ExUnit.Case, async: true

  @methods ~w(get put post delete options head patch trace)
  @priv Path.join([__DIR__, "..", "..", "priv", "static"])

  @public ~w(
    listPipelines createPipeline getPipeline
    listBuilds createBuild getBuild cancelBuild getBuildLogToken
    listJobs getJob
    listOrganizations getCurrentUser logout
    cliTransfer cliClaim cliCode cliRedeem
    getBillingBalance listBillingTransactions getBillingUsage
  )

  @hidden ~w(
    authGoogle authGithub
    passkeySignupBegin passkeySignupOptions passkeySignupFinalize
    passkeyLoginOptions passkeyLoginFinalize
    passkeyRegisterOptions passkeyRegisterFinalize
    recoverBegin recoverOptions recoverFinalize
    listPasskeys deletePasskey
    createCheckout redeemCoupon stripeWebhook
    listGithubInstallations connectGithubInstallation disconnectGithubInstallation
    listGithubInstallationRepos syncGithubInstallation
    getOrganization ping getBuildSource
  )

  # accessRequest went away with the invite-only access allowlist
  # (migration 20260609000003_remove_access_allowlist): signups are now open and
  # capped, so the request-access endpoint no longer exists in either spec.
  @deleted ~w(listGithubRepos listArtifacts renamePasskey accessRequest)

  defp op_ids(file) do
    @priv
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("paths", %{})
    |> Enum.flat_map(fn {_path, item} ->
      for m <- @methods, op = item[m], op != nil, do: op["operationId"]
    end)
    |> MapSet.new()
  end

  test "public spec exposes exactly the intended public operations" do
    public = op_ids("openapi.public.json")
    for id <- @public, do: assert(MapSet.member?(public, id), "expected #{id} in public spec")

    for id <- @hidden,
        do: refute(MapSet.member?(public, id), "#{id} must be hidden from public spec")

    for id <- @deleted, do: refute(MapSet.member?(public, id), "#{id} must be deleted")
  end

  test "no public operation carries the x-internal marker" do
    spec = @priv |> Path.join("openapi.public.json") |> File.read!() |> Jason.decode!()

    for {_path, item} <- spec["paths"], m <- @methods, op = item[m], op != nil do
      refute Map.has_key?(op, "x-internal"),
             "x-internal leaked into public op #{op["operationId"]}"
    end
  end

  test "full spec still carries the hidden ops (frontend) but not the deleted ones" do
    full = op_ids("openapi.json")

    for id <- @hidden,
        do: assert(MapSet.member?(full, id), "#{id} must stay in full spec for the frontend")

    for id <- @deleted,
        do: refute(MapSet.member?(full, id), "#{id} must be deleted from full spec too")
  end
end

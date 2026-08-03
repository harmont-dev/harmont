defmodule HarmontApi.BillingTest do
  @moduledoc """
  End-to-end tests for the org-scoped billing read endpoints (balance,
  transactions, usage).

  The bearer plug, the `OrgScope` tenancy plug, cursor pagination, and the
  `Harmont.Billing` core context all run for real against Postgres. The Stripe
  boundary is irrelevant here (read endpoints make no Stripe calls), but the
  test suite uses `HarmontApi.StripeFake` globally regardless.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Billing
  alias Harmont.Billing.Coupon
  alias Harmont.Billing.StripeCheckoutSession
  alias Harmont.Billing.VmLease
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Orgs
  alias Harmont.Pipelines.Pipeline

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp member_org(name, slug, user) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    {:ok, _} = Orgs.add_member(org, user, :member, Repo)
    org
  end

  defp credit(org, cents, source \\ :admin_grant) do
    {:ok, entry} =
      Billing.insert_entry(%{organization_id: org.id, amount_cents: cents, source: source}, Repo)

    entry
  end

  defp lease!(org, started_at, attrs) do
    base = %{
      organization_id: org.id,
      cpu_count: 1,
      memory_gb: 1,
      disk_gb: 1,
      started_at: started_at,
      duration_seconds: 60
    }

    {:ok, lease} = Repo.insert(VmLease.changeset(%VmLease{}, Map.merge(base, attrs)))
    lease
  end

  defp pipeline!(org, slug) do
    {:ok, pipeline} =
      Repo.insert(
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "Pipeline #{slug}",
          slug: slug,
          repository: "org/repo",
          default_branch: "main"
        })
      )

    pipeline
  end

  defp build!(pipeline, number) do
    {:ok, build} =
      Repo.insert(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          pipeline_id: pipeline.id,
          number: number,
          state: "passed"
        })
      )

    build
  end

  defp job!(build, name, vm_handle) do
    {:ok, job} =
      Repo.insert(
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "step-#{System.unique_integer([:positive])}",
          command: "echo hi",
          state: "passed",
          name: name,
          vm_handle: vm_handle
        })
      )

    job
  end

  defp coupon!(user, attrs) do
    base = %{
      code: "WELCOME",
      credit_cents: 1000,
      max_redemptions: 5,
      created_by_user_id: user.id
    }

    {:ok, coupon} = Repo.insert(Coupon.changeset(%Coupon{}, Map.merge(base, attrs)))
    coupon
  end

  defp req(method, path, opts) do
    conn =
      method
      |> Plug.Test.conn(path, "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()

    # Mirror the build-create router-test convention: set `body_params` and
    # merge it into `params` ourselves (no JSON decoder runs in the bare router).
    conn =
      case Keyword.get(opts, :body) do
        nil -> conn
        body -> %{conn | body_params: body, params: Map.merge(conn.params, body)}
      end

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp get_json(path, opts \\ []), do: req(:get, path, opts)
  defp post_json(path, opts), do: req(:post, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # GET /billing/balance/:org
  # ---------------------------------------------------------------------------

  describe "GET /billing/balance/:org" do
    test "returns the sum of the org's ledger entries" do
      user = create_user("bal@harmont.dev")
      org = member_org("Acme", "acme", user)
      credit(org, 1000)
      credit(org, 500)
      credit(org, -200, :vm_lease_debit)

      conn = get_json("/api/v0/billing/balance/acme", bearer: bearer_for(user))
      assert conn.status == 200
      assert decode(conn) == %{"balance_cents" => 1300}
    end

    test "zero for an org with no entries" do
      user = create_user("bal0@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn = get_json("/api/v0/billing/balance/acme", bearer: bearer_for(user))
      assert decode(conn) == %{"balance_cents" => 0}
    end

    test "non-member org -> 404" do
      user = create_user("balout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn = get_json("/api/v0/billing/balance/acme", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn = get_json("/api/v0/billing/balance/acme")
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # GET /billing/transactions/:org
  # ---------------------------------------------------------------------------

  describe "GET /billing/transactions/:org" do
    test "lists entries newest-first with pagination shape" do
      user = create_user("tx@harmont.dev")
      org = member_org("Acme", "acme", user)
      e1 = credit(org, 100)
      e2 = credit(org, 200)
      e3 = credit(org, 300)

      conn = get_json("/api/v0/billing/transactions/acme", bearer: bearer_for(user))
      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "data")
      assert Map.has_key?(body, "next_cursor")

      ids = Enum.map(body["data"], & &1["id"])
      assert ids == [e3.id, e2.id, e1.id]
      assert is_nil(body["next_cursor"])

      first = hd(body["data"])
      assert first["amount_cents"] == 300
      assert first["source"] == "admin_grant"
      assert is_binary(first["created_at"])
    end

    test "respects limit and returns a cursor; second page resumes newest-first" do
      user = create_user("txpage@harmont.dev")
      org = member_org("Acme", "acme", user)
      _e1 = credit(org, 100)
      e2 = credit(org, 200)
      e3 = credit(org, 300)

      conn = get_json("/api/v0/billing/transactions/acme?limit=2", bearer: bearer_for(user))
      body = decode(conn)
      assert Enum.map(body["data"], & &1["id"]) == [e3.id, e2.id]
      assert is_binary(body["next_cursor"])

      conn2 =
        get_json("/api/v0/billing/transactions/acme?limit=2&cursor=#{body["next_cursor"]}",
          bearer: bearer_for(user)
        )

      body2 = decode(conn2)
      assert length(body2["data"]) == 1
      assert is_nil(body2["next_cursor"])
    end

    test "only the scoped org's entries appear" do
      user = create_user("txiso@harmont.dev")
      org = member_org("Acme", "acme", user)
      other = member_org("Other", "other", user)
      credit(org, 100)
      credit(other, 999)

      conn = get_json("/api/v0/billing/transactions/acme", bearer: bearer_for(user))
      data = decode(conn)["data"]
      assert length(data) == 1
      assert hd(data)["amount_cents"] == 100
    end

    test "non-member org -> 404" do
      user = create_user("txout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn = get_json("/api/v0/billing/transactions/acme", bearer: bearer_for(user))
      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /billing/usage/:org?from=&to=
  # ---------------------------------------------------------------------------

  describe "GET /billing/usage/:org" do
    test "aggregates leases within the window" do
      user = create_user("use@harmont.dev")
      org = member_org("Acme", "acme", user)

      lease!(org, ~U[2026-01-10 00:00:00Z], %{
        cpu_count: 2,
        memory_gb: 4,
        disk_gb: 20,
        duration_seconds: 3600
      })

      lease!(org, ~U[2026-01-20 00:00:00Z], %{
        cpu_count: 1,
        memory_gb: 1,
        disk_gb: 1,
        duration_seconds: 60
      })

      # Outside the window — excluded.
      lease!(org, ~U[2026-03-01 00:00:00Z], %{cpu_count: 9, duration_seconds: 9999})

      conn =
        get_json(
          "/api/v0/billing/usage/acme?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      body = decode(conn)
      assert body["cpu_seconds"] == 2 * 3600 + 1 * 60
      assert body["memory_gb_seconds"] == 4 * 3600 + 1 * 60
      assert body["disk_gb_seconds"] == 20 * 3600 + 1 * 60
      assert is_integer(body["total_cents"])
      assert body["total_cents"] > 0
    end

    test "empty window -> all zeros" do
      user = create_user("use0@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        get_json(
          "/api/v0/billing/usage/acme?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 200

      assert decode(conn) == %{
               "cpu_seconds" => 0,
               "memory_gb_seconds" => 0,
               "disk_gb_seconds" => 0,
               "total_cents" => 0
             }
    end

    test "missing from/to -> 422" do
      user = create_user("usebad@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn = get_json("/api/v0/billing/usage/acme", bearer: bearer_for(user))
      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "billing_usage_window_invalid"
    end

    test "invalid timestamp -> 422" do
      user = create_user("usebad2@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        get_json("/api/v0/billing/usage/acme?from=nonsense&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "billing_usage_window_invalid"
    end

    test "to <= from (inverted/empty window) -> 422" do
      user = create_user("usebad3@harmont.dev")
      _org = member_org("Acme", "acme", user)

      # Inverted: to before from.
      inverted =
        get_json("/api/v0/billing/usage/acme?from=2026-02-01T00:00:00Z&to=2026-01-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert inverted.status == 422
      assert decode(inverted)["error"]["code"] == "billing_usage_window_invalid"

      # Empty: to == from. The window is half-open, so this is also rejected.
      empty =
        get_json("/api/v0/billing/usage/acme?from=2026-01-01T00:00:00Z&to=2026-01-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert empty.status == 422
      assert decode(empty)["error"]["code"] == "billing_usage_window_invalid"
    end

    test "non-member org -> 404" do
      user = create_user("useout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn =
        get_json(
          "/api/v0/billing/usage/acme?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /billing/usage/:org/series?from=&to=
  # ---------------------------------------------------------------------------

  describe "GET /billing/usage/:org/series" do
    test "returns per-day buckets" do
      user = create_user("series@example.com")
      org = member_org("Acme", "acme", user)

      lease!(org, ~U[2026-01-01 08:00:00Z], %{
        cpu_count: 2,
        memory_gb: 4,
        disk_gb: 20,
        duration_seconds: 3600
      })

      lease!(org, ~U[2026-01-02 12:00:00Z], %{
        cpu_count: 1,
        memory_gb: 1,
        disk_gb: 1,
        duration_seconds: 60
      })

      from = "2026-01-01T00:00:00Z"
      to = "2026-01-03T00:00:00Z"

      conn =
        get_json("/api/v0/billing/usage/#{org.slug}/series?from=#{from}&to=#{to}",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      body = decode(conn)
      assert is_list(body["data"])
      assert length(body["data"]) == 3
      first = hd(body["data"])
      assert first["date"] == "2026-01-01"
      assert Map.has_key?(first, "total_cents")
      assert Map.has_key?(first, "cpu_seconds")
    end

    test "rejects a non-increasing window with 422" do
      user = create_user("series422@example.com")
      org = member_org("Acme", "acme", user)

      conn =
        get_json(
          "/api/v0/billing/usage/#{org.slug}/series?from=2026-02-02T00:00:00Z&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "billing_usage_window_invalid"
    end
  end

  # ---------------------------------------------------------------------------
  # GET /billing/usage/:org/breakdown?from=&to=
  # ---------------------------------------------------------------------------

  describe "GET /billing/usage/:org/breakdown" do
    test "returns per-build groups with per-job lease detail" do
      user = create_user("breakdown@example.com")
      org = member_org("Acme", "acme", user)
      pipeline = pipeline!(org, "breakdown-pipe")
      build = build!(pipeline, 42)
      job_a = job!(build, "build", "vm-aaa")
      job_b = job!(build, "test", "vm-bbb")

      lease_attrs = fn job ->
        %{
          organization_id: org.id,
          job_id: job.id,
          pipeline_id: pipeline.id,
          cpu_count: 2,
          memory_gb: 4,
          disk_gb: 20,
          started_at: ~U[2026-06-06 10:00:00Z],
          finished_at: ~U[2026-06-06 10:05:00Z],
          duration_seconds: 300
        }
      end

      assert {:ok, %{lease: _, entry: _}} = Billing.record_lease(lease_attrs.(job_a), Repo)
      assert {:ok, %{lease: _, entry: _}} = Billing.record_lease(lease_attrs.(job_b), Repo)

      from = "2026-06-06T00:00:00Z"
      to = "2026-06-07T00:00:00Z"

      conn =
        get_json("/api/v0/billing/usage/acme/breakdown?from=#{from}&to=#{to}",
          bearer: bearer_for(user)
        )

      assert conn.status == 200
      body = decode(conn)
      assert is_list(body["data"])

      assert [first | _] = body["data"]
      assert is_integer(first["total_cents"])
      assert is_list(first["jobs"])
      assert first["job_count"] == length(first["jobs"])
    end

    test "inverted window -> 422 billing_usage_window_invalid" do
      user = create_user("breakdown422@example.com")
      _org = member_org("Acme", "acme", user)

      conn =
        get_json(
          "/api/v0/billing/usage/acme/breakdown?from=2026-02-01T00:00:00Z&to=2026-01-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "billing_usage_window_invalid"
    end

    test "non-member org -> 404" do
      user = create_user("breakdownout@example.com")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn =
        get_json(
          "/api/v0/billing/usage/acme/breakdown?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z",
          bearer: bearer_for(user)
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn =
        get_json(
          "/api/v0/billing/usage/acme/breakdown?from=2026-01-01T00:00:00Z&to=2026-02-01T00:00:00Z"
        )

      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # POST /billing/coupon/redeem/:org
  # ---------------------------------------------------------------------------

  describe "POST /billing/coupon/redeem/:org" do
    test "valid coupon -> 200 with credit and resulting balance" do
      user = create_user("rc@harmont.dev")
      org = member_org("Acme", "acme", user)
      coupon!(user, %{code: "WELCOME", credit_cents: 1500})

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "WELCOME"}
        )

      assert conn.status == 200
      assert decode(conn) == %{"credit_cents" => 1500, "balance_cents" => 1500}

      # The ledger reflects the credit.
      assert Billing.balance(org.id, Repo) == 1500
    end

    test "credit adds to an existing balance" do
      user = create_user("rcbal@harmont.dev")
      org = member_org("Acme", "acme", user)
      credit(org, 400)
      coupon!(user, %{code: "WELCOME", credit_cents: 600})

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "WELCOME"}
        )

      assert conn.status == 200
      assert decode(conn) == %{"credit_cents" => 600, "balance_cents" => 1000}
    end

    test "second redeem of the same coupon by the same org -> 409 already_claimed" do
      user = create_user("rcdup@harmont.dev")
      org = member_org("Acme", "acme", user)
      coupon!(user, %{code: "WELCOME", credit_cents: 1000})

      conn1 =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "WELCOME"}
        )

      assert conn1.status == 200

      conn2 =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "WELCOME"}
        )

      assert conn2.status == 409
      assert decode(conn2)["error"]["code"] == "coupon_already_claimed"

      # The credit was posted only once.
      assert Billing.balance(org.id, Repo) == 1000
    end

    test "unknown code -> 404 coupon_not_found" do
      user = create_user("rc404@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "NOPE"}
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "coupon_not_found"
    end

    test "expired coupon -> 422 coupon_expired" do
      user = create_user("rcexp@harmont.dev")
      _org = member_org("Acme", "acme", user)

      coupon!(user, %{
        code: "OLD",
        credit_cents: 1000,
        expires_at: ~U[2020-01-01 00:00:00.000000Z]
      })

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "OLD"}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "coupon_expired"
    end

    test "exhausted coupon -> 422 coupon_exhausted" do
      user = create_user("rcex@harmont.dev")
      _org = member_org("Acme", "acme", user)

      coupon!(user, %{
        code: "GONE",
        credit_cents: 1000,
        max_redemptions: 1,
        redemptions_used: 1
      })

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "GONE"}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "coupon_exhausted"
    end

    test "non-member org -> 404 organization_not_found" do
      user = create_user("rcout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)
      coupon!(user, %{code: "WELCOME", credit_cents: 1000})

      conn =
        post_json("/api/v0/billing/coupon/redeem/acme",
          bearer: bearer_for(user),
          body: %{"code" => "WELCOME"}
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn = post_json("/api/v0/billing/coupon/redeem/acme", body: %{"code" => "WELCOME"})
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # POST /billing/checkout/:org
  # ---------------------------------------------------------------------------

  describe "POST /billing/checkout/:org" do
    # Force a checkout error branch in the Stripe fake for the duration of the
    # test, restoring the default success behaviour afterwards.
    defp with_fake_checkout(response, fun) do
      Application.put_env(:harmont_api, :stripe_fake_checkout, response)
      on_exit(fn -> Application.delete_env(:harmont_api, :stripe_fake_checkout) end)
      fun.()
    end

    test "valid amount -> 200 with checkout_url and an :open session row" do
      user = create_user("co@harmont.dev")
      org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/billing/checkout/acme",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 5000}
        )

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["checkout_url"])

      session = Repo.one(StripeCheckoutSession)
      assert session.organization_id == org.id
      assert session.initiated_by_user_id == user.id
      assert session.amount_cents == 5000
      assert session.status == :open
      assert is_binary(session.session_id)
      # The recorded session id matches what the checkout URL was minted from.
      assert String.contains?(body["checkout_url"], session.session_id)
    end

    test "amount of 0 -> 422 invalid_amount; no session recorded" do
      user = create_user("co0@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/billing/checkout/acme",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 0}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "invalid_amount"
      assert Repo.aggregate(StripeCheckoutSession, :count) == 0
    end

    test "negative amount -> 422 invalid_amount" do
      user = create_user("coneg@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/billing/checkout/acme",
          bearer: bearer_for(user),
          body: %{"amount_cents" => -100}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "invalid_amount"
    end

    test "absurdly large amount -> 422 invalid_amount" do
      user = create_user("cohuge@harmont.dev")
      _org = member_org("Acme", "acme", user)

      conn =
        post_json("/api/v0/billing/checkout/acme",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 999_999_999}
        )

      assert conn.status == 422
      assert decode(conn)["error"]["code"] == "invalid_amount"
    end

    test "provider missing config -> 503 billing_unconfigured" do
      user = create_user("cocfg@harmont.dev")
      _org = member_org("Acme", "acme", user)

      with_fake_checkout(:unconfigured, fn ->
        conn =
          post_json("/api/v0/billing/checkout/acme",
            bearer: bearer_for(user),
            body: %{"amount_cents" => 5000}
          )

        assert conn.status == 503
        assert decode(conn)["error"]["code"] == "billing_unconfigured"
        assert Repo.aggregate(StripeCheckoutSession, :count) == 0
      end)
    end

    test "provider failure -> 502 billing_provider_error" do
      user = create_user("coprov@harmont.dev")
      _org = member_org("Acme", "acme", user)

      with_fake_checkout(:provider, fn ->
        conn =
          post_json("/api/v0/billing/checkout/acme",
            bearer: bearer_for(user),
            body: %{"amount_cents" => 5000}
          )

        assert conn.status == 502
        assert decode(conn)["error"]["code"] == "billing_provider_error"
        assert Repo.aggregate(StripeCheckoutSession, :count) == 0
      end)
    end

    test "non-member org -> 404 organization_not_found" do
      user = create_user("coout@harmont.dev")
      {:ok, _org} = Orgs.create_org(%{name: "Secret", slug: "acme"}, Repo)

      conn =
        post_json("/api/v0/billing/checkout/acme",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 5000}
        )

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      conn = post_json("/api/v0/billing/checkout/acme", body: %{"amount_cents" => 5000})
      assert conn.status == 401
    end
  end

  describe "POST /billing/checkout/:org — Stripe customer" do
    test "creates and persists a Stripe customer on first checkout, reuses it after" do
      user = create_user("cust@harmont.dev")
      org = member_org("Cust Co", "cust-org", user)

      assert org.stripe_customer_id == nil

      conn1 =
        post_json("/api/v0/billing/checkout/cust-org",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 5000}
        )

      assert conn1.status == 200
      assert is_binary(decode(conn1)["checkout_url"])

      reloaded = Repo.reload!(org)
      assert reloaded.stripe_customer_id =~ ~r/^cus_test_/

      # The persisted customer id is actually threaded into the Stripe session,
      # not just stored on the org.
      assert Process.get(:stripe_fake_last_checkout)[:customer] == reloaded.stripe_customer_id

      conn2 =
        post_json("/api/v0/billing/checkout/cust-org",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 2500}
        )

      assert conn2.status == 200
      assert is_binary(decode(conn2)["checkout_url"])
      assert Repo.reload!(org).stripe_customer_id == reloaded.stripe_customer_id
    end

    test "still succeeds when customer creation fails (degraded, anonymous session)" do
      Application.put_env(:harmont_api, :stripe_fake_customer, :provider)
      on_exit(fn -> Application.delete_env(:harmont_api, :stripe_fake_customer) end)

      user = create_user("cust-degraded@harmont.dev")
      org = member_org("Cust Degraded", "cust-org-degraded", user)

      conn =
        post_json("/api/v0/billing/checkout/cust-org-degraded",
          bearer: bearer_for(user),
          body: %{"amount_cents" => 5000}
        )

      assert conn.status == 200
      assert is_binary(decode(conn)["checkout_url"])
      assert Repo.reload!(org).stripe_customer_id == nil

      # Degraded path: no customer was attached to the session.
      refute Map.has_key?(Process.get(:stripe_fake_last_checkout), :customer)
    end
  end
end

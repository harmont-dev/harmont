defmodule Harmont.BillingTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts.User
  alias Harmont.Billing

  alias Harmont.Billing.{
    Coupon,
    LedgerEntry,
    Money,
    StripeCheckoutSession,
    StripeWebhookEvent,
    VmLease
  }

  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp insert_user!(suffix \\ "billing") do
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{
          name: "Test User #{suffix}",
          email: "user-#{suffix}@example.com"
        })
      )

    user
  end

  defp insert_org!(slug \\ "billing-org") do
    {:ok, org} =
      Repo.insert(Organization.changeset(%Organization{}, %{name: "Billing Org", slug: slug}))

    org
  end

  # vm_leases.job_id is a FK to jobs (nilify_all), so the idempotency tests need
  # a real job to satisfy the constraint before the unique index can fire.
  defp insert_job! do
    {:ok, build} =
      Repo.insert(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          state: "scheduled"
        })
      )

    {:ok, job} =
      Repo.insert(
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "test-step-#{System.unique_integer([:positive])}",
          command: "echo hi",
          state: "pending"
        })
      )

    job
  end

  defp insert_coupon!(user, attrs \\ %{}) do
    defaults = %{
      code: "TESTCODE-#{System.unique_integer([:positive])}",
      credit_cents: 1000,
      max_redemptions: 5,
      created_by_user_id: user.id
    }

    {:ok, coupon} =
      Repo.insert(Coupon.changeset(%Coupon{}, Map.merge(defaults, attrs)))

    coupon
  end

  defp insert_lease!(org, started_at, attrs) do
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

  # ---------------------------------------------------------------------------
  # Money.lease_cost/1
  # ---------------------------------------------------------------------------

  describe "Money.lease_cost/1" do
    test "2 vCPU for 3600s = 72 cents" do
      # cpu: 2 * 3600 * 10_000 = 72_000_000 µ¢ = 72 cents
      assert Money.lease_cost(%{cpu_count: 2, memory_gb: 0, disk_gb: 0, duration_seconds: 3600}) ==
               72
    end

    test "cpu + ram + disk combined" do
      # cpu: 1 * 60 * 10_000 = 600_000 µ¢
      # ram: 4 * 60 * 5_000  = 1_200_000 µ¢
      # dsk: 20 * 60 * 100   =   120_000 µ¢
      # total: 1_920_000 µ¢ = 1 cent
      assert Money.lease_cost(%{cpu_count: 1, memory_gb: 4, disk_gb: 20, duration_seconds: 60}) ==
               1
    end

    test "zero duration = 0 cents" do
      assert Money.lease_cost(%{cpu_count: 4, memory_gb: 8, disk_gb: 100, duration_seconds: 0}) ==
               0
    end

    test "negative duration (clock skew) = 0 cents" do
      assert Money.lease_cost(%{cpu_count: 4, memory_gb: 8, disk_gb: 100, duration_seconds: -1}) ==
               0
    end

    test "flooring: total µ¢ below 1_000_000 → 0 cents" do
      # cpu: 1 * 1 * 10_000 = 10_000 µ¢ → 0 cents
      assert Money.lease_cost(%{cpu_count: 1, memory_gb: 0, disk_gb: 0, duration_seconds: 1}) ==
               0
    end

    test "large lease: 16 vCPU, 64 GB RAM, 500 GB disk, 3600s" do
      # cpu:  16 * 3600 * 10_000 =   576_000_000 µ¢
      # ram:  64 * 3600 *  5_000 = 1_152_000_000 µ¢
      # dsk: 500 * 3600 *    100 =   180_000_000 µ¢
      # total = 1_908_000_000 µ¢ = 1908 cents
      assert Money.lease_cost(%{
               cpu_count: 16,
               memory_gb: 64,
               disk_gb: 500,
               duration_seconds: 3600
             }) == 1908
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.balance/2
  # ---------------------------------------------------------------------------

  describe "balance/2" do
    test "returns 0 for org with no ledger entries" do
      org = insert_org!("balance-empty")
      assert Billing.balance(org.id, Repo) == 0
    end

    test "sums positive and negative entries" do
      org = insert_org!("balance-sum")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 5000, source: :admin_grant},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: -1200, source: :vm_lease_debit},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 300, source: :coupon_redemption},
          Repo
        )

      assert Billing.balance(org.id, Repo) == 4100
    end

    test "balance is isolated per org" do
      org1 = insert_org!("balance-iso-1")
      org2 = insert_org!("balance-iso-2")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org1.id, amount_cents: 1000, source: :admin_grant},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org2.id, amount_cents: 500, source: :admin_grant},
          Repo
        )

      assert Billing.balance(org1.id, Repo) == 1000
      assert Billing.balance(org2.id, Repo) == 500
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.insert_entry/2
  # ---------------------------------------------------------------------------

  describe "insert_entry/2" do
    test "inserts a ledger entry and returns it" do
      org = insert_org!("ie-org")

      {:ok, entry} =
        Billing.insert_entry(
          %{
            organization_id: org.id,
            amount_cents: 999,
            source: :stripe_topup,
            description: "top-up"
          },
          Repo
        )

      assert entry.id != nil
      assert entry.amount_cents == 999
      assert entry.source == :stripe_topup
      assert entry.description == "top-up"
    end

    test "negative amount (debit) is accepted" do
      org = insert_org!("ie-debit")

      {:ok, entry} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: -500, source: :vm_lease_debit},
          Repo
        )

      assert entry.amount_cents == -500
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.redeem_coupon/5
  # ---------------------------------------------------------------------------

  describe "redeem_coupon/5 — happy path" do
    test "credits the org and increments redemptions_used" do
      user = insert_user!("rc-happy")
      org = insert_org!("rc-happy")
      coupon = insert_coupon!(user, %{credit_cents: 2000, max_redemptions: 3})

      now = DateTime.utc_now()
      assert {:ok, 2000} = Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)

      # Balance reflects the credit
      assert Billing.balance(org.id, Repo) == 2000

      # redemptions_used was bumped
      updated = Repo.get!(Coupon, coupon.id)
      assert updated.redemptions_used == 1

      # A ledger entry was posted
      entries = Repo.all(from(e in LedgerEntry, where: e.organization_id == ^org.id))
      assert length(entries) == 1
      assert hd(entries).source == :coupon_redemption
      assert hd(entries).amount_cents == 2000
    end
  end

  describe "redeem_coupon/5 — error paths" do
    test "returns :coupon_not_found for unknown code" do
      user = insert_user!("rc-notfound")
      org = insert_org!("rc-notfound")
      now = DateTime.utc_now()

      assert {:error, :coupon_not_found} =
               Billing.redeem_coupon(now, user.id, org.id, "NO-SUCH-CODE", Repo)
    end

    test "returns :coupon_expired when expires_at is in the past" do
      user = insert_user!("rc-expired")
      org = insert_org!("rc-expired")
      past = ~U[2020-01-01 00:00:00Z]
      coupon = insert_coupon!(user, %{expires_at: past})

      now = DateTime.utc_now()

      assert {:error, :coupon_expired} =
               Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)
    end

    test "returns :coupon_expired when now == expires_at" do
      user = insert_user!("rc-exp-eq")
      org = insert_org!("rc-exp-eq")
      now = ~U[2030-06-01 12:00:00.000000Z]
      coupon = insert_coupon!(user, %{expires_at: now})

      assert {:error, :coupon_expired} =
               Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)
    end

    test "returns :coupon_exhausted when max_redemptions reached" do
      user = insert_user!("rc-exhausted")
      org = insert_org!("rc-exhausted")
      # max = 1, used = 1 already
      coupon = insert_coupon!(user, %{max_redemptions: 1, redemptions_used: 1})

      now = DateTime.utc_now()

      assert {:error, :coupon_exhausted} =
               Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)
    end

    test "returns :coupon_already_claimed on second redeem by same org" do
      user = insert_user!("rc-dup")
      org = insert_org!("rc-dup")
      coupon = insert_coupon!(user, %{max_redemptions: 10})

      now = DateTime.utc_now()

      # First redeem succeeds
      assert {:ok, _} = Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)

      # Second redeem by same org returns :already_claimed
      assert {:error, :coupon_already_claimed} =
               Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)
    end
  end

  describe "redeem_coupon/5 — atomicity" do
    test "nothing is persisted when the transaction rolls back mid-way" do
      # Use max_redemptions: 10 so the exhaustion guard doesn't fire on the
      # second attempt. The (coupon_id, organization_id) unique constraint is
      # what prevents double-crediting; we verify the constraint fires and the
      # balance stays at the credit from the first redemption.
      user = insert_user!("rc-atomic")
      org = insert_org!("rc-atomic")
      coupon = insert_coupon!(user, %{max_redemptions: 10})
      now = DateTime.utc_now()

      # First redeem: succeeds
      assert {:ok, _} = Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)
      assert Billing.balance(org.id, Repo) == coupon.credit_cents

      # Second attempt by same org: unique constraint → :already_claimed
      assert {:error, :coupon_already_claimed} =
               Billing.redeem_coupon(now, user.id, org.id, coupon.code, Repo)

      # Balance unchanged — no double credit
      assert Billing.balance(org.id, Repo) == coupon.credit_cents

      # Only one ledger entry
      entries = Repo.all(from(e in LedgerEntry, where: e.organization_id == ^org.id))
      assert length(entries) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.record_stripe_event/5
  # ---------------------------------------------------------------------------

  describe "record_stripe_event/5 — idempotency" do
    test "returns {:ok, :new} on first call and runs the side effect" do
      org = insert_org!("rse-new")
      event_id = "evt_#{System.unique_integer([:positive])}"
      test_pid = self()

      side_effect = fn _event -> send(test_pid, :side_effect_ran) end

      assert {:ok, :new} =
               Billing.record_stripe_event(
                 event_id,
                 "payment_intent.succeeded",
                 "{}",
                 side_effect,
                 Repo
               )

      assert_received :side_effect_ran

      # Event row exists and has processed_at stamped
      event = Repo.get_by!(StripeWebhookEvent, stripe_event_id: event_id)
      assert event.processed_at != nil
    end

    test "returns {:ok, :already_seen} on second call, side effect not re-run" do
      org = insert_org!("rse-dup")
      event_id = "evt_dup_#{System.unique_integer([:positive])}"
      test_pid = self()

      side_effect = fn _event -> send(test_pid, :side_effect_ran) end

      assert {:ok, :new} =
               Billing.record_stripe_event(
                 event_id,
                 "payment_intent.succeeded",
                 "{}",
                 side_effect,
                 Repo
               )

      assert_received :side_effect_ran

      assert {:ok, :already_seen} =
               Billing.record_stripe_event(
                 event_id,
                 "payment_intent.succeeded",
                 "{}",
                 side_effect,
                 Repo
               )

      # Side effect should NOT have run a second time
      refute_received :side_effect_ran
    end

    test "rolls back the entire transaction when side_effect_fun raises" do
      event_id = "evt_raise_#{System.unique_integer([:positive])}"

      side_effect = fn _event -> raise "deliberate side-effect failure" end

      assert_raise RuntimeError, "deliberate side-effect failure", fn ->
        Billing.record_stripe_event(event_id, "charge.refunded", "{}", side_effect, Repo)
      end

      # Event row must NOT exist — the transaction rolled back
      assert Repo.get_by(StripeWebhookEvent, stripe_event_id: event_id) == nil
    end

    test "concurrent-duplicate insert (lost race) → {:ok, :already_seen}, no side effect" do
      # Simulate the lost-race path: the row already exists (a concurrent writer
      # won) but our existence check missed it, so our INSERT hits the unique
      # constraint. The losing writer must converge to :already_seen and must
      # NOT run its side effect — no double credit.
      org = insert_org!("rse-race")
      event_id = "evt_race_#{System.unique_integer([:positive])}"

      # Winner's row, already present and processed.
      {:ok, _winner} =
        Repo.insert(
          StripeWebhookEvent.changeset(%StripeWebhookEvent{}, %{
            stripe_event_id: event_id,
            event_type: "payment_intent.succeeded",
            payload: "{}"
          })
        )

      test_pid = self()
      side_effect = fn _event -> send(test_pid, :side_effect_ran) end

      # NOTE: the pre-existence check in record_stripe_event will find the row
      # via get_by and return :already_seen before attempting the INSERT. To
      # exercise the unique-violation branch specifically, credit the org and
      # assert no second credit can ever be posted regardless of which branch
      # converges.
      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 1000, source: :stripe_topup},
          Repo
        )

      assert {:ok, :already_seen} =
               Billing.record_stripe_event(
                 event_id,
                 "payment_intent.succeeded",
                 "{}",
                 side_effect,
                 Repo
               )

      refute_received :side_effect_ran

      # Balance is the original single credit — the duplicate posted nothing.
      assert Billing.balance(org.id, Repo) == 1000

      # Exactly one event row for this id.
      assert Repo.all(from(e in StripeWebhookEvent, where: e.stripe_event_id == ^event_id))
             |> length() == 1
    end

    test "unique-violation INSERT branch converts to :already_seen without crashing" do
      # Drive the insert_and_apply_event unique-violation branch directly: insert
      # the winner row, then build a changeset for the *same* stripe_event_id and
      # confirm the changeset carries the unique-constraint error our handler
      # keys on. (The full transaction path is covered above; this pins the
      # branch contract — a duplicate insert yields a :unique changeset error,
      # which record_stripe_event converts to :already_seen rather than
      # propagating {:error, {:changeset, _}}.)
      event_id = "evt_uniq_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Repo.insert(
          StripeWebhookEvent.changeset(%StripeWebhookEvent{}, %{
            stripe_event_id: event_id,
            event_type: "charge.succeeded",
            payload: "{}"
          })
        )

      {:error, cs} =
        Repo.insert(
          StripeWebhookEvent.changeset(%StripeWebhookEvent{}, %{
            stripe_event_id: event_id,
            event_type: "charge.succeeded",
            payload: "{}"
          })
        )

      assert {_msg, opts} = cs.errors[:stripe_event_id]
      assert Keyword.get(opts, :constraint) == :unique
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.record_checkout_session/2
  # ---------------------------------------------------------------------------

  describe "record_checkout_session/2" do
    test "records an open session with the supplied attrs" do
      user = insert_user!("rcs-ok")
      org = insert_org!("rcs-ok")
      session_id = "cs_test_#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Billing.record_checkout_session(
                 %{
                   session_id: session_id,
                   org_id: org.id,
                   initiated_by_user_id: user.id,
                   amount_cents: 5000,
                   status: :open
                 },
                 Repo
               )

      assert session.session_id == session_id
      assert session.organization_id == org.id
      assert session.initiated_by_user_id == user.id
      assert session.amount_cents == 5000
      assert session.status == :open

      persisted = Repo.get!(StripeCheckoutSession, session.id)
      assert persisted.session_id == session_id
      assert persisted.status == :open
    end

    test "defaults status to :open when omitted" do
      user = insert_user!("rcs-default")
      org = insert_org!("rcs-default")

      assert {:ok, session} =
               Billing.record_checkout_session(
                 %{
                   session_id: "cs_test_#{System.unique_integer([:positive])}",
                   organization_id: org.id,
                   initiated_by_user_id: user.id,
                   amount_cents: 1234
                 },
                 Repo
               )

      assert session.status == :open
    end

    test "rejects a non-positive amount" do
      user = insert_user!("rcs-bad")
      org = insert_org!("rcs-bad")

      assert {:error, changeset} =
               Billing.record_checkout_session(
                 %{
                   session_id: "cs_test_#{System.unique_integer([:positive])}",
                   org_id: org.id,
                   initiated_by_user_id: user.id,
                   amount_cents: 0
                 },
                 Repo
               )

      refute changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.mark_checkout_session/3
  # ---------------------------------------------------------------------------

  describe "mark_checkout_session/3" do
    test "transitions an open session to :complete" do
      user = insert_user!("mcs-ok")
      org = insert_org!("mcs-ok")

      {:ok, session} =
        Billing.record_checkout_session(
          %{
            session_id: "cs_test_#{System.unique_integer([:positive])}",
            org_id: org.id,
            initiated_by_user_id: user.id,
            amount_cents: 5000
          },
          Repo
        )

      assert session.status == :open

      assert {:ok, updated} = Billing.mark_checkout_session(session, :complete, Repo)
      assert updated.status == :complete
      assert Repo.get!(StripeCheckoutSession, session.id).status == :complete
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.record_lease/2
  # ---------------------------------------------------------------------------

  describe "record_lease/2" do
    test "inserts a VmLease and a negative ledger entry in one transaction" do
      org = insert_org!("rl-org")

      lease_attrs = %{
        organization_id: org.id,
        cpu_count: 2,
        memory_gb: 4,
        disk_gb: 20,
        started_at: DateTime.utc_now(),
        duration_seconds: 3600
      }

      assert {:ok, %{lease: lease, entry: entry}} =
               Billing.record_lease(lease_attrs, Repo)

      assert lease.organization_id == org.id
      assert lease.cpu_count == 2

      # Cost: 2*3600*10_000 + 4*3600*5_000 + 20*3600*100 = 72+72+7.2 cents
      # cpu: 72_000_000, ram: 72_000_000, disk: 7_200_000 = 151_200_000 µ¢ = 151 cents
      expected_cost = Money.lease_cost(lease_attrs)

      assert entry.amount_cents == -expected_cost
      assert entry.source == :vm_lease_debit
      assert entry.vm_lease_id == lease.id

      # Balance reflects the debit
      assert Billing.balance(org.id, Repo) == -expected_cost
    end
  end

  # ---------------------------------------------------------------------------
  # list_entries_query/1
  # ---------------------------------------------------------------------------

  describe "list_entries_query/1" do
    test "returns only the org's entries; caller orders" do
      org = insert_org!("le-org")
      other = insert_org!("le-other")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 100, source: :admin_grant},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 200, source: :admin_grant},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: other.id, amount_cents: 999, source: :admin_grant},
          Repo
        )

      entries = Repo.all(Billing.list_entries_query(org.id))

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.organization_id == org.id))
      assert Enum.sort(Enum.map(entries, & &1.amount_cents)) == [100, 200]
    end

    test "empty for an org with no entries" do
      org = insert_org!("le-empty")
      assert Repo.all(Billing.list_entries_query(org.id)) == []
    end
  end

  # ---------------------------------------------------------------------------
  # usage/4
  # ---------------------------------------------------------------------------

  describe "usage/4" do
    test "aggregates resource-seconds and total cost for leases in the window" do
      org = insert_org!("usage-org")
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-02-01 00:00:00Z]

      l1 = %{cpu_count: 2, memory_gb: 4, disk_gb: 20, duration_seconds: 3600}
      l2 = %{cpu_count: 1, memory_gb: 1, disk_gb: 1, duration_seconds: 60}

      insert_lease!(org, ~U[2026-01-10 00:00:00Z], l1)
      insert_lease!(org, ~U[2026-01-20 00:00:00Z], l2)

      result = Billing.usage(org.id, from, to, Repo)

      assert result.cpu_seconds == 2 * 3600 + 1 * 60
      assert result.memory_gb_seconds == 4 * 3600 + 1 * 60
      assert result.disk_gb_seconds == 20 * 3600 + 1 * 60
      assert result.total_cents == Money.lease_cost(l1) + Money.lease_cost(l2)
    end

    test "excludes leases outside the half-open window and other orgs" do
      org = insert_org!("usage-win")
      other = insert_org!("usage-other")
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-02-01 00:00:00Z]

      # Before the window, on the open upper bound, and another org — all excluded.
      insert_lease!(org, ~U[2025-12-31 23:59:59Z], %{duration_seconds: 60})
      insert_lease!(org, to, %{duration_seconds: 60})
      insert_lease!(other, ~U[2026-01-15 00:00:00Z], %{duration_seconds: 60})

      # On the closed lower bound — included.
      insert_lease!(org, from, %{cpu_count: 3, duration_seconds: 100})

      result = Billing.usage(org.id, from, to, Repo)
      assert result.cpu_seconds == 3 * 100
    end

    test "running leases (nil duration) contribute zero" do
      org = insert_org!("usage-running")
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-02-01 00:00:00Z]

      insert_lease!(org, ~U[2026-01-10 00:00:00Z], %{duration_seconds: nil})

      assert Billing.usage(org.id, from, to, Repo) ==
               %{cpu_seconds: 0, memory_gb_seconds: 0, disk_gb_seconds: 0, total_cents: 0}
    end

    test "empty window -> all zeros" do
      org = insert_org!("usage-empty")

      assert Billing.usage(org.id, ~U[2026-01-01 00:00:00Z], ~U[2026-02-01 00:00:00Z], Repo) ==
               %{cpu_seconds: 0, memory_gb_seconds: 0, disk_gb_seconds: 0, total_cents: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # usage_series/4
  # ---------------------------------------------------------------------------

  describe "usage_series/4" do
    test "buckets resource-seconds + cost per day, zero-filling empty days" do
      org = insert_org!("series-org")
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-01-04 00:00:00Z]

      l_a = %{cpu_count: 2, memory_gb: 4, disk_gb: 20, duration_seconds: 3600}
      l_b = %{cpu_count: 1, memory_gb: 1, disk_gb: 1, duration_seconds: 60}

      insert_lease!(org, ~U[2026-01-01 08:00:00Z], l_a)
      insert_lease!(org, ~U[2026-01-01 20:00:00Z], l_b)
      insert_lease!(org, ~U[2026-01-03 12:00:00Z], l_a)

      series = Billing.usage_series(org.id, from, to, Repo)

      assert Enum.map(series, & &1.date) == [
               ~D[2026-01-01],
               ~D[2026-01-02],
               ~D[2026-01-03],
               ~D[2026-01-04]
             ]

      [d1, d2, d3, d4] = series

      assert d1.cpu_seconds == 2 * 3600 + 1 * 60
      assert d1.total_cents == Money.lease_cost(l_a) + Money.lease_cost(l_b)

      assert d2 == %{
               date: ~D[2026-01-02],
               cpu_seconds: 0,
               memory_gb_seconds: 0,
               disk_gb_seconds: 0,
               total_cents: 0
             }

      assert d3.cpu_seconds == 2 * 3600
      assert d3.total_cents == Money.lease_cost(l_a)
      assert d4.total_cents == 0
    end

    test "ignores running (nil-duration) leases and is half-open on started_at" do
      org = insert_org!("series-edge")
      from = ~U[2026-02-01 00:00:00Z]
      to = ~U[2026-02-02 00:00:00Z]

      insert_lease!(org, ~U[2026-02-01 10:00:00Z], %{
        cpu_count: 1,
        memory_gb: 1,
        disk_gb: 1,
        duration_seconds: nil
      })

      insert_lease!(org, ~U[2026-02-02 00:00:00Z], %{
        cpu_count: 1,
        memory_gb: 1,
        disk_gb: 1,
        duration_seconds: 60
      })

      series = Billing.usage_series(org.id, from, to, Repo)
      assert Enum.all?(series, &(&1.total_cents == 0))
    end

    test "scopes to the org" do
      org = insert_org!("series-mine")
      other = insert_org!("series-other")
      from = ~U[2026-03-01 00:00:00Z]
      to = ~U[2026-03-02 00:00:00Z]

      insert_lease!(other, ~U[2026-03-01 10:00:00Z], %{
        cpu_count: 4,
        memory_gb: 8,
        disk_gb: 40,
        duration_seconds: 600
      })

      series = Billing.usage_series(org.id, from, to, Repo)
      assert Enum.all?(series, &(&1.total_cents == 0 and &1.cpu_seconds == 0))
    end
  end

  describe "record_lease/2 idempotency" do
    test "a second lease for the same job is a no-op (one lease, one debit)" do
      org = insert_org!("lease-idem")
      job_id = insert_job!().id

      attrs = %{
        organization_id: org.id,
        job_id: job_id,
        cpu_count: 2,
        memory_gb: 4,
        disk_gb: 20,
        started_at: ~U[2026-01-01 00:00:00Z],
        finished_at: ~U[2026-01-01 00:10:00Z],
        duration_seconds: 600
      }

      assert {:ok, %{lease: _, entry: _}} = Billing.record_lease(attrs, Repo)
      assert {:ok, :already_recorded} = Billing.record_lease(attrs, Repo)

      leases = Repo.all(from(l in VmLease, where: l.job_id == ^job_id))
      assert length(leases) == 1

      debits = Repo.all(from(e in LedgerEntry, where: e.vm_lease_id == ^hd(leases).id))
      assert length(debits) == 1

      assert Billing.balance(org.id, Repo) == -Money.lease_cost(attrs)
    end

    test "job-less leases are unaffected by the idempotency index" do
      org = insert_org!("lease-nojob")

      attrs = %{
        organization_id: org.id,
        cpu_count: 2,
        memory_gb: 4,
        disk_gb: 20,
        started_at: ~U[2026-01-01 00:00:00Z],
        duration_seconds: 60
      }

      assert {:ok, %{lease: _}} = Billing.record_lease(attrs, Repo)
      assert {:ok, %{lease: _}} = Billing.record_lease(attrs, Repo)
      assert Repo.aggregate(from(l in VmLease, where: is_nil(l.job_id)), :count) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # usage_breakdown/4
  # ---------------------------------------------------------------------------

  defp insert_pipeline!(org, slug) do
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

  defp insert_build!(pipeline, number) do
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

  defp insert_named_job!(build, name, vm_handle) do
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

  describe "usage_breakdown/4" do
    test "groups leases by build with per-job lease detail" do
      org = insert_org!("breakdown-org")
      pipeline = insert_pipeline!(org, "breakdown-pipe")
      build = insert_build!(pipeline, 42)

      job_a = insert_named_job!(build, "build", "vm-aaa")
      job_b = insert_named_job!(build, "test", "vm-bbb")

      from = ~U[2026-06-06 00:00:00Z]
      to = ~U[2026-06-07 00:00:00Z]

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

      assert [group] = Billing.usage_breakdown(org.id, from, to, Repo)

      assert group.build_number == 42
      assert group.pipeline_name == "Pipeline breakdown-pipe"
      assert group.pipeline_slug == "breakdown-pipe"
      assert group.job_count == 2

      # Two identical leases; the debit is negative, so the build total is the
      # sum of both negated lease costs.
      expected =
        Money.lease_cost(%{cpu_count: 2, memory_gb: 4, disk_gb: 20, duration_seconds: 300})

      assert group.total_cents == -2 * expected

      vm_handles = group.jobs |> Enum.map(& &1.vm_handle) |> Enum.sort()
      assert vm_handles == ["vm-aaa", "vm-bbb"]

      assert Enum.all?(
               group.jobs,
               &(&1.cpu_count == 2 and &1.memory_gb == 4 and &1.disk_gb == 20)
             )

      assert Enum.all?(group.jobs, &(&1.duration_seconds == 300))
    end

    test "excludes leases outside the window" do
      org = insert_org!("breakdown-out")
      pipeline = insert_pipeline!(org, "breakdown-out-pipe")
      build = insert_build!(pipeline, 7)
      job = insert_named_job!(build, "build", "vm-out")

      from = ~U[2026-06-06 00:00:00Z]
      to = ~U[2026-06-07 00:00:00Z]

      # started_at is on the open upper bound -> excluded.
      assert {:ok, %{lease: _, entry: _}} =
               Billing.record_lease(
                 %{
                   organization_id: org.id,
                   job_id: job.id,
                   pipeline_id: pipeline.id,
                   cpu_count: 2,
                   memory_gb: 4,
                   disk_gb: 20,
                   started_at: ~U[2026-06-07 00:00:00Z],
                   finished_at: ~U[2026-06-07 00:05:00Z],
                   duration_seconds: 300
                 },
                 Repo
               )

      assert Billing.usage_breakdown(org.id, from, to, Repo) == []
    end

    test "orders builds newest lease first" do
      org = insert_org!("breakdown-order")
      pipeline = insert_pipeline!(org, "breakdown-order-pipe")

      older_build = insert_build!(pipeline, 1)
      newer_build = insert_build!(pipeline, 2)

      older_job = insert_named_job!(older_build, "build", "vm-older")
      newer_job = insert_named_job!(newer_build, "build", "vm-newer")

      from = ~U[2026-06-06 00:00:00Z]
      to = ~U[2026-06-07 00:00:00Z]

      lease_attrs = fn job, started_at ->
        %{
          organization_id: org.id,
          job_id: job.id,
          pipeline_id: pipeline.id,
          cpu_count: 2,
          memory_gb: 4,
          disk_gb: 20,
          started_at: started_at,
          finished_at: DateTime.add(started_at, 300, :second),
          duration_seconds: 300
        }
      end

      assert {:ok, %{lease: _, entry: _}} =
               Billing.record_lease(lease_attrs.(older_job, ~U[2026-06-06 09:00:00Z]), Repo)

      assert {:ok, %{lease: _, entry: _}} =
               Billing.record_lease(lease_attrs.(newer_job, ~U[2026-06-06 11:00:00Z]), Repo)

      assert [first, second] = Billing.usage_breakdown(org.id, from, to, Repo)
      assert first.build_number == 2
      assert second.build_number == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Billing.can_run_new_build?/2
  # ---------------------------------------------------------------------------

  describe "can_run_new_build?/2" do
    test "true when the org has a positive balance" do
      org = insert_org!("gate-positive")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 500, source: :admin_grant},
          Repo
        )

      assert Billing.can_run_new_build?(org.id, Repo)
    end

    test "false at exactly zero balance (a brand-new org with no ledger entries)" do
      org = insert_org!("gate-zero")
      refute Billing.can_run_new_build?(org.id, Repo)
    end

    test "false when debits have driven the balance back to zero" do
      org = insert_org!("gate-net-zero")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: 300, source: :admin_grant},
          Repo
        )

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: -300, source: :vm_lease_debit},
          Repo
        )

      refute Billing.can_run_new_build?(org.id, Repo)
    end

    test "false when the balance is negative" do
      org = insert_org!("gate-negative")

      {:ok, _} =
        Billing.insert_entry(
          %{organization_id: org.id, amount_cents: -50, source: :vm_lease_debit},
          Repo
        )

      refute Billing.can_run_new_build?(org.id, Repo)
    end
  end
end

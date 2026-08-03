defmodule Harmont.Billing do
  @moduledoc """
  Context for the Billing domain.

  Manages the append-only credit/debit ledger, coupon redemption, VM lease
  recording, and Stripe webhook idempotency.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks.

  ## Error-return style

  Functions that fail in user-facing ways return plain atoms:

  - `:coupon_not_found`       — no coupon with that code exists
  - `:coupon_expired`         — coupon's `expires_at` is in the past
  - `:coupon_exhausted`       — `redemptions_used >= max_redemptions`
  - `:coupon_already_claimed` — this org already redeemed this coupon

  Internal / framework errors are re-raised or returned as
  `{:error, %Ecto.Changeset{}}`.

  ## Transaction discipline

  `redeem_coupon/5` and `record_stripe_event/5` each run inside a single
  `Repo.transaction/1`.  If any step raises or rolls back, nothing is
  persisted and the caller can retry safely.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Billing.Coupon
  alias Harmont.Billing.CouponRedemption
  alias Harmont.Billing.LedgerEntry
  alias Harmont.Billing.Money
  alias Harmont.Billing.StripeCheckoutSession
  alias Harmont.Billing.StripeWebhookEvent
  alias Harmont.Billing.VmLease
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Pipelines.Pipeline

  # ---------------------------------------------------------------------------
  # Ledger
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current balance (sum of `amount_cents`) for `org_id`.

  Returns `0` when the org has no ledger entries.
  """
  @spec balance(Ecto.UUID.t(), module()) :: integer()
  def balance(org_id, repo) do
    query =
      from(e in LedgerEntry,
        where: e.organization_id == ^org_id,
        select: sum(e.amount_cents)
      )

    repo.one(query) || 0
  end

  @doc """
  Whether `org_id` may START a NEW build right now.

  The billing rule: a new build is allowed only while the org's balance is
  strictly positive (`> 0` cents). An org whose balance has reached `$0` or gone
  negative (its VM-lease debits have caught up with its credit) is blocked from
  starting new work.

  This gate is enforced ONLY at build creation — at the API/webhook/scheduled
  boundaries, never inside `Harmont.Builds.create_build/3`. Builds already running
  are never interrupted: they run to completion and their leases keep metering.
  A brand-new org starts at a `$0` balance and so cannot run a build until it
  tops up or is granted credit.
  """
  @spec can_run_new_build?(Ecto.UUID.t(), module()) :: boolean()
  def can_run_new_build?(org_id, repo) do
    balance(org_id, repo) > 0
  end

  @doc """
  Appends a new ledger entry.

  Required keys in `attrs`: `:organization_id`, `:amount_cents`, `:source`.
  Optional: `:description`, `:vm_lease_id`, `:coupon_redemption_id`,
  `:stripe_webhook_event_id`, `:granted_by_user_id`.
  """
  @spec insert_entry(map(), module()) ::
          {:ok, LedgerEntry.t()} | {:error, Ecto.Changeset.t()}
  def insert_entry(attrs, repo) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Returns an `Ecto.Query` of an org's ledger entries.

  The query selects every `LedgerEntry` for `org_id` with no ordering imposed —
  the caller (e.g. cursor pagination) orders by `(inserted_at, id)`. Pure: it
  touches no repo, so callers compose and run it themselves.
  """
  @spec list_entries_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def list_entries_query(org_id) do
    from(e in LedgerEntry, where: e.organization_id == ^org_id)
  end

  # ---------------------------------------------------------------------------
  # Usage aggregation
  # ---------------------------------------------------------------------------

  @doc """
  Aggregates an org's VM-lease usage over the half-open window `[from, to)`.

  A lease is in the window when its `started_at` is `>= from` and `< to`.
  Returns:

      %{
        cpu_seconds:       Σ cpu_count    * duration_seconds,
        memory_gb_seconds: Σ memory_gb    * duration_seconds,
        disk_gb_seconds:   Σ disk_gb      * duration_seconds,
        total_cents:       Σ Money.lease_cost(lease)
      }

  Leases with a `nil` `duration_seconds` (still running) contribute 0 — they
  have not yet incurred a billable cost. All four values are `0` when no lease
  falls in the window.
  """
  @spec usage(Ecto.UUID.t(), DateTime.t(), DateTime.t(), module()) :: %{
          cpu_seconds: non_neg_integer(),
          memory_gb_seconds: non_neg_integer(),
          disk_gb_seconds: non_neg_integer(),
          total_cents: non_neg_integer()
        }
  def usage(org_id, from, to, repo) do
    query =
      from(l in VmLease,
        where:
          l.organization_id == ^org_id and
            l.started_at >= ^from and l.started_at < ^to
      )

    repo.all(query)
    |> Enum.reduce(
      %{cpu_seconds: 0, memory_gb_seconds: 0, disk_gb_seconds: 0, total_cents: 0},
      &accumulate_lease/2
    )
  end

  @doc """
  Per-day usage + cost for the half-open window `[from, to)`, one bucket per
  calendar day (zero-filled). Buckets by `started_at`'s UTC date and reduces each
  day's leases with the same per-lease accumulation as `usage/4`, so daily
  `total_cents` sums are exactly consistent with `total_cents`/`balance` (cents are
  floored per lease, never per sum).

  The bucket axis is inclusive of `to`'s calendar date (`Date.range/2` is
  inclusive on both ends), so when `to` is an exclusive midnight callers get a
  trailing zero-filled bucket for that end date.
  """
  @spec usage_series(Ecto.UUID.t(), DateTime.t(), DateTime.t(), module()) :: [
          %{
            date: Date.t(),
            cpu_seconds: non_neg_integer(),
            memory_gb_seconds: non_neg_integer(),
            disk_gb_seconds: non_neg_integer(),
            total_cents: non_neg_integer()
          }
        ]
  def usage_series(org_id, %DateTime{} = from, %DateTime{} = to, repo) do
    leases =
      repo.all(
        from(l in VmLease,
          where:
            l.organization_id == ^org_id and
              l.started_at >= ^from and l.started_at < ^to
        )
      )

    by_day = Enum.group_by(leases, fn l -> DateTime.to_date(l.started_at) end)

    DateTime.to_date(from)
    |> Date.range(DateTime.to_date(to))
    |> Enum.map(fn day ->
      by_day
      |> Map.get(day, [])
      |> Enum.reduce(
        %{cpu_seconds: 0, memory_gb_seconds: 0, disk_gb_seconds: 0, total_cents: 0},
        &accumulate_lease/2
      )
      |> Map.put(:date, day)
    end)
  end

  @doc """
  Per-build VM-usage breakdown over the half-open window `[from, to)`, newest
  build first. Each entry rolls up a build's lease debits and nests one row per
  job lease, with the cross-reference context needed to debug a charge: pipeline,
  build number, job name, the VM handle that ran it, resource shape and duration.

  A lease is in the window when its `started_at` is `>= from` and `< to`. Leases
  whose build has no pipeline (executor-only builds) still appear, with null
  pipeline fields. Leases with no associated job/build (`job_id` is null) all
  collapse into a single group keyed on a `nil` build (`build_number` nil). The
  amount comes from the actual `:vm_lease_debit` ledger entry (negative cents),
  so a build's `total_cents` matches the ledger exactly.
  """
  @spec usage_breakdown(Ecto.UUID.t(), DateTime.t(), DateTime.t(), module()) :: [map()]
  def usage_breakdown(org_id, %DateTime{} = from, %DateTime{} = to, repo) do
    repo.all(
      from(l in VmLease,
        join: e in LedgerEntry,
        on: e.vm_lease_id == l.id and e.source == :vm_lease_debit,
        left_join: j in Job,
        on: j.id == l.job_id,
        left_join: b in Build,
        on: b.id == j.build_id,
        left_join: p in Pipeline,
        on: p.id == b.pipeline_id,
        where:
          l.organization_id == ^org_id and
            l.started_at >= ^from and l.started_at < ^to,
        select: %{
          amount_cents: e.amount_cents,
          lease_started_at: l.started_at,
          lease_finished_at: l.finished_at,
          duration_seconds: l.duration_seconds,
          cpu_count: l.cpu_count,
          memory_gb: l.memory_gb,
          disk_gb: l.disk_gb,
          job_id: l.job_id,
          job_name: j.name,
          step_key: j.step_key,
          vm_handle: j.vm_handle,
          build_id: b.id,
          build_number: b.number,
          build_external_id: b.external_build_id,
          pipeline_id: p.id,
          pipeline_name: p.name,
          pipeline_slug: p.slug
        }
      )
    )
    |> group_breakdown_by_build()
  end

  defp group_breakdown_by_build(rows) do
    rows
    |> Enum.group_by(& &1.build_id)
    |> Enum.map(fn {_build_id, [first | _] = group} ->
      %{
        build_id: first.build_id,
        build_number: first.build_number,
        build_external_id: first.build_external_id,
        pipeline_id: first.pipeline_id,
        pipeline_name: first.pipeline_name,
        pipeline_slug: first.pipeline_slug,
        total_cents: group |> Enum.map(& &1.amount_cents) |> Enum.sum(),
        started_at: group |> Enum.map(& &1.lease_started_at) |> Enum.min(DateTime),
        finished_at: latest_finished(group),
        job_count: length(group),
        jobs:
          group
          |> Enum.map(&breakdown_job/1)
          |> Enum.sort_by(& &1.started_at, DateTime)
      }
    end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  defp latest_finished(group) do
    case group |> Enum.map(& &1.lease_finished_at) |> Enum.reject(&is_nil/1) do
      [] -> nil
      finishes -> Enum.max(finishes, DateTime)
    end
  end

  defp breakdown_job(r) do
    %{
      job_id: r.job_id,
      job_name: r.job_name,
      step_key: r.step_key,
      vm_handle: r.vm_handle,
      cpu_count: r.cpu_count,
      memory_gb: r.memory_gb,
      disk_gb: r.disk_gb,
      duration_seconds: r.duration_seconds,
      amount_cents: r.amount_cents,
      started_at: r.lease_started_at,
      finished_at: r.lease_finished_at
    }
  end

  defp accumulate_lease(%VmLease{duration_seconds: nil}, acc), do: acc

  defp accumulate_lease(%VmLease{} = lease, acc) do
    dur = lease.duration_seconds

    %{
      cpu_seconds: acc.cpu_seconds + lease.cpu_count * dur,
      memory_gb_seconds: acc.memory_gb_seconds + lease.memory_gb * dur,
      disk_gb_seconds: acc.disk_gb_seconds + lease.disk_gb * dur,
      total_cents:
        acc.total_cents +
          Money.lease_cost(%{
            cpu_count: lease.cpu_count,
            memory_gb: lease.memory_gb,
            disk_gb: lease.disk_gb,
            duration_seconds: dur
          })
    }
  end

  # ---------------------------------------------------------------------------
  # Coupon redemption
  # ---------------------------------------------------------------------------

  @doc """
  Redeems a coupon for an organization in a single atomic transaction.

  ## Steps (all-or-nothing)

  1. Load the coupon by `code` — `:coupon_not_found` if absent.
  2. Check expiry — `:coupon_expired` if `expires_at` is set and `now >= expires_at`.
  3. Check exhaustion — `:coupon_exhausted` if `redemptions_used >= max_redemptions`.
  4. Insert a `CouponRedemption` row — `:coupon_already_claimed` if the unique
     `(coupon_id, organization_id)` constraint fires (concurrent or repeated redemption).
  5. Increment `coupon.redemptions_used` by 1.
  6. Append a `LedgerEntry` with `source: :coupon_redemption`.

  Returns `{:ok, credit_cents}` on success.
  """
  @spec redeem_coupon(DateTime.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), module()) ::
          {:ok, pos_integer()} | {:error, atom()}
  def redeem_coupon(now, user_id, org_id, code, repo) do
    repo.transaction(fn ->
      coupon = repo.get_by(Coupon, code: code)

      cond do
        is_nil(coupon) -> repo.rollback(:coupon_not_found)
        coupon_expired?(coupon, now) -> repo.rollback(:coupon_expired)
        coupon_exhausted?(coupon) -> repo.rollback(:coupon_exhausted)
        true -> apply_redemption(coupon, org_id, user_id, code, repo)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Stripe webhook idempotency
  # ---------------------------------------------------------------------------

  @doc """
  Records a Stripe webhook event and runs a side-effect function exactly once.

  ## Steps (single transaction)

  1. Look up the event by `stripe_event_id`.
     - If found → return `{:ok, :already_seen}` without running `side_effect_fun`.
  2. Insert the event row.
  3. Call `side_effect_fun.(event)` (e.g. post a ledger credit).
     - If it raises, the transaction rolls back and the event row is absent,
       so Stripe's retry will reprocess cleanly.
  4. Stamp `processed_at` on the event row.
  5. Return `{:ok, :new}`.

  `side_effect_fun` receives the inserted `%StripeWebhookEvent{}` struct.
  """
  @spec record_stripe_event(
          String.t(),
          String.t(),
          String.t(),
          (StripeWebhookEvent.t() -> any()),
          module()
        ) :: {:ok, :new | :already_seen}
  def record_stripe_event(stripe_event_id, type, payload, side_effect_fun, repo) do
    # Idempotency via a pre-insert existence check:
    # - Looking up the row first avoids a unique-violation INSERT, which aborts
    #   the Postgres transaction and would prevent further DB work.
    # - side_effect_fun raising causes the whole transaction to roll back,
    #   leaving no event row — so Stripe's retry will reprocess cleanly.
    repo.transaction(fn ->
      case repo.get_by(StripeWebhookEvent, stripe_event_id: stripe_event_id) do
        %StripeWebhookEvent{} -> :already_seen
        nil -> insert_and_apply_event(stripe_event_id, type, payload, side_effect_fun, repo)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Stripe checkout sessions
  # ---------------------------------------------------------------------------

  @doc """
  Records a Stripe Checkout Session initiated for a credit top-up.

  Required keys in `attrs`: `:session_id`, `:org_id` (or `:organization_id`),
  `:initiated_by_user_id`, `:amount_cents`. Optional: `:status` (defaults to
  `:open`).

  The session starts `:open`; the Stripe webhook handler later marks it
  `:complete` (posting the matching ledger credit) or terminal-unpaid
  (`:expired` / `:failed`, posting no credit).

  Returns `{:ok, %StripeCheckoutSession{}}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec record_checkout_session(map(), module()) ::
          {:ok, StripeCheckoutSession.t()} | {:error, Ecto.Changeset.t()}
  def record_checkout_session(attrs, repo) do
    %StripeCheckoutSession{}
    |> StripeCheckoutSession.changeset(normalise_org_id(attrs))
    |> repo.insert()
  end

  @doc """
  Transitions a recorded Checkout Session to a new `status`.

  `status` must be one of `:open`, `:complete`, `:expired`, or `:failed`. The
  Stripe webhook handler calls this with `:complete` once a
  `checkout.session.completed` event has posted the matching ledger credit.

  Returns `{:ok, %StripeCheckoutSession{}}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec mark_checkout_session(
          StripeCheckoutSession.t(),
          :open | :complete | :expired | :failed,
          module()
        ) :: {:ok, StripeCheckoutSession.t()} | {:error, Ecto.Changeset.t()}
  def mark_checkout_session(%StripeCheckoutSession{} = session, status, repo) do
    session
    |> StripeCheckoutSession.changeset(%{status: status})
    |> repo.update()
  end

  # ---------------------------------------------------------------------------
  # VM lease
  # ---------------------------------------------------------------------------

  @doc """
  Records a VM lease and posts a debit ledger entry in one transaction.

  Required keys in `attrs`: `:organization_id`, `:cpu_count`, `:memory_gb`,
  `:disk_gb`, `:started_at`, `:duration_seconds`.

  The debit amount is `- Money.lease_cost(attrs)` (negative = debit).

  Returns `{:ok, %{lease: %VmLease{}, entry: %LedgerEntry{}}}`. Returns
  `{:ok, :already_recorded}` (committing nothing new) if a lease for this
  `job_id` already exists.
  """
  @spec record_lease(map(), module()) ::
          {:ok, %{lease: VmLease.t(), entry: LedgerEntry.t()} | :already_recorded}
          | {:error, Ecto.Changeset.t()}
  def record_lease(attrs, repo) do
    normalised = normalise_org_id(attrs)

    repo.transaction(fn ->
      with {:ok, lease} <- insert_lease(normalised, repo),
           {:ok, entry} <- insert_lease_debit(normalised, lease, repo) do
        %{lease: lease, entry: entry}
      else
        {:error, %Ecto.Changeset{} = cs} -> lease_conflict_or_rollback(cs, repo)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — coupon redemption helpers
  # ---------------------------------------------------------------------------

  defp coupon_expired?(%Coupon{expires_at: nil}, _now), do: false

  defp coupon_expired?(%Coupon{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp coupon_exhausted?(%Coupon{redemptions_used: used, max_redemptions: max}), do: used >= max

  defp apply_redemption(%Coupon{} = coupon, org_id, user_id, code, repo) do
    redemption_attrs = %{
      coupon_id: coupon.id,
      organization_id: org_id,
      redeemed_by_user_id: user_id,
      credit_cents: coupon.credit_cents
    }

    case %CouponRedemption{} |> CouponRedemption.changeset(redemption_attrs) |> repo.insert() do
      {:ok, redemption} ->
        bump_redemptions_used(coupon, repo)
        post_coupon_credit(org_id, coupon, code, redemption, repo)
        coupon.credit_cents

      {:error, changeset} ->
        reason =
          if has_unique_error?(changeset, [:coupon_id, :organization_id]),
            do: :coupon_already_claimed,
            else: {:changeset, changeset}

        repo.rollback(reason)
    end
  end

  defp bump_redemptions_used(%Coupon{id: id}, repo) do
    case repo.update_all(from(c in Coupon, where: c.id == ^id), inc: [redemptions_used: 1]) do
      {1, _} -> :ok
      other -> repo.rollback({:bump_redemptions_used_unexpected, other})
    end
  end

  defp post_coupon_credit(org_id, %Coupon{credit_cents: cents}, code, redemption, repo) do
    case insert_entry(
           %{
             organization_id: org_id,
             amount_cents: cents,
             source: :coupon_redemption,
             description: "Coupon #{code} redeemed",
             coupon_redemption_id: redemption.id
           },
           repo
         ) do
      {:ok, entry} -> entry
      {:error, cs} -> repo.rollback({:changeset, cs})
    end
  end

  # ---------------------------------------------------------------------------
  # Private — Stripe idempotency helpers
  # ---------------------------------------------------------------------------

  defp insert_and_apply_event(stripe_event_id, type, payload, side_effect_fun, repo) do
    changeset =
      StripeWebhookEvent.changeset(%StripeWebhookEvent{}, %{
        stripe_event_id: stripe_event_id,
        event_type: type,
        payload: payload
      })

    case repo.insert(changeset) do
      {:ok, event} ->
        side_effect_fun.(event)
        stamp_processed_at(event, repo)
        :new

      {:error, cs} ->
        # A concurrent writer won the race and inserted the same
        # `stripe_event_id` between our existence check and this INSERT. That is
        # the idempotency case: the event was effectively already seen, and
        # because side_effect_fun runs *after* a successful insert, the losing
        # writer applied no side effect — no double credit is possible. Convert
        # the unique violation to `:already_seen`; any other changeset error is
        # a real failure and rolls back.
        if has_unique_error?(cs, :stripe_event_id) do
          :already_seen
        else
          repo.rollback({:changeset, cs})
        end
    end
  end

  defp stamp_processed_at(%StripeWebhookEvent{id: id}, repo) do
    case repo.update_all(
           from(e in StripeWebhookEvent, where: e.id == ^id),
           set: [processed_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      other -> repo.rollback({:stamp_processed_at_unexpected, other})
    end
  end

  # ---------------------------------------------------------------------------
  # Private — VM lease helpers
  # ---------------------------------------------------------------------------

  defp insert_lease(attrs, repo) do
    # `mode: :savepoint` wraps the INSERT in a Postgres SAVEPOINT so a
    # `vm_leases_job_id_index` unique violation rolls back only to the
    # savepoint — leaving the surrounding `record_lease/2` transaction healthy
    # enough to commit the `:already_recorded` no-op instead of aborting it.
    %VmLease{} |> VmLease.changeset(attrs) |> repo.insert(mode: :savepoint)
  end

  defp insert_lease_debit(attrs, lease, repo) do
    cost = Money.lease_cost(attrs)
    org_id = attrs[:organization_id]

    insert_entry(
      %{
        organization_id: org_id,
        amount_cents: -cost,
        source: :vm_lease_debit,
        description: "VM lease debit",
        vm_lease_id: lease.id
      },
      repo
    )
  end

  # A lease for this job already exists (re-driven terminal transition / backstop
  # re-meter): commit nothing new and report it. Any other changeset error rolls
  # back. Pulled into a helper to keep record_lease/2 within Credo's nesting depth.
  defp lease_conflict_or_rollback(%Ecto.Changeset{} = cs, repo) do
    if has_unique_error?(cs, :job_id),
      do: :already_recorded,
      else: repo.rollback(cs)
  end

  # Accept both :org_id (public API shorthand) and :organization_id (Ecto FK name).
  defp normalise_org_id(%{org_id: id} = attrs) do
    attrs |> Map.delete(:org_id) |> Map.put(:organization_id, id)
  end

  defp normalise_org_id(attrs), do: attrs

  # ---------------------------------------------------------------------------
  # Private — error helpers
  # ---------------------------------------------------------------------------

  # Returns true when the changeset has a unique_constraint error on `field`.
  # Accepts an atom (single field) or a list (composite key — checks the first).
  defp has_unique_error?(%Ecto.Changeset{} = cs, field) when is_atom(field) do
    case cs.errors[field] do
      {_, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  defp has_unique_error?(%Ecto.Changeset{} = cs, [first | _rest]) do
    has_unique_error?(cs, first)
  end
end

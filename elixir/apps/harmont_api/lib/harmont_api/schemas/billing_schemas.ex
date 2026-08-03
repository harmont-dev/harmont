defmodule HarmontApi.Schemas.BalanceResponse do
  @moduledoc "An organization's current credit balance, in cents."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BalanceResponse",
    description:
      "The organization's current balance — the sum of every ledger entry " <>
        "(credits positive, debits negative). May be negative.",
    type: :object,
    properties: %{
      balance_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "Current balance in cents (credits − debits). May be negative."
      }
    },
    required: [:balance_cents]
  })
end

defmodule HarmontApi.Schemas.Transaction do
  @moduledoc "A single immutable ledger entry."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Transaction",
    description: "One append-only ledger entry — a credit (positive) or debit (negative).",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "The entry's id."},
      amount_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "Signed amount in cents: positive for credits, negative for debits."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        enum: ["stripe_topup", "coupon_redemption", "admin_grant", "vm_lease_debit", "refund"],
        description: "What produced the entry."
      },
      description: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional human-readable note."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the entry was recorded."
      }
    },
    required: [:id, :amount_cents, :source, :created_at]
  })
end

defmodule HarmontApi.Schemas.TransactionList do
  @moduledoc "A paginated list of ledger entries."
  require OpenApiSpex

  alias HarmontApi.Schemas.Transaction

  OpenApiSpex.schema(%{
    title: "TransactionList",
    description:
      "A page of an organization's ledger entries (newest first), with an opaque cursor.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: Transaction,
        description: "The ledger entries on this page, newest first."
      },
      next_cursor: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque cursor for the next page. Pass it as the `cursor` query " <>
            "parameter; `null` when there are no more pages."
      }
    },
    required: [:data, :next_cursor]
  })
end

defmodule HarmontApi.Schemas.RedeemCouponRequest do
  @moduledoc "A request to redeem a coupon code for the scoped organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RedeemCouponRequest",
    description:
      "Redeems a coupon for the organization identified by the path. The org is " <>
        "taken from the route (`:org`); the body carries only the coupon code.",
    type: :object,
    properties: %{
      code: %OpenApiSpex.Schema{
        type: :string,
        description: "The coupon code to redeem."
      }
    },
    required: [:code]
  })
end

defmodule HarmontApi.Schemas.RedeemCouponResponse do
  @moduledoc "The result of a successful coupon redemption."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RedeemCouponResponse",
    description:
      "The credit granted by the coupon and the organization's resulting balance, " <>
        "both in cents.",
    type: :object,
    properties: %{
      credit_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "The credit granted by the coupon, in cents."
      },
      balance_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "The organization's balance after the credit, in cents."
      }
    },
    required: [:credit_cents, :balance_cents]
  })
end

defmodule HarmontApi.Schemas.CheckoutRequest do
  @moduledoc "A request to start a Stripe Checkout Session for a credit top-up."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CheckoutRequest",
    description:
      "Starts a Stripe Checkout Session crediting the organization identified by " <>
        "the path (`:org`). The body carries only the top-up amount in cents.",
    type: :object,
    properties: %{
      amount_cents: %OpenApiSpex.Schema{
        type: :integer,
        minimum: 100,
        maximum: 1_000_000,
        description:
          "The credit top-up amount in cents. Must be a positive integer within " <>
            "the supported bounds (100–1,000,000)."
      }
    },
    required: [:amount_cents]
  })
end

defmodule HarmontApi.Schemas.CheckoutResponse do
  @moduledoc "The hosted Stripe Checkout URL to redirect the customer to."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CheckoutResponse",
    description:
      "The hosted Stripe Checkout URL. Redirect the customer here to complete the " <>
        "top-up; on success Stripe fires a webhook that posts the matching credit.",
    type: :object,
    properties: %{
      checkout_url: %OpenApiSpex.Schema{
        type: :string,
        description: "The hosted Stripe Checkout Session URL."
      }
    },
    required: [:checkout_url]
  })
end

defmodule HarmontApi.Schemas.StripeWebhookResponse do
  @moduledoc "Acknowledgement that a Stripe webhook event was verified and recorded."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StripeWebhookResponse",
    description:
      "Acknowledges that a Stripe webhook event verified and was recorded " <>
        "(idempotently). Returned for any verified event — handled or not — so " <>
        "Stripe stops retrying.",
    type: :object,
    properties: %{
      status: %OpenApiSpex.Schema{
        type: :string,
        enum: ["ok"],
        description: "Always `\"ok\"` on a verified, recorded event."
      }
    },
    required: [:status]
  })
end

defmodule HarmontApi.Schemas.UsageResponse do
  @moduledoc "VM-lease usage aggregates over a time window."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UsageResponse",
    description:
      "Aggregated VM-lease usage for an organization over the requested " <>
        "`[from, to)` window: resource-seconds per dimension and the total " <>
        "billed cost in cents.",
    type: :object,
    properties: %{
      cpu_seconds: %OpenApiSpex.Schema{
        type: :integer,
        description: "Σ (cpu_count × duration_seconds) over leases in the window."
      },
      memory_gb_seconds: %OpenApiSpex.Schema{
        type: :integer,
        description: "Σ (memory_gb × duration_seconds) over leases in the window."
      },
      disk_gb_seconds: %OpenApiSpex.Schema{
        type: :integer,
        description: "Σ (disk_gb × duration_seconds) over leases in the window."
      },
      total_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "Σ rate-card cost of the leases in the window, in cents."
      }
    },
    required: [:cpu_seconds, :memory_gb_seconds, :disk_gb_seconds, :total_cents]
  })
end

defmodule HarmontApi.Schemas.UsageSeriesBucket do
  @moduledoc "One per-day bucket of usage + cost."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UsageSeriesBucket",
    type: :object,
    properties: %{
      date: %OpenApiSpex.Schema{type: :string, format: :date, description: "Bucket day (UTC)."},
      cpu_seconds: %OpenApiSpex.Schema{type: :integer},
      memory_gb_seconds: %OpenApiSpex.Schema{type: :integer},
      disk_gb_seconds: %OpenApiSpex.Schema{type: :integer},
      total_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "Rate-card cost for the day, in cents."
      }
    },
    required: [:date, :cpu_seconds, :memory_gb_seconds, :disk_gb_seconds, :total_cents]
  })
end

defmodule HarmontApi.Schemas.UsageSeriesResponse do
  @moduledoc "Per-day usage time-series for a window."
  require OpenApiSpex
  alias HarmontApi.Schemas.UsageSeriesBucket

  OpenApiSpex.schema(%{
    title: "UsageSeriesResponse",
    type: :object,
    properties: %{data: %OpenApiSpex.Schema{type: :array, items: UsageSeriesBucket}},
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.UsageBreakdownJob do
  @moduledoc "One job's VM lease within a build's usage breakdown."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UsageBreakdownJob",
    description:
      "A single job's VM lease: the VM that ran it, its shape, how long it ran, and what it cost.",
    type: :object,
    properties: %{
      job_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The job's id."
      },
      job_name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The job's human-readable name."
      },
      step_key: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The job's DAG step key."
      },
      vm_handle: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The backend VM identifier that ran the job."
      },
      cpu_count: %OpenApiSpex.Schema{type: :integer, description: "vCPUs leased."},
      memory_gb: %OpenApiSpex.Schema{type: :integer, description: "GB of RAM leased."},
      disk_gb: %OpenApiSpex.Schema{type: :integer, description: "GB of disk leased."},
      duration_seconds: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description: "Lease duration in seconds (null while still running)."
      },
      amount_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "The debit for this lease, in cents (negative)."
      },
      started_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the lease started."
      },
      finished_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the lease finished (null if still running)."
      }
    },
    required: [:cpu_count, :memory_gb, :disk_gb, :amount_cents, :started_at]
  })
end

defmodule HarmontApi.Schemas.UsageBreakdownBuild do
  @moduledoc "A build's rolled-up VM usage with per-job detail."
  require OpenApiSpex
  alias HarmontApi.Schemas.UsageBreakdownJob

  OpenApiSpex.schema(%{
    title: "UsageBreakdownBuild",
    description: "All VM usage attributed to one build, rolled up and broken down per job.",
    type: :object,
    properties: %{
      build_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The build's id (null for leases with no build)."
      },
      build_number: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description: "The per-pipeline build number."
      },
      build_external_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The build's public external id."
      },
      pipeline_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The pipeline's id."
      },
      pipeline_name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The pipeline's name."
      },
      pipeline_slug: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The pipeline's routing slug (for linking)."
      },
      total_cents: %OpenApiSpex.Schema{
        type: :integer,
        description: "Sum of this build's lease debits, in cents (negative)."
      },
      started_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "Earliest lease start in the build."
      },
      finished_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description:
          "Latest finish among the build's completed leases (null only if no lease has finished yet)."
      },
      job_count: %OpenApiSpex.Schema{
        type: :integer,
        description: "Number of job leases in the build."
      },
      jobs: %OpenApiSpex.Schema{
        type: :array,
        items: UsageBreakdownJob,
        description: "Per-job leases, oldest first."
      }
    },
    required: [:total_cents, :started_at, :job_count, :jobs]
  })
end

defmodule HarmontApi.Schemas.UsageBreakdownResponse do
  @moduledoc "Per-build VM-usage breakdown for a window."
  require OpenApiSpex
  alias HarmontApi.Schemas.UsageBreakdownBuild

  OpenApiSpex.schema(%{
    title: "UsageBreakdownResponse",
    description: "An organization's VM usage over a window, grouped by build (newest first).",
    type: :object,
    properties: %{data: %OpenApiSpex.Schema{type: :array, items: UsageBreakdownBuild}},
    required: [:data]
  })
end

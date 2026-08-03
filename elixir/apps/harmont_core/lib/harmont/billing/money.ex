defmodule Harmont.Billing.Money do
  @moduledoc """
  Rate-card cost arithmetic for VM leases.

  ## Rate card

  Rates are in micro-cents (µ¢) per resource unit per second and are
  configurable via:

      config :harmont_core, :billing_rates,
        cpu: 10_000,   # µ¢ per vCPU per second
        ram: 5_000,    # µ¢ per GB of RAM per second
        disk: 100      # µ¢ per GB of disk per second

  ## Formula

      total_µ¢ = cpu_count * duration_seconds * cpu_rate
               + memory_gb * duration_seconds * ram_rate
               + disk_gb   * duration_seconds * disk_rate

  Floor to whole cents: `div(total_µ¢, 1_000_000)`.

  A negative duration (clock-skew, test data) returns 0.
  """

  @default_rates %{cpu: 10_000, ram: 5_000, disk: 100}

  @doc """
  Returns the cost in cents for a VM lease described by `attrs`.

  Required keys: `:cpu_count`, `:memory_gb`, `:disk_gb`, `:duration_seconds`.

  Returns `0` when `duration_seconds < 0` (clock-skew guard).
  """
  @spec lease_cost(%{
          cpu_count: non_neg_integer(),
          memory_gb: non_neg_integer(),
          disk_gb: non_neg_integer(),
          duration_seconds: integer()
        }) :: non_neg_integer()
  def lease_cost(%{duration_seconds: dur} = _attrs) when dur < 0, do: 0

  def lease_cost(%{
        cpu_count: cpu,
        memory_gb: mem,
        disk_gb: disk,
        duration_seconds: dur
      }) do
    rates =
      Application.get_env(:harmont_core, :billing_rates, @default_rates)

    cpu_rate = Map.get(rates, :cpu, @default_rates.cpu)
    ram_rate = Map.get(rates, :ram, @default_rates.ram)
    disk_rate = Map.get(rates, :disk, @default_rates.disk)

    total_micro_cents =
      cpu * dur * cpu_rate +
        mem * dur * ram_rate +
        disk * dur * disk_rate

    div(total_micro_cents, 1_000_000)
  end
end

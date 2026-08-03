defmodule Harmont.Orgs.Slug do
  @moduledoc """
  Slug helpers for organization names and email addresses.

  - `normalize/1` — lowercases text, replaces non-alphanumeric characters with
    hyphens, collapses consecutive hyphens, and trims leading/trailing hyphens.
  - `email_to_slug/1` — converts an email address to a slug by joining the
    local part and domain components (e.g. `a.b@c.org` → `a-b-c`).
  - `pick_free_slug/2` — walks `base`, `base-2`, `base-3`… until a slug is
    not already taken in the `organizations` table.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Orgs.Organization

  @doc """
  Normalizes `text` into a URL-safe slug.

  Steps:
  1. Downcase.
  2. Replace every non-alphanumeric character with `-`.
  3. Collapse consecutive hyphens into one.
  4. Trim leading and trailing hyphens.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Fallback slug for input that normalizes to nothing (e.g. an all-symbol
  # local part, or a malformed address with no usable characters). Keeps the
  # caller from ever receiving an empty slug.
  @default_slug "user"

  @doc """
  Converts an email address to a slug.

  The local part and each domain label are each normalized, then joined with
  hyphens. For example, `a.b@c.org` → `a-b-c`.

  Tolerant of malformed input: an address without `@` is treated as a single
  part, and input that normalizes to nothing falls back to `"#{@default_slug}"`
  so the result is never empty.
  """
  @spec email_to_slug(String.t()) :: String.t()
  def email_to_slug(email) when is_binary(email) do
    {local, domain_parts} =
      case String.split(email, "@", parts: 2) do
        [local, domain] -> {local, String.split(domain, ".")}
        [single] -> {single, []}
      end

    slug =
      [local | domain_parts]
      |> Enum.map(&normalize/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("-")

    if slug == "", do: @default_slug, else: slug
  end

  @doc """
  Returns the first slug in the sequence `base`, `base-2`, `base-3`, … that is
  not already present in the `organizations.slug` column.

  Performs individual existence checks against the database using `repo`.
  """
  @spec pick_free_slug(String.t(), module()) :: String.t()
  def pick_free_slug(base, repo) when is_binary(base) do
    do_pick(base, base, 2, repo)
  end

  defp do_pick(candidate, base, n, repo) do
    taken? =
      repo.exists?(from(o in Organization, where: o.slug == ^candidate))

    if taken? do
      do_pick("#{base}-#{n}", base, n + 1, repo)
    else
      candidate
    end
  end
end

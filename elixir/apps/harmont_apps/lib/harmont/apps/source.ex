defmodule Harmont.Apps.Source do
  @moduledoc """
  Provider-agnostic helpers for turning an inbound webhook into a build's source
  archive, shared by the provider-agnostic fan-out (`Harmont.Apps.Engine`).

  Two concerns live here because they MUST be identical across providers:

    * `flatten_source_tarball/1` — strip the single wrapper directory that
      provider archives (GitHub `<owner>-<repo>-<sha>/`, Bitbucket
      `<owner>-<repo>-<short-sha>/`) wrap every entry under, so `.hm/` + the
      repo root land at the tarball root. The render sandbox and the in-VM agent
      both extract the stored source WITHOUT `--strip-components`; without this
      flattening, `.hm/` sits one directory deep and pipeline discovery finds
      nothing.

    * `existing_webhook_build/3` — the at-least-once idempotency guard. Webhook
      fan-out runs inside an Oban worker (`max_attempts > 1`) and providers
      redeliver webhooks at-least-once, so the same `(pipeline, commit)` can
      re-enter the fan-out. Before creating a build, look it up here; a hit means
      reuse the existing build (do NOT `create_build` again — each new build
      leases a fresh sandbox VM + mints a new runner token).
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Builds.Build
  alias Harmont.Pipelines.Pipeline

  @doc """
  Strip the single common top-level wrapper directory from a `.tar.gz`.

  Provider source archives wrap all entries under one top-level dir
  (`<owner>-<repo>-<sha>/`). The render sandbox and the in-VM agent both extract
  the stored source WITHOUT `--strip-components`, so strip that single common
  wrapper here, at storage time, leaving `.hm/` + the repo root at the top level.
  Idempotent: a tarball with no single common top-level segment is returned
  unchanged.
  """
  @spec flatten_source_tarball(binary()) :: binary()
  def flatten_source_tarball(gz_bytes) when is_binary(gz_bytes) do
    case :erl_tar.extract({:binary, gz_bytes}, [:memory, :compressed]) do
      {:ok, entries} -> maybe_strip_common_dir(gz_bytes, entries)
      {:error, _} -> gz_bytes
    end
  end

  defp maybe_strip_common_dir(original, entries) do
    names = Enum.map(entries, fn {n, _} -> List.to_string(n) end)

    case common_top_segment(names) do
      nil ->
        original

      top ->
        prefix = top <> "/"

        repacked =
          for {name, content} <- entries,
              sname = List.to_string(name),
              # Keep only entries genuinely UNDER the wrapper dir. This drops the
              # dir's own entry (`<top>` or `<top>/`, which strips to "") so it
              # isn't repacked as a stray top-level file.
              String.starts_with?(sname, prefix),
              rel = String.replace_prefix(sname, prefix, ""),
              rel != "" do
            {String.to_charlist(rel), content}
          end

        repack_targz(repacked)
    end
  end

  # Returns the single top-level directory all entries live under, or nil if
  # there isn't one (already flat / mixed). Tolerates the provider's explicit
  # directory entry (`<owner>-<repo>-<sha>/` extracts to `<owner>-<repo>-<sha>`
  # with no trailing slash) and requires at least one real file under the dir so
  # a degenerate dir-only archive isn't repacked to nothing.
  defp common_top_segment([]), do: nil

  defp common_top_segment(names) do
    tops =
      names
      |> Enum.map(fn n -> n |> String.split("/", parts: 2) |> hd() end)
      |> Enum.uniq()

    case tops do
      [only] -> top_if_common(only, names)
      _ -> nil
    end
  end

  # The single shared top segment `only`, but only when it is a genuine common
  # prefix: at least one name lives under `only/`, and every name is either the
  # bare dir entry or under that prefix. Otherwise nil (don't strip).
  defp top_if_common(only, names) do
    prefix = only <> "/"

    if Enum.any?(names, &String.starts_with?(&1, prefix)) and
         Enum.all?(names, fn n -> n == only or String.starts_with?(n, prefix) end) do
      only
    else
      nil
    end
  end

  defp repack_targz(entries) do
    tmp =
      Path.join(System.tmp_dir!(), "harmont-src-#{System.unique_integer([:positive])}.tar.gz")

    try do
      {:ok, tar} = :erl_tar.open(String.to_charlist(tmp), [:write, :compressed])
      Enum.each(entries, fn {name, content} -> :ok = :erl_tar.add(tar, content, name, []) end)
      :ok = :erl_tar.close(tar)
      File.read!(tmp)
    after
      File.rm(tmp)
    end
  end

  @doc """
  The webhook-sourced build for this `(pipeline, commit)`, if one already exists.

  Source is pinned to `"webhook"` so a manual or API build at the same commit
  doesn't suppress the webhook build (different origin, different intent). When
  several exist (shouldn't, but a torn earlier attempt could leave two), the
  lowest build number wins so retries converge on the first one created.

  `repo` is the Ecto repo module (so callers can pass a sandboxed repo in tests).
  """
  @spec existing_webhook_build(Pipeline.t(), String.t(), module()) :: Build.t() | nil
  def existing_webhook_build(%Pipeline{id: pipeline_id}, commit, repo) do
    repo.one(
      from(b in Build,
        where: b.pipeline_id == ^pipeline_id and b.commit == ^commit and b.source == "webhook",
        order_by: [asc: b.number],
        limit: 1
      )
    )
  end
end

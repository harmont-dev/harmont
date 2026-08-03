defmodule Harmont.Engine.Render do
  @moduledoc """
  Renders a pipeline's v0 IR by running the user's `.hm/*.py` inside a
  short-lived sandbox — never in the engine process. Two execs on one sandbox:
  (1) fetch+extract the source (runner token present, no user code), (2) run the
  bundled `hm` CLI (no token present) to emit the IR. Returns the IR JSON from
  stdout, or a `{:render_failed, detail}` error mapped to a `PlanRejected`
  upstream.

  The render sandbox is provisioned from a base image (Runloop blueprint) that
  bakes the `hm` binary plus its Python runtime (`python3` + `croniter` +
  `python-dateutil`); `hm` embeds the harmont DSL, so nothing is installed at
  render time. `hm render <slug>` prints one pipeline's v0 IR; `hm pipelines`
  prints the full discovery envelope.
  """
  require Logger
  alias Harmont.Sandboxes

  @render_spec %{cpu_count: 2, memory_gb: 4.0, disk_gb: 20.0, name: "render"}
  @hard_cap_ms 120_000

  @spec render(module(), %{
          source_url: String.t(),
          source_sha256: String.t(),
          slug: String.t(),
          runner_token: String.t()
        }) :: {:ok, String.t()} | {:error, {:render_failed, String.t()}}
  def render(backend, %{source_url: url, source_sha256: sha, slug: slug, runner_token: tok}) do
    with {:ok, handle} <- provision(backend),
         :ok <- ready(backend, handle) do
      try do
        do_render(backend, handle, url, sha, slug, tok)
      after
        backend.teardown(handle)
        delete_render(backend, handle)
      end
    end
  end

  defp provision(backend) do
    spec = Map.put(@render_spec, :name, "render-#{System.unique_integer([:positive])}")

    case backend.provision(spec) do
      {:ok, h} ->
        _ = record_render(backend, h)
        {:ok, h}

      {:error, e} ->
        {:error, {:render_failed, "render sandbox provision failed: #{inspect(e)}"}}
    end
  end

  # Render sandboxes have no job/build; track them as kind "render" so a failed
  # teardown is still reachable by the reaper (deleted here on the happy path).
  defp record_render(backend, handle) do
    if function_exported?(backend, :handle_id, 1) do
      _ =
        Sandboxes.record(%{
          provider: HarmontVm.Backend.provider(),
          external_id: backend.handle_id(handle),
          kind: "render"
        })
    end

    :ok
  end

  defp delete_render(backend, handle) do
    if function_exported?(backend, :handle_id, 1) do
      Sandboxes.mark_deleted(HarmontVm.Backend.provider(), backend.handle_id(handle))
    end

    :ok
  end

  defp ready(backend, handle) do
    if function_exported?(backend, :await_ready, 2) do
      case backend.await_ready(handle, @hard_cap_ms) do
        :ok -> :ok
        {:error, e} -> {:error, {:render_failed, "render sandbox not ready: #{inspect(e)}"}}
      end
    else
      :ok
    end
  end

  defp do_render(backend, handle, url, sha, slug, tok) do
    with {:ok, _} <- exec(backend, handle, fetch_cmd(url, sha, tok), "source fetch"),
         {:ok, %{stdout: ir}} <- exec(backend, handle, render_cmd(slug), "render") do
      ensure_nonempty(ir, slug)
    end
  end

  # `hm render` exiting 0 while printing nothing is never a valid IR. Without
  # this guard the empty string flows into the planner's `Jason.decode("")`,
  # which fails with an opaque `%Jason.DecodeError{data: ""}` that gets dumped
  # verbatim into the customer's error envelope. Some sandbox backends can yield
  # an empty exec result even on exit 0 (e.g. a forked snapshot whose renderer
  # output was dropped), so catch it here and surface a precise, actionable
  # render failure instead. Logged so prod (docker logs) shows the empty render.
  defp ensure_nonempty(ir, slug) do
    if String.trim(ir) == "" do
      Logger.warning("render: hm render #{slug} exited 0 with empty stdout (no IR emitted)")

      {:error,
       {:render_failed,
        "pipeline render produced no output: `hm render #{slug}` exited 0 but " <>
          "printed no IR. The render sandbox may be missing the hm renderer or " <>
          "its output was dropped."}}
    else
      {:ok, ir}
    end
  end

  # exec 1: token present, NO user code runs here.
  defp fetch_cmd(url, sha, tok) do
    verify =
      if sha == "" do
        ""
      else
        "echo #{shq(sha)}'  /tmp/src.tar.gz' | sha256sum -c -\n"
      end

    """
    set -euo pipefail
    curl -fsSL -H 'Authorization: Bearer '#{shq(tok)} #{shq(url)} -o /tmp/src.tar.gz
    #{verify}mkdir -p /tmp/co && tar -xzf /tmp/src.tar.gz -C /tmp/co
    """
  end

  # exec 2: NO token. `hm render <slug>` emits the slug's v0 IR to stdout
  # (exit non-zero with the available slugs on stderr if the slug is unknown).
  defp render_cmd(slug) do
    """
    set -euo pipefail
    cd /tmp/co && hm render #{shq(slug)}
    """
  end

  defp exec(backend, handle, cmd, label) do
    backend.exec(handle, %{command: cmd, hard_cap_ms: @hard_cap_ms})
    |> classify_exec(label, false)
  end

  # Like exec/4 but a non-zero exit is the *user's* program failing (their
  # `.hm/*.py` crashed), not an infra fault — tagged distinctly so the
  # caller can report it to the user and stop retrying.
  defp exec_user(backend, handle, cmd, label) do
    backend.exec(handle, %{command: cmd, hard_cap_ms: @hard_cap_ms})
    |> classify_exec(label, true)
  end

  @spec classify_exec({:ok, map()} | {:error, term()}, String.t(), boolean()) ::
          {:ok, map()} | {:error, {:user_code | :render_failed, String.t()}}
  # Pure classifier for a backend.exec/2 result. `user_step?` true means a
  # non-zero exit is user code failing (`{:user_code, _}`); false means infra
  # (`{:render_failed, _}`). A backend-level error is always infra.
  @doc false
  def classify_exec({:ok, %{exit_code: 0} = r}, _label, _user_step?), do: {:ok, r}

  def classify_exec({:ok, %{exit_code: code, stderr: err, stdout: out}}, label, true),
    do: {:error, {:user_code, "#{label} failed (exit #{code}): #{trim(err, out)}"}}

  def classify_exec({:ok, %{exit_code: code, stderr: err, stdout: out}}, label, false),
    do: {:error, {:render_failed, "#{label} failed (exit #{code}): #{trim(err, out)}"}}

  def classify_exec({:error, e}, label, _user_step?),
    do: {:error, {:render_failed, "#{label} error: #{inspect(e)}"}}

  # stderr if present (Freestyle separates it), else stdout (Local merges).
  defp trim("", out), do: String.slice(out, 0, 4000)
  defp trim(err, _), do: String.slice(err, 0, 4000)

  @doc """
  Render the **whole** pipeline registry for a repo by running its `.hm/*.py`
  in a sandbox. Two execs on one sandbox: (1) fetch+extract the GitHub tarball
  (installation token present, NO user code), (2) dump the registry (NO token).
  Returns the registry envelope JSON, or `{:error, {:render_failed, detail}}`.
  """
  @spec discover(module(), %{tarball_url: String.t(), token: String.t()}) ::
          {:ok, String.t()} | {:error, {:render_failed | :user_code, String.t()}}
  def discover(backend, %{tarball_url: url, token: token}) do
    with {:ok, handle} <- provision(backend),
         :ok <- ready(backend, handle) do
      try do
        do_discover(backend, handle, url, token)
      after
        backend.teardown(handle)
        delete_render(backend, handle)
      end
    end
  end

  # Only the discover step gets user-code tagging: a discovery crash has no
  # build/check entity to surface it, so we must report it explicitly. The
  # render path's user-code failures already surface as a failed build + check
  # run (the engine's {:plan_rejected} path), so it stays on plain exec/4.
  defp do_discover(backend, handle, url, token) do
    with {:ok, _} <- exec(backend, handle, gh_fetch_cmd(url, token), "source fetch"),
         {:ok, %{stdout: env}} <- exec_user(backend, handle, discover_cmd(), "discover") do
      {:ok, env}
    end
  end

  # exec 1: GitHub tarball via Bearer token (api.github.com 302 -> signed
  # codeload; curl -L follows). NO user code runs here.
  defp gh_fetch_cmd(url, token) do
    """
    set -euo pipefail
    curl -fsSL -H 'Authorization: Bearer '#{shq(token)} #{shq(url)} -o /tmp/src.tar.gz
    mkdir -p /tmp/co && tar -xzf /tmp/src.tar.gz --strip-components=1 -C /tmp/co
    """
  end

  # exec 2: NO token. `hm pipelines` dumps the full discovery envelope
  # (slugs + names + allow_manual + triggers + definitions) to stdout.
  defp discover_cmd do
    """
    set -euo pipefail
    cd /tmp/co && hm pipelines
    """
  end

  # Returns a single-quoted shell literal. Concatenate it directly into the
  # command (`-H 'Prefix: '#{shq(x)}`); never nest it inside a double-quoted
  # argument (`-H "Prefix: #{shq(x)}"`), or the single quotes become literal
  # bytes in the value and the token/header is corrupted (GitHub → 401).
  defp shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end

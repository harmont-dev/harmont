defmodule Harmont.Engine.Bootstrap do
  @moduledoc """
  Renders the bash script that boots `harmont-agent` inside a freshly-provisioned
  job VM. The script hands the agent the build/job identifiers and the runner
  token it uses to authenticate its WebSocket back to the engine
  (`/v0/agent/connect`). The token is written to a `0600` temp file and passed
  via `--token-file` rather than exported into the environment.

  The agent is launched as **root** (`sudo`). It must create root-owned paths —
  the disk spool (default `/var/lib/harmont-agent`) and the `/workspace` it
  extracts source into — both of which it opens BEFORE it reports the job
  started; and a job's own commands (`apt-get`, package installs, docker)
  routinely need root. Job VMs are single-tenant and disposable, so running the
  agent privileged is the right, simplest model. Without it the agent dies on a
  `Permission denied` while creating those dirs and never connects, so the
  engine only ever observes the 90s `agent_connect_deadline`.
  """

  @spec render_agent(%{
          build_id: String.t(),
          job_id: String.t(),
          api_url: String.t(),
          token: String.t()
        }) :: String.t()
  def render_agent(%{build_id: b, job_id: j, api_url: url, token: tok}) do
    # single-quote every interpolated value (escaping any embedded quote) so an
    # unexpected alphabet can't break the script or inject shell. The ids are
    # UUIDs and api_url is config today, so this is defense-in-depth, but it's
    # free and keeps the quoting uniform.
    #
    # Threat model for the token: it is written to a private (0600, via
    # `umask 077`) temp file and handed to the agent with `--token-file`, NOT
    # exported into the environment. An env/argv token is readable via /proc by
    # every child process of the job; the file keeps it out of both. The VM is
    # single-tenant per job, so this is defense-in-depth, but it's cheap and
    # closes the one place the runner secret was broadly readable. The token
    # file is written 0600 as the unprivileged login user; root (the agent runs
    # under sudo) still reads it, so it stays unreadable to the job's children.
    #
    # `sudo -n -H`: run the agent as root non-interactively. Job VMs grant the
    # login user passwordless sudo; `-n` fails fast instead of blocking on a
    # password prompt if that ever changes. `-H` sets HOME=/root for the agent
    # so tools that read $HOME (e.g. rustup) resolve correctly — the agent's
    # job children inherit it. See the moduledoc for why root.
    """
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    tokfile="$(mktemp)"
    printf '%s' #{shq(tok)} > "$tokfile"
    exec sudo -n -H /usr/local/bin/harmont-agent \\
      --build-id #{shq(b)} --job-id #{shq(j)} --api-url #{shq(url)} \\
      --token-file "$tokfile"
    """
  end

  defp shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end

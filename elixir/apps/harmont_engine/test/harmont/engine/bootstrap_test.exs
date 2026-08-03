defmodule Harmont.Engine.BootstrapTest do
  use ExUnit.Case, async: true
  alias Harmont.Engine.Bootstrap

  test "renders an agent-launch command pointing at the engine ws url" do
    script =
      Bootstrap.render_agent(%{
        build_id: "b1",
        job_id: "j1",
        api_url: "https://api.harmont.dev",
        token: "tok"
      })

    assert script =~ "/usr/local/bin/harmont-agent"
    assert script =~ "--build-id 'b1'"
    assert script =~ "--job-id 'j1'"
    assert script =~ "--api-url 'https://api.harmont.dev'"
  end

  test "writes the token to a 0600 file, not the process environment" do
    script =
      Bootstrap.render_agent(%{
        build_id: "b",
        job_id: "j",
        api_url: "u",
        token: "secret-tok"
      })

    # The token must never be exported into the agent's environment — that is
    # readable via /proc by every child process of the job.
    refute script =~ "export HARMONT_TOKEN="
    # It lives in a private (0600 / umask 077) temp file instead.
    assert script =~ "umask 077" or script =~ "chmod 600"
    # And the agent is told to read it via --token-file.
    assert script =~ "--token-file"
    assert script =~ "'secret-tok'"
  end

  test "launches the agent as root (sudo) so it can create /workspace + spool and run privileged commands" do
    # The agent creates root-owned dirs (the disk spool and /workspace) and
    # opens them BEFORE it reports the job started; job VMs run as a non-root
    # login user, so without root create_dir_all fails EACCES and the agent
    # exits before connecting (engine sees agent_connect_deadline). Run it under
    # passwordless sudo, non-interactively.
    script =
      Bootstrap.render_agent(%{
        build_id: "b",
        job_id: "j",
        api_url: "u",
        token: "tok"
      })

    # -H sets HOME=/root for the agent (and thus its job children), so tools
    # that read $HOME (rustup) resolve correctly.
    assert script =~ "exec sudo -n -H /usr/local/bin/harmont-agent"
  end
end

defmodule HarmontApi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # No supervised children yet. The Swoosh mailer (Task 2), OAuth, and
    # WebAuthn edges are API-adapter modules that need no process here.
    # The HTTP surface is served by harmont_web's single endpoint, which
    # mounts HarmontApi.Router.
    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: HarmontApi.Supervisor)
  end
end

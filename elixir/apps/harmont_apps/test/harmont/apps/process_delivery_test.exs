defmodule Harmont.Apps.ProcessDeliveryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.ProcessDelivery
  alias Harmont.Repo

  # A fake provider whose `decode/2` keys off the event name so each test can
  # deterministically steer `Harmont.Apps.Engine.handle/3` to the response class
  # the worker's result mapping must translate. The worker no longer dispatches
  # to a per-provider handler MFA — it always calls the engine — so we exercise
  # the mapping through the real engine.
  defmodule FakeProvider do
    use Harmont.Apps.Provider

    alias Harmont.Apps.Event

    @impl true
    def id, do: :fakep
    @impl true
    def event_header, do: "x-fakep-event"
    @impl true
    def delivery_header, do: "x-fakep-delivery"
    @impl true
    def verify_signature(_s, _r, _h), do: true

    @impl true
    def decode("ack", _j), do: {:ok, :ack}
    def decode("unsupported", _j), do: {:error, :unsupported}
    def decode("bad", _j), do: {:error, :boom}

    def decode("push", _j) do
      # A push referencing an installation that does not exist -> the engine's
      # resolve_org returns {:retry, 503, _}, i.e. a 5xx the worker must retry.
      {:ok,
       [
         Event.push(%{
           provider: :fakep,
           installation_external_id: "no-such-install-#{System.unique_integer([:positive])}",
           owner: "o",
           repo: "r",
           commit: "deadbeef",
           branch: "main"
         })
       ]}
    end

    @impl true
    def fetch_token(_i), do: {:ok, "t"}
    @impl true
    def download_tarball(_c, _o, _r, _ref), do: {:ok, <<>>}
    @impl true
    def create_check(_b, _c, _client), do: {:ok, "c"}
    @impl true
    def report(_c, _s, _client), do: :ok
  end

  setup do
    prevp = Application.get_env(:harmont_apps, :providers, [])

    on_exit(fn ->
      Application.put_env(:harmont_apps, :providers, prevp)
    end)

    Application.put_env(:harmont_apps, :providers, fakep: FakeProvider)
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  defp job(provider, event \\ "push"),
    do: %Oban.Job{args: %{"provider" => provider, "event" => event, "payload" => %{}}}

  test "unknown provider is terminal (no crash, no retry)" do
    assert :ok = ProcessDelivery.perform(job("nope"))
  end

  test "a <500 engine result is terminal :ok" do
    # decode -> {:ok, :ack} -> engine {200, "ok"} -> :ok
    assert :ok = ProcessDelivery.perform(job("fakep", "ack"))
    # decode -> {:error, :unsupported} -> engine {204, ""} -> :ok
    assert :ok = ProcessDelivery.perform(job("fakep", "unsupported"))
    # decode -> {:error, _} -> engine {400, _} -> :ok
    assert :ok = ProcessDelivery.perform(job("fakep", "bad"))
  end

  test "a >=500 engine result is an error (Oban retry)" do
    # push for an unknown installation -> engine {503, _} -> retry
    assert {:error, {:handle_failed, 503}} = ProcessDelivery.perform(job("fakep", "push"))
  end
end

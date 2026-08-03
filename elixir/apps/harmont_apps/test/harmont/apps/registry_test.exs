defmodule Harmont.Apps.RegistryTest do
  use ExUnit.Case, async: false

  alias Harmont.Apps.Registry

  defmodule FakeProvider do
    use Harmont.Apps.Provider
    @impl true
    def id, do: :fake
    @impl true
    def event_header, do: "x-fake-event"
    @impl true
    def delivery_header, do: "x-fake-delivery"
    @impl true
    def verify_signature(_s, _r, _h), do: true
    @impl true
    def decode(_e, _j), do: {:ok, []}
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
    prev = Application.get_env(:harmont_apps, :providers, [])
    on_exit(fn -> Application.put_env(:harmont_apps, :providers, prev) end)
    Application.put_env(:harmont_apps, :providers, fake: FakeProvider)
    :ok
  end

  test "fetch/1 resolves a registered provider by atom or string id" do
    assert {:ok, FakeProvider} = Registry.fetch(:fake)
    assert {:ok, FakeProvider} = Registry.fetch("fake")
  end

  test "fetch/1 returns :error for an unknown provider" do
    assert :error = Registry.fetch("nope")
  end
end

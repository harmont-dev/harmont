defmodule Harmont.Apps.WebhookTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Harmont.Repo
  import Plug.Test
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.ProcessDelivery
  alias Harmont.Apps.Webhook
  alias Harmont.Repo
  alias Harmont.Vcs

  @secret "0123456789abcdef0123456789abcdef"

  defmodule TestProvider do
    # Declares a non-default queue so the per-job override the webhook applies is
    # observable in the inserted Oban job.
    use Harmont.Apps.Provider, queue: :bitbucket

    @impl true
    def id, do: :testp
    @impl true
    def event_header, do: "x-testp-event"
    @impl true
    def delivery_header, do: "x-testp-delivery"
    @impl true
    def verify_signature(secret, raw, headers) do
      sig = Enum.find_value(headers, fn {k, v} -> if k == "x-testp-sig", do: v end)
      expected = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
      is_binary(sig) and Plug.Crypto.secure_compare(sig, expected)
    end
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
    prev_p = Application.get_env(:harmont_apps, :providers, [])
    prev_s = Application.get_env(:harmont_apps, :secrets, [])
    on_exit(fn ->
      Application.put_env(:harmont_apps, :providers, prev_p)
      Application.put_env(:harmont_apps, :secrets, prev_s)
    end)
    Application.put_env(:harmont_apps, :providers, testp: TestProvider)
    Application.put_env(:harmont_apps, :secrets, testp: fn -> @secret end)
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  defp sign(raw), do: :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower)

  test "unknown provider -> 404" do
    conn =
      conn(:post, "/webhooks/nope", "{}")
      |> assign(:raw_body, ["{}"])
      |> assign(:webhook_provider, "nope")

    conn = Webhook.call(conn, [])
    assert conn.status == 404
  end

  test "bad signature -> 401" do
    raw = ~s({"x":1})
    conn =
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-delivery", "d-1")
      |> put_req_header("x-testp-sig", "deadbeef")

    conn = Webhook.call(conn, [])
    assert conn.status == 401
  end

  test "good signature -> 202 and reserves the delivery" do
    raw = ~s({"x":1})
    conn =
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-delivery", "d-2")
      |> put_req_header("x-testp-sig", sign(raw))

    conn = Webhook.call(conn, [])
    assert conn.status == 202
    assert :duplicate = Vcs.reserve_delivery("testp", "d-2", "push")
  end

  test "the delivery is enqueued on the provider's capability queue, not the worker default" do
    raw = ~s({"x":4})

    conn =
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-delivery", "d-queue")
      |> put_req_header("x-testp-sig", sign(raw))

    conn = Webhook.call(conn, [])
    assert conn.status == 202

    # TestProvider declares capabilities().queue == :bitbucket; the per-job
    # override must place the job there even though ProcessDelivery's compiled
    # default queue is :gh_app.
    assert_enqueued(worker: ProcessDelivery, queue: :bitbucket, args: %{"provider" => "testp"})
  end

  test "a validly-signed delivery with NO delivery header is still accepted (202), not dropped" do
    raw = ~s({"x":2})

    conn =
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-sig", sign(raw))

    # deliberately NO x-testp-delivery header
    conn = Webhook.call(conn, [])
    assert conn.status == 202
  end

  test "emits hmex.apps.webhook with result :enqueued then :duplicate on a resend" do
    raw = ~s({"x":9})
    handler = "apps-webhook-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:hmex, :apps, :webhook],
      fn _e, m, meta, _ -> send(test_pid, {:tel, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    deliver = fn ->
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-delivery", "d-tel")
      |> put_req_header("x-testp-sig", sign(raw))
      |> Webhook.call([])
    end

    assert deliver.().status == 202

    assert_receive {:tel, %{count: 1},
                    %{provider: "testp", event: "push", result: :enqueued}}

    assert deliver.().status == 200

    assert_receive {:tel, %{count: 1},
                    %{provider: "testp", event: "push", result: :duplicate}}
  end

  test "a delivery with NO delivery header still dedups on resend (body-hash id)" do
    raw = ~s({"x":3})

    deliver = fn ->
      conn(:post, "/webhooks/testp", raw)
      |> assign(:raw_body, [raw])
      |> assign(:webhook_provider, "testp")
      |> put_req_header("x-testp-event", "push")
      |> put_req_header("x-testp-sig", sign(raw))
      # deliberately NO x-testp-delivery header on either delivery
      |> Webhook.call([])
    end

    # First delivery reserves a synthesized body-sha256 dedup id.
    assert deliver.().status == 202

    # An identical replay/retry collides on that id and is deduped, not refunded.
    assert deliver.().status == 200

    # The reserved id is content-addressed over the raw body.
    expected_id = "body-sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
    assert :duplicate = Vcs.reserve_delivery("testp", expected_id, "push")
  end
end

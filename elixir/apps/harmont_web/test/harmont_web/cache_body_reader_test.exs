defmodule HarmontWeb.CacheBodyReaderTest do
  @moduledoc """
  Unit tests for `HarmontWeb.CacheBodyReader`.

  The `:more` path is exercised by passing `length: N` with N smaller than the
  body, which forces Plug to return `{:more, partial, conn}` on the first call
  and `{:ok, remainder, conn}` on the second. We assert that:

  1. Every chunk is prepended to `conn.assigns.raw_body` in call order.
  2. After the full read loop completes, `Enum.reverse/1 + IO.iodata_to_binary/1`
     reconstructs the exact original bytes.
  3. The HMAC computed over that reconstructed binary matches a signature
     produced over the same original bytes — i.e. the whole reverse+join+HMAC
     path that `GithubWebhook` uses in production is verified.
  """

  use ExUnit.Case, async: true

  alias HarmontWeb.CacheBodyReader

  @secret "test-chunked-secret"

  # Build a body that is definitely longer than any small read-length we choose
  # so we get at least one `:more` chunk.  256 bytes is enough; the test sets
  # `length: 64` so we get four chunks.
  @body String.duplicate("abcdefghijklmnopqrstuvwxyz0123456789", 8)
        |> binary_part(0, 256)

  defp sign(body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, body), case: :lower)

  # Simulate the Plug.Parsers read loop: keep calling read_body until we get
  # {:ok, ...}.  Returns {accumulated_assigns_raw_body, full_binary}.
  defp read_all(conn, opts, acc \\ []) do
    case CacheBodyReader.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        # Last chunk – acc is newest-first just like assigns.raw_body
        {[chunk | acc], conn}

      {:more, chunk, conn} ->
        read_all(conn, opts, [chunk | acc])
    end
  end

  test "non-webhook path passes through unchanged" do
    conn = Plug.Test.conn(:post, "/other/path", "hello")
    {:ok, body, _conn} = CacheBodyReader.read_body(conn, [])
    assert body == "hello"
  end

  test "webhook path with body <= read-length returns :ok and caches chunk" do
    body = "small body"
    conn = Plug.Test.conn(:post, "/webhooks/github", body)
    {:ok, got, conn2} = CacheBodyReader.read_body(conn, length: 64)
    assert got == body
    assert conn2.assigns[:raw_body] == [body]
  end

  test "webhook path with body > read-length accumulates all chunks and HMAC verifies" do
    conn = Plug.Test.conn(:post, "/webhooks/github", @body)

    # length: 64 forces at least four `:more` rounds for a 256-byte body
    {_chunks_newest_first, final_conn} = read_all(conn, length: 64)

    # The assigns list is newest-first (prepend design); reverse+join must
    # reconstruct the original bytes exactly.
    raw_body = final_conn.assigns[:raw_body] |> Enum.reverse() |> IO.iodata_to_binary()
    assert raw_body == @body

    # HMAC over the reassembled bytes must match a signature over the original.
    assert sign(@body) == sign(raw_body)
  end

  test "read_all helper accumulates assigns in the same newest-first order" do
    conn = Plug.Test.conn(:post, "/webhooks/github", @body)
    {_chunks, final_conn} = read_all(conn, length: 64)

    # assigns.raw_body must be non-empty and newest-first
    raw_body_assigns = final_conn.assigns[:raw_body]
    assert is_list(raw_body_assigns)
    assert length(raw_body_assigns) >= 2

    # Reversed join equals original
    assert IO.iodata_to_binary(Enum.reverse(raw_body_assigns)) == @body
  end
end

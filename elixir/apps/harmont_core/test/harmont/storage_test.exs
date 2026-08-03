defmodule Harmont.StorageTest do
  @moduledoc """
  Unit tests for the pluggable blob storage behaviour and its Local adapter.

  These exercise the dispatcher (`Harmont.Storage`) and the filesystem-backed
  `Harmont.Storage.Local` round-trip — the dev/test adapter selected by default
  (config/test.exs). The Gcs adapter is a Plan-8 stub and is not tested for I/O
  here (it has no credentials in the suite); we only assert it fails fast when
  selected without a bucket.
  """
  use ExUnit.Case, async: true

  alias Harmont.Storage

  setup do
    # Isolate each test under its own tmp root so put/get can't see another
    # test's objects. Restore the suite default afterwards.
    prev = Application.get_env(:harmont, Storage.Local)

    root =
      Path.join(System.tmp_dir!(), "harmont-storage-test-#{System.unique_integer([:positive])}")

    Application.put_env(:harmont, Storage.Local, root: root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:harmont, Storage.Local, prev)
      else
        Application.delete_env(:harmont, Storage.Local)
      end
    end)

    {:ok, root: root}
  end

  describe "Local put/get round-trip" do
    test "stores and reads back bytes at a key" do
      key = Storage.source_key("b1")
      bytes = :crypto.strong_rand_bytes(256)

      assert {:ok, uri} = Storage.put(key, bytes)
      assert is_binary(uri)
      assert {:ok, ^bytes} = Storage.get(key)
    end

    test "get of a missing key returns :not_found" do
      assert {:error, :not_found} = Storage.get(Storage.source_key("nope"))
    end

    test "put creates intermediate directories", %{root: root} do
      key = "builds/deep/uuid/source.tar.gz"
      assert {:ok, _} = Storage.put(key, "x")
      assert File.exists?(Path.join(root, key))
    end
  end

  describe "Local signed_url" do
    test "returns the internal serving-endpoint path for a source key" do
      assert {:ok, "/api/v0/internal/builds/abc/source.tar.gz"} =
               Storage.signed_url(Storage.source_key("abc"))
    end
  end

  describe "source_key/1" do
    test "builds the canonical key" do
      assert Storage.source_key("123") == "builds/123/source.tar.gz"
    end
  end

  describe "Gcs stub (creds-gated)" do
    test "raises a clear error when selected without a bucket configured" do
      prev = Application.get_env(:harmont, Storage.Gcs)
      Application.delete_env(:harmont, Storage.Gcs)
      on_exit(fn -> if prev, do: Application.put_env(:harmont, Storage.Gcs, prev) end)

      assert_raise RuntimeError, ~r/no bucket is configured/, fn ->
        Storage.Gcs.get(Storage.source_key("x"))
      end
    end
  end
end

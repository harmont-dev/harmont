defmodule Harmont.Storage.GcsTest do
  # async: false — these tests mutate global app env (Application.put_env) for
  # the adapter config, which would race other async modules on the same key.
  use ExUnit.Case, async: false

  alias Harmont.Storage.Gcs

  # Configure the adapter to use a fake token and a Req.Test plug instead of
  # talking to Goth / real GCS.
  setup do
    Application.put_env(:harmont, Harmont.Storage.Gcs,
      bucket: "test-bucket",
      token_fun: fn -> {:ok, "fake-token"} end,
      req_options: [plug: {Req.Test, Harmont.Storage.GcsTest}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:harmont, Harmont.Storage.Gcs) end)
    :ok
  end

  test "put uploads the bytes to the media endpoint with a bearer token" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "storage.googleapis.com"
      assert conn.request_path == "/upload/storage/v1/b/test-bucket/o"
      assert conn.query_string =~ "uploadType=media"
      assert conn.query_string =~ "name=builds%2Fabc%2Fsource.tar.gz"
      assert ["Bearer fake-token"] == Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "TARBALL"
      Req.Test.json(conn, %{"name" => "builds/abc/source.tar.gz"})
    end)

    assert {:ok, "gs://test-bucket/builds/abc/source.tar.gz"} =
             Gcs.put("builds/abc/source.tar.gz", "TARBALL")
  end

  test "put surfaces a non-2xx as an error" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "denied"})
    end)

    assert {:error, {:gcs_put, 403, _}} = Gcs.put("builds/abc/source.tar.gz", "TARBALL")
  end

  test "put surfaces a transport error" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, {:gcs_put, %Req.TransportError{reason: :econnrefused}}} =
             Gcs.put("builds/abc/source.tar.gz", "TARBALL")
  end

  test "get downloads the object bytes" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "storage.googleapis.com"
      assert conn.request_path == "/storage/v1/b/test-bucket/o/builds%2Fabc%2Fsource.tar.gz"
      assert conn.query_string == "alt=media"
      assert ["Bearer fake-token"] == Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.send_resp(conn, 200, "TARBALL-BYTES")
    end)

    assert {:ok, "TARBALL-BYTES"} = Gcs.get("builds/abc/source.tar.gz")
  end

  test "get maps 404 to :not_found" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert {:error, :not_found} = Gcs.get("builds/missing/source.tar.gz")
  end

  test "get surfaces a transport error" do
    Req.Test.stub(Harmont.Storage.GcsTest, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, {:gcs_get, %Req.TransportError{reason: :econnrefused}}} =
             Gcs.get("builds/abc/source.tar.gz")
  end
end

defmodule Harmont.LogTokenTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Harmont.LogToken

  @secret "test-secret"

  test "sign then verify round-trips the build uuid" do
    build = Ecto.UUID.generate()
    exp = System.system_time(:second) + 3600
    token = LogToken.sign(build, exp, @secret)

    assert {:ok, ^build} = LogToken.verify(token, @secret)
  end

  test "an expired token is rejected" do
    token = LogToken.sign(Ecto.UUID.generate(), System.system_time(:second) - 1, @secret)
    assert LogToken.verify(token, @secret) == {:error, :expired}
  end

  test "a token signed with another secret fails the signature check" do
    token = LogToken.sign(Ecto.UUID.generate(), System.system_time(:second) + 60, @secret)
    assert LogToken.verify(token, "other-secret") == {:error, :bad_signature}
  end

  test "a garbage token is malformed" do
    assert LogToken.verify("not-a-token", @secret) == {:error, :malformed}
  end
end

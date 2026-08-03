defmodule Freestyle.RetryTest do
  use ExUnit.Case, async: true
  alias Freestyle.Retry

  describe "transient_status?/1" do
    test "429 and 5xx are transient" do
      assert Retry.transient_status?(429)
      assert Retry.transient_status?(500)
      assert Retry.transient_status?(503)
      assert Retry.transient_status?(599)
    end

    test "2xx/3xx and other 4xx are not transient" do
      refute Retry.transient_status?(200)
      refute Retry.transient_status?(404)
      refute Retry.transient_status?(400)
      refute Retry.transient_status?(301)
    end

    test "599 is transient but 600 is not (5xx boundary)" do
      assert Retry.transient_status?(599)
      refute Retry.transient_status?(600)
    end
  end

  describe "max_retries/0" do
    test "is 4 (5 attempts total)" do
      assert Retry.max_retries() == 4
    end
  end

  describe "delay/1" do
    test "is full-jitter within the exponential window, capped at 30s" do
      for attempt <- 0..10 do
        d = Retry.delay(attempt)
        window = min(trunc(250 * :math.pow(2, attempt)), 30_000)
        assert d >= 0
        assert d <= window
      end
    end

    test "never exceeds the 30s cap" do
      assert Retry.delay(50) <= 30_000
    end
  end
end

defmodule Freestyle.Retry do
  @moduledoc """
  Retry policy for Freestyle requests:
  full-jitter exponential backoff (base 250 ms, cap 30 s), 4 retries
  (5 attempts total). Transient outcomes are HTTP 429 / 5xx and transport
  errors — for **all** methods, including POST, because the engine relies
  on retried `exec-await`/`snapshot` calls.
  """

  @base_ms 250
  @cap_ms 30_000
  @max_retries 4

  @doc "Number of retries after the first attempt."
  @spec max_retries() :: non_neg_integer()
  def max_retries, do: @max_retries

  @doc "Whether an HTTP status code is a transient (retryable) outcome."
  @spec transient_status?(integer()) :: boolean()
  def transient_status?(429), do: true
  def transient_status?(status) when status >= 500 and status < 600, do: true
  def transient_status?(_), do: false

  @doc """
  Full-jitter backoff delay in milliseconds for a 0-based attempt index.
  `delay(0)` is the wait before the first retry. Returns a value uniformly
  drawn from `[0, min(250 * 2^attempt, 30_000)]`.
  """
  @spec delay(non_neg_integer()) :: non_neg_integer()
  def delay(attempt) when is_integer(attempt) and attempt >= 0 do
    window = min(trunc(@base_ms * :math.pow(2, attempt)), @cap_ms)
    :rand.uniform(window + 1) - 1
  end
end

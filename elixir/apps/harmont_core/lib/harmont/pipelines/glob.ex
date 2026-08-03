defmodule Harmont.Pipelines.Glob do
  @moduledoc """
  Glob matching for branch/tag trigger patterns.

  Uses Python `fnmatch` semantics for the subset we use. The match is anchored
  at both ends
  (whole-string match):

    * `*` matches any sequence of characters **including** `/`.
    * `?` matches exactly one character (including `/`).
    * Every other character — including regex/`fnmatch` metacharacters
      such as `.`, `[`, `]` — is matched **literally**. There is no
      character-class (`[abc]`) support; `[abc]` matches the literal
      five-character string `[abc]`.

  Mirrors what the `hm` pipeline DSL enforces on the same patterns so both
  layers agree byte-for-byte.
  """

  @doc """
  Match `pattern` against `text`. Returns `true` iff `text` matches the
  glob as a whole (anchored at both ends).
  """
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, text) when is_binary(pattern) and is_binary(text) do
    go(String.graphemes(pattern), String.graphemes(text))
  end

  # Both exhausted: match.
  defp go([], []), do: true
  # Pattern exhausted, text remains: no match.
  defp go([], _text), do: false

  # '*' matches any (possibly empty) suffix of the remaining text.
  defp go(["*" | rest], text), do: Enum.any?(tails_inclusive(text), &go(rest, &1))

  # '?' matches exactly one remaining character.
  defp go(["?" | rest], [_ | text]), do: go(rest, text)
  defp go(["?" | _rest], []), do: false

  # Literal character: must match the next text character exactly.
  defp go([c | rest], [c | text]), do: go(rest, text)
  defp go([_ | _rest], _text), do: false

  # All suffixes of the list, including the list itself and the empty list.
  defp tails_inclusive([]), do: [[]]
  defp tails_inclusive([_ | rest] = xs), do: [xs | tails_inclusive(rest)]
end

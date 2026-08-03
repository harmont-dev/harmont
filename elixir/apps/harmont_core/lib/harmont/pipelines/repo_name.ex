defmodule Harmont.Pipelines.RepoName do
  @moduledoc """
  Derives a display `owner/repo` name from a git clone URL.

  Used to label pipelines whose repo is not a mirrored GitHub repo (no
  `github_repo` row, so no `full_name` to copy). Returns the last two path
  segments of the URL with any scheme/host and trailing `.git` stripped, or
  `nil` when nothing usable can be parsed.
  """

  @spec from_clone_url(String.t() | nil) :: String.t() | nil
  def from_clone_url(nil), do: nil

  def from_clone_url(url) when is_binary(url) do
    url
    |> strip_scheme()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> last_two_segments()
  end

  # Drop "https://host/", "ssh://git@host/" → leave the path after the host.
  # For scp-style "git@host:owner/repo" split on the ":" host separator.
  defp strip_scheme(url) do
    cond do
      String.contains?(url, "://") ->
        url |> String.split("://", parts: 2) |> List.last() |> drop_host("/")

      String.contains?(url, "@") and String.contains?(url, ":") ->
        url |> String.split("@", parts: 2) |> List.last() |> drop_host(":")

      true ->
        drop_host(url, "/")
    end
  end

  # Remove the leading host component up to the first `sep`.
  defp drop_host(rest, sep) do
    case String.split(rest, sep, parts: 2) do
      [_host, path] -> path
      [only] -> only
    end
  end

  defp last_two_segments(path) do
    case path |> String.split("/", trim: true) |> Enum.take(-2) do
      [] -> nil
      segs -> Enum.join(segs, "/")
    end
  end
end

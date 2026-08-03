defmodule Harmont.Pipelines.Triggers do
  @moduledoc """
  Pure trigger matcher for git events.

  Answers "should a pipeline with this trigger fire on this git event?".

  ## Git event shape

  A normalised git event is a map:

      %{
        kind: :push | :pull_request,
        branch: String.t() | nil,
        tag: String.t() | nil,
        pr_action: String.t() | nil,
        pr_target_branch: String.t() | nil
      }

  A push event carries a `branch` **or** a `tag` (exactly one is set; the
  other is `nil`). A pull_request event carries `pr_action` and
  `pr_target_branch`.

  ## Trigger map shape

  Triggers are stored as a JSONB array on `Harmont.Pipelines.Pipeline`, so
  trigger maps have **string** keys with a `"type"` discriminator:

      %{"type" => "push", "branches" => [glob], "tags" => [glob]}
      %{"type" => "pull_request", "branches" => [glob], "types" => [action]}

  Missing list keys default to the empty list. Any unrecognized `"type"`
  (including legacy `"schedule"` rows persisted before scheduled triggers
  were removed) never matches a git event.
  """

  alias Harmont.Pipelines.Glob
  alias Harmont.Pipelines.Pipeline

  @type git_event :: %{
          required(:kind) => :push | :pull_request,
          optional(:branch) => String.t() | nil,
          optional(:tag) => String.t() | nil,
          optional(:pr_action) => String.t() | nil,
          optional(:pr_target_branch) => String.t() | nil
        }

  @doc """
  True iff `trigger_map` (a JSONB trigger map with string keys) matches
  `event`.
  """
  @spec matches_event?(map(), git_event()) :: boolean()
  def matches_event?(trigger_map, event) when is_map(trigger_map) and is_map(event) do
    case {trigger_type(trigger_map), event[:kind]} do
      {"push", :push} ->
        push_matches?(trigger_map, event)

      {"pull_request", :pull_request} ->
        pr_matches?(trigger_map, event)

      # Any unrecognized trigger type (e.g. a legacy "schedule" row) and
      # any trigger/event kind mismatch (e.g. push trigger vs PR event)
      # do not match.
      _ ->
        false
    end
  end

  @doc """
  True iff **any** trigger in the pipeline's trigger list matches `event`.

  Accepts either a `%Harmont.Pipelines.Pipeline{}` struct or a bare list of
  trigger maps.
  """
  @spec pipeline_matches?(Pipeline.t() | [map()], git_event()) :: boolean()
  def pipeline_matches?(%Pipeline{triggers: triggers}, event),
    do: pipeline_matches?(triggers || [], event)

  def pipeline_matches?(triggers, event) when is_list(triggers) do
    Enum.any?(triggers, &matches_event?(&1, event))
  end

  # The "event"/"type" discriminator. The task contract uses "type"; an
  # older wire format used "event" — accept either.
  defp trigger_type(trigger_map),
    do: trigger_map["type"] || trigger_map["event"]

  # Push event vs push trigger: branch event matches a `branches` glob, or
  # tag event matches a `tags` glob.
  defp push_matches?(trigger_map, event) do
    branches = globs(trigger_map, "branches")
    tags = globs(trigger_map, "tags")

    case {event[:branch], event[:tag]} do
      {branch, nil} when is_binary(branch) -> Enum.any?(branches, &Glob.match?(&1, branch))
      {nil, tag} when is_binary(tag) -> Enum.any?(tags, &Glob.match?(&1, tag))
      _ -> false
    end
  end

  # PR event vs PR trigger: action must be in `types`, and either there is
  # no branch filter (empty branches => any) or the target branch matches a
  # `branches` glob.
  defp pr_matches?(trigger_map, event) do
    branches = globs(trigger_map, "branches")
    types = list(trigger_map, "types")
    action = event[:pr_action]
    target = event[:pr_target_branch]

    is_binary(action) and action in types and
      (branches == [] or
         (is_binary(target) and Enum.any?(branches, &Glob.match?(&1, target))))
  end

  defp globs(trigger_map, key), do: list(trigger_map, key)

  defp list(trigger_map, key) do
    case trigger_map[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end
end

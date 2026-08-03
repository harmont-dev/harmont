defmodule Freestyle.Types do
  @moduledoc """
  Shared type aliases. Freestyle resource IDs are opaque strings on the wire;
  these aliases document intent and aid Dialyzer without runtime wrapping.
  """

  @type repo_id :: String.t()
  @type identity_id :: String.t()
  @type vm_id :: String.t()
  @type snapshot_id :: String.t()
  @type schedule_id :: String.t()
  @type token_id :: String.t()
  @type trigger_id :: String.t()
  @type deployment_id :: String.t()
  @type request_id :: String.t()
  @type commit_sha :: String.t()
  @type domain_name :: String.t()

  @typedoc "Offset-based pagination params. Defaults: limit 50, offset 0."
  @type page_params :: %{
          optional(:limit) => non_neg_integer(),
          optional(:offset) => non_neg_integer()
        }

  @doc "Default page params: limit 50, offset 0."
  @spec default_page_params() :: page_params()
  def default_page_params, do: %{limit: 50, offset: 0}
end

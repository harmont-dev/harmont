defmodule HarmontIr.Transition do
  @moduledoc "A graph node: a CommandStep + its fully-resolved env."
  use TypedStruct
  alias HarmontIr.CommandStep

  typedstruct enforce: true do
    field :step, CommandStep.t()
    field :env, %{String.t() => String.t()}
  end
end

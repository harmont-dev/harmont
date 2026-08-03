defmodule Harmont.Repo do
  @moduledoc """
  The single Ecto repository for the entire Harmont umbrella. Ecto is the
  sole migrator of the one `harmont` database — there is no Atlas, and no
  second repo. Execution tables, GitHub-App tables, and (from Plan 2) the
  whole domain all live here behind real foreign keys.
  """
  use Ecto.Repo, otp_app: :harmont_core, adapter: Ecto.Adapters.Postgres
end

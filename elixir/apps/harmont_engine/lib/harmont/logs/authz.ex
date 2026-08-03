defmodule Harmont.Logs.Authz do
  @moduledoc "Build-scoped access check for job logs: does job_id belong to the build named by the HMAC token's external_build_id?"
  import Ecto.Query
  alias Harmont.Builds.{Build, Job}

  @spec authorized?(String.t(), term()) :: boolean()
  def authorized?(job_id, build_uuid) when is_binary(build_uuid) do
    Harmont.Repo.one(
      from(j in Job,
        join: b in Build,
        on: b.id == j.build_id,
        where: j.id == ^job_id and b.external_build_id == ^build_uuid,
        select: 1
      )
    ) == 1
  rescue
    Ecto.Query.CastError -> false
  end

  def authorized?(_job_id, _build_uuid), do: false
end

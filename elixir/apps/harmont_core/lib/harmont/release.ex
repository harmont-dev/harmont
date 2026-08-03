defmodule Harmont.Release do
  @moduledoc """
  Runtime migration helpers for `mix release` deployments.

  Invoked from the container entrypoint before starting the application:

      bin/harmont eval "Harmont.Release.migrate()"

  This avoids the overhead of starting the full supervision tree just to
  run migrations, while still ensuring Ecto and Postgrex are loaded.
  """

  @app :harmont_core

  @doc "Run all pending Ecto migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Roll back `steps` migrations for `repo`."
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, steps) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, step: steps))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok
  defp load_app do
    _ = Application.load(@app)
    :ok
  end
end

defmodule HarmontApi.ApiSpec do
  @moduledoc """
  The OpenApiSpex specification for the Harmont REST API.

  This module is the single source of truth for the API contract. The spec is
  assembled from the router (`OpenApiSpex.Paths.from_router/1`) plus the static
  metadata below (info, servers, security schemes). In Plan 7 it feeds the CLI
  (progenitor) and frontend (openapi-typescript) codegen, so it must stay
  clean: every operation carries a stable `operation_id`, `tags`, and
  documented responses.
  """

  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Operation
  alias OpenApiSpex.PathItem
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server
  alias OpenApiSpex.Tag

  @behaviour OpenApi

  # The HTTP verbs a PathItem may carry an Operation under.
  @http_methods [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @impl OpenApi
  def spec do
    paths = Paths.from_router(HarmontApi.Router)

    %OpenApi{
      info: %Info{
        title: "Harmont API",
        version: "0",
        description: "Harmont's user-facing REST authentication API."
      },
      servers: servers(),
      paths: paths,
      # Declare the tags at the document root, derived from the tags the
      # operations already carry. Tooling that groups endpoints by tag (the
      # Fumadocs docs-site generator among them) iterates this root list; an
      # absent or empty `tags` array makes it emit zero per-tag pages. Deriving
      # it here keeps the root list from drifting out of sync with operations.
      tags: tags_from_paths(paths),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "A Harmont session bearer token."
          },
          "runnerToken" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "A build's single-issue runner token, presented as " <>
                "`Authorization: Bearer <runner_token>`. Used only by the in-VM " <>
                "agent for the internal source-archive endpoint; validated against " <>
                "the build's stored hash (non-consuming)."
          }
        }
      }
    }
    # Discover the named request/response schema modules referenced by the
    # operations and inline them into `components.schemas` (as `$ref`s). Without
    # this, named schemas never land in `components`, which breaks codegen
    # (progenitor / openapi-typescript) downstream in Plan 7.
    |> OpenApiSpex.resolve_schema_modules()
  end

  # Collect the unique tags used across every operation, sorted, as root-level
  # Tag entries. Sorting keeps the generated spec stable across builds.
  defp tags_from_paths(paths) do
    paths
    |> Map.values()
    |> Enum.flat_map(fn %PathItem{} = item ->
      item |> Map.take(@http_methods) |> Map.values()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn %Operation{tags: tags} -> tags || [] end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%Tag{name: &1})
  end

  defp servers do
    Application.get_env(:harmont_api, :servers, [%{url: "https://api.harmont.dev"}])
    |> Enum.map(fn
      %Server{} = server -> server
      %{url: url} = server -> %Server{url: url, description: Map.get(server, :description)}
      url when is_binary(url) -> %Server{url: url}
    end)
  end
end

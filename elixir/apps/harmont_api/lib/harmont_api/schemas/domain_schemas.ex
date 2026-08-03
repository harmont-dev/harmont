defmodule HarmontApi.Schemas.Organization do
  @moduledoc "An organization (tenant) the current user can access."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Organization",
    description: "A Harmont organization the authenticated user is a member of.",
    type: :object,
    properties: %{
      slug: %OpenApiSpex.Schema{
        type: :string,
        description: "URL-safe unique slug identifying the organization."
      },
      name: %OpenApiSpex.Schema{type: :string, description: "Display name."},
      url: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The organization's website, if set."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the organization was created."
      }
    },
    required: [:slug, :name, :created_at]
  })
end

defmodule HarmontApi.Schemas.OrganizationList do
  @moduledoc "A paginated list of organizations."
  require OpenApiSpex

  alias HarmontApi.Schemas.Organization

  OpenApiSpex.schema(%{
    title: "OrganizationList",
    description: "A page of the current user's organizations, with an opaque cursor.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: Organization,
        description: "The organizations on this page."
      },
      next_cursor: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque cursor for the next page. Pass it as the `cursor` query " <>
            "parameter; `null` when there are no more pages."
      }
    },
    required: [:data, :next_cursor]
  })
end

defmodule HarmontApi.Schemas.CreateOrganizationRequest do
  @moduledoc "Request body for creating a new organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateOrganizationRequest",
    description: "Create a new organization owned by the authenticated user.",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{
        type: :string,
        minLength: 1,
        description: "Display name. The slug is derived from this."
      },
      url: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional website URL."
      }
    },
    required: [:name]
  })
end

defmodule HarmontApi.Schemas.Pipeline do
  @moduledoc "A CI pipeline within an organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Pipeline",
    description: "A repeatable CI workflow belonging to an organization.",
    type: :object,
    properties: %{
      slug: %OpenApiSpex.Schema{
        type: :string,
        description: "URL-safe slug, unique within the organization. Derived from the name."
      },
      name: %OpenApiSpex.Schema{type: :string, description: "Display name."},
      repo_name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "The pipeline's repo as `owner/repo` — from the mirrored GitHub repo " <>
            "when known, else parsed from the clone URL. `null` when unknown."
      },
      description: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional human description."
      },
      repository: %OpenApiSpex.Schema{
        type: :string,
        description: "The source repository this pipeline builds."
      },
      default_branch: %OpenApiSpex.Schema{
        type: :string,
        description: "The branch built by default."
      },
      visibility: %OpenApiSpex.Schema{
        type: :string,
        enum: ["private", "public"],
        description: "Whether the pipeline is private or public."
      },
      allow_manual: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Whether manual (e.g. `hm run`) builds are permitted."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the pipeline was created."
      }
    },
    required: [
      :slug,
      :name,
      :repository,
      :default_branch,
      :visibility,
      :allow_manual,
      :created_at
    ]
  })
end

defmodule HarmontApi.Schemas.PipelineList do
  @moduledoc "A paginated list of pipelines."
  require OpenApiSpex

  alias HarmontApi.Schemas.Pipeline

  OpenApiSpex.schema(%{
    title: "PipelineList",
    description: "A page of an organization's pipelines, with an opaque cursor.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: Pipeline,
        description: "The pipelines on this page."
      },
      next_cursor: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque cursor for the next page. Pass it as the `cursor` query " <>
            "parameter; `null` when there are no more pages."
      }
    },
    required: [:data, :next_cursor]
  })
end

defmodule HarmontApi.Schemas.Build do
  @moduledoc "A single pipeline run."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Build",
    description: "One run of a pipeline, identified by its pipeline-scoped number.",
    type: :object,
    properties: %{
      number: %OpenApiSpex.Schema{
        type: :integer,
        description: "The build's number, sequential and unique within its pipeline."
      },
      state: %OpenApiSpex.Schema{
        type: :string,
        enum: ["scheduled", "running", "failing", "passed", "failed", "canceling", "canceled"],
        description: "The rolled-up build state."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "How the build was triggered (e.g. `api`, `webhook`, `ui`)."
      },
      branch: %OpenApiSpex.Schema{type: :string, nullable: true, description: "Source branch."},
      commit: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Source commit SHA."
      },
      message: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Commit/build message."
      },
      pipeline_slug: %OpenApiSpex.Schema{
        type: :string,
        description: "The global slug of the pipeline this build belongs to."
      },
      error_code: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Stable build-level error code, if the build failed at the build level."
      },
      error_message: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Human-readable build-level error message, if any."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the build row was created."
      },
      scheduled_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the build was queued."
      },
      started_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the build started running."
      },
      finished_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the build reached a terminal state."
      }
    },
    required: [:number, :state, :pipeline_slug, :created_at]
  })
end

defmodule HarmontApi.Schemas.BuildList do
  @moduledoc "A paginated list of builds."
  require OpenApiSpex

  alias HarmontApi.Schemas.Build

  OpenApiSpex.schema(%{
    title: "BuildList",
    description: "A page of a pipeline's builds (newest first), with an opaque cursor.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: Build,
        description: "The builds on this page, newest first."
      },
      next_cursor: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque cursor for the next page. Pass it as the `cursor` query " <>
            "parameter; `null` when there are no more pages."
      }
    },
    required: [:data, :next_cursor]
  })
end

defmodule HarmontApi.Schemas.Job do
  @moduledoc "A single node of a build's DAG."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Job",
    description: "One job (DAG node) of a build.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "The job's id."},
      step_key: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The job's stable key within the build's DAG."
      },
      name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Human-readable job name."
      },
      state: %OpenApiSpex.Schema{
        type: :string,
        description: "The job's FSM state.",
        enum: [
          "pending",
          "scheduled",
          "assigned",
          "running",
          "passed",
          "failed",
          "skipped",
          "canceling",
          "canceled",
          "timing_out",
          "timed_out"
        ]
      },
      command: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "The shell command the job runs."
      },
      exit_code: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description: "The command's exit status, once finished."
      },
      soft_failed: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Whether the job failed but the build was allowed to continue."
      },
      soft_fail_policy: %OpenApiSpex.Schema{
        type: :object,
        nullable: true,
        description: "The job's soft-fail policy, if any.",
        additionalProperties: true
      },
      retry_policy: %OpenApiSpex.Schema{
        type: :object,
        nullable: true,
        description: "The job's retry policy, if any.",
        additionalProperties: true
      },
      error_code: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Stable job-level error code, if the job failed."
      },
      error_message: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Human-readable job-level error message, if any."
      },
      depends_on: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string, format: :uuid},
        description:
          "Ids of this job's prerequisite jobs (its DAG in-edges), spanning both " <>
            "`depends_on` and `builds_in` dependency kinds. Empty when the job has no " <>
            "prerequisites."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the job row was created."
      },
      started_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the job started running."
      },
      finished_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the job reached a terminal state."
      }
    },
    required: [:id, :state, :soft_failed, :depends_on, :created_at]
  })
end

defmodule HarmontApi.Schemas.JobList do
  @moduledoc "A list of a build's jobs."
  require OpenApiSpex

  alias HarmontApi.Schemas.Job

  OpenApiSpex.schema(%{
    title: "JobList",
    description: "A build's jobs, in DAG creation order.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: Job,
        description: "The build's jobs."
      }
    },
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.LogTokenResponse do
  @moduledoc "A short-lived, build-scoped HMAC token for the SSE log stream."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogTokenResponse",
    description:
      "A build-scoped HMAC token the SSE log stream accepts, plus its expiry. " <>
        "Pass the token as the `token` query parameter when opening the log stream.",
    type: :object,
    properties: %{
      token: %OpenApiSpex.Schema{
        type: :string,
        description: "The opaque, build-scoped log token."
      },
      expires_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the token expires (~1 hour out)."
      }
    },
    required: [:token, :expires_at]
  })
end

defmodule HarmontApi.Schemas.CreateBuildRequest do
  @moduledoc "Request body to create a build (pre-rendered IR or in-sandbox render)."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateBuildRequest",
    description:
      "Creates a build for a pipeline. Two paths: supply pre-rendered v0 IR JSON " <>
        "in `pipeline_ir` (the `hm run` / API path), or omit `pipeline_ir` to have " <>
        "the engine render the registered pipeline's IR in a sandbox VM (decision " <>
        "#5 — rendering never happens on the API host). The IR is then parsed and " <>
        "planned in-process; on a plan/render rejection the build row is created with " <>
        "its error fields set and the request returns 422.",
    type: :object,
    properties: %{
      branch: %OpenApiSpex.Schema{type: :string, description: "Source branch."},
      commit: %OpenApiSpex.Schema{type: :string, description: "Source commit SHA."},
      message: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional build/commit message."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "How the build was triggered (e.g. `api`, `ui`). Defaults to `api`."
      },
      pipeline_ir: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "The pre-rendered v0 IR JSON the engine materialises into jobs. When " <>
            "absent/blank the engine renders the pipeline's IR in a sandbox VM instead."
      },
      source_b64: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Base64-encoded source tarball (expected to be gzipped; the API " <>
            "validates only that it is valid base64, not the archive format) — " <>
            "the `hm run` local-code upload path. When present, the API stores " <>
            "it at the build's key and derives the internal, runner-token-" <>
            "authenticated `source_url`; it takes precedence over any caller-" <>
            "supplied `source_url`."
      },
      source_url: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "URL to the build's source archive, fetched by the sandbox. Ignored " <>
            "when `source_b64` is supplied (the API derives this internally)."
      },
      source_sha256: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "SHA-256 of the source archive, verified by the sandbox before rendering " <>
            "(in-sandbox-render path). Defaults to empty when omitted."
      },
      env: %OpenApiSpex.Schema{
        type: :object,
        nullable: true,
        additionalProperties: %OpenApiSpex.Schema{type: :string},
        description: "Build-level environment variables."
      }
    },
    required: [:branch, :commit]
  })
end

defmodule HarmontApi.Schemas.CreateRepoBuildRequest do
  @moduledoc "Request body to create a build addressed by repo + source slug."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateRepoBuildRequest",
    description:
      "Creates a build by addressing the pipeline through its repo-natural " <>
        "identity — `repo_name` (`owner/repo`) plus `source_slug` (the in-repo " <>
        "`@hm.pipeline(\"…\")` name) — rather than the org-global slug. This is " <>
        "the `hm run` path: a repo-local client knows its git remote and its " <>
        "pipeline name but not the namespaced slug. Build semantics are otherwise " <>
        "identical to `createBuild`.",
    type: :object,
    properties: %{
      repo_name: %OpenApiSpex.Schema{
        type: :string,
        description: "The worktree's repository as `owner/repo` (from its git remote)."
      },
      source_slug: %OpenApiSpex.Schema{
        type: :string,
        description: "The in-repo pipeline name — the `@hm.pipeline(\"…\")` slug."
      },
      branch: %OpenApiSpex.Schema{type: :string, description: "Source branch."},
      commit: %OpenApiSpex.Schema{type: :string, description: "Source commit SHA."},
      message: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional build/commit message."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "How the build was triggered (e.g. `api`, `ui`). Defaults to `api`."
      },
      pipeline_ir: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "The pre-rendered v0 IR JSON the engine materialises into jobs. When " <>
            "absent/blank the engine renders the pipeline's IR in a sandbox VM instead."
      },
      source_b64: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Base64-encoded source tarball (the `hm run` local-code upload). When " <>
            "present, the API stores it at the build's key and derives the internal, " <>
            "runner-token-authenticated `source_url`."
      },
      env: %OpenApiSpex.Schema{
        type: :object,
        nullable: true,
        additionalProperties: %OpenApiSpex.Schema{type: :string},
        description: "Build-level environment variables."
      }
    },
    required: [:repo_name, :source_slug, :branch, :commit]
  })
end

defmodule HarmontApi.Schemas.CreatePipelineRequest do
  @moduledoc "Request body to create a pipeline."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreatePipelineRequest",
    description:
      "Creates a pipeline within an organization. The slug is derived from the " <>
        "name; a slug collision within the organization is rejected.",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, description: "Display name."},
      repository: %OpenApiSpex.Schema{
        type: :string,
        description: "The source repository this pipeline builds."
      },
      default_branch: %OpenApiSpex.Schema{
        type: :string,
        description: "The branch built by default."
      },
      description: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Optional human description."
      },
      repo_name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description:
          "Optional `owner/repo` label. When omitted it is derived from " <>
            "`repository`."
      }
    },
    required: [:name, :repository, :default_branch]
  })
end

defmodule HarmontApi.Schemas.GithubInstallation do
  @moduledoc "A GitHub App installation bound to an organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "GithubInstallation",
    description:
      "A GitHub App installation the organization has connected. The numeric " <>
        "`installation_id` is GitHub's installation id (used to address sync/" <>
        "unbind), while `id` is Harmont's internal row id.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Harmont's internal installation row id."
      },
      installation_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "GitHub's numeric installation id."
      },
      account_login: %OpenApiSpex.Schema{
        type: :string,
        description: "The GitHub account (org or user) the App is installed on."
      },
      account_type: %OpenApiSpex.Schema{
        type: :string,
        description: "`Organization` or `User`."
      },
      created_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the installation row was first mirrored."
      },
      updated_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When the installation row was last updated."
      }
    },
    required: [:id, :installation_id, :account_login, :account_type, :created_at, :updated_at]
  })
end

defmodule HarmontApi.Schemas.GithubInstallationList do
  @moduledoc "A list of GitHub installations bound to an organization."
  require OpenApiSpex

  alias HarmontApi.Schemas.GithubInstallation

  OpenApiSpex.schema(%{
    title: "GithubInstallationList",
    description: "The organization's connected GitHub App installations.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: GithubInstallation,
        description: "The connected installations."
      }
    },
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.GithubRepo do
  @moduledoc "A repository mirrored from a connected GitHub installation."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "GithubRepo",
    description:
      "A repository Harmont mirrors from a connected GitHub installation. " <>
        "`installation_id` is Harmont's internal installation row id (FK), not " <>
        "GitHub's installation id.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :integer, description: "Harmont's internal repo row id."},
      installation_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "FK onto the internal installation row id."
      },
      gh_repo_id: %OpenApiSpex.Schema{type: :integer, description: "GitHub's numeric repo id."},
      full_name: %OpenApiSpex.Schema{
        type: :string,
        description: "`owner/name` GitHub full name."
      },
      name: %OpenApiSpex.Schema{type: :string, description: "Short repo name."},
      owner: %OpenApiSpex.Schema{type: :string, description: "GitHub owner login."},
      clone_url: %OpenApiSpex.Schema{type: :string, description: "HTTPS clone URL."},
      default_branch: %OpenApiSpex.Schema{type: :string, description: "Default branch name."},
      private: %OpenApiSpex.Schema{type: :boolean, description: "Whether the repo is private."},
      last_synced_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When the repo was last synced from GitHub."
      }
    },
    required: [
      :id,
      :installation_id,
      :gh_repo_id,
      :full_name,
      :name,
      :owner,
      :clone_url,
      :default_branch,
      :private
    ]
  })
end

defmodule HarmontApi.Schemas.GithubRepoList do
  @moduledoc "A list of mirrored GitHub repositories."
  require OpenApiSpex

  alias HarmontApi.Schemas.GithubRepo

  OpenApiSpex.schema(%{
    title: "GithubRepoList",
    description: "Mirrored repositories for an installation or across an organization.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: GithubRepo,
        description: "The mirrored repositories."
      }
    },
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.RepoRegistration do
  @moduledoc "One way a repository has been registered with Harmont."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RepoRegistration",
    description:
      "A single registration channel for a repository. `provider` is the " <>
        "channel the repo was connected through: `github` (the GitHub App), " <>
        "`bitbucket` (Bitbucket OAuth), or `cli` (reserved for direct CLI " <>
        "registration — not yet emitted). `account` is the connecting " <>
        "account/workspace login.",
    type: :object,
    properties: %{
      provider: %OpenApiSpex.Schema{
        type: :string,
        description: "The registration channel: `github`, `bitbucket`, or `cli`."
      },
      account: %OpenApiSpex.Schema{
        type: :string,
        description: "The account/workspace login the repo was registered under."
      }
    },
    required: [:provider, :account]
  })
end

defmodule HarmontApi.Schemas.RepoSummary do
  @moduledoc "A provider-agnostic repository, with all its registration channels."
  require OpenApiSpex

  alias HarmontApi.Schemas.RepoRegistration

  OpenApiSpex.schema(%{
    title: "RepoSummary",
    description:
      "A repository visible to the organization, identified by its canonical " <>
        "clone URL. One logical repository may be registered through several " <>
        "channels (e.g. the GitHub App and the CLI); each appears in " <>
        "`registrations`.",
    type: :object,
    properties: %{
      full_name: %OpenApiSpex.Schema{type: :string, description: "`owner/name` full name."},
      name: %OpenApiSpex.Schema{type: :string, description: "Short repo name."},
      owner: %OpenApiSpex.Schema{type: :string, description: "Owner/namespace login."},
      clone_url: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "HTTPS clone URL (may be null for some providers)."
      },
      default_branch: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Default branch name."
      },
      private: %OpenApiSpex.Schema{type: :boolean, description: "Whether the repo is private."},
      last_synced_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "Most recent sync across this repo's registrations."
      },
      registrations: %OpenApiSpex.Schema{
        type: :array,
        items: RepoRegistration,
        description: "Every channel through which this repo is registered."
      }
    },
    required: [:full_name, :name, :owner, :private, :registrations]
  })
end

defmodule HarmontApi.Schemas.RepoSummaryList do
  @moduledoc "The organization's repositories across every connected provider."
  require OpenApiSpex

  alias HarmontApi.Schemas.RepoSummary

  OpenApiSpex.schema(%{
    title: "RepoSummaryList",
    description: "All repositories visible to the organization, across all providers.",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :array,
        items: RepoSummary,
        description: "The repositories."
      }
    },
    required: [:data]
  })
end

defmodule HarmontApi.Schemas.ConnectInstallationRequest do
  @moduledoc "Request body to bind a GitHub installation to an organization."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ConnectInstallationRequest",
    description:
      "Binds an existing GitHub App installation (identified by its GitHub " <>
        "numeric installation id) to this organization.",
    type: :object,
    properties: %{
      installation_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "GitHub's numeric installation id to bind."
      }
    },
    required: [:installation_id]
  })
end

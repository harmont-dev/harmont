defmodule HarmontApi.Router do
  @moduledoc """
  The Harmont REST API router.

  Mounted by `harmont_web`'s endpoint at the root; all routes live under
  `/api/v0`. The `:api` pipeline accepts JSON and registers the OpenApiSpex
  spec module so `OpenApiSpex.Plug.RenderSpec` can serve it and per-operation
  `operation` annotations are picked up.
  """
  use Phoenix.Router

  alias HarmontApi.Controllers.ApiTokenController
  alias HarmontApi.Controllers.AuthGithubController
  alias HarmontApi.Controllers.AuthGoogleController
  alias HarmontApi.Controllers.BillingController
  alias HarmontApi.Controllers.BitbucketController
  alias HarmontApi.Controllers.BuildController
  alias HarmontApi.Controllers.CliController
  alias HarmontApi.Controllers.GithubController
  alias HarmontApi.Controllers.JobController
  alias HarmontApi.Controllers.LogoutController
  alias HarmontApi.Controllers.LogTokenController
  alias HarmontApi.Controllers.OrganizationController
  alias HarmontApi.Controllers.OrgInviteController
  alias HarmontApi.Controllers.OrgMemberController
  alias HarmontApi.Controllers.PasskeyListController
  alias HarmontApi.Controllers.PasskeyLoginController
  alias HarmontApi.Controllers.PasskeyRecoverController
  alias HarmontApi.Controllers.PasskeyRegisterController
  alias HarmontApi.Controllers.PasskeySignupController
  alias HarmontApi.Controllers.PingController
  alias HarmontApi.Controllers.PipelineController
  alias HarmontApi.Controllers.RepoController
  alias HarmontApi.Controllers.SourceController
  alias HarmontApi.Controllers.StripeWebhookController
  alias HarmontApi.Controllers.UserController

  pipeline :api do
    plug(:accepts, ["json"])
    plug(OpenApiSpex.Plug.PutApiSpec, module: HarmontApi.ApiSpec)
  end

  pipeline :authed do
    plug(HarmontApi.Plugs.Auth)
  end

  # Runs after `:authed`; resolves the `:org` path param to a member org or
  # 404s (tenancy). Must be piped through together with `:authed`.
  pipeline :org_scoped do
    plug(HarmontApi.Plugs.OrgScope)
  end

  # Runs after `:org_scoped`; resolves the `:pipeline` slug within the scoped
  # org or 404s (tenancy). Reused by build endpoints nested under a pipeline.
  pipeline :pipeline_scoped do
    plug(HarmontApi.Plugs.PipelineScope)
  end

  # Runs after `:pipeline_scoped`; resolves the `:number` within the scoped
  # pipeline or 404s (tenancy). Reused by job/log-token endpoints
  # nested under a build.
  pipeline :build_scoped do
    plug(HarmontApi.Plugs.BuildScope)
  end

  scope "/api/v0" do
    pipe_through(:api)

    get("/ping", PingController, :ping)
    get("/openapi.json", OpenApiSpex.Plug.RenderSpec, [])

    post("/auth/google", AuthGoogleController, :create)
    post("/auth/github", AuthGithubController, :create)

    post("/auth/passkey/signup/begin", PasskeySignupController, :begin)
    post("/auth/passkey/signup/options", PasskeySignupController, :options)
    post("/auth/passkey/signup/finalize", PasskeySignupController, :finalize)

    post("/auth/passkey/login/options", PasskeyLoginController, :options)
    post("/auth/passkey/login/finalize", PasskeyLoginController, :finalize)

    post("/auth/recover/begin", PasskeyRecoverController, :begin)
    post("/auth/recover/options", PasskeyRecoverController, :options)
    post("/auth/recover/finalize", PasskeyRecoverController, :finalize)

    post("/auth/cli/claim", CliController, :claim)
    post("/auth/cli/redeem", CliController, :redeem)

    # Internal source-archive endpoint. Authenticated with the build's runner
    # token (NOT a session bearer), so it lives in the public scope rather than
    # behind `:authed`. The agent/sandbox fetches the uploaded tarball here.
    get("/internal/builds/:build_uuid/source.tar.gz", SourceController, :show)

    # Stripe webhook receiver. PUBLIC (no bearer, no OrgScope): authenticated by
    # the `Stripe-Signature` header verified against the raw request body, which
    # `HarmontWeb.CacheBodyReader` caches for this path.
    post("/stripe/webhook", StripeWebhookController, :handle)
  end

  scope "/api/v0" do
    pipe_through([:api, :authed])

    post("/auth/passkey/register/options", PasskeyRegisterController, :options)
    post("/auth/passkey/register/finalize", PasskeyRegisterController, :finalize)

    post("/auth/cli/transfer", CliController, :transfer)
    post("/auth/cli/code", CliController, :code)

    post("/auth/logout", LogoutController, :logout)

    get("/user", UserController, :show)
    patch("/user", UserController, :update)
    delete("/user", UserController, :delete)
    get("/user/passkeys", PasskeyListController, :index)
    delete("/user/passkeys/:uuid", PasskeyListController, :delete)

    get("/user/api-tokens", ApiTokenController, :index)
    post("/user/api-tokens", ApiTokenController, :create)
    delete("/user/api-tokens/:id", ApiTokenController, :delete)

    get("/organizations", OrganizationController, :index)
    post("/organizations", OrganizationController, :create)

    post("/invites/accept", OrgInviteController, :accept)

    # Bitbucket's OAuth callback URL is static (`/bitbucket/setup`), so this
    # connect endpoint is NOT org-scoped: it recovers the org from the signed
    # `state` and re-checks membership in the controller.
    post("/integrations/bitbucket/connect", BitbucketController, :connect)
  end

  scope "/api/v0" do
    pipe_through([:api, :authed, :org_scoped])

    get("/organizations/:org", OrganizationController, :show)

    get("/organizations/:org/members", OrgMemberController, :index)
    patch("/organizations/:org/members/:user_id", OrgMemberController, :update)
    delete("/organizations/:org/members/:user_id", OrgMemberController, :delete)

    get("/organizations/:org/invites", OrgInviteController, :index)
    post("/organizations/:org/invites", OrgInviteController, :create)
    delete("/organizations/:org/invites/:id", OrgInviteController, :delete)

    get("/organizations/:org/pipelines", PipelineController, :index)
    post("/organizations/:org/pipelines", PipelineController, :create)
    post("/organizations/:org/builds", BuildController, :create_by_source)

    get("/organizations/:org/repos", RepoController, :index)

    get("/organizations/:org/github/installations", GithubController, :installations)
    post("/organizations/:org/github/installations", GithubController, :connect)
    delete("/organizations/:org/github/installations/:id", GithubController, :disconnect)

    get(
      "/organizations/:org/github/installations/:id/repos",
      GithubController,
      :installation_repos
    )

    post("/organizations/:org/github/installations/:id/sync", GithubController, :sync)

    get("/organizations/:org/bitbucket/oauth-url", BitbucketController, :oauth_url)

    get("/organizations/:org/bitbucket/workspaces", BitbucketController, :workspaces)

    get(
      "/organizations/:org/bitbucket/workspaces/:id/repos",
      BitbucketController,
      :repos
    )

    delete("/organizations/:org/bitbucket/workspaces/:id", BitbucketController, :disconnect)

    get("/billing/balance/:org", BillingController, :balance)
    get("/billing/transactions/:org", BillingController, :transactions)
    get("/billing/usage/:org", BillingController, :usage)
    get("/billing/usage/:org/series", BillingController, :usage_series)
    get("/billing/usage/:org/breakdown", BillingController, :usage_breakdown)
    post("/billing/coupon/redeem/:org", BillingController, :redeem_coupon)
    post("/billing/checkout/:org", BillingController, :checkout)
  end

  scope "/api/v0" do
    pipe_through([:api, :authed, :org_scoped, :pipeline_scoped])

    get("/organizations/:org/pipelines/:pipeline", PipelineController, :show)

    get("/organizations/:org/pipelines/:pipeline/builds", BuildController, :index)
    post("/organizations/:org/pipelines/:pipeline/builds", BuildController, :create)
  end

  scope "/api/v0" do
    pipe_through([:api, :authed, :org_scoped, :pipeline_scoped, :build_scoped])

    get("/organizations/:org/pipelines/:pipeline/builds/:number", BuildController, :show)

    put(
      "/organizations/:org/pipelines/:pipeline/builds/:number/cancel",
      BuildController,
      :cancel
    )

    get(
      "/organizations/:org/pipelines/:pipeline/builds/:number/log-token",
      LogTokenController,
      :show
    )

    get("/organizations/:org/pipelines/:pipeline/builds/:number/jobs", JobController, :index)

    get(
      "/organizations/:org/pipelines/:pipeline/builds/:number/jobs/:job_id",
      JobController,
      :show
    )
  end
end

import { Router, Route } from "@solidjs/router";
import { QueryClient, QueryClientProvider, MutationCache } from "@tanstack/solid-query";
import { apiErrorMessage } from "./api/errors";
import { pushToast } from "./components/toast";
import { Toaster } from "./components/Toaster";
import { AuthLayout } from "./layouts/AuthLayout";
import { AppLayout } from "./layouts/AppLayout";
import { LoginPage } from "./pages/Login";
import { RegisterPage } from "./pages/Register";
import { RegisterVerifyPage } from "./pages/RegisterVerify";
import { DashboardPage } from "./pages/Dashboard";
import { PipelineDetailPage } from "./pages/PipelineDetail";
import { RunDetailPage } from "./pages/RunDetail";
import { ReposPage } from "./pages/Repos";
import { BillingPage } from "./pages/Billing";
import { AuthCallbackPage } from "./pages/AuthCallback";
import { AcceptInvitePage } from "./pages/AcceptInvite";
import { RecoverPage } from "./pages/Recover";
import { RecoverVerifyPage } from "./pages/RecoverVerify";
import { SettingsPage } from "./pages/Settings";
import { CliLoginPage } from "./pages/CliLogin";
import { GithubSetupPage } from "./pages/GithubSetup";
import { BitbucketSetupPage } from "./pages/BitbucketSetup";
import { NotFoundPage } from "./pages/NotFound";
import { OrgRedirectPage } from "./pages/OrgRedirect";
import { CheckoutSuccessPage } from "./pages/CheckoutSuccess";
import { CheckoutCancelPage } from "./pages/CheckoutCancel";

const queryClient = new QueryClient({
  // Safety net: any mutation that doesn't surface its own error inline gets a
  // toast with the server's message. Mutations that render an inline ErrorBanner
  // opt out via `meta: { silenceToast: true }` so the user isn't told twice.
  mutationCache: new MutationCache({
    onError: (error, _vars, _ctx, mutation) => {
      if (mutation.meta?.silenceToast) return;
      pushToast(apiErrorMessage(error));
    },
  }),
  defaultOptions: {
    queries: {
      retry: false,
      staleTime: 30_000,
    },
  },
});

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Toaster />
      <Router>
        <Route path="/auth/callback" component={AuthCallbackPage} />
        <Route path="/invite/accept" component={AcceptInvitePage} />
        <Route component={AuthLayout}>
          <Route path="/login" component={LoginPage} />
          <Route path="/register/verify" component={RegisterVerifyPage} />
          <Route path="/register" component={RegisterPage} />
          <Route path="/recover" component={RecoverPage} />
          <Route path="/recover/verify" component={RecoverVerifyPage} />
          <Route path="/cli-login" component={CliLoginPage} />
        </Route>
        <Route component={AppLayout}>
          {/* Bare `/` resolves to the user's default org (cookie → personal → first). */}
          <Route path="/" component={OrgRedirectPage} />
          <Route path="/:orgSlug/pipelines" component={DashboardPage} />
          <Route path="/:orgSlug/pipelines/:slug" component={PipelineDetailPage} />
          <Route
            path="/:orgSlug/pipelines/:slug/builds/:number"
            component={RunDetailPage}
          />
          <Route path="/:orgSlug/repos" component={ReposPage} />
          <Route path="/:orgSlug/usage" component={BillingPage} />
          <Route path="/:orgSlug/settings" component={SettingsPage} />
          {/* GitHub's App Setup URL is static (`/github/setup`, no org slug —
              GitHub can't know the org), so the post-install callback lands here
              WITHOUT an `:orgSlug` segment; the org rides in the `state` query
              param. This bare route is the one GitHub actually hits; without it
              the callback fell through to the catch-all 404, the bind POST never
              fired, and installations stayed unbound (empty repo list). The
              slug-prefixed variant is kept for in-app links. */}
          <Route path="/github/setup" component={GithubSetupPage} />
          <Route path="/:orgSlug/github/setup" component={GithubSetupPage} />
          {/* Bitbucket's OAuth callback URL is static (`/bitbucket/setup`, no org
              slug — Bitbucket can't know the org), so the callback lands here
              WITHOUT an `:orgSlug`; the org rides in the signed `state` and is
              recovered server-side by the connect endpoint. */}
          <Route path="/bitbucket/setup" component={BitbucketSetupPage} />
          {/* Stripe hosted-checkout redirect targets. Non-org-scoped to match
              the static success_url/cancel_url the backend hands Stripe
              (<app_base>/billing/success|cancel). The "Back to your dashboard"
              link routes through OrgRedirect to the user's default org, where
              the balance refetches. */}
          <Route path="/billing/success" component={CheckoutSuccessPage} />
          <Route path="/billing/cancel" component={CheckoutCancelPage} />
          {/* Catch-all 404 — authed users see it in the app shell; unauthed
              users hitting a bad URL get bounced to login by AppLayout. */}
          <Route path="*" component={NotFoundPage} />
        </Route>
      </Router>
    </QueryClientProvider>
  );
}

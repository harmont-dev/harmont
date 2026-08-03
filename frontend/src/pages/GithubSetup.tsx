import { createSignal, createEffect, Show } from "solid-js";
import { A, useSearchParams } from "@solidjs/router";
import { useOrgSlug } from "../auth/context";
import { connectInstallation } from "../repos/queries";
import { ErrorBanner } from "../components/ErrorBanner";
import { apiErrorMessage } from "../api/errors";

type State =
  | { step: "connecting" }
  | { step: "connected"; accountLogin: string }
  | { step: "error"; message: string };

// Org slugs are lowercase alphanumeric + hyphens (≤63). Anything else in the
// `state` param is rejected so it can't become a protocol-relative URL or an
// API-path injection.
const ORG_SLUG_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;

export function GithubSetupPage() {
  const [params] = useSearchParams();
  const orgSlug = useOrgSlug();
  const [state, setState] = createSignal<State>({ step: "connecting" });

  // GitHub hits the static Setup URL `/github/setup` (no `:orgSlug` segment), so
  // the org rides in the `state` param. Prefer it over the route-derived
  // orgSlug() (undefined on the bare callback path) for both the bind and the
  // post-connect links — otherwise the links point at `/undefined/repos` → 404.
  //
  // SECURITY: `state` is attacker-influenceable (a crafted /github/setup link).
  // Validate it as a real org slug before using it in a URL or the bind path —
  // an unvalidated value like `//evil.com` would make `/${org}/repos` a
  // protocol-relative open redirect, and could inject into the API path.
  const effectiveOrg = (): string | undefined => {
    const candidate = (typeof params.state === "string" && params.state) || orgSlug();
    return candidate && ORG_SLUG_RE.test(candidate) ? candidate : undefined;
  };

  const reposHref = () => {
    const org = effectiveOrg();
    return org ? `/${org}/repos` : "/";
  };

  // GitHub redirects here after install with `installation_id` (+ the `state`
  // we set on the install link, which carries the org). Bind reactively, NOT in
  // onMount: this is a fresh page load, so the user/org context (orgSlug, from
  // the still-loading user query) is usually undefined on first paint —
  // checking it once there produced the spurious "No organization context".
  // Prefer the `state` param (available immediately); otherwise wait for orgSlug
  // to resolve. Fire the bind exactly once.
  let started = false;
  createEffect(() => {
    if (started) return;

    const installationId = params.installation_id;
    if (!installationId) {
      started = true;
      setState({ step: "error", message: "No installation ID provided" });
      return;
    }

    // A present-but-malformed `state` is rejected outright (don't silently wait
    // on the orgSlug fallback for an attacker-supplied value).
    if (typeof params.state === "string" && params.state && !ORG_SLUG_RE.test(params.state)) {
      started = true;
      setState({ step: "error", message: "Invalid organization in the GitHub callback." });
      return;
    }

    const org = effectiveOrg();
    if (!org) return; // org not resolved yet — effect re-runs when it loads

    started = true;
    connectInstallation(org, Number(installationId))
      .then((data) => setState({ step: "connected", accountLogin: data.account_login }))
      .catch((e) =>
        setState({ step: "error", message: apiErrorMessage(e, "Failed to connect GitHub") }),
      );
  });

  return (
    <div>
      <h1 class="text-xl font-semibold text-fg mb-4">GitHub Setup</h1>

      <Show when={state().step === "connecting"}>
        <p class="font-mono text-sm text-fg-muted">Connecting your GitHub account...</p>
      </Show>

      <Show when={state().step === "connected"}>
        <div class="flex flex-col gap-3">
          <p class="font-mono text-sm text-fg">
            GitHub account <span class="font-semibold">{(state() as { accountLogin: string }).accountLogin}</span> connected.
          </p>
          <A href={reposHref()} class="font-mono text-sm text-accent hover:text-fg">
            Go to Repositories →
          </A>
        </div>
      </Show>

      <Show when={state().step === "error"}>
        <ErrorBanner message={(state() as { message: string }).message} />
        <A href={reposHref()} class="font-mono text-sm text-fg-muted hover:text-fg mt-2 inline-block">
          Back to Repositories
        </A>
      </Show>
    </div>
  );
}

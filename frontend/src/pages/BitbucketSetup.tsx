import { createSignal, createEffect, Show } from "solid-js";
import { A, useSearchParams } from "@solidjs/router";
import { connectBitbucket } from "../bitbucket/queries";
import { ErrorBanner } from "../components/ErrorBanner";
import { apiErrorMessage } from "../api/errors";

type State =
  | { step: "connecting" }
  | { step: "connected"; count: number; org: string | undefined }
  | { step: "error"; message: string };

export function BitbucketSetupPage() {
  const [params] = useSearchParams();
  const [state, setState] = createSignal<State>({ step: "connecting" });

  // Bitbucket hits the static callback `/bitbucket/setup` (no `:orgSlug`
  // segment), so we can't derive the org from the route — `useOrgSlug()` would
  // be undefined here. The org rides in the SIGNED `state` and is recovered
  // server-side by the connect endpoint, which returns the org slug back so we
  // can link to the org-scoped repos view. Both `code` and `state` come
  // straight from the query params, available on first paint.
  let started = false;
  createEffect(() => {
    if (started) return;
    started = true;

    const code = typeof params.code === "string" ? params.code : undefined;
    const csrfState = typeof params.state === "string" ? params.state : undefined;
    if (!code || !csrfState) {
      setState({
        step: "error",
        message: "Missing authorization code or state. Restart the Bitbucket connect flow.",
      });
      return;
    }

    connectBitbucket(code, csrfState)
      .then((resp) =>
        setState({ step: "connected", count: resp.workspaces.length, org: resp.org }),
      )
      .catch((e) =>
        setState({ step: "error", message: apiErrorMessage(e, "Failed to connect Bitbucket") }),
      );
  });

  // The connect response carries the org slug; link to its repos view. Fall
  // back to `/` (default-org redirect) if it's somehow absent.
  const reposHref = () => {
    const s = state();
    const org = s.step === "connected" ? s.org : undefined;
    return org ? `/${org}/repos` : "/";
  };

  return (
    <div>
      <h1 class="text-xl font-semibold text-fg mb-4">Bitbucket Setup</h1>

      <Show when={state().step === "connecting"}>
        <p class="font-mono text-sm text-fg-muted">Connecting your Bitbucket workspace…</p>
      </Show>

      <Show when={state().step === "connected"}>
        <div class="flex flex-col gap-3">
          <p class="font-mono text-sm text-fg">
            Connected {(state() as { count: number }).count} workspace(s).
          </p>
          <A href={reposHref()} class="font-mono text-sm text-accent hover:text-fg">
            Go to Repositories →
          </A>
        </div>
      </Show>

      <Show when={state().step === "error"}>
        <ErrorBanner message={(state() as { message: string }).message} />
        <A href="/" class="font-mono text-sm text-fg-muted hover:text-fg mt-2 inline-block">
          Back to Dashboard
        </A>
      </Show>
    </div>
  );
}

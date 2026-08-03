import { createSignal, onMount, Show } from "solid-js";
import { useSearchParams, useLocation, useNavigate } from "@solidjs/router";
import {
  useCliTransfer,
  useCliCodeCreate,
  useCurrentUser,
  useLogout,
} from "../auth/queries";
import { hasToken } from "../auth/token";
import { apiErrorMessage, apiErrorCode, apiErrorDocUrl } from "../api/errors";
import { Button } from "../components/Button";
import { ErrorBanner } from "../components/ErrorBanner";

type State =
  | { step: "authorize" }
  | { step: "transferring" }
  | { step: "done-loopback" }
  | { step: "showing-code"; code: string }
  | { step: "error"; message: string; errorCode?: string; docUrl?: string };

export function CliLoginPage() {
  const [params] = useSearchParams<{
    port?: string;
    nonce?: string;
    state?: string;
    paste?: string;
  }>();
  const location = useLocation();
  const navigate = useNavigate();
  const [state, setState] = createSignal<State>({ step: "authorize" });
  const cliTransfer = useCliTransfer();
  const cliCode = useCliCodeCreate();
  const currentUser = useCurrentUser();
  const logout = useLogout();

  const isPaste = () => params.paste === "true";
  const loopbackPort = () => params.port;
  const nonce = () => params.nonce;
  const csrfState = () => params.state;

  // Where /login should return to once a session exists: this exact page with
  // all CLI params intact.
  const selfPath = () => location.pathname + location.search;
  const loginHref = () => `/login?redirect=${encodeURIComponent(selfPath())}`;

  const toLogin = () => navigate(loginHref(), { replace: true });

  // No session? Route through the canonical /login (passkey + OAuth +
  // register/recover) rather than re-implementing auth here. /login returns to
  // this page, where the user is then authenticated and can authorize the CLI.
  onMount(() => {
    if (!hasToken()) toLogin();
  });

  const authorize = async () => {
    try {
      if (isPaste()) {
        setState({ step: "transferring" });
        const result = await cliCode.mutateAsync();
        setState({ step: "showing-code", code: result.code });
      } else if (loopbackPort() && nonce()) {
        setState({ step: "transferring" });
        await cliTransfer.mutateAsync({ nonce: nonce()! });
        const callbackUrl = `http://localhost:${loopbackPort()}/callback?state=${csrfState() ?? ""}`;
        window.location.href = callbackUrl;
        setState({ step: "done-loopback" });
      } else {
        setState({ step: "error", message: "Missing CLI parameters" });
      }
    } catch (e) {
      // A 401 here (stale session) is handled globally by the API middleware,
      // which clears the token and bounces to /login?redirect=<here>. Anything
      // else we surface inline.
      setState({
        step: "error",
        message: apiErrorMessage(e, "Authorization failed"),
        errorCode: apiErrorCode(e),
        docUrl: apiErrorDocUrl(e),
      });
    }
  };

  const useAnotherAccount = () => {
    logout.mutate();
    toLogin();
  };

  const handleCopy = async (code: string) => {
    await navigator.clipboard.writeText(code);
  };

  const errorState = () => {
    const s = state();
    return s.step === "error" ? s : null;
  };
  const busy = () => state().step === "transferring";

  return (
    <Show when={hasToken()}>
      <div class="flex flex-col gap-2">
        <h1 class="font-mono text-2xl font-bold text-fg">Authorize the CLI</h1>
        <p class="font-mono text-sm text-fg-muted">
          {isPaste()
            ? "Authorize this terminal to get a sign-in code."
            : "Authorize this terminal to access your account."}
        </p>
      </div>

      <Show when={errorState()}>
        {(s) => (
          <ErrorBanner message={s().message} code={s().errorCode} docUrl={s().docUrl} />
        )}
      </Show>

      <Show when={state().step === "showing-code"}>
        <div class="flex flex-col gap-3 items-center">
          <p class="font-mono text-sm text-fg-muted">Paste this code into your terminal:</p>
          <code class="font-mono text-2xl font-bold text-fg tracking-widest select-all">
            {(state() as { code: string }).code}
          </code>
          <Button size="md" onClick={() => handleCopy((state() as { code: string }).code)}>
            Copy to clipboard
          </Button>
        </div>
      </Show>

      <Show when={state().step === "done-loopback"}>
        <p class="font-mono text-sm text-fg">Done. You can close this tab.</p>
      </Show>

      <Show
        when={
          state().step === "authorize" ||
          state().step === "transferring" ||
          state().step === "error"
        }
      >
        <div class="flex flex-col gap-3">
          <Button
            variant="primary"
            size="lg"
            mode={busy() ? "inactive" : "active"}
            onClick={authorize}
            class="w-full justify-center"
          >
            {busy() ? "Authorizing..." : "Authorize this terminal"}
          </Button>

          <div class="flex flex-col items-center gap-1 pt-1">
            <Show when={currentUser.data}>
              <p class="font-mono text-xs text-fg-muted">
                Signed in as {currentUser.data!.email}
              </p>
            </Show>
            <button
              type="button"
              onClick={useAnotherAccount}
              class="font-mono text-sm text-fg-muted hover:text-fg"
            >
              Use another account
            </button>
          </div>
        </div>
      </Show>
    </Show>
  );
}

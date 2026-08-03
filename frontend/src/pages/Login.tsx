import { createSignal, Show } from "solid-js";
import { A, useNavigate, useSearchParams } from "@solidjs/router";
import { usePasskeyLogin, useGoogleLogin, useGithubLogin } from "../auth/queries";
import { openOAuthPopup, mintOAuthState } from "../auth/oauth-popup";
import { safeRedirect } from "../auth/redirect";
import {
  apiErrorMessage,
  apiErrorCode,
  apiErrorDocUrl,
  isWebauthnCancel,
} from "../api/errors";
import { ErrorBanner } from "../components/ErrorBanner";
import { Button } from "../components/Button";
import { BaffleText } from "../components/BaffleText";
import { GithubIcon } from "../components/icons/GithubIcon";
import { GoogleIcon } from "../components/icons/GoogleIcon";
import { PasskeyIcon } from "../components/icons/PasskeyIcon";
import { Separator } from "../components/Separator";

type LoginState =
  | { step: "idle" }
  | { step: "passkey"; phase: "loading-options" | "waiting-for-browser" | "submitting" }
  | { step: "sso"; provider: "google" | "github"; phase: "popup-open" | "exchanging" }
  | { step: "error"; message: string; code?: string; docUrl?: string };

const passkeyLabel = (state: LoginState): string => {
  if (state.step === "passkey") {
    const labels = {
      "loading-options": "Preparing...",
      "waiting-for-browser": "Waiting for authenticator...",
      submitting: "Signing in...",
    };
    return labels[state.phase];
  }
  return "Sign in with a passkey";
};

const isBusy = (state: LoginState): boolean =>
  state.step === "passkey" || state.step === "sso";

export function LoginPage() {
  const navigate = useNavigate();
  const [state, setState] = createSignal<LoginState>({ step: "idle" });
  const [params] = useSearchParams<{ redirect?: string }>();
  const redirectTo = () => safeRedirect(params.redirect);
  const passkeyLogin = usePasskeyLogin();
  const googleLogin = useGoogleLogin();
  const githubLogin = useGithubLogin();

  const busy = () => isBusy(state());
  const errorState = () => {
    const s = state();
    return s.step === "error" ? s : null;
  };
  const ssoActive = (provider: "google" | "github") => {
    const s = state();
    return s.step === "sso" && s.provider === provider;
  };

  const handlePasskey = async () => {
    setState({ step: "passkey", phase: "loading-options" });
    try {
      await passkeyLogin.mutateAsync(undefined);
      navigate(redirectTo(), { replace: true });
    } catch (e) {
      // WebAuthn NotAllowedError — user cancelled or browser denied the ceremony.
      // simplewebauthn passes these through as-is (ERROR_PASSTHROUGH_SEE_CAUSE_PROPERTY).
      if (isWebauthnCancel(e)) {
        setState({ step: "idle" });
        return;
      }
      setState({
        step: "error",
        message: apiErrorMessage(e, "Passkey login failed"),
        code: apiErrorCode(e),
        docUrl: apiErrorDocUrl(e),
      });
    }
  };

  const handleGoogle = async () => {
    setState({ step: "sso", provider: "google", phase: "popup-open" });
    const clientId = import.meta.env.VITE_GOOGLE_CLIENT_ID;
    if (!clientId) {
      setState({ step: "error", message: "Google OAuth not configured" });
      return;
    }
    const redirectUri = `${window.location.origin}/auth/callback`;
    const oauthState = mintOAuthState();
    const url = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&scope=openid%20email%20profile&access_type=offline&state=${oauthState}`;
    const result = await openOAuthPopup(url, oauthState);
    if (!result.ok) {
      if (result.error === "Popup closed") {
        setState({ step: "idle" });
      } else {
        setState({ step: "error", message: result.error });
      }
      return;
    }
    setState({ step: "sso", provider: "google", phase: "exchanging" });
    try {
      await googleLogin.mutateAsync({ code: result.code, redirect_uri: redirectUri });
      navigate(redirectTo(), { replace: true });
    } catch (e) {
      setState({
        step: "error",
        message: apiErrorMessage(e, "Google login failed"),
        code: apiErrorCode(e),
        docUrl: apiErrorDocUrl(e),
      });
    }
  };

  const handleGithub = async () => {
    setState({ step: "sso", provider: "github", phase: "popup-open" });
    const clientId = import.meta.env.VITE_GITHUB_CLIENT_ID;
    if (!clientId) {
      setState({ step: "error", message: "GitHub OAuth not configured" });
      return;
    }
    const redirectUri = `${window.location.origin}/auth/callback`;
    const oauthState = mintOAuthState();
    const url = `https://github.com/login/oauth/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&state=${oauthState}&scope=user:email`;
    const result = await openOAuthPopup(url, oauthState);
    if (!result.ok) {
      if (result.error === "Popup closed") {
        setState({ step: "idle" });
      } else {
        setState({ step: "error", message: result.error });
      }
      return;
    }
    setState({ step: "sso", provider: "github", phase: "exchanging" });
    try {
      await githubLogin.mutateAsync({ code: result.code, redirect_uri: redirectUri });
      navigate(redirectTo(), { replace: true });
    } catch (e) {
      setState({
        step: "error",
        message: apiErrorMessage(e, "GitHub login failed"),
        code: apiErrorCode(e),
        docUrl: apiErrorDocUrl(e),
      });
    }
  };

  return (
    <>
      <div class="flex flex-col gap-2">
        <h1 class="font-mono text-2xl font-bold text-fg">Sign in</h1>
        <p class="font-mono text-sm text-fg-muted">
          Use a passkey, or continue with an SSO provider.
        </p>
      </div>

      <Show when={errorState()}>
        {(s) => (
          <ErrorBanner message={s().message} code={s().code} docUrl={s().docUrl} />
        )}
      </Show>

      <div class="flex flex-col gap-3">
        <Button
          variant="primary"
          size="lg"
          icon={<PasskeyIcon />}
          mode={busy() ? "inactive" : "active"}
          onClick={handlePasskey}
          class="w-full justify-center"
        >
          {busy()
            ? <BaffleText text={"······" + passkeyLabel(state()) + "······"} reveal={false} charset="ascii" />
            : passkeyLabel(state())}
        </Button>

        <div class={`flex flex-col items-center gap-1 pt-1 ${busy() ? "pointer-events-none text-fg-dim" : ""}`}>
          <A href="/register" class={`font-mono text-sm ${busy() ? "" : "text-fg-secondary hover:text-fg"}`}>
            Create an account.
          </A>
          <a href="/recover" class={`font-mono text-sm ${busy() ? "" : "text-fg-muted hover:text-fg"}`}>
            Lost your device?
          </a>
        </div>

        <Separator label="or" class="my-1" />

        <div class="flex gap-3 justify-center">
          <Button
            variant="default"
            size="2xl"
            icon={<span class={ssoActive("google") ? "animate-pulse" : ""}><GoogleIcon /></span>}
            mode={busy() && !ssoActive("google") ? "inactive" : "active"}
            onClick={handleGoogle}
            aria-label="Sign in with Google"
          />
          <Button
            variant="default"
            size="2xl"
            icon={<span class={ssoActive("github") ? "animate-pulse" : ""}><GithubIcon /></span>}
            mode={busy() && !ssoActive("github") ? "inactive" : "active"}
            onClick={handleGithub}
            aria-label="Sign in with GitHub"
          />
        </div>
      </div>
    </>
  );
}

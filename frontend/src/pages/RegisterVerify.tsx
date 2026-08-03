import { onMount } from "solid-js";
import { A, useSearchParams, useNavigate } from "@solidjs/router";
import { createSignal, Show } from "solid-js";
import { useSignupFinalize } from "../auth/queries";
import {
  apiErrorMessage,
  apiErrorCode,
  apiErrorDocUrl,
  isWebauthnCancel,
} from "../api/errors";
import { ErrorBanner } from "../components/ErrorBanner";
import { BaffleText } from "../components/BaffleText";

export function RegisterVerifyPage() {
  const [params] = useSearchParams<{ token?: string }>();
  const navigate = useNavigate();
  const signupFinalize = useSignupFinalize();

  const [error, setError] = createSignal<string | null>(null);
  const [errorCode, setErrorCode] = createSignal<string | undefined>(undefined);
  const [errorDocUrl, setErrorDocUrl] = createSignal<string | undefined>(undefined);

  onMount(() => {
    const token = params.token;
    if (!token) {
      navigate("/register", { replace: true });
      return;
    }
    handleFinalize(token);
  });

  const handleFinalize = async (token: string) => {
    try {
      await signupFinalize.mutateAsync(token);
      navigate("/", { replace: true });
    } catch (e) {
      // User dismissed the OS passkey prompt — silent, send them back to retry.
      if (isWebauthnCancel(e)) {
        navigate("/register", { replace: true });
        return;
      }
      setError(apiErrorMessage(e, "Passkey creation failed"));
      setErrorCode(apiErrorCode(e));
      setErrorDocUrl(apiErrorDocUrl(e));
    }
  };

  return (
    <>
      <Show when={error()}>
        <ErrorBanner message={error()!} code={errorCode()} docUrl={errorDocUrl()} />
      </Show>

      <Show when={!error()}>
        <div class="flex flex-col gap-2">
          <h1 class="font-mono text-2xl font-bold text-fg">Creating your passkey.</h1>
          <p class="font-mono text-sm text-fg-muted/50">
            <BaffleText text="····························" charset="cjk" reveal={false} speed={80} />
          </p>
          <p class="font-mono text-sm text-fg-muted">
            Follow the prompt from your browser or authenticator.
          </p>
        </div>
      </Show>

      <Show when={error()}>
        <A href="/register" class="font-mono text-sm text-fg-secondary hover:text-fg">
          Back to sign up.
        </A>
      </Show>
    </>
  );
}

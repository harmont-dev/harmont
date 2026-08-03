import { createSignal, onMount, Show } from "solid-js";
import { A, useNavigate, useSearchParams } from "@solidjs/router";
import { useRecoverFinalize } from "../auth/queries";
import { apiErrorMessage, apiErrorCode, apiErrorDocUrl } from "../api/errors";
import { ErrorBanner } from "../components/ErrorBanner";

export function RecoverVerifyPage() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [error, setError] = createSignal<string | null>(null);
  const [errorCode, setErrorCode] = createSignal<string | undefined>(undefined);
  const [errorDocUrl, setErrorDocUrl] = createSignal<string | undefined>(undefined);
  const recover = useRecoverFinalize();

  onMount(async () => {
    const token = params.token;
    if (!token) {
      setError("No recovery token provided");
      return;
    }
    try {
      await recover.mutateAsync(token as string);
      navigate("/", { replace: true });
    } catch (e) {
      setError(apiErrorMessage(e, "Recovery link expired or already used"));
      setErrorCode(apiErrorCode(e));
      setErrorDocUrl(apiErrorDocUrl(e));
    }
  });

  return (
    <>
      <div class="flex flex-col gap-2">
        <h1 class="font-mono text-2xl font-bold text-fg">Signing you in</h1>
      </div>

      <Show
        when={error()}
        fallback={
          <p class="font-mono text-sm text-fg-muted">Verifying recovery link...</p>
        }
      >
        <ErrorBanner message={error()!} code={errorCode()} docUrl={errorDocUrl()} />
        <A href="/recover" class="font-mono text-sm text-fg-secondary hover:text-fg">
          Request a new link
        </A>
      </Show>
    </>
  );
}

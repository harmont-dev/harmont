import { createSignal, Show } from "solid-js";
import { A } from "@solidjs/router";
import { useRecoverBegin } from "../auth/queries";
import { apiErrorMessage, apiErrorCode, apiErrorDocUrl } from "../api/errors";
import { Button } from "../components/Button";
import { TextInput } from "../components/TextInput";
import { ErrorBanner } from "../components/ErrorBanner";

type State = "editing" | "submitting" | "submitted";

export function RecoverPage() {
  const [email, setEmail] = createSignal("");
  const [state, setState] = createSignal<State>("editing");
  const [error, setError] = createSignal<string | null>(null);
  const [errorCode, setErrorCode] = createSignal<string | undefined>(undefined);
  const [errorDocUrl, setErrorDocUrl] = createSignal<string | undefined>(undefined);
  const recover = useRecoverBegin();

  const handleSubmit = async (e: Event) => {
    e.preventDefault();
    if (!email().trim()) return;
    setState("submitting");
    setError(null);
    try {
      await recover.mutateAsync({ email: email() });
      setState("submitted");
    } catch (err) {
      setState("editing");
      setError(apiErrorMessage(err, "Recovery request failed"));
      setErrorCode(apiErrorCode(err));
      setErrorDocUrl(apiErrorDocUrl(err));
    }
  };

  return (
    <>
      <div class="flex flex-col gap-2">
        <h1 class="font-mono text-2xl font-bold text-fg">Recover access</h1>
        <p class="font-mono text-sm text-fg-muted">
          Enter your email and we'll send a sign-in link.
        </p>
      </div>

      <Show when={error()}>
        <ErrorBanner message={error()!} code={errorCode()} docUrl={errorDocUrl()} />
      </Show>

      <Show
        when={state() !== "submitted"}
        fallback={
          <div class="flex flex-col gap-4">
            <p class="font-mono text-sm text-fg">
              Check <span class="text-fg font-semibold">{email()}</span> for the sign-in link. The link expires in 30 minutes.
            </p>
            <A href="/login" class="font-mono text-sm text-fg-secondary hover:text-fg">
              Back to sign in
            </A>
          </div>
        }
      >
        <form onSubmit={handleSubmit} class="flex flex-col gap-4">
          <TextInput
            placeholder="Email"
            value={email()}
            onInput={setEmail}
            type="email"
          />
          <Button
            variant="primary"
            size="lg"
            class="w-full justify-center"
            mode={state() === "submitting" ? "inactive" : "active"}
            type="submit"
          >
            {state() === "submitting" ? "Sending..." : "Send recovery link"}
          </Button>
          <A href="/login" class="font-mono text-sm text-fg-muted hover:text-fg text-center">
            Back to sign in
          </A>
        </form>
      </Show>
    </>
  );
}

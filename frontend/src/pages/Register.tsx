import { createSignal, Show } from "solid-js";
import { A } from "@solidjs/router";
import { useSignupBegin } from "../auth/queries";
import { apiErrorMessage, apiErrorCode, apiErrorDocUrl } from "../api/errors";
import { ErrorBanner } from "../components/ErrorBanner";
import { Button } from "../components/Button";
import { BaffleText } from "../components/BaffleText";
import { PasskeyIcon } from "../components/icons/PasskeyIcon";
import { TextInput } from "../components/TextInput";

type RegisterState =
  | { step: "form" }
  | { step: "submitting" }
  | { step: "check-email"; email: string }
  | { step: "error"; message: string; code?: string; docUrl?: string };

export function RegisterPage() {
  const signupBegin = useSignupBegin();

  const [state, setState] = createSignal<RegisterState>({ step: "form" });
  const [email, setEmail] = createSignal("");
  const [name, setName] = createSignal("");

  const busy = () => state().step === "submitting";
  const errorState = () => {
    const s = state();
    return s.step === "error" ? s : null;
  };

  const handleBegin = async () => {
    setState({ step: "submitting" });
    try {
      await signupBegin.mutateAsync({ email: email(), name: name() });
      setState({ step: "check-email", email: email() });
    } catch (e) {
      setState({
        step: "error",
        message: apiErrorMessage(e, "Signup failed"),
        code: apiErrorCode(e),
        docUrl: apiErrorDocUrl(e),
      });
    }
  };

  return (
    <>
      <Show when={errorState()}>
        {(s) => (
          <ErrorBanner message={s().message} code={s().code} docUrl={s().docUrl} />
        )}
      </Show>

      <Show when={state().step === "check-email"}>
        <div class="flex flex-col gap-2">
          <h1 class="font-mono text-2xl font-bold text-fg">Check your email</h1>
          <p class="font-mono text-sm text-fg-muted">
            We sent a verification link to{" "}
            <span class="text-fg">{(state() as { email: string }).email}</span>.
            Open it to create your passkey.
          </p>
        </div>

        <A href="/login" class="font-mono text-sm text-fg-secondary hover:text-fg">
          Back to sign in.
        </A>
      </Show>

      <Show when={state().step === "form" || state().step === "submitting" || state().step === "error"}>
        <div class="flex flex-col gap-2">
          <h1 class="font-mono text-2xl font-bold text-fg">Create an account</h1>
          <p class="font-mono text-sm text-fg-muted">
            Sign up with a passkey. No passwords.
          </p>
        </div>

        <form
          class="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            handleBegin();
          }}
        >
          <TextInput
            label="Name"
            placeholder="Ada Lovelace"
            value={name()}
            onInput={setName}
          />
          <TextInput
            label="Email"
            placeholder="ada@example.com"
            value={email()}
            onInput={setEmail}
          />
          <Button
            type="submit"
            variant="primary"
            size="lg"
            icon={<PasskeyIcon />}
            mode={busy() ? "inactive" : "active"}
            class="w-full justify-center"
          >
            {busy()
              ? <BaffleText text="······Registering······" reveal={false} charset="ascii" />
              : "Continue with passkey"}
          </Button>
        </form>

        <A href="/login" class="font-mono text-sm text-fg-secondary hover:text-fg text-center">
          Already have an account? Sign in.
        </A>
      </Show>
    </>
  );
}

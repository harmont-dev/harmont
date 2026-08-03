import { createSignal, For, Show } from "solid-js";
import { useApiKeys, useCreateApiKey, useRevokeApiKey } from "./queries";
import { EXPIRY_OPTIONS, expiryToIso, type ExpiryOption } from "./expiry";
import type { ApiKeyCreateResponse } from "./types";
import { apiErrorMessage, apiErrorCode, apiErrorDocUrl } from "../api/errors";
import { Button } from "../components/Button";
import { TextInput } from "../components/TextInput";
import { Panel } from "../components/Panel";
import { QueryGuard } from "../components/QueryGuard";
import { PanelList, PanelRow } from "../components/PanelList";
import { EmptyState } from "../components/EmptyState";
import { ErrorBanner } from "../components/ErrorBanner";
import { TimeAgo } from "../components/TimeAgo";
import { Collapsible } from "../components/Collapsible";
import { ExpandToggle } from "../components/ExpandToggle";
import { useArmedConfirm } from "../components/useArmedConfirm";
import { pushToast } from "../components/toast";

export function ApiKeysSection() {
  const keys = useApiKeys();
  const createKey = useCreateApiKey();
  const revokeKey = useRevokeApiKey();

  // Inline create flow: the section expands to a two-phase area — a form,
  // then a one-time reveal of the freshly minted secret. The header's `+`
  // toggles it open and rotates into an `×`.
  const [open, setOpen] = createSignal(false);
  const [name, setName] = createSignal("");
  const [expiry, setExpiry] = createSignal<ExpiryOption>("never");
  const [creating, setCreating] = createSignal(false);
  const [created, setCreated] = createSignal<ApiKeyCreateResponse | null>(null);
  const [formError, setFormError] = createSignal<string | null>(null);
  const [formErrorCode, setFormErrorCode] = createSignal<string | undefined>(undefined);
  const [formErrorDocUrl, setFormErrorDocUrl] = createSignal<string | undefined>(undefined);

  // Section-level (revoke) error.
  const [error, setError] = createSignal<string | null>(null);
  const [errorCode, setErrorCode] = createSignal<string | undefined>(undefined);
  const [errorDocUrl, setErrorDocUrl] = createSignal<string | undefined>(undefined);

  const resetForm = () => {
    setName("");
    setExpiry("never");
    setCreated(null);
    setFormError(null);
    setCreating(false);
  };

  const closeForm = () => {
    setOpen(false);
    resetForm();
  };

  const toggleForm = () => {
    if (open()) {
      closeForm();
    } else {
      resetForm();
      setOpen(true);
    }
  };

  const handleCreate = async () => {
    const description = name().trim();
    if (!description || creating()) return;
    setCreating(true);
    setFormError(null);
    setFormErrorCode(undefined);
    setFormErrorDocUrl(undefined);
    try {
      const res = await createKey.mutateAsync({
        description,
        expires_at: expiryToIso(expiry()),
      });
      setCreated(res);
    } catch (e) {
      setFormError(apiErrorMessage(e, "Failed to create API key"));
      setFormErrorCode(apiErrorCode(e));
      setFormErrorDocUrl(apiErrorDocUrl(e));
    } finally {
      setCreating(false);
    }
  };

  const handleCopy = async () => {
    const token = created()?.token;
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token);
      pushToast("API key copied to clipboard", "info");
    } catch {
      pushToast("Copy failed — select the key and copy it manually", "error");
    }
  };

  const revoke = useArmedConfirm<string>(async (id) => {
    setError(null);
    try {
      await revokeKey.mutateAsync(id);
    } catch (e) {
      setError(apiErrorMessage(e, "Failed to revoke API key"));
      setErrorCode(apiErrorCode(e));
      setErrorDocUrl(apiErrorDocUrl(e));
    }
  });

  return (
    <Panel
      title="API Keys"
      description="Authenticate the hm CLI and scripts. Treat keys like passwords — revoke any you no longer use."
      actions={<ExpandToggle open={open()} onToggle={toggleForm} label="Create API key" />}
    >
      {/* Inline create flow — expands gracefully under the header. */}
      <Collapsible open={open()}>
        {/* Outer padding is the gap below the form. It must be PADDING, not
            margin — TransitionHeight measures offsetHeight (margins excluded). */}
        <div class="pb-5">
          <div class="pb-5 border-b border-border-subtle">
            <Show
              when={created()}
              fallback={
                <div class="flex flex-col gap-4">
                  <Show when={formError()}>
                    <ErrorBanner
                      message={formError()!}
                      code={formErrorCode()}
                      docUrl={formErrorDocUrl()}
                    />
                  </Show>

                  <TextInput
                    label="Name"
                    value={name()}
                    onInput={setName}
                    placeholder="e.g. Laptop CLI"
                    onKeyDown={(e: KeyboardEvent) => {
                      if (e.key === "Enter") handleCreate();
                    }}
                    autofocus
                  />

                  <label class="flex flex-col gap-1">
                    <span class="font-mono text-xs font-medium text-fg-secondary uppercase tracking-[0.04em]">
                      Expires
                    </span>
                    <select
                      aria-label="Key expiry"
                      class="py-2 px-[10px] font-mono text-sm bg-bg border border-border-focus rounded-[2px] text-fg outline-hidden transition-fast focus:border-accent focus:bg-bg-raise"
                      value={expiry()}
                      onChange={(e) => setExpiry(e.currentTarget.value as ExpiryOption)}
                    >
                      <For each={EXPIRY_OPTIONS}>
                        {(o) => <option value={o.value}>{o.label}</option>}
                      </For>
                    </select>
                  </label>

                  <div class="flex justify-end">
                    <Button
                      variant="primary"
                      onClick={handleCreate}
                      mode={!name().trim() || creating() ? "inactive" : "active"}
                    >
                      {creating() ? "Creating..." : "Create key"}
                    </Button>
                  </div>
                </div>
              }
            >
              {(res) => (
                <div class="flex flex-col gap-4">
                  <div class="font-mono text-2xs text-fg-dim uppercase tracking-[0.04em]">
                    Copy your key now — it won't be shown again
                  </div>
                  <div class="flex items-center gap-3 p-3 border border-accent/50 rounded-[2px] bg-bg-inset">
                    <code class="flex-1 min-w-0 font-mono text-sm text-fg break-all select-all">
                      {res().token}
                    </code>
                    <Button variant="primary" onClick={handleCopy}>
                      Copy
                    </Button>
                  </div>
                  <div class="flex justify-end">
                    <Button variant="default" onClick={closeForm}>
                      Done
                    </Button>
                  </div>
                </div>
              )}
            </Show>
          </div>
        </div>
      </Collapsible>

      <Show when={error()}>
        <div class="mb-4">
          <ErrorBanner message={error()!} code={errorCode()} docUrl={errorDocUrl()} />
        </div>
      </Show>

      <QueryGuard query={keys} loadingRows={2}>
        <Show
          when={(keys.data?.api_tokens ?? []).length > 0}
          fallback={<EmptyState>No API keys yet. Create one with the + button.</EmptyState>}
        >
          <PanelList>
            <For each={keys.data?.api_tokens ?? []}>
              {(k) => (
                <PanelRow>
                  <div class="flex-1 min-w-0">
                    <div class="font-mono text-sm text-fg truncate">
                      {k.description || "Unnamed key"}
                    </div>
                    <div class="font-mono text-xs text-fg-dim mt-0.5">
                      Created <TimeAgo date={k.created_at} />
                      <Show when={k.last_used_at} fallback={<> · Never used</>}>
                        {(d) => <> · Last used <TimeAgo date={d()} /></>}
                      </Show>
                      <Show when={k.expires_at}>
                        {(d) => <> · Expires <TimeAgo date={d()} /></>}
                      </Show>
                    </div>
                  </div>
                  <Button
                    variant={revoke.isArmed(k.id) ? "danger" : "default"}
                    onClick={() => revoke.trigger(k.id)}
                  >
                    {revoke.isArmed(k.id) ? "Confirm" : "Revoke"}
                  </Button>
                </PanelRow>
              )}
            </For>
          </PanelList>
        </Show>
      </QueryGuard>
    </Panel>
  );
}

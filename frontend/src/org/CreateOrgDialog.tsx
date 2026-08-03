import { createSignal, Show } from "solid-js";
import { useNavigate } from "@solidjs/router";
import { Dialog } from "../components/Dialog";
import { Button } from "../components/Button";
import { TextInput } from "../components/TextInput";
import { ErrorBanner } from "../components/ErrorBanner";
import { apiErrorMessage } from "../api/errors";
import { useCreateOrg } from "./queries";
import { setDefaultOrg } from "./defaultOrg";

export function CreateOrgDialog(props: { open: boolean; onClose: () => void }) {
  const [name, setName] = createSignal("");
  const create = useCreateOrg();
  const navigate = useNavigate();

  const submit = (e: Event) => {
    e.preventDefault();
    create.mutate(
      { name: name().trim() },
      {
        onSuccess: (org) => {
          setDefaultOrg(org.slug);
          props.onClose();
          navigate(`/${org.slug}/pipelines`);
        },
      },
    );
  };

  return (
    <Dialog
      open={props.open}
      onOpenChange={(open) => { if (!open) { create.reset(); setName(""); props.onClose(); } }}
      title="Create organization"
    >
      <form onSubmit={submit} class="flex flex-col gap-4">
        <TextInput
          label="Name"
          value={name()}
          onInput={setName}
          placeholder="Acme Corp"
          autofocus
        />
        <Show when={create.isError}>
          <ErrorBanner message={apiErrorMessage(create.error)} />
        </Show>
        <div class="flex justify-end gap-2 mt-1">
          <Button type="button" variant="default" onClick={props.onClose}>
            Cancel
          </Button>
          <Button
            type="submit"
            variant="primary"
            disabled={!name().trim() || create.isPending}
          >
            {create.isPending ? "Creating…" : "Create"}
          </Button>
        </div>
      </form>
    </Dialog>
  );
}

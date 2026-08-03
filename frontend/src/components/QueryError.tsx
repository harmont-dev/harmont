import { Show } from "solid-js";
import { apiErrorMessage, apiErrorDocUrl } from "../api/errors";

export function QueryError(props: { error: unknown }) {
  const message = () => apiErrorMessage(props.error, "Failed to load.");
  const docUrl = () => apiErrorDocUrl(props.error);
  return (
    <div class="text-status-failed font-mono text-sm py-8 text-center" role="alert">
      {message()}
      <Show when={docUrl()}>
        {(u) => (
          <a
            href={u()}
            target="_blank"
            rel="noreferrer"
            class="ml-2 underline opacity-70 hover:opacity-100"
          >
            docs
          </a>
        )}
      </Show>
    </div>
  );
}

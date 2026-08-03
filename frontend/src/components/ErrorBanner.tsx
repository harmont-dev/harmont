import { Show } from "solid-js";

export function ErrorBanner(props: {
  message: string;
  code?: string;
  docUrl?: string;
  class?: string;
}) {
  return (
    <div
      class={`text-status-failed text-sm font-mono py-2 px-3 border border-status-failed/30 bg-status-failed/10 rounded-[2px] ${props.class ?? ""}`.trim()}
      role="alert"
    >
      {props.message}
      <Show when={props.docUrl}>
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

import { Show } from "solid-js";
import type { LogStreamState } from "../logs/useLogStream";

export function LogViewer(props: { state: LogStreamState }) {
  return (
    <div class="font-mono text-xs">
      <Show when={props.state.status === "connecting"}>
        <div class="text-fg-dim text-center py-4">Connecting to log stream...</div>
      </Show>
      <Show when={props.state.status === "idle"}>
        <div class="text-fg-dim text-center py-4">Select a job to view logs</div>
      </Show>
      <Show
        when={
          props.state.status === "streaming" ||
          props.state.status === "done" ||
          props.state.status === "error"
        }
      >
        <pre class="bg-bg-inset p-3 rounded-[2px] border border-border overflow-x-auto whitespace-pre-wrap max-h-[400px] overflow-y-auto text-fg-muted">
          {(props.state as { content: string }).content || "(no output)"}
        </pre>
      </Show>
      <Show when={props.state.status === "error"}>
        <div class="text-status-failed text-xs mt-1">
          {(props.state as { message: string }).message}
        </div>
      </Show>
    </div>
  );
}

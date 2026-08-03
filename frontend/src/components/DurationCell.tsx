import { Show } from "solid-js";
import { fmtDuration } from "../format/duration";
import { Dash } from "./Dash";

export function DurationCell(props: {
  startedAt?: string | null;
  finishedAt?: string | null;
}) {
  return (
    <Show
      when={props.startedAt && props.finishedAt}
      fallback={
        <Show when={props.startedAt} fallback={<Dash />}>
          <span class="font-mono text-xs text-fg-muted">...</span>
        </Show>
      }
    >
      <span class="font-mono text-xs text-fg-muted">
        {fmtDuration(props.startedAt!, props.finishedAt!)}
      </span>
    </Show>
  );
}

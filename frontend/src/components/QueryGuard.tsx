import { Show, type JSX } from "solid-js";
import { LoadingSkeleton } from "./LoadingSkeleton";
import { QueryError } from "./QueryError";

export function QueryGuard(props: {
  query: { isPending: boolean; isError: boolean; error: unknown };
  loadingRows?: number;
  loadingHeight?: number;
  loadingFallback?: JSX.Element;
  children: JSX.Element;
}) {
  return (
    <Show
      when={!props.query.isPending}
      fallback={
        props.loadingFallback ?? (
          <LoadingSkeleton rows={props.loadingRows} height={props.loadingHeight} />
        )
      }
    >
      <Show
        when={!props.query.isError}
        fallback={<QueryError error={props.query.error} />}
      >
        {props.children}
      </Show>
    </Show>
  );
}

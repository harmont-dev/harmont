import { type JSX, Show } from "solid-js";
import { TransitionHeight } from "./TransitionHeight";

/**
 * Smoothly expands/collapses its children by animating height.
 *
 * Gotcha: `TransitionHeight` measures `offsetHeight` (margins excluded) and
 * clips past it, so give the content bottom spacing with PADDING, not margin.
 */
export function Collapsible(props: {
  open: boolean;
  children: JSX.Element;
  /** Rendered (also height-animated) while closed — e.g. a trigger button. */
  fallback?: JSX.Element;
}) {
  return (
    <TransitionHeight>
      <Show when={props.open} fallback={props.fallback}>
        {props.children}
      </Show>
    </TransitionHeight>
  );
}

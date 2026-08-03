import { type JSX, onMount, onCleanup } from "solid-js";

export type TransitionHeightProps = {
  children: JSX.Element;
  duration?: number;
  class?: string;
};

export function TransitionHeight(props: TransitionHeightProps) {
  let outer!: HTMLDivElement;
  let inner!: HTMLDivElement;

  onMount(() => {
    const sync = () => {
      outer.style.height = `${inner.offsetHeight}px`;
    };
    const ro = new ResizeObserver(sync);
    ro.observe(inner);
    sync();
    onCleanup(() => ro.disconnect());
  });

  return (
    <div
      ref={outer}
      class={props.class}
      style={{ overflow: "hidden", transition: `height ${props.duration ?? 200}ms ease` }}
    >
      <div ref={inner}>
        {props.children}
      </div>
    </div>
  );
}

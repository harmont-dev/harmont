import { type JSX, Show, splitProps } from "solid-js";

type Size = "sm" | "md" | "lg";

type CommonProps = {
  size?: Size;
  class?: string;
};

export type AvatarProps = CommonProps &
  (
    | { name: string; src?: string }
    | { name?: undefined; src: string }
  );

const sizeClasses: Record<Size, string> = {
  sm: "w-[26px] h-[26px] text-sm",
  md: "w-[34px] h-[34px] text-md",
  lg: "w-12 h-12 text-xl",
};

export function Avatar(props: AvatarProps) {
  const size = () => props.size ?? "sm";
  const name = () => props.name ?? "";
  const initial = () => name().trim()[0]?.toUpperCase();

  return (
    <span
      class={`relative inline-flex items-center justify-center rounded-full bg-bg-raise text-fg font-mono font-semibold leading-none overflow-hidden shrink-0 select-none align-middle border border-border-active ${sizeClasses[size()]} ${props.class ?? ""}`.trim()}
      role="img"
      aria-label={name() || undefined}
    >
      <Show
        when={props.src}
        fallback={<span class="-translate-y-[3%]">{initial()}</span>}
      >
        <img
          src={props.src}
          alt={name()}
          class="absolute inset-0 w-full h-full object-cover rounded-full block"
        />
      </Show>
    </span>
  );
}

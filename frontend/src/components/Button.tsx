import { Button as KobalteButton } from "@kobalte/core/button";
import { type ComponentProps, type JSX, Show, splitProps } from "solid-js";

type Variant = "default" | "primary" | "danger";
type Size = "sm" | "md" | "lg" | "xl" | "2xl" | "3xl";
type Mode = "active" | "inactive";

export type ButtonProps = ComponentProps<typeof KobalteButton> & {
  variant?: Variant;
  size?: Size;
  mode?: Mode;
  icon?: JSX.Element;
};

// Solid fills (no gradient) with a tiny drop shadow for a touch of paper feel.
// Press feedback (translate-down + shadow off) lives in the base class so it
// applies to every variant.
const variantClasses: Record<Variant, string> = {
  default:
    "text-fg border-border-active bg-bg-hover shadow-[0_1px_2px_rgba(0,0,0,0.5)] hover:bg-[#2a2a2a] hover:border-fg-dim",
  primary:
    "text-bg border-accent bg-accent shadow-[0_1px_2px_rgba(0,0,0,0.5)] hover:bg-accent-hover hover:border-accent-hover",
  danger:
    "text-err border-err/60 bg-err/10 shadow-[0_1px_2px_rgba(0,0,0,0.4)] hover:bg-err/20 hover:border-err",
};

const sizeClasses: Record<Size, string> = {
  sm: "px-[9px] py-1 text-2xs",
  md: "px-3 py-[7px] text-xs",
  lg: "px-4 py-[9px] text-sm",
  xl: "px-5 py-3 text-base",
  "2xl": "px-5 py-3 text-lg",
  "3xl": "px-5 py-3 text-xl",
};

const iconOnlySizeClasses: Record<Size, string> = {
  sm: "p-1 text-2xs",
  md: "p-[7px] text-xs",
  lg: "p-[9px] text-sm",
  xl: "p-3 text-base",
  "2xl": "p-3 text-lg",
  "3xl": "p-4 text-xl",
};

export function Button(props: ButtonProps) {
  const [local, rest] = splitProps(props, ["variant", "size", "mode", "class", "children", "icon"]);

  const variant = () => local.variant ?? "default";
  const size = () => local.size ?? "md";
  const mode = () => local.mode ?? "active";
  const iconOnly = () => local.icon && !local.children;
  const inactive = () => mode() === "inactive";

  return (
    <KobalteButton
      class={`inline-flex items-center justify-center gap-1.5 whitespace-nowrap font-mono font-medium uppercase tracking-[0.04em] leading-none border rounded-[2px] cursor-pointer transition duration-100 active:translate-y-px active:shadow-none disabled:text-fg-dim disabled:opacity-60 disabled:cursor-not-allowed disabled:shadow-none disabled:active:translate-y-0 ${inactive() ? "text-fg-dim cursor-not-allowed pointer-events-none bg-bg-raise border-border shadow-none" : variantClasses[variant()]} ${iconOnly() ? iconOnlySizeClasses[size()] : sizeClasses[size()]} ${local.class ?? ""}`.trim()}
      {...rest}
    >
      <Show when={local.icon}>
        <span class={`shrink-0 [&>img]:rounded-full [&>img]:object-cover ${size() === "2xl" || size() === "3xl" ? "[&>img]:h-[1.3em] [&>img]:w-[1.3em] [&>svg]:h-[1.3em] [&>svg]:w-[1.3em]" : "[&>img]:h-[1.1em] [&>img]:w-[1.1em] [&>svg]:h-[1.1em] [&>svg]:w-[1.1em]"}`}>{local.icon}</span>
      </Show>
      {local.children}
    </KobalteButton>
  );
}

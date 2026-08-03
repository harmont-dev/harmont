type Size = "xs" | "sm" | "md" | "lg" | "xl" | "2xl" | "3xl" | "display";

export type LogoProps = {
  size?: Size;
  class?: string;
};

const sizeConfig: Record<Size, { text: string; h: number; w: number; gap: string }> = {
  xs:      { text: "text-xs",  h: 12, w: 9,  gap: "gap-1" },
  sm:      { text: "text-sm",  h: 14, w: 10, gap: "gap-1.5" },
  md:      { text: "text-md",  h: 16, w: 12, gap: "gap-2" },
  lg:      { text: "text-lg",  h: 20, w: 15, gap: "gap-2" },
  xl:      { text: "text-xl",  h: 24, w: 18, gap: "gap-2.5" },
  "2xl":   { text: "text-2xl", h: 30, w: 22, gap: "gap-3" },
  "3xl":   { text: "text-3xl", h: 38, w: 28, gap: "gap-3" },
  display: { text: "text-4xl", h: 52, w: 38, gap: "gap-4" },
};

function HMark(props: { width: number; height: number }) {
  return (
    <svg
      viewBox="0 0 330.92 448"
      width={props.width}
      height={props.height}
      fill="currentColor"
      aria-hidden="true"
      class="block shrink-0"
    >
      <path d="M269.79,262.18c-60.18-62.42-88.14-90.55-45.27-225.8l10.9-31.49c1.2-3.13.64-4.89-3.77-4.89h-72.12c-4.17,0-5.21.72-6.97,5.21L.32,443.27c-.88,2.48,0,4.33,3.29,4.33h74.44c1.98.25,3.8-1.09,4.17-3.04l70.83-202.33c9.1,13.36,19.87,25.5,32.05,36.14,52.32,46.8,72.12,70.11,62.58,161.62-.64,6.33,0,8.01,6.65,8.01h71.55c2.56,0,3.53-1.52,3.77-4.09,6.49-86.14-11.78-131.97-59.86-181.73Z" />
    </svg>
  );
}

export function Logo(props: LogoProps) {
  const cfg = () => sizeConfig[props.size ?? "md"];

  return (
    <span
      class={`inline-flex items-baseline font-mono font-semibold text-fg tracking-[-0.02em] leading-none whitespace-nowrap [&>.brand-word]:[text-box-trim:trim-end] [&>.brand-word]:[text-box-edge:cap_alphabetic] supports-[text-box-trim:trim-end]:items-end ${cfg().gap} ${cfg().text} ${props.class ?? ""}`.trim()}
    >
      <HMark width={cfg().w} height={cfg().h} />
      <span class="brand-word">harmont</span>
    </span>
  );
}

export function PlusIcon(props: { size?: number; class?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      width={props.size ?? "1em"}
      height={props.size ?? "1em"}
      class={props.class}
    >
      <path d="M8 3.25v9.5M3.25 8h9.5" />
    </svg>
  );
}

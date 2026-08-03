export function BitbucketIcon(props: { size?: number; class?: string }) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="currentColor"
      width={props.size ?? "1em"}
      height={props.size ?? "1em"}
      class={props.class}
    >
      <path d="M2.363 2a.73.73 0 0 0-.727.847l4.344 26.5a.99.99 0 0 0 .97.833h18.277a.727.727 0 0 0 .727-.613l4.344-26.72a.73.73 0 0 0-.727-.847zm17.02 18.067h-6.79l-1.84-9.647h10.23z" />
    </svg>
  );
}

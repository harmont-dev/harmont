export function CommitHash(props: { sha: string }) {
  return (
    <code class="font-mono text-xs text-fg-dim tracking-[0.02em]">
      {props.sha.slice(0, 7)}
    </code>
  );
}

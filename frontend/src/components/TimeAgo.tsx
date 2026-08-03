import { formatDistanceToNowStrict } from "date-fns";

export function TimeAgo(props: { date: string; class?: string }) {
  return (
    <span class={`font-mono text-xs text-fg-muted ${props.class ?? ""}`.trim()} title={props.date}>
      {formatDistanceToNowStrict(new Date(props.date), {
        addSuffix: true,
        roundingMethod: "floor",
      })}
    </span>
  );
}

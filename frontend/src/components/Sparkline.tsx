import { For, Show } from "solid-js";
import type { components } from "../api/v1";

type BuildState = NonNullable<components["schemas"]["Build"]["state"]>;

const STATE_COLORS: Record<BuildState, string> = {
  scheduled: "var(--color-status-queued)",
  running: "var(--color-status-running)",
  failing: "var(--color-status-running)",
  passed: "var(--color-status-passed)",
  failed: "var(--color-status-failed)",
  canceling: "var(--color-status-canceled)",
  canceled: "var(--color-status-canceled)",
};

export type SparklineProps = {
  builds: { state: BuildState }[];
  max?: number;
};

export function Sparkline(props: SparklineProps) {
  const recent = () => {
    const max = props.max ?? 10;
    return props.builds.slice(0, max).toReversed();
  };

  const totalWidth = () => recent().length * 10;

  return (
    <Show
      when={recent().length > 0}
      fallback={
        <svg width="80" height="16" viewBox="0 0 80 16">
          <text
            x="40"
            y="10"
            text-anchor="middle"
            font-size="9"
            fill="var(--color-fg-dim)"
            font-family="var(--font-mono)"
          >
            no builds
          </text>
        </svg>
      }
    >
      <svg
        width={totalWidth()}
        height="16"
        viewBox={`0 0 ${totalWidth()} 16`}
      >
        <For each={recent()}>
          {(build, i) => (
            <rect
              x={i() * 10}
              y="0"
              width="8"
              height="16"
              fill={STATE_COLORS[build.state]}
              rx="0"
            />
          )}
        </For>
      </svg>
    </Show>
  );
}

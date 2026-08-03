import type { components } from "../api/v1";

type BuildSource = NonNullable<components["schemas"]["Build"]["source"]>;

// `source` is now a free-form string in the spec (e.g. `push`, `manual`, `api`,
// `webhook`, `ui`); map the known ones and title-case the rest.
const SOURCE_LABELS: Record<string, string> = {
  push: "Push",
  manual: "Manual",
  api: "API",
  schedule: "Schedule",
  trigger_job: "Trigger",
  webhook: "Webhook",
  ui: "UI",
};

function sourceLabel(source: BuildSource | null | undefined): string {
  if (!source) return "—";
  return SOURCE_LABELS[source] ?? source;
}

export function TriggerBadge(props: { source: BuildSource | null | undefined }) {
  return (
    <span class="inline-flex items-center font-mono text-2xs text-fg-muted uppercase tracking-[0.04em]">
      {sourceLabel(props.source)}
    </span>
  );
}

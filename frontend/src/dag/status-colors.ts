import type { components } from "../api/v1";

type JobState = NonNullable<components["schemas"]["Job"]["state"]>;

const STATE_COLORS: Record<JobState, string> = {
  pending: "var(--color-status-queued)",
  scheduled: "var(--color-status-queued)",
  assigned: "var(--color-status-waiting)",
  running: "var(--color-status-running)",
  passed: "var(--color-status-passed)",
  failed: "var(--color-status-failed)",
  timing_out: "var(--color-status-running)",
  timed_out: "var(--color-status-timed-out)",
  canceling: "var(--color-status-canceled)",
  canceled: "var(--color-status-canceled)",
  skipped: "var(--color-status-skipped)",
};

export function statusColor(state: JobState): string {
  return STATE_COLORS[state];
}

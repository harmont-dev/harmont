import type { BadgeVariant } from "../components/StatusBadge";
import type { components } from "../api/v1";

type BuildState = NonNullable<components["schemas"]["Build"]["state"]>;

const STATE_TO_VARIANT: Record<BuildState, BadgeVariant> = {
  scheduled: "queued",
  running: "running",
  failing: "running",
  passed: "passed",
  failed: "failed",
  canceling: "canceled",
  canceled: "canceled",
};

const STATE_TO_LABEL: Record<BuildState, string> = {
  scheduled: "Scheduled",
  running: "Running",
  failing: "Failing",
  passed: "Passed",
  failed: "Failed",
  canceling: "Canceling",
  canceled: "Canceled",
};

export function buildStateToVariant(state: BuildState): BadgeVariant {
  return STATE_TO_VARIANT[state];
}

export function buildStateToLabel(state: BuildState): string {
  return STATE_TO_LABEL[state];
}

export function isBuildTerminal(state: BuildState): boolean {
  return state === "passed" || state === "failed" || state === "canceled";
}

type JobState = NonNullable<components["schemas"]["Job"]["state"]>;

const JOB_STATE_TO_VARIANT: Record<JobState, BadgeVariant> = {
  pending: "queued",
  scheduled: "queued",
  assigned: "waiting",
  running: "running",
  passed: "passed",
  failed: "failed",
  skipped: "skipped",
  canceling: "canceled",
  canceled: "canceled",
  timing_out: "running",
  timed_out: "timed-out",
};

const JOB_STATE_TO_LABEL: Record<JobState, string> = {
  pending: "Pending",
  scheduled: "Scheduled",
  assigned: "Assigned",
  running: "Running",
  passed: "Passed",
  failed: "Failed",
  skipped: "Skipped",
  canceling: "Canceling",
  canceled: "Canceled",
  timing_out: "Timing Out",
  timed_out: "Timed Out",
};

export function jobStateToVariant(state: JobState): BadgeVariant {
  return JOB_STATE_TO_VARIANT[state];
}

export function jobStateToLabel(state: JobState): string {
  return JOB_STATE_TO_LABEL[state];
}

export function isJobTerminal(state: JobState): boolean {
  return (
    state === "passed" ||
    state === "failed" ||
    state === "skipped" ||
    state === "canceled" ||
    state === "timed_out"
  );
}

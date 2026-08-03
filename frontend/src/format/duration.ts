import { intervalToDuration } from "date-fns";

export function fmtDuration(start: string, end: string): string {
  const dur = intervalToDuration({ start: new Date(start), end: new Date(end) });
  const mins = (dur.hours ?? 0) * 60 + (dur.minutes ?? 0);
  const secs = dur.seconds ?? 0;
  return mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
}

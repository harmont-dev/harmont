import { For, Show, createSignal } from "solid-js";
import { useNavigate } from "@solidjs/router";
import { TimeAgo } from "../components/TimeAgo";
import { renderCents, renderDuration } from "./format";
import type { components } from "../api/v1";

type BuildRow = components["schemas"]["UsageBreakdownBuild"];

const BUILD_COLS = "grid grid-cols-[1.5rem_1fr_6rem_4rem_6rem] gap-2";

export function UsageBreakdown(props: { builds: BuildRow[] }) {
  const navigate = useNavigate();
  const [expanded, setExpanded] = createSignal<Set<string>>(new Set());

  const rowKey = (b: BuildRow) => b.build_id ?? "no-build";
  const isExpanded = (b: BuildRow) => expanded().has(rowKey(b));

  const toggle = (b: BuildRow) => {
    const next = new Set(expanded());
    const k = rowKey(b);
    if (next.has(k)) {
      next.delete(k);
    } else {
      next.add(k);
    }
    setExpanded(next);
  };

  const runHref = (b: BuildRow): string | null =>
    b.pipeline_slug && b.build_number != null
      ? `/pipeline/${b.pipeline_slug}/run/${b.build_number}`
      : null;

  return (
    <div class="bg-bg-raise border border-border-focus rounded-[2px] shadow-[var(--shadow-card)] overflow-hidden">
      <div class={`${BUILD_COLS} px-3 py-2 text-xs font-mono font-semibold uppercase tracking-[0.06em] text-fg border-b border-border-active bg-bg-inset`}>
        <span />
        <span>Pipeline</span>
        <span>Build</span>
        <span class="text-right">Jobs</span>
        <span class="text-right">Amount</span>
      </div>

      <For each={props.builds}>
        {(b) => (
          <>
            <div
              class={`${BUILD_COLS} px-3 py-2 items-center text-sm cursor-pointer border-b border-border last:border-b-0 hover:bg-bg-hover focus:bg-bg-hover outline-none`}
              tabindex={0}
              role="button"
              aria-expanded={isExpanded(b)}
              onClick={() => toggle(b)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  toggle(b);
                }
              }}
            >
              <span class="text-fg-muted select-none" aria-hidden="true">
                {isExpanded(b) ? "▾" : "▸"}
              </span>
              <span class="text-fg truncate">
                <Show
                  when={b.pipeline_name}
                  fallback={<span class="text-fg-muted">(no pipeline)</span>}
                >
                  {b.pipeline_name}
                </Show>
                <span class="ml-2">
                  <TimeAgo date={b.started_at} />
                </span>
              </span>
              <span class="font-mono text-xs">
                <Show
                  when={runHref(b)}
                  fallback={
                    <span class="text-fg-muted">
                      {b.build_number != null ? `#${b.build_number}` : "—"}
                    </span>
                  }
                >
                  {(href) => (
                    <a
                      class="text-accent hover:underline"
                      href={href()}
                      onClick={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        navigate(href());
                      }}
                    >
                      #{b.build_number}
                    </a>
                  )}
                </Show>
              </span>
              <span class="text-right font-mono text-xs text-fg-muted">
                {b.job_count}
              </span>
              <span
                class={`text-right font-mono text-xs ${
                  b.total_cents < 0 ? "text-fg-muted" : "text-ok"
                }`}
              >
                {renderCents(b.total_cents)}
              </span>
            </div>

            <Show when={isExpanded(b)}>
              <div class="bg-bg-inset border-b border-border last:border-b-0 px-3 py-2">
                <For
                  each={b.jobs}
                  fallback={
                    <div class="py-1 text-xs font-mono text-fg-muted">
                      No job leases.
                    </div>
                  }
                >
                  {(j) => (
                    <div class="grid grid-cols-[1fr_8rem_4rem_5rem] gap-2 py-1 text-xs font-mono items-center">
                      <span class="text-fg truncate">
                        {j.job_name ?? j.step_key ?? "job"}
                      </span>
                      <span class="text-fg-muted truncate" title={j.vm_handle ?? ""}>
                        {j.vm_handle ?? "—"}
                      </span>
                      <span class="text-fg-muted text-right">
                        {renderDuration(j.duration_seconds)}
                      </span>
                      <span
                        class={`text-right ${
                          j.amount_cents < 0 ? "text-fg-muted" : "text-ok"
                        }`}
                      >
                        {renderCents(j.amount_cents)}
                      </span>
                    </div>
                  )}
                </For>
              </div>
            </Show>
          </>
        )}
      </For>
    </div>
  );
}

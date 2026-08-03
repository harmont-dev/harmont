import { type JSX, For } from "solid-js";

export type Column<T> = {
  key: string;
  label: string;
  align?: "left" | "right";
  render: (row: T) => JSX.Element;
};

export type TableProps<T> = {
  columns: Column<T>[];
  rows: T[];
  selectedIndex?: number;
  onRowClick?: (row: T, index: number) => void;
  class?: string;
};

export function Table<T>(props: TableProps<T>) {
  return (
    <div class={`bg-bg-raise border border-border-focus rounded-[2px] shadow-[var(--shadow-card)] overflow-hidden ${props.class ?? ""}`.trim()}>
      <table class="w-full border-collapse font-mono text-sm">
        <thead>
          <tr>
            <For each={props.columns}>
              {(col) => (
                <th
                  class={`py-2 px-3 text-xs font-semibold text-fg uppercase tracking-[0.06em] border-b border-border-active bg-bg-inset whitespace-nowrap ${
                    col.align === "right" ? "text-right" : "text-left"
                  }`}
                >
                  {col.label}
                </th>
              )}
            </For>
          </tr>
        </thead>
        <tbody>
          <For each={props.rows}>
            {(row, i) => (
              <tr
                class={`transition-fast cursor-pointer last:[&>td]:border-b-0 ${
                  props.selectedIndex === i() ? "[&>td]:bg-bg-selected!" : "hover:[&>td]:bg-bg-hover"
                }`}
                onClick={() => props.onRowClick?.(row, i())}
              >
                <For each={props.columns}>
                  {(col) => (
                    <td
                      class={`py-[9px] px-3 border-b border-border align-middle leading-tight ${
                        col.align === "right" ? "text-right" : ""
                      }`}
                    >
                      {col.render(row)}
                    </td>
                  )}
                </For>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

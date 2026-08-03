import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { useLocation, useNavigate } from "@solidjs/router";
import { useOrgSlug } from "../auth/context";
import { useOrganizations } from "../org/queries";
import { setDefaultOrg } from "../org/defaultOrg";
import { Avatar } from "../components/Avatar";
import { PlusIcon } from "../components/icons/PlusIcon";

export type OrgSwitcherProps = {
  onSignOut?: () => void;
};

// Buildings glyph — the standing signifier that this control governs the
// active organization. Phosphor "Buildings", 256 viewBox to match the nav set.
const IconBuildings = () => (
  <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor" class="shrink-0">
    <path d="M240,208H224V96a16,16,0,0,0-16-16H144V32a16,16,0,0,0-24.88-13.32L39.12,72A16,16,0,0,0,32,85.34V208H16a8,8,0,0,0,0,16H240a8,8,0,0,0,0-16ZM208,96V208H144V96ZM48,85.34,128,32V208H48ZM112,112v16a8,8,0,0,1-16,0V112a8,8,0,0,1,16,0Zm-32,0v16a8,8,0,0,1-16,0V112a8,8,0,0,1,16,0Zm0,56v16a8,8,0,0,1-16,0V168a8,8,0,0,1,16,0Zm32,0v16a8,8,0,0,1-16,0V168a8,8,0,0,1,16,0Z" />
  </svg>
);

// Caret points up while collapsed (the panel opens upward); flips down on open.
const IconCaret = (props: { open: boolean }) => (
  <svg
    viewBox="0 0 256 256"
    width="14"
    height="14"
    fill="currentColor"
    class={`shrink-0 text-fg-dim transition-transform duration-200 ${props.open ? "rotate-180" : ""}`}
  >
    <path d="M213.66,165.66a8,8,0,0,1-11.32,0L128,91.31,53.66,165.66a8,8,0,0,1-11.32-11.32l80-80a8,8,0,0,1,11.32,0l80,80A8,8,0,0,1,213.66,165.66Z" />
  </svg>
);

const IconSignOut = () => (
  <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor" class="shrink-0">
    <path d="M120,216a8,8,0,0,1-8,8H48a8,8,0,0,1-8-8V40a8,8,0,0,1,8-8h64a8,8,0,0,1,0,16H56V208h56A8,8,0,0,1,120,216Zm109.66-93.66-40-40a8,8,0,0,0-11.32,11.32L204.69,120H112a8,8,0,0,0,0,16h92.69l-26.35,26.34a8,8,0,0,0,11.32,11.32l40-40A8,8,0,0,0,229.66,122.34Z" />
  </svg>
);

// Rewrite the current path into another org, preserving the in-org screen where
// it makes sense. `/acme/pipelines` -> `/globex/pipelines`. Pipeline/build deep
// paths don't carry across orgs (different ids), so switching from one of those
// lands on the new org's pipelines list.
function rewritePath(pathname: string, fromSlug: string | undefined, toSlug: string): string {
  if (!fromSlug) return `/${toSlug}/pipelines`;
  const rest = pathname.startsWith(`/${fromSlug}/`)
    ? pathname.slice(fromSlug.length + 1)
    : "/pipelines";
  const sectionRoots = ["/pipelines", "/repos", "/usage", "/settings"];
  const section = sectionRoots.find((s) => rest === s || rest.startsWith(s + "/"));
  const safe = section && rest === section ? rest : "/pipelines";
  return `/${toSlug}${safe}`;
}

export function OrgSwitcher(props: OrgSwitcherProps) {
  const orgSlug = useOrgSlug();
  const orgs = useOrganizations();
  const location = useLocation();
  const navigate = useNavigate();
  const [open, setOpen] = createSignal(false);

  let root: HTMLDivElement | undefined;
  let panelInner: HTMLDivElement | undefined;
  const [panelH, setPanelH] = createSignal(0);

  const list = createMemo(() => orgs.data?.data ?? []);
  const current = createMemo(() => list().find((o) => o.slug === orgSlug()));

  // Drive the in-place expand off a measured height so the panel slides open
  // upward instead of the old floating popover. Re-measure whenever the open
  // state or the org list changes the panel's intrinsic height.
  createEffect(() => {
    open();
    list();
    setPanelH(open() ? (panelInner?.scrollHeight ?? 0) : 0);
  });

  // Collapse on an outside click — the panel pushes the nav, so a stale-open
  // panel would otherwise linger.
  onMount(() => {
    const onDocClick = (e: MouseEvent) => {
      if (open() && root && !root.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("click", onDocClick);
    onCleanup(() => document.removeEventListener("click", onDocClick));
  });

  const switchTo = (slug: string) => {
    setOpen(false);
    if (slug === orgSlug()) return;
    setDefaultOrg(slug);
    navigate(rewritePath(location.pathname, orgSlug(), slug));
  };

  const createOrg = () => {
    setOpen(false);
    navigate(`/${orgSlug() ?? ""}/settings?create-org=1`);
  };

  return (
    <div ref={root} class="relative z-10 bg-black border-t border-border">
      {/* Expanding panel: org list + create + account, sliding up above the trigger. */}
      <div
        class="overflow-hidden border-b border-border"
        style={{ height: `${panelH()}px`, transition: "height 200ms ease" }}
      >
        <div ref={panelInner}>
          <div class="px-3 pt-3 pb-1.5 font-mono text-2xs font-semibold uppercase tracking-[0.08em] text-fg-muted">
            Organizations
          </div>
          <div class="max-h-[40vh] overflow-y-auto pb-1">
            <For each={list()}>
              {(o) => {
                const active = () => o.slug === orgSlug();
                return (
                  <button
                    type="button"
                    class={`flex items-center gap-2.5 w-full px-3 py-2 text-left bg-transparent cursor-pointer transition-fast ${
                      active()
                        ? "bg-bg-selected text-fg"
                        : "text-fg-secondary hover:text-fg hover:bg-bg-hover"
                    }`}
                    onClick={() => switchTo(o.slug)}
                  >
                    <Avatar
                      name={o.name}
                      size="sm"
                      class={active() ? "ring-2 ring-accent ring-offset-2 ring-offset-bg-selected" : ""}
                    />
                    <span class="min-w-0 flex-1 truncate text-sm">{o.name}</span>
                  </button>
                );
              }}
            </For>
          </div>
          <button
            type="button"
            class="flex items-center gap-2.5 w-full px-3 py-2 text-left bg-transparent cursor-pointer text-fg-secondary hover:text-fg hover:bg-bg-hover transition-fast border-t border-border-subtle"
            onClick={createOrg}
          >
            <span class="flex items-center justify-center shrink-0 w-[26px]">
              <PlusIcon size={16} />
            </span>
            <span class="text-sm">Create organization</span>
          </button>

          <Show when={props.onSignOut}>
            <button
              type="button"
              class="flex items-center gap-2.5 w-full px-3 py-2 text-left bg-transparent cursor-pointer text-fg-muted hover:text-fg hover:bg-bg-hover transition-fast border-t border-border"
              onClick={props.onSignOut}
            >
              <span class="flex items-center justify-center shrink-0 w-[26px]">
                <IconSignOut />
              </span>
              <span class="text-sm">Sign out</span>
            </button>
          </Show>
        </div>
      </div>

      {/* Collapsed trigger: the active org, always visible at the foot of the rail. */}
      <button
        type="button"
        class="flex items-center gap-2.5 w-full px-3 py-3 text-left bg-transparent cursor-pointer text-fg-secondary hover:text-fg hover:bg-bg-hover transition-fast"
        aria-expanded={open()}
        onClick={() => setOpen((v) => !v)}
      >
        <span class="flex items-center justify-center shrink-0 w-[18px] h-[18px] text-fg-secondary">
          <IconBuildings />
        </span>
        <span class="min-w-0 flex-1 truncate font-mono text-xs font-medium uppercase tracking-[0.08em] text-fg">
          {current()?.name ?? orgSlug() ?? "Select org"}
        </span>
        <IconCaret open={open()} />
      </button>
    </div>
  );
}

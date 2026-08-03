import { type JSX, For, createSignal, createEffect } from "solid-js";
import { A, useLocation } from "@solidjs/router";
import { Logo } from "./Logo";
import { useOrgSlug } from "../auth/context";
import { OrgSwitcher } from "../org/OrgSwitcher";

export type SidebarProps = {
  user?: { name: string; avatarUrl?: string };
  onSignOut?: () => void;
  class?: string;
};

type InternalLink = {
  kind: "internal";
  label: string;
  href: string;
  suffix: string;
  icon: () => JSX.Element;
  activeOn: string[];
};

type ExternalLink = {
  kind: "external";
  label: string;
  href: string;
  icon: () => JSX.Element;
};

type NavEntry = InternalLink | ExternalLink;

const Icon = (props: { children: JSX.Element }) => (
  <span class="flex items-center justify-center shrink-0 w-[18px] h-[18px]">
    {props.children}
  </span>
);

const IconExternal = () => (
  <svg viewBox="0 0 256 256" width="12" height="12" fill="currentColor" class="shrink-0 text-fg-dim">
    <path d="M200,64V168a8,8,0,0,1-16,0V83.31L69.66,197.66a8,8,0,0,1-11.32-11.32L172.69,72H88a8,8,0,0,1,0-16H192A8,8,0,0,1,200,64Z" />
  </svg>
);

const IconGitBranch = () => (
  <Icon>
    <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor">
      <path d="M232,64a32,32,0,1,0-40,31v17a8,8,0,0,1-8,8H96a23.84,23.84,0,0,0-8,1.38V95a32,32,0,1,0-16,0v66a32,32,0,1,0,16,0V144a8,8,0,0,1,8-8h88a24,24,0,0,0,24-24V95A32.06,32.06,0,0,0,232,64ZM64,64A16,16,0,1,1,80,80,16,16,0,0,1,64,64ZM96,192a16,16,0,1,1-16-16A16,16,0,0,1,96,192ZM200,80a16,16,0,1,1,16-16A16,16,0,0,1,200,80Z" />
    </svg>
  </Icon>
);

const IconGithub = () => (
  <Icon>
    <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor">
      <path d="M208.31,75.68A59.78,59.78,0,0,0,202.93,28,8,8,0,0,0,196,24a59.75,59.75,0,0,0-48,24H124A59.75,59.75,0,0,0,76,24a8,8,0,0,0-6.93,4,59.78,59.78,0,0,0-5.38,47.68A58.14,58.14,0,0,0,56,104v8a56.06,56.06,0,0,0,48.44,55.47A39.8,39.8,0,0,0,96,192v8H72a24,24,0,0,1-24-24A40,40,0,0,0,8,136a8,8,0,0,0,0,16,24,24,0,0,1,24,24,40,40,0,0,0,40,40H96v16a8,8,0,0,0,16,0V192a24,24,0,0,1,48,0v40a8,8,0,0,0,16,0V192a39.8,39.8,0,0,0-8.44-24.53A56.06,56.06,0,0,0,216,112v-8A58.14,58.14,0,0,0,208.31,75.68ZM200,112a40,40,0,0,1-40,40H112a40,40,0,0,1-40-40v-8a41.74,41.74,0,0,1,6.9-22.48A8,8,0,0,0,80,73.83a43.81,43.81,0,0,1,.79-33.58,43.88,43.88,0,0,1,32.32,20.06A8,8,0,0,0,119.82,64h32.35a8,8,0,0,0,6.74-3.69,43.87,43.87,0,0,1,32.32-20.06A43.81,43.81,0,0,1,192,73.83a8.09,8.09,0,0,0,1,7.65A41.72,41.72,0,0,1,200,104Z" />
    </svg>
  </Icon>
);

const IconChartBar = () => (
  <Icon>
    <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor">
      <path d="M224,200h-8V40a8,8,0,0,0-8-8H152a8,8,0,0,0-8,8V88H96a8,8,0,0,0-8,8v40H48a8,8,0,0,0-8,8v56H32a8,8,0,0,0,0,16H224a8,8,0,0,0,0-16ZM160,48h40V200H160ZM104,104h40v96H104ZM56,152H88v48H56Z" />
    </svg>
  </Icon>
);

const IconBookOpen = () => (
  <Icon>
    <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor">
      <path d="M232,48H160a40,40,0,0,0-32,16A40,40,0,0,0,96,48H24a8,8,0,0,0-8,8V200a8,8,0,0,0,8,8H96a24,24,0,0,1,24,24,8,8,0,0,0,16,0,24,24,0,0,1,24-24h72a8,8,0,0,0,8-8V56A8,8,0,0,0,232,48ZM96,192H32V64H96a24,24,0,0,1,24,24V200A39.81,39.81,0,0,0,96,192Zm128,0H160a39.81,39.81,0,0,0-24,8V88a24,24,0,0,1,24-24h64Z" />
    </svg>
  </Icon>
);

const IconGear = () => (
  <Icon>
    <svg viewBox="0 0 256 256" width="18" height="18" fill="currentColor">
      <path d="M128,80a48,48,0,1,0,48,48A48.05,48.05,0,0,0,128,80Zm0,80a32,32,0,1,1,32-32A32,32,0,0,1,128,160Zm88-29.84q.06-2.16,0-4.32l14.92-18.64a8,8,0,0,0,1.48-7.06,107.21,107.21,0,0,0-10.88-26.25,8,8,0,0,0-6-3.93l-23.72-2.64q-1.48-1.56-3-3L186,40.54a8,8,0,0,0-3.94-6,107.71,107.71,0,0,0-26.25-10.87,8,8,0,0,0-7.06,1.49L130.16,40Q128,40,125.84,40L107.2,25.11a8,8,0,0,0-7.06-1.48A107.6,107.6,0,0,0,73.89,34.51a8,8,0,0,0-3.93,6L67.32,64.27q-1.56,1.49-3,3L40.54,70a8,8,0,0,0-6,3.94,107.71,107.71,0,0,0-10.87,26.25,8,8,0,0,0,1.49,7.06L40,125.84Q40,128,40,130.16L25.11,148.8a8,8,0,0,0-1.48,7.06,107.21,107.21,0,0,0,10.88,26.25,8,8,0,0,0,6,3.93l23.72,2.64q1.49,1.56,3,3L70,215.46a8,8,0,0,0,3.94,6,107.71,107.71,0,0,0,26.25,10.87,8,8,0,0,0,7.06-1.49L125.84,216q2.16.06,4.32,0l18.64,14.92a8,8,0,0,0,7.06,1.48,107.21,107.21,0,0,0,26.25-10.88,8,8,0,0,0,3.93-6l2.64-23.72q1.56-1.48,3-3L215.46,186a8,8,0,0,0,6-3.94,107.71,107.71,0,0,0,10.87-26.25,8,8,0,0,0-1.49-7.06Zm-16.1-6.5a73.93,73.93,0,0,1,0,8.68,8,8,0,0,0,1.74,5.68l14.19,17.73a91.57,91.57,0,0,1-6.23,15L187.11,168a8,8,0,0,0-5.1,2.64,74.11,74.11,0,0,1-6.14,6.14,8,8,0,0,0-2.64,5.1l-2.51,22.58a91.32,91.32,0,0,1-15,6.23l-17.74-14.19a8,8,0,0,0-5-1.75h-.7a73.93,73.93,0,0,1-8.68,0,8,8,0,0,0-5.68,1.74L100.2,210.73a91.57,91.57,0,0,1-15-6.23L82.46,182.11A8,8,0,0,0,79.82,177a74.11,74.11,0,0,1-6.14-6.14,8,8,0,0,0-5.1-2.64L46.05,165.68a91.32,91.32,0,0,1-6.23-15l14.19-17.74a8,8,0,0,0,1.74-5.68,73.93,73.93,0,0,1,0-8.68,8,8,0,0,0-1.74-5.68L39.82,95.2a91.57,91.57,0,0,1,6.23-15L68.46,77.46A8,8,0,0,0,73.56,74.82a74.11,74.11,0,0,1,6.14-6.14A8,8,0,0,0,82.34,63.58L84.85,41a91.32,91.32,0,0,1,15-6.23l17.74,14.19a8,8,0,0,0,5.68,1.74,73.93,73.93,0,0,1,8.68,0,8,8,0,0,0,5.68-1.74L155.8,34.82a91.57,91.57,0,0,1,15,6.23l2.51,22.58a8,8,0,0,0,2.64,5.1,74.11,74.11,0,0,1,6.14,6.14,8,8,0,0,0,5.1,2.64l22.58,2.51a91.32,91.32,0,0,1,6.23,15l-14.19,17.74A8,8,0,0,0,199.87,123.66Z" />
    </svg>
  </Icon>
);

const NAV_ITEMS: NavEntry[] = [
  { kind: "internal", label: "Pipelines", href: "/pipelines", suffix: "/pipelines", icon: IconGitBranch, activeOn: ["/pipelines"] },
  { kind: "internal", label: "Repos", href: "/repos", suffix: "/repos", icon: IconGithub, activeOn: ["/repos", "/github"] },
  { kind: "internal", label: "Usage", href: "/usage", suffix: "/usage", icon: IconChartBar, activeOn: ["/usage"] },
  { kind: "internal", label: "Settings", href: "/settings", suffix: "/settings", icon: IconGear, activeOn: ["/settings"] },
  { kind: "external", label: "Docs", href: "https://docs.harmont.dev/", icon: IconBookOpen },
];

function isActive(pathname: string, entry: InternalLink, slug?: string): boolean {
  const orgPrefix = slug ? `/${slug}` : "";
  return entry.activeOn.some((suffix) => {
    const full = `${orgPrefix}${suffix}`;
    return pathname === full || pathname.startsWith(full + "/");
  });
}

// `relative` so the item text/icons paint above the absolutely-positioned
// sliding highlight; `border-transparent` reserves the 1px so text doesn't
// shift relative to the active item (whose border lives on the highlight).
const LINK_CLASS =
  "relative flex items-center gap-2.5 px-3 py-2 border border-transparent font-mono text-xs font-medium uppercase tracking-[0.08em] whitespace-nowrap no-underline";
// Inactive item: a hover gradient that echoes the active highlight but lighter
// (grey fading to transparent, vs the active's full grey two-tone).
const INACTIVE_LINK =
  "text-fg-secondary hover:text-fg hover:border-t-border-active hover:border-b-border-active hover:bg-gradient-to-r hover:from-bg-hover hover:to-transparent";
// A single shared highlight slides between active items (top/height animated):
// a subtle grey gradient with top/bottom/right hairlines, full-bleed and flush
// to the left edge (no left border, no rounding).
const HIGHLIGHT_CLASS =
  "pointer-events-none absolute left-0 right-0 border border-border-active bg-gradient-to-r from-bg-hover to-bg-raise";

export function Sidebar(props: SidebarProps) {
  const location = useLocation();
  const orgSlug = useOrgSlug();
  let navRef: HTMLElement | undefined;
  const [hl, setHl] = createSignal({ top: 0, height: 0, shown: false });

  const orgHref = (suffix: string) => {
    const slug = orgSlug();
    return slug ? `/${slug}${suffix}` : suffix;
  };

  const activeIndex = () =>
    NAV_ITEMS.findIndex(
      (it) => it.kind === "internal" && isActive(location.pathname, it, orgSlug()),
    );

  // Position the highlight on the active item. Measured from the rendered
  // anchors (DOM order matches NAV_ITEMS), so it stays correct without threading
  // refs through <A>. Re-runs whenever the route (and thus activeIndex) changes.
  createEffect(() => {
    const i = activeIndex();
    if (!navRef || i < 0) {
      setHl((h) => ({ ...h, shown: false }));
      return;
    }
    const el = navRef.querySelectorAll<HTMLElement>("a")[i];
    if (el) setHl({ top: el.offsetTop, height: el.offsetHeight, shown: true });
  });

  return (
    <div class={`relative w-[200px] shrink-0 h-full bg-black border-r border-border flex flex-col overflow-hidden ${props.class ?? ""}`.trim()}>

      <div class="relative z-10 shrink-0 h-16 flex items-center justify-center">
        <A class="flex items-center justify-center" href={orgHref("/pipelines")}>
          <Logo size="xl" class="drop-shadow-[0_1px_3px_rgba(0,0,0,0.95)]" />
        </A>
      </div>

      <nav ref={navRef} class="relative z-10 flex-1 flex flex-col py-3 overflow-y-auto">
        <div
          class={HIGHLIGHT_CLASS}
          style={{
            top: `${hl().top}px`,
            height: `${hl().height}px`,
            opacity: hl().shown ? "1" : "0",
          }}
        />
        <For each={NAV_ITEMS}>
          {(item) => {
            if (item.kind === "external") {
              return (
                <a
                  class={`${LINK_CLASS} ${INACTIVE_LINK}`}
                  href={item.href}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  {item.icon()}
                  <span class="overflow-hidden flex-1">{item.label}</span>
                  <IconExternal />
                </a>
              );
            }

            const active = () => isActive(location.pathname, item, orgSlug());
            return (
              <A
                class={`${LINK_CLASS} ${active() ? "text-fg" : INACTIVE_LINK}`}
                href={orgHref(item.suffix)}
              >
                {item.icon()}
                <span class="overflow-hidden">{item.label}</span>
              </A>
            );
          }}
        </For>
      </nav>

      <OrgSwitcher onSignOut={props.onSignOut} />
    </div>
  );
}

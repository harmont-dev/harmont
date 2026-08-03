import { Show, type JSX } from "solid-js";
import { GithubIcon } from "./icons/GithubIcon";
import { BitbucketIcon } from "./icons/BitbucketIcon";
import { CliIcon } from "./icons/CliIcon";

type ChipStyle = { label: string; classes: string; icon: JSX.Element };

// Per-channel colour + icon. GitHub App → accent blue, Bitbucket → cyan,
// CLI → green. Each uses a tinted background with matching foreground, matching
// the Tag/StatusBadge convention (`text-X bg-X/10`).
function styleFor(provider: string): ChipStyle {
  switch (provider) {
    case "github":
      return {
        label: "GitHub App",
        classes: "text-accent-hover bg-accent/10",
        icon: <GithubIcon size={11} />,
      };
    case "bitbucket":
      return {
        label: "Bitbucket",
        classes: "text-cyan-hover bg-cyan/10",
        icon: <BitbucketIcon size={11} />,
      };
    case "cli":
      return {
        label: "CLI",
        classes: "text-ok bg-ok/10",
        icon: <CliIcon size={11} />,
      };
    default:
      return {
        label: provider,
        classes: "text-fg-muted bg-fg-dim/10",
        icon: <></>,
      };
  }
}

export function RegistrationChip(props: { provider: string; account?: string; class?: string }) {
  const s = () => styleFor(props.provider);
  return (
    <span
      class={`inline-flex items-center gap-1 font-mono text-2xs uppercase tracking-[0.04em] py-[2px] px-[6px] rounded-[2px] ${s().classes} ${props.class ?? ""}`.trim()}
    >
      {s().icon}
      {s().label}
      <Show when={props.account}>
        {(acct) => (
          <span class="normal-case tracking-normal text-fg-muted font-normal">
            {acct()}
          </span>
        )}
      </Show>
    </span>
  );
}

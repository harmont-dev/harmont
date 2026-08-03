import { Button } from "./Button";
import { PlusIcon } from "./icons/PlusIcon";

/**
 * The `+` button that toggles an inline form open. While open it rotates into
 * a flat-red `×` (cancel). Pair with `Collapsible` for the expanding body.
 */
export function ExpandToggle(props: {
  open: boolean;
  onToggle: () => void;
  /** aria-label when closed, e.g. "Create API key". */
  label: string;
}) {
  return (
    <Button
      variant={props.open ? "danger" : "default"}
      class={props.open ? "shadow-none!" : ""}
      icon={
        <PlusIcon
          class={`transition-transform duration-200 ${props.open ? "rotate-45" : ""}`}
        />
      }
      onClick={props.onToggle}
      aria-label={props.open ? "Cancel" : props.label}
      aria-expanded={props.open}
    />
  );
}

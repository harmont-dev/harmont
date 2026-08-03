import { TextField } from "@kobalte/core/text-field";
import { type ComponentProps, Show, splitProps } from "solid-js";

export type TextInputProps = {
  label?: string;
  value?: string;
  onInput?: (value: string) => void;
  placeholder?: string;
  id?: string;
  class?: string;
  error?: string;
  type?: string;
  onKeyDown?: (e: KeyboardEvent) => void;
  onBlur?: () => void;
  autofocus?: boolean;
};

export function TextInput(props: TextInputProps) {
  return (
    <TextField
      value={props.value}
      onChange={props.onInput}
      class={`flex flex-col gap-1 ${props.class ?? ""}`.trim()}
      validationState={props.error ? "invalid" : "valid"}
    >
      <Show when={props.label}>
        <TextField.Label class="font-mono text-xs font-medium text-fg-secondary uppercase tracking-[0.04em]">
          {props.label}
        </TextField.Label>
      </Show>
      <TextField.Input
        id={props.id}
        type={props.type}
        placeholder={props.placeholder}
        onKeyDown={props.onKeyDown}
        onBlur={props.onBlur}
        autofocus={props.autofocus}
        class="py-2 px-[10px] font-mono text-sm text-fg bg-bg border border-border-focus rounded-[2px] outline-hidden transition-fast focus:border-accent focus:bg-bg-raise placeholder:text-fg-dim"
      />
      <Show when={props.error}>
        <TextField.ErrorMessage class="text-status-failed text-sm font-mono">
          {props.error}
        </TextField.ErrorMessage>
      </Show>
    </TextField>
  );
}

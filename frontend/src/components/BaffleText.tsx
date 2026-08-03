import { onMount, onCleanup } from "solid-js";
import baffle from "baffle";

type Charset = "ascii" | "block" | "matrix" | "cjk";

const charsets: Record<Charset, string> = {
  ascii: "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz~!@#$%^&*()-+=[]{}|;:,./<>?",
  block: "█▓▒░█▓▒░</>",
  matrix: "∑∂∆λΩπ╔╗╚╝║═░▒▓█◈◇«»‡†¤§¶01{}<>/\\:;",
  cjk: "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン電脳機密暗号鍵認証零壱鬼龍夢幻影無限天地風雷火水光闇",
};

export type BaffleTextProps = {
  text: string;
  class?: string;
  charset?: Charset;
  speed?: number;
  reveal?: boolean;
  revealDuration?: number;
  revealDelay?: number;
  exclude?: string[];
};

export function BaffleText(props: BaffleTextProps) {
  let ref!: HTMLSpanElement;

  onMount(() => {
    const b = baffle(ref, {
      characters: charsets[props.charset ?? "block"],
      speed: props.speed ?? 50,
      exclude: props.exclude ?? [" "],
    });
    b.start();
    if (props.reveal !== false) {
      b.reveal(props.revealDuration ?? 1500, props.revealDelay ?? 0);
    }

    onCleanup(() => b.stop());
  });

  return (
    <span ref={ref} class={props.class}>
      {props.text}
    </span>
  );
}

import { useLocation } from "@solidjs/router";
import { Show, type ParentProps } from "solid-js";
import { Motion, Presence } from "solid-motionone";
import { Logo } from "../components/Logo";
import { MatrixGradient } from "../components/MatrixGradient";
import { TransitionHeight } from "../components/TransitionHeight";

export function AuthLayout(props: ParentProps) {
  const location = useLocation();

  return (
    <div class="flex h-screen w-full overflow-hidden bg-bg">
      <div class="flex w-full md:max-w-lg md:shrink-0 flex-col justify-center p-8 md:p-16">
        <div class="flex flex-col gap-8">
          <Logo size="3xl" />
          <TransitionHeight duration={120}>
            <Presence exitBeforeEnter>
              <Show when={location.pathname} keyed>
                {(_) => (
                  <Motion.div
                    class="flex flex-col gap-8"
                    initial={{ opacity: 0, y: 4 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -4 }}
                    transition={{ duration: 0.1, easing: "ease-out" }}
                  >
                    {props.children}
                  </Motion.div>
                )}
              </Show>
            </Presence>
          </TransitionHeight>
        </div>
      </div>

      <div class="relative flex-1 min-h-0 self-stretch hidden md:block">
        <MatrixGradient />
        <div class="absolute inset-y-0 left-0 w-1/3 bg-gradient-to-r from-bg to-transparent pointer-events-none" />
      </div>
    </div>
  );
}

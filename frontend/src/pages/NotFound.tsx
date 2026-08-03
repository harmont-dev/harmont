import { useLocation, useNavigate } from "@solidjs/router";
import { Button } from "../components/Button";

export function NotFoundPage() {
  const location = useLocation();
  const navigate = useNavigate();

  return (
    <div class="mx-auto flex max-w-[560px] flex-col items-start gap-5 py-20">
      <div class="font-mono text-4xl font-semibold text-fg-secondary">404</div>
      <h1 class="text-xl font-semibold text-fg">Page not found</h1>
      <p class="text-sm text-fg-secondary">
        Nothing lives at{" "}
        <code class="font-mono text-fg bg-bg-inset border border-border-subtle rounded-[2px] px-1.5 py-0.5">
          {location.pathname}
        </code>
        . Check the URL, or head back to your pipelines.
      </p>
      <Button variant="default" onClick={() => navigate("/")}>
        Back to pipelines
      </Button>
    </div>
  );
}

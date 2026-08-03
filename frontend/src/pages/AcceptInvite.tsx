import { Show, createEffect } from "solid-js";
import { useNavigate, useSearchParams } from "@solidjs/router";
import { hasToken } from "../auth/token";
import { useAcceptInvite } from "../org/queries";
import { setDefaultOrg } from "../org/defaultOrg";
import { apiErrorMessage } from "../api/errors";
import { Button } from "../components/Button";
import { ErrorBanner } from "../components/ErrorBanner";

// Invite link target. Not wrapped in AppLayout (no org context yet): the token
// names the org. If the visitor isn't logged in, we bounce to /login and return
// here afterward via the `next` param. Note: the login page does not currently
// honor `next`, so a logged-out visitor will land on their default org after
// signing in rather than returning here — known v1 gap.
export function AcceptInvitePage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const accept = useAcceptInvite();
  const token = () => (params.token as string | undefined) ?? "";

  createEffect(() => {
    if (!hasToken()) {
      const next = encodeURIComponent(`/invite/accept?token=${token()}`);
      navigate(`/login?next=${next}`, { replace: true });
    }
  });

  const onAccept = () => {
    accept.mutate(token(), {
      onSuccess: (org) => {
        setDefaultOrg(org.slug);
        navigate(`/${org.slug}/pipelines`, { replace: true });
      },
    });
  };

  return (
    <div class="min-h-screen flex items-center justify-center p-6">
      <div class="w-full max-w-sm flex flex-col gap-4 text-center">
        <h1 class="text-lg text-fg">You've been invited to an organization</h1>
        <p class="text-sm text-fg-dim">
          Accept to join. You must be signed in as the invited email address.
        </p>
        <Show when={accept.isError}>
          <ErrorBanner message={apiErrorMessage(accept.error)} />
        </Show>
        <Button
          variant="primary"
          onClick={onAccept}
          disabled={!token() || accept.isPending}
        >
          Accept invite
        </Button>
      </div>
    </div>
  );
}

import type { RouteSectionProps } from "@solidjs/router";
import { useNavigate, useParams } from "@solidjs/router";
import { createEffect, Show } from "solid-js";
import { Sidebar } from "../components/Sidebar";
import { useCurrentUser, useLogout } from "../auth/queries";
import { useOrganizations } from "../org/queries";
import { hasToken } from "../auth/token";
import { OrgProvider } from "../auth/context";
import { setDefaultOrg } from "../org/defaultOrg";

export function AppLayout(props: RouteSectionProps) {
  const navigate = useNavigate();
  const user = useCurrentUser();
  const orgs = useOrganizations();
  const logout = useLogout();
  const params = useParams();

  // The org context is now the URL slug — the source of truth (Buildkite-style).
  const orgSlug = () => params.orgSlug as string | undefined;

  const authed = () => hasToken() && !user.isError;

  createEffect(() => {
    if (!authed()) {
      navigate("/login", { replace: true });
    }
  });

  // Membership guard + default-org persistence: once the org list loads, a slug
  // the user doesn't belong to bounces to their default org; a valid slug is
  // remembered as the new default. We DON'T 404 here — the backend already
  // returns 404 for non-member org data; this is the friendly client redirect.
  createEffect(() => {
    const slug = orgSlug();
    if (!slug || !orgs.isSuccess) return;
    const list = orgs.data?.data ?? [];
    if (list.some((o) => o.slug === slug)) {
      setDefaultOrg(slug);
    } else {
      navigate("/", { replace: true });
    }
  });

  const handleSignOut = () => {
    logout.mutate();
    navigate("/login", { replace: true });
  };

  return (
    <Show when={authed()}>
      <OrgProvider value={{ orgSlug }}>
        <div class="flex h-screen overflow-hidden">
          <Sidebar
            user={
              user.data ? { name: user.data.name ?? user.data.email } : undefined
            }
            onSignOut={handleSignOut}
          />
          <main class="flex-1 min-w-0 overflow-y-auto p-6">{props.children}</main>
        </div>
      </OrgProvider>
    </Show>
  );
}

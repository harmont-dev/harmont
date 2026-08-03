import { createEffect, Show } from "solid-js";
import { Navigate, useNavigate } from "@solidjs/router";
import { useCurrentUser } from "../auth/queries";
import { useOrganizations } from "../org/queries";
import { getDefaultOrg } from "../org/defaultOrg";

// Resolves bare `/` to the user's last-active org (cookie), else their personal
// org, else the first org they belong to. Renders nothing visible — it's a
// routing hop. If the user belongs to no org at all (shouldn't happen: signup
// always makes a personal org), it falls through to the org list in settings.
export function OrgRedirectPage() {
  const user = useCurrentUser();
  const orgs = useOrganizations();
  const navigate = useNavigate();

  const target = () => {
    const cookie = getDefaultOrg();
    const list = orgs.data?.data ?? [];
    const known = (slug?: string) => list.some((o) => o.slug === slug);

    if (cookie && known(cookie)) return cookie;
    const personal = user.data?.personal_org_slug ?? undefined;
    if (personal && known(personal)) return personal;
    return list[0]?.slug;
  };

  createEffect(() => {
    const slug = target();
    if (slug) navigate(`/${slug}/pipelines`, { replace: true });
  });

  return (
    <Show when={orgs.isSuccess && !target()}>
      <Navigate href="/login" />
    </Show>
  );
}

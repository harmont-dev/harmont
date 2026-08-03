import { createContext, useContext, type Accessor } from "solid-js";

type OrgContext = {
  orgSlug: Accessor<string | undefined>;
};

const OrgCtx = createContext<OrgContext>();

export const OrgProvider = OrgCtx.Provider;

export function useOrgSlug(): Accessor<string | undefined> {
  const ctx = useContext(OrgCtx);
  if (!ctx) return () => undefined;
  return ctx.orgSlug;
}

import { createEffect, createSignal } from "solid-js";
import { useSearchParams } from "@solidjs/router";
import { ProfileSection } from "../settings/ProfileSection";
import { OrganizationSection } from "../settings/OrganizationSection";
import { OrganizationsListSection } from "../settings/OrganizationsListSection";
import { MembersSection } from "../settings/MembersSection";
import { ConnectedAccountsSection } from "../settings/ConnectedAccountsSection";
import { BitbucketSection } from "../settings/BitbucketSection";
import { CouponSection } from "../settings/CouponSection";
import { PasskeysSection } from "../settings/PasskeysSection";
import { ApiKeysSection } from "../apikeys/ApiKeysSection";
import { DangerZoneSection } from "../settings/DangerZoneSection";
import { CreateOrgDialog } from "../org/CreateOrgDialog";

export function SettingsPage() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [createOpen, setCreateOpen] = createSignal(false);

  createEffect(() => {
    if (searchParams["create-org"] === "1") setCreateOpen(true);
  });

  const closeCreate = () => {
    setCreateOpen(false);
    setSearchParams({ "create-org": undefined });
  };

  return (
    <div class="max-w-[720px] mx-auto">
      <h1 class="text-xl font-semibold text-fg mb-6">Settings</h1>
      <div class="flex flex-col gap-6">
        <ProfileSection />
        <OrganizationSection />
        <MembersSection />
        <OrganizationsListSection />
        <ConnectedAccountsSection />
        <BitbucketSection />
        <CouponSection />
        <PasskeysSection />
        <ApiKeysSection />
        <DangerZoneSection />
      </div>
      <CreateOrgDialog open={createOpen()} onClose={closeCreate} />
    </div>
  );
}

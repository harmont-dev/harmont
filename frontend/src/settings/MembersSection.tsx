import { For, Show, createMemo, createSignal } from "solid-js";
import { useOrgSlug } from "../auth/context";
import { useCurrentUser } from "../auth/queries";
import {
  useOrgMembers,
  useUpdateMemberRole,
  useRemoveMember,
  useOrgInvites,
  useCreateInvite,
  useRevokeInvite,
} from "../org/queries";
import { Panel } from "../components/Panel";
import { PanelList, PanelRow } from "../components/PanelList";
import { QueryGuard } from "../components/QueryGuard";
import { Button } from "../components/Button";
import { Tag } from "../components/Tag";
import { TextInput } from "../components/TextInput";
import { pushToast } from "../components/toast";
import { apiErrorMessage } from "../api/errors";

const ROLE_SELECT_CLASS =
  "bg-bg-raise border border-border text-fg text-xs px-2 py-1 rounded-[2px] outline-none focus:border-accent cursor-pointer";

export function MembersSection() {
  const orgSlug = useOrgSlug();
  const user = useCurrentUser();
  const members = useOrgMembers(orgSlug);
  const invites = useOrgInvites(orgSlug);
  const updateRole = useUpdateMemberRole(orgSlug);
  const removeMember = useRemoveMember(orgSlug);
  const createInvite = useCreateInvite(orgSlug);
  const revokeInvite = useRevokeInvite(orgSlug);

  const myRole = createMemo(
    () => members.data?.data.find((m) => m.user_uuid === user.data?.uuid)?.role,
  );
  const canManage = () => myRole() === "owner" || myRole() === "admin";

  const [inviteEmail, setInviteEmail] = createSignal("");
  const [inviteRole, setInviteRole] = createSignal<"admin" | "member">("member");
  const [inviteError, setInviteError] = createSignal<string | undefined>(undefined);

  function handleInvite() {
    const email = inviteEmail().trim();
    if (!email) {
      setInviteError("Email is required.");
      return;
    }
    setInviteError(undefined);
    createInvite.mutate(
      { email, role: inviteRole() },
      {
        onSuccess: (inv) => {
          setInviteEmail("");
          const token = inv.token;
          if (token) {
            const link = `${window.location.origin}/invite/accept?token=${token}`;
            navigator.clipboard?.writeText(link);
          }
          pushToast("Invite created — link copied to clipboard.", "info");
        },
        onError: (err) => {
          pushToast(apiErrorMessage(err));
        },
      },
    );
  }

  return (
    <>
      <Panel title="Members" description="People with access to this organization.">
        <QueryGuard query={members} loadingRows={2}>
          <PanelList>
            <For each={members.data?.data ?? []}>
              {(m) => {
                const isMe = () => m.user_uuid === user.data?.uuid;
                return (
                  <PanelRow class="justify-between">
                    <div class="min-w-0">
                      <div class="text-sm text-fg truncate">{m.name ?? m.email}</div>
                      <div class="font-mono text-xs text-fg-dim mt-0.5">{m.email}</div>
                    </div>
                    <div class="flex items-center gap-2 shrink-0">
                      <Show
                        when={canManage() && !isMe()}
                        fallback={<Tag variant="default">{m.role}</Tag>}
                      >
                        <select
                          class={ROLE_SELECT_CLASS}
                          value={m.role}
                          onChange={(e) => {
                            const role = e.currentTarget.value as
                              | "owner"
                              | "admin"
                              | "member";
                            updateRole.mutate({ userId: m.user_uuid, role });
                          }}
                        >
                          <option value="owner">owner</option>
                          <option value="admin">admin</option>
                          <option value="member">member</option>
                        </select>
                        <Button
                          variant="danger"
                          size="sm"
                          disabled={removeMember.isPending}
                          onClick={() => removeMember.mutate(m.user_uuid)}
                        >
                          Remove
                        </Button>
                      </Show>
                    </div>
                  </PanelRow>
                );
              }}
            </For>
          </PanelList>
        </QueryGuard>
      </Panel>

      <Show when={canManage()}>
        <Panel title="Invite" description="Send an invite link to add someone to this organization.">
          <div class="flex items-end gap-3">
            <TextInput
              class="flex-1"
              label="Email"
              placeholder="colleague@example.com"
              value={inviteEmail()}
              onInput={setInviteEmail}
              error={inviteError()}
              type="email"
            />
            <div class="flex flex-col gap-1 shrink-0">
              <span class="font-mono text-xs font-medium text-fg-secondary uppercase tracking-[0.04em]">
                Role
              </span>
              <select
                class={ROLE_SELECT_CLASS + " py-[9px]"}
                value={inviteRole()}
                onChange={(e) =>
                  setInviteRole(e.currentTarget.value as "admin" | "member")
                }
              >
                <option value="member">member</option>
                <option value="admin">admin</option>
              </select>
            </div>
            <Button
              variant="primary"
              disabled={createInvite.isPending}
              onClick={handleInvite}
            >
              Invite
            </Button>
          </div>
        </Panel>

        <Show when={(invites.data?.data ?? []).length > 0}>
          <Panel title="Pending invites" description="These invites have been sent but not yet accepted.">
            <QueryGuard query={invites} loadingRows={2}>
              <PanelList>
                <For each={invites.data?.data ?? []}>
                  {(inv) => (
                    <PanelRow class="justify-between">
                      <div class="min-w-0">
                        <div class="text-sm text-fg truncate">{inv.email}</div>
                        <div class="font-mono text-xs text-fg-dim mt-0.5">
                          <Tag variant="muted">{inv.role}</Tag>
                        </div>
                      </div>
                      <Button
                        variant="danger"
                        size="sm"
                        disabled={revokeInvite.isPending}
                        onClick={() => revokeInvite.mutate(inv.id)}
                      >
                        Revoke
                      </Button>
                    </PanelRow>
                  )}
                </For>
              </PanelList>
            </QueryGuard>
          </Panel>
        </Show>
      </Show>
    </>
  );
}

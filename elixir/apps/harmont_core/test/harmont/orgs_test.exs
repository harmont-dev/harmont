defmodule Harmont.OrgsTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts.User
  alias Harmont.Orgs
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.OrgMember
  alias Harmont.Orgs.SignupAttempt
  alias Harmont.Orgs.Slug

  # ---------------------------------------------------------------------------
  # Schema changeset tests
  # ---------------------------------------------------------------------------

  describe "Organization.changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"})
      assert cs.valid?
    end

    test "optional url accepted" do
      cs =
        Organization.changeset(%Organization{}, %{
          name: "Acme",
          slug: "acme",
          url: "https://acme.com"
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = Organization.changeset(%Organization{}, %{})
      refute cs.valid?
      assert cs.errors[:name]
      assert cs.errors[:slug]
    end

    test "slug unique constraint is declared" do
      {:ok, _} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "abc"}))

      {:error, cs} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "B", slug: "abc"}))

      assert cs.errors[:slug]
    end
  end

  describe "OrgMember.changeset/2" do
    setup do
      {:ok, org} = Repo.insert(Organization.changeset(%Organization{}, %{name: "O", slug: "o1"}))

      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"}))

      %{org: org, user: user}
    end

    test "valid attrs produce a valid changeset", %{org: org, user: user} do
      cs =
        OrgMember.changeset(%OrgMember{}, %{
          organization_id: org.id,
          user_id: user.id,
          role: :admin
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = OrgMember.changeset(%OrgMember{}, %{})
      refute cs.valid?
      assert cs.errors[:organization_id]
      assert cs.errors[:user_id]
      assert cs.errors[:role]
    end

    test "rejects invalid role enum" do
      cs = OrgMember.changeset(%OrgMember{}, %{role: :superadmin})
      refute cs.valid?
      assert cs.errors[:role]
    end

    test "unique constraint on (organization_id, user_id)", %{org: org, user: user} do
      {:ok, _} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org.id,
            user_id: user.id,
            role: :admin
          })
        )

      {:error, cs} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org.id,
            user_id: user.id,
            role: :member
          })
        )

      assert cs.errors[:organization_id] || cs.errors[:user_id]
    end
  end

  describe "SignupAttempt.changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        SignupAttempt.changeset(%SignupAttempt{}, %{
          email: "bob@example.com",
          decision: :allowed
        })

      assert cs.valid?
    end

    test "nullable provider is accepted" do
      cs =
        SignupAttempt.changeset(%SignupAttempt{}, %{
          email: "bob@example.com",
          provider: :google,
          decision: :allowed
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = SignupAttempt.changeset(%SignupAttempt{}, %{})
      refute cs.valid?
      assert cs.errors[:email]
      assert cs.errors[:decision]
    end

    test "rejects invalid decision enum" do
      cs =
        SignupAttempt.changeset(%SignupAttempt{}, %{
          email: "x@example.com",
          decision: :maybe
        })

      refute cs.valid?
      assert cs.errors[:decision]
    end

    test "rejects invalid provider enum" do
      cs =
        SignupAttempt.changeset(%SignupAttempt{}, %{
          email: "x@example.com",
          decision: :allowed,
          provider: :twitter
        })

      refute cs.valid?
      assert cs.errors[:provider]
    end
  end

  # ---------------------------------------------------------------------------
  # Slug helpers
  # ---------------------------------------------------------------------------

  describe "Slug.normalize/1" do
    test "lowercases text" do
      assert Slug.normalize("ACME") == "acme"
    end

    test "replaces non-alphanumeric with hyphens" do
      assert Slug.normalize("hello world") == "hello-world"
      assert Slug.normalize("foo.bar") == "foo-bar"
    end

    test "collapses consecutive hyphens" do
      assert Slug.normalize("foo--bar") == "foo-bar"
      assert Slug.normalize("a...b") == "a-b"
    end

    test "trims leading and trailing hyphens" do
      assert Slug.normalize("-hello-") == "hello"
      assert Slug.normalize("...leading") == "leading"
    end

    test "mixed example" do
      assert Slug.normalize("  Hello World! ") == "hello-world"
    end
  end

  describe "Slug.email_to_slug/1" do
    test "converts a simple email" do
      assert Slug.email_to_slug("alice@example.com") == "alice-example-com"
    end

    test "joins local+domain parts with hyphens" do
      assert Slug.email_to_slug("a.b@c.org") == "a-b-c-org"
    end

    test "handles dots in local part" do
      assert Slug.email_to_slug("first.last@corp.io") == "first-last-corp-io"
    end

    test "lowercases everything" do
      assert Slug.email_to_slug("ALICE@EXAMPLE.COM") == "alice-example-com"
    end

    test "input without an @ does not crash and yields a slug" do
      # Treated as a single part; must not MatchError on the missing @.
      assert Slug.email_to_slug("no-at-sign") == "no-at-sign"
    end

    test "all-symbol input falls back to a safe default rather than an empty slug" do
      assert Slug.email_to_slug("!!!@???") == "user"
    end

    test "empty string falls back to the default slug" do
      assert Slug.email_to_slug("") == "user"
    end
  end

  describe "Slug.pick_free_slug/2" do
    test "returns base when it is free" do
      assert Slug.pick_free_slug("free-slug", Repo) == "free-slug"
    end

    test "appends -2 when base is taken" do
      {:ok, _} = Repo.insert(Organization.changeset(%Organization{}, %{name: "X", slug: "taken"}))
      assert Slug.pick_free_slug("taken", Repo) == "taken-2"
    end

    test "walks base-2, base-3 until a free slot is found" do
      {:ok, _} = Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "walk"}))

      {:ok, _} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "B", slug: "walk-2"}))

      assert Slug.pick_free_slug("walk", Repo) == "walk-3"
    end
  end

  # ---------------------------------------------------------------------------
  # require_member
  # ---------------------------------------------------------------------------

  describe "Orgs.require_member/3" do
    setup do
      {:ok, org} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "Org", slug: "org-rm"}))

      {:ok, member_user} =
        Repo.insert(User.changeset(%User{}, %{name: "Member", email: "member@example.com"}))

      {:ok, other_user} =
        Repo.insert(User.changeset(%User{}, %{name: "Other", email: "other@example.com"}))

      {:ok, _} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org.id,
            user_id: member_user.id,
            role: :member
          })
        )

      %{org: org, member_user: member_user, other_user: other_user}
    end

    test "returns :ok for a member", %{org: org, member_user: member_user} do
      assert Orgs.require_member(member_user, org, Repo) == :ok
    end

    test "returns {:error, :not_found} for a non-member", %{org: org, other_user: other_user} do
      assert Orgs.require_member(other_user, org, Repo) == {:error, :not_found}
    end

    test "returns :ok for the service user regardless of membership", %{org: org} do
      service_user = %User{id: Ecto.UUID.generate(), email: "service@harmont.local", name: "svc"}
      assert Orgs.require_member(service_user, org, Repo) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_org_scoped
  # ---------------------------------------------------------------------------

  describe "Orgs.fetch_org_scoped/3" do
    setup do
      {:ok, org} =
        Repo.insert(
          Organization.changeset(%Organization{}, %{name: "Scoped", slug: "scoped-org"})
        )

      {:ok, member_user} =
        Repo.insert(User.changeset(%User{}, %{name: "Scoped M", email: "scopedm@example.com"}))

      {:ok, other_user} =
        Repo.insert(User.changeset(%User{}, %{name: "Scoped O", email: "scopedo@example.com"}))

      {:ok, _} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org.id,
            user_id: member_user.id,
            role: :admin
          })
        )

      %{org: org, member_user: member_user, other_user: other_user}
    end

    test "returns {:ok, org} for a member", %{org: org, member_user: member_user} do
      assert {:ok, fetched} = Orgs.fetch_org_scoped(member_user, "scoped-org", Repo)
      assert fetched.id == org.id
    end

    test "returns {:error, :not_found} when slug does not exist", %{member_user: member_user} do
      assert Orgs.fetch_org_scoped(member_user, "no-such-org", Repo) == {:error, :not_found}
    end

    test "returns {:error, :not_found} for a non-member (same error as slug-miss)", %{
      other_user: other_user
    } do
      assert Orgs.fetch_org_scoped(other_user, "scoped-org", Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # list_for_user
  # ---------------------------------------------------------------------------

  describe "Orgs.list_for_user/2" do
    setup do
      {:ok, org_a} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "A", slug: "lfu-a"}))

      {:ok, org_b} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "B", slug: "lfu-b"}))

      {:ok, _org_c} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "C", slug: "lfu-c"}))

      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "LFU", email: "lfu@example.com"}))

      {:ok, _} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org_a.id,
            user_id: user.id,
            role: :member
          })
        )

      {:ok, _} =
        Repo.insert(
          OrgMember.changeset(%OrgMember{}, %{
            organization_id: org_b.id,
            user_id: user.id,
            role: :admin
          })
        )

      %{user: user, org_a: org_a, org_b: org_b}
    end

    test "returns only orgs the user is a member of", %{user: user, org_a: org_a, org_b: org_b} do
      slugs = user |> Orgs.list_for_user(Repo) |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == [org_a.slug, org_b.slug]
    end

    test "returns an empty list for a user with no memberships" do
      {:ok, lonely} =
        Repo.insert(User.changeset(%User{}, %{name: "Lonely", email: "lonely@example.com"}))

      assert Orgs.list_for_user(lonely, Repo) == []
    end

    test "orders by inserted_at then id (stable for pagination)", %{user: user} do
      orgs = Orgs.list_for_user(user, Repo)
      assert length(orgs) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # record_signup_attempt
  # ---------------------------------------------------------------------------

  describe "Orgs.record_signup_attempt/2" do
    test "records an allowed attempt" do
      assert {:ok, attempt} =
               Orgs.record_signup_attempt(
                 %{email: "new@example.com", decision: :allowed, provider: :google},
                 Repo
               )

      assert attempt.email == "new@example.com"
      assert attempt.decision == :allowed
      assert attempt.provider == :google
    end

    test "records a denied_cap_reached attempt with no provider" do
      assert {:ok, attempt} =
               Orgs.record_signup_attempt(
                 %{email: "denied@example.com", decision: :denied_cap_reached},
                 Repo
               )

      assert attempt.decision == :denied_cap_reached
      assert is_nil(attempt.provider)
    end

    test "returns error for missing required fields" do
      assert {:error, cs} = Orgs.record_signup_attempt(%{}, Repo)
      refute cs.valid?
    end

    test "persists request_id when provided" do
      assert {:ok, attempt} =
               Orgs.record_signup_attempt(
                 %{
                   email: "trace@example.com",
                   provider: :google,
                   decision: :allowed,
                   request_id: "req-abc-123"
                 },
                 Repo
               )

      assert attempt.request_id == "req-abc-123"
    end
  end

  # ---------------------------------------------------------------------------
  # Orgs.create_org / add_member convenience
  # ---------------------------------------------------------------------------

  describe "Orgs.create_org/2" do
    test "creates an organization" do
      assert {:ok, org} = Orgs.create_org(%{name: "New Co", slug: "new-co"}, Repo)
      assert org.id != nil
      assert org.slug == "new-co"
    end

    test "returns error for duplicate slug" do
      {:ok, _} = Orgs.create_org(%{name: "First", slug: "dup-co"}, Repo)
      assert {:error, cs} = Orgs.create_org(%{name: "Second", slug: "dup-co"}, Repo)
      assert cs.errors[:slug]
    end
  end

  describe "set_stripe_customer_id/3" do
    test "persists the Stripe customer id on the org" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-cust"}, Repo)
      assert org.stripe_customer_id == nil

      {:ok, updated} = Orgs.set_stripe_customer_id(org, "cus_abc123", Repo)
      assert updated.stripe_customer_id == "cus_abc123"
      assert Repo.reload!(org).stripe_customer_id == "cus_abc123"
    end
  end

  describe "ensure_stripe_customer_id/3" do
    test "mints and persists a customer id when the org has none" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-ensure-new"}, Repo)

      assert {:ok, "cus_minted"} =
               Orgs.ensure_stripe_customer_id(org, fn -> {:ok, "cus_minted"} end, Repo)

      assert Repo.reload!(org).stripe_customer_id == "cus_minted"
    end

    test "reuses an existing id and never calls create_fun" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-ensure-existing"}, Repo)
      {:ok, _} = Orgs.set_stripe_customer_id(org, "cus_existing", Repo)
      org = Repo.reload!(org)

      create_fun = fn -> flunk("create_fun must not be called when an id already exists") end

      assert {:ok, "cus_existing"} = Orgs.ensure_stripe_customer_id(org, create_fun, Repo)
      assert Repo.reload!(org).stripe_customer_id == "cus_existing"
    end

    test "propagates a create_fun error and persists nothing" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-ensure-err"}, Repo)

      assert {:error, :boom} =
               Orgs.ensure_stripe_customer_id(org, fn -> {:error, :boom} end, Repo)

      assert Repo.reload!(org).stripe_customer_id == nil
    end
  end

  describe "Orgs.add_member/4" do
    test "adds a member to an organization" do
      {:ok, org} = Orgs.create_org(%{name: "M Org", slug: "m-org"}, Repo)

      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "New M", email: "newm@example.com"}))

      assert {:ok, mem} = Orgs.add_member(org, user, :member, Repo)
      assert mem.role == :member
      assert mem.user_id == user.id
    end
  end

  describe "create_org_with_owner/3" do
    setup do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Ada", email: "ada@acme.test"}))

      %{user: user}
    end

    test "creates the org and makes the creator an owner", %{user: user} do
      assert {:ok, org} = Orgs.create_org_with_owner(user, %{name: "Acme Inc"}, Repo)
      assert org.name == "Acme Inc"
      assert org.slug == "acme-inc"
      assert {:ok, :owner} = Orgs.member_role(user, org, Repo)
    end

    test "derives a unique slug on collision", %{user: user} do
      {:ok, _} = Orgs.create_org(%{name: "Taken", slug: "acme-inc"}, Repo)
      assert {:ok, org} = Orgs.create_org_with_owner(user, %{name: "Acme Inc"}, Repo)
      assert org.slug != "acme-inc"
    end

    test "rejects a blank name", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = Orgs.create_org_with_owner(user, %{name: ""}, Repo)
    end
  end

  describe "member management" do
    setup do
      {:ok, org} = Orgs.create_org(%{name: "Mgmt", slug: "mgmt"}, Repo)
      {:ok, owner} = Repo.insert(User.changeset(%User{}, %{name: "O", email: "o@m.test"}))
      {:ok, bob} = Repo.insert(User.changeset(%User{}, %{name: "Bob", email: "bob@m.test"}))
      {:ok, _} = Orgs.add_member(org, owner, :owner, Repo)
      {:ok, _} = Orgs.add_member(org, bob, :member, Repo)
      %{org: org, owner: owner, bob: bob}
    end

    test "list_members returns members with their user and role", %{org: org} do
      members = Orgs.list_members(org, Repo)
      assert length(members) == 2
      assert Enum.all?(members, &(&1.user != nil))
      roles = members |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == [:member, :owner]
    end

    test "update_member_role changes a member's role", %{org: org, bob: bob} do
      assert {:ok, m} = Orgs.update_member_role(org, bob, :admin, Repo)
      assert m.role == :admin
      assert {:ok, :admin} = Orgs.member_role(bob, org, Repo)
    end

    test "remove_member deletes the membership", %{org: org, bob: bob} do
      assert :ok = Orgs.remove_member(org, bob, Repo)
      assert {:error, :not_found} = Orgs.member_role(bob, org, Repo)
    end

    test "remove_member refuses to remove the last owner", %{org: org, owner: owner} do
      assert {:error, :last_owner} = Orgs.remove_member(org, owner, Repo)
    end

    test "update_member_role refuses to demote the last owner", %{org: org, owner: owner} do
      assert {:error, :last_owner} = Orgs.update_member_role(org, owner, :admin, Repo)
    end
  end

  describe "member_role/3" do
    setup do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-role"}, Repo)

      {:ok, owner} =
        Repo.insert(User.changeset(%User{}, %{name: "Owner", email: "owner@acme.test"}))

      {:ok, member} =
        Repo.insert(User.changeset(%User{}, %{name: "Member", email: "member@acme.test"}))

      {:ok, stranger} =
        Repo.insert(User.changeset(%User{}, %{name: "Stranger", email: "stranger@acme.test"}))

      {:ok, _} = Orgs.add_member(org, owner, :owner, Repo)
      {:ok, _} = Orgs.add_member(org, member, :member, Repo)

      %{org: org, owner: owner, member: member, stranger: stranger}
    end

    test "returns the role for a member", %{org: org, owner: owner, member: member} do
      assert {:ok, :owner} = Orgs.member_role(owner, org, Repo)
      assert {:ok, :member} = Orgs.member_role(member, org, Repo)
    end

    test "returns :not_found for a non-member", %{org: org, stranger: stranger} do
      assert {:error, :not_found} = Orgs.member_role(stranger, org, Repo)
    end

    test "owner role is accepted by the OrgMember changeset", %{org: org, stranger: stranger} do
      cs =
        OrgMember.changeset(%OrgMember{}, %{
          organization_id: org.id,
          user_id: stranger.id,
          role: :owner
        })

      assert cs.valid?
    end
  end
end

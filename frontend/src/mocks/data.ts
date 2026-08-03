import type { components } from "../api/v1";
import type {
  GithubInstallationResponse,
  GithubRepoResponse,
} from "../repos/queries";
import type { ApiKey } from "../apikeys/types";

type BuildResponse = components["schemas"]["Build"];

export const mockUser = {
  uuid: "019f4c7a-9d2e-7a40-9c12-6d2b5c0bb111",
  name: "Marko Vejnovic",
  email: "marko@harmont.dev",
  personal_org_slug: "marko",
};

export const mockOrg = {
  name: "Marko Vejnovic",
  slug: "marko",
  url: null,
  created_at: "2026-01-15T09:30:00Z",
};

export const mockOrganizations = [mockOrg];

export const mockToken = "hm_mock_eyJhbGciOiJIUzI1NiJ9.mock-session-token";

type PasskeyResponse = components["schemas"]["Passkey"];

export const mockPasskeys: PasskeyResponse[] = [
  {
    uuid: "pk-001",
    nickname: "MacBook TouchID",
    created_at: "2026-03-15T10:00:00Z",
    last_used_at: "2026-05-28T08:30:00Z",
  },
  {
    uuid: "pk-002",
    nickname: "YubiKey 5",
    created_at: "2026-04-01T14:00:00Z",
    last_used_at: "2026-05-20T16:45:00Z",
  },
];

type PipelineResponse = components["schemas"]["Pipeline"];

export const mockPipelines: PipelineResponse[] = [
  {
    name: "api",
    slug: "api",
    description: "Harmont API build & test",
    repository: "harmont/harmont",
    default_branch: "main",
    allow_manual: true,
    visibility: "private",
    created_at: "2026-02-01T10:00:00Z",
  },
  {
    name: "cli",
    slug: "cli",
    description: "Harmont CLI build & test",
    repository: "harmont/harmont",
    default_branch: "main",
    allow_manual: true,
    visibility: "private",
    created_at: "2026-02-15T14:00:00Z",
  },
  {
    name: "dashboard",
    slug: "dashboard",
    description: "Solid.js SPA dashboard",
    repository: "harmont/harmont",
    default_branch: "main",
    allow_manual: true,
    visibility: "private",
    created_at: "2026-03-01T08:00:00Z",
  },
];

export const mockBuilds: Record<string, BuildResponse[]> = {
  api: [
    {
      number: 47,
      pipeline_slug: "api",
      state: "passed",
      source: "push",
      branch: "main",
      commit: "a3f9c12e8b7d4e5f6a1b2c3d4e5f6a7b8c9d0e1f",
      message: "fix: correct token expiry check",
      created_at: "2026-05-27T11:50:00Z",
      started_at: "2026-05-27T11:50:05Z",
      finished_at: "2026-05-27T11:52:19Z",
    },
    {
      number: 46,
      pipeline_slug: "api",
      state: "passed",
      source: "push",
      branch: "main",
      commit: "71b0e8d3cc914a2b3c4d5e6f7a8b9c0d1e2f3a4b",
      message: "chore: bump dependencies",
      created_at: "2026-05-27T09:30:00Z",
      started_at: "2026-05-27T09:30:03Z",
      finished_at: "2026-05-27T09:32:47Z",
    },
    {
      number: 45,
      pipeline_slug: "api",
      state: "failed",
      source: "push",
      branch: "feat/oauth",
      commit: "5b1d72e0a4f39c8d7e6f5a4b3c2d1e0f9a8b7c6d",
      message: "feat: add OAuth callback handler",
      created_at: "2026-05-26T16:20:00Z",
      started_at: "2026-05-26T16:20:02Z",
      finished_at: "2026-05-26T16:21:48Z",
    },
    {
      number: 44,
      pipeline_slug: "api",
      state: "passed",
      source: "manual",
      branch: "main",
      commit: "e09c3a2f5610d8b7c6a5f4e3d2c1b0a9f8e7d6c5",
      message: "refactor: simplify auth middleware",
      created_at: "2026-05-26T14:00:00Z",
      started_at: "2026-05-26T14:00:04Z",
      finished_at: "2026-05-26T14:02:31Z",
    },
    {
      number: 43,
      pipeline_slug: "api",
      state: "passed",
      source: "push",
      branch: "main",
      commit: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b",
      message: "test: add handler integration tests",
      created_at: "2026-05-26T10:15:00Z",
      started_at: "2026-05-26T10:15:02Z",
      finished_at: "2026-05-26T10:17:44Z",
    },
  ],
  cli: [
    {
      number: 31,
      pipeline_slug: "cli",
      state: "running",
      source: "push",
      branch: "feat/run-timeout",
      commit: "f1e2d3c4b5a6978867564534231201f0e9d8c7b6",
      message: "feat: add --timeout flag to hm run",
      created_at: "2026-05-27T12:00:00Z",
      started_at: "2026-05-27T12:00:03Z",
    },
    {
      number: 30,
      pipeline_slug: "cli",
      state: "passed",
      source: "push",
      branch: "main",
      commit: "a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0",
      message: "fix: handle missing config gracefully",
      created_at: "2026-05-26T17:45:00Z",
      started_at: "2026-05-26T17:45:02Z",
      finished_at: "2026-05-26T17:46:38Z",
    },
    {
      number: 29,
      pipeline_slug: "cli",
      state: "canceled",
      source: "push",
      branch: "feat/run-timeout",
      commit: "0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a",
      message: "wip: timeout plumbing",
      created_at: "2026-05-26T15:30:00Z",
      started_at: "2026-05-26T15:30:01Z",
      finished_at: "2026-05-26T15:30:22Z",
    },
  ],
  dashboard: [
    {
      number: 12,
      pipeline_slug: "dashboard",
      state: "passed",
      source: "push",
      branch: "main",
      commit: "deadbeefcafe1337beef0badcoffee0babe123456",
      message: "chore: update solid packages",
      created_at: "2026-05-20T16:00:00Z",
      started_at: "2026-05-20T16:00:01Z",
      finished_at: "2026-05-20T16:01:12Z",
    },
  ],
};

type JobResponse = components["schemas"]["Job"];

// Keyed by `${pipelineSlug}:${buildNumber}` — builds no longer expose an opaque
// `id`, so handlers look jobs up by pipeline + build number.
export const mockJobs: Record<string, JobResponse[]> = {
  "api:47": [
    {
      id: "j-api-001-1",
      name: "build",
      state: "passed",
      step_key: "build",
      command: "mix compile",
      started_at: "2026-05-27T11:50:05Z",
      finished_at: "2026-05-27T11:51:30Z",
      created_at: "2026-05-27T11:50:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: [],
    },
    {
      id: "j-api-001-2",
      name: "test",
      state: "passed",
      step_key: "test",
      command: "mix test",
      started_at: "2026-05-27T11:51:32Z",
      finished_at: "2026-05-27T11:52:15Z",
      created_at: "2026-05-27T11:50:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-api-001-1"],
    },
    {
      id: "j-api-001-3",
      name: "lint",
      state: "passed",
      step_key: "lint",
      command: "make lint",
      started_at: "2026-05-27T11:51:33Z",
      finished_at: "2026-05-27T11:52:19Z",
      created_at: "2026-05-27T11:50:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-api-001-1"],
    },
  ],
  "api:45": [
    {
      id: "j-api-003-1",
      name: "build",
      state: "passed",
      step_key: "build",
      command: "mix compile",
      started_at: "2026-05-26T16:20:02Z",
      finished_at: "2026-05-26T16:21:10Z",
      created_at: "2026-05-26T16:20:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: [],
    },
    {
      id: "j-api-003-2",
      name: "test",
      state: "failed",
      step_key: "test",
      command: "mix test",
      started_at: "2026-05-26T16:21:12Z",
      finished_at: "2026-05-26T16:21:48Z",
      created_at: "2026-05-26T16:20:00Z",
      exit_code: 1,
      error_code: "exit_non_zero",
      error_message: "Test suite 'harmont-api-test' failed: 2 of 34 tests failed",
      soft_failed: false,
      depends_on: ["j-api-003-1"],
    },
  ],
  "cli:31": [
    {
      id: "j-cli-001-1",
      name: "checkout",
      state: "passed",
      step_key: "checkout",
      command: "git clone --depth=1 && cd harmont",
      started_at: "2026-05-28T09:00:01Z",
      finished_at: "2026-05-28T09:00:18Z",
      created_at: "2026-05-28T09:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: [],
    },
    {
      id: "j-cli-001-2",
      name: "\u{1F427} build-linux",
      state: "passed",
      step_key: "build-linux",
      command: "cargo build --release --target x86_64-unknown-linux-gnu",
      started_at: "2026-05-28T09:00:20Z",
      finished_at: "2026-05-28T09:01:45Z",
      created_at: "2026-05-28T09:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-cli-001-1"],
    },
    {
      id: "j-cli-001-3",
      name: "\u{1F34E} build-mac",
      state: "running",
      step_key: "build-mac",
      command: "cargo build --release --target aarch64-apple-darwin",
      started_at: "2026-05-28T09:00:20Z",
      created_at: "2026-05-28T09:00:00Z",
      soft_failed: false,
      depends_on: ["j-cli-001-1"],
    },
    {
      id: "j-cli-001-4",
      name: "lint",
      state: "passed",
      step_key: "lint",
      command: "cargo clippy --all-targets -- -D warnings",
      started_at: "2026-05-28T09:00:21Z",
      finished_at: "2026-05-28T09:00:55Z",
      created_at: "2026-05-28T09:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-cli-001-1"],
    },
    {
      id: "j-cli-001-5",
      name: "integration-test",
      state: "pending",
      step_key: "integration-test",
      command: "cargo test --test integration -- --test-threads=1",
      created_at: "2026-05-28T09:00:00Z",
      soft_failed: false,
      depends_on: ["j-cli-001-2", "j-cli-001-3"],
    },
    {
      id: "j-cli-001-6",
      name: "publish",
      state: "pending",
      step_key: "publish",
      command: "cargo publish --registry harmont",
      created_at: "2026-05-28T09:00:00Z",
      soft_failed: false,
      depends_on: ["j-cli-001-5"],
    },
  ],
  "cli:30": [
    {
      id: "j-cli-002-1",
      name: "checkout",
      state: "passed",
      step_key: "checkout",
      command: "git clone --depth=1 && cd harmont",
      started_at: "2026-05-27T14:00:02Z",
      finished_at: "2026-05-27T14:00:18Z",
      created_at: "2026-05-27T14:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: [],
    },
    {
      id: "j-cli-002-2",
      name: "build",
      state: "passed",
      step_key: "build",
      command: "cargo build --release",
      started_at: "2026-05-27T14:00:20Z",
      finished_at: "2026-05-27T14:01:22Z",
      created_at: "2026-05-27T14:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-cli-002-1"],
    },
    {
      id: "j-cli-002-3",
      name: "test",
      state: "passed",
      step_key: "test",
      command: "cargo test --all",
      started_at: "2026-05-27T14:01:24Z",
      finished_at: "2026-05-27T14:02:05Z",
      created_at: "2026-05-27T14:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-cli-002-2"],
    },
    {
      id: "j-cli-002-4",
      name: "lint",
      state: "passed",
      step_key: "lint",
      command: "cargo clippy --all-targets -- -D warnings",
      started_at: "2026-05-27T14:01:24Z",
      finished_at: "2026-05-27T14:02:02Z",
      created_at: "2026-05-27T14:00:00Z",
      exit_code: 0,
      soft_failed: false,
      depends_on: ["j-cli-002-2"],
    },
  ],
};

// GitHub mock fixtures. Shapes match the spec-generated `GithubInstallation` /
// `GithubRepo` schemas. `installation_id` is GitHub's numeric id (used to key
// `mockRepos`); `id` is Harmont's internal row id (the repos' `installation_id`
// FK points at it).
export const mockInstallations: GithubInstallationResponse[] = [
  {
    id: 1,
    installation_id: 90001,
    account_login: "harmont",
    account_type: "Organization",
    created_at: "2026-05-01T00:00:00Z",
    updated_at: "2026-05-01T00:00:00Z",
  },
  {
    id: 2,
    installation_id: 90002,
    account_login: "marko-dev",
    account_type: "User",
    created_at: "2026-05-01T00:00:00Z",
    updated_at: "2026-05-01T00:00:00Z",
  },
];

const repo = (
  id: number,
  installationId: number,
  fullName: string,
  isPrivate: boolean,
  defaultBranch = "main",
): GithubRepoResponse => {
  const [owner = "", name = ""] = fullName.split("/");
  return {
    id,
    installation_id: installationId,
    gh_repo_id: 100_000 + id,
    full_name: fullName,
    name,
    owner,
    clone_url: `https://github.com/${fullName}.git`,
    default_branch: defaultBranch,
    private: isPrivate,
    last_synced_at: "2026-05-01T00:00:00Z",
  };
};

export const mockRepos: Record<number, GithubRepoResponse[]> = {
  90001: [
    repo(1, 1, "harmont/harmont", true),
    repo(2, 1, "harmont/docs", false),
    repo(3, 1, "harmont/infra", true),
  ],
  90002: [
    repo(4, 2, "marko-dev/dotfiles", false),
    repo(5, 2, "marko-dev/side-project", true, "develop"),
  ],
};

type BalanceResponse = components["schemas"]["BalanceResponse"];
type TransactionResponse = components["schemas"]["Transaction"];
type UsageResponse = components["schemas"]["UsageResponse"];

export const mockBalance: BalanceResponse = {
  balance_cents: 4250,
};

export const mockTransactions: TransactionResponse[] = [
  {
    id: "t-001",
    source: "vm_lease_debit",
    description: "api pipeline #47 — 3 jobs, 2m 14s",
    amount_cents: -18,
    created_at: "2026-05-27T11:52:19Z",
  },
  {
    id: "t-002",
    source: "vm_lease_debit",
    description: "cli pipeline #31 — 2 jobs, 1m 38s",
    amount_cents: -12,
    created_at: "2026-05-27T12:01:41Z",
  },
  {
    id: "t-003",
    source: "stripe_topup",
    description: "Stripe payment",
    amount_cents: 2500,
    created_at: "2026-05-25T09:15:00Z",
  },
  {
    id: "t-004",
    source: "coupon_redemption",
    description: "LAUNCH2026 — welcome credit",
    amount_cents: 2000,
    created_at: "2026-05-20T10:00:00Z",
  },
  {
    id: "t-005",
    source: "admin_grant",
    description: "Beta tester bonus",
    amount_cents: 500,
    created_at: "2026-05-15T14:30:00Z",
  },
];

export const mockUsage: UsageResponse = {
  cpu_seconds: 9000,
  memory_gb_seconds: 18000,
  disk_gb_seconds: 612,
  total_cents: 30,
};

type UsageSeriesBucket = components["schemas"]["UsageSeriesBucket"];

/** Deterministic per-day usage buckets for the [from, to) window. */
export function mockUsageSeries(from: Date, to: Date): UsageSeriesBucket[] {
  const out: UsageSeriesBucket[] = [];
  const day = new Date(
    Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate()),
  );
  const end = new Date(
    Date.UTC(to.getUTCFullYear(), to.getUTCMonth(), to.getUTCDate()),
  );
  let i = 0;
  while (day <= end) {
    const wave = (Math.sin(i / 3) + 1.2) * 9;
    const weekend = i % 7 >= 5 ? 0.15 : 1;
    const cents = Math.round(wave * weekend);
    out.push({
      date: day.toISOString().slice(0, 10),
      cpu_seconds: cents * 120,
      memory_gb_seconds: cents * 240,
      disk_gb_seconds: cents * 20,
      total_cents: cents,
    });
    day.setUTCDate(day.getUTCDate() + 1);
    i += 1;
  }
  return out;
}

export const mockApiKeys: ApiKey[] = [
  {
    id: "key-001",
    description: "Laptop CLI",
    created_at: "2026-04-10T09:00:00Z",
    expires_at: null,
    last_used_at: "2026-06-01T18:22:00Z",
  },
  {
    id: "key-002",
    description: "CI deploy bot",
    created_at: "2026-05-01T12:00:00Z",
    expires_at: "2026-08-01T12:00:00Z",
    last_used_at: null,
  },
];

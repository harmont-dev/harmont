defmodule HarmontApi.Controllers.CliController do
  @moduledoc """
  CLI authentication handoff: getting a session token from the browser (where
  the user is logged in) onto a locally-running `hm` CLI.

  Two complementary flows mirror Buildkite/`gh`-style device login:

  ## Loopback (transfer/claim)

  The CLI opens a local listener, generates a random `nonce`, and opens the SPA
  in the browser. The SPA — while authenticated — `POST`s the nonce to
  **`transfer`** (authed), which mints a fresh session token and parks it under
  `sha256(nonce)` for 60 seconds. Meanwhile the CLI polls **`claim`** (public)
  with the same nonce and receives the raw token. The handoff is single-use and
  short-lived; the raw token is never logged or echoed back to the browser.

  ## Paste code (code/redeem)

  When the loopback isn't available (headless box, SSH), the SPA calls
  **`code`** (authed) to mint a token and a short, human-typeable paste code
  (valid 5 minutes). The user reads the code into the CLI, which `POST`s it to
  **`redeem`** (public) to receive the token. Single-use.

  All token lifecycle lives in `Harmont.Accounts`; this controller is pure HTTP
  edge orchestration. `transfer`/`code` run behind `HarmontApi.Plugs.Auth`, so
  `conn.assigns.current_user` is the authenticated SPA user. `claim`/`redeem`
  are public — the polling/redeeming CLI has no token yet.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Repo

  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.CliClaimRequest
  alias HarmontApi.Schemas.CliCodeResponse
  alias HarmontApi.Schemas.CliRedeemRequest
  alias HarmontApi.Schemas.CliTokenResponse
  alias HarmontApi.Schemas.CliTransferRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  tags(["auth"])

  # ---------------------------------------------------------------------------
  # transfer (authed)
  # ---------------------------------------------------------------------------

  operation(:transfer,
    summary: "Hand a session token to a locally-running CLI (loopback)",
    description:
      "Mints a fresh session token for the current user and parks it under the " <>
        "CLI-supplied nonce for 60 seconds. The CLI claims it via the claim endpoint.",
    operation_id: "cliTransfer",
    security: [%{"bearer" => []}],
    request_body: {"Transfer request", "application/json", CliTransferRequest},
    responses: [
      no_content: {"Token parked for the CLI to claim", nil, nil}
    ]
  )

  @spec transfer(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def transfer(conn, params) do
    user = conn.assigns.current_user
    nonce = params["nonce"]
    now = DateTime.utc_now()

    {raw, _token} = Accounts.create_session_token(user.id, now, Repo)
    :ok = Accounts.put_cli_transfer(raw, nonce, now, Repo)

    send_resp(conn, 204, "")
  end

  # ---------------------------------------------------------------------------
  # claim (public)
  # ---------------------------------------------------------------------------

  operation(:claim,
    summary: "Claim a transferred session token (CLI loopback poll)",
    description:
      "The CLI polls with the nonce it generated; on a match within the 60s window " <>
        "it receives the raw session token (single-use).",
    operation_id: "cliClaim",
    request_body: {"Claim request", "application/json", CliClaimRequest},
    responses: [
      ok: {"The session token", "application/json", CliTokenResponse},
      bad_request: {"No token available for this nonce", "application/json", ErrorSchema}
    ]
  )

  @spec claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim(conn, params) do
    nonce = params["nonce"]
    now = DateTime.utc_now()

    case Accounts.take_cli_transfer(nonce, now, Repo) do
      {:ok, raw} -> json(conn, %{token: raw})
      {:error, :invalid} -> send_cli_code_invalid(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # code (authed)
  # ---------------------------------------------------------------------------

  operation(:code,
    summary: "Mint a human-typeable CLI paste code",
    description:
      "Mints a fresh session token for the current user and a short paste code " <>
        "(valid 5 minutes) the user re-types into the CLI to redeem it.",
    operation_id: "cliCode",
    security: [%{"bearer" => []}],
    responses: [
      ok: {"The paste code", "application/json", CliCodeResponse}
    ]
  )

  @spec code(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def code(conn, _params) do
    user = conn.assigns.current_user
    now = DateTime.utc_now()

    {raw, _token} = Accounts.create_session_token(user.id, now, Repo)
    {:ok, code} = Accounts.put_cli_paste(raw, now, Repo)

    json(conn, %{code: code})
  end

  # ---------------------------------------------------------------------------
  # redeem (public)
  # ---------------------------------------------------------------------------

  operation(:redeem,
    summary: "Redeem a CLI paste code for a session token",
    description:
      "The CLI submits the paste code the user typed in; on a match within the 5m " <>
        "window it receives the raw session token (single-use).",
    operation_id: "cliRedeem",
    request_body: {"Redeem request", "application/json", CliRedeemRequest},
    responses: [
      ok: {"The session token", "application/json", CliTokenResponse},
      bad_request: {"Invalid or expired paste code", "application/json", ErrorSchema}
    ]
  )

  @spec redeem(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem(conn, params) do
    code = params["code"]
    now = DateTime.utc_now()

    case Accounts.take_cli_paste(code, now, Repo) do
      {:ok, raw} -> json(conn, %{token: raw})
      {:error, :invalid} -> send_cli_code_invalid(conn)
    end
  end

  # A missing/expired/already-consumed CLI code is an edge condition, not a
  # domain error in the catalog, so render the envelope directly (mirrors the
  # OAuth upstream-rejection pattern from Task 3).
  defp send_cli_code_invalid(conn) do
    EndpointError.send_envelope(conn, 400,
      type: "invalid_request",
      code: "cli_code_invalid",
      message: "This CLI code is invalid, expired, or already used. Start the login again.",
      doc_url: "https://docs.harmont.dev/api/errors/cli_code_invalid"
    )
  end
end

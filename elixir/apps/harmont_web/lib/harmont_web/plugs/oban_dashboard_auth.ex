defmodule HarmontWeb.Plugs.ObanDashboardAuth do
  @moduledoc """
  HTTP Basic auth gate for the internal Oban Web dashboard (`/ops/oban`).

  The dashboard exposes job args/meta and cancel/retry controls, so access is
  mandatory and real: credentials come from `config :harmont_web, :oban_dashboard`
  (`:user` / `:password`), which prod sources from `HARMONT_OBAN_DASHBOARD_USER`
  / `HARMONT_OBAN_DASHBOARD_PASSWORD` via `runtime.exs`. The comparison is
  constant-time (over SHA-256 digests so user and password length never leak),
  and any failure halts with a 401 + `www-authenticate` challenge.

  If no credentials are configured the gate fails closed (401): an
  unconfigured dashboard must never be world-readable.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = Application.get_env(:harmont_web, :oban_dashboard, [])
    user = Keyword.get(config, :user)
    pass = Keyword.get(config, :password)

    with true <- is_binary(user) and is_binary(pass),
         ["Basic " <> encoded | _] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [req_user, req_pass] <- String.split(decoded, ":", parts: 2),
         true <- secure_equal?(req_user, user) and secure_equal?(req_pass, pass) do
      conn
    else
      _ -> reject(conn)
    end
  end

  # Constant-time compare over SHA-256 digests (same idiom as agent_socket.ex):
  # hashing first keeps the comparison length-independent so neither the
  # configured secret's length nor the presented value's length leaks via timing.
  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))
  end

  defp reject(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="ops"))
    |> send_resp(401, "")
    |> halt()
  end
end

defmodule PhoenixDiscovery.IndexNow.KeyPlug do
  @moduledoc """
  Serves the IndexNow key file at `/<key>.txt`.

  IndexNow engines fetch this URL to confirm you own the host. The body is
  the key as plain text. Every other request passes through untouched, and
  the plug does nothing when the key is `nil` or empty.

  In a Phoenix endpoint, mount it after `Plug.Static` and before the router:

      plug PhoenixDiscovery.IndexNow.KeyPlug,
        key: {System, :get_env, ["INDEXNOW_KEY"]}

  Endpoint plug options are evaluated at compile time, so pass a
  `{mod, fun, args}` tuple for a key that is only known at runtime. It is
  called on requests whose path ends in `.txt`.

  ## Options

    * `:key` (required) - a string, a `{mod, fun, args}` tuple, or `nil`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PhoenixDiscovery.IndexNow

  @impl true
  def init(opts) do
    Keyword.fetch!(opts, :key)
    opts
  end

  @impl true
  def call(%Plug.Conn{method: method, request_path: "/" <> file} = conn, opts)
      when method in ["GET", "HEAD"] do
    with true <- String.ends_with?(file, ".txt"),
         key when is_binary(key) <- IndexNow.resolve_key(opts[:key]),
         true <- file == key <> ".txt" do
      Logger.info("[IndexNow] key file served to #{user_agent(conn)}")

      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> put_resp_header("x-robots-tag", "noindex")
      |> send_resp(200, key)
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  # The header is client-controlled: strip control characters so it cannot
  # forge log lines.
  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua |> String.replace(~r/[\x00-\x1f\x7f]/, "") |> String.slice(0, 100)
      [] -> "(no user-agent)"
    end
  end
end

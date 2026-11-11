defmodule PhoenixDiscovery.IndexNow.KeyPlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias PhoenixDiscovery.IndexNow.KeyPlug

  @key "0123456789abcdef"

  defp call(path, key \\ @key, method \\ :get) do
    method
    |> conn(path)
    |> KeyPlug.call(KeyPlug.init(key: key))
  end

  describe "init/1" do
    test "requires the :key option" do
      assert_raise KeyError, fn -> KeyPlug.init([]) end
    end
  end

  describe "call/2 with a key" do
    @describetag :capture_log

    test "serves the key as plain text and halts" do
      conn = call("/#{@key}.txt")

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == @key
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
    end

    test "answers HEAD requests" do
      conn = call("/#{@key}.txt", @key, :head)
      assert conn.halted
      assert conn.status == 200
    end

    test "passes every other request through" do
      for {method, path} <- [
            get: "/",
            get: "/robots.txt",
            get: "/#{@key}",
            get: "/nested/#{@key}.txt",
            post: "/#{@key}.txt"
          ] do
        conn = call(path, @key, method)
        refute conn.halted
        assert conn.status == nil
      end
    end

    test "resolves a {mod, fun, args} key on each request" do
      conn = call("/#{@key}.txt", {Function, :identity, [@key]})
      assert conn.resp_body == @key
    end

    test "logs the fetch without control characters from the user agent" do
      log =
        capture_log(fn ->
          :get
          |> conn("/#{@key}.txt")
          |> Plug.Conn.put_req_header("user-agent", "bot\r\n[error] forged")
          |> KeyPlug.call(KeyPlug.init(key: @key))
        end)

      assert log =~ "key file served to bot[error] forged"
    end
  end

  describe "call/2 without a key" do
    test "passes the key path through" do
      for key <- [nil, ""] do
        conn = call("/#{@key}.txt", key)
        refute conn.halted
        assert conn.status == nil
      end
    end
  end
end

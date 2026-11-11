defmodule PhoenixDiscovery.IndexNowTest do
  use ExUnit.Case, async: true

  alias PhoenixDiscovery.IndexNow

  @moduletag :capture_log
  @moduletag :tmp_dir

  @now ~U[2026-03-01 12:00:00Z]
  @key "0123456789abcdef"

  @entries [
    %{path: "/", updated_at: nil},
    %{path: "/about", updated_at: nil},
    %{path: "/blog/new", updated_at: ~U[2026-02-25 08:00:00Z]},
    %{path: "/blog/naive", updated_at: ~N[2026-02-28 10:00:00]},
    %{path: "/blog/old", updated_at: ~D[2025-06-01]}
  ]

  defp opts(tmp_dir, extra \\ []) do
    Keyword.merge(
      [
        key: @key,
        base_url: "https://example.com",
        state_path: Path.join(tmp_dir, "indexnow.json"),
        now: @now,
        req_options: [plug: responding(200), retry: false]
      ],
      extra
    )
  end

  defp responding(status) do
    test_pid = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")

      send(
        test_pid,
        {:indexnow, conn.method, conn.request_path, content_type, Jason.decode!(body)}
      )

      Plug.Conn.send_resp(conn, status, "")
    end
  end

  defp read_state(tmp_dir),
    do: tmp_dir |> Path.join("indexnow.json") |> File.read!() |> Jason.decode!()

  defp write_state(tmp_dir, state),
    do: File.write!(Path.join(tmp_dir, "indexnow.json"), Jason.encode!(state))

  # The `url => lastmod` map exactly as submit_changed/2 stores it for @entries.
  defp lastmods do
    %{
      "https://example.com/" => nil,
      "https://example.com/about" => nil,
      "https://example.com/blog/new" => "2026-02-25T08:00:00Z",
      "https://example.com/blog/naive" => "2026-02-28T10:00:00",
      "https://example.com/blog/old" => "2025-06-01"
    }
  end

  describe "submit/2" do
    test "posts the IndexNow payload to the gateway", %{tmp_dir: tmp_dir} do
      urls = ["https://example.com/a", "https://example.com/b"]

      assert IndexNow.submit(urls, opts(tmp_dir)) == {:ok, 200}

      assert_received {:indexnow, "POST", "/indexnow", "application/json; charset=utf-8", payload}
      assert payload == %{"host" => "example.com", "key" => @key, "urlList" => urls}
    end

    test "treats 202 as success", %{tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, req_options: [plug: responding(202), retry: false])
      assert IndexNow.submit(["https://example.com/a"], opts) == {:ok, 202}
    end

    test "returns the status and body of a rejected request", %{tmp_dir: tmp_dir} do
      for status <- [403, 422, 429, 500] do
        opts = opts(tmp_dir, req_options: [plug: responding(status), retry: false])

        assert {:error, {:http_error, ^status, _body}} =
                 IndexNow.submit(["https://example.com/a"], opts)
      end
    end

    test "returns a transport error instead of raising", %{tmp_dir: tmp_dir} do
      plug = &Req.Test.transport_error(&1, :econnrefused)
      opts = opts(tmp_dir, req_options: [plug: plug, retry: false])

      assert {:error, {:transport, message}} = IndexNow.submit(["https://example.com/a"], opts)
      assert message =~ "connection refused"
    end

    test "splits lists over 10,000 URLs into several requests", %{tmp_dir: tmp_dir} do
      urls = for n <- 1..10_001, do: "https://example.com/p/#{n}"

      assert IndexNow.submit(urls, opts(tmp_dir)) == {:ok, 200}

      assert_received {:indexnow, _, _, _, %{"urlList" => first}}
      assert_received {:indexnow, _, _, _, %{"urlList" => second}}
      assert {length(first), length(second)} == {10_000, 1}
    end

    test "returns :no_key without a key", %{tmp_dir: tmp_dir} do
      assert IndexNow.submit(["https://example.com/a"], opts(tmp_dir, key: nil)) ==
               {:error, :no_key}

      refute_received {:indexnow, _, _, _, _}
    end

    test "resolves the key from a tuple or a function and trims it", %{tmp_dir: tmp_dir} do
      for key <- [{Function, :identity, [@key <> "\n"]}, fn -> "  " <> @key end] do
        assert {:ok, 200} = IndexNow.submit(["https://example.com/a"], opts(tmp_dir, key: key))
        assert_received {:indexnow, _, _, _, %{"key" => @key}}
      end
    end
  end

  describe "submit_changed/2 without state" do
    test "submits only entries dated within the lookback window", %{tmp_dir: tmp_dir} do
      assert IndexNow.submit_changed(@entries, opts(tmp_dir)) ==
               {:ok, %{status: 200, url_count: 2}}

      assert_received {:indexnow, _, _, _, %{"urlList" => urls}}
      assert urls == ["https://example.com/blog/new", "https://example.com/blog/naive"]

      assert read_state(tmp_dir) == %{
               "last_attempt_at" => "2026-03-01T12:00:00Z",
               "url_lastmods" => lastmods()
             }
    end

    test "honors :lookback_days", %{tmp_dir: tmp_dir} do
      assert {:ok, %{url_count: 1}} =
               IndexNow.submit_changed(@entries, opts(tmp_dir, lookback_days: 1))

      assert_received {:indexnow, _, _, _, %{"urlList" => ["https://example.com/blog/naive"]}}
    end

    test "seeds the baseline without a request when nothing is recent", %{tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, now: ~U[2027-01-01 00:00:00Z])

      assert IndexNow.submit_changed(@entries, opts) == {:ok, :no_changes}
      refute_received {:indexnow, _, _, _, _}

      assert read_state(tmp_dir) == %{"last_attempt_at" => nil, "url_lastmods" => lastmods()}
    end

    test "with fallback: false submits nothing and writes nothing", %{tmp_dir: tmp_dir} do
      assert IndexNow.submit_changed(@entries, opts(tmp_dir, fallback: false)) ==
               {:ok, :no_changes}

      refute_received {:indexnow, _, _, _, _}
      refute File.exists?(Path.join(tmp_dir, "indexnow.json"))
    end

    test "a failed submission seeds the baseline minus the failed URLs", %{tmp_dir: tmp_dir} do
      opts = opts(tmp_dir, req_options: [plug: responding(500), retry: false])

      assert {:error, {:http_error, 500, _}} = IndexNow.submit_changed(@entries, opts)

      assert read_state(tmp_dir) == %{
               "last_attempt_at" => "2026-03-01T12:00:00Z",
               "url_lastmods" =>
                 Map.drop(lastmods(), [
                   "https://example.com/blog/new",
                   "https://example.com/blog/naive"
                 ])
             }
    end

    test "treats an unreadable state file as no state", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "indexnow.json"), "not json")

      assert {:ok, %{url_count: 2}} = IndexNow.submit_changed(@entries, opts(tmp_dir))
    end

    test "defaults the state file to the system temp dir, named by host", %{tmp_dir: tmp_dir} do
      host = "t#{System.unique_integer([:positive])}.example.com"
      path = Path.join(System.tmp_dir!(), "phoenix_discovery_indexnow_#{host}.json")
      on_exit(fn -> File.rm(path) end)

      opts =
        tmp_dir
        |> opts(base_url: "https://" <> host)
        |> Keyword.delete(:state_path)

      assert {:ok, _} = IndexNow.submit_changed([%{path: "/", updated_at: @now}], opts)
      assert File.exists?(path)
    end
  end

  describe "submit_changed/2 with state" do
    test "submits only new URLs and URLs whose lastmod moved, in entry order",
         %{tmp_dir: tmp_dir} do
      write_state(tmp_dir, %{"last_attempt_at" => nil, "url_lastmods" => lastmods()})

      entries =
        @entries
        |> List.replace_at(4, %{path: "/blog/old", updated_at: ~D[2026-01-02]})
        |> Kernel.++([%{path: "/contact", updated_at: nil}])

      assert {:ok, %{status: 200, url_count: 2}} = IndexNow.submit_changed(entries, opts(tmp_dir))

      assert_received {:indexnow, _, _, _, %{"urlList" => urls}}
      assert urls == ["https://example.com/blog/old", "https://example.com/contact"]

      assert read_state(tmp_dir)["url_lastmods"]["https://example.com/blog/old"] == "2026-01-02"
    end

    test "makes no request when nothing changed", %{tmp_dir: tmp_dir} do
      write_state(tmp_dir, %{"last_attempt_at" => nil, "url_lastmods" => lastmods()})

      assert IndexNow.submit_changed(@entries, opts(tmp_dir)) == {:ok, :no_changes}
      refute_received {:indexnow, _, _, _, _}
    end

    test "a second run after a success has nothing to submit", %{tmp_dir: tmp_dir} do
      assert {:ok, %{url_count: 2}} = IndexNow.submit_changed(@entries, opts(tmp_dir))
      assert IndexNow.submit_changed(@entries, opts(tmp_dir)) == {:ok, :no_changes}
    end

    test "a failed submission keeps the previous map so the URLs retry", %{tmp_dir: tmp_dir} do
      stale = Map.put(lastmods(), "https://example.com/blog/old", "1999-01-01")
      write_state(tmp_dir, %{"last_attempt_at" => nil, "url_lastmods" => stale})
      failing = opts(tmp_dir, req_options: [plug: responding(503), retry: false])

      assert {:error, {:http_error, 503, _}} = IndexNow.submit_changed(@entries, failing)

      assert read_state(tmp_dir) == %{
               "last_attempt_at" => "2026-03-01T12:00:00Z",
               "url_lastmods" => stale
             }

      assert {:ok, %{url_count: 1}} = IndexNow.submit_changed(@entries, opts(tmp_dir))
      assert_received {:indexnow, _, _, _, %{"urlList" => ["https://example.com/blog/old"]}}
    end

    test "force: true submits every entry", %{tmp_dir: tmp_dir} do
      write_state(tmp_dir, %{"last_attempt_at" => nil, "url_lastmods" => lastmods()})

      assert {:ok, %{url_count: 5}} =
               IndexNow.submit_changed(@entries, opts(tmp_dir, force: true))

      assert_received {:indexnow, _, _, _, %{"urlList" => urls}}
      assert length(urls) == 5
    end
  end

  describe "submit_changed/2 without a key" do
    test "skips without a request or a state file", %{tmp_dir: tmp_dir} do
      for key <- [nil, "", "  \n"] do
        assert IndexNow.submit_changed(@entries, opts(tmp_dir, key: key)) == {:ok, :skipped}
      end

      refute_received {:indexnow, _, _, _, _}
      refute File.exists?(Path.join(tmp_dir, "indexnow.json"))
    end
  end

  describe "last_attempt_at/1" do
    test "is nil without a state file", %{tmp_dir: tmp_dir} do
      assert IndexNow.last_attempt_at(opts(tmp_dir)) == nil
    end

    test "returns the time of the last attempt", %{tmp_dir: tmp_dir} do
      {:ok, _} = IndexNow.submit_changed(@entries, opts(tmp_dir))
      assert IndexNow.last_attempt_at(opts(tmp_dir)) == @now
    end

    test "is nil when the state file has no attempt recorded", %{tmp_dir: tmp_dir} do
      write_state(tmp_dir, %{"last_attempt_at" => nil, "url_lastmods" => lastmods()})
      assert IndexNow.last_attempt_at(opts(tmp_dir)) == nil
    end
  end
end

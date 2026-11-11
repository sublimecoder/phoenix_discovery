defmodule PhoenixDiscovery.IndexNow.PingerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixDiscovery.IndexNow.Pinger

  @moduletag :capture_log
  @moduletag :tmp_dir

  @now ~U[2026-03-01 12:00:00Z]
  @hour 3_600_000

  @entries [
    %{path: "/", updated_at: nil},
    %{path: "/blog/new", updated_at: ~U[2026-02-25 08:00:00Z]},
    %{path: "/blog/old", updated_at: ~D[2025-06-01]}
  ]

  @lastmods %{
    "https://example.com/" => nil,
    "https://example.com/blog/new" => "2026-02-25T08:00:00Z",
    "https://example.com/blog/old" => "2025-06-01"
  }

  # Timers are an hour out, so a test drives the pinger by sending :fire or
  # :rescan itself; :sys.get_state/1 then waits until that message is handled.
  defp start_pinger(tmp_dir, extra \\ []) do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:indexnow, Jason.decode!(body)["urlList"]})
      Plug.Conn.send_resp(conn, 200, "")
    end

    opts =
      Keyword.merge(
        [
          name: nil,
          key: "0123456789abcdef",
          base_url: "https://example.com",
          entries: fn -> @entries end,
          state_path: state_path(tmp_dir),
          clock: fn -> @now end,
          delay_ms: @hour,
          rescan_interval_ms: @hour,
          req_options: [plug: plug, retry: false]
        ],
        extra
      )

    start_supervised!({Pinger, opts})
  end

  defp run(pid, message) do
    send(pid, message)
    :sys.get_state(pid)
  end

  defp state_path(tmp_dir), do: Path.join(tmp_dir, "indexnow.json")

  defp write_state(tmp_dir, last_attempt_at, lastmods) do
    json = Jason.encode!(%{"last_attempt_at" => last_attempt_at, "url_lastmods" => lastmods})
    File.write!(state_path(tmp_dir), json)
  end

  describe "boot submission" do
    test "fires after :delay_ms", %{tmp_dir: tmp_dir} do
      start_pinger(tmp_dir, delay_ms: 0)
      assert_receive {:indexnow, ["https://example.com/blog/new"]}
    end

    test "without state, submits the lookback window", %{tmp_dir: tmp_dir} do
      tmp_dir |> start_pinger() |> run(:fire)

      assert_received {:indexnow, ["https://example.com/blog/new"]}
      assert File.exists?(state_path(tmp_dir))
    end

    test "is skipped within the cooldown", %{tmp_dir: tmp_dir} do
      stale = Map.put(@lastmods, "https://example.com/blog/old", "1999-01-01")
      write_state(tmp_dir, "2026-03-01T11:59:00Z", stale)

      tmp_dir |> start_pinger() |> run(:fire)

      refute_received {:indexnow, _}
    end

    test "submits the diff once the cooldown has passed", %{tmp_dir: tmp_dir} do
      stale = Map.put(@lastmods, "https://example.com/blog/old", "1999-01-01")
      write_state(tmp_dir, "2026-02-27T12:00:00Z", stale)

      tmp_dir |> start_pinger() |> run(:fire)

      assert_received {:indexnow, ["https://example.com/blog/old"]}
    end

    test "honors :cooldown_seconds", %{tmp_dir: tmp_dir} do
      stale = Map.put(@lastmods, "https://example.com/blog/old", "1999-01-01")
      write_state(tmp_dir, "2026-03-01T11:59:00Z", stale)

      tmp_dir |> start_pinger(cooldown_seconds: 30) |> run(:fire)

      assert_received {:indexnow, ["https://example.com/blog/old"]}
    end

    test "schedules the first rescan", %{tmp_dir: tmp_dir} do
      %{timer: timer} = tmp_dir |> start_pinger() |> run(:fire)

      assert is_integer(Process.read_timer(timer))
    end
  end

  describe "rescan" do
    test "without state, makes no request and writes nothing", %{tmp_dir: tmp_dir} do
      tmp_dir |> start_pinger() |> run(:rescan)

      refute_received {:indexnow, _}
      refute File.exists?(state_path(tmp_dir))
    end

    test "submits a change even inside the boot cooldown", %{tmp_dir: tmp_dir} do
      stale = Map.put(@lastmods, "https://example.com/blog/old", "1999-01-01")
      write_state(tmp_dir, "2026-03-01T11:59:59Z", stale)

      tmp_dir |> start_pinger() |> run(:rescan)

      assert_received {:indexnow, ["https://example.com/blog/old"]}
    end

    test "calls :entries on every run", %{tmp_dir: tmp_dir} do
      write_state(tmp_dir, nil, @lastmods)
      {:ok, agent} = start_supervised({Agent, fn -> @entries end})
      pid = start_pinger(tmp_dir, entries: fn -> Agent.get(agent, & &1) end)

      run(pid, :rescan)
      refute_received {:indexnow, _}

      Agent.update(agent, &(&1 ++ [%{path: "/blog/scheduled", updated_at: @now}]))
      run(pid, :rescan)
      assert_received {:indexnow, ["https://example.com/blog/scheduled"]}
    end

    test "keeps one timer armed", %{tmp_dir: tmp_dir} do
      pid = start_pinger(tmp_dir)
      %{timer: first} = run(pid, :rescan)
      %{timer: second} = run(pid, :rescan)

      assert Process.read_timer(first) == false
      assert is_integer(Process.read_timer(second))
    end
  end

  describe "failures" do
    test "an :entries function that raises is logged and the process stays up",
         %{tmp_dir: tmp_dir} do
      pid = start_pinger(tmp_dir, entries: fn -> raise "content store down" end)

      log = capture_log(fn -> run(pid, :rescan) end)

      assert log =~ "content store down"
      assert %{timer: _} = :sys.get_state(pid)
    end

    test "start fails when :entries is not a zero-arity function", %{tmp_dir: tmp_dir} do
      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(
                 {Pinger,
                  name: nil,
                  key: "k",
                  base_url: "https://example.com",
                  entries: @entries,
                  state_path: state_path(tmp_dir)}
               )

      assert message =~ ":entries must be a zero-arity function"
    end

    test "start fails without :base_url" do
      assert {:error, {{%KeyError{key: :base_url}, _stack}, _child}} =
               start_supervised({Pinger, name: nil, key: "k", entries: fn -> [] end})
    end
  end

  describe "start_link/1" do
    test "registers the process under :name", %{tmp_dir: tmp_dir} do
      pid = start_pinger(tmp_dir, name: Pinger)
      assert Process.whereis(Pinger) == pid
    end
  end
end

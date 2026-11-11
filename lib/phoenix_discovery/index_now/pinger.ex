defmodule PhoenixDiscovery.IndexNow.Pinger do
  @moduledoc """
  A GenServer that submits changed URLs shortly after boot and then
  rescans on a fixed interval.

  Add it to your application's supervision tree, after your endpoint:

      children = [
        MyAppWeb.Endpoint,
        {PhoenixDiscovery.IndexNow.Pinger,
         key: System.get_env("INDEXNOW_KEY"),
         base_url: "https://example.com",
         entries: &MyApp.Sitemap.entries/0,
         state_path: "/data/indexnow.json"}
      ]

  Start it only in production. With no key it logs and submits nothing.

  ## Boot submission

  `:delay_ms` after start (default 30 seconds, so a rolling deploy has
  moved traffic to the new release), it calls
  `PhoenixDiscovery.IndexNow.submit_changed/2`. The boot submission is
  skipped if the state file records an attempt within `:cooldown_seconds`
  (default 24 hours). That bounds the cost of hosts that start and stop
  machines on demand: each cold start would otherwise submit again.

  ## Rescan

  Every `:rescan_interval_ms` (default 6 hours) it calls `submit_changed/2`
  with `fallback: false`. A rescan makes a request only when a URL changed
  against the saved state, and submits nothing when there is no state, so
  it ignores the cooldown. This picks up changes that happen without a
  deploy, such as a post with a future publish date going live.

  ## Options

    * `:entries` (required) - zero-arity function returning the current
      list of `%{path, updated_at}` entries. Called on every run.
    * `:key`, `:base_url` (required) and any other option accepted by
      `PhoenixDiscovery.IndexNow.submit_changed/2`.
    * `:delay_ms` - delay before the boot submission. Default `30_000`.
    * `:cooldown_seconds` - minimum gap between boot submissions. Default `86_400`.
    * `:rescan_interval_ms` - time between rescans. Default `21_600_000`.
    * `:clock` - zero-arity function returning the current `DateTime`.
      Default `&DateTime.utc_now/0`.
    * `:name` - process name. Default `PhoenixDiscovery.IndexNow.Pinger`;
      `nil` starts it unnamed.
  """

  use GenServer

  require Logger

  alias PhoenixDiscovery.IndexNow

  @defaults [
    delay_ms: 30_000,
    cooldown_seconds: 86_400,
    rescan_interval_ms: 21_600_000,
    clock: &DateTime.utc_now/0
  ]

  @doc "Starts the pinger. See the module docs for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    unless is_function(opts[:entries], 0) do
      raise ArgumentError,
            ":entries must be a zero-arity function, got: #{inspect(opts[:entries])}"
    end

    Keyword.fetch!(opts, :key)
    Keyword.fetch!(opts, :base_url)

    {:ok, %{opts: opts, timer: Process.send_after(self(), :fire, opts[:delay_ms])}}
  end

  @impl true
  def handle_info(:fire, %{opts: opts} = state) do
    now = opts[:clock].()
    last = IndexNow.last_attempt_at(opts)
    age = last && DateTime.diff(now, last)

    if age && age < opts[:cooldown_seconds] do
      Logger.info("[IndexNow] boot submission skipped, last attempt #{age}s ago")
    else
      run(opts, now, [])
    end

    {:noreply, schedule_rescan(state)}
  end

  def handle_info(:rescan, %{opts: opts} = state) do
    run(opts, opts[:clock].(), fallback: false)
    {:noreply, schedule_rescan(state)}
  end

  defp schedule_rescan(%{opts: opts, timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :rescan, opts[:rescan_interval_ms])}
  end

  # The entries callback is application code. A crash there must not
  # restart this process in a loop and take the supervisor down with it.
  defp run(opts, now, extra) do
    entries = opts[:entries].()
    IndexNow.submit_changed(entries, opts |> Keyword.merge(extra) |> Keyword.put(:now, now))
  rescue
    exception ->
      Logger.error(
        "[IndexNow] run failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, exception}
  end
end

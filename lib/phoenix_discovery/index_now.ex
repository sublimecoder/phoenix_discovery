defmodule PhoenixDiscovery.IndexNow do
  @moduledoc """
  Submits URLs to [IndexNow](https://www.indexnow.org/documentation), the
  push protocol used by Bing, Yandex, Seznam, Naver, Yep and others.

  Requests go to the shared gateway at `https://api.indexnow.org/indexnow`,
  which forwards each submission to every participating engine.

  ## Changed-only submission

  `submit_changed/2` takes your full list of entries (the same
  `%{path, updated_at}` maps you render into `sitemap.xml`) and submits only
  the URLs that are new or whose `updated_at` moved since the last
  successful submission. The `url => lastmod` map from that submission is
  kept as JSON in a state file. When nothing changed, no request is made.

  With no state file at all (first boot, or a host whose disk is wiped on
  restart), it submits only entries dated within the last `:lookback_days`
  (default 14). Entries with `updated_at: nil` are never part of that
  fallback, so undated pages are not resubmitted on every cold start. They
  are still submitted when they first appear in a later diff.

  ## Key verification

  IndexNow checks ownership by fetching `https://<host>/<key>.txt`, which
  must return the key as plain text. `PhoenixDiscovery.IndexNow.KeyPlug`
  serves that file. The payload never sends `keyLocation`, so engines look
  at that default location.

  Bing also requires the site to be verified in Bing Webmaster Tools.
  Without that, submissions are rejected with 403 even when the key file
  is correct.

  ## Common options

    * `:key` (required) - the IndexNow key. A string, a `{mod, fun, args}`
      tuple or a zero-arity function. Surrounding whitespace is trimmed.
    * `:base_url` (required) - for example `"https://example.com"`. A string,
      tuple or function, like `:key`. The submitted `host` comes from it.
    * `:endpoint` - submission URL. Defaults to `"https://api.indexnow.org/indexnow"`.
    * `:req_options` - extra options merged into the `Req.request/1` call.
      Pass `plug: ...` here to stub HTTP in tests.
  """

  require Logger

  @endpoint "https://api.indexnow.org/indexnow"
  @lookback_days 14
  @max_urls_per_request 10_000

  @type submit_result ::
          {:ok, %{status: pos_integer(), url_count: pos_integer()}}
          | {:ok, :no_changes}
          | {:ok, :skipped}
          | {:error, term()}

  @doc """
  Submits a list of absolute URLs. All URLs must be on the `:base_url` host.

  Lists over 10,000 URLs (the protocol limit per request) are sent in
  several requests, stopping at the first failure.

  Returns `{:ok, status}` for a 200 or 202 response. Otherwise returns
  `{:error, :no_key}`, `{:error, {:http_error, status, body}}` or
  `{:error, {:transport, message}}`. It never raises on HTTP failures.
  Common statuses: 403 means the key file could not be verified or the
  site is not verified with the engine, 422 means a URL does not match the
  host, 429 means too many requests.

  Takes the common options listed in the module docs.
  """
  @spec submit([String.t(), ...], keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def submit([_ | _] = urls, opts) do
    host = opts |> base_url!() |> URI.parse() |> Map.fetch!(:host)

    case resolve_key(Keyword.get(opts, :key)) do
      nil ->
        {:error, :no_key}

      key ->
        urls
        |> Enum.chunk_every(@max_urls_per_request)
        |> Enum.reduce_while(nil, fn chunk, _acc ->
          case post(%{"host" => host, "key" => key, "urlList" => chunk}, opts) do
            {:ok, _status} = ok -> {:cont, ok}
            error -> {:halt, error}
          end
        end)
        |> tap(&log_submit(&1, length(urls)))
    end
  end

  @doc """
  Submits the entries that changed since the last successful submission.

  `entries` is the full current list of `%{path, updated_at}` maps. See the
  module docs for how changes are detected.

  Returns:

    * `{:ok, %{status: status, url_count: count}}` after a successful submission
    * `{:ok, :no_changes}` when nothing changed (no request is made)
    * `{:ok, :skipped}` when no key is configured
    * `{:error, reason}` as in `submit/2`

  ## Options

  The common options from the module docs, plus:

    * `:state_path` - where the state file lives. Defaults to
      `System.tmp_dir!()/phoenix_discovery_indexnow_<host>.json`. Point it at
      persistent disk if you have one.
    * `:lookback_days` - window for the stateless fallback. Default 14.
    * `:fallback` - set to `false` to submit nothing when there is no state
      file, instead of the lookback window. Default `true`.
    * `:force` - set to `true` to submit every entry regardless of state.
      Default `false`.
    * `:now` - the current time as a `DateTime`. Defaults to
      `DateTime.utc_now/0`. Used for the lookback window and the recorded
      attempt time.

  Every attempted submission records its time in the state file, which is
  what `PhoenixDiscovery.IndexNow.Pinger` uses for its boot cooldown. A
  failed submission keeps the previous `url => lastmod` map, so the failed
  URLs are retried on the next run.
  """
  @spec submit_changed([PhoenixDiscovery.entry()], keyword()) :: submit_result()
  def submit_changed(entries, opts) when is_list(entries) do
    base_url = base_url!(opts)

    case resolve_key(Keyword.get(opts, :key)) do
      nil ->
        Logger.info("[IndexNow] no key configured, skipping submission")
        {:ok, :skipped}

      _key ->
        do_submit_changed(entries, base_url, opts)
    end
  end

  defp do_submit_changed(entries, base_url, opts) do
    force? = Keyword.get(opts, :force, false)
    fallback? = Keyword.get(opts, :fallback, true)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    path = state_path(opts, base_url)

    state = read_state(path)
    previous = previous_lastmods(state)

    current =
      entries
      |> Enum.map(fn %{path: p, updated_at: at} -> {PhoenixDiscovery.url(base_url, p), at} end)
      |> Enum.uniq_by(&elem(&1, 0))

    current_lastmods = Map.new(current, fn {url, at} -> {url, serialize(at)} end)

    urls =
      cond do
        force? ->
          Enum.map(current, &elem(&1, 0))

        previous ->
          for {url, _at} <- current,
              Map.get(previous, url, :missing) != current_lastmods[url],
              do: url

        fallback? ->
          cutoff =
            Date.add(DateTime.to_date(now), -Keyword.get(opts, :lookback_days, @lookback_days))

          for {url, at} <- current, recent?(at, cutoff), do: url

        true ->
          []
      end

    # Only a run that may use the fallback seeds a baseline when there is no
    # state, so a later rescan has something to diff against.
    seed? = fallback? and not force? and is_nil(previous)

    if urls == [] do
      Logger.debug("[IndexNow] no URLs changed since the last submission")
      if seed?, do: write_state(path, last_attempt(state), current_lastmods)
      {:ok, :no_changes}
    else
      case submit(urls, Keyword.put(opts, :base_url, base_url)) do
        {:ok, status} ->
          write_state(path, now, current_lastmods)
          {:ok, %{status: status, url_count: length(urls)}}

        {:error, _reason} = error ->
          kept = previous || if(seed?, do: Map.drop(current_lastmods, urls))
          write_state(path, now, kept)
          error
      end
    end
  end

  @doc """
  Time of the last recorded submission attempt, or `nil` if there is none.

  Takes `:base_url` and `:state_path` as in `submit_changed/2`.
  """
  @spec last_attempt_at(keyword()) :: DateTime.t() | nil
  def last_attempt_at(opts) do
    base_url = base_url!(opts)

    with %{"last_attempt_at" => at} when is_binary(at) <- read_state(state_path(opts, base_url)),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
      datetime
    else
      _ -> nil
    end
  end

  @doc false
  @spec resolve_key(term()) :: String.t() | nil
  def resolve_key(value) do
    case PhoenixDiscovery.resolve(value) do
      key when is_binary(key) ->
        case String.trim(key) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp post(payload, opts) do
    [
      method: :post,
      url: Keyword.get(opts, :endpoint, @endpoint),
      json: payload,
      headers: [{"content-type", "application/json; charset=utf-8"}],
      receive_timeout: 10_000,
      retry: :transient,
      max_retries: 2
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status}} when status in [200, 202] -> {:ok, status}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp log_submit({:ok, status}, count),
    do: Logger.info("[IndexNow] submitted #{count} URL(s), status #{status}")

  defp log_submit({:error, reason}, count),
    do: Logger.warning("[IndexNow] submitting #{count} URL(s) failed: #{inspect(reason)}")

  defp base_url!(opts), do: opts |> Keyword.fetch!(:base_url) |> PhoenixDiscovery.resolve()

  defp state_path(opts, base_url) do
    Keyword.get_lazy(opts, :state_path, fn ->
      host = URI.parse(base_url).host
      Path.join(System.tmp_dir!(), "phoenix_discovery_indexnow_#{host}.json")
    end)
  end

  defp serialize(nil), do: nil
  defp serialize(%mod{} = at) when mod in [Date, DateTime, NaiveDateTime], do: mod.to_iso8601(at)

  defp recent?(nil, _cutoff), do: false
  defp recent?(at, cutoff), do: Date.compare(PhoenixDiscovery.to_date(at), cutoff) != :lt

  defp previous_lastmods(%{"url_lastmods" => %{} = lastmods}) when map_size(lastmods) > 0,
    do: lastmods

  defp previous_lastmods(_state), do: nil

  defp last_attempt(%{"last_attempt_at" => at}) when is_binary(at), do: at
  defp last_attempt(_state), do: nil

  defp read_state(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = state} <- Jason.decode(json) do
      state
    else
      _ -> nil
    end
  end

  defp write_state(path, last_attempt_at, url_lastmods) do
    json =
      Jason.encode!(%{
        "last_attempt_at" => encode_time(last_attempt_at),
        "url_lastmods" => url_lastmods
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[IndexNow] could not write state to #{path}: #{inspect(reason)}. " <>
            "The next run cannot diff against this one."
        )
    end
  end

  defp encode_time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encode_time(at), do: at
end

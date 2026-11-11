defmodule PhoenixDiscovery do
  @moduledoc """
  Search and AI discovery plumbing for Plug and Phoenix apps.

    * `PhoenixDiscovery.IndexNow` submits changed URLs to IndexNow.
    * `PhoenixDiscovery.IndexNow.KeyPlug` serves the IndexNow key file.
    * `PhoenixDiscovery.IndexNow.Pinger` submits on boot and rescans on a timer.
    * `PhoenixDiscovery.Sitemap` renders `sitemap.xml`.
    * `PhoenixDiscovery.LlmsTxt` renders `llms.txt` and `llms-full.txt`.
    * `PhoenixDiscovery.JsonLd` builds schema.org JSON-LD nodes linked by `@id`.

  Every module takes the site's base URL (for example `"https://example.com"`)
  as an argument or option. Nothing reads application config.

  The sitemap and IndexNow share one entry shape, so a single function in
  your app can feed both:

      %{path: "/blog/hello-world", updated_at: ~U[2026-01-15 09:00:00Z]}
      %{path: "/about", updated_at: nil}

  `updated_at` is a `DateTime`, `NaiveDateTime`, `Date`, or `nil`. Use `nil`
  for pages that have no real change date.
  """

  @typedoc "A sitemap or IndexNow entry. Extra keys are ignored."
  @type entry :: %{
          required(:path) => String.t(),
          required(:updated_at) => DateTime.t() | NaiveDateTime.t() | Date.t() | nil,
          optional(any()) => any()
        }

  @doc """
  Joins a base URL and a path. Absolute `http://` and `https://` URLs pass
  through unchanged.

      iex> PhoenixDiscovery.url("https://example.com", "/about")
      "https://example.com/about"

      iex> PhoenixDiscovery.url("https://example.com/", "/")
      "https://example.com/"

      iex> PhoenixDiscovery.url("https://example.com", "https://cdn.example.com/a.png")
      "https://cdn.example.com/a.png"
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url(_base_url, "http://" <> _ = absolute), do: absolute
  def url(_base_url, "https://" <> _ = absolute), do: absolute
  def url(base_url, "/" <> _ = path), do: String.trim_trailing(base_url, "/") <> path

  @doc false
  def to_date(%Date{} = date), do: date
  def to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  def to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)

  # Options that may be given as a value, a `{mod, fun, args}` tuple (usable
  # in compile-time plug options) or a zero-arity function.
  @doc false
  def resolve({mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args),
    do: apply(mod, fun, args)

  def resolve(fun) when is_function(fun, 0), do: fun.()
  def resolve(value), do: value
end

defmodule PhoenixDiscovery.Sitemap do
  @moduledoc """
  Renders a `sitemap.xml` document from `%{path, updated_at}` entries.

  An entry with a date gets a `<lastmod>`. An entry with `updated_at: nil`
  gets none. Google ignores `<lastmod>` across a site once it finds the
  values unreliable, so a page without a real change date should carry no
  date rather than, say, the time of the last deploy.

  `<changefreq>` and `<priority>` are not emitted. Google ignores both.
  """

  @max_urls 50_000

  @doc """
  Renders the sitemap as a string.

  Raises `ArgumentError` for more than 50,000 entries, the protocol limit
  for one file.

      iex> PhoenixDiscovery.Sitemap.render("https://example.com", [
      ...>   %{path: "/", updated_at: nil},
      ...>   %{path: "/blog/hello", updated_at: ~D[2026-01-15]}
      ...> ])
      ~s(<?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url>
          <loc>https://example.com/</loc>
        </url>
        <url>
          <loc>https://example.com/blog/hello</loc>
          <lastmod>2026-01-15</lastmod>
        </url>
      </urlset>
      )
  """
  @spec render(String.t(), [PhoenixDiscovery.entry()]) :: String.t()
  def render(base_url, entries) when is_list(entries) do
    if length(entries) > @max_urls do
      raise ArgumentError,
            "a sitemap holds at most #{@max_urls} URLs, got #{length(entries)}; split it with a sitemap index"
    end

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      Enum.map(entries, &url_xml(base_url, &1)),
      "</urlset>\n"
    ])
  end

  defp url_xml(base_url, %{path: "/" <> _ = path, updated_at: updated_at}) do
    [
      "  <url>\n    <loc>",
      Plug.HTML.html_escape(PhoenixDiscovery.url(base_url, path)),
      "</loc>\n",
      lastmod_xml(updated_at),
      "  </url>\n"
    ]
  end

  defp lastmod_xml(nil), do: []

  defp lastmod_xml(updated_at),
    do: ["    <lastmod>", Date.to_iso8601(PhoenixDiscovery.to_date(updated_at)), "</lastmod>\n"]
end

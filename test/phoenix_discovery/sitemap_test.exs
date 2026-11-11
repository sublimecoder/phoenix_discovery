defmodule PhoenixDiscovery.SitemapTest do
  use ExUnit.Case, async: true

  alias PhoenixDiscovery.Sitemap

  doctest Sitemap

  describe "render/2" do
    test "writes the date part of DateTime and NaiveDateTime values" do
      xml =
        Sitemap.render("https://example.com", [
          %{path: "/a", updated_at: ~U[2026-01-15 23:30:00Z]},
          %{path: "/b", updated_at: ~N[2026-02-01 08:00:00]}
        ])

      assert xml =~ "<loc>https://example.com/a</loc>\n    <lastmod>2026-01-15</lastmod>"
      assert xml =~ "<loc>https://example.com/b</loc>\n    <lastmod>2026-02-01</lastmod>"
    end

    test "escapes XML special characters in URLs" do
      xml = Sitemap.render("https://example.com", [%{path: "/search?q=a&b=<c>", updated_at: nil}])

      assert xml =~ "<loc>https://example.com/search?q=a&amp;b=&lt;c&gt;</loc>"
    end

    test "ignores extra keys, so structs and richer maps can be passed in" do
      xml = Sitemap.render("https://example.com/", [%{path: "/a", updated_at: nil, title: "A"}])

      assert xml =~ "<loc>https://example.com/a</loc>"
      refute xml =~ "title"
    end

    test "renders an empty urlset" do
      assert Sitemap.render("https://example.com", []) ==
               ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
                 ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n</urlset>\n)
    end

    test "rejects more than 50,000 entries" do
      entries = List.duplicate(%{path: "/", updated_at: nil}, 50_001)

      assert_raise ArgumentError, ~r/at most 50000 URLs/, fn ->
        Sitemap.render("https://example.com", entries)
      end
    end

    test "rejects entries whose path is not root-relative" do
      assert_raise FunctionClauseError, fn ->
        Sitemap.render("https://example.com", [
          %{path: "https://other.example/x", updated_at: nil}
        ])
      end
    end
  end
end

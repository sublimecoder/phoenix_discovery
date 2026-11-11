# PhoenixDiscovery

Search and AI discovery plumbing for Plug and Phoenix apps:

- **IndexNow**: a plug that serves the key file, a function that submits only the URLs that changed, and a GenServer that runs it on boot and on a timer.
- **sitemap.xml**: rendered from a list of `%{path, updated_at}` entries, with `<lastmod>` only where you have a real date.
- **llms.txt** and **llms-full.txt**: rendered from plain maps.
- **JSON-LD**: schema.org builders for `WebSite`, `Organization`, `Person`, `BlogPosting`, `BreadcrumbList`, `FAQPage` and `CollectionPage`, linked by `@id`.

It depends on `plug`, `jason` and `req`. It does not depend on Phoenix and reads no application config: everything is a function argument.

## Installation

Not on Hex yet. Add it as a git dependency:

```elixir
def deps do
  [
    {:phoenix_discovery, github: "sublimecoder/phoenix_discovery"}
  ]
end
```

## One entry list for the sitemap and IndexNow

Both features read the same shape. Write one function in your app that returns every public URL:

```elixir
defmodule MyApp.Discovery do
  def entries do
    pages = Enum.map(["/", "/about", "/blog"], &%{path: &1, updated_at: nil})

    posts =
      for post <- MyApp.Blog.published_posts() do
        %{path: "/blog/#{post.slug}", updated_at: post.updated_at}
      end

    pages ++ posts
  end
end
```

`updated_at` is a `DateTime`, `NaiveDateTime`, `Date` or `nil`. Use `nil` when a page has no real change date. Do not stamp static pages with the deploy time: Google uses `<lastmod>` only when it is consistently accurate, so wrong dates on some pages can cost you the dates on all of them.

## sitemap.xml

```elixir
# router.ex
get "/sitemap.xml", DiscoveryController, :sitemap

# discovery_controller.ex
def sitemap(conn, _params) do
  xml = PhoenixDiscovery.Sitemap.render(MyAppWeb.Endpoint.url(), MyApp.Discovery.entries())

  conn
  |> put_resp_content_type("application/xml")
  |> send_resp(200, xml)
end
```

URLs are XML-escaped. `<lastmod>` is written as a date (`2026-01-15`). One file holds at most 50,000 URLs; `render/2` raises past that.

## IndexNow

### Why changed-only submission

IndexNow asks you to submit URLs when they are added, updated or deleted. The easy implementation resubmits the whole sitemap on every deploy, which tells the engines nothing about what changed. `PhoenixDiscovery.IndexNow.submit_changed/2` keeps the `url => lastmod` map from the last successful submission in a small JSON file and submits only URLs that are new or whose `updated_at` changed. When nothing changed, it makes no request. With no state file (a fresh machine, or a host whose disk is wiped on restart) it submits only entries dated in the last 14 days, never the full list.

For Bing, verify the site in Bing Webmaster Tools first. On the site this code came from, submissions were rejected with 403 until the site was verified there, even though the key file was served correctly.

### 1. Serve the key file

Generate a key once (`openssl rand -hex 16`) and set it as `INDEXNOW_KEY`. In your endpoint, after `Plug.Static` and before the router:

```elixir
plug PhoenixDiscovery.IndexNow.KeyPlug, key: {System, :get_env, ["INDEXNOW_KEY"]}
```

Endpoint plug options are evaluated at compile time, which is why the key is a `{mod, fun, args}` tuple. The plug answers `GET /<key>.txt` with the key and passes every other request through.

### 2. Submit on boot and on a timer

```elixir
# application.ex
children = [
  MyAppWeb.Endpoint,
  {PhoenixDiscovery.IndexNow.Pinger,
   key: System.get_env("INDEXNOW_KEY"),
   base_url: "https://example.com",
   entries: &MyApp.Discovery.entries/0,
   state_path: "/data/indexnow.json"}
]
```

Start the pinger only in production. 30 seconds after boot it submits what changed, unless the state file shows an attempt in the last 24 hours. Every 6 hours after that it diffs again and submits only real changes, which catches posts with a future publish date going live without a deploy. All of these intervals are options; see the module docs.

`state_path` defaults to a file in `System.tmp_dir!()`. Point it at persistent disk if you have one, so a restart can diff against the previous run.

### Submit by hand

```elixir
PhoenixDiscovery.IndexNow.submit_changed(MyApp.Discovery.entries(),
  key: System.fetch_env!("INDEXNOW_KEY"),
  base_url: "https://example.com",
  state_path: "/data/indexnow.json"
)
#=> {:ok, %{status: 200, url_count: 3}} | {:ok, :no_changes} | {:ok, :skipped} | {:error, reason}
```

Pass `force: true` to submit every entry. `PhoenixDiscovery.IndexNow.submit/2` sends an explicit list of URLs. Neither function raises on HTTP errors; they return `{:error, reason}` and log a warning.

### Testing without the network

`submit/2`, `submit_changed/2` and the pinger accept `:req_options`, which are merged into the `Req` request. Pass a plug to stub the HTTP call:

```elixir
stub = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

PhoenixDiscovery.IndexNow.submit_changed(entries,
  key: "test-key-123",
  base_url: "https://example.com",
  state_path: Path.join(tmp_dir, "indexnow.json"),
  req_options: [plug: stub, retry: false]
)
```

## llms.txt

```elixir
def llms_txt(conn, _params) do
  text =
    PhoenixDiscovery.LlmsTxt.render(MyAppWeb.Endpoint.url(), %{
      title: "Example",
      summary: "Guides and API reference for Example.",
      sections: [
        {"Docs", [%{title: "Quick start", url: "/docs/start", description: "Install and first request"}]},
        {"Optional", [%{title: "Changelog", url: "/changelog"}]}
      ]
    })

  conn
  |> put_resp_content_type("text/plain")
  |> send_resp(200, text)
end
```

Output:

```markdown
# Example

> Guides and API reference for Example.

## Docs

- [Quick start](https://example.com/docs/start): Install and first request

## Optional

- [Changelog](https://example.com/changelog)
```

`PhoenixDiscovery.LlmsTxt.render_full/2` builds `llms-full.txt` from `%{title, url, body}` documents, and rewrites root-relative Markdown links in each body to absolute URLs, so a chunk of the file read on its own keeps working links.

## JSON-LD

Build the nodes for a page:

```elixir
base = MyAppWeb.Endpoint.url()

json_ld = [
  PhoenixDiscovery.JsonLd.website(base, name: "Example", publisher: :organization),
  PhoenixDiscovery.JsonLd.organization(base, name: "Example Inc.", logo: "/images/logo.png"),
  PhoenixDiscovery.JsonLd.blog_posting(base,
    path: "/blog/#{post.slug}",
    headline: post.title,
    date_published: post.published_at,
    date_modified: post.updated_at,
    author: :organization
  ),
  PhoenixDiscovery.JsonLd.breadcrumbs(base, [{"Home", "/"}, {"Blog", "/blog"}, {post.title, "/blog/#{post.slug}"}])
]
```

Render them in your layout:

```heex
<script type="application/ld+json">
  <%= Phoenix.HTML.raw(PhoenixDiscovery.JsonLd.encode(@json_ld)) %>
</script>
```

The site-wide nodes have fixed ids (`https://example.com/#website`, `#organization`, `#person`). Other nodes refer to them by `@id` instead of repeating their data, so crawlers resolve one entity per thing. `encode/1` escapes `<`, `>`, `&` and `/`, so content cannot close the script tag. Each builder returns a plain map; add any other schema.org property with `Map.put/3`.

## Development

```sh
mix deps.get
mix test
```

CI runs `mix compile --warnings-as-errors`, `mix format --check-formatted` and `mix test` on Elixir 1.20.4 and OTP 29.1.2.

## License

MIT. See [LICENSE](LICENSE).

Extracted from the code that runs [sublimecoding.com](https://sublimecoding.com).

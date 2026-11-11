defmodule PhoenixDiscovery.JsonLd do
  @moduledoc """
  Builders for schema.org JSON-LD nodes that refer to each other by `@id`.

  ## Identifiers

  The site-wide nodes get fixed identifiers under the base URL:

  | Node           | `@id`                               |
  |----------------|-------------------------------------|
  | `WebSite`      | `https://example.com/#website`      |
  | `Organization` | `https://example.com/#organization` |
  | `Person`       | `https://example.com/#person`       |

  Page nodes use the page URL plus a fragment: `#article`, `#faq`,
  `#collection`. Other nodes point at these with `%{"@id" => ...}` instead
  of repeating their data, so crawlers resolve one entity per thing
  instead of several partial copies.

  Options that link to another node (`:author`, `:publisher`, `:founder`,
  `:works_for`) take `:person`, `:organization`, a map that is embedded as
  given, or `nil` to leave the property out.

  `faq_page/2` and `collection_page/2` set `isPartOf` to the `WebSite` node,
  so emit `website/2` on every page.

  Each builder returns a map with string keys. Properties that are `nil`,
  `""` or `[]` are left out. Add any other schema.org property with
  `Map.put/3` or `Map.merge/2`.

  ## Embedding

  In a HEEx layout:

  ```heex
  <script type="application/ld+json">
    <%= Phoenix.HTML.raw(PhoenixDiscovery.JsonLd.encode(@json_ld)) %>
  </script>
  ```

  `encode/1` escapes `<`, `>`, `&` and `/`, so text in the data cannot
  close the script tag.
  """

  @context "https://schema.org"

  @typedoc "A link to another node: a site-wide node, an embedded map, or nothing."
  @type link :: :person | :organization | map() | nil

  @doc """
  A reference to a site-wide node.

      iex> PhoenixDiscovery.JsonLd.ref("https://example.com", :person)
      %{"@id" => "https://example.com/#person"}
  """
  @spec ref(String.t(), :website | :organization | :person) :: map()
  def ref(base_url, kind) when kind in [:website, :organization, :person],
    do: %{"@id" => PhoenixDiscovery.url(base_url, "/") <> "##{kind}"}

  @doc """
  Encodes one node or a list of nodes as JSON that is safe to place inside
  a `<script>` element.
  """
  @spec encode(map() | [map()]) :: String.t()
  def encode(data), do: Jason.encode!(data, escape: :html_safe)

  @doc """
  The `WebSite` node.

  ## Attributes

    * `:name` (required)
    * `:description`
    * `:in_language` - for example `"en-US"`
    * `:publisher` - a link, see the module docs. Default `nil`.
  """
  @spec website(String.t(), keyword()) :: map()
  def website(base_url, attrs) do
    node("WebSite", ref(base_url, :website))
    |> Map.put("url", PhoenixDiscovery.url(base_url, "/"))
    |> Map.put("name", Keyword.fetch!(attrs, :name))
    |> put("description", attrs[:description])
    |> put("inLanguage", attrs[:in_language])
    |> put("publisher", link(base_url, attrs[:publisher]))
  end

  @doc """
  The `Organization` node.

  ## Attributes

    * `:name` (required)
    * `:url` - defaults to the site root
    * `:description`
    * `:logo` - path or URL of the logo image
    * `:same_as` - list of profile URLs for the same organization
    * `:founder` - a link, see the module docs. Default `nil`.
  """
  @spec organization(String.t(), keyword()) :: map()
  def organization(base_url, attrs) do
    node("Organization", ref(base_url, :organization))
    |> Map.put("name", Keyword.fetch!(attrs, :name))
    |> Map.put("url", absolute(base_url, Keyword.get(attrs, :url, "/")))
    |> put("description", attrs[:description])
    |> put("logo", absolute(base_url, attrs[:logo]))
    |> put("sameAs", attrs[:same_as])
    |> put("founder", link(base_url, attrs[:founder]))
  end

  @doc """
  The `Person` node.

  ## Attributes

    * `:name` (required)
    * `:url` - defaults to the site root
    * `:description`
    * `:job_title`
    * `:image` - path or URL of a photo
    * `:same_as` - list of profile URLs for the same person
    * `:works_for` - a link, see the module docs. Default `nil`.
  """
  @spec person(String.t(), keyword()) :: map()
  def person(base_url, attrs) do
    node("Person", ref(base_url, :person))
    |> Map.put("name", Keyword.fetch!(attrs, :name))
    |> Map.put("url", absolute(base_url, Keyword.get(attrs, :url, "/")))
    |> put("description", attrs[:description])
    |> put("jobTitle", attrs[:job_title])
    |> put("image", absolute(base_url, attrs[:image]))
    |> put("sameAs", attrs[:same_as])
    |> put("worksFor", link(base_url, attrs[:works_for]))
  end

  @doc """
  A `BlogPosting` node for one post.

  ## Attributes

    * `:path` (required) - the post's path, for example `"/blog/hello"`
    * `:headline` (required)
    * `:date_published` (required) - `DateTime`, `NaiveDateTime`, `Date`
      or ISO 8601 string
    * `:date_modified` - same types as `:date_published`
    * `:description`
    * `:image` - path or URL
    * `:author` - a link. Default `:person`.
    * `:publisher` - a link. Default `nil`.
    * `:keywords` - list of strings
    * `:section` - becomes `articleSection`
    * `:word_count`
    * `:in_language`
  """
  @spec blog_posting(String.t(), keyword()) :: map()
  def blog_posting(base_url, attrs) do
    url = PhoenixDiscovery.url(base_url, Keyword.fetch!(attrs, :path))

    node("BlogPosting", %{"@id" => url <> "#article"})
    |> Map.merge(%{
      "url" => url,
      "headline" => Keyword.fetch!(attrs, :headline),
      "datePublished" => iso8601(Keyword.fetch!(attrs, :date_published)),
      "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => url}
    })
    |> put("dateModified", iso8601(attrs[:date_modified]))
    |> put("description", attrs[:description])
    |> put("image", absolute(base_url, attrs[:image]))
    |> put("author", link(base_url, Keyword.get(attrs, :author, :person)))
    |> put("publisher", link(base_url, attrs[:publisher]))
    |> put("keywords", attrs[:keywords] && Enum.join(attrs[:keywords], ", "))
    |> put("articleSection", attrs[:section])
    |> put("wordCount", attrs[:word_count])
    |> put("inLanguage", attrs[:in_language])
  end

  @doc """
  A `BreadcrumbList` from `{name, path}` tuples, root first.

      iex> PhoenixDiscovery.JsonLd.breadcrumbs("https://example.com", [{"Home", "/"}, {"Blog", "/blog"}])
      %{
        "@context" => "https://schema.org",
        "@type" => "BreadcrumbList",
        "itemListElement" => [
          %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => "https://example.com/"},
          %{"@type" => "ListItem", "position" => 2, "name" => "Blog", "item" => "https://example.com/blog"}
        ]
      }
  """
  @spec breadcrumbs(String.t(), [{String.t(), String.t()}]) :: map()
  def breadcrumbs(base_url, items) when is_list(items) do
    %{
      "@context" => @context,
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, path}, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "name" => name,
            "item" => PhoenixDiscovery.url(base_url, path)
          }
        end)
    }
  end

  @doc """
  A `FAQPage` node. Each question and answer should also be visible on
  the page itself.

  ## Attributes

    * `:path` (required) - the page that shows the questions. Give every
      FAQ page its own path, so two pages never share one `@id`.
    * `:questions` (required) - list of `{question, answer}` tuples
    * `:name`
    * `:in_language`
  """
  @spec faq_page(String.t(), keyword()) :: map()
  def faq_page(base_url, attrs) do
    url = PhoenixDiscovery.url(base_url, Keyword.fetch!(attrs, :path))

    questions =
      for {question, answer} <- Keyword.fetch!(attrs, :questions) do
        %{
          "@type" => "Question",
          "name" => question,
          "acceptedAnswer" => %{"@type" => "Answer", "text" => answer}
        }
      end

    node("FAQPage", %{"@id" => url <> "#faq"})
    |> Map.merge(%{
      "url" => url,
      "isPartOf" => ref(base_url, :website),
      "mainEntity" => questions
    })
    |> put("name", attrs[:name])
    |> put("inLanguage", attrs[:in_language])
  end

  @doc """
  A `CollectionPage` whose `mainEntity` is an `ItemList`, for index pages
  such as a tag or category listing.

  ## Attributes

    * `:path` (required)
    * `:name` (required)
    * `:items` (required) - list of `%{name: name, path: path}` maps, with
      an optional `:description`. Positions follow list order.
    * `:description`
    * `:in_language`
  """
  @spec collection_page(String.t(), keyword()) :: map()
  def collection_page(base_url, attrs) do
    url = PhoenixDiscovery.url(base_url, Keyword.fetch!(attrs, :path))

    items =
      attrs
      |> Keyword.fetch!(:items)
      |> Enum.with_index(1)
      |> Enum.map(fn {%{name: name, path: path} = item, position} ->
        %{
          "@type" => "ListItem",
          "position" => position,
          "url" => PhoenixDiscovery.url(base_url, path),
          "name" => name
        }
        |> put("description", item[:description])
      end)

    node("CollectionPage", %{"@id" => url <> "#collection"})
    |> Map.merge(%{
      "url" => url,
      "name" => Keyword.fetch!(attrs, :name),
      "isPartOf" => ref(base_url, :website),
      "mainEntity" => %{
        "@type" => "ItemList",
        "numberOfItems" => length(items),
        "itemListElement" => items
      }
    })
    |> put("description", attrs[:description])
    |> put("inLanguage", attrs[:in_language])
  end

  defp node(type, id_ref),
    do: Map.merge(%{"@context" => @context, "@type" => type}, id_ref)

  defp link(_base_url, nil), do: nil
  defp link(base_url, kind) when kind in [:person, :organization], do: ref(base_url, kind)
  defp link(_base_url, %{} = embedded), do: embedded

  defp absolute(_base_url, nil), do: nil
  defp absolute(base_url, path_or_url), do: PhoenixDiscovery.url(base_url, path_or_url)

  defp iso8601(nil), do: nil
  defp iso8601(value) when is_binary(value), do: value

  defp iso8601(%mod{} = value) when mod in [Date, DateTime, NaiveDateTime],
    do: mod.to_iso8601(value)

  defp put(map, _key, value) when value in [nil, "", []], do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end

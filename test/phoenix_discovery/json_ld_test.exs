defmodule PhoenixDiscovery.JsonLdTest do
  use ExUnit.Case, async: true

  alias PhoenixDiscovery.JsonLd

  doctest JsonLd

  @base "https://example.com"

  describe "ref/2" do
    test "builds the fixed site-wide identifiers" do
      assert JsonLd.ref(@base, :website) == %{"@id" => "https://example.com/#website"}

      assert JsonLd.ref(@base <> "/", :organization) == %{
               "@id" => "https://example.com/#organization"
             }
    end
  end

  describe "encode/1" do
    test "escapes text that could close the script element" do
      json = JsonLd.encode(%{"name" => "</script><script>alert(1)</script>"})

      refute json =~ "</script>"
      assert Jason.decode!(json) == %{"name" => "</script><script>alert(1)</script>"}
    end

    test "encodes a list of nodes as a JSON array" do
      assert JsonLd.encode([JsonLd.ref(@base, :person)]) ==
               ~S([{"@id":"https:\/\/example.com\/#person"}])
    end
  end

  describe "website/2" do
    test "builds a minimal node" do
      assert JsonLd.website(@base, name: "Example") == %{
               "@context" => "https://schema.org",
               "@type" => "WebSite",
               "@id" => "https://example.com/#website",
               "url" => "https://example.com/",
               "name" => "Example"
             }
    end

    test "adds optional properties and links the publisher" do
      node =
        JsonLd.website(@base,
          name: "Example",
          description: "Docs and guides",
          in_language: "en-US",
          publisher: :organization
        )

      assert node["description"] == "Docs and guides"
      assert node["inLanguage"] == "en-US"
      assert node["publisher"] == %{"@id" => "https://example.com/#organization"}
    end

    test "requires :name" do
      assert_raise KeyError, fn -> JsonLd.website(@base, []) end
    end
  end

  describe "organization/2" do
    test "builds the node with absolute logo URL and profile links" do
      assert JsonLd.organization(@base,
               name: "Example Inc.",
               logo: "/images/logo.png",
               same_as: ["https://github.com/example"],
               founder: :person
             ) == %{
               "@context" => "https://schema.org",
               "@type" => "Organization",
               "@id" => "https://example.com/#organization",
               "name" => "Example Inc.",
               "url" => "https://example.com/",
               "logo" => "https://example.com/images/logo.png",
               "sameAs" => ["https://github.com/example"],
               "founder" => %{"@id" => "https://example.com/#person"}
             }
    end

    test "leaves out empty properties" do
      node = JsonLd.organization(@base, name: "Example Inc.", same_as: [], description: "")

      refute Map.has_key?(node, "sameAs")
      refute Map.has_key?(node, "description")
    end
  end

  describe "person/2" do
    test "builds the node and links the employer" do
      assert JsonLd.person(@base,
               name: "Ada Example",
               url: "/about",
               job_title: "Engineer",
               image: "https://cdn.example.com/ada.jpg",
               works_for: :organization
             ) == %{
               "@context" => "https://schema.org",
               "@type" => "Person",
               "@id" => "https://example.com/#person",
               "name" => "Ada Example",
               "url" => "https://example.com/about",
               "jobTitle" => "Engineer",
               "image" => "https://cdn.example.com/ada.jpg",
               "worksFor" => %{"@id" => "https://example.com/#organization"}
             }
    end
  end

  describe "blog_posting/2" do
    test "builds the node with ids, dates and links" do
      node =
        JsonLd.blog_posting(@base,
          path: "/blog/hello",
          headline: "Hello",
          date_published: ~U[2026-01-15 09:00:00Z],
          date_modified: ~D[2026-02-01],
          description: "A first post",
          image: "/images/hello.png",
          publisher: :organization,
          keywords: ["elixir", "phoenix"],
          section: "Engineering",
          word_count: 1200,
          in_language: "en-US"
        )

      assert node == %{
               "@context" => "https://schema.org",
               "@type" => "BlogPosting",
               "@id" => "https://example.com/blog/hello#article",
               "url" => "https://example.com/blog/hello",
               "headline" => "Hello",
               "datePublished" => "2026-01-15T09:00:00Z",
               "dateModified" => "2026-02-01",
               "mainEntityOfPage" => %{
                 "@type" => "WebPage",
                 "@id" => "https://example.com/blog/hello"
               },
               "description" => "A first post",
               "image" => "https://example.com/images/hello.png",
               "author" => %{"@id" => "https://example.com/#person"},
               "publisher" => %{"@id" => "https://example.com/#organization"},
               "keywords" => "elixir, phoenix",
               "articleSection" => "Engineering",
               "wordCount" => 1200,
               "inLanguage" => "en-US"
             }
    end

    test "defaults the author to the site person and omits the rest" do
      node =
        JsonLd.blog_posting(@base,
          path: "/blog/hello",
          headline: "Hello",
          date_published: "2026-01-15",
          keywords: []
        )

      assert node["author"] == %{"@id" => "https://example.com/#person"}
      assert node["datePublished"] == "2026-01-15"

      for key <- ~w(publisher dateModified keywords image description) do
        refute Map.has_key?(node, key)
      end
    end

    test "embeds an author map or omits the author" do
      guest = %{"@type" => "Person", "name" => "Guest Writer"}

      embedded =
        JsonLd.blog_posting(@base,
          path: "/blog/guest",
          headline: "Guest",
          date_published: ~N[2026-01-15 09:00:00],
          author: guest
        )

      assert embedded["author"] == guest
      assert embedded["datePublished"] == "2026-01-15T09:00:00"

      none =
        JsonLd.blog_posting(@base, path: "/x", headline: "X", date_published: "2026", author: nil)

      refute Map.has_key?(none, "author")
    end
  end

  describe "breadcrumbs/2" do
    test "renders an empty list" do
      assert JsonLd.breadcrumbs(@base, [])["itemListElement"] == []
    end
  end

  describe "faq_page/2" do
    test "builds questions with accepted answers, anchored to the page" do
      assert JsonLd.faq_page(@base,
               path: "/faq",
               name: "FAQ",
               questions: [{"Is it free?", "Yes."}]
             ) == %{
               "@context" => "https://schema.org",
               "@type" => "FAQPage",
               "@id" => "https://example.com/faq#faq",
               "url" => "https://example.com/faq",
               "name" => "FAQ",
               "isPartOf" => %{"@id" => "https://example.com/#website"},
               "mainEntity" => [
                 %{
                   "@type" => "Question",
                   "name" => "Is it free?",
                   "acceptedAnswer" => %{"@type" => "Answer", "text" => "Yes."}
                 }
               ]
             }
    end
  end

  describe "collection_page/2" do
    test "wraps the items in a numbered ItemList" do
      node =
        JsonLd.collection_page(@base,
          path: "/blog/tag/elixir",
          name: "Elixir posts",
          description: "Posts tagged Elixir",
          items: [
            %{name: "Hello", path: "/blog/hello", description: "A first post"},
            %{name: "Second", path: "/blog/second"}
          ]
        )

      assert node["@type"] == "CollectionPage"
      assert node["@id"] == "https://example.com/blog/tag/elixir#collection"
      assert node["isPartOf"] == %{"@id" => "https://example.com/#website"}
      assert node["description"] == "Posts tagged Elixir"

      assert node["mainEntity"] == %{
               "@type" => "ItemList",
               "numberOfItems" => 2,
               "itemListElement" => [
                 %{
                   "@type" => "ListItem",
                   "position" => 1,
                   "url" => "https://example.com/blog/hello",
                   "name" => "Hello",
                   "description" => "A first post"
                 },
                 %{
                   "@type" => "ListItem",
                   "position" => 2,
                   "url" => "https://example.com/blog/second",
                   "name" => "Second"
                 }
               ]
             }
    end
  end
end

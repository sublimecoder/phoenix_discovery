defmodule PhoenixDiscovery.LlmsTxtTest do
  use ExUnit.Case, async: true

  alias PhoenixDiscovery.LlmsTxt

  @base "https://example.com"

  describe "render/2" do
    test "renders title, summary, details and sections in order" do
      text =
        LlmsTxt.render(@base, %{
          title: "Example",
          summary: "Guides for the Example API.",
          details: "All guides assume version 2.",
          sections: [
            {"Docs",
             [
               %{
                 title: "Quick start",
                 url: "/docs/start",
                 description: "Install and first request"
               },
               %{title: "API reference", url: "https://api.example.com/ref"}
             ]},
            {"Optional", [%{title: "Changelog", url: "/changelog"}]}
          ]
        })

      assert text == """
             # Example

             > Guides for the Example API.

             All guides assume version 2.

             ## Docs

             - [Quick start](https://example.com/docs/start): Install and first request
             - [API reference](https://api.example.com/ref)

             ## Optional

             - [Changelog](https://example.com/changelog)
             """
    end

    test "renders a title on its own" do
      assert LlmsTxt.render(@base, %{title: "Example"}) == "# Example\n"
    end

    test "leaves out sections with no links" do
      text = LlmsTxt.render(@base, %{title: "Example", sections: [{"Empty", []}]})
      refute text =~ "Empty"
    end

    test "quotes every line of a multi-line summary" do
      text = LlmsTxt.render(@base, %{title: "Example", summary: "Line one.\n\nLine two."})
      assert text == "# Example\n\n> Line one.\n>\n> Line two.\n"
    end

    test "keeps each link on one line and drops empty descriptions" do
      text =
        LlmsTxt.render(@base, %{
          title: "Example",
          sections: [
            {"Docs",
             [
               %{title: "Two\nlines", url: "/a", description: "First\n  second"},
               %{title: "Blank", url: "/b", description: ""},
               %{title: "Nil", url: "/c", description: nil}
             ]}
          ]
        })

      assert text =~ "- [Two lines](https://example.com/a): First second\n"
      assert text =~ "- [Blank](https://example.com/b)\n"
      assert text =~ "- [Nil](https://example.com/c)\n"
    end
  end

  describe "render_full/2" do
    test "inlines each document with its URL" do
      text =
        LlmsTxt.render_full(@base, %{
          title: "Example",
          summary: "Full text of every guide.",
          documents: [
            %{title: "Hello", url: "/blog/hello", body: "First post.\n"},
            %{title: "Second", url: "/blog/second", body: "Second post."}
          ]
        })

      assert text == """
             # Example

             > Full text of every guide.

             ## Hello

             URL: https://example.com/blog/hello

             First post.

             ---

             ## Second

             URL: https://example.com/blog/second

             Second post.

             ---
             """
    end

    test "makes root-relative links absolute and leaves other links alone" do
      body = "[a](/docs) [b](//cdn.example.com/x) [c](https://example.org/y) [d](#top)"

      text =
        LlmsTxt.render_full(@base <> "/", %{
          title: "Example",
          documents: [%{title: "Links", url: "/links", body: body}]
        })

      assert text =~
               "[a](https://example.com/docs) [b](//cdn.example.com/x) " <>
                 "[c](https://example.org/y) [d](#top)"
    end

    test "renders a header with no documents" do
      assert LlmsTxt.render_full(@base, %{title: "Example", details: "Nothing yet."}) ==
               "# Example\n\nNothing yet.\n"
    end
  end
end

defmodule PhoenixDiscovery.LlmsTxt do
  @moduledoc """
  Renders [`llms.txt`](https://llmstxt.org) and an `llms-full.txt` companion.

  `llms.txt` is a Markdown index for language models: an H1 title, an
  optional blockquote summary, optional free text, then H2 sections of
  links. A section named `"Optional"` marks links a model may skip when
  its context is short.

  `llms-full.txt` is a common companion (not part of the llmstxt.org
  proposal) that inlines the full text of each page, so a model can read
  the content without crawling the HTML.

  Link and document URLs may be paths (`"/about"`), which are joined to the
  base URL, or absolute URLs.
  """

  @typedoc "A link in an `llms.txt` section. `:description` is optional."
  @type link :: %{
          required(:title) => String.t(),
          required(:url) => String.t(),
          optional(:description) => String.t() | nil
        }

  @typedoc "A page inlined into `llms-full.txt`. `:body` is Markdown."
  @type document :: %{title: String.t(), url: String.t(), body: String.t()}

  @doc """
  Renders `llms.txt`.

  `index` is a map with:

    * `:title` (required) - the H1.
    * `:summary` - rendered as a blockquote.
    * `:details` - free Markdown placed before the sections.
    * `:sections` - a list of `{heading, [link]}` tuples, in order. Sections
      with no links are left out.

  ## Example

      PhoenixDiscovery.LlmsTxt.render("https://example.com", %{
        title: "Example",
        summary: "Guides for the Example API.",
        sections: [
          {"Docs", [%{title: "Quick start", url: "/docs/start", description: "Install and first request"}]},
          {"Optional", [%{title: "Changelog", url: "/changelog"}]}
        ]
      })

  returns:

  ```markdown
  # Example

  > Guides for the Example API.

  ## Docs

  - [Quick start](https://example.com/docs/start): Install and first request

  ## Optional

  - [Changelog](https://example.com/changelog)
  ```
  """
  @spec render(String.t(), map()) :: String.t()
  def render(base_url, %{title: title} = index) do
    sections =
      for {heading, [_ | _] = links} <- Map.get(index, :sections, []) do
        ["## ", heading, "\n\n", Enum.map(links, &link_line(base_url, &1)), "\n"]
      end

    [header(title, Map.get(index, :summary)), paragraph(Map.get(index, :details)), sections]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @doc """
  Renders `llms-full.txt`.

  `full` is a map with `:title` (required), `:summary`, `:details` and
  `:documents`, a list of `%{title, url, body}` maps rendered in order.

  Root-relative Markdown links in a body (`[text](/path)`) are made
  absolute, so a chunk of the file read on its own still has working
  links. Headings inside a body are not changed; if a body has its own `#`
  or `##` headings, demote them before passing it in.

  ## Example

      PhoenixDiscovery.LlmsTxt.render_full("https://example.com", %{
        title: "Example",
        documents: [%{title: "Hello", url: "/blog/hello", body: "See [the docs](/docs)."}]
      })

  returns:

  ```markdown
  # Example

  ## Hello

  URL: https://example.com/blog/hello

  See [the docs](https://example.com/docs).

  ---
  ```
  """
  @spec render_full(String.t(), map()) :: String.t()
  def render_full(base_url, %{title: title} = full) do
    documents =
      for %{title: doc_title, url: url, body: body} <- Map.get(full, :documents, []) do
        [
          ["## ", doc_title, "\n\n"],
          ["URL: ", PhoenixDiscovery.url(base_url, url), "\n\n"],
          [absolutize_links(String.trim(body), base_url), "\n\n---\n\n"]
        ]
      end

    [header(title, Map.get(full, :summary)), paragraph(Map.get(full, :details)), documents]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp header(title, summary) do
    ["# ", single_line(title), "\n\n", quote_block(summary)]
  end

  defp quote_block(nil), do: []

  defp quote_block(text) do
    lines = text |> String.trim() |> String.split("\n")
    [Enum.map_join(lines, "\n", &String.trim_trailing("> " <> &1)), "\n\n"]
  end

  defp paragraph(nil), do: []
  defp paragraph(text), do: [String.trim(text), "\n\n"]

  defp link_line(base_url, %{title: title, url: url} = link) do
    description =
      case Map.get(link, :description) do
        nil -> []
        "" -> []
        text -> [": ", single_line(text)]
      end

    ["- [", single_line(title), "](", PhoenixDiscovery.url(base_url, url), ")", description, "\n"]
  end

  # A newline inside a list item or heading would end it early.
  defp single_line(text), do: text |> String.trim() |> String.replace(~r/\s*\n\s*/, " ")

  # `](/path` but not protocol-relative `](//host`.
  defp absolutize_links(markdown, base_url) do
    String.replace(markdown, ~r{\]\(/(?!/)}, "](" <> String.trim_trailing(base_url, "/") <> "/")
  end
end

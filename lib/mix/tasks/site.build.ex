defmodule Mix.Tasks.Site.Build do
  @shortdoc "Builds the static homepage into site/dist"

  @moduledoc """
  Builds Kinoko's static homepage:

      mix site.build

  Writes `site/dist/`:

    * `index.html`: `site/src/index.html.eex` rendered with, read verbatim
      and HTML-escaped: the code samples `site/samples/*.yabu`, their printed
      verdicts and the counter's CIDs (`site/samples/verdicts/*.txt`, kept
      true by `test/site/samples_test.exs`), and the terminal session
      `site/samples/session.txt` (recorded from the release binary);
    * `site.css`: the Tailwind `site` profile (input `site/src/site.css`);
    * `fonts/*`: the Vellum fonts and their licences from `priv/static/fonts`;
    * `copy.js`: the copy-to-clipboard script, from `site/src/copy.js`.

  `mix site.serve` previews the result.
  """

  use Mix.Task

  @site "site"
  @fonts "priv/static/fonts"

  # The GitHub repository the page links to and installs from: `KINOKO_REPO`
  # (CI sets it from `github.repository`), else this placeholder locally. The install line fetches install.sh from the latest release,
  # where the release workflow has stamped this repository into it (the copy
  # on the main branch keeps the OWNER/kinoko default and refuses to run).
  @repo "OWNER/kinoko"

  # Keywords the console colours at the start of a line (and a trailing `do`).
  @keywords ~w(defmodel deftype defapp def case if else end)

  @impl Mix.Task
  def run(_args) do
    dist = Path.join(@site, "dist")
    build(@site, dist)
    Mix.shell().info("Built #{dist}/")
  end

  @doc """
  Builds the page from `site` into `dist` (emptied first): the HTML, the
  copy script, the fonts, and the stylesheet (Tailwind's `site` profile).
  """
  @spec build(Path.t(), Path.t()) :: :ok
  def build(site, dist) do
    File.rm_rf!(dist)
    File.mkdir_p!(Path.join(dist, "fonts"))

    File.write!(Path.join(dist, "index.html"), render(site))
    File.cp!(Path.join([site, "src", "copy.js"]), Path.join(dist, "copy.js"))

    for font <- File.ls!(@fonts),
        do: File.cp!(Path.join(@fonts, font), Path.join([dist, "fonts", font]))

    Mix.Task.run("tailwind", ["site", "--minify", "--output=#{Path.expand("site.css", dist)}"])
    Mix.Task.reenable("tailwind")
    :ok
  end

  @doc "The homepage's HTML, from the template and samples under `site`."
  @spec render(Path.t()) :: String.t()
  def render(site) do
    sample = &read(site, ["samples", &1])
    verdict = &read(site, ["samples", "verdicts", &1])

    EEx.eval_file(Path.join([site, "src", "index.html.eex"]),
      assigns: [
        version: Mix.Project.config()[:version],
        install_url: install_url(),
        source_url: "https://github.com/#{repo()}",
        releases_url: "https://github.com/#{repo()}/releases",
        glossary_url: "https://github.com/#{repo()}/blob/main/docs/GLOSSARY.md",
        counter: code(sample.("counter.yabu")),
        store: code(sample.("store.yabu")),
        mistake: code(sample.("mistake.yabu")),
        counter_verdict: escape(verdict.("counter.txt")),
        store_verdict: escape(verdict.("store.txt")),
        mistake_verdict: verdict_lines(verdict.("mistake.txt")),
        mistake_reasons: reasons(verdict.("mistake.txt")),
        cids: cids(verdict.("counter-cids.txt")),
        session: session(sample.("session.txt"))
      ]
    )
  end

  @doc "The install script's URL: the latest release's stamped `install.sh`."
  @spec install_url() :: String.t()
  def install_url, do: "https://github.com/#{repo()}/releases/latest/download/install.sh"

  defp repo do
    case System.get_env("KINOKO_REPO") do
      repo when repo in [nil, ""] -> @repo
      repo -> repo
    end
  end

  defp read(site, parts),
    do: [site | parts] |> Path.join() |> File.read!() |> String.trim_trailing()

  defp escape(text), do: Plug.HTML.html_escape(text)

  # A code sample as `%{lines: n, html: highlighted}`: the gutter shows 1..n;
  # the html is the escaped source, every line kept, with the console's
  # keyword colouring (a leading keyword and a trailing `do`).
  defp code(text) do
    lines = String.split(text, "\n")
    %{lines: length(lines), html: Enum.map_join(lines, "\n", &highlight/1)}
  end

  defp highlight(line) do
    [_, indent, rest] = Regex.run(~r/^(\s*)(.*)$/, line)
    {word, tail} = split_word(rest)

    head =
      if word in @keywords, do: ~s(<span class="tok-kw">#{word}</span>), else: escape(word)

    tail =
      if String.ends_with?(tail, " do"),
        do: escape(String.slice(tail, 0..-4//1)) <> ~s( <span class="tok-kw">do</span>),
        else: escape(tail)

    indent <> head <> tail
  end

  defp split_word(text) do
    case Regex.run(~r/^([a-z]+)(.*)$/, text) do
      [_, word, tail] -> {word, tail}
      nil -> {"", text}
    end
  end

  # The printed verdict, one `{class, escaped line}` per line: the head line
  # (`staged: ...`) and each `- symbol [code] message` reason.
  defp verdict_lines(text) do
    for line <- String.split(text, "\n") do
      {if(String.starts_with?(line, "- "), do: "tok-reason", else: "tok-staged"), escape(line)}
    end
  end

  # The reasons of a printed verdict, `- Symbol [code] message`, as
  # `%{name, code, message}` (escaped) for the console's Blocked callout.
  defp reasons(text) do
    for line <- String.split(text, "\n"),
        [_, name, code, message] <- [Regex.run(~r/^- (\S+) \[([^\]]+)\] (.*)$/, line)] do
      %{name: escape(name), code: escape(code), message: escape(message)}
    end
  end

  # `sha256 <8 hex>  <symbol>` lines, as `{cid, symbol}`.
  defp cids(text) do
    for line <- String.split(text, "\n"),
        [_, cid, symbol] <- [Regex.run(~r/^sha256 ([0-9a-f]+)  (\S+)$/, line)] do
      {cid, escape(symbol)}
    end
  end

  # The recorded session, one line each: `{:cmd, command}` for `$ ...`,
  # `{:ok, text}` for a promotion, `{:out, text}` otherwise (all escaped).
  defp session(text) do
    for line <- String.split(text, "\n") do
      cond do
        String.starts_with?(line, "$ ") -> {:cmd, escape(String.slice(line, 2..-1//1))}
        String.starts_with?(line, "promoted: ") -> {:ok, escape(line)}
        true -> {:out, escape(line)}
      end
    end
  end
end

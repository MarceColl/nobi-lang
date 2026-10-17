defmodule Mix.Tasks.Site.Build do
  @shortdoc "Builds the static homepage into site/dist"

  @moduledoc """
  Builds Kinoko's static homepage:

      mix site.build

  Writes `site/dist/`:

    * `index.html`: `site/src/index.html.eex` rendered with, HTML-escaped:
      the counter sample `site/samples/counter.yabu` verbatim (kept
      compiling by `test/site/samples_test.exs`), and the Kinoko tool calls
      of a recorded agent run, `site/samples/agent-run.jsonl` (see
      `agent_run/1`);
    * `forum.webp`: the forum that run built, from `site/src/forum.webp`;
    * `site.css`: the Tailwind `site` profile (input `site/src/site.css`);
    * `fonts/*`: the Vellum fonts and their licences from `priv/static/fonts`;
    * `copy.js`: the copy-to-clipboard script, from `site/src/copy.js`.

  `mix site.serve` previews the result.
  """

  use Mix.Task

  @site "site"
  @fonts "priv/static/fonts"

  # The GitHub repository the page links to and installs from: `KINOKO_REPO`
  # (CI sets it from `github.repository`), else this placeholder locally. The install line fetches install.sh from
  # the latest release, where the release workflow has stamped this repository into it (the copy
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
  copy script, the screenshot, the fonts, and the stylesheet (Tailwind's `site` profile).
  """
  @spec build(Path.t(), Path.t()) :: :ok
  def build(site, dist) do
    File.rm_rf!(dist)
    File.mkdir_p!(Path.join(dist, "fonts"))

    File.write!(Path.join(dist, "index.html"), render(site))

    for file <- ~w(copy.js forum.webp),
        do: File.cp!(Path.join([site, "src", file]), Path.join(dist, file))

    for font <- File.ls!(@fonts),
        do: File.cp!(Path.join(@fonts, font), Path.join([dist, "fonts", font]))

    Mix.Task.run("tailwind", ["site", "--minify", "--output=#{Path.expand("site.css", dist)}"])
    Mix.Task.reenable("tailwind")
    :ok
  end

  @doc "The homepage's HTML, from the template and samples under `site`."
  @spec render(Path.t()) :: String.t()
  def render(site) do
    EEx.eval_file(Path.join([site, "src", "index.html.eex"]),
      assigns: [
        version: Mix.Project.config()[:version],
        release: release(Mix.Project.config()[:version]),
        install_url: install_url(),
        source_url: "https://github.com/#{repo()}",
        releases_url: "https://github.com/#{repo()}/releases",
        counter: code(read(site, ["samples", "counter.yabu"])),
        agent_run: agent_run(read(site, ["samples", "agent-run.jsonl"]))
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

  # "0.1.0" -> "0.1": the release line the Status section names.
  defp release(version), do: version |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  @doc """
  The recorded agent run (`site/samples/agent-run.jsonl`, Claude Code's
  `stream-json` events) as the page shows it: `calls`, one per Kinoko tool
  call in order, `%{name, label, result}` (the tool without its
  `mcp__kinoko__` prefix, the name with its key argument, and the result's
  one line), and `summary`, the agent's closing sentence.
  """
  @spec agent_run(String.t()) :: %{calls: [map()], summary: String.t()}
  def agent_run(jsonl) do
    events = for line <- String.split(jsonl, "\n", trim: true), do: Jason.decode!(line)

    uses =
      for %{"type" => "assistant", "message" => %{"content" => content}} <- events,
          %{"type" => "tool_use", "name" => "mcp__kinoko__" <> name} = use <- content,
          do: {use["id"], name, use["input"]}

    results =
      Map.new(
        for %{"type" => "user", "message" => %{"content" => content}} <- events,
            is_list(content),
            %{"type" => "tool_result"} = r <- content,
            do: {r["tool_use_id"], result_text(r["content"])}
      )

    calls =
      for {id, name, input} <- uses do
        result = summarize(Map.fetch!(results, id))
        %{name: name, label: label(name, input), result: result, class: result_class(result)}
      end

    width = calls |> Enum.map(&String.length(&1.label)) |> Enum.max(fn -> 0 end)

    %{
      calls:
        for call <- calls do
          pad = String.duplicate(" ", width - String.length(call.label))
          %{call | label: escape(call.label), result: escape(call.result)} |> Map.put(:pad, pad)
        end,
      summary:
        events
        |> Enum.find(&(&1["type"] == "result"))
        |> Map.fetch!("result")
        |> first_sentence()
        |> escape()
    }
  end

  defp result_text(text) when is_binary(text), do: text
  defp result_text(parts), do: Enum.map_join(parts, "\n", &(&1["text"] || ""))

  # The tool with its key argument: a patch id, a deployment name, a test, or
  # the start of an expression.
  defp label(name, input) do
    arg = input["id"] || input["name"] || input["symbol"] || input["expression"]
    if arg, do: "#{name} #{clip(arg, 28)}", else: name
  end

  # A result's one line: the URL a deployment serves at, else the first line.
  defp summarize(text) do
    lines = String.split(text, "\n", trim: true)
    line = Enum.find_value(lines, &url_line/1) || List.first(lines, "")
    clip(line, 44)
  end

  defp url_line("URL: " <> url), do: url
  defp url_line(_), do: nil

  defp result_class(result) do
    if result =~ ~r/^(promoted|https?:)|: ok$/, do: "tok-ok", else: "tok-out"
  end

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # The first sentence of the agent's closing message, without its Markdown.
  defp first_sentence(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.replace(~r/[*`]/, "")
    |> String.split(~r/(?<=\.) /, parts: 2)
    |> List.first()
  end
end

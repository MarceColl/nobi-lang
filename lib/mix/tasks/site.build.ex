defmodule Mix.Tasks.Site.Build do
  @shortdoc "Builds the static homepage into site/dist"

  @moduledoc """
  Builds Kinoko's static homepage:

      mix site.build

  Writes `site/dist/`:

    * `index.html`: `site/src/index.html.eex` rendered with the code samples
      of `site/samples/*.yabu` read verbatim and the printed verdicts of
      `site/samples/verdicts/*.txt` (both kept true by
      `test/site/samples_test.exs`), HTML-escaped;
    * `site.css`: the Tailwind `site` profile (input `site/src/site.css`);
    * `fonts/*`: the Vellum fonts and their licences from `priv/static/fonts`;
    * `copy.js`: the copy-to-clipboard script, from `site/src/copy.js`.

  `mix site.serve` previews the result.
  """

  use Mix.Task

  @site "site"
  @fonts "priv/static/fonts"
  # install.sh has no release repository configured yet (KINOKO_REPO=OWNER/kinoko).
  @install_url "https://raw.githubusercontent.com/OWNER/kinoko/main/install.sh"

  # {section id, heading, sample file, verdict fixture}
  @sections [
    {"elm-architecture", "The Elm architecture, Elixir syntax", "counter.yabu", "counter.txt"},
    {"explains-itself", "A compiler that explains itself", "mistake.yabu", "mistake.txt"},
    {"persists", "The BEAM, with data that persists", "store.yabu", "store.txt"}
  ]

  @impl Mix.Task
  def run(_args) do
    dist = Path.join(@site, "dist")
    File.rm_rf!(dist)
    File.mkdir_p!(Path.join(dist, "fonts"))

    File.write!(Path.join(dist, "index.html"), render(@site))
    File.cp!(Path.join([@site, "src", "copy.js"]), Path.join(dist, "copy.js"))

    for font <- File.ls!(@fonts),
        do: File.cp!(Path.join(@fonts, font), Path.join([dist, "fonts", font]))

    Mix.Task.run("tailwind", ["site", "--minify"])
    Mix.shell().info("Built #{dist}/")
  end

  @doc "The homepage's HTML, from the template and samples under `site`."
  @spec render(Path.t()) :: String.t()
  def render(site) do
    sections =
      for {id, title, sample, verdict} <- @sections do
        {id, title, read_escaped(site, ["samples", sample]),
         read_escaped(site, ["samples", "verdicts", verdict])}
      end

    EEx.eval_file(Path.join([site, "src", "index.html.eex"]),
      assigns: [
        version: Mix.Project.config()[:version],
        install_url: @install_url,
        sections: sections
      ]
    )
  end

  defp read_escaped(site, parts),
    do:
      [site | parts]
      |> Path.join()
      |> File.read!()
      |> String.trim_trailing()
      |> Plug.HTML.html_escape()
end

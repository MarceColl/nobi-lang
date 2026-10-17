defmodule Kinoko.Site.BuildTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Site.Build

  @samples ~w(counter.yabu store.yabu mistake.yabu session.txt)
  @verdicts ~w(counter.txt store.txt mistake.txt)

  # The page's text with its markup removed: the samples are highlighted
  # with spans, which must not change a character of them.
  defp visible(html), do: Regex.replace(~r/<[^>]*>/, html, "")

  defp read(path), do: path |> File.read!() |> String.trim_trailing()

  test "the page includes every sample, the session and each printed verdict verbatim" do
    html = Build.render("site")
    text = visible(html)

    for file <- @samples do
      sample = read("site/samples/#{file}")
      assert text =~ Plug.HTML.html_escape(sample), "the page lacks #{file}"
    end

    for file <- @verdicts, line <- String.split(read("site/samples/verdicts/#{file}"), "\n") do
      assert text =~ Plug.HTML.html_escape(line), "the page lacks #{file}: #{line}"
    end

    for line <- String.split(read("site/samples/verdicts/counter-cids.txt"), "\n") do
      [_, cid, symbol] = Regex.run(~r/^sha256 (\S+)  (\S+)$/, line)
      assert text =~ symbol
      assert text =~ "sha256 #{cid}"
    end

    assert html =~ ~s(data-copy="#install")

    # The release asset, which the release workflow stamps with the
    # repository; main's install.sh refuses to run.
    assert Build.install_url() =~
             ~r{^https://github\.com/[^/]+/[^/]+/releases/latest/download/install\.sh$}

    assert html =~ "curl -fsSL #{Build.install_url()} | bash"
    refute html =~ "raw.githubusercontent.com"
    assert html =~ Mix.Project.config()[:version]
  end

  test "the page loads nothing from another origin" do
    html = Build.render("site")

    for [_, url] <- Regex.scan(~r/(?:src|href)="([^"]+)"/, html),
        not String.starts_with?(url, ["#", "data:"]) do
      assert url =~ ~r/^[a-z0-9.\/-]+$/ or
               url =~ ~r{^https://github\.com/},
             "unexpected reference #{url}"
    end

    refute html =~ ~r/<link[^>]+href="https?:/
    refute html =~ ~r/<script[^>]+src="https?:/
  end

  @tag :tmp_dir
  test "the build writes the page, copy.js, every font, and CSS with relative font URLs",
       %{tmp_dir: dir} do
    dist = Path.join(dir, "dist")
    capture_io(fn -> Build.build("site", dist) end)

    assert File.exists?(Path.join(dist, "index.html"))
    assert File.read!(Path.join(dist, "copy.js")) == File.read!("site/src/copy.js")

    fonts = File.ls!("priv/static/fonts")
    assert Enum.any?(fonts, &String.ends_with?(&1, ".woff2"))

    for font <- fonts,
        do: assert(File.exists?(Path.join([dist, "fonts", font])), "dist lacks fonts/#{font}")

    css = File.read!(Path.join(dist, "site.css"))
    urls = Regex.scan(~r/url\(\s*["']?([^"')]+)/, css) |> Enum.map(&List.last/1)
    assert urls != []

    for url <- urls do
      assert String.starts_with?(url, "fonts/"),
             "site.css loads #{url}, not a relative fonts/ URL"

      assert File.exists?(Path.join(dist, url)), "site.css loads #{url}, which dist lacks"
    end
  end

  test "site.css carries the console's --k-* tokens unchanged" do
    tokens = fn path ->
      Regex.scan(~r/--k-[a-z0-9-]+:\s*[^;]+;/, File.read!(path)) |> List.flatten()
    end

    app = tokens.("assets/css/app.css")
    assert length(app) > 30
    assert tokens.("site/src/site.css") == app
  end
end

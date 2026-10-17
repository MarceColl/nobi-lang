defmodule Kinoko.Site.BuildTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Site.Build

  @run "site/samples/agent-run.jsonl"

  # The page's text with its markup removed: the samples are highlighted
  # with spans, which must not change a character of them.
  defp visible(html), do: html |> then(&Regex.replace(~r/<[^>]*>/, &1, "")) |> unescape()

  defp unescape(text) do
    Enum.reduce(
      [{"&quot;", ~s(")}, {"&#39;", "'"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&amp;", "&"}],
      text,
      fn {e, c}, t ->
        String.replace(t, e, c)
      end
    )
  end

  defp events do
    for line <- @run |> File.read!() |> String.split("\n", trim: true), do: Jason.decode!(line)
  end

  test "the page shows the counter sample verbatim and the install line from the release" do
    html = Build.render("site")
    text = visible(html)

    assert text =~ String.trim_trailing(File.read!("site/samples/counter.yabu"))
    assert html =~ ~s(data-copy="#install")
    assert html =~ ~s(data-copy="#mcp-add")

    # The release asset, which the release workflow stamps with the
    # repository; main's install.sh refuses to run.
    assert Build.install_url() =~
             ~r{^https://github\.com/[^/]+/[^/]+/releases/latest/download/install\.sh$}

    assert text =~ "curl -fsSL #{Build.install_url()} | sh"
    refute html =~ "raw.githubusercontent.com"
    assert html =~ Mix.Project.config()[:version]

    [major, minor | _] = String.split(Mix.Project.config()[:version], ".")
    assert text =~ "v#{major}.#{minor}. macOS and Linux."
  end

  test "the agent-run block is every Kinoko tool call of the recorded run, in order" do
    events = events()

    # A finished, successful run that refused nothing.
    assert %{"is_error" => false, "permission_denials" => []} =
             Enum.find(events, &(&1["type"] == "result"))

    recorded =
      for %{"type" => "assistant", "message" => %{"content" => content}} <- events,
          %{"type" => "tool_use", "name" => "mcp__kinoko__" <> name} <- content,
          do: name

    assert recorded != []
    %{calls: calls, summary: summary} = Build.agent_run(File.read!(@run))
    assert Enum.map(calls, & &1.name) == recorded

    text = "site" |> Build.render() |> visible()
    [block] = Regex.run(~r/What the agent did.*?The agent's summary/s, text)

    # One table row per call, the tool name first.
    [tbody] =
      Regex.run(~r{<tbody[^>]*>(.*?)</tbody>}s, Build.render("site"), capture: :all_but_first)

    shown =
      for line <- String.split(tbody, "\n"),
          row = String.trim(visible(line)),
          row != "",
          do: row |> String.split(" ") |> hd()

    assert shown == recorded
    assert block =~ "promoted: "
    assert text =~ unescape(summary)

    # The deployment the agent created, and the URL the page says it serves at.
    assert "create_deployment" in recorded
    assert block =~ "http://forum.localhost:4123/"
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
    assert File.read!(Path.join(dist, "forum.webp")) == File.read!("site/src/forum.webp")

    fonts = File.ls!("site/fonts")
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
end

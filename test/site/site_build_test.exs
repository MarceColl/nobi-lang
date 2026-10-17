defmodule Kinoko.Site.BuildTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Site.Build

  @samples ~w(counter.yabu store.yabu mistake.yabu)

  test "the page includes every sample and its printed verdict verbatim (HTML-escaped)" do
    html = Build.render("site")

    for file <- @samples ++ Enum.map(~w(counter store mistake), &"verdicts/#{&1}.txt") do
      text = "site/samples/#{file}" |> File.read!() |> String.trim_trailing()
      assert html =~ Plug.HTML.html_escape(text), "the page lacks #{file}"
    end

    assert html =~ ~s(data-copy="#install")
    assert html =~ Mix.Project.config()[:version]
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

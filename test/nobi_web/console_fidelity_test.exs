defmodule NobiWeb.ConsoleFidelityTest do
  @moduledoc """
  Static contracts for the Vellum console's measured values (Task 7 fidelity
  pass, `docs/design/nobi-vellum/Kinoko Vellum.dc.html`). Each value was
  measured in headless Chrome against the prototype; these pin the classes
  and ids that produce it, so a refactor that drifts from the design fails
  here rather than in a screenshot.
  """
  use NobiWeb.ConnCase, async: false

  import Bitwise
  import Phoenix.LiveViewTest
  import Nobi.UniverseHelpers

  alias Nobi.{Data, Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/nobi/forum.nobi")

  # The forum universe, deployed under its own name, with two topics stored.
  defp seeded do
    u = fresh_universe("fid")
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    :ok = Deployment.create(u, u, "Forum")
    {:ok, models} = Universe.models(u)
    {:ok, repo} = Data.open(u)

    for t <- ["Lift passes", "Groceries"] do
      {:ok, _} =
        Data.insert(
          repo,
          "Forum.Topic",
          models,
          {:rec, "Forum.Topic", %{"title" => t, "replies" => 1}}
        )
    end

    u
  end

  # Every console screen the pass measured, rendered.
  defp screens(conn, u) do
    pages =
      for path <- [
            "/_",
            "/_/u/#{u}?sel=Forum.Threads",
            "/_/u/#{u}?sel=Forum.Topic",
            "/_/u/#{u}?view=code&sym=Forum.Threads.update",
            "/_/u/#{u}?view=data&store=Forum.Topic",
            "/_/d/#{u}"
          ] do
        {:ok, view, _} = live(conn, path)
        {path, render(view)}
      end

    {:ok, view, _} = live(conn, "/_/u/#{u}")
    palette = view |> element("#cmd-open") |> render_click()
    {:ok, view, _} = live(conn, "/_/u/#{u}")
    intro = view |> element("#intro-open") |> render_click()
    pages ++ [{"palette", palette}, {"intro", intro}]
  end

  defp classes(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split()
  end

  defp assert_classes(view, selector, wanted) do
    got = classes(view, selector)
    missing = wanted -- got
    assert missing == [], "#{selector} lacks #{inspect(missing)}; has #{inspect(got)}"
  end

  defp all_classes(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("[class]") |> LazyHTML.attribute("class")
  end

  @mono "font-(family-name:--k-mono)"
  @display "font-(family-name:--k-display)"
  @label ["text-[10.5px]", "tracking-[.11em]", "uppercase", "text-(--k-faint)"]

  describe "shell frame" do
    test "top bar, sidebar, title bar, REPL bar and root at the prototype's sizes and colours",
         %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      # #1B1A17 ink on #F2F1EC paper, Chivo.
      assert_classes(view, "#console", [
        "k-console",
        "h-screen",
        "font-(family-name:--k-sans)",
        "text-(--k-ink)",
        "bg-(--k-paper)",
        "[color-scheme:light]"
      ])

      # 46px, white, 1px #DDDAD1 bottom rule.
      assert_classes(view, "#console-topbar", [
        "h-[46px]",
        "bg-white",
        "border-b",
        "border-(--k-line)"
      ])

      # 230px on #EDEBE4.
      assert_classes(view, "#console-sidebar", [
        "w-[230px]",
        "bg-(--k-sand)",
        "border-r",
        "border-(--k-line)"
      ])

      # 42px on #F7F6F2.
      assert_classes(view, "#console-titlebar", [
        "h-[42px]",
        "bg-(--k-tint)",
        "border-b",
        "border-(--k-line)"
      ])

      # 38px white input bar under a #EAE7DE rule; mono 12.5 input.
      assert_classes(view, "#repl-form", [
        "h-[38px]",
        "bg-white",
        "border-t",
        "border-(--k-row-line)"
      ])

      assert_classes(view, "#repl-input", [@mono, "text-[12.5px]"])
    end

    test "sidebar section labels are 10.5px, .11em, uppercase, faint", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      labels =
        view
        |> element("#console-sidebar")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".uppercase")

      texts = labels |> Enum.map(&LazyHTML.text/1) |> Enum.map(&String.trim/1)
      assert "Deployments" in texts
      assert "Environments" in texts

      for class <- LazyHTML.attribute(labels, "class") do
        assert @label -- String.split(class) == [], "section label class #{class}"
      end
    end

    test "names are set in IBM Plex Mono", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/u/#{u}?sel=Forum.Threads")

      assert_classes(view, "#crumb-universe", [@mono, "text-[12.5px]", "font-medium"])
      assert_classes(view, "#sidebar-env-#{u} > span:nth-child(2)", [@mono, "text-[12px]"])
      assert_classes(view, "#node-Forum-Threads span.font-medium", [@mono, "text-[12px]"])
      assert_classes(view, "#node-Forum-Topic span.font-medium", [@mono, "text-[12px]"])
    end
  end

  describe "stages" do
    test "the inspector is 326px on the tint", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/u/#{u}?sel=Forum.Threads")
      assert_classes(view, "#console-inspector", ["w-[326px]", "bg-(--k-tint)", "border-l"])
    end

    test "the canvas is paper with #D7D3C8 dots every 26px", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      assert_classes(view, "#graph-canvas", [
        "bg-(--k-paper)",
        "bg-[radial-gradient(var(--k-grid-dots)_1px,transparent_1px)]",
        "bg-size-[26px_26px]"
      ])
    end

    test "Home and Deployment titles are Newsreader 25px/500", %{conn: conn} do
      u = seeded()
      {:ok, home, _} = live(conn, "/_")
      assert_classes(home, "#home-title", [@display, "text-[25px]", "font-medium"])

      {:ok, dep, _} = live(conn, "/_/d/#{u}")
      assert_classes(dep, "#deployment-name", [@display, "text-[25px]", "font-medium"])
    end

    test "deployment table cells carry one size and one colour each", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      # Prototype `deploymentStage` cells: name mono 12, faint mono 11.5 detail.
      assert_classes(view, "#dep-model-Forum\\.Topic > span:nth-child(1)", [@mono, "text-[12px]"])

      assert_classes(view, "#dep-model-Forum\\.Topic > span.dep-columns", [
        @mono,
        "text-[11.5px]",
        "text-(--k-faint)"
      ])

      assert_classes(view, "#dep-ver-1 > span:nth-child(2)", [
        @mono,
        "text-[11.5px]",
        "text-(--k-faint)"
      ])

      assert_classes(view, "#dep-ver-1 > span:nth-child(4)", ["text-[11.5px]", "font-medium"])
      refute "text-[12.5px]" in classes(view, "#dep-ver-1 > span:nth-child(4)")
    end

    test "deployment rows rule only between rows, never under the head", %{conn: conn} do
      u = seeded()
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      for row <- ["#dep-ver-1", "#dep-route-0", "#dep-model-Forum\\.Topic"] do
        got = classes(view, row)
        assert "dep-row" in got and "[.dep-row+&]:border-t" in got, "#{row}: #{inspect(got)}"
        refute "border-t" in got, "#{row} rules its top unconditionally"
      end
    end
  end

  describe "every screen" do
    test "no rose/zinc, rounded-xl, shadow-sm or dark: classes", %{conn: conn} do
      u = seeded()

      for {page, html} <- screens(conn, u),
          class <- all_classes(html),
          token <- String.split(class) do
        refute token =~ ~r/(^|[:-])(rose|zinc)-\d|^rounded-xl$|^shadow-sm$|(^|:)dark:/,
               "#{page}: #{token}"
      end
    end

    test "no element stacks two sizes, text colours, families, weights or backgrounds",
         %{conn: conn} do
      u = seeded()

      kinds = [
        size: ~r/^text-\[\d+(\.\d+)?px\]$|^text-(xs|sm|base|lg|\dxl|xl)$/,
        colour: ~r/^text-\(--[\w-]+\)$|^text-\[#\h+\]$|^text-(white|black)$/,
        family: ~r/^font-\(family-name/,
        weight: ~r/^font-(thin|light|normal|medium|semibold|bold)$/,
        bg: ~r/^bg-\(--[\w-]+\)$|^bg-\[#\h+\]$|^bg-(white|transparent)$/
      ]

      for {page, html} <- screens(conn, u), class <- all_classes(html), {kind, re} <- kinds do
        hits = class |> String.split() |> Enum.filter(&(&1 =~ re))
        assert length(hits) <= 1, "#{page}: stacked #{kind} #{inspect(hits)} in #{class}"
      end
    end
  end

  describe "assets" do
    @css File.read!("assets/css/app.css")

    test "a console page is light paper even when the OS asks for dark" do
      assert @css =~
               ":root:has(.k-console) { background: var(--k-paper); color: var(--k-ink); color-scheme: light; }"
    end

    test "every @font-face declaring a weight range serves a variable (fvar) font" do
      faces = Regex.scan(~r/@font-face\s*\{(.*?)\}/s, @css, capture: :all_but_first)
      assert faces != []

      for [face] <- faces, [_, lo, hi] <- Regex.scan(~r/font-weight:\s*(\d+)\s+(\d+);/, face) do
        [_, file] = Regex.run(~r{url\("/fonts/([^"]+)"\)}, face)
        tags = woff2_tags(File.read!("priv/static/fonts/#{file}"))
        assert "fvar" in tags, "#{file} declares #{lo}..#{hi} but is static: faux bold"
      end
    end
  end

  # WOFF2 table directory (W3C WOFF2 §5.2): tags only, from the uncompressed header.
  # Index i of the known-tag table; "_" stands for a trailing space.
  @known ~w(cmap head hhea hmtx maxp name OS/2 post cvt_ fpgm glyf loca prep CFF_ VORG EBDT
            EBLC gasp hdmx kern LTSH PCLT VDMX vhea vmtx BASE GDEF GPOS GSUB EBSC JSTF MATH CBDT CBLC COLR CPAL SVG_ sbix acnt avar
            bdat bloc bsln cvar fdsc feat fmtx fvar gvar hsty just lcar mort morx opbd prop trak Zapf Silf Glat Gloc Feat Sill)
         |> Enum.map(&String.replace(&1, "_", " "))

  defp woff2_tags(<<"wOF2", _flavor::32, _len::32, n::16, _::binary-size(34), dir::binary>>),
    do: dir_tags(dir, n, [])

  defp dir_tags(_dir, 0, acc), do: Enum.reverse(acc)

  defp dir_tags(<<flags, rest::binary>>, n, acc) do
    {tag, rest} =
      case flags &&& 0x3F do
        63 ->
          <<t::binary-size(4), r::binary>> = rest
          {t, r}

        i ->
          {Enum.at(@known, i), rest}
      end

    rest = skip_base128(rest)
    version = flags >>> 6 &&& 3
    transformed? = if tag in ["glyf", "loca"], do: version == 0, else: version != 0
    rest = if transformed?, do: skip_base128(rest), else: rest
    dir_tags(rest, n - 1, [tag | acc])
  end

  defp skip_base128(<<1::1, _::7, rest::binary>>), do: skip_base128(rest)
  defp skip_base128(<<0::1, _::7, rest::binary>>), do: rest
end

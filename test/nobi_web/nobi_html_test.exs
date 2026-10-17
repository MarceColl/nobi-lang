defmodule NobiWeb.NobiHtmlTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias NobiWeb.NobiHtml

  defp el(tag, attrs \\ [], children \\ []),
    do: {:var, "Html", "Element", [tag, attrs, children]}

  defp txt(s), do: {:var, "Html", "Text", [s]}

  defp render(html) do
    {tree, handlers} = NobiHtml.prepare(html)
    assigns = %{tree: tree}

    doc =
      rendered_to_string(~H"<NobiHtml.nobi_html tree={@tree} />")
      |> LazyHTML.from_fragment()

    {doc, handlers}
  end

  defp attr(doc, sel, name), do: doc |> LazyHTML.query(sel) |> LazyHTML.attribute(name)

  test "allow-listed attributes pass, others are dropped" do
    {doc, _} =
      render(
        el("div", [{"class", "a"}, {"id", "x"}, {"style", "color:red"}, {"aria-label", "l"}])
      )

    assert attr(doc, "div", "class") == ["a"]
    assert attr(doc, "div", "id") == ["x"]
    assert attr(doc, "div", "aria-label") == ["l"]
    assert attr(doc, "div", "style") == []
  end

  test "phx-* and on* plain attributes are dropped" do
    {doc, handlers} =
      render(
        el("div", [
          {"phx-click", "evil"},
          {"onclick", "x()"},
          {"onerror", "x()"},
          {"phx-value-h", "r0.e9"}
        ])
      )

    assert attr(doc, "div", "phx-click") == []
    assert attr(doc, "div", "onclick") == []
    assert attr(doc, "div", "phx-value-h") == []
    assert handlers == %{}
  end

  test "href/src: javascript: and data: are dropped, http/https/relative kept" do
    for bad <- ["javascript:alert(1)", " JaVa\tScript:alert(1)", "data:text/html,x", "vbscript:x"] do
      {doc, _} = render(el("a", [{"href", bad}]))
      assert attr(doc, "a", "href") == [], bad
    end

    for ok <- ["http://a.b/c", "https://a.b", "/post/1", "rel/path", "#frag", "?q=1"] do
      {doc, _} = render(el("a", [{"href", ok}]))
      assert attr(doc, "a", "href") == [ok]
    end

    {doc, _} = render(el("img", [{"src", "javascript:x"}]))
    assert attr(doc, "img", "src") == []
  end

  test "text and attribute values are escaped; script text is inert" do
    {doc, _} =
      render(el("p", [{"title", ~s(" onmouseover="x)}], [txt("<script>alert(1)</script>")]))

    assert LazyHTML.query(doc, "script") |> Enum.count() == 0
    assert LazyHTML.text(doc) =~ "<script>alert(1)</script>"
    assert attr(doc, "p", "title") == [~s(" onmouseover="x)]
    assert attr(doc, "p", "onmouseover") == []
  end

  test "disallowed tags render as nothing, children included" do
    for tag <- ~w(script style iframe object embed link meta base) do
      {doc, _} = render(el("div", [], [el(tag, [], [txt("boom")]), txt("ok")]))
      assert LazyHTML.query(doc, tag) |> Enum.count() == 0
      refute LazyHTML.text(doc) =~ "boom"
      assert LazyHTML.text(doc) =~ "ok"
    end
  end

  test "form action is dropped" do
    {doc, _} = render(el("form", [{"action", "https://evil.example"}]))
    assert attr(doc, "form", "action") == []
  end

  test "values are coerced; boolean attributes present or absent" do
    {doc, _} =
      render(
        el("input", [
          {"rows", 3},
          {"value", {:uuid, "abc"}},
          {"checked", true},
          {"disabled", false},
          {"maxlength", {:var, "O", "V", []}}
        ])
      )

    assert attr(doc, "input", "rows") == ["3"]
    assert attr(doc, "input", "value") == ["abc"]
    assert LazyHTML.query(doc, "input[checked]") |> Enum.count() == 1
    assert LazyHTML.query(doc, "input[disabled]") |> Enum.count() == 0
    assert attr(doc, "input", "maxlength") == []
  end

  # The checker (Nobi.Lang.Types.JsxApp.events/0) accepts exactly the
  # events this renderer wires, on exactly the tags it wires them on.
  test "every event the checker accepts is wired here, on its tags; no other is" do
    msg = {:var, "T.Msg", "Go", []}
    fun = fn s -> {:var, "T.Msg", "Set", [s]} end
    all_tags = ~w(div button form input textarea select a)

    for {event, tags} <- Nobi.Lang.Types.JsxApp.events(), tag <- all_tags do
      value = if event == "change", do: fun, else: msg
      {_doc, handlers} = render(el(tag, [{"on-" <> event, value}]))
      wired? = handlers != %{}
      expected = tags == :any or tag in tags
      assert wired? == expected, "on-#{event} on <#{tag}>: wired #{wired?}, checker #{expected}"
    end

    # A form inside a form: its on-submit is not wired (the checker refuses it).
    inner = el("form", [{"on-submit", msg}])
    assert elem(render(el("form", [], [el("div", [], [inner])])), 1) == %{}

    for event <- ~w(input dblclick mouseover change2),
        do: assert(elem(render(el("input", [{"on-" <> event, msg}])), 1) == %{})
  end

  test "on-click becomes phx-click=nobi:click with phx-value-click" do
    msg = {:var, "Todo.Msg", "Toggle", [{:uuid, "u1"}]}
    {doc, handlers} = render(el("button", [{"on-click", msg}], [txt("go")]))

    assert attr(doc, "button", "phx-click") == ["nobi:click"]
    assert attr(doc, "button", "phx-value-click") == ["r0.e0"]
    assert handlers == %{"r0.e0" => {:click, msg}}
  end

  test "standalone on-change gets a minimal form wrapper, named nobi[id]" do
    fun = fn s -> {:var, "T.Msg", "Set", [s]} end
    {doc, handlers} = render(el("input", [{"value", "v"}, {"on-change", fun}]))

    assert attr(doc, "form", "phx-change") == ["nobi:change"]
    assert attr(doc, "form input", "name") == ["nobi[r0.e0]"]
    assert attr(doc, "form input", "value") == ["v"]
    assert LazyHTML.query(doc, "input[type=hidden]") |> Enum.count() == 0
    assert handlers == %{"r0.e0" => {:change, fun}}
  end

  test "on-change inside a form: no wrapper, the form gets phx-change" do
    {doc, handlers} =
      render(
        el("form", [], [
          el("input", [{"on-change", fn s -> s end}]),
          el("textarea", [{"on-change", fn s -> s end}])
        ])
      )

    assert LazyHTML.query(doc, "form") |> Enum.count() == 1
    assert attr(doc, "form", "phx-change") == ["nobi:change"]
    assert attr(doc, "input", "name") == ["nobi[r0.e0]"]
    assert attr(doc, "textarea", "name") == ["nobi[r0.e1]"]
    assert Map.keys(handlers) == ["r0.e0", "r0.e1"]
  end

  test "on-change inside an on-submit form: one form, both bindings" do
    {doc, handlers} =
      render(el("form", [{"on-submit", :go}], [el("input", [{"on-change", fn s -> s end}])]))

    assert LazyHTML.query(doc, "form") |> Enum.count() == 1
    assert attr(doc, "form", "phx-submit") == ["nobi:submit"]
    assert attr(doc, "form", "phx-change") == ["nobi:change"]
    assert attr(doc, "form input[name=nobi_submit]", "value") == ["r0.e0"]
    assert attr(doc, "form input[name='nobi[r0.e1]']", "name") == ["nobi[r0.e1]"]
    assert handlers["r0.e0"] == {:submit, :go}
  end

  test "on-submit puts its id in the nobi_submit hidden field" do
    {doc, handlers} = render(el("form", [{"on-submit", :msg}], [el("button", [], [txt("x")])]))
    assert attr(doc, "form", "phx-submit") == ["nobi:submit"]
    assert attr(doc, "form", "phx-change") == []
    assert attr(doc, "form input[type=hidden]", "name") == ["nobi_submit"]
    assert attr(doc, "form input[type=hidden]", "value") == ["r0.e0"]
    assert handlers == %{"r0.e0" => {:submit, :msg}}
  end

  test "attribute names are validated strictly" do
    bad = [
      "aria-x onclick=alert(1);x",
      "aria-x\nonclick",
      "aria-x=\"y",
      "data-x onclick=1",
      "data-phx-click",
      "data-nobi-submit",
      "data-",
      "aria-",
      "formaction",
      "srcdoc",
      "xlink:href",
      "class onclick=1"
    ]

    for name <- bad do
      {doc, _} = render(el("div", [{name, "1"}]))
      assert doc |> LazyHTML.query("div") |> LazyHTML.attributes() == [[]], inspect(name)
    end

    {doc, _} = render(el("div", [{"aria-label", "l"}, {"data-foo-1", "d"}]))
    assert attr(doc, "div", "aria-label") == ["l"]
    assert attr(doc, "div", "data-foo-1") == ["d"]
  end

  test "invalid UTF-8 in href/src is dropped, not raised" do
    {doc, _} = render(el("a", [{"href", <<0xFF, 0xFE>>}, {"title", <<0xFF>>}]))
    assert attr(doc, "a", "href") == []
    assert attr(doc, "a", "title") == []
  end

  test "no whitespace leaks into textarea or pre" do
    {doc, _} = render(el("textarea", [], [txt("hi")]))
    assert LazyHTML.text(LazyHTML.query(doc, "textarea")) == "hi"
    {doc, _} = render(el("pre", [], [txt("a"), txt("b")]))
    assert LazyHTML.text(LazyHTML.query(doc, "pre")) == "ab"
  end

  test "svg tags are not allowed" do
    {doc, _} = render(el("div", [], [el("svg", [], [el("path")])]))
    assert LazyHTML.query(doc, "svg") |> Enum.count() == 0
  end

  test "duplicate user names on an on-change element are all replaced" do
    {doc, _} =
      render(el("input", [{"name", "a"}, {"name", "b"}, {"on-change", fn s -> s end}]))

    assert attr(doc, "input", "name") == ["nobi[r0.e0]"]
  end

  test "several simple events on one element keep separate ids" do
    {doc, handlers} = render(el("input", [{"on-click", :c}, {"on-blur", :b}]))
    assert attr(doc, "input", "phx-value-click") == ["r0.e0"]
    assert attr(doc, "input", "phx-value-blur") == ["r0.e1"]
    assert attr(doc, "input", "phx-click") == ["nobi:click"]
    assert attr(doc, "input", "phx-blur") == ["nobi:blur"]
    assert handlers == %{"r0.e0" => {:click, :c}, "r0.e1" => {:blur, :b}}
  end

  test "a form nested in a form renders as a div; one outer binding set" do
    inner = el("form", [{"on-submit", :inner}], [el("input", [{"on-change", fn s -> s end}])])
    {doc, handlers} = render(el("form", [{"on-submit", :outer}], [inner]))

    assert LazyHTML.query(doc, "form") |> Enum.count() == 1
    assert LazyHTML.query(doc, "input[name=nobi_submit]") |> Enum.count() == 1
    assert attr(doc, "form", "phx-change") == ["nobi:change"]
    assert LazyHTML.query(doc, "form > div > input[name='nobi[r0.e1]']") |> Enum.count() == 1
    assert Map.has_key?(handlers, "r0.e0") and match?({:change, _}, handlers["r0.e1"])
    refute Enum.any?(Map.values(handlers), &(&1 == {:submit, :inner}))
  end

  test "reserved names and phx- ids are dropped" do
    for n <- ["nobi", "nobi_submit", "_target", "h", "nobi[r0.e0]", "nobi_x"] do
      {doc, _} = render(el("input", [{"name", n}]))
      assert attr(doc, "input", "name") == [], n
    end

    {doc, _} = render(el("div", [{"id", "phx-F123"}]))
    assert attr(doc, "div", "id") == []
    {doc, _} = render(el("div", [{"id", "ok"}]))
    assert attr(doc, "div", "id") == ["ok"]
  end

  test "unknown events and mistyped handlers are ignored" do
    {_doc, handlers} =
      render(el("div", [{"on-mouseover", :m}, {"on-click", fn x -> x end}, {"on-change", :m}]))

    assert handlers == %{}
  end

  test "nested elements render and handler ids are in render order and stable" do
    tree =
      el("ul", [], [
        el("li", [{"on-click", :a}], [el("span", [{"on-click", :b}], [txt("x")])]),
        el("li", [{"on-click", :c}])
      ])

    {t1, h1} = NobiHtml.prepare(tree)
    {t2, h2} = NobiHtml.prepare(tree)
    assert {t1, h1} == {t2, h2}
    assert h1 == %{"r0.e0" => {:click, :a}, "r0.e1" => {:click, :b}, "r0.e2" => {:click, :c}}

    {doc, _} = render(tree)
    assert attr(doc, "ul > li:first-child > span", "phx-value-click") == ["r0.e1"]
    assert attr(doc, "ul > li:last-child", "phx-value-click") == ["r0.e2"]
  end

  test "void elements render without children" do
    {doc, _} = render(el("div", [], [el("br"), el("hr"), el("img", [{"src", "/a.png"}])]))
    assert LazyHTML.query(doc, "br") |> Enum.count() == 1
    assert attr(doc, "img", "src") == ["/a.png"]
  end

  test "prepared tree contains no Nobi terms" do
    {tree, _} = NobiHtml.prepare(el("div", [{"on-click", {:var, "A", "B", []}}], [txt("x")]))
    refute inspect(tree) =~ ":var"
  end

  test "handler ids carry the render number they were prepared for" do
    tree = el("div", [], [el("button", [{"on-click", :a}]), el("button", [{"on-blur", :b}])])
    {_tree, handlers} = NobiHtml.prepare(tree, 7)
    assert handlers == %{"r7.e0" => {:click, :a}, "r7.e1" => {:blur, :b}}

    {t7, _} = NobiHtml.prepare(tree, 7)
    {t8, _} = NobiHtml.prepare(tree, 8)
    assert inspect(t7) =~ "r7.e0" and inspect(t8) =~ "r8.e0"
  end

  test "every form gets phx-submit, so Enter is never a native submit" do
    {doc, handlers} = render(el("input", [{"on-change", fn s -> s end}]))
    assert attr(doc, "form", "phx-submit") == ["nobi:submit"]
    assert LazyHTML.query(doc, "input[name=nobi_submit]") |> Enum.count() == 0
    assert map_size(handlers) == 1

    {doc, _} = render(el("form", [], [el("input", [{"on-change", fn s -> s end}])]))
    assert attr(doc, "form", "phx-submit") == ["nobi:submit"]
    assert attr(doc, "form", "phx-change") == ["nobi:change"]
    assert LazyHTML.query(doc, "input[name=nobi_submit]") |> Enum.count() == 0

    {doc, _} = render(el("form", [], [el("input", [{"name", "q"}])]))
    assert attr(doc, "form", "phx-submit") == ["nobi:submit"]
  end

  test "ids in the host's nobi- namespace are dropped" do
    for id <- ["nobi-error", "Nobi-notice", "PHX-x"] do
      {doc, _} = render(el("div", [{"id", id}]))
      assert attr(doc, "div", "id") == [], id
    end
  end
end

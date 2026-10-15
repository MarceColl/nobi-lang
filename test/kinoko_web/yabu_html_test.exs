defmodule KinokoWeb.YabuHtmlTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KinokoWeb.YabuHtml

  defp el(tag, attrs \\ [], children \\ []),
    do: {:var, "Html", "Element", [tag, attrs, children]}

  defp txt(s), do: {:var, "Html", "Text", [s]}

  defp render(html) do
    {tree, handlers} = YabuHtml.prepare(html)
    assigns = %{tree: tree}

    doc =
      rendered_to_string(~H"<YabuHtml.yabu_html tree={@tree} />")
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
          {"phx-value-h", "e9"}
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

  test "on-click becomes phx-click=yabu with phx-value-h" do
    msg = {:var, "Todo.Msg", "Toggle", [{:uuid, "u1"}]}
    {doc, handlers} = render(el("button", [{"on-click", msg}], [txt("go")]))

    assert attr(doc, "button", "phx-click") == ["yabu"]
    assert attr(doc, "button", "phx-value-h") == ["e0"]
    assert handlers == %{"e0" => msg}
  end

  test "on-change wraps the input in its own phx-change form carrying h" do
    fun = fn s -> {:var, "T.Msg", "Set", [s]} end
    {doc, handlers} = render(el("input", [{"value", "v"}, {"on-change", fun}]))

    assert attr(doc, "form", "phx-change") == ["yabu"]
    assert attr(doc, "form input[type=hidden]", "name") == ["h"]
    assert attr(doc, "form input[type=hidden]", "value") == ["e0"]
    assert attr(doc, "form input:not([type=hidden])", "name") == ["value"]
    assert attr(doc, "form input:not([type=hidden])", "value") == ["v"]
    assert handlers == %{"e0" => {:change, fun}}
  end

  test "on-submit puts h in a hidden field" do
    {doc, handlers} = render(el("form", [{"on-submit", :msg}], [el("button", [], [txt("x")])]))
    assert attr(doc, "form", "phx-submit") == ["yabu"]
    assert attr(doc, "form input[type=hidden]", "value") == ["e0"]
    assert handlers == %{"e0" => :msg}
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

    {t1, h1} = YabuHtml.prepare(tree)
    {t2, h2} = YabuHtml.prepare(tree)
    assert {t1, h1} == {t2, h2}
    assert h1 == %{"e0" => :a, "e1" => :b, "e2" => :c}

    {doc, _} = render(tree)
    assert attr(doc, "ul > li:first-child > span", "phx-value-h") == ["e1"]
    assert attr(doc, "ul > li:last-child", "phx-value-h") == ["e2"]
  end

  test "void elements render without children" do
    {doc, _} = render(el("div", [], [el("br"), el("hr"), el("img", [{"src", "/a.png"}])]))
    assert LazyHTML.query(doc, "br") |> Enum.count() == 1
    assert attr(doc, "img", "src") == ["/a.png"]
  end

  test "prepared tree contains no Yabu terms" do
    {tree, _} = YabuHtml.prepare(el("div", [{"on-click", {:var, "A", "B", []}}], [txt("x")]))
    refute inspect(tree) =~ ":var"
  end
end

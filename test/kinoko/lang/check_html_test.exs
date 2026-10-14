defmodule Kinoko.Lang.CheckHtmlTest do
  @moduledoc """
  The checker's `Html<m>`, against the Rust crate's `tests/types_html.rs`:
  what an element's events send, agreed on by its children and its app's
  view. TS's `Html` takes no parameter; every case here is Rust-only.
  """
  use ExUnit.Case, async: true

  import Kinoko.Lang.CheckHelpers

  alias Kinoko.Lang.Ast
  alias Kinoko.Lang.Types.Extract

  # App `app` whose view's body is `view`, with `extra` declared before the
  # view: `{app}.Msg` is `Go | Set(String)`, and `O.Msg`, `Stop |
  # Put(String)`, is the messages of no app.
  defp html_app(app, extra, view) do
    """
    defmodel #{app}.Model do n : Int end
    deftype #{app}.Msg do Go | Set(String) end
    deftype O.Msg do Stop | Put(String) end
    def #{app}.init() : (#{app}.Model, Cmd<#{app}.Msg>) do (%#{app}.Model{n: 0}, Cmd.none()) end
    def #{app}.update(msg : #{app}.Msg, model : #{app}.Model) : (#{app}.Model, Cmd<#{app}.Msg>) do (model, Cmd.none()) end
    #{extra}def #{app}.view(model : #{app}.Model) : Html<#{app}.Msg> do #{view} end
    defapp #{app}
    """
  end

  defp mismatch(expected, got, quoted),
    do: [{"mismatch", "type mismatch: expected #{expected}, got #{got} in `#{quoted}`"}]

  defp errors_of(checked, name) do
    case checked[name].result do
      {:ok, _} -> []
      {:error, errs} -> Enum.map(errs, &{&1.code, &1.message})
    end
  end

  test "an element that sends nothing fits any app" do
    assert lone_types("<p>hi</p>") == {:ok, ["Html<a>"]}
    assert lone_types("<button on-click={Option.None}>x</button>") == {:ok, ["Html<Option<a>>"]}
    all_ok(html_app("M", "", "<p>hi</p>"))
    all_ok(html_app("Q", "", "<p>hi</p>"))
    open = "def A.f() : Int do\n  x = <p>hi</p>\n  1\nend"
    assert found(open) == [{"cannot-infer", "cannot infer the type of `<p>hi</p>`"}]
  end

  test "an Html of any message is not data" do
    field = "model field `h` cannot hold `Html<Int>` — a view is not data to store"
    assert found("defmodel A.M do h : Html<Int> end") == [{"invalid-model-field", field}]

    key =
      first_error("deftype A.Msg do Go end\ndef A.f(m : Map<Html<A.Msg>, Int>) : Int do 0 end")

    assert key.code == "non-data-map-key"
  end

  test "a view sending another deftype's message is a mismatch" do
    view = "<div><button on-click={O.Msg.Stop}>x</button></div>"
    quoted = "<div>\n  <button on-click={O.Msg.Stop}>x</button>\n</div>"
    assert found(html_app("M", "", view)) == mismatch("Html<M.Msg>", "Html<O.Msg>", quoted)
    view = "<button on-click={M.Msg.Go} on-blur={O.Msg.Stop}>x</button>"
    assert found(html_app("M", "", view)) == mismatch("M.Msg", "O.Msg", "O.Msg.Stop")
    all_ok(html_app("M", "", "<div><button on-click={M.Msg.Go}>x</button></div>"))
  end

  test "children sending different messages are refused" do
    nested = "<div><b on-click={M.Msg.Go}>a</b><i on-click={O.Msg.Stop}>b</i></div>"
    quoted = "<i on-click={O.Msg.Stop}>b</i>"
    assert found(html_app("M", "", nested)) == mismatch("Html<M.Msg>", "Html<O.Msg>", quoted)

    helpers = """
    def M.go() : Html<M.Msg> do <b on-click={M.Msg.Go}>go</b> end
    def M.stop() : Html<O.Msg> do <b on-click={O.Msg.Stop}>stop</b> end
    """

    view = "<div>{M.go()}{M.stop()}</div>"

    assert found(html_app("M", helpers, view)) ==
             mismatch("Html<M.Msg>", "Html<O.Msg>", "M.stop()")
  end

  test "a list child agrees with its parent" do
    items =
      "<ul on-click={M.Msg.Go}>{List.map([1], fn (i : Int) -> <li on-click={M.Msg.Go}>x</li> end)}</ul>"

    all_ok(html_app("M", "", items))
    helper = "def M.items() : List<Html<O.Msg>> do [<li on-click={O.Msg.Stop}>x</li>] end\n"
    view = "<ul on-click={M.Msg.Go}>{M.items()}</ul>"

    assert found(html_app("M", helper, view)) ==
             mismatch("List<Html<M.Msg>>", "List<Html<O.Msg>>", "M.items()")
  end

  test "on-change with another deftype's constructor is refused" do
    view = "<input on-change={O.Msg.Put} />"
    assert found(html_app("M", "", view)) == mismatch("Html<M.Msg>", "Html<O.Msg>", view)
    view = "<input on-click={M.Msg.Go} on-change={O.Msg.Put} />"
    assert found(html_app("M", "", view)) == mismatch("M.Msg", "O.Msg", "O.Msg.Put")
    all_ok(html_app("M", "", "<input on-change={M.Msg.Set} />"))
  end

  test "bare Html is an arity error" do
    arity = fn src ->
      e = first_error(src)
      {e.code, e.message}
    end

    bare =
      {"arity",
       "type `Html` expects 1 parameter(s): the type of the messages it sends, as in `Html<App.Msg>`"}

    assert arity.("def A.f() : Html do <p>hi</p> end") == bare
    assert arity.("def A.f(h : Html) : Int do 1 end") == bare
    assert arity.("def A.f() : Int do\n  x = (<p>hi</p> : Html)\n  1\nend") == bare
    assert arity.("defmodel A.M do h : Html end") == bare
    two = {"arity", "type `Html` expects 1 parameter(s), got 2"}
    assert arity.("def A.f() : Html<Int, Int> do <p>hi</p> end") == two
  end

  test "a bare Html is one error, not three" do
    bare = [
      {"arity",
       "type `Html` expects 1 parameter(s): the type of the messages it sends, as in `Html<App.Msg>`"}
    ]

    app =
      html_app("M", "", "<div>{model.n}</div>")
      |> String.replace(": Html<M.Msg> do", ": Html do")

    checked = check_all(app)
    assert errors_of(checked, "M.view") == bare
    assert errors_of(checked, "M") == []
    child = "deftype A.Msg do Go end\ndef A.f(h : Html) : Html<A.Msg> do <div>{h}</div> end"
    assert errors_of(check_all(child), "A.f") == bare
  end

  test "a helper returning the app's Html is used in its view" do
    helper =
      "def M.button(label : String) : Html<M.Msg> do <button on-click={M.Msg.Go}>{label}</button> end\n"

    all_ok(html_app("M", helper, ~S|<div>{M.button("go")}</div>|))
  end

  test "a view returns its app's Html and depends on its message type" do
    src = html_app("M", "", "<p>hi</p>")
    view = Enum.find(parse(src), &(Ast.name(&1) == "M.view"))
    assert sorted(check_all(src)["M.view"].deps) == ["M.Model", "M.Msg"]
    assert MapSet.member?(Extract.deps(view), "M.Msg")

    other = String.replace(src, ": Html<M.Msg> do", ": Html<O.Msg> do")

    assert errors_of(check_all(other), "M") |> Enum.take(1) == [
             {"bad-app-shape",
              "`M.view` must have type (M.Model -> Html<M.Msg>), got (M.Model -> Html<O.Msg>)"}
           ]
  end
end

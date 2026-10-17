defmodule Nobi.Lang.RoutesTest do
  @moduledoc "`defroutes`, parameterised `init` and `Cmd.navigate`: syntax and checking."
  use ExUnit.Case, async: true

  alias Nobi.Lang.{Cid, Format, Parser}
  alias Nobi.Lang.Types.{Check, Extract, Stdlib}

  import NobiOracle, only: [strip: 1]

  @forum """
  defroutes Forum do
    "/" -> Forum.Threads
    "/post/:id" -> Forum.Post
    "/settings" -> Forum.Settings
  end
  """

  defp decl!(src) do
    assert {:ok, [d]} = Parser.program(src), src
    d
  end

  defp fail(src) do
    case Parser.program(src) do
      {:ok, _} -> "(parsed)"
      {:error, %{code: "parse", message: m, line: l, col: c}} -> "#{l}:#{c}: #{m}"
    end
  end

  describe "parsing" do
    test "a route table parses into segments per pattern" do
      assert strip(decl!(@forum)) ==
               {:defroutes,
                [
                  "Forum",
                  [
                    {[], "Forum.Threads"},
                    {[{:lit, "post"}, {:param, "id"}], "Forum.Post"},
                    {[{:lit, "settings"}], "Forum.Settings"}
                  ]
                ]}
    end

    test "positions are kept on the declaration" do
      assert {:defroutes, [line: 1, col: 1], _} = decl!(@forum)
    end

    test "an empty table and a one-line table parse" do
      assert strip(decl!("defroutes A do\nend")) == {:defroutes, ["A", []]}

      assert strip(decl!(~s(defroutes A do "/a/:x/b" -> A.B end))) ==
               {:defroutes, ["A", [{[{:lit, "a"}, {:param, "x"}, {:lit, "b"}], "A.B"}]]}
    end

    test "sits between other declarations" do
      src = "defapp A\n\n" <> @forum <> "\ndef A.f() : Int do 1 end"
      assert {:ok, [{:defapp, _, _}, {:defroutes, _, _}, {:def, _, _}]} = Parser.program(src)
    end

    test "malformed patterns are parse errors at the pattern" do
      assert fail(~s(defroutes A do\n  "post" -> A.B\nend)) ==
               ~s(2:3: route pattern "post" must start with `/` — write it as "/post")

      assert fail(~s(defroutes A do\n  "/a//b" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a\/\/b" has an empty segment/

      assert fail(~s(defroutes A do\n  "/a/" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a\/" has an empty segment/

      assert fail(~s(defroutes A do\n  "/a/:" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a\/:" has a `:` with no parameter name/

      assert fail(~s(defroutes A do\n  "/a:b" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a:b" has `:` inside segment "a:b"/

      assert fail(~s(defroutes A do\n  "/:Id" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/:Id" has parameter `Id`/

      assert fail(~s(defroutes A do\n  "/a b" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a b" has segment "a b"/

      assert fail(~s(defroutes A do\n  "/a/.." -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/a\/\.\." has segment "\.\."/

      assert fail(~s(defroutes A do\n  "/." -> A.B\nend)) =~ ~r/has segment "\."/
      assert {:ok, _} = Parser.program(~s(defroutes A do "/v1.2/a..b" -> A.B end))

      assert fail(~s(defroutes A do\n  "/:id/:id" -> A.B\nend)) =~
               ~r/^2:3: route pattern "\/:id\/:id" names parameter `id` twice/
    end

    test "the route syntax is spelled out when it is wrong" do
      assert fail(~s(defroutes A do\n  "/" A.B\nend)) =~ ~r/^2:7: expected '->'/
      assert fail("defroutes A do\n  A.B\nend") =~ ~r/^2:3: expected a route `"\/path" -> App`/
      assert fail(~s(defroutes A do\n  "/" -> A.B)) =~ ~r/unclosed `do`/
      assert fail(~s(defroutes A do\n  "/" -> a\nend)) =~ ~r/^2:10: route target `a` must be/
    end

    test "defroutes is a keyword" do
      assert fail("def A.f(defroutes : Int) : Int do 1 end") =~ ~r/'defroutes' is a keyword/
    end
  end

  describe "formatting and CIDs" do
    test "format, parse again: the same tree" do
      d = decl!(@forum)
      text = Format.decl(d)

      assert text ==
               String.trim_trailing(@forum)

      assert strip(decl!(text)) == strip(d)
    end

    test "an empty table formats" do
      assert Format.decl(decl!("defroutes A do end")) == "defroutes A do\nend"
    end

    test "the CID ignores layout, not content" do
      spaced =
        ~s(defroutes   Forum do\n\n  "/" ->   Forum.Threads\n  "/post/:id"->Forum.Post\n\n  "/settings" -> Forum.Settings end)

      assert Cid.of(decl!(spaced)) == Cid.of(decl!(@forum))

      other = String.replace(@forum, ":id", ":slug")
      refute Cid.of(decl!(other)) == Cid.of(decl!(@forum))
    end
  end

  # ---------- checking ----------

  # forum.nobi (Nobi has no comments, so its notes live here): topics would
  # come from the store, whose effects do not run yet, so the thread list
  # starts empty and `Forum.Post` is reachable only by its URL, "/post/:id".
  @fixture File.read!("test/fixtures/nobi/forum.nobi")

  # A one-model app `name` whose init takes `params` (source text).
  defp app(name, params \\ "") do
    """
    defmodel #{name}.Model do
      n : Int
    end

    deftype #{name}.Msg do
      Go
    end

    def #{name}.init(#{params}) : (#{name}.Model, Cmd<#{name}.Msg>) do
      (%#{name}.Model{n: 0}, Cmd.none())
    end

    def #{name}.update(msg : #{name}.Msg, model : #{name}.Model) : (#{name}.Model, Cmd<#{name}.Msg>) do
      (model, Cmd.none())
    end

    def #{name}.view(model : #{name}.Model) : Html<#{name}.Msg> do
      <div>{model.n}</div>
    end

    defapp #{name}
    """
  end

  defp check(src) do
    {:ok, decls} = Parser.program(src)
    Check.program(decls, Stdlib.signatures())
  end

  defp errors(checked, name) do
    case checked[name].result do
      {:ok, _} -> []
      {:error, errors} -> Enum.map(errors, &{&1.code, &1.message})
    end
  end

  defp codes(checked, name), do: checked |> errors(name) |> Enum.map(&elem(&1, 0))

  defp all_ok(checked) do
    for {name, c} <- checked,
        do: assert(match?({:ok, _}, c.result), "#{name}: #{inspect(c.result)}")
  end

  describe "the forum fixture" do
    test "typechecks whole" do
      all_ok(check(@fixture))
    end

    test "the route table's signature and deps" do
      {:ok, decls} = Parser.program(@fixture)
      routes = Enum.find(decls, &match?({:defroutes, _, _}, &1))

      assert Extract.signature(routes) ==
               {:routes,
                [
                  {[], "Forum.Threads"},
                  {[{:lit, "post"}, {:param, "id"}], "Forum.Post"},
                  {[{:lit, "settings"}], "Forum.Settings"}
                ]}

      want =
        ~w(Forum.Threads Forum.Threads.init Forum.Post Forum.Post.init Forum.Settings Forum.Settings.init)

      assert check(@fixture)["Forum"].deps == MapSet.new(want)
      assert Extract.deps(routes) == MapSet.new(want)

      assert Format.signature("Forum", Extract.signature(routes)) ==
               ~s(routes {"/" -> Forum.Threads, "/post/:id" -> Forum.Post, "/settings" -> Forum.Settings})
    end

    test "a def's signature names its parameters; the text shows types only" do
      {:ok, decls} = Parser.program(@fixture)
      init = Enum.find(decls, &(Nobi.Lang.Ast.name(&1) == "Forum.Post.init"))
      assert {:def, [{:named, "Uuid"}], _, ["id"]} = sig = Extract.signature(init)
      assert Format.signature("Forum.Post.init", sig) =~ ~r/^Forum.Post.init\(Uuid\) : /
    end
  end

  describe "route tables refuse" do
    test "an unknown target" do
      c = check(app("A") <> ~s(defroutes R do "/" -> A\n "/x" -> B end))
      assert [{"bad-route", m}] = errors(c, "R")
      assert m =~ "`B` is not defined"
      assert m =~ "defapp B"
    end

    test "a target that is not an app" do
      c = check(app("A") <> ~s(defroutes R do "/" -> A.Model end))
      assert [{"bad-route", m}] = errors(c, "R")
      assert m =~ "`A.Model` is a model, not an app"
    end

    test "a parameter name that is not init's" do
      c = check(app("A", "id : Int") <> ~s(defroutes R do "/post/:slug" -> A end))
      assert [{"route-mismatch", m}] = errors(c, "R")
      assert m =~ ~s("/post/:slug")
      assert m =~ "`A.init(id : Int)`"
      assert m =~ ~s("/post/:id")
    end

    test "too few or too many parameters" do
      c = check(app("A", "id : Int, page : Int") <> ~s(defroutes R do "/post/:id" -> A end))
      assert ["route-mismatch"] = codes(c, "R")
      c = check(app("A") <> ~s(defroutes R do "/post/:id" -> A end))
      assert [{"route-mismatch", m}] = errors(c, "R")
      assert m =~ ~s(write it as "/post")
    end

    test "parameters in another order than init's are fine: they match by name" do
      c = check(app("A", "a : Int, b : String") <> ~s(defroutes R do "/:b/:a" -> A end))
      all_ok(c)
    end

    test "an init parameter of a type a URL cannot carry" do
      c = check(app("A", "on : Bool") <> ~s(defroutes R do "/x/:on" -> A end))
      assert [{"route-mismatch", m}] = errors(c, "R")
      assert m =~ "`on : Bool`"
      assert m =~ "Int, String or Uuid"
      assert ["bad-app-shape"] = codes(c, "A")
    end

    test "two patterns that match the same URLs" do
      c =
        check(
          app("A", "a : Int") <>
            app("B", "b : Int") <> ~s(defroutes R do "/post/:a" -> A\n "/post/:b" -> B end)
        )

      assert [{"duplicate-route", m}] = errors(c, "R")
      assert m =~ ~s("/post/:b")
      assert m =~ ~s("/post/:a")

      assert ["duplicate-route"] =
               codes(check(app("A") <> ~s(defroutes R do "/" -> A\n "/" -> A end)), "R")
    end

    test "overlapping but different patterns are allowed: first match wins" do
      c =
        check(
          app("A", "a : String") <>
            app("B") <> ~s(defroutes R do "/p/new" -> B\n "/p/:a" -> A end)
        )

      all_ok(c)
    end

    test "a route table's name follows the naming rules" do
      assert "bad-name" in codes(check(app("A") <> ~s(defroutes r do "/" -> A end)), "r")
    end
  end

  describe "parameterised init" do
    test "takes Int, String and Uuid parameters, and needs no route" do
      all_ok(check(app("A", "a : Int, b : String, c : Uuid")))
    end

    test "refuses any other parameter type, saying which ones it takes" do
      c = check(app("A", "xs : List<Int>"))
      assert [{"bad-app-shape", m}] = errors(c, "A")
      assert m =~ "`A.init`"
      assert m =~ "`xs : List<Int>`"
      assert m =~ "Int, String or Uuid"
    end

    test "still refuses a wrong return type" do
      src =
        String.replace(
          app("A", "a : Int"),
          "def A.init(a : Int) : (A.Model, Cmd<A.Msg>)",
          "def A.init(a : Int) : A.Model"
        )

      src = String.replace(src, "(%A.Model{n: 0}, Cmd.none())", "%A.Model{n: 0}")
      assert ["bad-app-shape"] = codes(check(src), "A")
    end
  end

  describe "Cmd.navigate" do
    defp navigating(target_params, call) do
      app("T", target_params) <>
        app("A") <>
        """
        def A.go(model : A.Model, id : Uuid) : (A.Model, Cmd<A.Msg>) do
          (model, #{call})
        end
        """
    end

    test "is typed like the target's init and is a Cmd of the caller's messages" do
      c = check(navigating("id : Uuid, n : Int", "Cmd.navigate(T, id, 1)"))
      all_ok(c)
      assert MapSet.subset?(MapSet.new(["T", "T.init"]), c["A.go"].deps)
    end

    test "records the app and its parameters for codegen" do
      c = check(navigating("id : Uuid, n : Int", "Cmd.navigate(T, id, model.n)"))
      {:ok, typed} = c["A.go"].result
      [call] = find_calls(typed, "Cmd.navigate")
      {:call, m, ["Cmd.navigate", [{:name, am, ["T"]}, _, _]]} = call
      assert m[:res] == {:navigate, "T", [{"id", {:named, "Uuid"}}, {"n", {:named, "Int"}}]}
      assert m[:type] == {:applied, "Cmd", [{:named, "A.Msg"}]}
      assert am[:res] == {:app, "T"}
    end

    test "with no parameters" do
      all_ok(check(navigating("", "Cmd.navigate(T)")))
    end

    test "refuses the wrong number of arguments" do
      c = check(navigating("n : Int", "Cmd.navigate(T)"))
      assert [{"bad-navigate", m}] = errors(c, "A.go")
      assert m =~ "`T.init(n : Int)`"
      assert m =~ "Cmd.navigate(T, n)"
    end

    test "refuses an argument of the wrong type" do
      c = check(navigating("n : Int", ~s|Cmd.navigate(T, "x")|))
      assert [{"bad-navigate", m}] = errors(c, "A.go")
      assert m =~ "`n : Int`"
      assert m =~ "String"
    end

    test "refuses an argument whose type can never be the parameter's" do
      c = check(navigating("id : Uuid", "Cmd.navigate(T, [])"))
      assert [{"bad-navigate", m}] = errors(c, "A.go")
      assert m =~ "`id : Uuid`"
      assert m =~ "List<"
    end

    test "refuses a first argument that is not an app" do
      assert ["bad-navigate"] = codes(check(navigating("", "Cmd.navigate(T.Model)")), "A.go")
      assert ["bad-navigate"] = codes(check(navigating("", "Cmd.navigate(Nope)")), "A.go")
      assert ["bad-navigate"] = codes(check(navigating("", "Cmd.navigate(1)")), "A.go")
      assert ["bad-navigate"] = codes(check(navigating("", "Cmd.navigate()")), "A.go")
    end

    test "is not routed at check time: an unrouted app is navigable" do
      all_ok(check(navigating("n : Int", "Cmd.navigate(T, 3)")))
    end
  end

  defp find_calls({:call, _, [name, args]} = c, want) do
    here = if name == want, do: [c], else: []
    here ++ Enum.flat_map(args, &find_calls(&1, want))
  end

  defp find_calls({_, _, args}, want) when is_list(args),
    do: Enum.flat_map(args, &find_calls(&1, want))

  defp find_calls({a, b}, want), do: find_calls(a, want) ++ find_calls(b, want)
  defp find_calls(list, want) when is_list(list), do: Enum.flat_map(list, &find_calls(&1, want))
  defp find_calls(_, _), do: []
end

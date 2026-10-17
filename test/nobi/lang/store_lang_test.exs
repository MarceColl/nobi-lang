defmodule Nobi.Lang.StoreLangTest do
  @moduledoc """
  The store's language (piece "store", Task 1): stored models, field
  defaults, the evolution rule at promotion, and the types of `Cmd.store.tx`,
  `Store.get`/`Store.list` and `Tx.*`.
  """
  use ExUnit.Case, async: true

  import Nobi.Lang.CheckHelpers

  alias Nobi.Lang
  alias Nobi.Lang.{Cid, Format, Parser, Rt}
  alias Nobi.Lang.Types.{Evolution, Extract}

  @post """
  defmodel Forum.Post do
    id : Uuid
    title : String
    replies : Int = 0
    pinned : Bool = false
    tags : List<String> = []
  end
  """

  defp model!(src) do
    {:ok, [{:defmodel, _, _} = d]} = Parser.program(src)
    d
  end

  defp codes_of(src, name), do: codes(check_all(src)[name])
  defp messages_of(src, name), do: Enum.map(errors_of(src, name), & &1.message)

  defp errors_of(src, name) do
    case check_all(src)[name] do
      %{result: {:error, errs}} -> errs
      other -> flunk("#{name} checked: #{inspect(other)}")
    end
  end

  # ---------- defaults: syntax, format, CID, signature ----------

  describe "field defaults" do
    test "parse: a field is {name, type, default | :none}" do
      {:defmodel, _, ["Forum.Post", fields]} = model!(@post)

      assert [
               {"id", {:named, "Uuid"}, :none},
               {"title", {:named, "String"}, :none},
               {"replies", {:named, "Int"}, {:int, _, [0]}},
               {"pinned", {:named, "Bool"}, {:bool, _, [false]}},
               {"tags", {:applied, "List", [{:named, "String"}]}, {:list, _, []}}
             ] = fields
    end

    test "format prints `name : Type = <const>` and reparses to the same tree" do
      d = model!(@post)
      text = Format.decl(d)
      assert text == String.trim_trailing(@post)

      assert Nobi.Lang.Ast.without_positions(model!(text)) ==
               Nobi.Lang.Ast.without_positions(d)

      compound =
        "defmodel A.M do\n  id : Uuid\n  o : List<Option<Int>> = [Option.Some(-1)]\n  " <>
          "m : Map<String, Int> = %{\"a\" => 1}\n  t : (Int, String) = (1, \"x\")\nend"

      assert Format.decl(model!(compound)) == compound
    end

    test "`>=` closing a type argument list is `>` then a default's `=`" do
      {:defmodel, _, [_, fields]} =
        model!("defmodel A.M do\n  l : List<Int>= [1]\n  m : Map<String, List<Int>>= %{}\nend")

      assert [
               {"l", {:applied, "List", [{:named, "Int"}]}, {:list, _, [{:int, _, [1]}]}},
               {"m",
                {:applied, "Map", [{:named, "String"}, {:applied, "List", [{:named, "Int"}]}]},
                {:map, _, []}}
             ] = fields

      assert {:ok, _} = Parser.expr("a >= b")
    end

    test "the CID covers defaults" do
      a = model!("defmodel A.M do\n  n : Int = 0\nend")
      b = model!("defmodel A.M do\n  n : Int = 1\nend")
      c = model!("defmodel A.M do\n  n : Int\nend")
      assert length(Enum.uniq([Cid.of(a), Cid.of(b), Cid.of(c)])) == 3
    end

    test "the signature holds each default as its constant, positions dropped" do
      assert Extract.signature(model!(@post)) ==
               {:model,
                [
                  {"id", {:named, "Uuid"}, :none},
                  {"title", {:named, "String"}, :none},
                  {"replies", {:named, "Int"}, {:int, [], [0]}},
                  {"pinned", {:named, "Bool"}, {:bool, [], [false]}},
                  {"tags", {:applied, "List", [{:named, "String"}]}, {:list, [], []}}
                ]}

      assert Format.signature("Forum.Post", Extract.signature(model!(@post))) ==
               "model {id : Uuid, title : String, replies : Int = 0, pinned : Bool = false, tags : List<String> = []}"
    end

    test "a default's variant names its type as a dependency" do
      d = model!("defmodel A.M do\n  s : A.S = A.S.On\nend")
      assert MapSet.member?(Extract.deps(d), "A.S")
    end

    test "Rt.constant/1 is a default's value" do
      fields = elem(Extract.signature(model!(@post)), 1)
      assert Enum.map(fields, &Rt.constant(elem(&1, 2))) == [:none, :none, 0, false, []]

      {:ok, e} = Parser.expr(~S|(Option.Some(-1), %{"a" => [A.S.On]}, Option.None)|)

      assert Rt.constant(e) ==
               {{:var, "Option", "Some", [-1]}, %{"a" => [{:var, "A.S", "On", []}]},
                {:var, "Option", "None", []}}
    end

    test "constant defaults typecheck against their field" do
      src = """
      deftype A.S do On | Off end
      defmodel A.M do
        id : Uuid
        n : Int = -3
        s : String = "x"
        l : List<Int> = [1, 2]
        m : Map<String, Int> = %{"a" => 1}
        t : (Int, Bool) = (1, true)
        o : List<Option<Int>> = [Option.None, Option.Some(2)]
        e : A.S = A.S.Off
      end
      """

      assert codes_of(src, "A.M") == []
    end

    test "bad-default: a call, a symbol reference, a local, or a wrong type" do
      base =
        "def A.zero() : Int do 0 end\ndeftype A.S do On end\ndefmodel A.M2 do\n  n : Int\nend\n"

      for field <- [
            "n : Int = A.zero()",
            "n : Int = String.length(\"x\")",
            "n : Int = A.zero",
            "n : Int = x",
            "n : Int = 1 + 1",
            "l : List<Int> = [A.zero()]",
            ~S|n : Int = "zero"|,
            "n : Int = A.M2",
            "n : Int = A.S.Nope",
            "n : Int = A.Thing.Nope(1)",
            "o : List<Option<Int>> = [Option.Some(\"x\")]",
            "o : Option<Int> = Option.None",
            "o : Option<Int> = Option.Some(2)"
          ] do
        src = base <> "defmodel A.M do\n  #{field}\nend"
        assert codes_of(src, "A.M") == ["bad-default"], field
      end

      [m] = messages_of("defmodel A.M do\n  n : Int = A.zero()\nend", "A.M")
      assert m =~ "constant"

      [m] = messages_of("defmodel A.M do\n  o : Option<Int> = Option.None\nend", "A.M")
      assert m =~ "an Option field reads as Option.None when absent"

      [m] = messages_of(~s|defmodel A.M do\n  n : Int = "zero"\nend|, "A.M")
      assert m =~ "`n`"
      assert m =~ "Int"
    end

    test "a construction still lists every field (defaults apply only when decoding)" do
      src =
        @post <>
          ~S|def Forum.mk() : Forum.Post do %Forum.Post{title: "t"} end|

      assert "missing-field" in codes_of(src, "Forum.mk")
    end
  end

  # ---------- stored models ----------

  @models """
  defmodel A.Post do
    id : Uuid
    n : Int
  end
  defmodel A.Note do
    text : String
  end
  deftype A.Msg do Saved(Uuid) | Rows(List<A.Post>) | Notes(List<A.Note>) | Got(Option<A.Note>) | Done(Result<(List<Uuid>, Int), String>) end
  """

  describe "not-stored" do
    test "store effects, Tx and Store reads on a stored model check" do
      src =
        @models <>
          """
          def A.ok(id : Uuid) : List<Cmd<A.Msg>> do
            [
              Cmd.store.insert(%A.Post{n: 1}, A.Msg.Saved),
              Cmd.store.list(A.Msg.Rows),
              Cmd.store.update(id, %A.Post{n: 2}, A.Msg.Saved),
              Cmd.store.delete(id, fn (r : Option<A.Post>) -> A.Msg.Saved(id) end)
            ]
          end
          """

      assert codes_of(src, "A.ok") == []
    end

    test "each store form on a model without `id : Uuid` is not-stored" do
      for call <- [
            ~S|Cmd.store.insert(%A.Note{text: "t"}, A.Msg.Saved)|,
            "Cmd.store.list(A.Msg.Notes)",
            "Cmd.store.get(id, A.Msg.Got)",
            ~S|Cmd.store.update(id, %A.Note{text: "t"}, A.Msg.Saved)|,
            "Cmd.store.delete(id, A.Msg.Got)"
          ] do
        src = @models <> "def A.f(id : Uuid) : Cmd<A.Msg> do\n  #{call}\nend"
        assert codes_of(src, "A.f") == ["not-stored"], call
      end

      [m] =
        messages_of(@models <> "def A.f() : Cmd<A.Msg> do Cmd.store.list(A.Msg.Notes) end", "A.f")

      assert m =~ "`A.Note`"
      assert m =~ "id : Uuid"
    end

    test "a store effect on something that is not a model is not-stored" do
      src = @models <> "def A.f() : Cmd<A.Msg> do Cmd.store.insert(5, A.Msg.Saved) end"
      assert codes_of(src, "A.f") == ["not-stored"]
    end

    test "Tx and Store forms on a non-stored model are not-stored" do
      for body <- [
            ~S|[Tx.insert(%A.Note{text: "t"})]|,
            ~S|[Tx.update(id, %A.Note{text: "t"})]|
          ] do
        src = @models <> "def A.f(id : Uuid) : List<Tx.Op> do\n  #{body}\nend"
        assert codes_of(src, "A.f") == ["not-stored"], body
      end

      src =
        @models <>
          "def A.f(s : Store, id : Uuid) : Option<A.Note> do\n  Store.get(s, id)\nend"

      assert codes_of(src, "A.f") == ["not-stored"]

      src = @models <> "def A.f(s : Store) : List<A.Note> do\n  Store.list(s)\nend"
      assert codes_of(src, "A.f") == ["not-stored"]
    end

    test "a model may not hold a Store" do
      assert "invalid-model-field" in codes_of("defmodel A.M do\n  s : Store\nend", "A.M")
    end
  end

  # ---------- tx closure, Store reads, Tx ops ----------

  describe "Cmd.store.tx" do
    @incr @models <>
            """
            def A.incr(id : Uuid) : Cmd<A.Msg> do
              Cmd.store.tx(
                fn (s : Store) ->
                  case Store.get(s, id) do
                    Option.Some(p) -> ([Tx.update(id, %A.Post{p | n: p.n + 1})], p.n + 1)
                    Option.None -> ([], 0)
                  end
                end,
                A.Msg.Done
              )
            end
            """

    test "the closure form checks; Store.get takes its model from how its result is used" do
      assert codes_of(@incr, "A.incr") == []
    end

    test "the closure's result and the callback's agree on `r`" do
      src =
        @models <>
          """
          def A.f() : Cmd<A.Msg> do
            Cmd.store.tx(fn (s : Store) -> ([], "not an Int") end, A.Msg.Done)
          end
          """

      assert codes_of(src, "A.f") != []
    end

    test "the list form is gone" do
      src =
        @models <>
          "def A.f() : Cmd<A.Msg> do Cmd.store.tx([Tx.insert(%A.Post{n: 1})], A.Msg.Saved) end"

      assert codes_of(src, "A.f") != []
    end

    test "Store.list and Store.get take their model from the expected type" do
      src =
        @models <>
          """
          def A.all(s : Store) : List<A.Post> do Store.list(s) end
          def A.one(s : Store, id : Uuid) : Option<A.Post> do Store.get(s, id) end
          def A.annotated(s : Store) : Int do List.length((Store.list(s) : List<A.Post>)) end
          """

      assert codes_of(src, "A.all") == []
      assert codes_of(src, "A.one") == []
      assert codes_of(src, "A.annotated") == []
    end

    test "a Store read whose model nothing determines is cannot-infer, with a hint" do
      src = @models <> "def A.f(s : Store) : Int do List.length(Store.list(s)) end"
      assert [%{code: "cannot-infer", message: m}] = errors_of(src, "A.f")
      assert m =~ "Store.list(s)"
      assert m =~ "annotate"
    end

    test "Tx.delete(Model, id) names its stored model" do
      ok = @models <> "def A.f(id : Uuid) : List<Tx.Op> do [Tx.delete(A.Post, id)] end"
      assert codes_of(ok, "A.f") == []

      {:def, _, [_, _, _, body]} = all_ok(ok)["A.f"]
      assert [{"Tx.delete", "A.Post"}] = walk(body, [])

      [d] = ok |> parse() |> Enum.filter(&(Nobi.Lang.Ast.name(&1) == "A.f"))
      assert MapSet.member?(Extract.deps(d), "A.Post")
    end

    test "Tx.delete: a non-stored model, a wrong id, the old form, and as a value" do
      for {body, code} <- [
            {"[Tx.delete(A.Note, id)]", "not-stored"},
            {"[Tx.delete(A.Msg, id)]", "not-stored"},
            {"[Tx.delete(A.Post, 1)]", "mismatch"},
            {"[Tx.delete(id)]", "bad-tx-delete"},
            {"[Tx.delete(x, id)]", "bad-tx-delete"},
            {"List.map([id], fn (i : Uuid) -> Tx.delete(A.Post, i) end)", nil},
            {"List.map([id], Tx.delete)", "bad-tx-delete"}
          ] do
        src = @models <> "def A.f(id : Uuid, x : Uuid) : List<Tx.Op> do\n  #{body}\nend"
        assert codes_of(src, "A.f") == List.wrap(code), body
      end
    end

    test "Tx.insert of an open or generic row is not-stored" do
      src = @models <> "def A.f(x : a) : Tx.Op do Tx.insert(x) end"
      assert "not-stored" in codes_of(src, "A.f")
    end

    test "a field read off a Store.get row waits for the model the body settles" do
      src =
        @models <>
          """
          def A.cap(id : Uuid) : Cmd<A.Msg> do
            Cmd.store.tx(
              fn (s : Store) ->
                case Store.get(s, id) do
                  Option.Some(p) ->
                    if p.n > 9 do
                      ([], p.n)
                    else
                      ([Tx.update(id, %A.Post{p | n: p.n + 1})], p.n + 1)
                    end
                  Option.None -> ([], 0)
                end
              end,
              A.Msg.Done
            )
          end
          """

      assert codes_of(src, "A.cap") == []
    end

    test "a field read off a row nothing settles names the annotation that fixes it" do
      src =
        @models <>
          """
          def A.peek(id : Uuid) : Cmd<A.Msg> do
            Cmd.store.tx(
              fn (s : Store) ->
                case Store.get(s, id) do
                  Option.Some(p) -> ([], p.n)
                  Option.None -> ([], 0)
                end
              end,
              A.Msg.Done
            )
          end
          """

      assert [%{code: "not-a-model", message: m}] = errors_of(src, "A.peek")
      assert m =~ "(Store.get(s, id) : Option<App.Row>)"
    end

    test "the typed tree names each store form's model (for codegen)" do
      typed = all_ok(@incr)["A.incr"]
      models = collect_store_models(typed)
      assert {"Store.get", "A.Post"} in models
      assert {"Tx.update", "A.Post"} in models
    end
  end

  defp collect_store_models({:def, _, [_, _, _, body]}), do: walk(body, [])

  defp walk({_, m, _} = node, acc) do
    acc =
      case {node, m[:store]} do
        {{:call, _, [name, _]}, model} when is_binary(model) -> [{name, model} | acc]
        _ -> acc
      end

    {_, acc} = Nobi.Lang.Types.Check.Tree.map_children(node, acc, &{&1, walk(&1, &2)})
    acc
  end

  # ---------- the evolution rule ----------

  @v1 """
  defmodel Forum.Post do
    id : Uuid
    title : String
  end
  """

  defp promoted!(u, id, src) do
    {u, verdict} = Lang.stage(u, id, src)
    assert {:promoted, _} = verdict, "#{id}: #{inspect(verdict)}"
    u
  end

  defp refused!(u, id, src) do
    {u, verdict} = Lang.stage(u, id, src)
    assert {:staged, reasons} = verdict
    assert Enum.all?(reasons, &(&1.code == "model-evolution")), inspect(reasons)
    {u, Enum.map(reasons, & &1.message)}
  end

  defp v1, do: promoted!(Lang.new(), "v1", @v1)

  describe "evolution (Review Focus 4)" do
    test "the first commit is unconstrained" do
      u = v1()
      assert ["Forum.Post"] == Enum.map(Lang.symbols(u), & &1.name)
    end

    test "a retyped field is refused, staged, never promoted, and says what to do" do
      {u, [m]} =
        refused!(v1(), "v2", "defmodel Forum.Post do\n  id : Uuid\n  title : Int\nend")

      assert m == "Forum.Post.title was String, cannot become Int; add a new field instead"
      assert %{"v2" => %{reasons: [%{code: "model-evolution"}]}} = Lang.staged(u)
      assert Lang.read(u, "Forum.Post") == {:ok, String.trim_trailing(@v1)}
    end

    test "a removed field is refused" do
      {_, [m]} = refused!(v1(), "v2", "defmodel Forum.Post do\n  id : Uuid\nend")
      assert m == "cannot remove Forum.Post.title; leave it in place"
    end

    test "removing `id` is removing a field" do
      {_, [m]} = refused!(v1(), "v2", "defmodel Forum.Post do\n  title : String\nend")
      assert m == "cannot remove Forum.Post.id; leave it in place"
    end

    test "a new field with neither a default nor Option is refused, the fix named" do
      {_, [m]} =
        refused!(v1(), "v2", @v1 |> String.replace("end", "  replies : Int\nend"))

      assert m ==
               "Forum.Post: new field replies : Int needs a default (replies : Int = 0) or an Option type"
    end

    test "several violations are each a reason" do
      {_, ms} =
        refused!(v1(), "v2", "defmodel Forum.Post do\n  id : Uuid\n  body : String\nend")

      assert length(ms) == 2
    end

    test "Option and defaulted fields are accepted; so is changing or adding a default" do
      u = v1()

      u =
        promoted!(
          u,
          "v2",
          "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  replies : Int = 0\n  " <>
            "tag : Option<String>\nend"
        )

      u =
        promoted!(
          u,
          "v3",
          ~s|defmodel Forum.Post do\n  id : Uuid\n  title : String = "untitled"\n  replies : Int = 5\n  | <>
            "tag : Option<String>\nend"
        )

      assert {:ok, "defmodel Forum.Post do\n  id : Uuid\n  title : String = \"untitled\"" <> _} =
               Lang.read(u, "Forum.Post")
    end

    test "a model that is not stored evolves freely; once stored the rule applies" do
      u = promoted!(Lang.new(), "v1", "defmodel A.M do\n  n : Int\nend")
      u = promoted!(u, "v2", "defmodel A.M do\n  n : String\nend")
      u = promoted!(u, "v3", "defmodel A.M do\n  id : Uuid\n  n : Int\nend")
      {_, [m]} = refused!(u, "v4", "defmodel A.M do\n  id : Uuid\n  n : String\nend")
      assert m =~ "A.M.n was Int"
    end

    test "removing a stored model, or redefining it as another kind, is not this rule's" do
      promoted!(v1(), "v2", "deftype Forum.Post do A | B end")
      {u, {:promoted, _}} = Lang.stage(v1(), "v2", "", remove: ["Forum.Post"])
      # declared again later, it is a first commit
      promoted!(u, "v3", "defmodel Forum.Post do\n  id : Uuid\n  title : Int\nend")
    end

    test "a fixed patch, restaged under its id, promotes" do
      {u, _} = refused!(v1(), "v2", "defmodel Forum.Post do\n  id : Uuid\nend")

      u =
        promoted!(
          u,
          "v2",
          "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  body : Option<String>\nend"
        )

      assert Lang.staged(u) == %{}
    end

    test "a staged patch is judged again against the version that promotes after it" do
      mandatory = "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  replies : Int\nend"
      {u, _} = refused!(v1(), "late", mandatory)

      defaulted =
        "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  replies : Int = 0\nend"

      {u, verdict} = Lang.stage(u, "first", defaulted)
      # Over the defaulted version, `late` only drops a default: it promotes too.
      assert verdict == {:promoted, ["first", "late"]}
      assert Lang.read(u, "Forum.Post") == {:ok, mandatory}

      # and the other way: a patch fine over v1 is refused once v2 retypes under it
      {u, {:staged, _}} =
        Lang.stage(v1(), "waits", @v1 <> "\ndef Forum.x() : Int do Forum.missing() end")

      u =
        promoted!(
          u,
          "v2",
          "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  n : Option<Int>\nend"
        )

      {_, {:staged, reasons}} = Lang.stage(u, "waits", @v1)

      assert [
               %{
                 code: "model-evolution",
                 message: "cannot remove Forum.Post.n; leave it in place"
               }
             ] = reasons
    end

    @nested """
    defmodel Forum.Tag do
      label : String
    end
    deftype Forum.Body do Text(String) | Tagged(List<Forum.Tag>) end
    defmodel Forum.Post do
      id : Uuid
      tags : List<Option<Forum.Tag>>
      body : Forum.Body
    end
    """

    test "a model kept inside a stored model's rows evolves add-only too" do
      u = promoted!(Lang.new(), "v1", @nested)

      {u, [m]} = refused!(u, "retag", "defmodel Forum.Tag do\n  label : Int\nend")
      assert m =~ "Forum.Tag.label was String, cannot become Int"
      assert m =~ "Forum.Post"
      assert %{"retag" => %{reasons: [%{name: "Forum.Post"}]}} = Lang.staged(u)

      {_, [_]} = refused!(u, "drop", "defmodel Forum.Tag do\n  color : Option<String>\nend")
      {_, [_]} = refused!(u, "add", "defmodel Forum.Tag do\n  label : String\n  n : Int\nend")

      promoted!(u, "ok", "defmodel Forum.Tag do\n  label : String\n  n : Int = 0\nend")
    end

    test "a deftype kept inside a stored model's rows only gains variants" do
      u = promoted!(Lang.new(), "v1", @nested)

      {_, [m]} =
        refused!(u, "retype", "deftype Forum.Body do Text(Int) | Tagged(List<Forum.Tag>) end")

      assert m ==
               "Forum.Body.Text had (String), cannot become (Int); add a new variant instead " <>
                 "(Forum.Body is kept inside the stored model Forum.Post)"

      {_, [m]} = refused!(u, "remove", "deftype Forum.Body do Text(String) end")
      assert m =~ "cannot remove Forum.Body.Tagged; leave it in place"

      # (the model's own `body : Forum.Body` breaks too: an arity error beside it)
      {_, {:staged, reasons}} =
        Lang.stage(
          u,
          "params",
          "deftype Forum.Body<T> do Text(String) | Tagged(List<Forum.Tag>) end"
        )

      assert Enum.any?(
               reasons,
               &(&1.code == "model-evolution" and
                   &1.message =~ "Forum.Body had type parameters <>, cannot become <T>")
             )

      promoted!(
        u,
        "add",
        "deftype Forum.Body do Text(String) | Tagged(List<Forum.Tag>) | Empty | Quote(String, Int) end"
      )
    end

    test "a deftype no stored model reaches evolves freely" do
      u =
        promoted!(
          Lang.new(),
          "v1",
          "deftype A.Body do Text(String) | Gone end\ndefmodel A.State do\n  body : A.Body\nend"
        )

      promoted!(u, "v2", "deftype A.Body do Text(Int) end")
    end

    test "reached through a deftype's variant, three deep" do
      src =
        "defmodel A.Leaf do\n  v : Int\nend\ndefmodel A.Mid do\n  leaf : A.Leaf\nend\n" <>
          "deftype A.Box do Full(Map<String, (Int, A.Mid)>) | Empty end\n" <>
          "defmodel A.Root do\n  id : Uuid\n  box : A.Box\nend"

      u = promoted!(Lang.new(), "v1", src)
      {_, [m]} = refused!(u, "leaf", "defmodel A.Leaf do\n  v : String\nend")
      assert m =~ "A.Leaf.v was Int"
    end

    test "a model no stored model reaches evolves freely" do
      u =
        promoted!(
          Lang.new(),
          "v1",
          "defmodel A.Tag do\n  label : String\nend\ndefmodel A.State do\n  tags : List<A.Tag>\nend"
        )

      promoted!(u, "v2", "defmodel A.Tag do\n  label : Int\nend")
    end

    test "the rule is incremental: checking again after promotion reads the memo" do
      u = v1()
      before = Nobi.Lang.Universe.check_count(u)
      u = promoted!(u, "f", "def Forum.title(p : Forum.Post) : String do p.title end")
      # one check: the new def; the model's check is not run again
      assert Nobi.Lang.Universe.check_count(u) == before + 1
    end

    test "restore re-checks committed code with no previous version, so it is sound" do
      u =
        promoted!(
          v1(),
          "v2",
          "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  n : Int = 0\nend"
        )

      durable = Nobi.Lang.Universe.durable(u)
      decls = for {_, c} <- Lang.committed(u), into: %{}, do: {c.cid, c.decl}
      assert {:ok, r} = Lang.restore(durable.commits, durable.staged, decls)
      assert Lang.health(r) == :ok

      # and the restored universe still holds the rule
      {_, [m]} =
        refused!(
          r,
          "v3",
          "defmodel Forum.Post do\n  id : Uuid\n  title : Int\n  n : Int = 0\nend"
        )

      assert m =~ "was String"
    end
  end

  describe "Evolution.errors/3" do
    test "nothing to compare, or a model that was not stored: no errors" do
      new = Extract.signature(model!("defmodel A.M do\n  n : String\nend"))
      assert Evolution.errors("A.M", nil, new) == []
      assert Evolution.errors("A.M", {:model, [{"n", {:named, "Int"}, :none}]}, new) == []
    end

    test "a suggested default fits its type" do
      old = {:model, [{"id", {:named, "Uuid"}, :none}]}

      for {t, want} <- [
            {"String", ~S|s : String = ""|},
            {"Bool", "s : Bool = false"},
            {"List<Int>", "s : List<Int> = []"},
            {"Map<String, Int>", "s : Map<String, Int> = %{}"}
          ] do
        new = Extract.signature(model!("defmodel A.M do\n  id : Uuid\n  s : #{t}\nend"))
        [%{message: m}] = Evolution.errors("A.M", old, new)
        assert m =~ "(#{want})", t
      end
    end
  end
end

defmodule Kinoko.Lang.ExtractTest do
  use ExUnit.Case, async: true

  alias Kinoko.Lang.{Ast, Format, Parser}
  alias Kinoko.Lang.Types.{Extract, Stdlib}

  defp parse!(src) do
    assert {:ok, decls} = Parser.program(src), src
    decls
  end

  describe "signature/1" do
    test "def signature is annotation-derived" do
      [d] = parse!("def Foo.add(a : Int, b : Int) : Int do a + b end")
      assert Extract.signature(d) == {:def, [{:named, "Int"}, {:named, "Int"}], {:named, "Int"}}
    end

    test "model and type signatures" do
      [m, t] = parse!("defmodel A.M do x : Int end\ndeftype A.T do L | R(String) end")
      assert Extract.signature(m) == {:model, [{"x", {:named, "Int"}}]}
      assert Extract.signature(t) == {:type, [], [{"L", []}, {"R", [{:named, "String"}]}]}
    end

    test "app and test" do
      [a, t] = parse!("defapp A\ndeftest A.t do 1 end")
      assert Extract.signature(a) == :app
      assert Extract.signature(t) == :test
    end
  end

  describe "deps/1" do
    test "type refs, call targets, variant owners and model names" do
      [d] =
        parse!("""
        def Counter.update(msg : Counter.Msg, model : Counter.Model) : Counter.Model do
          case msg do
            Counter.Msg.Increment -> %Counter.Model{model | count: model.count + 1}
            _ -> model
          end
        end
        """)

      deps = Extract.deps(d)
      assert "Counter.Msg" in deps
      assert "Counter.Model" in deps
      refute "Int" in deps
      refute "model" in deps
    end

    test "stdlib calls and builtin type heads" do
      [d] =
        parse!(
          "def A.f(xs : List<Int>) : Int do List.length(List.filter(xs, fn (x : Int) -> x > 0 end)) end"
        )

      deps = Extract.deps(d)
      assert "List.length" in deps
      assert "List.filter" in deps
      refute "List" in deps
    end

    test "does not invent dependencies" do
      [_, d] = parse!("defmodel A.M do\n  x : Int\nend\ndef B.f() : Int do 1 end")
      assert Extract.deps(d) == MapSet.new()
    end

    test "a variant inside a tuple pattern depends on its type" do
      decls =
        parse!("""
        deftype A.T do X | Y end
        deftype B.T do Z(A.T) | W end
        def C.f(p : (B.T, Int)) : Int do
          case p do
            (B.T.Z(A.T.X), _) -> 1
            ((n), 2) -> 2
            _ -> 0
          end
        end
        """)

      assert Extract.deps(Enum.at(decls, 2)) == MapSet.new(["A.T", "B.T"])
    end

    test "defapp depends on its five parts; type params are not deps" do
      [a, t] = parse!("defapp A\ndeftype A.T<X> do V(X) end")

      assert Extract.deps(a) ==
               MapSet.new(~w(A.init A.update A.view A.Model A.Msg))

      assert Extract.deps(t) == MapSet.new()
    end

    test "deps are a subset of the oracle's for every corpus declaration" do
      for %{"file" => f, "deps" => want} <- YabuOracle.corpus() do
        for d <- parse!(YabuOracle.corpus_source(f)) do
          # The oracle's deps predate typed Html: each `Html<M>` now names M too.
          html_msgs =
            ~r/Html<([\w.]+)>/
            |> Regex.scan(Format.decl(d), capture: :all_but_first)
            |> List.flatten()

          allowed = MapSet.new(want[Ast.name(d)] ++ html_msgs)
          assert MapSet.subset?(Extract.deps(d), allowed), "#{f} #{Ast.name(d)}"
        end
      end
    end

    test "deps never raise across every generated and ill-typed source" do
      for {label, src} <- YabuOracle.every_source(), not String.ends_with?(label, ".yabu") do
        for d <- parse!(src), do: assert(%MapSet{} = Extract.deps(d), label)
      end
    end
  end

  describe "Stdlib" do
    test "has the 59 Rust rows in declared order, then the 9 Map rows" do
      assert map_size(Stdlib.signatures()) == 68
      assert length(Stdlib.names()) == 68
      assert Enum.take(Stdlib.names(), 2) == ["List.map", "List.filter"]
      assert Enum.at(Stdlib.names(), 58) == "Tx.delete"
      assert Enum.drop(Stdlib.names(), 59) |> Enum.all?(&String.starts_with?(&1, "Map."))
      assert Enum.all?(Stdlib.names(), &Map.has_key?(Stdlib.signatures(), &1))
    end

    test "has every name the oracle examples use" do
      for n <-
            ~w(List.map List.filter List.append List.concat String.from_int Cmd.none JSON.parse) do
        assert Map.has_key?(Stdlib.signatures(), n)
      end
    end

    test "known signatures" do
      a = {:var, "a"}
      b = {:var, "b"}

      assert Stdlib.signatures()["List.map"] ==
               {:def, [{:applied, "List", [a]}, {:arrow, [a], b}], {:applied, "List", [b]}}

      assert Stdlib.signatures()["String.from_int"] ==
               {:def, [{:named, "Int"}], {:named, "String"}}

      assert Stdlib.signatures()["JSON.stringify"] ==
               {:def, [a], {:applied, "Result", [{:named, "String"}, {:named, "String"}]}}

      assert Stdlib.signatures()["Option"] ==
               {:type, ["T"], [{"Some", [{:var, "T"}]}, {"None", []}]}

      assert Stdlib.signatures()["Tx.Op"] == {:type, [], []}
    end
  end
end

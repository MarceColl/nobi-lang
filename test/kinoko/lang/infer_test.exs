defmodule Kinoko.Lang.InferTest do
  use ExUnit.Case, async: true

  alias Kinoko.Lang.{Format, Parser}
  alias Kinoko.Lang.Types.{Infer, Quote, Stdlib}

  @int {:named, "Int"}
  @string {:named, "String"}

  defp body(src) do
    {:ok, [{:def, _, [_, _, _, {:block, _, [_, last]}]}]} =
      Parser.program("def A.f() : Int do #{src} end")

    last
  end

  describe "unify/resolve" do
    test "identical types unify" do
      assert {:ok, _} =
               Infer.unify(Infer.new(), {:applied, "List", [@int]}, {:applied, "List", [@int]})
    end

    test "a uvar unifies with List<Int> and resolves" do
      {u, st} = Infer.fresh(Infer.new())
      assert {:ok, st} = Infer.unify(st, u, {:applied, "List", [@int]})
      assert Infer.resolve_full(st, u) == {:applied, "List", [@int]}
    end

    test "resolve follows chains and nested uvars to a fixpoint" do
      {a, st} = Infer.fresh(Infer.new())
      {b, st} = Infer.fresh(st)
      {:ok, st} = Infer.unify(st, a, {:tuple, [b, b]})
      {:ok, st} = Infer.unify(st, b, @int)
      assert Infer.resolve_full(st, a) == {:tuple, [@int, @int]}
    end

    test "resolve is top-only" do
      {a, st} = Infer.fresh(Infer.new())
      {b, st} = Infer.fresh(st)
      {:ok, st} = Infer.unify(st, a, {:tuple, [b]})
      {:ok, st} = Infer.unify(st, b, @int)
      assert Infer.resolve(st, a) == {:tuple, [b]}
    end

    @tag :perf
    test "20_000 mismatching unifications stay fast" do
      st = Infer.allow(Infer.new(), 1_000_000)

      {us, st} =
        :timer.tc(fn ->
          Enum.reduce(1..20_000, st, fn _, st ->
            {:error, "mismatch", st} = Infer.unify(st, @int, @string)
            st
          end)
        end)

      assert length(Infer.errors(st)) == 20_000
      assert us < 200_000
    end

    test "the occurs check" do
      {u, st} = Infer.fresh(Infer.new())
      assert {:error, "occurs", st} = Infer.unify(st, u, {:applied, "List", [u]})
      assert ["occurs", "mismatch"] = Enum.map(Infer.errors(st), & &1.code)
    end

    test "Int against String is a mismatch recorded once" do
      assert {:error, "mismatch", st} = Infer.unify(Infer.new(), @int, @string, body("1 + \"x\""))
      assert [%{code: "mismatch", message: msg}] = Infer.errors(st)
      assert msg =~ "expected String, got Int"
      assert msg =~ "1 + \"x\""
    end

    test "arity and shape mismatches" do
      assert {:error, "mismatch", _} =
               Infer.unify(Infer.new(), {:tuple, [@int]}, {:tuple, [@int, @int]})

      assert {:error, "mismatch", _} =
               Infer.unify(Infer.new(), {:arrow, [@int], @int}, {:arrow, [], @int})
    end

    test "an uninstantiated scheme variable is internal" do
      assert {:error, "internal", st} = Infer.unify(Infer.new(), {:var, "a"}, @int)
      assert Infer.stopped?(st)
    end
  end

  describe "instantiate" do
    test "List.map's scheme gets distinct uvars each time" do
      {:def, params, ret} = Map.fetch!(Stdlib.signatures(), "List.map")
      scheme = {:arrow, params, ret}
      {t1, st} = Infer.instantiate(Infer.new(), scheme)
      {t2, _st} = Infer.instantiate(st, scheme)
      assert t1 != t2
      assert Infer.uvar_ids(t1) -- Infer.uvar_ids(t2) == Infer.uvar_ids(t1)
      assert length(Infer.uvar_ids(t1)) == 2
      refute match?({:var, _}, t1)
    end

    test "deftype params are recognised by membership and share a mapping" do
      {t, mapping, _st} =
        Infer.instantiate(
          Infer.new(),
          {:tuple, [{:named, "T"}, {:named, "T"}, @int]},
          MapSet.new(["T"]),
          %{}
        )

      assert {:tuple, [u, u, @int]} = t
      assert %{"T" => ^u} = mapping
    end
  end

  describe "size limits" do
    test "a doubling type stops at type-too-large, not OOM" do
      {t, st} =
        Enum.reduce(1..64, {{:named, "Int"}, Infer.new()}, fn _, {t, st} ->
          {{:tuple, [t, t]}, st}
        end)

      assert {:error, "type-too-large", st} = Infer.check_size(st, t)
      assert Infer.stopped?(st)
    end

    test "the doubling type is also reported when unified" do
      {t, st} =
        Enum.reduce(1..64, {@int, Infer.new()}, fn _, {t, st} -> {{:tuple, [t, t]}, st} end)

      assert {:error, "type-too-large", _} = Infer.unify(st, t, t)
    end

    test "a small type fits" do
      assert {:ok, _} = Infer.check_size(Infer.new(), {:applied, "List", [@int]})
    end

    test "per-declaration work allowance stops a check" do
      st = %{Infer.new() | allowance: 3}
      {:ok, st} = Infer.check_size(st, {:tuple, [@int, @int]})
      assert {:error, "type-too-large", _} = Infer.check_size(st, {:tuple, [@int, @int]})
    end

    test "after stopping, nothing is recorded" do
      st = Infer.stop(Infer.new(), "internal", "x")
      assert Infer.error(st, "mismatch", "y").errors == Infer.errors(st)
    end
  end

  describe "Quote" do
    test "a type is written, and cut over the limit" do
      assert Quote.type({:applied, "List", [@int]}) == "List<Int>"
      assert Quote.type({:arrow, [], @int}) == "(() -> Int)"
      assert Quote.type({:tuple, [@int, @string]}) == "(Int, String)"

      wide = {:tuple, List.duplicate({:named, String.duplicate("x", 30)}, 20)}
      cut = Quote.type(wide)
      assert String.length(cut) == Quote.limit() + 1
      assert String.ends_with?(cut, "…")
    end

    test "residual uvars print ?id, or _ in a lone expression" do
      {u, st} = Infer.fresh(Infer.new())
      assert Infer.format_itype(st, {:applied, "List", [u]}) == "List<?0>"
      assert Infer.format_itype(Infer.lone_expression(st), {:applied, "List", [u]}) == "List<_>"
    end

    test "a small expression quotes as formatted whole" do
      for src <- [
            "1 + \"x\"",
            "case x do A.T.B(y, _) -> [y, 2] end",
            "if a.b do fn (x : List<Int>) -> x end else %A.M{n | x: 1} end",
            "<p class=\"c\" on-click={A.Msg.Go}>hi {x}<i>{%{1 => 2}}</i></p>",
            "([(x : Int)] : List<(Int, Map<String, A.T>)>)",
            "\"#{String.duplicate("x", 300)}\"",
            "[#{Enum.join(List.duplicate("1", 150), ", ")}]"
          ] do
        e = body(src)
        assert Quote.expr(e) == Quote.cut(Format.expr(e)), src
      end
    end

    test "a large expression is cut where the whole would be" do
      e = body("[#{Enum.join(List.duplicate("1", 20_000), ", ")}]")
      q = Quote.expr(e)
      assert q == Quote.cut(Format.expr(e))
      assert String.length(q) == Quote.limit() + 1
      assert String.ends_with?(q, "…")
    end

    test "cuts count code points, not graphemes" do
      s = String.duplicate("e\u0301", 150)
      assert String.length(s) == 150

      assert Quote.cut(s) ==
               s |> String.to_charlist() |> Enum.take(200) |> List.to_string() |> Kernel.<>("…")

      assert Quote.length(Quote.take(s, 200)) == 200
    end

    test "patterns quote" do
      assert Quote.pattern({:pvariant, "A.T.B", [{:pvar, "y"}, :wild]}) == "A.T.B(y, _)"
    end
  end
end

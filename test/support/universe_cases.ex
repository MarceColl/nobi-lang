defmodule Nobi.Lang.UniverseCases do
  @moduledoc """
  The universe tests' generated cases (Rust's proptest strategies in
  `universe/tests.rs`) as seeded `:rand` generators, and the helpers that
  play them. Seed `:rand` before drawing.

  An op is `{:stage, i, changes}` (staged as `"p<i>"`) or `{:unstage, i}`;
  a change is `{:def, source}` or `{:gone, name}`.
  """

  alias Nobi.Lang.{Ast, Parser, Universe}

  @names ~w(a b c d e f)
  @types [
    {"Int", "1", "+"},
    {"String", "\"s\"", "++"},
    {"Bool", "true", "=="},
    {"Float", "1.5", "+"}
  ]

  # ---------- drawing ----------

  @doc "An integer in `lo..hi-1`."
  def int(lo, hi), do: lo + :rand.uniform(hi - lo) - 1

  defp pick(list), do: Enum.at(list, int(0, length(list)))
  defp vec(lo, hi, gen), do: for(_ <- 1..int(lo, hi)//1, do: gen.())

  defp weighted(choices),
    do: weighted(choices, int(0, choices |> Enum.map(&elem(&1, 0)) |> Enum.sum()))

  defp weighted([{w, gen} | rest], roll),
    do: if(roll < w, do: gen.(), else: weighted(rest, roll - w))

  @doc """
  A definition of one of six names. Its body usually fits its type and calls
  one or two names, so it can typecheck, break when a callee changes, and
  depend on two signatures at once.
  """
  def def_src do
    {n, t, body, f, g, other} =
      {int(0, 6), int(0, length(@types)), int(0, 10), int(0, 6), int(0, 6),
       int(0, length(@types))}

    {ty, lit, op} = Enum.at(@types, t)
    {f, g} = {Enum.at(@names, f), Enum.at(@names, g)}

    body =
      cond do
        body in 0..1 -> lit
        body in 2..4 -> "M.#{f}()"
        body in 5..7 and op == "==" -> "M.#{f}() #{Enum.at(["==", "!="], rem(body, 2))} M.#{g}()"
        body in 5..7 -> "M.#{f}() #{op} M.#{g}()"
        body == 8 -> "if M.#{f}() == M.#{g}() do #{lit} else #{lit} end"
        true -> "M.#{f}() #{elem(Enum.at(@types, other), 2)} M.#{g}()"
      end

    "def M.#{Enum.at(@names, n)}() : #{ty} do #{body} end"
  end

  @doc "Committed code to start from: every name, as a literal of some type."
  def base do
    for n <- @names do
      {ty, lit, _} = Enum.at(@types, int(0, length(@types)))
      "def M.#{n}() : #{ty} do #{lit} end"
    end
  end

  @doc "A patch: one to three definitions, or now and then one or two tombstones and up to two definitions."
  def changes do
    gone = fn -> {:gone, "M.#{pick(@names)}"} end
    defn = fn -> {:def, def_src()} end
    weighted([{4, fn -> vec(1, 4, defn) end}, {1, fn -> vec(0, 3, defn) ++ vec(1, 3, gone) end}])
  end

  def op,
    do:
      weighted([
        {5, fn -> {:stage, int(0, 6), changes()} end},
        {1, fn -> {:unstage, int(0, 6)} end}
      ])

  @doc """
  `M.a` changes type, or a quarter of the time is removed, under 1–4
  committed callers. Each caller is fixed by its own staged patch (60%: to
  the new type, or off `M.a` when it goes), or removed by one, or not fixed,
  or "fixed" to a type that never fits. A type change comes after its fixes;
  a removal comes before them. Fixes are staged in random order, and random
  operations follow.
  """
  def fan_in do
    t = int(0, 3)
    shift = int(1, 3)

    fixes =
      vec(1, 5, fn ->
        weighted([{14, fn -> 0 end}, {3, fn -> 1 end}, {3, fn -> 2 end}, {3, fn -> 3 end}])
      end)

    tail = vec(0, 8, &op/0)
    removing = :rand.uniform() < 0.25
    {old, new} = {Enum.at(@types, t), Enum.at(@types, rem(t + shift, 3))}
    never = Enum.at(@types, 3 - t - rem(t + shift, 3))

    callers =
      fixes |> Enum.with_index() |> Enum.map(fn {f, i} -> {i, Enum.at(@names, i + 1), f} end)

    base = [
      "def M.a() : #{elem(old, 0)} do #{elem(old, 1)} end"
      | Enum.map(callers, fn {_, n, _} -> "def M.#{n}() : #{elem(old, 0)} do M.a() end" end)
    ]

    fixed =
      for {i, n, f} <- callers, f != 1 do
        cond do
          f == 3 ->
            {:stage, i, [{:gone, "M.#{n}"}]}

          f == 0 and removing ->
            {:stage, i, [{:def, "def M.#{n}() : #{elem(new, 0)} do #{elem(new, 1)} end"}]}

          true ->
            {:stage, i,
             [{:def, "def M.#{n}() : #{elem(Enum.at([new, new, never], f), 0)} do M.a() end"}]}
        end
      end
      |> Enum.shuffle()

    change =
      if removing,
        do: {:stage, 5, [{:gone, "M.a"}]},
        else: {:stage, 5, [{:def, "def M.a() : #{elem(new, 0)} do #{elem(new, 1)} end"}]}

    ops = if removing, do: [change] ++ fixed ++ tail, else: fixed ++ [change] ++ tail
    {base, ops}
  end

  @doc "Half random sequences over a random committed base, half fan-ins."
  def random_case, do: if(:rand.uniform(2) == 1, do: {base(), vec(1, 24, &op/0)}, else: fan_in())

  @typed [
    [
      "deftype T.A<K> do A(Map<K, Int>) end",
      "deftype T.A<K> do A(K) end",
      "deftype T.A<K> do A(K) | Z end",
      "deftype T.A<K> do A(Map<K, Int>) | Z end"
    ],
    [
      "deftype T.B<K> do B(T.A<K>) end",
      "deftype T.B<K> do B(T.A<K>) | N end",
      "deftype T.B<K> do B(K) end"
    ],
    # A stored model: the evolution rule refuses a retype, a removal and a
    # new mandatory field over a committed version, allows a defaulted one.
    [
      "defmodel T.R do\n  id : Uuid\n  v : Int\nend",
      "defmodel T.R do\n  id : Uuid\n  v : String\nend",
      "defmodel T.R do\n  id : Uuid\n  v : Int\n  w : Int = 0\nend",
      "defmodel T.R do\n  v : Int\nend",
      "defmodel T.R do\n  id : Uuid\n  v : Int\n  w : Int\nend"
    ],
    [
      "def T.f(b : T.B<Int>) : Int do 1 end",
      "def T.f(b : T.B<(Int -> Int)>) : Int do 1 end",
      "def T.f(g : (T.A<Int> -> Int)) : Int do 1 end"
    ],
    ["def T.k() : T.R do %T.R{v: 1} end", "def T.k() : T.R do %T.R{v: \"s\"} end"],
    ["def T.h() : Int do T.k().v end", "def T.h() : String do T.k().v end"],
    [
      "def T.m(a : T.A<Int>) : Int do case a do T.A.A(x) -> 1 end end",
      "def T.m(a : T.A<Int>) : Int do case a do\n  T.A.A(x) -> 1\n  T.A.Z -> 0\nend end",
      "def T.m(a : T.A<Int>) : Int do case a do T.A.A(x) -> x end end"
    ],
    ["deftype T.C<K> do C(K) end", "deftype T.C<K> do C(T.B<K>) end"],
    ["def T.g(c : T.C<(Int -> Int)>) : Int do 1 end", "def T.g(c : T.C<Int>) : Int do 1 end"]
  ]

  @doc """
  Every typed declaration's first version committed, then patches of random
  versions of one to three of them, now and then a tombstone in place of a
  version. They depend on one another through types: map keys, `case`
  coverage, a field reached through a return type, and `T.g` reaching `T.A`
  only once `T.C` nests `T.B`.
  """
  def typed_case do
    change = fn t, v ->
      versions = Enum.at(@typed, t)

      if v >= 12,
        do: {:gone, versions |> hd() |> parse() |> hd() |> Ast.name()},
        else: {:def, Enum.at(versions, rem(v, length(versions)))}
    end

    patch = fn ->
      ts = 0..(length(@typed) - 1) |> Enum.shuffle() |> Enum.take(int(1, 4)) |> Enum.sort()
      Enum.map(ts, &change.(&1, int(0, 14)))
    end

    op = fn ->
      weighted([
        {5, fn -> {:stage, int(0, 6), patch.()} end},
        {1, fn -> {:unstage, int(0, 6)} end}
      ])
    end

    {Enum.map(@typed, &hd/1), vec(1, 16, op)}
  end

  @doc "One op of TS's property: one declaration of `M.a`–`M.d`, which may need one other name at one type, or one tombstone."
  def ts_op do
    name = fn -> pick(~w(a b c d)) end
    {n, sig} = {name.(), int(0, 2)}
    dep = if :rand.uniform(2) == 1, do: {name.(), int(0, 2)}
    lit = &Enum.at(["0", "\"\""], &1)

    body =
      case dep do
        {on, at} when on != n ->
          "if M.#{on}() == #{lit.(at)} do #{lit.(sig)} else #{lit.(sig)} end"

        _ ->
          lit.(sig)
      end

    if :rand.uniform(2) == 1,
      do: {:gone, "M.#{n}"},
      else: {:def, "def M.#{n}() : #{Enum.at(["Int", "String"], sig)} do #{body} end"}
  end

  # ---------- playing ----------

  def parse(src) do
    {:ok, decls} = Parser.program(src)
    decls
  end

  @doc "A patch defining what `src` declares."
  def patch(src), do: Enum.map(parse(src), &{:live, &1})

  def entries(changes) do
    Enum.flat_map(changes, fn
      {:def, src} -> patch(src)
      {:gone, name} -> [{:gone, name}]
    end)
  end

  @doc """
  Play a case on `mod` (`Universe` or `NaiveUniverse`), calling
  `each.(before, op, verdict, after, acc)` around every operation. After
  every other operation, the universe drops every memo nothing holds, as it
  does when they pile up. Returns `{universe, acc}`.
  """
  def play(base, ops, acc, each, mod \\ Universe) do
    {u, _} = mod.stage(mod.new(), "base", patch(Enum.join(base, "\n")))

    ops
    |> Enum.with_index()
    |> Enum.reduce({u, acc}, fn {op, n}, {u, acc} ->
      {after_op, verdict} = run(mod, u, op)
      after_op = if rem(n, 2) == 1, do: Universe.collect(after_op, true), else: after_op
      {after_op, each.(u, op, verdict, after_op, acc)}
    end)
  end

  @doc "One op on `u`: `{u, verdict | nil}`."
  def run(mod, u, {:stage, i, changes}), do: mod.stage(u, "p#{i}", entries(changes))
  def run(mod, u, {:unstage, i}), do: {mod.unstage(u, "p#{i}") |> elem(0), nil}
end

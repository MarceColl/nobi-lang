defmodule Kinoko.Lang.MapStdlibTest do
  @moduledoc """
  The `Map` stdlib (Elixir-only; kinoko-next has none): its signatures as
  the checker sees them, and its bodies called directly with BEAM values.
  """
  use ExUnit.Case, async: true

  import Kinoko.Lang.CheckHelpers

  alias Kinoko.Lang.Rt.Stdlib
  alias Kinoko.Lang.Types.Stdlib, as: Sigs

  @int {:named, "Int"}
  @string {:named, "String"}
  @out {:yabu_error, "evaluation took more than 1000000 steps"}

  defp some(v), do: {:var, "Option", "Some", [v]}
  defp none, do: {:var, "Option", "None", []}
  defp map_of(k, v), do: {:applied, "Map", [k, v]}
  defp list_of(t), do: {:applied, "List", [t]}

  # `[x, x]` forty times over: forty-one nodes in memory, 2^41 - 1 to walk.
  defp doubled(n), do: Enum.reduce(1..n, [1], fn _, x -> [x, x] end)

  @m "m : Map<String, Int>"

  describe "signatures" do
    test "every Map def is a stdlib name, provided by the language" do
      for name <- ~w(Map.get Map.put Map.delete Map.has_key Map.size Map.keys Map.values
                     Map.to_list Map.from_list) do
        assert {:def, _, _} = Sigs.signature(name), name
        assert Sigs.provided?(name), name
        assert name in Sigs.names(), name
        assert {Stdlib, _, _} = Stdlib.function_for(name), name
      end
    end

    test "Map.get answers an Option of the value type" do
      typed = checks(~s|def A.f(#{@m}) : Option<Int> do Map.get(m, "a") end|)
      assert ty(typed) == {:applied, "Option", [@int]}
    end

    test "Map.get's key must be the map's key type" do
      assert first_error(~s|def A.f(#{@m}) : Option<Int> do Map.get(m, 1) end|).code ==
               "mismatch"
    end

    test "Map.put keeps the map's types, and its value must be the value type" do
      typed = checks(~s|def A.f(#{@m}) : Map<String, Int> do Map.put(m, "a", 1) end|)
      assert ty(typed) == map_of(@string, @int)

      assert first_error(~s|def A.f(#{@m}) : Map<String, Int> do Map.put(m, "a", "x") end|).code ==
               "mismatch"
    end

    test "Map.delete, has_key and size" do
      assert ty(checks(~s|def A.f(#{@m}) : Map<String, Int> do Map.delete(m, "a") end|)) ==
               map_of(@string, @int)

      assert ty(checks(~s|def A.f(#{@m}) : Bool do Map.has_key(m, "a") end|)) ==
               {:named, "Bool"}

      assert ty(checks(~s|def A.f(#{@m}) : Int do Map.size(m) end|)) == @int
    end

    test "Map.keys, values and to_list" do
      assert ty(checks(~s|def A.f(#{@m}) : List<String> do Map.keys(m) end|)) == list_of(@string)
      assert ty(checks(~s|def A.f(#{@m}) : List<Int> do Map.values(m) end|)) == list_of(@int)

      assert ty(checks(~s|def A.f(#{@m}) : List<(String, Int)> do Map.to_list(m) end|)) ==
               list_of({:tuple, [@string, @int]})
    end

    test "Map.from_list builds the map its pairs type" do
      typed = checks(~s|def A.f() : Map<String, Int> do Map.from_list([("a", 1)]) end|)
      assert ty(typed) == map_of(@string, @int)
    end

    test "a map built with a function key is refused" do
      src = """
      def A.f() : Int do
        m = Map.from_list([(fn (x : Int) -> x end, 1)])
        0
      end
      """

      assert "non-data-map-key" in Enum.map(errors(src), & &1.code)
    end
  end

  describe "bodies" do
    test "the empty map" do
      assert Stdlib.map_get(%{}, "a") == none()
      assert Stdlib.map_has_key(%{}, "a") == false
      assert Stdlib.map_size(%{}) == 0
      assert Stdlib.map_keys(%{}) == []
      assert Stdlib.map_values(%{}) == []
      assert Stdlib.map_to_list(%{}) == []
      assert Stdlib.map_from_list([]) == %{}
      assert Stdlib.map_delete(%{}, "a") == %{}
    end

    test "get: Some at a key, None at a missing one" do
      m = %{"a" => 1}
      assert Stdlib.map_get(m, "a") == some(1)
      assert Stdlib.map_get(m, "b") == none()
      assert Stdlib.map_has_key(m, "a")
      refute Stdlib.map_has_key(m, "b")
    end

    test "put adds and overwrites, never changing the map it was given" do
      m = %{"a" => 1}
      assert Stdlib.map_put(m, "b", 2) == %{"a" => 1, "b" => 2}
      assert Stdlib.map_put(m, "a", 9) == %{"a" => 9}
      assert m == %{"a" => 1}
      assert Stdlib.map_size(Stdlib.map_put(m, "a", 9)) == 1
    end

    test "delete removes a key; a missing key is a no-op" do
      assert Stdlib.map_delete(%{"a" => 1, "b" => 2}, "a") == %{"b" => 2}
      assert Stdlib.map_delete(%{"a" => 1}, "z") == %{"a" => 1}
    end

    test "keys, values and to_list are in Yabu key order, whatever the insertion order" do
      m =
        Enum.reduce([{"c", 3}, {"a", 1}, {"b", 2}], %{}, fn {k, v}, m ->
          Stdlib.map_put(m, k, v)
        end)

      assert Stdlib.map_keys(m) == ["a", "b", "c"]
      assert Stdlib.map_values(m) == [1, 2, 3]
      assert Stdlib.map_to_list(m) == [{"a", 1}, {"b", 2}, {"c", 3}]

      ints = Stdlib.map_from_list([{10, "x"}, {-5, "y"}, {2, "z"}])
      assert Stdlib.map_keys(ints) == [-5, 2, 10]

      # Keys no native sort orders as Yabu does: None before Some, then by
      # argument; tuples element-wise.
      opts = Stdlib.map_from_list([{some(1), 1}, {none(), 0}, {some(0), 2}])
      assert Stdlib.map_keys(opts) == [none(), some(0), some(1)]

      pairs = Stdlib.map_from_list([{{2, "a"}, 1}, {{1, "b"}, 2}, {{1, "a"}, 3}])
      assert Stdlib.map_keys(pairs) == [{1, "a"}, {1, "b"}, {2, "a"}]
    end

    test "from_list: the last value for a repeated key wins" do
      assert Stdlib.map_from_list([{"a", 1}, {"b", 2}, {"a", 3}]) == %{"a" => 3, "b" => 2}
    end

    test "a key too heavy to hash is the step-budget error, on every keyed path" do
      big = doubled(40)

      # Never let a failure print `big` (inspecting it walks 2^41 nodes).
      outcome = fn f ->
        try do
          f.()
          :answered
        rescue
          e -> {:raised, e.__struct__}
        catch
          :throw, thrown -> thrown
        end
      end

      assert outcome.(fn -> Stdlib.map_get(%{}, big) end) == @out
      assert outcome.(fn -> Stdlib.map_has_key(%{}, big) end) == @out
      assert outcome.(fn -> Stdlib.map_put(%{}, big, 1) end) == @out
      assert outcome.(fn -> Stdlib.map_delete(%{}, big) end) == @out
      assert outcome.(fn -> Stdlib.map_from_list([{big, 1}]) end) == @out
    end
  end
end

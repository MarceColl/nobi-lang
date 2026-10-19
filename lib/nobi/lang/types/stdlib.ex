defmodule Nobi.Lang.Types.Stdlib do
  @moduledoc """
  Stdlib signatures (ported from `types/stdlib.rs`): the 59 rows the checker
  resolves calls against, in the Rust/TS declared order, then the `Map` rows
  this port adds, then `Store.get`/`Store.list`, then `Uuid.to_string`/`Uuid.parse`, then `Cmd.time.after`, then the seven `Float` rows (80 in all). `Cmd.store.tx`
  takes a closure and `Tx.delete` a model and an id (a special form), where
  Rust's took a list of ops and a row. Generic positions use
  lowercase `{:var, "a"}` for defs and `{:var, "T"}` for the `Option`/`Result`
  deftypes. Only what feeds the checker lives here; the evaluator's metadata
  (codegen, effect idempotency) belongs to the interpreter.
  """

  @rows (
          tv = fn n -> {:var, n} end
          nm = fn n -> {:named, n} end
          ap = fn n, args -> {:applied, n, args} end
          arrow = fn ps, r -> {:arrow, ps, r} end
          list = fn t -> {:applied, "List", [t]} end
          option = fn t -> {:applied, "Option", [t]} end
          cmd = fn t -> {:applied, "Cmd", [t]} end

          def_ = fn ps, r ->
            {:def, ps, r, Enum.map(Enum.with_index(ps, 1), &"a#{elem(&1, 1)}")}
          end

          a = tv.("a")
          b = tv.("b")
          k = tv.("k")
          v = tv.("v")
          map = fn k, v -> {:applied, "Map", [k, v]} end
          int = nm.("Int")
          float = nm.("Float")
          str = nm.("String")
          bool = nm.("Bool")
          uuid = nm.("Uuid")
          op = nm.("Tx.Op")
          store = nm.("Store")
          r = tv.("r")
          tuple = fn ts -> {:tuple, ts} end

          [
            # List
            {"List.map", def_.([list.(a), arrow.([a], b)], list.(b))},
            {"List.filter", def_.([list.(a), arrow.([a], bool)], list.(a))},
            {"List.append", def_.([list.(a), a], list.(a))},
            {"List.concat", def_.([list.(a), list.(a)], list.(a))},
            {"List.length", def_.([list.(a)], int)},
            {"List.is_empty", def_.([list.(a)], bool)},
            {"List.foldl", def_.([list.(a), b, arrow.([a, b], b)], b)},
            {"List.sum", def_.([list.(int)], int)},
            {"List.maximum", def_.([list.(int)], option.(int))},
            {"List.minimum", def_.([list.(int)], option.(int))},
            {"List.reverse", def_.([list.(a)], list.(a))},
            {"List.member", def_.([list.(a), a], bool)},
            {"List.all", def_.([list.(a), arrow.([a], bool)], bool)},
            {"List.any", def_.([list.(a), arrow.([a], bool)], bool)},
            {"List.head", def_.([list.(a)], option.(a))},
            {"List.take", def_.([list.(a), int], list.(a))},
            {"List.drop", def_.([list.(a), int], list.(a))},
            {"List.filter_map", def_.([list.(a), arrow.([a], option.(b))], list.(b))},
            {"List.sort_by", def_.([list.(a), arrow.([a], int)], list.(a))},
            # String
            {"String.length", def_.([str], int)},
            {"String.concat", def_.([str, str], str)},
            {"String.from_int", def_.([int], str)},
            {"String.to_int", def_.([str], option.(int))},
            {"String.is_empty", def_.([str], bool)},
            {"String.reverse", def_.([str], str)},
            {"String.trim", def_.([str], str)},
            {"String.to_upper", def_.([str], str)},
            {"String.to_lower", def_.([str], str)},
            {"String.contains", def_.([str, str], bool)},
            {"String.starts_with", def_.([str, str], bool)},
            {"String.split", def_.([str, str], list.(str))},
            {"String.join", def_.([list.(str), str], str)},
            {"String.slice", def_.([str, int, int], str)},
            # Option
            {"Option.with_default", def_.([option.(a), a], a)},
            {"Option.map", def_.([option.(a), arrow.([a], b)], option.(b))},
            {"Option.and_then", def_.([option.(a), arrow.([a], option.(b))], option.(b))},
            # JSON. stringify returns a Result: a function, Cmd or Html is not data.
            {"JSON.parse", def_.([str], ap.("Result", [a, str]))},
            {"JSON.stringify", def_.([a], ap.("Result", [str, str]))},
            # stdlib deftypes
            {"Option", {:type, ["T"], [{"Some", [tv.("T")]}, {"None", []}]}},
            {"Result", {:type, ["T", "E"], [{"Ok", [tv.("T")]}, {"Err", [tv.("E")]}]}},
            # Effects
            {"Cmd.none", def_.([], cmd.(a))},
            {"Cmd.batch", def_.([list.(cmd.(a))], cmd.(a))},
            {"Cmd.store.insert", def_.([a, arrow.([uuid], b)], cmd.(b))},
            {"Cmd.store.list", def_.([arrow.([list.(a)], b)], cmd.(b))},
            {"Cmd.store.get", def_.([uuid, arrow.([option.(a)], b)], cmd.(b))},
            {"Cmd.store.update", def_.([uuid, a, arrow.([uuid], b)], cmd.(b))},
            {"Cmd.store.delete", def_.([uuid, arrow.([option.(a)], b)], cmd.(b))},
            # The closure reads through its `Store` and returns the ops to
            # apply and a value of its own; the callback gets the ids the
            # inserts minted, in order, with that value, or why it failed.
            {"Cmd.store.tx",
             def_.(
               [
                 arrow.([store], tuple.([list.(op), r])),
                 arrow.([ap.("Result", [tuple.([list.(uuid), r]), str])], b)
               ],
               cmd.(b)
             )},
            {"Cmd.time.now", def_.([arrow.([int], a)], cmd.(a))},
            {"Cmd.random.int", def_.([int, int, arrow.([int], a)], cmd.(a))},
            {"Cmd.blob.put", def_.([str, str, arrow.([str], a)], cmd.(a))},
            {"Cmd.blob.get", def_.([str, arrow.([option.(str)], a)], cmd.(a))},
            {"Cmd.blob.list", def_.([str, arrow.([list.(str)], a)], cmd.(a))},
            {"Cmd.blob.delete", def_.([str, arrow.([str], a)], cmd.(a))},
            {"Cmd.ai.generate", def_.([str, str, arrow.([str], a)], cmd.(a))},
            # Tx: a zero-variant type; insert/update/delete build values of it.
            {"Tx.Op", {:type, [], []}},
            {"Tx.insert", def_.([a], op)},
            {"Tx.update", def_.([uuid, a], op)},
            # A special form, `Tx.delete(Model, id)` (`Nobi.Lang.Types.Store`):
            # its first argument names the stored model; never a value.
            {"Tx.delete", def_.([a, uuid], op)},
            # Map (Elixir-only; after the Rust/TS rows so their order holds).
            # Keys and pairs come out in Nobi key order (`Rt.compare/2`).
            {"Map.get", def_.([map.(k, v), k], option.(v))},
            {"Map.put", def_.([map.(k, v), k, v], map.(k, v))},
            {"Map.delete", def_.([map.(k, v), k], map.(k, v))},
            {"Map.has_key", def_.([map.(k, v), k], bool)},
            {"Map.size", def_.([map.(k, v)], int)},
            {"Map.keys", def_.([map.(k, v)], list.(k))},
            {"Map.values", def_.([map.(k, v)], list.(v))},
            {"Map.to_list", def_.([map.(k, v)], list.({:tuple, [k, v]}))},
            {"Map.from_list", def_.([list.({:tuple, [k, v]})], map.(k, v))},
            # Reads inside a `Cmd.store.tx` closure (after the Map rows so
            # every earlier row keeps its rank). `a` is the stored model,
            # taken from the type the result is used at.
            {"Store.get", def_.([store, uuid], option.(a))},
            {"Store.list", def_.([store], list.(a))},
            # Uuid <-> String (after the Store rows so every earlier row
            # keeps its rank): to_string is the canonical lowercase form a
            # route matches; parse takes any case and answers None for
            # anything that is not a UUID.
            {"Uuid.to_string", def_.([uuid], str)},
            {"Uuid.parse", def_.([str], option.(uuid))},
            # A timer (after the Uuid rows so every earlier row keeps its
            # rank): the msg itself, not a callback, delivered to `update`
            # after `ms` milliseconds.
            {"Cmd.time.after", def_.([int, a], cmd.(a))},
            # Float (after the timer so every earlier row keeps its rank).
            # round/floor/ceil give an Int; to_string fixes 0..15 decimals.
            {"Float.from_int", def_.([int], float)},
            {"Float.round", def_.([float], int)},
            {"Float.floor", def_.([float], int)},
            {"Float.ceil", def_.([float], int)},
            {"Float.sqrt", def_.([float], float)},
            {"Float.abs", def_.([float], float)},
            {"Float.to_string", def_.([float, int], str)}
          ]
        )

  @signatures Map.new(@rows)
  @names Enum.map(@rows, &elem(&1, 0))

  @doc "Every stdlib signature, keyed by fully qualified name."
  @spec signatures() :: %{String.t() => Nobi.Lang.Types.Extract.signature()}
  def signatures, do: @signatures

  @doc "Every stdlib name, in the declared (TS `STDLIB`) order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The stdlib's signature of `name`, or `nil` when it has none."
  @spec signature(String.t()) :: Nobi.Lang.Types.Extract.signature() | nil
  def signature(name), do: Map.get(@signatures, name)

  @doc """
  Whether the language itself provides `name`: a stdlib name or a builtin
  type (`Int`, `List`, ...). A check's dependencies leave these out, so a
  patch defining one can change any check (the universe treats it so).
  """
  @spec provided?(String.t()) :: boolean()
  def provided?(name),
    do:
      Map.has_key?(@signatures, name) or name in Nobi.Lang.Types.Extract.builtin_named() or
        Map.has_key?(Nobi.Lang.Types.Extract.builtin_applied(), name)
end

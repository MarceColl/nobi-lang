defmodule Nobi.Lang.Ast do
  @moduledoc """
  The Nobi AST shape and its small helpers (ported from `syntax/ast.rs`).

  Every node is `{kind, meta, args}`; `meta` is a keyword list holding
  `line:` and `col:` after parsing, plus `type:` and `res:` after checking.
  Types and patterns are meta-free values compared structurally.

  Kinds are a closed set written in the parser; names stay strings.
  """

  @type meta :: keyword()
  @type type ::
          {:named, String.t()}
          | {:applied, String.t(), [type]}
          | {:arrow, [type], type}
          | {:tuple, [type]}
          | {:var, String.t()}
  @type node_ :: {atom, meta, list}
  @type decl ::
          {:def | :defmodel | :deftype | :defapp | :deftest | :defroutes, meta, nonempty_list}

  @typedoc "A route pattern's segment; the pattern `/` has none."
  @type segment :: {:lit, String.t()} | {:param, String.t()}
  @typedoc "One route of a `defroutes`: its pattern's segments and the app it opens."
  @type route :: {[segment], String.t()}

  # {atom, symbol, precedence}, in `BinOp::ALL` order. Every operator is
  # left-associative.
  @ops [
    {:or, "or", 1},
    {:and, "and", 2},
    {:==, "==", 3},
    {:!=, "!=", 3},
    {:<, "<", 4},
    {:>, ">", 4},
    {:<=, "<=", 4},
    {:>=, ">=", 4},
    {:++, "++", 5},
    {:+, "+", 6},
    {:-, "-", 6},
    {:*, "*", 7},
    {:/, "/", 7}
  ]

  @doc "Binary operators as `{atom, symbol, precedence}`, in `BinOp::ALL` order."
  @spec ops() :: [{atom, String.t(), 1..7}]
  def ops, do: @ops

  @doc "Unary `not` / `-` bind tighter than every binary operator."
  @spec unary_precedence() :: 8
  def unary_precedence, do: 8

  @doc "The fully qualified name a declaration defines."
  @spec name(decl) :: String.t()
  def name({_kind, _meta, [name | _]}) when is_binary(name), do: name

  @node_kinds ~w(int str bool name list map tuple bin not neg call field construct update case
                 if fn block always sometimes jsx annot def defmodel deftype defapp deftest
                 defroutes)a

  @doc """
  `tree` with no `line:` or `col:` in any node's meta: what its CID names,
  and so equal to the same declaration parsed from anywhere (Rust's AST has
  no positions). Nothing reads positions once a declaration is staged.
  """
  @spec without_positions(term) :: term
  def without_positions({kind, meta, args})
      when kind in @node_kinds and is_list(meta) and is_list(args),
      do: {kind, Keyword.drop(meta, [:line, :col]), without_positions(args)}

  def without_positions(list) when is_list(list), do: Enum.map(list, &without_positions/1)

  def without_positions(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&without_positions/1) |> List.to_tuple()

  def without_positions(other), do: other

  @doc """
  A capitalised head makes a name a dotted global (`Counter.Msg`), a lowercase
  head a local (`total`).
  """
  @spec capitalised?(String.t()) :: boolean
  def capitalised?(<<c, _::binary>>) when c in ?A..?Z, do: true
  def capitalised?(_), do: false
end

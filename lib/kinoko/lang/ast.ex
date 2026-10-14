defmodule Kinoko.Lang.Ast do
  @moduledoc """
  The Yabu AST shape and its small helpers (ported from `syntax/ast.rs`).

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
  @type decl :: {:def | :defmodel | :deftype | :defapp | :deftest, meta, nonempty_list}

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

  @doc """
  A capitalised head makes a name a dotted global (`Counter.Msg`), a lowercase
  head a local (`total`).
  """
  @spec capitalised?(String.t()) :: boolean
  def capitalised?(<<c, _::binary>>) when c in ?A..?Z, do: true
  def capitalised?(_), do: false
end

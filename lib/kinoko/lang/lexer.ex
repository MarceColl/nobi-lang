defmodule Kinoko.Lang.Lexer do
  @moduledoc """
  Source text to tokens (port of `syntax/lexer.rs`).

  A token is `{kind, value, line, col}`, with 1-based line and column counted
  in characters. Kinds:

      :name        value = identifier; a capitalised head absorbs following
                   `.ident` parts (`Counter.Msg.Add`). Keywords are plain names;
                   the parser decides which are keywords.
      :int         value = integer (must fit i64)
      :str         value = decoded string
      :op          value = "==" "!=" "<=" ">=" "++" "<" ">" "+" "-" "*" "/"
      :lparen :rparen :lbracket :rbracket :lbrace :rbrace
      :arrow ("->") :fat_arrow ("=>") :eq :colon :comma :dot :pipe :percent
      :newline     a newline plus every following blank line and indentation
      :eof

  `<` is always an `:op`: whether it starts JSX or is less-than is the
  parser's decision, where an operand is expected. Because JSX bodies are not
  tokenisable in normal mode, `tokens/1` only suits JSX-free source; the parser
  drives the streaming cursor (`new/1`, `next_token/1`) and switches to the raw
  functions (`jsx_text/1`, `jsx_name/1`, `raw_consume/2`, ...) inside elements.

  Errors are `%{code: "parse", message:, line:, col:}`.
  """

  defstruct rest: "", line: 1, col: 1

  @type t :: %__MODULE__{rest: binary, line: pos_integer, col: pos_integer}
  @type token :: {atom, term, pos_integer, pos_integer}
  @type error :: %{code: String.t(), message: String.t(), line: pos_integer, col: pos_integer}

  @i64_max 9_223_372_036_854_775_807

  @doc "Tokenise a whole source. Ends with an `:eof` token."
  @spec tokens(String.t()) :: {:ok, [token]} | {:error, error}
  def tokens(src) when is_binary(src) do
    if String.valid?(src) do
      collect(new(src), [])
    else
      {:error, error(1, 1, "source is not valid UTF-8")}
    end
  end

  defp collect(lexer, acc) do
    case next_token(lexer) do
      {:ok, {:eof, _, _, _} = tok, _} -> {:ok, Enum.reverse([tok | acc])}
      {:ok, tok, lexer} -> collect(lexer, [tok | acc])
      {:error, _} = err -> err
    end
  end

  @doc "A cursor at the start of `src` (CRLF is normalised to LF)."
  @spec new(String.t()) :: t
  def new(src), do: %__MODULE__{rest: String.replace(src, "\r\n", "\n")}

  @doc "Where the cursor is, as `{line, col}`."
  @spec position(t) :: {pos_integer, pos_integer}
  def position(%__MODULE__{line: l, col: c}), do: {l, c}

  @doc "The next normal-mode token and the advanced cursor."
  @spec next_token(t) :: {:ok, token, t} | {:error, error}
  def next_token(%__MODULE__{} = lx), do: lx |> skip_inline_space() |> dispatch()

  defp skip_inline_space(%{rest: <<c, rest::binary>>} = lx) when c in [?\s, ?\t, ?\r],
    do: skip_inline_space(advance(lx, c, rest))

  defp skip_inline_space(lx), do: lx

  defp dispatch(%{rest: "", line: l, col: c} = lx), do: {:ok, {:eof, nil, l, c}, lx}

  defp dispatch(%{rest: <<?\n, _::binary>>, line: l, col: c} = lx),
    do: {:ok, {:newline, nil, l, c}, skip_blank(lx)}

  defp dispatch(%{rest: <<d, _::binary>>} = lx) when d in ?0..?9, do: int(lx)

  defp dispatch(%{rest: <<c, _::binary>>} = lx) when c in ?a..?z or c in ?A..?Z or c == ?_,
    do: name(lx)

  defp dispatch(%{rest: <<?", rest::binary>>, line: l, col: c} = lx),
    do: string(advance(lx, ?", rest), l, c, [])

  defp dispatch(lx), do: punct(lx)

  defp skip_blank(%{rest: <<c, rest::binary>>} = lx) when c in [?\n, ?\s, ?\t, ?\r],
    do: skip_blank(advance(lx, c, rest))

  defp skip_blank(lx), do: lx

  # ---------- ints ----------

  defp int(%{line: l, col: c} = lx) do
    {digits, lx} = take_ascii(lx, &(&1 in ?0..?9))
    n = String.to_integer(digits)

    if n > @i64_max do
      {:error, error(l, c, "integer literal is too large (limit #{@i64_max})")}
    else
      {:ok, {:int, n, l, c}, lx}
    end
  end

  # ---------- names ----------

  defp name(%{line: l, col: c} = lx) do
    {head, lx} = take_ascii(lx, &ident_char?/1)

    {full, lx} =
      if head =~ ~r/\A[A-Z]/, do: dotted(lx, head), else: {head, lx}

    {:ok, {:name, full, l, c}, lx}
  end

  # A capitalised head joins every following `.ident`.
  defp dotted(%{rest: <<?., s, _::binary>>} = lx, acc)
       when s in ?a..?z or s in ?A..?Z or s == ?_ do
    <<?., rest::binary>> = lx.rest
    {part, lx} = take_ascii(advance(lx, ?., rest), &ident_char?/1)
    dotted(lx, acc <> "." <> part)
  end

  defp dotted(lx, acc), do: {acc, lx}

  defp ident_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  # Takes a run of ASCII characters matching `pred` (one byte = one column).
  defp take_ascii(%{rest: rest, col: col} = lx, pred) do
    n = count_while(rest, pred, 0)
    <<taken::binary-size(n), rest::binary>> = rest
    {taken, %{lx | rest: rest, col: col + n}}
  end

  defp count_while(<<c, rest::binary>>, pred, n) do
    if pred.(c), do: count_while(rest, pred, n + 1), else: n
  end

  defp count_while(<<>>, _pred, n), do: n

  # ---------- strings ----------

  defp string(%{rest: ""}, l, c, _acc), do: {:error, error(l, c, "unterminated string")}

  defp string(%{rest: <<?\n, _::binary>>}, l, c, _acc),
    do: {:error, error(l, c, "newline in string literal")}

  defp string(%{rest: <<?", rest::binary>>} = lx, l, c, acc),
    do: {:ok, {:str, acc |> Enum.reverse() |> IO.iodata_to_binary(), l, c}, advance(lx, ?", rest)}

  defp string(%{rest: <<?\\, rest::binary>>} = lx, l, c, acc) do
    lx = advance(lx, ?\\, rest)

    case lx.rest do
      "" ->
        # A backslash at EOF still moves the cursor once more (as in the TS
        # lexer): reported as an unknown escape, one column past.
        {:error, error(lx.line, lx.col + 1, "unknown escape \\")}

      <<e::utf8, rest::binary>> ->
        lx = advance(lx, e, rest)

        case escape(e) do
          {:ok, ch} -> string(lx, l, c, [ch | acc])
          :error -> {:error, error(lx.line, lx.col, "unknown escape \\" <> <<e::utf8>>)}
        end
    end
  end

  defp string(%{rest: <<ch::utf8, rest::binary>>} = lx, l, c, acc),
    do: string(advance(lx, ch, rest), l, c, [<<ch::utf8>> | acc])

  defp escape(?"), do: {:ok, "\""}
  defp escape(?\\), do: {:ok, "\\"}
  defp escape(?n), do: {:ok, "\n"}
  defp escape(?t), do: {:ok, "\t"}
  defp escape(?r), do: {:ok, "\r"}
  defp escape(_), do: :error

  # ---------- punctuation (longest match first) ----------

  @puncts [
    {"->", :arrow},
    {"=>", :fat_arrow},
    {"==", :op},
    {"!=", :op},
    {"<=", :op},
    {">=", :op},
    {"++", :op},
    {"(", :lparen},
    {")", :rparen},
    {"[", :lbracket},
    {"]", :rbracket},
    {"{", :lbrace},
    {"}", :rbrace},
    {"<", :op},
    {">", :op},
    {"+", :op},
    {"-", :op},
    {"*", :op},
    {"/", :op},
    {"=", :eq},
    {":", :colon},
    {",", :comma},
    {".", :dot},
    {"|", :pipe},
    {"%", :percent}
  ]

  for {p, kind} <- @puncts do
    value = if kind == :op, do: p, else: nil
    size = byte_size(p)

    defp punct(%{rest: <<unquote(p), rest::binary>>, line: l, col: c} = lx),
      do: {:ok, {unquote(kind), unquote(value), l, c}, %{lx | rest: rest, col: c + unquote(size)}}
  end

  defp punct(%{rest: <<ch::utf8, _::binary>>, line: l, col: c}),
    do: {:error, error(l, c, "unexpected character '" <> <<ch::utf8>> <> "'")}

  # ---------- JSX raw mode ----------

  @doc "Raw text up to (not including) `<` or `{`."
  @spec jsx_text(t) :: {:ok, String.t(), t} | {:error, error}
  def jsx_text(%__MODULE__{line: l, col: c} = lx), do: jsx_text(lx, l, c, [])

  defp jsx_text(%{rest: ""}, l, c, _acc), do: {:error, error(l, c, "unterminated JSX element")}

  defp jsx_text(%{rest: <<ch, _::binary>>} = lx, _l, _c, acc) when ch in [?<, ?{],
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), lx}

  defp jsx_text(%{rest: <<ch::utf8, rest::binary>>} = lx, l, c, acc),
    do: jsx_text(advance(lx, ch, rest), l, c, [<<ch::utf8>> | acc])

  @doc "Skip Unicode whitespace (including newlines)."
  @spec skip_raw_whitespace(t) :: t
  def skip_raw_whitespace(%{rest: <<ch::utf8, rest::binary>>} = lx) do
    if whitespace?(ch), do: skip_raw_whitespace(advance(lx, ch, rest)), else: lx
  end

  def skip_raw_whitespace(lx), do: lx

  @doc "The next character (codepoint) without consuming it, or nil. Does not skip whitespace."
  @spec raw_peek(t) :: non_neg_integer | nil
  def raw_peek(%{rest: <<ch::utf8, _::binary>>}), do: ch
  def raw_peek(_), do: nil

  @doc "The character after the one `raw_peek/1` returns, or nil."
  @spec raw_peek2(t) :: non_neg_integer | nil
  def raw_peek2(%{rest: <<_::utf8, ch::utf8, _::binary>>}), do: ch
  def raw_peek2(_), do: nil

  @doc "Skip leading whitespace, then consume `expected` exactly."
  @spec raw_consume(t, String.t()) :: {:ok, t} | {:error, error}
  def raw_consume(lx, expected) do
    %{line: l, col: c} = lx = skip_raw_whitespace(lx)

    case lx.rest do
      <<^expected::binary-size(byte_size(expected)), _::binary>> ->
        {:ok, consume_chars(lx, String.length(expected))}

      _ ->
        {:error, error(l, c, "expected '#{expected}'")}
    end
  end

  defp consume_chars(lx, 0), do: lx

  defp consume_chars(%{rest: <<ch::utf8, rest::binary>>} = lx, n),
    do: consume_chars(advance(lx, ch, rest), n - 1)

  @doc "A JSX tag or attribute name, `[A-Za-z_][A-Za-z0-9_-]*` (so `on-click` is one name)."
  @spec jsx_name(t) :: {:ok, String.t(), t} | {:error, error}
  def jsx_name(lx) do
    %{line: l, col: c} = lx = skip_raw_whitespace(lx)

    case lx.rest do
      <<s, _::binary>> when s in ?a..?z or s in ?A..?Z or s == ?_ ->
        {name, lx} = take_ascii(lx, &(ident_char?(&1) or &1 == ?-))
        {:ok, name, lx}

      _ ->
        {:error, error(l, c, "expected a JSX name")}
    end
  end

  # ---------- helpers ----------

  defp advance(%{line: l} = lx, ?\n, rest), do: %{lx | rest: rest, line: l + 1, col: 1}
  defp advance(%{col: c} = lx, _ch, rest), do: %{lx | rest: rest, col: c + 1}

  defp error(line, col, message), do: %{code: "parse", message: message, line: line, col: col}

  # Rust `char::is_whitespace`.
  defp whitespace?(c),
    do:
      c in 9..13 or c == 32 or c == 0x85 or c == 0xA0 or c == 0x1680 or c in 0x2000..0x200A or
        c in [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
end

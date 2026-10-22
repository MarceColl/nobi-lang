defmodule Nobi.Lang.Lexer do
  @moduledoc """
  Source text to tokens (port of `syntax/lexer.rs`).

  A token is `{kind, value, line, col}`, with 1-based line and column counted
  in characters. Kinds:

      :name        value = identifier; a capitalised head absorbs following
                   `.ident` parts (`Counter.Msg.Add`). Keywords are plain names;
                   the parser decides which are keywords.
      :int         value = integer (at most `Rt.max_int_digits/0` digits)
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
  def new(src) do
    # No copy of a source without CRLF (the common case).
    src =
      if :binary.match(src, "\r\n") == :nomatch, do: src, else: String.replace(src, "\r\n", "\n")

    %__MODULE__{rest: src}
  end

  @doc "Where the cursor is, as `{line, col}`."
  @spec position(t) :: {pos_integer, pos_integer}
  def position(%__MODULE__{line: l, col: c}), do: {l, c}

  @doc "The next normal-mode token and the advanced cursor."
  @spec next_token(t) :: {:ok, token, t} | {:error, error}
  def next_token(%__MODULE__{} = lx), do: lx |> skip_inline_space() |> dispatch()

  defp skip_inline_space(%{rest: rest, col: col} = lx) do
    case inline_run(rest, 0) do
      0 ->
        lx

      n ->
        <<_::binary-size(n), rest::binary>> = rest
        %{lx | rest: rest, col: col + n}
    end
  end

  defp inline_run(<<c, rest::binary>>, n) when c in [?\s, ?\t, ?\r], do: inline_run(rest, n + 1)
  defp inline_run(_, n), do: n

  defp dispatch(%{rest: "", line: l, col: c} = lx), do: {:ok, {:eof, nil, l, c}, lx}

  defp dispatch(%{rest: <<?\n, _::binary>>, line: l, col: c} = lx),
    do: {:ok, {:newline, nil, l, c}, skip_blank(lx)}

  defp dispatch(%{rest: <<d, _::binary>>} = lx) when d in ?0..?9, do: int(lx)

  defp dispatch(%{rest: <<c, _::binary>>} = lx) when c in ?a..?z or c in ?A..?Z or c == ?_,
    do: name(lx)

  defp dispatch(%{rest: <<?", rest::binary>>, line: l, col: c} = lx),
    do: string(advance(lx, ?", rest), l, c, [])

  defp dispatch(lx), do: punct(lx)

  defp skip_blank(%{rest: rest, line: line, col: col}), do: blank_run(rest, line, col)

  defp blank_run(<<?\n, rest::binary>>, line, _col), do: blank_run(rest, line + 1, 1)

  defp blank_run(<<c, rest::binary>>, line, col) when c in [?\s, ?\t, ?\r],
    do: blank_run(rest, line, col + 1)

  defp blank_run(rest, line, col), do: %__MODULE__{rest: rest, line: line, col: col}

  # ---------- ints ----------

  defp int(%{line: l, col: c} = lx) do
    {digits, lx} = take_ascii(lx, :digit)
    max = Nobi.Lang.Rt.max_int_digits()

    if byte_size(digits) > max do
      {:error, error(l, c, "integer literal is too long (limit #{max} digits)")}
    else
      {:ok, {:int, String.to_integer(digits), l, c}, lx}
    end
  end

  # ---------- names ----------

  defp name(%{line: l, col: c} = lx) do
    {head, lx} = take_ascii(lx, :ident)

    {full, lx} =
      if Nobi.Lang.Ast.capitalised?(head), do: dotted(lx, head), else: {head, lx}

    # Copy: a name kept in a tree must not be a sub-binary of the whole source
    # (that made GC of a big parsed program ~2.5x slower and pinned the source).
    {:ok, {:name, :binary.copy(full), l, c}, lx}
  end

  # A capitalised head joins every following `.ident`.
  defp dotted(%{rest: <<?., s, _::binary>>} = lx, acc)
       when s in ?a..?z or s in ?A..?Z or s == ?_ do
    <<?., rest::binary>> = lx.rest
    {part, lx} = take_ascii(advance(lx, ?., rest), :ident)
    dotted(lx, acc <> "." <> part)
  end

  defp dotted(lx, acc), do: {acc, lx}

  # Takes a run of ASCII characters matching `pred` (one byte = one column).
  defp take_ascii(%{rest: rest, col: col} = lx, pred) do
    n = count_while(rest, pred, 0)
    <<taken::binary-size(n), rest::binary>> = rest
    {taken, %{lx | rest: rest, col: col + n}}
  end

  defp count_while(<<c, rest::binary>>, :digit, n) when c in ?0..?9,
    do: count_while(rest, :digit, n + 1)

  defp count_while(<<c, rest::binary>>, :ident, n)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: count_while(rest, :ident, n + 1)

  defp count_while(<<c, rest::binary>>, :jsx_ident, n)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?-,
       do: count_while(rest, :jsx_ident, n + 1)

  defp count_while(_, _kind, n), do: n

  # ---------- strings ----------

  defp string(%{rest: ""}, l, c, _acc), do: {:error, error(l, c, "unterminated string")}

  defp string(%{rest: <<?\n, _::binary>>}, l, c, _acc),
    do: {:error, error(l, c, "newline in string literal")}

  defp string(%{rest: <<?", rest::binary>>} = lx, l, c, acc),
    do:
      {:ok, {:str, acc |> Enum.reverse() |> IO.iodata_to_binary() |> :binary.copy(), l, c},
       advance(lx, ?", rest)}

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
          :error -> {:error, error(lx.line, lx.col, "unknown escape \\" <> shown(e))}
        end
    end
  end

  # A run of plain characters at once: one chunk and one cursor update,
  # not one of each per character.
  defp string(%{rest: rest, col: col} = lx, l, c, acc) do
    case plain_run(rest, 0, 0) do
      {0, _} ->
        # Not valid UTF-8 here: never, `tokens/1` checks it first.
        {:error, error(lx.line, col, "source is not valid UTF-8")}

      {bytes, chars} ->
        <<chunk::binary-size(bytes), rest::binary>> = rest
        string(%{lx | rest: rest, col: col + chars}, l, c, [chunk | acc])
    end
  end

  # Bytes and characters of the longest run of characters that are none of
  # `"`, `\\`, newline (a string's plain text; also stops at invalid UTF-8).
  defp plain_run(<<c, _::binary>>, b, n) when c in [?", ?\\, ?\n], do: {b, n}
  defp plain_run(<<c, rest::binary>>, b, n) when c < 0x80, do: plain_run(rest, b + 1, n + 1)

  defp plain_run(<<ch::utf8, rest::binary>>, b, n),
    do: plain_run(rest, b + byte_size(<<ch::utf8>>), n + 1)

  defp plain_run(_, b, n), do: {b, n}

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
    do: {:error, error(l, c, "unexpected character " <> quoted(ch))}

  # ---------- JSX raw mode ----------

  @doc "Raw text up to (not including) `<` or `{`."
  @spec jsx_text(t) :: {:ok, String.t(), t} | {:error, error}
  def jsx_text(%__MODULE__{line: l, col: c} = lx), do: jsx_text(lx, l, c, [])

  defp jsx_text(%{rest: ""}, l, c, _acc), do: {:error, error(l, c, "unterminated JSX element")}

  defp jsx_text(%{rest: <<ch, _::binary>>} = lx, _l, _c, acc) when ch in [?<, ?{],
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary() |> :binary.copy(), lx}

  defp jsx_text(%{rest: <<?\n, rest::binary>>} = lx, l, c, acc),
    do: jsx_text(advance(lx, ?\n, rest), l, c, ["\n" | acc])

  defp jsx_text(%{rest: rest, col: col} = lx, l, c, acc) do
    case text_run(rest, 0, 0) do
      {0, _} ->
        {:error, error(lx.line, col, "source is not valid UTF-8")}

      {bytes, chars} ->
        <<chunk::binary-size(bytes), rest::binary>> = rest
        jsx_text(%{lx | rest: rest, col: col + chars}, l, c, [chunk | acc])
    end
  end

  # `plain_run/3` for JSX text: stops at `<`, `{` and newline.
  defp text_run(<<c, _::binary>>, b, n) when c in [?<, ?{, ?\n], do: {b, n}
  defp text_run(<<c, rest::binary>>, b, n) when c < 0x80, do: text_run(rest, b + 1, n + 1)

  defp text_run(<<ch::utf8, rest::binary>>, b, n),
    do: text_run(rest, b + byte_size(<<ch::utf8>>), n + 1)

  defp text_run(_, b, n), do: {b, n}

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
        {name, lx} = take_ascii(lx, :jsx_ident)
        {:ok, :binary.copy(name), lx}

      _ ->
        {:error, error(l, c, "expected a JSX name")}
    end
  end

  # ---------- helpers ----------

  defp advance(%{line: l} = lx, ?\n, rest), do: %{lx | rest: rest, line: l + 1, col: 1}
  defp advance(%{col: c} = lx, _ch, rest), do: %{lx | rest: rest, col: c + 1}

  defp error(line, col, message), do: %{code: "parse", message: message, line: line, col: col}

  # A character as a message shows it: quoted, or as `U+XXXX` when printing
  # it raw would hide it or reorder the text around it (controls, bidi
  # controls, zero-width and other format characters, separators).
  defp quoted(ch), do: if(invisible?(ch), do: shown(ch), else: "'" <> <<ch::utf8>> <> "'")

  defp shown(ch) do
    if invisible?(ch),
      do: "U+" <> String.pad_leading(Integer.to_string(ch, 16), 4, "0"),
      else: <<ch::utf8>>
  end

  defp invisible?(ch),
    do:
      ch < 0x20 or ch in 0x7F..0x9F or ch == 0xAD or ch in 0x200B..0x200F or
        ch in 0x2028..0x202E or ch in 0x2060..0x206F or ch == 0xFEFF or ch in 0xFFF9..0xFFFB or
        ch == 0x061C or ch == 0x180E or (ch != 0x20 and whitespace?(ch))

  # Rust `char::is_whitespace`.
  defp whitespace?(c),
    do:
      c in 9..13 or c == 32 or c == 0x85 or c == 0xA0 or c == 0x1680 or c in 0x2000..0x200A or
        c in [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
end

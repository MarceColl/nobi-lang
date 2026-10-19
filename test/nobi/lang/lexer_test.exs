defmodule Nobi.Lang.LexerTest do
  use ExUnit.Case, async: true

  alias Nobi.Lang.{Ast, Lexer}

  defp kinds(src) do
    assert {:ok, toks} = Lexer.tokens(src)
    Enum.map(toks, &elem(&1, 0))
  end

  defp values(src) do
    assert {:ok, toks} = Lexer.tokens(src)
    Enum.map(toks, &elem(&1, 1))
  end

  defp err(src) do
    assert {:error, %{code: "parse"} = e} = Lexer.tokens(src)
    {e.message, e.line, e.col}
  end

  test "dotted names, ints, strings with unicode" do
    assert {:ok, toks} = Lexer.tokens(~s|Counter.Msg.Add(10) ++ "猫"|)
    assert Enum.map(toks, &elem(&1, 0)) == [:name, :lparen, :int, :rparen, :op, :str, :eof]

    assert Enum.map(toks, &elem(&1, 1)) |> Enum.take(6) == [
             "Counter.Msg.Add",
             nil,
             10,
             nil,
             "++",
             "猫"
           ]
  end

  test "an int past i64 is a parse error" do
    assert {:error, %{code: "parse"}} = Lexer.tokens("9223372036854775808")

    assert err("9223372036854775808") ==
             {"integer literal is too large (limit 9223372036854775807)", 1, 1}
  end

  test "i64 max lexes, leading zeros are digits" do
    assert values("9223372036854775807") == [9_223_372_036_854_775_807, nil]
    assert values("0 42 007") == [0, 42, 7, nil]
  end

  test "CRLF lexes like LF" do
    assert {:ok, a} = Lexer.tokens("def A.f() : Int do\r\n  1\r\nend")
    assert {:ok, b} = Lexer.tokens("def A.f() : Int do\n  1\nend")
    assert Enum.map(a, &Tuple.delete_at(&1, 3)) == Enum.map(b, &Tuple.delete_at(&1, 3))
  end

  test "every punctuation lexes alone, longest match first" do
    for {p, kind} <- [
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
        ] do
      assert {:ok, [{^kind, _, 1, 1}, {:eof, _, 1, _}]} = Lexer.tokens(p), "lexing #{p}"
    end

    assert kinds("-> => == != <= >= ++") == [:arrow, :fat_arrow, :op, :op, :op, :op, :op, :eof]
  end

  test "identifiers and keywords are plain names" do
    assert values("_fooBar123 do end") == ["_fooBar123", "do", "end", nil]
    assert kinds("do fn case") == [:name, :name, :name, :eof]
  end

  test "dots join only after a capitalised head" do
    assert kinds("Counter.Msg.Add") == [:name, :eof]
    assert kinds("model.count") == [:name, :dot, :name, :eof]
    assert kinds("Counter.count") == [:name, :eof]
    assert kinds("a.") == [:name, :dot, :eof]
    assert kinds("A. ") == [:name, :dot, :eof]
  end

  test "newline and following blank lines and indentation collapse to one token" do
    assert kinds("a\n\n\nb") == [:name, :newline, :name, :eof]
    assert kinds("a\n    \n\nb") == [:name, :newline, :name, :eof]
  end

  test "string escapes decode" do
    assert values(~S|"\n\t\r\"\\"|) == ["\n\t\r\"\\", nil]
    assert values(~s|"señor ☃"|) == ["señor ☃", nil]
  end

  test "string errors" do
    assert err(~S|"\q"|) == {"unknown escape \\q", 1, 4}
    assert err("\"abc\ndef\"") == {"newline in string literal", 1, 1}
    assert err("\"abc") == {"unterminated string", 1, 1}
    assert err("\"abc\\") == {"unknown escape \\", 1, 7}
  end

  test "a string's position after it counts characters, not bytes" do
    assert {:ok, [{:str, "ñ☃é", 1, 1}, {:name, "x", 1, 7}, _]} = Lexer.tokens(~s|"ñ☃é" x|)
    assert {:ok, [{:str, "a\\tb", 1, 1}, {:name, "x", 1, 9}, _]} = Lexer.tokens(~S|"a\\tb" x|)
  end

  test "a message shows control, bidi and zero-width characters as code points" do
    assert err("\u0007") == {"unexpected character U+0007", 1, 1}
    assert err("\u202E") == {"unexpected character U+202E", 1, 1}
    assert err("\u200B") == {"unexpected character U+200B", 1, 1}
    assert err("\uFEFF") == {"unexpected character U+FEFF", 1, 1}
    assert err("\u00A0") == {"unexpected character U+00A0", 1, 1}
    assert err("\"\\\u2066\"") == {"unknown escape \\U+2066", 1, 4}
    assert err("é") == {"unexpected character 'é'", 1, 1}
  end

  test "no comments" do
    assert err("#") == {"unexpected character '#'", 1, 1}
    assert kinds("//") == [:op, :op, :eof]
  end

  test "positions are 1-based characters after leading whitespace" do
    assert {:ok, [{:name, "abc", 1, 4}, _]} = Lexer.tokens("   abc")
    assert {:ok, [_, _, {:name, "bb", 2, 1}, _]} = Lexer.tokens("a\nbb")
    assert err("\"ñ\" é") == {"unexpected character 'é'", 1, 5}
  end

  describe "cursor and JSX raw mode" do
    test "next_token streams and ends with eof" do
      s = Lexer.new("a 1")
      assert {:ok, {:name, "a", 1, 1}, s} = Lexer.next_token(s)
      assert {:ok, {:int, 1, 1, 3}, s} = Lexer.next_token(s)
      assert {:ok, {:eof, nil, 1, 4}, _} = Lexer.next_token(s)
    end

    test "jsx_text stops at < or {" do
      assert {:ok, "hello world", s} = Lexer.jsx_text(Lexer.new("hello world<div>"))
      assert Lexer.raw_peek(s) == ?<
      assert {:ok, "hi ", s} = Lexer.jsx_text(Lexer.new("hi {x}"))
      assert Lexer.raw_peek(s) == ?{
    end

    test "jsx_text at eof is an unterminated element" do
      assert {:error, %{code: "parse", message: "unterminated JSX element", line: 1, col: 1}} =
               Lexer.jsx_text(Lexer.new("no closing tag"))
    end

    test "raw peeks" do
      s = Lexer.skip_raw_whitespace(Lexer.new("   <div"))
      assert Lexer.raw_peek(s) == ?<
      assert Lexer.raw_peek2(s) == ?d
      assert Lexer.raw_peek(Lexer.new("  x")) == ?\s
      assert Lexer.raw_peek(Lexer.new("")) == nil
      assert Lexer.raw_peek2(Lexer.new("")) == nil
    end

    test "raw_consume" do
      assert {:ok, s} = Lexer.raw_consume(Lexer.new("  />rest"), "/>")
      assert Lexer.raw_peek(s) == ?r

      assert {:error, %{message: "expected '/>'"}} = Lexer.raw_consume(Lexer.new("  >rest"), "/>")
    end

    test "jsx_name allows hyphens and needs an identifier start" do
      assert {:ok, "on-click", s} = Lexer.jsx_name(Lexer.new("on-click="))
      assert Lexer.raw_peek(s) == ?=
      assert {:error, %{message: "expected a JSX name"}} = Lexer.jsx_name(Lexer.new("123abc"))
    end

    test "position tracks lines through raw mode" do
      assert {:ok, _, s} = Lexer.jsx_text(Lexer.new("ab\ncd<"))
      assert Lexer.position(s) == {2, 3}
    end
  end

  describe "Ast helpers" do
    test "ops table in BinOp::ALL order" do
      assert Ast.ops() == [
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

      assert Ast.unary_precedence() == 8
    end

    test "name/1 and capitalised?/1" do
      assert Ast.name({:def, [line: 1, col: 1], ["A.f", [], {:named, "Int"}, nil]}) == "A.f"
      assert Ast.name({:defapp, [], ["Counter"]}) == "Counter"
      assert Ast.capitalised?("Counter")
      refute Ast.capitalised?("counter")
      refute Ast.capitalised?("_X")
      refute Ast.capitalised?("")
    end
  end

  describe "floats" do
    test "a fraction or an exponent makes a Float" do
      assert values("1.5 2.0e-3 1e3 1E+2 0.25") == [1.5, 0.002, 1000.0, 100.0, 0.25, nil]
      assert kinds("1.5 1e3") == [:float, :float, :eof]
    end

    test "a dot before a name, or a bare e, is not a Float" do
      assert kinds("x.f") == [:name, :dot, :name, :eof]
      assert kinds("1.f") == [:int, :dot, :name, :eof]
      assert kinds("x.1") == [:name, :dot, :int, :eof]
      assert kinds("7e") == [:int, :name, :eof]
      assert kinds("1..2") == [:int, :dot, :dot, :int, :eof]
    end

    test "past the largest double is a parse error" do
      assert err("x = 1.0e400") == {"float literal is out of range", 1, 5}
      assert values("1e300") == [1.0e300, nil]
    end
  end
end

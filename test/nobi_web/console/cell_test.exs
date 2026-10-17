defmodule NobiWeb.Console.CellTest do
  use ExUnit.Case, async: true

  alias NobiWeb.Console.Cell

  @models %{"A.Row" => [{"id", {:named, "Uuid"}, :none}, {"n", {:named, "Int"}, :none}]}

  test "a scalar reads as a person reads it" do
    assert Cell.text(42, @models) == "42"
    assert Cell.text(-3, @models) == "-3"
    assert Cell.text("hi \"there\"", @models) == "hi \"there\""

    assert Cell.text({:uuid, "0b9e2c4a-1111-4222-8333-444455556666"}, @models) ==
             "0b9e2c4a-1111-4222-8333-444455556666"

    assert Cell.text(true, @models) == "true"
    assert Cell.text(false, @models) == "false"
  end

  test "an Option is its value or blank" do
    assert Cell.text({:var, "Option", "None", []}, @models) == ""
    assert Cell.text({:var, "Option", "Some", ["x"]}, @models) == "x"
    assert Cell.text({:var, "Option", "Some", [7]}, @models) == "7"
  end

  test "a compound is compact JSON" do
    assert Cell.text(["a", "b"], @models) == ~s(["a","b"])
    assert Cell.text(%{"k" => 1}, @models) == ~s({"k":1})

    assert Cell.text({:rec, "A.Row", %{"id" => {:uuid, "u"}, "n" => 1}}, @models) ==
             ~s({"id":"u","n":1})
  end

  test "an Int column is numeric" do
    assert Cell.numeric?({:named, "Int"})
    refute Cell.numeric?({:named, "String"})
    refute Cell.numeric?({:applied, "Option", [{:named, "Int"}]})
  end
end

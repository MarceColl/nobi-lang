defmodule NobiWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias NobiWeb.CoreComponents

  test "icon renders a hero icon span" do
    assigns = %{}

    html = rendered_to_string(~H|<CoreComponents.icon name="hero-x-mark" class="size-5" />|)

    assert html =~ ~s(class="hero-x-mark size-5")
  end

  test "icon renders a Phosphor icon span" do
    assigns = %{}

    html = rendered_to_string(~H|<CoreComponents.icon name="ph-graph" class="text-[13px]" />|)

    assert html =~ ~s(class="ph-graph text-[13px]")
  end

  test "Phosphor icon has no default size so it follows font-size" do
    assigns = %{}

    html = rendered_to_string(~H|<CoreComponents.icon name="ph-git-fork" />|)

    assert html =~ ~s(class="ph-git-fork")
    refute html =~ "size-4"
  end
end
